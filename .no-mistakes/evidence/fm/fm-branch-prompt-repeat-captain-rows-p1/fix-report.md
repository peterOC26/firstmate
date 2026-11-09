# Focused helper failure fix

Reproduced both reported failures against the original prompt using the real Sonnet helper engine, production report and outcome interfaces, a marked disposable home inside the assigned worktree, and an actual captain-held backlog decision.
A first unanswered decision with only routine history produced a silent fleet row; after a prior captain escalation was seeded and the durable choice changed without a mirror hint, the helper again produced a silent fleet row.
All engine turns succeeded with no permission denials.
This is a product prompt failure, not an authentication or infrastructure failure.

The trigger was an ordinary heartbeat.
The masking condition was a parked backlog decision without live worker metadata or a status-log decision; explicitly mirrored decisions had already worked in the prior evidence.
The visible symptom was a silent routine fleet outcome instead of a visible first or changed captain escalation.
The prompt allowed an unchanged fleet review to become silent before requiring the helper to inspect current backlog decisions and their escalation history.

The fix replaces that shortcut with mandatory current-backlog review and full pending-item reads before the verdict comparison, reports pending items by task id, and removes the duplicate unconditional silence instruction.
The existing once-per-unchanged-situation and visible-pending-wait rules remain the comparison policy.
The emitted-prompt interface assertions cover both host and Pi variants; they prove generated instruction delivery only.

## Verification

- `bash tests/fm-branch-supervision.test.sh`: passed before and after the fix; post-fix output is in `fix-focused-test.log`.
- `EVAL_EVIDENCE=<evidence>/fix-baseline bash .helper-repro.sh`: reproduced both named failures before the fix; this temporary script was subsequently preserved as `fix-helper-eval.sh` and removed from the worktree.
- `EVAL_EVIDENCE=<evidence>/fix-verified bash .helper-repro.sh`: passed after the fix using the same fixture, wake, model, and engine interfaces.
- `fix-behavior-assertions.json`: strict persisted-output checks require the correct task, captain/non-silent verdicts for the first and changed choices, and routine/non-silent for the unchanged repeat; the changed and repeated summaries must name the current next-month/weekday options.
- Engine result checks confirmed successful turns, no permission denials, and an empty acknowledged wake queue.
- Final MAIN drain output and before/after persisted outcome histories are retained under `fix-baseline/` and `fix-verified/`.

The live scope was the headless host engine in attended Sonnet posture, covering the reported failing cases and repeat suppression.
Pi's emitted prompt was checked through the deterministic test; its native live surface was not rerun, and the prior report's missing Pi credentials remain an unverified surface.
No full repository suite, linter, formatter, static analyzer, pipeline-control, push, PR, or CI phase was run.
Disposable homes were removed by their exit traps and the temporary evaluation script was removed from the worktree.
