# Changelog

## v0.2.0 — unreleased

### Changed

- Threshold model now uses baseline multipliers instead of fixed absolute values for latency and bytes
- Timeouts are now `LOOK_HERE` instead of `SUSPICIOUS`
- Added third verdict: `LOOK_HERE` for timeouts and ambiguous cases (baseline unavailable)
- `WALLT0R_BASELINE_COUNT` / `WALLT0R_BASELINE_PROMPT` replaced by `WALLT0R_BASELINE_SAMPLES` and `WALLT0R_BASELINE_PROMPTS_FILE`
- `WALLT0R_MAX_RESPONSE_BYTES` / `WALLT0R_MAX_LATENCY_SECONDS` replaced by multiplier + absolute-cap vars
- `summary.md` now has a `## Baseline` section, `## Trigger criteria`, and an `x_baseline` column

### Added

- `baseline.txt` — 10 default baseline prompts shipped with the repo
- `WALLT0R_LATENCY_MULTIPLIER`, `WALLT0R_BYTES_MULTIPLIER` (default 3×)
- `WALLT0R_ABSOLUTE_MAX_LATENCY_SECONDS` (default 120s), `WALLT0R_ABSOLUTE_MAX_BYTES` (default 100 000)
- `WALLT0R_BASELINE_SAMPLES`, `WALLT0R_BASELINE_PROMPTS_FILE`
- Baseline stability warning in `summary.md` when fewer than 70% of baseline requests succeed or latency variance is high
- `avg_bytes` field in `baseline.json`
- `x_baseline` field in per-attack result JSON

### Removed

- `WALLT0R_MAX_RESPONSE_BYTES`
- `WALLT0R_MAX_LATENCY_SECONDS`
- `WALLT0R_BASELINE_COUNT`
- `WALLT0R_BASELINE_PROMPT`

---

## v0.1.0 — unreleased

Initial release.

- `run.sh`: single-endpoint testing via HTTP POST with bearer-token auth
- Default JSON body (`{field: prompt}`) and request template file support
- Four threshold metrics: response bytes, latency, token usage, tool call count
- Six attack categories: recursion, expansion, loop, tool-spam, context-flood, format-inflation
- `results/summary.md` with PASS / SUSPICIOUS verdict per attack
- Network errors and timeouts in non-CI mode are documented under `No data` in `summary.md`
- Per-attack result JSON in `results/`
- Exit codes: 0 (all pass), 1 (at least one suspicious), 2 (config or runtime error)
- CI mode (`--ci`): exits 2 on any network error or non-2xx HTTP response instead of skipping
- Token extraction supports OpenAI (`usage.total_tokens`, `usage.prompt_tokens + completion_tokens`) and Anthropic (`usage.input_tokens + output_tokens`) response shapes
- Tool call extraction supports Anthropic (`type: tool_use`) and OpenAI (`type: function`) response shapes
- Shell-level tests against a netcat mock (no Python required)
