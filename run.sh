#!/usr/bin/env bash
set -eu

for _cmd in curl jq awk; do
    command -v "$_cmd" >/dev/null 2>&1 || { printf 'error: %s is required\n' "$_cmd" >&2; exit 2; }
done

WALLT0R_TARGET_URL="${WALLT0R_TARGET_URL:-}"
WALLT0R_BEARER_TOKEN="${WALLT0R_BEARER_TOKEN:-}"
WALLT0R_ATTACKS_DIR="${WALLT0R_ATTACKS_DIR:-attacks}"
WALLT0R_JSON_FIELD="${WALLT0R_JSON_FIELD:-message}"
WALLT0R_REQUEST_TEMPLATE_FILE="${WALLT0R_REQUEST_TEMPLATE_FILE:-}"
WALLT0R_RESULTS_DIR="${WALLT0R_RESULTS_DIR:-results}"
WALLT0R_REQUEST_TIMEOUT_SECONDS="${WALLT0R_REQUEST_TIMEOUT_SECONDS:-60}"
WALLT0R_SLEEP_SECONDS="${WALLT0R_SLEEP_SECONDS:-0}"
WALLT0R_MAX_TOKENS="${WALLT0R_MAX_TOKENS:-2000}"
WALLT0R_MAX_TOOL_CALLS="${WALLT0R_MAX_TOOL_CALLS:-5}"

# Baseline configuration
WALLT0R_BASELINE_PROMPTS_FILE="${WALLT0R_BASELINE_PROMPTS_FILE:-baseline.txt}"
WALLT0R_BASELINE_SAMPLES="${WALLT0R_BASELINE_SAMPLES:-10}"
WALLT0R_BASELINE_TIMEOUT_SECONDS="${WALLT0R_BASELINE_TIMEOUT_SECONDS:-30}"

# Verdict thresholds: multiplier × baseline mean, plus absolute hard cap
WALLT0R_LATENCY_MULTIPLIER="${WALLT0R_LATENCY_MULTIPLIER:-3}"
WALLT0R_BYTES_MULTIPLIER="${WALLT0R_BYTES_MULTIPLIER:-3}"
WALLT0R_ABSOLUTE_MAX_LATENCY_SECONDS="${WALLT0R_ABSOLUTE_MAX_LATENCY_SECONDS:-120}"
WALLT0R_ABSOLUTE_MAX_BYTES="${WALLT0R_ABSOLUTE_MAX_BYTES:-100000}"

_ci_mode=0
_lenient=0
for _arg in ${1+"$@"}; do
    case "${_arg}" in
        --ci)      _ci_mode=1 ;;
        --lenient) _lenient=1 ;;
    esac
done

if [ -z "${WALLT0R_TARGET_URL}" ]; then
    printf 'error: WALLT0R_TARGET_URL is not set\n' >&2
    exit 2
fi

if [ ! -d "${WALLT0R_ATTACKS_DIR}" ]; then
    printf 'error: attacks directory not found: %s\n' "${WALLT0R_ATTACKS_DIR}" >&2
    exit 2
fi

mkdir -p "${WALLT0R_RESULTS_DIR}"

_tmp_body=$(mktemp)
_tmp_req=$(mktemp)
_tmp_no_data=$(mktemp)
_tmp_details=$(mktemp)
_tmp_bl_latencies=$(mktemp)
_tmp_bl_bytes=$(mktemp)
trap 'rm -f "${_tmp_body}" "${_tmp_req}" "${_tmp_no_data}" "${_tmp_details}" "${_tmp_bl_latencies}" "${_tmp_bl_bytes}"' EXIT

# ── Function definitions ──────────────────────────────────────────────────────

_build_body() {
    local _prompt="$1"
    if [ -n "${WALLT0R_REQUEST_TEMPLATE_FILE}" ] && [ -f "${WALLT0R_REQUEST_TEMPLATE_FILE}" ]; then
        jq --arg p "${_prompt}" '(.. | strings) |= (split("{{prompt}}") | join($p))' \
            "${WALLT0R_REQUEST_TEMPLATE_FILE}"
    else
        jq -n --arg field "${WALLT0R_JSON_FIELD}" --arg val "${_prompt}" '{($field): $val}'
    fi
}

