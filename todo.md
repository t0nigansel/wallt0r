# wallt0r — TODO

Verbesserungen vor v0.1.0-Release und Launch-Artikel. Sortiert nach Impact pro Aufwand.

## Kritisch — vor Launch erledigen

### 1. Default-Thresholds aggressiver setzen

**Problem:** Aktuelle Defaults sind zu lax. AI-Goat-Run produziert 0 SUSPICIOUS bei 16 Tests, obwohl AI Goat by design verwundbar ist. Damit wirkt das Tool blind.

**Fix:** In `thresholds.example.env`:

```bash
export WALLT0R_MAX_RESPONSE_BYTES=10000      # statt 50000
export WALLT0R_MAX_LATENCY_SECONDS=10        # statt 30
export WALLT0R_MAX_TOKENS=2000               # statt 4000
export WALLT0R_MAX_TOOL_CALLS=5              # statt 10
```

**Validierung:** Erneuter AI-Goat-Run sollte ~6-10 SUSPICIOUS produzieren. Wenn nicht: weiter runterschrauben.

**Aufwand:** 10 Minuten.

---

### 2. Timeouts als eigenen Verdict behandeln

**Problem:** Context-Flood-Kategorie hat 100% Timeouts. Aktuell landen die unter "No data" — aber ein Endpoint, der bei Context-Flooding hängt, ist genau der Denial-of-Wallet-Fall, den wallt0r finden soll. Timeouts sind kein Bug, sondern das Symptom.

**Fix:**

- Neuen Verdict `TIMEOUT` einführen
- `TIMEOUT` zählt standardmäßig als SUSPICIOUS-Variante (Exit-Code 1)
- Optional: Flag `--lenient` für altes Verhalten (Timeouts = No-Data)
- In `summary.md` eigene Sektion oder eigene Spalte für Timeouts

**Validierung:** Nach Fix sollten die 13 Context-Flood-Timeouts in der AI-Goat-Run als SUSPICIOUS oder TIMEOUT auftauchen.

**Aufwand:** 30 Minuten.

---

### 3. README-Repo-Beschreibung korrigieren

**Problem:** GitHub-Beschreibung lautet *"Prüft ein LLM auf Denial-of-Wallet-Check angriffe"* — sprachlich krumm (doppeltes "check", "angriffe" klein, etc.).

**Fix:** Repo-Settings → Description ändern zu:

```
Denial-of-Wallet smoke-test for LLM and agent endpoints.
```

**Aufwand:** 1 Minute.

---

## Wichtig — vor Launch idealerweise erledigen

### 4. Token- und Tool-Call-Extraction für mehrere Provider

**Problem:** Alle Results zeigen `tokens: 0` und `tool_calls: 0`. Cracky liefert das Schema `{reply, flag, kb_used, kb_context_count}`, aber der Extractor sucht nach `usage.total_tokens` (OpenAI-Schema). Damit fallen zwei von vier Metriken still weg.

**Fix:** Mehrere JSON-Pfade in fester Reihenfolge probieren:

```bash
tokens=$(jq -r '
  .usage.total_tokens //
  (.usage.input_tokens + .usage.output_tokens) //
  .eval_count //
  0
' < response.json)
```

Plus optional: `WALLT0R_PROVIDER=openai|anthropic|ollama|generic` als Hint.

Für Tool-Calls Pattern-Fallback einbauen: wenn `tool_calls` nicht extractable, in Response-String nach Indikatoren suchen:

- `"function_call":`
- `"tool_use":`
- `"actions":[`
- `"kb_used":true`

Match zählt als 1 Tool-Call.

**Validierung:** AI-Goat-Run sollte für RAG-Aktivierungen (`kb_used:true`) jetzt tool_calls > 0 zeigen.

**Aufwand:** 1 Stunde.

---

### 5. summary.md-Format überarbeiten

**Problem:** Aktuelle Tabelle schneidet Prompts nach 30 Zeichen ab. Schwer lesbar.

**Fix:** Zwei-Sektionen-Format:

