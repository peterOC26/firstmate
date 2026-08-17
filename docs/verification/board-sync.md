# GitHub fleet-board sync verification

Audience: maintainer verification.

This record holds reusable evidence for the board sync's active exposure, exclusion, baseline, and watcher-check guarantees.
`docs/configuration.md` owns the operating contract, while `bin/fm-board-sync.sh` owns exact formats and mechanics.

Verified on 2026-08-17 on macOS with the repository-pinned ShellCheck and the behavior suite in `tests/fm-board-sync.test.sh`.

The focused behavior command is:

```sh
bin/fm-test-run.sh tests/fm-board-sync.test.sh
```

Its thirty-four behavioral cases prove custom-check arm/status/disarm, withdrawal of a check whose trust binding fails, allowlisted issue bodies, exclusion-file enforcement, opaque titles for tasks with no structured title, escalation of excluded tasks that still hold a card, retirement of that report once the card is gone, single-instance reconcile locking, pending-create recovery, private-repository refusal, mutation-free dry runs for both new and already-mapped tasks, pointer-only poll deduplication, escalation-only pull, wake quiescence for an already-reported board move, no silent suppression of a mapped board move that lands inside the reconcile window, no silent absorption of a foreign-card change or addition that lands in that same window, explained fleet-authoritative conflict snapback, escalation of a write over an unrecorded baseline without inventing a captain move, escalation of a cleared Status by the run that restores the column, escalation of a hand-archived card that is otherwise left completely alone, an ordinary forward column write that is never called a snapback, a brand-new board card carried as the one adoption, adoption of a hand-filed card as its task's own card instead of a duplicate with the captain's own body preserved verbatim under the appended token, escalation of a matching draft card for conversion with nothing minted meanwhile, exactly one truthful escalation for a card removed from the board, retirement of a mapping the sync no longer owns once its card is gone, an archived card that counts pending once and wakes again only when it is unarchived, a card re-added under a new board item id that reconciles and rebinds instead of wedging, a dry-run plan that matches the real operation list field for field, a dry run that recovers an existing card by token instead of proposing a duplicate adoption, a board read that survives an all-digit GitHub login, a foreign card that counts once and then only when it really moves, a bare GitHub touch that never re-wakes the poll, and escalations that report only what the run actually observes.

The security fixtures contain free-form hold detail, a private path, a credential-shaped value, an excluded confidential title, and internal task ids, all of them invented for the fixture and describing nothing real.
The fake GitHub boundary records every argument and fails the case if any forbidden fixture value reaches a GitHub call.
A missing, empty, unreadable, or symlinked `config/board-exclude` is a separate negative case that must exit nonzero before the first GitHub call, so the exclusion guarantee is not only an absence assertion against a compliant fixture.
A task carrying only free-form runtime detail is a second negative case whose issue title must degrade to the opaque correlation token rather than that detail.
Each of these guarantees was confirmed to fail when its implementation was neutralized, so none of them passes vacuously.
The cases added for the all-digit login, the foreign-card baseline, the mid-reconcile foreign-card window, the retiring excluded-card report, and the withdrawn check binding were each confirmed to fail against the code that preceded their fix, so each one reproduces the reported defect.
The cases added for the cleared Status, the hand-archived card, and the truthful forward-write explanation were confirmed the same way against the code that preceded each of those fixes.
Together with the conflict and unrecorded-baseline cases they assert the standing property that a board-side change is escalated by the same run that observes it, whether or not that run also set the card back to the fleet column.
The cases added for card adoption, the matching draft card, the removed card, mapping retirement, and the dry-run token recovery were each confirmed to fail against the code that preceded their fix.
The adoption case is the end-to-end proof of the one automatic pull action: a hand-filed card becomes its task's own card with no second issue minted and no further adoption report.
It also proves the origin rule, that an adopted captain-authored body survives verbatim with only the token marker appended and is not rewritten again on the next run, while the allowlist negative controls still prove a firstmate-created body carries nothing beyond the allowlist.
The cases added for the re-added board item id, the archived-card baseline, and dry-run plan parity were each confirmed to fail against the code that preceded their fix, the last of them by making the dry-run plan diverge again on purpose.
The fake GitHub boundary rejects a numeric-looking `owner` sent as a typed GraphQL variable exactly as the real API type checker would, so the all-digit login case exercises the coercion rather than asserting the flag.

The exact focused result for this revision is:

```text
board-sync tests: 34 passed
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=51144
```

The affected projection, documentation, and runner surfaces were exercised together with:

```sh
bin/fm-test-run.sh tests/fm-board-sync.test.sh tests/fm-bearings-snapshot.test.sh tests/fm-fleet-snapshot-view.test.sh tests/fm-documentation-audiences.test.sh tests/fm-test-run.test.sh
```

The exact aggregate result was:

```text
FM_TEST_SUMMARY total=5 failed=0 skipped_gate=0 duration_ms=234439
FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=2 duration_ms=27573 failed=0
FM_TEST_SUMMARY_FAMILY family=snapshot-bearings count=3 duration_ms=206557 failed=0
```

Pinned lint and documentation classification returned:

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-doc-audience-check: ok surfaces=68 local_links=219
```

Refresh shell syntax, lint, documentation classification, and changed-surface evidence with:

```sh
while IFS= read -r script; do /bin/bash -n "$script" || exit; done < <(bin/fm-lint.sh --list-files)
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
bin/fm-test-run.sh --changed
```

GitHub infrastructure was inspected after setup with `gh-axi repo view peterOC26/fleet`, `gh-axi project view 1 --owner peterOC26`, and `gh-axi project field-list 1 --owner peterOC26`.
Those reads confirmed a private `peterOC26/fleet` repository, project #1 titled `Fleet`, and Status options `Ready`, `Held`, `Blocked`, `Under way`, `Waiting on you`, and `Done`.
Disabling the five built-in Status-writing project workflows remains a manual captain action and is not claimed as automated verification.