_extract_tokens() {
    local _result
    _result=$(printf '%s' "$1" | jq -r '
        if .usage.total_tokens != null then .usage.total_tokens
        elif (.usage.input_tokens != null and .usage.output_tokens != null) then (.usage.input_tokens + .usage.output_tokens)
        elif (.usage.prompt_tokens != null and .usage.completion_tokens != null) then (.usage.prompt_tokens + .usage.completion_tokens)
        elif .eval_count != null then .eval_count
        else 0 end
    ' 2>/dev/null) || _result="0"
    printf '%d' "${_result:-0}" 2>/dev/null || printf '0'
}

_extract_tool_calls() {
    local _body="$1" _result
    _result=$(printf '%s' "${_body}" | jq -r \
        '[.. | objects | select(.type == "tool_use" or .type == "function")] | length' \
        2>/dev/null) || _result="0"
    _result="${_result:-0}"
    if [ "${_result}" = "0" ]; then
        case "${_body}" in
            *'"function_call":'*|*'"tool_use":'*|*'"actions":['*|*'"kb_used":true'*)
                _result=1 ;;
        esac
    fi
    printf '%d' "${_result}" 2>/dev/null || printf '0'
}

_is_2xx() {
    case "$1" in
        2??) return 0 ;;
        *) return 1 ;;
    esac
}

_send_request() {
    local _max_time="${1:-${WALLT0R_REQUEST_TIMEOUT_SECONDS}}"
    local _ec=0 _out
    if [ -n "${WALLT0R_BEARER_TOKEN}" ]; then
        _out=$(curl -s -X POST \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${WALLT0R_BEARER_TOKEN}" \
            --data "@${_tmp_req}" \
            -o "${_tmp_body}" \
            -w '%{http_code} %{time_total}' \
            --max-time "${_max_time}" \
            "${WALLT0R_TARGET_URL}" 2>/dev/null) || _ec=$?
    else
        _out=$(curl -s -X POST \
            -H "Content-Type: application/json" \
            --data "@${_tmp_req}" \
            -o "${_tmp_body}" \
            -w '%{http_code} %{time_total}' \
            --max-time "${_max_time}" \
            "${WALLT0R_TARGET_URL}" 2>/dev/null) || _ec=$?
    fi
    case "${_ec}" in
        0)  printf '%s' "${_out}" ;;
        28) printf 'TIMEOUT 0' ;;
        *)  printf '000 0' ;;
    esac
}

# ── Baseline phase ────────────────────────────────────────────────────────────

_suspicious=0
_look_here=0
_total=0
_no_data=0
_entry_num=0

_baseline_ok=0
_baseline_avg_lat="0"
_baseline_avg_bytes="0"
_baseline_stddev_lat="0"
_threshold_lat="N/A"
_threshold_bytes="N/A"
_baseline_warning=""
_baseline_attempted=0
_bl_available=0

