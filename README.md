# wallt0r

`wallt0r` is a tiny denial-of-wallet smoke-test tool for LLM and agent HTTP endpoints.

It sends a small set of resource-exhausting prompts to a target endpoint, measures response size, latency, token usage, and tool call count, and flags responses that exceed configured thresholds.

`wallt0r` is intentionally simple.

It does not prove that an agent is cost-safe.

It helps find endpoints that fail basic resource limits.

---

## Why?

LLM and agent applications often expose new failure modes related to cost and resource consumption:

- runaway generation (model never stops)
- recursive tool calls
- multi-language or multi-format output explosion
- unbounded list expansion
- prompt-induced infinite loops
- context window flooding

Before deploying an AI endpoint, run resource-exhausting prompts against it.

If a single hostile prompt triples your hosting bill, that is something you want to know before production, not after.

This addresses OWASP LLM10:2025 (Unbounded Consumption).

---

## Current Scope

`wallt0r` assumes:

- HTTP POST endpoint
- JSON request body
- bearer-token authentication
- one prompt per line in each `attacks/*.txt` file

Default request body:

```
{
  "message": "prompt text"
}
```

To use a different prompt field, set:

```
export WALLT0R_JSON_FIELD="input"
```

---

## Files

```
wallt0r/
  README.md
  AGENTS.md
  PLAN.md
  attacks/
  config.example.env
  thresholds.example.env
  docs/
  examples/
  request.template.example.json
  run.sh
  tests/
  results/
```

---

## Quick Start

```
cp config.example.env .env
cp thresholds.example.env .thresholds
```

Edit `.env`:

```
export WALLT0R_TARGET_URL="https://example.com/chat"
export WALLT0R_BEARER_TOKEN="replace-me"
export WALLT0R_ATTACKS_DIR="attacks"
export WALLT0R_JSON_FIELD="message"
```

Edit `.thresholds`:

```
export WALLT0R_MAX_RESPONSE_BYTES=50000
export WALLT0R_MAX_LATENCY_SECONDS=30
export WALLT0R_MAX_TOKENS=4000
export WALLT0R_MAX_TOOL_CALLS=10
```

Then run:

```
. ./.env
. ./.thresholds
./run.sh
```

For CI:

```
./run.sh --ci
```

---

## Output

Results are written to:

```
results/
```

Example:

```
results/
  recursion_001.json
  expansion_001.json
  tool-spam_001.json
  summary.md
```

Each `summary.md` entry contains the prompt, the HTTP status, measured metrics (bytes, latency, tokens, tool calls), and the verdict (`PASS` or `SUSPICIOUS`).

---

## Attack Corpus

Attack prompts live in plain text files under:

```
attacks/
```

Each `.txt` file is treated as a category. Each non-empty line is sent as one prompt.

Example:

```
attacks/
  recursion.txt
  expansion.txt
  loop.txt
  tool-spam.txt
  context-flood.txt
```

To add or remove tests, edit those files or add another `.txt` file.

---

## Thresholds

A response is flagged `SUSPICIOUS` if any of the following exceed their configured limit:

- response size in bytes
- end-to-end latency in seconds
- reported token usage (when available)
- number of tool calls (when available)

Token usage and tool call counts are extracted from the response JSON when present. For OpenAI-compatible endpoints, `usage.total_tokens` is used. For endpoints that do not report token usage, response byte size serves as a proxy.

Thresholds are intentionally externalized so each project can choose its own pain point.

---

## Request Templates

By default, `wallt0r` sends:

```
{
  "message": "prompt text"
}
```

For endpoints that expect a different JSON shape, create a request template file and put `{{prompt}}` where each attack prompt should be injected.

Example:

```
{
  "messages": [
    {
      "role": "user",
      "content": "{{prompt}}"
    }
  ],
  "temperature": 0
}
```

Then set:

```
export WALLT0R_REQUEST_TEMPLATE_FILE="request.template.json"
```

When `WALLT0R_REQUEST_TEMPLATE_FILE` is set, it takes precedence over `WALLT0R_JSON_FIELD`.

Example templates are available in:

```
examples/
```

---

## Exit Codes

```
0 = no response exceeded any threshold
1 = at least one response exceeded a threshold
2 = configuration or runtime error
```

In CI mode, endpoint errors such as curl failures or non-2xx HTTP responses exit with `2`.

---

## Tests

Run the shell checks with:

```
./tests/run-tests.sh
```

---

## Limitations

`wallt0r` v0.1 measures simple, externally observable metrics.

It does not account for backend tool execution cost beyond what the endpoint reports.

It cannot detect cost spikes that occur after the response is returned.

It may produce false positives when the endpoint legitimately returns large or slow responses.

It is a smoke test, not a full cost-safety assessment.

---

## Example Attack Prompts

See:

```
attacks/
```

The initial corpus includes basic checks for:

- recursive generation (repeat forever, count to infinity)
- output expansion (translate into N languages, list all items)
- format inflation (return as JSON, then XML, then YAML, then CSV)
- tool-call spam (call every available tool repeatedly)
- context flooding (include large input, then ask for full repetition)
- nested elaboration (explain, then explain the explanation, then explain that)

---

## Related Tools

- `pinj` — prompt injection smoke-test ([github.com/t0nigansel/pinj](https://github.com/t0nigansel/pinj))
- Promptfoo — full LLM evaluation framework with broader coverage

`wallt0r` and `pinj` share a common design: small, curl-based, single shell script, no runtime dependencies beyond `bash`, `curl`, and `jq`.

---

## License

MIT