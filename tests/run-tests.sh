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

_test_dir=$(mktemp -d)
_mock_pid=""

_stop_mock() {
    if [ -n "${_mock_pid}" ]; then
        kill "${_mock_pid}" 2>/dev/null || true
        _mock_pid=""
    fi
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
    local _len=${#_body}
    printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' \
        "${_len}" "${_body}" | nc -l "${_port}" >/dev/null 2>&1 &
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
    bash "${ROOT_DIR}/run.sh" --ci >/dev/null 2>&1
) || _rc=$?
[ "${_rc}" = "2" ] \
    && _pass "CI mode exits 2 on network error" \
    || _fail "CI mode exits 2 on network error (got ${_rc})"

# ── Test 7: summary.md is created ────────────────────────────────────────────
[ -f "${_test_dir}/r3/summary.md" ] \
    && _pass "summary.md is created" \
    || _fail "summary.md is created"

# ── Test 8: result JSON file is created ──────────────────────────────────────
_json_count=$(ls "${_test_dir}/r3/"*.json 2>/dev/null | wc -l | tr -d ' ')
[ "${_json_count}" -ge 1 ] \
    && _pass "result JSON file is created" \
    || _fail "result JSON file is created (got ${_json_count})"

# ── Test 9: result JSON contains expected fields ─────────────────────────────
_json_file=$(ls "${_test_dir}/r3/"*.json 2>/dev/null | head -1)
if [ -n "${_json_file}" ] && jq -e '.verdict and .prompt and .http_status and .response_bytes' \
    "${_json_file}" >/dev/null 2>&1; then
    _pass "result JSON contains expected fields"
else
    _fail "result JSON contains expected fields"
fi

# ── Test 10: non-JSON response is stored as string ───────────────────────────
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
    bash "${ROOT_DIR}/run.sh" >/dev/null 2>&1
) || _rc=$?
_stop_mock
_j10=$(ls "${_test_dir}/r10/"*.json 2>/dev/null | head -1)
if [ -n "${_j10}" ] && jq -e '.response | type == "string"' "${_j10}" >/dev/null 2>&1; then
    _pass "non-JSON response body is stored as string"
else
    _fail "non-JSON response body is stored as string"
fi

# ── Test 11: template file substitution ──────────────────────────────────────
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
    bash "${ROOT_DIR}/run.sh" >/dev/null 2>&1
) || _rc=$?
_stop_mock
[ "${_rc}" = "0" ] \
    && _pass "template file substitution runs without error" \
    || _fail "template file substitution runs without error (got ${_rc})"

# ─────────────────────────────────────────────────────────────────────────────
printf '\n%d passed, %d failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
[ "${FAIL_COUNT}" -gt 0 ] && exit 1
exit 0
