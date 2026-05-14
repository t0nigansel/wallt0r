# AGENTS.md

Guidance for AI coding agents (Claude Code, Cursor, Codex, Copilot Workspace) working on this repository.

## Project Identity

`wallt0r` is a denial-of-wallet smoke-test tool for LLM and agent HTTP endpoints. It sends resource-exhausting prompts and measures whether responses exceed configured thresholds for size, latency, token usage, and tool call count.

It is the sister tool to `pinj` (prompt injection smoke-test). Both tools share the same design principles.

## Design Principles

1. **Small over featureful.** No frameworks. No heavy dependencies. Shell + curl + jq.
2. **One job, done plainly.** This tool measures resource consumption against thresholds. It does not classify prompt content, it does not score responses semantically, it does not chain into broader evaluation pipelines.
3. **Configuration via environment variables and plain text files.** No YAML schemas. No DSL.
4. **Externalized thresholds.** Every project has different cost limits. Defaults are sane, but they must be easy to override.
5. **Plain text attack corpora.** One prompt per line, one file per category. New tests are added by creating new files.
6. **Honest limitations.** Document what the tool cannot do. Do not oversell.

## What This Tool Is Not

- Not a replacement for a full LLM evaluation framework.
- Not a load tester. Single-request resource checks, not sustained traffic.
- Not a cost calculator. It reports observable metrics, not dollar amounts.
- Not a tool for production runtime protection. It is for pre-deployment checks.

## File Conventions

- `run.sh` is the main entry point. Keep it readable. POSIX shell where possible; bash features only when necessary.
- Configuration: `config.example.env` for connection settings, `thresholds.example.env` for limits.
- Attack files: `attacks/<category>.txt`, one prompt per line, blank lines and `#`-prefixed lines ignored.
- Output: `results/<category>_<number>.json` for raw responses, `results/summary.md` for human-readable summary.
- Request templates: JSON files with `{{prompt}}` placeholder.

## Coding Guidelines

### Shell

- POSIX-compatible where possible. Bash features (arrays, `[[ ]]`) only where they make code clearly better.
- `set -eu` at the top of every script.
- Quote all variable expansions.
- Use `command -v` to check for dependencies before use.
- Prefer `printf` over `echo` for anything beyond plain literal strings.

### JSON handling

- Use `jq` for all JSON parsing. Do not regex JSON.
- For token usage extraction, support both flat (`usage.total_tokens`) and nested response shapes; document which paths are tried.

### Error handling

- Configuration errors: exit 2, print to stderr.
- Threshold breaches: exit 1, summary contains details.
- Network errors in CI mode: exit 2.
- Network errors in non-CI mode: log and continue, count as no-data, not as PASS.

## Things to Avoid

- Do not add Python, Node, or Go dependencies. This tool runs anywhere bash, curl, and jq are available.
- Do not silently change the request structure based on the response. Templates are explicit.
- Do not collapse `results/summary.md` into a single line. Each entry must be independently readable.
- Do not introduce a YAML config layer. The two env files are deliberate.
- Do not add scoring beyond `PASS` / `SUSPICIOUS`. This tool is binary by design.
- Do not import attack prompts from external services at runtime. The corpus is part of the repo.

## When Modifying Attack Corpora

- New categories go in new files, not appended to existing ones.
- Prompts must be plain text, one per line, no JSON escaping in the file.
- Prefer prompts that are short, illustrative, and obviously hostile. Subtlety is for other tools.
- Document the threat category in the file header as a `#` comment.

## When Adding Metrics

- Each new metric needs: an env variable for the threshold, extraction logic in `run.sh`, a column in `summary.md`, an entry in the README threshold section, and a test case.
- If a metric cannot be reliably extracted from arbitrary endpoints, document the conditions under which it works and the fallback behavior.

## Testing

- `tests/run-tests.sh` runs shell-level checks against a mock endpoint.
- New features need new test cases. Tests use a local mock server (Python's `http.server` is acceptable here as a test-only dependency, but must not be required for `run.sh` itself).

## Pull Request Expectations

- One concern per PR. Threshold logic, attack corpus expansion, and CI mode improvements are separate PRs.
- Update README and AGENTS.md when behavior changes.
- Run `./tests/run-tests.sh` before submitting.

## Versioning

Semantic versioning. v0.x is pre-stable; breaking changes to env variable names or file layouts are allowed but should be called out in the changelog.