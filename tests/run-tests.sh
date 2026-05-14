#!/usr/bin/env bash
set -eu

PASS_COUNT=0
FAIL_COUNT=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

_pass() { printf '[PASS] %s\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
_fail() { printf '[FAIL] %s\n' "$1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

command -v nc >/dev/null 2>&1 || { printf 'error: nc (netcat) is required for tests\n' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'error: jq is required\n' >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { printf 'error: python3 is required for baseline tests\n' >&2; exit 2; }

_test_dir=$(mktemp -d)
_mock_pid=""

_stop_mock() {
    if [ -n "${_mock_pid}" ]; then
        kill "${_mock_pid}" 2>/dev/null || true
        _mock_pid=""
    fi
}

# Start a persistent HTTP server that responds to every POST request with _body.
# Uses python3 http.server. Sets _mock_pid.
_start_persistent_mock() {
    local _port="$1" _body="$2"
    local _body_file _srv_file
    _body_file=$(mktemp)
    _srv_file=$(mktemp)
    printf '%s' "${_body}" > "${_body_file}"
    cat > "${_srv_file}" << 'PYEOF'
import sys, http.server

class H(http.server.BaseHTTPRequestHandler):
    body_file = sys.argv[2]
    def do_POST(self):
        with open(self.body_file, 'rb') as f:
            body = f.read()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass

http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PYEOF
    python3 "${_srv_file}" "${_port}" "${_body_file}" &
    _mock_pid=$!
    sleep 0.3
}

trap 'rm -rf "${_test_dir}"; _stop_mock' EXIT

# Find a free port starting from 18765
_free_port() {
    local _p=18765
    while nc -z 127.0.0.1 "$_p" 2>/dev/null; do
        _p=$((_p + 1))
    done
    printf '%d' "$_p"
}

# Start a one-shot nc mock that responds to a single request, then exits.
# Each test that needs the mock calls this.
_start_mock() {
    local _port="$1" _body="$2"
    local _status="${3:-200 OK}"
    local _len=${#_body}
    printf 'HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' \
        "${_status}" "${_len}" "${_body}" | nc -l "${_port}" >/dev/null 2>&1 &
    _mock_pid=$!
    sleep 0.2
}

_port=$(_free_port)

# ── single-prompt attack file used by all integration tests ──────────────────
mkdir -p "${_test_dir}/attacks"
printf '# test\ncount to infinity\n' > "${_test_dir}/attacks/recursion.txt"

# ── Test 1: exits 2 when WALLT0R_TARGET_URL is not set ───────────────────────
_rc=0
(
    export WALLT0R_TARGET_URL=""
    export WALLT0R_ATTACKS_DIR="${_test_dir}/attacks"
    export WALLT0R_RESULTS_DIR="${_test_dir}/r1"
    bash "${ROOT_DIR}/run.sh" >/dev/null 2>&1
) || _rc=$?
[ "${_rc}" = "2" ] \
    && _pass "exits 2 when WALLT0R_TARGET_URL not set" \
    || _fail "exits 2 when WALLT0R_TARGET_URL not set (got ${_rc})"

# ── Test 2: exits 2 when attacks dir does not exist ──────────────────────────
_rc=0
(
    export WALLT0R_TARGET_URL="http://127.0.0.1:${_port}/chat"
    export WALLT0R_ATTACKS_DIR="${_test_dir}/no-such-dir"
    export WALLT0R_RESULTS_DIR="${_test_dir}/r2"
    bash "${ROOT_DIR}/run.sh" >/dev/null 2>&1
) || _rc=$?
[ "${_rc}" = "2" ] \
    && _pass "exits 2 when attacks dir does not exist" \
    || _fail "exits 2 when attacks dir does not exist (got ${_rc})"

# ── Test 3: exits 0 when response is under all thresholds ────────────────────
_start_mock "${_port}" '{"reply":"ok","usage":{"total_tokens":10}}'
_rc=0
(
    export WALLT0R_TARGET_URL="http://127.0.0.1:${_port}/chat"
    export WALLT0R_BEARER_TOKEN=""
    export WALLT0R_ATTACKS_DIR="${_test_dir}/attacks"
    export WALLT0R_RESULTS_DIR="${_test_dir}/r3"
    export WALLT0R_MAX_RESPONSE_BYTES=50000
    export WALLT0R_MAX_LATENCY_SECONDS=30
    export WALLT0R_MAX_TOKENS=4000
    export WALLT0R_MAX_TOOL_CALLS=10
    export WALLT0R_BASELINE_COUNT=0
    bash "${ROOT_DIR}/run.sh" >/dev/null 2>&1
) || _rc=$?
_stop_mock
[ "${_rc}" = "0" ] \
    && _pass "exits 0 when all responses pass thresholds" \
    || _fail "exits 0 when all responses pass thresholds (got ${_rc})"

# ── Test 4: exits 1 when response exceeds byte threshold ─────────────────────
_big=$(awk 'BEGIN { for (i=0;i<250;i++) printf "AAAA"; print "" }')
_start_mock "${_port}" "{\"reply\":\"${_big}\"}"
_rc=0
(
    export WALLT0R_TARGET_URL="http://127.0.0.1:${_port}/chat"
    export WALLT0R_BEARER_TOKEN=""
    export WALLT0R_ATTACKS_DIR="${_test_dir}/attacks"
    export WALLT0R_RESULTS_DIR="${_test_dir}/r4"
    export WALLT0R_MAX_RESPONSE_BYTES=100
    export WALLT0R_MAX_LATENCY_SECONDS=30
    export WALLT0R_MAX_TOKENS=4000
    export WALLT0R_MAX_TOOL_CALLS=10
    export WALLT0R_BASELINE_COUNT=0
    bash "${ROOT_DIR}/run.sh" >/dev/null 2>&1
) || _rc=$?
_stop_mock
[ "${_rc}" = "1" ] \
    && _pass "exits 1 when response exceeds byte threshold" \
    || _fail "exits 1 when response exceeds byte threshold (got ${_rc})"

# ── Test 5: exits 1 when response exceeds token threshold ────────────────────
_start_mock "${_port}" '{"reply":"ok","usage":{"total_tokens":9999}}'
_rc=0
(
    export WALLT0R_TARGET_URL="http://127.0.0.1:${_port}/chat"
    export WALLT0R_BEARER_TOKEN=""
    export WALLT0R_ATTACKS_DIR="${_test_dir}/attacks"
    export WALLT0R_RESULTS_DIR="${_test_dir}/r5"
    export WALLT0R_MAX_RESPONSE_BYTES=50000
    export WALLT0R_MAX_LATENCY_SECONDS=30
    export WALLT0R_MAX_TOKENS=100
    export WALLT0R_MAX_TOOL_CALLS=10
    export WALLT0R_BASELINE_COUNT=0
    bash "${ROOT_DIR}/run.sh" >/dev/null 2>&1
) || _rc=$?
_stop_mock
[ "${_rc}" = "1" ] \
    && _pass "exits 1 when response exceeds token threshold" \
    || _fail "exits 1 when response exceeds token threshold (got ${_rc})"

# ── Test 6: CI mode exits 2 on network error ─────────────────────────────────
_rc=0
(
    export WALLT0R_TARGET_URL="http://127.0.0.1:19999/nowhere"
    export WALLT0R_BEARER_TOKEN=""
    export WALLT0R_ATTACKS_DIR="${_test_dir}/attacks"
    export WALLT0R_RESULTS_DIR="${_test_dir}/r6"
    export WALLT0R_MAX_RESPONSE_BYTES=50000
    export WALLT0R_MAX_LATENCY_SECONDS=3
    export WALLT0R_MAX_TOKENS=4000
    export WALLT0R_MAX_TOOL_CALLS=10
    export WALLT0R_BASELINE_COUNT=0
    bash "${ROOT_DIR}/run.sh" --ci >/dev/null 2>&1
) || _rc=$?
[ "${_rc}" = "2" ] \
    && _pass "CI mode exits 2 on network error" \
    || _fail "CI mode exits 2 on network error (got ${_rc})"

# ── Test 7: non-CI network error is documented as no data ────────────────────
_rc=0
(
    export WALLT0R_TARGET_URL="http://127.0.0.1:19999/nowhere"
    export WALLT0R_BEARER_TOKEN=""
    export WALLT0R_ATTACKS_DIR="${_test_dir}/attacks"
    export WALLT0R_RESULTS_DIR="${_test_dir}/r7"
    export WALLT0R_MAX_RESPONSE_BYTES=50000
    export WALLT0R_MAX_LATENCY_SECONDS=3
    export WALLT0R_MAX_TOKENS=4000
    export WALLT0R_MAX_TOOL_CALLS=10
    export WALLT0R_BASELINE_COUNT=0
    bash "${ROOT_DIR}/run.sh" >/dev/null 2>&1
) || _rc=$?
if [ "${_rc}" = "0" ] && grep -q 'No data: 1' "${_test_dir}/r7/summary.md" \
    && grep -q 'network_error_or_timeout' "${_test_dir}/r7/summary.md"; then
    _pass "non-CI network error is documented as no data"
else
    _fail "non-CI network error is documented as no data (got ${_rc})"
fi

# ── Test 8: CI mode exits 2 on non-2xx HTTP response ─────────────────────────
_start_mock "${_port}" '{"error":"nope"}' '500 Internal Server Error'
_rc=0
(
    export WALLT0R_TARGET_URL="http://127.0.0.1:${_port}/chat"
    export WALLT0R_BEARER_TOKEN=""
    export WALLT0R_ATTACKS_DIR="${_test_dir}/attacks"
    export WALLT0R_RESULTS_DIR="${_test_dir}/r8"
    export WALLT0R_MAX_RESPONSE_BYTES=50000
    export WALLT0R_MAX_LATENCY_SECONDS=30
    export WALLT0R_MAX_TOKENS=4000
    export WALLT0R_MAX_TOOL_CALLS=10
    export WALLT0R_BASELINE_COUNT=0
    bash "${ROOT_DIR}/run.sh" --ci >/dev/null 2>&1
) || _rc=$?
_stop_mock
[ "${_rc}" = "2" ] \
    && _pass "CI mode exits 2 on non-2xx HTTP response" \
    || _fail "CI mode exits 2 on non-2xx HTTP response (got ${_rc})"

# ── Test 9: summary.md is created ────────────────────────────────────────────
[ -f "${_test_dir}/r3/summary.md" ] \
    && _pass "summary.md is created" \
    || _fail "summary.md is created"

# ── Test 10: result JSON file is created ─────────────────────────────────────
_json_count=$(ls "${_test_dir}/r3/"*.json 2>/dev/null | wc -l | tr -d ' ')
[ "${_json_count}" -ge 1 ] \
    && _pass "result JSON file is created" \
    || _fail "result JSON file is created (got ${_json_count})"

# ── Test 11: result JSON contains expected fields ────────────────────────────
_json_file=$(ls "${_test_dir}/r3/"*.json 2>/dev/null | head -1)
if [ -n "${_json_file}" ] && jq -e '.verdict and .prompt and .http_status and .response_bytes' \
    "${_json_file}" >/dev/null 2>&1; then
    _pass "result JSON contains expected fields"
else
    _fail "result JSON contains expected fields"
fi

# ── Test 12: non-JSON response is stored as string ───────────────────────────
_start_mock "${_port}" 'plain text response, not JSON'
_rc=0
(
    export WALLT0R_TARGET_URL="http://127.0.0.1:${_port}/chat"
    export WALLT0R_BEARER_TOKEN=""
    export WALLT0R_ATTACKS_DIR="${_test_dir}/attacks"
    export WALLT0R_RESULTS_DIR="${_test_dir}/r10"
    export WALLT0R_MAX_RESPONSE_BYTES=50000
    export WALLT0R_MAX_LATENCY_SECONDS=30
    export WALLT0R_MAX_TOKENS=4000
    export WALLT0R_MAX_TOOL_CALLS=10
    export WALLT0R_BASELINE_COUNT=0
    bash "${ROOT_DIR}/run.sh" >/dev/null 2>&1
) || _rc=$?
_stop_mock
_j10=$(ls "${_test_dir}/r10/"*.json 2>/dev/null | head -1)
if [ -n "${_j10}" ] && jq -e '.response | type == "string"' "${_j10}" >/dev/null 2>&1; then
    _pass "non-JSON response body is stored as string"
else
    _fail "non-JSON response body is stored as string"
fi

# ── Test 13: template file substitution ──────────────────────────────────────
_tmpl_dir="${_test_dir}/tmpl"
mkdir -p "${_tmpl_dir}/attacks"
printf '# test\nsay hello\n' > "${_tmpl_dir}/attacks/basic.txt"
printf '{"input":"{{prompt}}","mode":"test"}' > "${_tmpl_dir}/template.json"
_start_mock "${_port}" '{"reply":"ok"}'
_rc=0
(
    export WALLT0R_TARGET_URL="http://127.0.0.1:${_port}/chat"
    export WALLT0R_BEARER_TOKEN=""
    export WALLT0R_ATTACKS_DIR="${_tmpl_dir}/attacks"
    export WALLT0R_RESULTS_DIR="${_tmpl_dir}/results"
    export WALLT0R_REQUEST_TEMPLATE_FILE="${_tmpl_dir}/template.json"
    export WALLT0R_MAX_RESPONSE_BYTES=50000
    export WALLT0R_MAX_LATENCY_SECONDS=30
    export WALLT0R_MAX_TOKENS=4000
    export WALLT0R_MAX_TOOL_CALLS=10
    export WALLT0R_BASELINE_COUNT=0
    bash "${ROOT_DIR}/run.sh" >/dev/null 2>&1
) || _rc=$?
_stop_mock
[ "${_rc}" = "0" ] \
    && _pass "template file substitution runs without error" \
    || _fail "template file substitution runs without error (got ${_rc})"

# ── Test 14: Anthropic token shape is counted ────────────────────────────────
_start_mock "${_port}" '{"reply":"ok","usage":{"input_tokens":60,"output_tokens":50}}'
_rc=0
(
    export WALLT0R_TARGET_URL="http://127.0.0.1:${_port}/chat"
    export WALLT0R_BEARER_TOKEN=""
    export WALLT0R_ATTACKS_DIR="${_test_dir}/attacks"
    export WALLT0R_RESULTS_DIR="${_test_dir}/r13"
    export WALLT0R_MAX_RESPONSE_BYTES=50000
    export WALLT0R_MAX_LATENCY_SECONDS=30
    export WALLT0R_MAX_TOKENS=100
    export WALLT0R_MAX_TOOL_CALLS=10
    export WALLT0R_BASELINE_COUNT=0
    bash "${ROOT_DIR}/run.sh" >/dev/null 2>&1
) || _rc=$?
_stop_mock
[ "${_rc}" = "1" ] \
    && _pass "Anthropic token shape is counted against threshold" \
    || _fail "Anthropic token shape is counted against threshold (got ${_rc})"

# ── Test 15: tool calls are counted ──────────────────────────────────────────
_start_mock "${_port}" '{"content":[{"type":"tool_use"},{"type":"tool_use"}]}'
_rc=0
(
    export WALLT0R_TARGET_URL="http://127.0.0.1:${_port}/chat"
    export WALLT0R_BEARER_TOKEN=""
    export WALLT0R_ATTACKS_DIR="${_test_dir}/attacks"
    export WALLT0R_RESULTS_DIR="${_test_dir}/r14"
    export WALLT0R_MAX_RESPONSE_BYTES=50000
    export WALLT0R_MAX_LATENCY_SECONDS=30
    export WALLT0R_MAX_TOKENS=4000
    export WALLT0R_MAX_TOOL_CALLS=1
    export WALLT0R_BASELINE_COUNT=0
    bash "${ROOT_DIR}/run.sh" >/dev/null 2>&1
) || _rc=$?
_stop_mock
[ "${_rc}" = "1" ] \
    && _pass "tool calls are counted against threshold" \
    || _fail "tool calls are counted against threshold (got ${_rc})"

# ── Test 16: TIMEOUT counts as SUSPICIOUS (non-lenient) ──────────────────────
# tail -f /dev/null keeps nc stdin open so it never sends a response
tail -f /dev/null | nc -l "${_port}" >/dev/null 2>&1 &
_mock_pid=$!
sleep 0.3
_rc=0
(
    export WALLT0R_TARGET_URL="http://127.0.0.1:${_port}/chat"
    export WALLT0R_BEARER_TOKEN=""
    export WALLT0R_ATTACKS_DIR="${_test_dir}/attacks"
    export WALLT0R_RESULTS_DIR="${_test_dir}/r15"
    export WALLT0R_MAX_RESPONSE_BYTES=50000
    export WALLT0R_MAX_LATENCY_SECONDS=1
    export WALLT0R_REQUEST_TIMEOUT_SECONDS=1
    export WALLT0R_MAX_TOKENS=4000
    export WALLT0R_MAX_TOOL_CALLS=10
    export WALLT0R_BASELINE_COUNT=0
    bash "${ROOT_DIR}/run.sh" >/dev/null 2>&1
) || _rc=$?
_stop_mock
[ "${_rc}" = "1" ] \
    && _pass "TIMEOUT counts as SUSPICIOUS (exit 1)" \
    || _fail "TIMEOUT counts as SUSPICIOUS (exit 1) (got ${_rc})"

# ── Test 17: --lenient treats TIMEOUT as no-data ─────────────────────────────
tail -f /dev/null | nc -l "${_port}" >/dev/null 2>&1 &
_mock_pid=$!
sleep 0.3
_rc=0
(
    export WALLT0R_TARGET_URL="http://127.0.0.1:${_port}/chat"
    export WALLT0R_BEARER_TOKEN=""
    export WALLT0R_ATTACKS_DIR="${_test_dir}/attacks"
    export WALLT0R_RESULTS_DIR="${_test_dir}/r16"
    export WALLT0R_MAX_RESPONSE_BYTES=50000
    export WALLT0R_MAX_LATENCY_SECONDS=1
    export WALLT0R_REQUEST_TIMEOUT_SECONDS=1
    export WALLT0R_MAX_TOKENS=4000
    export WALLT0R_MAX_TOOL_CALLS=10
    export WALLT0R_BASELINE_COUNT=0
    bash "${ROOT_DIR}/run.sh" --lenient >/dev/null 2>&1
) || _rc=$?
_stop_mock
if [ "${_rc}" = "0" ] && grep -q 'No data: 1' "${_test_dir}/r16/summary.md" \
    && grep -q 'timeout' "${_test_dir}/r16/summary.md"; then
    _pass "--lenient treats TIMEOUT as no-data"
else
    _fail "--lenient treats TIMEOUT as no-data (got ${_rc})"
fi

# ── Test 18: Ollama eval_count token shape is counted ────────────────────────
_start_mock "${_port}" '{"response":"ok","eval_count":3000}'
_rc=0
(
    export WALLT0R_TARGET_URL="http://127.0.0.1:${_port}/chat"
    export WALLT0R_BEARER_TOKEN=""
    export WALLT0R_ATTACKS_DIR="${_test_dir}/attacks"
    export WALLT0R_RESULTS_DIR="${_test_dir}/r17"
    export WALLT0R_MAX_RESPONSE_BYTES=50000
    export WALLT0R_MAX_LATENCY_SECONDS=30
    export WALLT0R_MAX_TOKENS=100
    export WALLT0R_MAX_TOOL_CALLS=10
    export WALLT0R_BASELINE_COUNT=0
    bash "${ROOT_DIR}/run.sh" >/dev/null 2>&1
) || _rc=$?
_stop_mock
[ "${_rc}" = "1" ] \
    && _pass "Ollama eval_count token shape is counted against threshold" \
    || _fail "Ollama eval_count token shape is counted against threshold (got ${_rc})"

# ── Test 19: pattern-based tool call detection (kb_used:true) ────────────────
_start_mock "${_port}" '{"reply":"ok","kb_used":true}'
_rc=0
(
    export WALLT0R_TARGET_URL="http://127.0.0.1:${_port}/chat"
    export WALLT0R_BEARER_TOKEN=""
    export WALLT0R_ATTACKS_DIR="${_test_dir}/attacks"
    export WALLT0R_RESULTS_DIR="${_test_dir}/r18"
    export WALLT0R_MAX_RESPONSE_BYTES=50000
    export WALLT0R_MAX_LATENCY_SECONDS=30
    export WALLT0R_MAX_TOKENS=4000
    export WALLT0R_MAX_TOOL_CALLS=0
    export WALLT0R_BASELINE_COUNT=0
    bash "${ROOT_DIR}/run.sh" >/dev/null 2>&1
) || _rc=$?
_stop_mock
[ "${_rc}" = "1" ] \
    && _pass "pattern-based tool call detection (kb_used:true)" \
    || _fail "pattern-based tool call detection (kb_used:true) (got ${_rc})"

# ── Test 20: WALLT0R_BASELINE_COUNT=0 skips baseline (no baseline.json) ──────
_start_mock "${_port}" '{"reply":"ok","usage":{"total_tokens":10}}'
_rc=0
(
    export WALLT0R_TARGET_URL="http://127.0.0.1:${_port}/chat"
    export WALLT0R_BEARER_TOKEN=""
    export WALLT0R_ATTACKS_DIR="${_test_dir}/attacks"
    export WALLT0R_RESULTS_DIR="${_test_dir}/r19"
    export WALLT0R_MAX_RESPONSE_BYTES=50000
    export WALLT0R_MAX_LATENCY_SECONDS=30
    export WALLT0R_MAX_TOKENS=4000
    export WALLT0R_MAX_TOOL_CALLS=10
    export WALLT0R_BASELINE_COUNT=0
    bash "${ROOT_DIR}/run.sh" >/dev/null 2>&1
) || _rc=$?
_stop_mock
if [ "${_rc}" = "0" ] && [ ! -f "${_test_dir}/r19/baseline.json" ]; then
    _pass "WALLT0R_BASELINE_COUNT=0 skips baseline"
else
    _fail "WALLT0R_BASELINE_COUNT=0 skips baseline (rc=${_rc}, file=$(ls ${_test_dir}/r19/baseline.json 2>/dev/null || echo missing))"
fi

# ── Test 21: baseline.json is created with correct structure ──────────────────
_start_persistent_mock "${_port}" '{"reply":"ok","usage":{"total_tokens":10}}'
_rc=0
(
    export WALLT0R_TARGET_URL="http://127.0.0.1:${_port}/chat"
    export WALLT0R_BEARER_TOKEN=""
    export WALLT0R_ATTACKS_DIR="${_test_dir}/attacks"
    export WALLT0R_RESULTS_DIR="${_test_dir}/r20"
    export WALLT0R_MAX_RESPONSE_BYTES=50000
    export WALLT0R_MAX_LATENCY_SECONDS=30
    export WALLT0R_MAX_TOKENS=4000
    export WALLT0R_MAX_TOOL_CALLS=10
    export WALLT0R_BASELINE_COUNT=3
    bash "${ROOT_DIR}/run.sh" >/dev/null 2>&1
) || _rc=$?
_stop_mock
_bl_json="${_test_dir}/r20/baseline.json"
if [ -f "${_bl_json}" ] \
    && jq -e '.avg_latency_s and .min_latency_s and .max_latency_s and .successful and .latencies_s' \
        "${_bl_json}" >/dev/null 2>&1 \
    && [ "$(jq '.successful' "${_bl_json}")" = "3" ] \
    && [ "$(jq '.latencies_s | length' "${_bl_json}")" = "3" ]; then
    _pass "baseline.json created with correct structure (n=3)"
else
    _fail "baseline.json created with correct structure (rc=${_rc}, file=$(cat "${_bl_json}" 2>/dev/null || echo missing))"
fi

# ── Test 22: baseline section appears in summary.md ──────────────────────────
if grep -q 'Baseline:' "${_test_dir}/r20/summary.md" 2>/dev/null; then
    _pass "baseline section appears in summary.md"
else
    _fail "baseline section appears in summary.md"
fi

# ─────────────────────────────────────────────────────────────────────────────
printf '\n%d passed, %d failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
[ "${FAIL_COUNT}" -gt 0 ] && exit 1
exit 0
