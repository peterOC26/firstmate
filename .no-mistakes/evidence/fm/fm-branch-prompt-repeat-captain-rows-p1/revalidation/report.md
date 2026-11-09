# Helper behavior revalidation: go

Target: `1b383f416e3fd2cbeaab2fa151fc84c2d7ba5428`.

The two previously reported failures now pass in fresh attended Sonnet conversations. A parked decision with only routine history generates its first captain escalation. Changing the decision only in the durable backlog generates a new captain escalation. Unchanged repeats remain visible routine outcomes, including after real MAIN acknowledgement and when the earlier captain outcome is behind 25 unrelated rows.

## Method and scope

Ran ten real authenticated Claude helper-engine turns through production `fm_supervision_engine_turn`, using the generated host prompt, real Bash/Read tools, actual backlog holds, live-process-bound wake grants, real report receipts, durable outcome storage, and wake acknowledgements. Two marked disposable homes were created inside the assigned worktree and removed by exit traps. Fixture choices, answers, and historical outcomes are synthetic test inputs; no model response, tool, login, or report was stubbed.

This exercises the headless helper engine and report path. It does not exercise a primary UI or the complete watcher/primary loop. Native Pi was not driven: `pi auth check --provider anthropic --no-refresh --json` returned `credentials_not_configured`. An operator-configured Pi Anthropic login is needed to rerun that surface; no credentials were changed.

## Observed outcomes

| Case | Persisted result | Result |
| --- | --- | --- |
| initial-unreported | seq 2: captain, silent=false | pass |
| repeat-acknowledged | seq 3: routine, silent=false | pass |
| repeat-again | seq 4: routine, silent=false | pass |
| repeat-buried-history | seq 30: routine, silent=false | pass |
| changed-decision | seq 31: captain, silent=false | pass |
| changed-repeat | seq 32: routine, silent=false | pass |
| resolved-idle | seq 33: routine, silent=false | pass |
| away-initial | seq 34: captain, silent=false | pass |
| away-repeat | seq 35: routine, silent=false | pass |
| idle-empty | seq 1: routine, silent=true | pass |

The changed and repeated changed-decision summaries both name the current next-month versus paid emergency weekday choices. The newly recorded answer produces a visible routine resolution update, rather than a stale captain question. Away Opus reports the separate budget choice once and keeps its unchanged repeat visible without deciding it. The genuinely empty home produces a silent fleet review.

Two unchanged attended summaries use task `fleet` while naming the pending migration choice; their visibility and deduplication satisfy the acceptance intent. Captain escalations preserve the task identity. No tracked files were changed.

## Validation and evidence

- `bash tests/fm-branch-supervision.test.sh`: passed. This focused baseline checks emitted prompt delivery and record mechanics; prompt-text assertions are not model-adherence evidence.
- `EVAL_EVIDENCE=<this directory> bash <this directory>/live-helper-eval.sh`: nine live helper turns, all successful with no permission denials and empty acknowledged wake queues.
- `EVAL_EVIDENCE=<this directory>/idle bash <this directory>/idle-helper-eval.sh`: one live empty-home turn, successful and silent.
- `python3 <this directory>/assert-behavior.py` plus the empty-home persisted-output check: passed. Assertions inspect generated outcomes and engine results, not implementation text.
- `initial-main-drain.txt` shows the actual escalation presented to MAIN and its sequence-bound acknowledgement command. `live-final-outcomes.jsonl` and `idle/idle-empty-after.jsonl` retain the product's persisted rows. Per-turn messages, engine results, before/after rows, receipts, and remaining queues are retained alongside them.
- `git status --short`: clean after both exit traps completed.

No screenshot was captured because the changed surface and driven scenarios are headless prompt/CLI outputs. No linter, formatter, static analyzer, full repository suite, pipeline-control, push, PR, or CI phase ran.