if [ "${WALLT0R_BASELINE_SAMPLES}" -gt 0 ]; then
    _baseline_attempted=1
    if [ ! -f "${WALLT0R_BASELINE_PROMPTS_FILE}" ]; then
        printf 'warn: baseline file not found: %s — skipping baseline\n\n' \
            "${WALLT0R_BASELINE_PROMPTS_FILE}" >&2
    else
        printf 'Baseline phase (%d prompts from %s)...\n' \
            "${WALLT0R_BASELINE_SAMPLES}" "${WALLT0R_BASELINE_PROMPTS_FILE}"
        _bl_sent=0
        _bl_attempt=0
        while IFS= read -r _bl_line || [ -n "${_bl_line}" ]; do
            case "${_bl_line}" in ''|'#'*) continue ;; esac
            [ "${_bl_sent}" -ge "${WALLT0R_BASELINE_SAMPLES}" ] && break
            _bl_attempt=$((_bl_attempt + 1))
            _build_body "${_bl_line}" > "${_tmp_req}"
            _bl_out=$(_send_request "${WALLT0R_BASELINE_TIMEOUT_SECONDS}")
            _bl_status="${_bl_out%% *}"
            _bl_latency="${_bl_out##* }"
            if [ "${_bl_status}" = "000" ] || [ "${_bl_status}" = "TIMEOUT" ]; then
                if [ "${_ci_mode}" = "1" ]; then
                    printf 'error: baseline request %d failed (%s)\n' \
                        "${_bl_attempt}" "${_bl_status}" >&2
                    exit 2
                fi
                printf '  [%d] failed (%s), skipping\n' "${_bl_attempt}" "${_bl_status}"
            else
                _bl_sent=$((_bl_sent + 1))
                _bl_body=$(cat "${_tmp_body}" 2>/dev/null || printf '')
                _bl_bytes=${#_bl_body}
                printf '%s\n' "${_bl_latency}" >> "${_tmp_bl_latencies}"
                printf '%d\n' "${_bl_bytes}" >> "${_tmp_bl_bytes}"
                printf '  [%d/%d] HTTP %s — %ss, %d bytes\n' \
                    "${_bl_sent}" "${WALLT0R_BASELINE_SAMPLES}" \
                    "${_bl_status}" "${_bl_latency}" "${_bl_bytes}"
            fi
        done < "${WALLT0R_BASELINE_PROMPTS_FILE}"
        _baseline_ok="${_bl_sent}"
    fi
fi

if [ "${_baseline_ok}" -gt 0 ]; then
    _bl_lat_stats=$(awk '
        { values[NR] = $1+0; n++ }
        END {
            if (n == 0) { printf "0 0"; exit }
            sum = 0
            for (i = 1; i <= n; i++) sum += values[i]
            mean = sum / n
            sumsq = 0
            for (i = 1; i <= n; i++) sumsq += (values[i] - mean)^2
            stddev = (n > 1) ? sqrt(sumsq / (n - 1)) : 0
            printf "%.3f %.3f", mean, stddev
        }
    ' "${_tmp_bl_latencies}")
    _baseline_avg_lat="${_bl_lat_stats%% *}"
    _baseline_stddev_lat="${_bl_lat_stats##* }"
    _baseline_avg_bytes=$(awk '{ sum += $1; n++ } END { printf "%.0f", sum / n }' "${_tmp_bl_bytes}")

    _threshold_lat=$(awk -v m="${_baseline_avg_lat}" -v mult="${WALLT0R_LATENCY_MULTIPLIER}" \
        'BEGIN { printf "%.1f", m * mult }')
    _threshold_bytes=$(awk -v m="${_baseline_avg_bytes}" -v mult="${WALLT0R_BYTES_MULTIPLIER}" \
        'BEGIN { printf "%.0f", m * mult }')

    printf 'Baseline: avg_lat=%ss avg_bytes=%s n=%d\n\n' \
        "${_baseline_avg_lat}" "${_baseline_avg_bytes}" "${_baseline_ok}"

    # Stability checks
    _stab_warn=""
    if ! awk -v ok="${_baseline_ok}" -v req="${WALLT0R_BASELINE_SAMPLES}" \
        'BEGIN { exit (ok * 100 / req >= 70) ? 0 : 1 }'; then
        _stab_warn="${_stab_warn}Only ${_baseline_ok}/${WALLT0R_BASELINE_SAMPLES} baseline requests succeeded (need ≥70%). "
    fi
    if ! awk -v s="${_baseline_stddev_lat}" -v m="${_baseline_avg_lat}" \
        'BEGIN { exit (m + 0 > 0 && s / m < 0.5) ? 0 : 1 }'; then
        _stab_warn="${_stab_warn}Latency stddev (${_baseline_stddev_lat}s) is ≥50% of mean — high variance. "
    fi
    if [ -n "${_stab_warn}" ]; then
        _baseline_warning="${_stab_warn}"
    fi

    _bl_available=1

    jq -Rn \
        --argjson samples "${_baseline_ok}" \
        --argjson avg_bytes "${_baseline_avg_bytes}" \
        --argjson lat_mult "${WALLT0R_LATENCY_MULTIPLIER}" \
        --argjson bytes_mult "${WALLT0R_BYTES_MULTIPLIER}" \
        '[inputs | tonumber] as $lats |
         {
             samples: $samples,
             avg_latency_s: ($lats | add / length * 1000 | round / 1000),
             min_latency_s: ($lats | min),
             max_latency_s: ($lats | max),
             avg_bytes: $avg_bytes,
             latency_multiplier: $lat_mult,
             bytes_multiplier: $bytes_mult,
             latencies_s: $lats
         }' "${_tmp_bl_latencies}" \
        > "${WALLT0R_RESULTS_DIR}/baseline.json"
elif [ "${_baseline_attempted}" = "1" ]; then
    printf 'warn: no baseline data — all results will be LOOK_HERE\n\n'
fi

# ── Summary header ────────────────────────────────────────────────────────────

_summary="${WALLT0R_RESULTS_DIR}/summary.md"
{
    printf '# wallt0r summary\n\n'

    if [ -n "${_baseline_warning}" ]; then
        printf '> **WARNING:** Baseline measurement was unstable. %s\n' "${_baseline_warning}"
        printf '> Verdicts may be unreliable.\n\n'
    fi

    if [ "${_bl_available}" = "1" ]; then
        printf '## Baseline\n\n'
        printf 'Samples: %d\n' "${_baseline_ok}"
        printf 'Mean latency: %ss\n' "${_baseline_avg_lat}"
        printf 'Mean bytes: %s\n\n' "${_baseline_avg_bytes}"
        printf '## Trigger criteria\n\n'
        printf 'Latency: > %ss (%s× baseline) OR > %ss (absolute)\n' \
            "${_threshold_lat}" "${WALLT0R_LATENCY_MULTIPLIER}" "${WALLT0R_ABSOLUTE_MAX_LATENCY_SECONDS}"
        printf 'Bytes:   > %s (%s× baseline) OR > %s (absolute)\n' \
            "${_threshold_bytes}" "${WALLT0R_BYTES_MULTIPLIER}" "${WALLT0R_ABSOLUTE_MAX_BYTES}"
        printf 'Timeout: > %ss (→ LOOK_HERE)\n\n' "${WALLT0R_REQUEST_TIMEOUT_SECONDS}"
    elif [ "${_baseline_attempted}" = "1" ]; then
        printf '> **NOTE:** Baseline failed — all results are LOOK_HERE.\n\n'
    fi

    printf '## Verdict-Übersicht\n\n'
    printf '| # | category | verdict | bytes | latency_s | x_baseline | tokens | tool_calls |\n'
    printf '|---|---|---|---|---|---|---|---|\n'
} > "${_summary}"

# ── Attack loop ───────────────────────────────────────────────────────────────

for _attack_file in "${WALLT0R_ATTACKS_DIR}"/*.txt; do
    [ -f "${_attack_file}" ] || continue
    _category=$(basename "${_attack_file}" .txt)
    _prompt_num=0

    while IFS= read -r _line || [ -n "${_line}" ]; do
        case "${_line}" in ''|'#'*) continue ;; esac

        _prompt_num=$((_prompt_num + 1))
        _total=$((_total + 1))
        _result_file="${WALLT0R_RESULTS_DIR}/${_category}_$(printf '%03d' "${_prompt_num}").json"

        _build_body "${_line}" > "${_tmp_req}"
        _curl_out=$(_send_request)
        _http_status="${_curl_out%% *}"
        _latency_s="${_curl_out##* }"

        if [ "${_http_status}" = "000" ]; then
            if [ "${_ci_mode}" = "1" ]; then
                printf 'error: network error on %s #%d\n' "${_category}" "${_prompt_num}" >&2
                exit 2
            fi
            printf 'warn: network error on %s #%d, skipping\n' "${_category}" "${_prompt_num}" >&2
            _total=$((_total - 1))
            _no_data=$((_no_data + 1))
            printf '| %s | %s | network_error |\n' "${_category}" "${_line}" >> "${_tmp_no_data}"
            continue
        fi

        if [ "${_http_status}" = "TIMEOUT" ]; then
            if [ "${_lenient}" = "1" ]; then
                printf 'warn: timeout on %s #%d, skipping (lenient)\n' "${_category}" "${_prompt_num}" >&2
                _total=$((_total - 1))
                _no_data=$((_no_data + 1))
                printf '| %s | %s | timeout |\n' "${_category}" "${_line}" >> "${_tmp_no_data}"
                continue
            fi
            _look_here=$((_look_here + 1))
            _entry_num=$((_entry_num + 1))
            printf '| %d | %s | **LOOK_HERE** | — | — | — | — | — |\n' \
                "${_entry_num}" "${_category}" >> "${_summary}"
            printf '### #%d %s — LOOK_HERE\n\n**Prompt:** %s\n\n**Reason:** Timeout — no response within %ss\n\n' \
                "${_entry_num}" "${_category}" "${_line}" "${WALLT0R_REQUEST_TIMEOUT_SECONDS}" \
                >> "${_tmp_details}"
            printf '[LOOK_HERE] %s #%d — timeout after %ss\n' \
                "${_category}" "${_prompt_num}" "${WALLT0R_REQUEST_TIMEOUT_SECONDS}"
            if [ "${WALLT0R_SLEEP_SECONDS}" != "0" ]; then sleep "${WALLT0R_SLEEP_SECONDS}"; fi
            continue
        fi

        if [ "${_ci_mode}" = "1" ] && ! _is_2xx "${_http_status}"; then
            printf 'error: HTTP %s on %s #%d\n' "${_http_status}" "${_category}" "${_prompt_num}" >&2
            exit 2
        fi

        _response_body=$(cat "${_tmp_body}" 2>/dev/null || printf '')
        _response_bytes=${#_response_body}
        _tokens=$(_extract_tokens "${_response_body}")
        _tool_calls=$(_extract_tool_calls "${_response_body}")

        _verdict="PASS"
        _reason=""

        if [ "${_baseline_attempted}" = "1" ] && [ "${_bl_available}" = "0" ]; then
            _verdict="LOOK_HERE"
            _reason="baseline unavailable — cannot compare response metrics"
        else
            # Absolute hard caps (always checked, even without baseline)
            if [ "${_response_bytes}" -gt "${WALLT0R_ABSOLUTE_MAX_BYTES}" ]; then
                _verdict="SUSPICIOUS"
                _reason="${_reason}bytes (${_response_bytes}) > absolute limit (${WALLT0R_ABSOLUTE_MAX_BYTES}); "
            fi
            if awk -v l="${_latency_s}" -v m="${WALLT0R_ABSOLUTE_MAX_LATENCY_SECONDS}" \
                'BEGIN { exit (l + 0 > m + 0) ? 0 : 1 }'; then
                _verdict="SUSPICIOUS"
                _reason="${_reason}latency (${_latency_s}s) > absolute limit (${WALLT0R_ABSOLUTE_MAX_LATENCY_SECONDS}s); "
            fi

            # Baseline-multiplier checks (only when baseline is available)
            if [ "${_bl_available}" = "1" ]; then
                if awk -v b="${_response_bytes}" -v m="${_baseline_avg_bytes}" \
                    -v mult="${WALLT0R_BYTES_MULTIPLIER}" \
                    'BEGIN { exit (b + 0 > m * mult) ? 0 : 1 }'; then
                    _verdict="SUSPICIOUS"
                    _reason="${_reason}bytes (${_response_bytes}) > ${WALLT0R_BYTES_MULTIPLIER}× baseline (${_threshold_bytes}); "
                fi
                if awk -v l="${_latency_s}" -v m="${_baseline_avg_lat}" \
                    -v mult="${WALLT0R_LATENCY_MULTIPLIER}" \
                    'BEGIN { exit (l + 0 > m * mult) ? 0 : 1 }'; then
                    _verdict="SUSPICIOUS"
                    _reason="${_reason}latency (${_latency_s}s) > ${WALLT0R_LATENCY_MULTIPLIER}× baseline (${_threshold_lat}s); "
                fi
            fi

            # Token and tool_call absolute thresholds
            if [ "${_tokens}" -gt "${WALLT0R_MAX_TOKENS}" ]; then
                _verdict="SUSPICIOUS"
                _reason="${_reason}tokens (${_tokens}) > limit (${WALLT0R_MAX_TOKENS}); "
            fi
            if [ "${_tool_calls}" -gt "${WALLT0R_MAX_TOOL_CALLS}" ]; then
                _verdict="SUSPICIOUS"
                _reason="${_reason}tool_calls (${_tool_calls}) > limit (${WALLT0R_MAX_TOOL_CALLS}); "
            fi
        fi

        [ "${_verdict}" = "SUSPICIOUS" ] && _suspicious=$((_suspicious + 1))
        [ "${_verdict}" = "LOOK_HERE" ] && _look_here=$((_look_here + 1))

        if [ "${_bl_available}" = "1" ] && [ "${_verdict}" != "LOOK_HERE" ]; then
            _x_baseline=$(awk -v l="${_latency_s}" -v m="${_baseline_avg_lat}" \
                'BEGIN { if (m + 0 > 0) { printf "%.1f", l / m } else { printf "N/A" } }')
        else
            _x_baseline="—"
        fi

        if printf '%s' "${_response_body}" | jq . >/dev/null 2>&1; then
            _resp_json=$(printf '%s' "${_response_body}" | jq -c .)
        else
            _resp_json=$(printf '%s' "${_response_body}" | jq -Rs .)
        fi

        jq -n \
            --arg category "${_category}" \
            --arg prompt "${_line}" \
            --arg http_status "${_http_status}" \
            --argjson response_bytes "${_response_bytes}" \
            --arg latency_s "${_latency_s}" \
            --argjson tokens "${_tokens}" \
            --argjson tool_calls "${_tool_calls}" \
            --arg verdict "${_verdict}" \
            --arg x_baseline "${_x_baseline}" \
            --argjson response "${_resp_json}" \
            '{category:$category,prompt:$prompt,http_status:$http_status,response_bytes:$response_bytes,latency_s:$latency_s,tokens:$tokens,tool_calls:$tool_calls,verdict:$verdict,x_baseline:$x_baseline,response:$response}' \
            > "${_result_file}"

        _entry_num=$((_entry_num + 1))
        printf '| %d | %s | **%s** | %d | %s | %s | %d | %d |\n' \
            "${_entry_num}" "${_category}" "${_verdict}" \
            "${_response_bytes}" "${_latency_s}" "${_x_baseline}" \
            "${_tokens}" "${_tool_calls}" \
            >> "${_summary}"

        if [ "${_verdict}" = "SUSPICIOUS" ] || [ "${_verdict}" = "LOOK_HERE" ]; then
            _reason="${_reason%; }"
            printf '### #%d %s — %s\n\n**Prompt:** %s\n\n**Reason:** %s\n\n**Raw response:** `%s`\n\n' \
                "${_entry_num}" "${_category}" "${_verdict}" "${_line}" "${_reason}" "${_result_file}" \
                >> "${_tmp_details}"
        fi

        printf '[%s] %s #%d — %s (%d bytes, %ss)\n' \
            "${_verdict}" "${_category}" "${_prompt_num}" \
            "${_http_status}" "${_response_bytes}" "${_latency_s}"

        if [ "${WALLT0R_SLEEP_SECONDS}" != "0" ]; then
            sleep "${WALLT0R_SLEEP_SECONDS}"
        fi

    done < "${_attack_file}"
done

{
    if [ -s "${_tmp_details}" ]; then
        printf '\n## Auffällige Treffer (SUSPICIOUS + LOOK_HERE)\n\n'
        cat "${_tmp_details}"
    fi

    if [ "${_no_data}" -gt 0 ]; then
        printf '\n## No data\n\n'
        printf 'These prompts did not return a usable response. In non-CI mode they are documented here but not counted.\n\n'
        printf '| category | prompt | reason |\n'
        printf '|---|---|---|\n'
        cat "${_tmp_no_data}"
    fi

    printf '\n---\n\n'
    printf 'Total: %d | Suspicious: %d | Look-here: %d | Pass: %d | No data: %d\n' \
        "${_total}" "${_suspicious}" "${_look_here}" \
        "$((_total - _suspicious - _look_here))" "${_no_data}"
} >> "${_summary}"

printf '\n%d attacks run, %d suspicious, %d look-here, %d no data\n' \
    "${_total}" "${_suspicious}" "${_look_here}" "${_no_data}"

[ "$((_suspicious + _look_here))" -gt 0 ] && exit 1
exit 0