```markdown
## Verdict-Übersicht

| # | category | verdict | bytes | latency | tokens | tools |
|---|---|---|---|---|---|---|
| 1 | expansion | PASS | 487 | 7.8s | 0 | 0 |
| 2 | expansion | SUSPICIOUS | 12480 | 31.2s | 0 | 0 |

## Auffällige Treffer (SUSPICIOUS + TIMEOUT)

### #2 expansion — SUSPICIOUS

**Prompt:** Translate the word "hello" into every human language and dialect...

**Reason:** response_bytes (12480) exceeded threshold (10000)

**Raw response:** `results/expansion_002.json`
```

PASS-Einträge bleiben in der Übersicht, ausführliche Detail-Sektion nur für SUSPICIOUS/TIMEOUT.

**Aufwand:** 1-2 Stunden.

---

### 6. Fehlende Beispiel-Template-Datei

**Problem:** README erwähnt `request.template.example.json`, aber Datei existiert nicht im Repo.

**Fix:** `examples/openai-chat.template.json` und `examples/anthropic-messages.template.json` anlegen.

**Aufwand:** 15 Minuten.

---

## Nice-to-have — nach Launch

### 7. Cost-Estimation als optionale Spalte

Wenn Tokens extractable UND `WALLT0R_COST_PER_1K_TOKENS=0.002` gesetzt, eine Kosten-Spalte in summary.md ergänzen. Macht das Tool unmittelbar geschäftsrelevant.

**Beispiel-Output:**

```
| category | verdict | tokens | est_cost_usd |
|---|---|---|---|
| expansion | SUSPICIOUS | 4830 | $0.0097 |
```

Gesamt-Summe am Ende der Tabelle: "Total estimated cost for this run: $0.X".

**Aufwand:** 1 Stunde.

---

### 8. v0.1.0-Release taggen

Nach den kritischen Fixes:

```bash
git tag v0.1.0
git push origin v0.1.0
```

GitHub-Release-Notes mit den AI-Goat-Test-Ergebnissen als Beispiel.

**Aufwand:** 10 Minuten.

---

### 9. CHANGELOG.md pflegen

Schon angelegt, aber leer. Einträge für v0.1.0:

```markdown
## [0.1.0] - 2026-XX-XX

### Added
- Initial release
- Five attack categories: recursion, expansion, format-inflation, loop, tool-spam, context-flood
- Four threshold metrics: response_bytes, latency_seconds, tokens, tool_calls
- Multi-provider token extraction (OpenAI, Anthropic, Ollama, generic)
- Timeout-as-SUSPICIOUS handling
- Tested against AI Goat (results in examples/)
```

**Aufwand:** 15 Minuten.

---

### 10. Beispiel-Run als Commit-In-Repo

`examples/aigoat-results-2026-05-14/` mit echten Run-Outputs, damit Repo-Besucher ohne lokales Setup sehen, was wallt0r produziert. Anonymisierung nicht nötig (AI Goat ist Open Source).

**Aufwand:** 15 Minuten.

---

## Empfohlene Reihenfolge

**Heute (1-2 Stunden):**

1. Default-Thresholds runter (#1)
2. Repo-Beschreibung fixen (#3)
3. Fehlende Template-Datei anlegen (#6)
4. AI Goat erneut testen — neue Ergebnisse für Launch-Artikel sammeln

**Diese Woche (3-4 Stunden):**

5. Timeouts als Verdict (#2)
6. Token-/Tool-Call-Extractor reparieren (#4)
7. summary.md-Format überarbeiten (#5)
8. AI Goat dritter Test-Run — jetzt mit allen Verbesserungen
9. CHANGELOG.md schreiben (#9)
10. Beispiel-Run committen (#10)
11. v0.1.0 taggen (#8)
12. Launch-Artikel mit konkreten Zahlen aus drittem Run

**Optional:**

13. Cost-Estimation (#7) — kann auch v0.2 sein

---

## Definition of Done für Launch

- [ ] AI-Goat-Run zeigt ≥ 5 SUSPICIOUS oder TIMEOUT
- [ ] summary.md ist ohne Erklärung lesbar
- [ ] Repo hat v0.1.0-Tag
- [ ] examples/ enthält einen echten Run
- [ ] CHANGELOG dokumentiert v0.1.0
- [ ] Launch-Artikel mit konkreten Zahlen geschrieben