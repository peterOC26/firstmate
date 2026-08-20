# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

The current candidate timings came from the 2026-07-29 concurrent proof recorded in [fm-test-isolation-proof.md](fm-test-isolation-proof.md).
The proof ran 24 candidates with four workers and no failures.

| duration_ms | script |
|---:|---|
| 52939 | `tests/fm-x-mode.test.sh` |
| 48294 | `tests/fm-backend-herdr.test.sh` |
| 46788 | `tests/fm-arm-pretool-check.test.sh` |
| 34207 | `tests/fm-cd-pretool-check.test.sh` |
| 30771 | `tests/fm-decision-hold-lifecycle.test.sh` |
| 25365 | `tests/fm-crew-state.test.sh` |
| 15674 | `tests/fm-test-run.test.sh` |
| 15422 | `tests/fm-herdr-lab.test.sh` |
| 9065 | `tests/fm-composer-ghost.test.sh` |
| 8564 | `tests/fm-pr-merge.test.sh` |
| 6251 | `tests/fm-grok-harness.test.sh` |
| 5644 | `tests/fm-send-popup-settle.test.sh` |
| 5237 | `tests/fm-lint.test.sh` |
| 4816 | `tests/fm-tmux-submit-busy.test.sh` |
| 2945 | `tests/fm-pi-primary-types.test.sh` |
| 2911 | `tests/fm-send-settle.test.sh` |
| 2875 | `tests/fm-review-diff.test.sh` |
| 2747 | `tests/fm-send-strict.test.sh` |
| 2224 | `tests/fm-brief.test.sh` |
| 855 | `tests/fm-spawn-batch.test.sh` |
| 703 | `tests/fm-supervision-instructions.test.sh` |
| 581 | `tests/fm-ensure-agents-md.test.sh` |
| 248 | `tests/fm-transition-lib.test.sh` |
| 64 | `tests/fm-composer-lib.test.sh` |

## Parallel lanes

The two parallel lanes use longest-processing-time assignment from those measured durations.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-parallel-1` | 11 | 162436 ms (~162.4 s) |
| `portable-parallel-2` | 13 | 162754 ms (~162.8 s) |
| imbalance | | 318 ms |

`bin/fm-test-run.sh` contains the exact ordered memberships in `list_portable_parallel_1` and `list_portable_parallel_2`.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, live-harness opt-in, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
The hints were refreshed on 2026-08-20 from the per-shard timing of CI runs [32266444318](https://github.com/peterOC26/firstmate/actions/runs/32266444318) and [32327637318](https://github.com/peterOC26/firstmate/actions/runs/32327637318), taking the larger of the two measurements per script so a fast-runner sample cannot under-hint a script.
They total 2645017 ms across the lane's 115 scripts, against the 69 scripts and 1143762 ms the previous 2026-08-02 hints described.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
That cost is real, which is why every serial script stays in the hint table.
While 44 of the 115 serial scripts had no hint, longest-processing-time balanced phantom loads instead of real ones: on run 32327637318 `portable-serial-2of4` was cancelled at its 15-minute cap after 17 of its 31 scripts, with `tests/fm-backend-orca.test.sh` still running.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-serial-1of4` | 27 | 661246 ms (~661.2 s) |
| `portable-serial-2of4` | 30 | 661254 ms (~661.3 s) |
| `portable-serial-3of4` | 29 | 661260 ms (~661.3 s) |
| `portable-serial-4of4` | 29 | 661257 ms (~661.3 s) |
| imbalance | | 14 ms |

Replaying both runs' measured durations against this partition puts every shard between 9m09s and 10m56s of actual work.

The single longest script, `tests/fm-pr-check-security.test.sh` at 199573 ms, is the floor for any shard count.

Refresh the hints by downloading the per-shard timing artifacts from a green CI run, replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the measured `path`/`duration_ms` pairs, and updating the table above.
Every script the serial lane lists belongs in that table, and when the pairs come from more than one run, keep the larger measurement per script.

```sh
gh run download <run-id> -R kunchenguid/firstmate --pattern 'fm-test-timing-portable-serial-*' -D /tmp/fm-serial
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*.json | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
Its `FM_TEST_COVERAGE` line also reports the planned serial shard budget as `serial_shard_max_ms` and `serial_unhinted`, so hints falling behind the suite are visible before a shard runs into its CI job cap.
`tests/fm-test-run.test.sh` holds that budget to well inside the `timeout-minutes` the workflow actually enforces.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Lane | Bound | Rationale |
|---|---|---|
| portable parallel 1/2 | job `timeout-minutes: 10` | The measured shard sums are about three minutes and the timeout is a hang tripwire. |
| portable serial 1-4 | job `timeout-minutes: 25` | Each balanced shard is about eleven minutes, leaving roughly 2x hang-tripwire margin over that plus the runner-speed spread seen between consecutive runs. |
| Herdr | family-run step `timeout-minutes: 20`; job `timeout-minutes: 75` backstop | Healthy runs finish around 7 minutes, so the step bound is the hang tripwire (cleanup and timing artifacts still upload) while the job cap stays a last-resort backstop. |

Timeouts are hang tripwires rather than expected healthy durations.
`.github/workflows/ci.yml` owns the exact numbers.
