# Changelog

## v0.1.0 — unreleased

Initial release.

- `run.sh`: single-endpoint testing via HTTP POST with bearer-token auth
- Default JSON body (`{field: prompt}`) and request template file support
- Four threshold metrics: response bytes, latency, token usage, tool call count
- Six attack categories: recursion, expansion, loop, tool-spam, context-flood, format-inflation
- `results/summary.md` with PASS / SUSPICIOUS verdict per attack
- Per-attack result JSON in `results/`
- Exit codes: 0 (all pass), 1 (at least one suspicious), 2 (config or runtime error)
- CI mode (`--ci`): exits 2 on any network error instead of skipping
- Token extraction supports OpenAI (`usage.total_tokens`, `usage.prompt_tokens + completion_tokens`) and Anthropic (`usage.input_tokens + output_tokens`) response shapes
- Tool call extraction supports Anthropic (`type: tool_use`) and OpenAI (`type: function`) response shapes
- Shell-level tests against a netcat mock (no Python required)
