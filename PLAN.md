# PLAN.md

Roadmap and intentional non-goals for `wallt0r`.

## Current Status

v0.1.0 is implemented and unreleased. The main script, attack corpus, example configuration, result output, changelog, and shell-level tests are in place.

Remaining release work:

- keep documentation aligned with the implemented behavior
- run smoke tests against real local/demo endpoints
- tag `v0.1.0` after the first release pass

## v0.1 — Minimum Viable Tool

Goal: a working shell script that sends attacks, measures metrics, writes a summary.

Scope:

- [x] `run.sh` with single-endpoint testing
- [x] bearer-token auth
- [x] default JSON body and template-file support
- [x] four threshold metrics: response bytes, latency seconds, token usage (where available), tool call count (where available)
- [x] six attack categories: recursion, expansion, loop, format inflation, tool-spam, context flooding
- [x] `results/summary.md` with PASS / SUSPICIOUS per attack
- [x] exit codes 0 / 1 / 2
- [x] CI mode flag
- [x] shell-level smoke tests against a mock endpoint
- [x] MIT license file
- [x] example templates for OpenAI-compatible and Anthropic Messages-style endpoints

Out of scope for v0.1:

- non-JSON request bodies
- non-bearer authentication
- streaming response endpoints
- cost-in-dollars calculation
- parallel request execution

## v0.2 — Refinement

Goal: clean up rough edges discovered in real-world use.

Likely scope:

- documented response-shape detection for major LLM providers (OpenAI, Anthropic, Ollama, generic)
- per-attack thresholds (some attacks legitimately produce larger responses than others)
- improved summary with aggregated metrics table at the top
- more attack prompts, especially for tool-using agents

Not committed. Scope confirmed only after v0.1 has been used against real endpoints.

## Unscheduled / Ideas

- Streaming response support (measure time-to-first-byte separately from total latency)
- Cost estimation given per-provider pricing tables
- Comparative mode (run same attacks against two endpoints, diff the summaries)
- Integration with `pinj` for combined security + cost reports

These are noted as possibilities, not commitments.

## Explicit Non-Goals

These will not be added regardless of demand:

- A web UI
- A Python or Node runtime
- YAML configuration
- A plugin system
- Cloud-hosted SaaS version
- Real-time monitoring or alerting (this is a pre-deployment tool, not a runtime guard)
- LLM-based response analysis (no AI in the analysis pipeline; the tool measures objective metrics only)

## Release Discipline

- Tag releases as `v0.1.0`, `v0.1.1`, etc.
- Changelog in `CHANGELOG.md` (added in v0.1).
- Breaking changes in v0.x: allowed, documented in changelog.
- Breaking changes in v1.x+: avoided; if necessary, major version bump.

## Design Decisions Worth Preserving

1. **No Python, no Node.** Bash + curl + jq is the deployment surface. Anyone with a shell can run this. Reconsidering this would change the tool's identity.
2. **Externalized thresholds.** Every team has different cost pain. The tool does not pick numbers for the user.
3. **Binary verdicts.** PASS or SUSPICIOUS. No scores, no severity levels. Severity is a conversation, not a metric.
4. **Attack corpus in repo.** No runtime fetch, no remote feed. The corpus is auditable and forkable.
5. **Sister tool to pinj.** Same shape, same idioms. Anyone who learned pinj should be able to use wallt0r in five minutes.
