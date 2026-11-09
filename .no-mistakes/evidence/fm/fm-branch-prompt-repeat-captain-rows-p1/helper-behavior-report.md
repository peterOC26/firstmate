# Live helper validation: no-go

The helper still hides first-time decisions in attended Sonnet runs. Both independent cold conversations had a real captain-held backlog item and only an earlier routine outcome; both wrote a silent routine fleet row instead of a first captain escalation. A heartbeat also missed a materially changed choice when the change existed only in the durable backlog.

## Method

Ran the unmodified production `fm_supervision_engine_turn` with the generated host prompt, normal authenticated Claude CLI, and its real Bash/Read tools. Each disposable marked home contained an actual backlog item created and held by `fm-captain-hold.sh`. Each turn used the real wake queue, live-process-bound grant, report receipts, append-only outcome store, and acknowledgement commands. No model, login, tool, report, or outcome was stubbed; fixture backlog/history rows were explicitly seeded.

This is a live helper-engine evaluation, not a full primary/watch-loop or native UI test. No primary conversation was launched and no real fleet state was touched. Pi was not driven: `pi auth check --provider anthropic --no-refresh --json` returned `credentials_not_configured`. It needs an operator-configured Pi Anthropic login before re-running that surface.

| Case | Expected | Observed | Result |
| --- | --- | --- | --- |
| First unreported decision, attended Sonnet | captain, silent=false | seq 2: routine, silent=true | fail |
| Independent first unreported decision, attended Sonnet | captain, silent=false | seq 2: routine, silent=true | fail |
| First unreported decision, away Opus | captain, silent=false | seq 2: captain, silent=false | pass |
| Unchanged repeat after acknowledgement | routine, silent=false | seq 4: routine, silent=false | pass |
| Fresh Opus helper; captain outcome behind 25 unrelated rows | routine, silent=false | seq 30: routine, silent=false | pass |
| Changed choice in durable backlog, no mirror hint | captain, silent=false | seq 31: routine, silent=true | fail |
| Changed choice mirrored to attended Sonnet | captain, silent=false | seq 3: captain, silent=false | pass |
| Changed choice mirrored to away Opus | captain, silent=false | seq 3: captain, silent=false | pass |
| Unchanged updated choice, attended Sonnet | routine, silent=false | seq 4: routine, silent=false | pass |
| Unchanged updated choice, away Opus | routine, silent=false | seq 4: routine, silent=false | pass |

The original first-turn result explicitly admits: "I didn't check whether an earlier captain outcome already covers it, so if none does, the next wake should report it as a captain item." Its durable row was already silent. Both failed cold starts completed successfully without permission denials. The failure is helper decision-making rather than a CLI/login failure.

For unchanged situations, both resumed helpers and the fresh Opus helper produced routine, non-silent rows naming the pending choice. The fresh helper found the older captain row beyond the default history window. When the changed decision was explicitly mirrored, both attended Sonnet and away Opus escalated it once and kept subsequent repeats visible without another captain row.

## Evidence

- [First Sonnet result](initial-unreported-result.json) and [persisted rows](initial-unreported-after.jsonl).
- [Independent Sonnet result](verified-sonnet/unreported-cold-result.json) and [persisted rows](verified-sonnet/unreported-cold-after.jsonl).
- [Changed durable decision result](changed-decision-result.json) and [persisted rows](changed-decision-after.jsonl).
- [Actual MAIN drain output](main-visible-outcomes.txt).
- [Attended Sonnet final history](verified-sonnet/live-final-outcomes.jsonl).
- [Away Opus final history](verified-opus/live-final-outcomes.jsonl).
- [Machine-readable behavioral assertions](behavior-assertions.json).
- [Pi readiness](pi-provider-readiness.json).

## Baseline and cleanup

`bash tests/fm-branch-supervision.test.sh` passed. This checks emitted prompt delivery and record-layer behavior; it is not evidence of model adherence. No full repository suite, linter, formatter, or static analyzer was run. The first follow-up evaluation had a turn-posture serialization mistake; those exploratory results are excluded, documented in `setup-correction.txt`, and replaced by fresh corrected evaluations. All disposable homes were removed by their exit traps. No tracked files changed. No screenshot was captured because this change and evaluation use a headless prompt/CLI surface, not a rendered UI.
