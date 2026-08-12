---
name: context-usage
description: >-
  Agent-only procedure for reading dispatched-worker context usage and handling
  a context usage warning or unknown result.
user-invocable: false
metadata:
  internal: true
---

# Worker context usage

This procedure is observational.
Modern harnesses own their context windows and automatic compaction, and Firstmate does not cap, rotate, interrupt, reroute, or refuse a worker because of this measurement.

## Audit

Run `bin/fm-context-usage.sh [<task-id> ...]` for the read-only fleet audit.
Use `--json` for machine-readable rows.
The script header and `--help` own its fields and exact adapter metrics.

Treat `unknown` as a first-class result.
Do not infer a count from a worktree, newest transcript, cumulative token field, display percentage, or cached-input subtraction.
A missing or conflicting binding, schema drift, unavailable exact transcript, or unreachable remote transcript stays unknown.

The reading is best-effort and bounded: only a fixed-size window at the end of the transcript is scanned, so a reported count can lag a turn, and a session whose latest usage record has scrolled past that window reports unknown.
Report it as an indicator, never as an exact or authoritative account, and do not chase a more exact number by hand.
Every row, unknown included, still carries the effective threshold.

`warning` means usage reached the operator's configured threshold.
`over` means usage exceeded a native context window reported by the runtime, not that Firstmate enforced or promised a ceiling.
Tell the captain the measured tokens and threshold or native window, then continue the existing supervision procedure.
Do not turn either status into automatic lifecycle action.

## Verification

Run `bin/fm-test-run.sh tests/fm-context-usage.test.sh` after reader, binding, or warning mechanics change.
[`docs/verification/context-usage.md`](../../../docs/verification/context-usage.md) records the installed-version evidence that the adapter metrics agree with each runtime's own display.
