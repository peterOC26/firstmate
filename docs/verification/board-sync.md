# GitHub fleet-board sync verification

Audience: maintainer verification.

This record holds reusable evidence for the board sync's active exposure, exclusion, one-way push, informational-note, and watcher-check guarantees.
[`../configuration.md`](../configuration.md) owns the operating contract, while `bin/fm-board-sync.sh` owns exact formats and mechanics.

Verified on 2026-08-18 on macOS with the repository-pinned ShellCheck and the behavior suite in `tests/fm-board-sync.test.sh`.

The focused behavior command is:

```sh
bin/fm-test-run.sh tests/fm-board-sync.test.sh
```

Its thirty-five behavioral cases prove custom-check arm, status, and disarm with trust-binding verification, withdrawal of a check whose trust binding fails, allowlisted issue bodies that reject credential-bearing artifacts, exclusion-file enforcement in both reconcile and poll, opaque titles for tasks with no structured title, identity-owned single-instance reconcile locking that blocks a second run while a live owner holds the lock, serializes competing stale-owner reclaimers, reclaims dead ones, and cannot be wedged by an interrupted claim publication, private-repository refusal at startup and again immediately before mutation, mutation-free dry runs for both new and already-mapped tasks, a dry-run plan that matches the real operation list field for field, persisted state that holds only the task mapping, pointer-only poll deduplication, a card off its fleet column that is noted and pushed back, a cleared Status that is noted and restored, a card removed from the board that is noted and restored at its fleet column, an archived card that is reported and never written, unarchived, or deleted, a closed issue that is reported and never reopened, an excluded task that receives no card, no write, and no note, an unmanaged card that is reported and left untouched, a separate canonical card created beside a same-title hand-filed issue and beside a manual draft, a card re-added under a new board item id that reconciles and rebinds instead of wedging, issue writes that follow the repository a task's own mapping records rather than a reconfigured one, a board read that survives an all-digit GitHub login, an already-reported board difference that stops re-waking the watcher while a new one still wakes it, board moves, archives, issue closes, and unmanaged-card changes landing inside the reconcile window that are never silently absorbed, a bare GitHub touch that never re-wakes the poll, and notes that report only what the run actually observes.

The suite asserts the reduced contract directly.
`test_state_holds_only_the_task_mapping` pins the persisted state and `status` keys, so no baseline, pending, orphan, retirement, or correlation-token field can return unnoticed.
`test_allowlist_and_exclusions` and `test_hand_filed_card_never_binds_to_a_fleet_task` assert that no correlation marker is ever published and that the sync never issues a GitHub issue search to adopt a card.
`test_archived_card_is_noted_and_left_untouched` and `test_closed_issue_is_noted_and_never_reopened` assert that a reported board fact produces no operation and no issue write, so a note stays a report.

The security fixtures contain free-form hold detail, a private path, a credential-shaped value, an excluded confidential title, and internal task ids, all of them invented for the fixture and describing nothing real.
The fake GitHub boundary records every argument and fails the case if any forbidden fixture value reaches a GitHub call, and it exits nonzero on any unexpected call shape, so an issue search or other unmodelled request fails the run rather than passing silently.
A missing, empty, unreadable, or symlinked `config/board-exclude` is a separate negative case that must exit nonzero before the first GitHub call, so the exclusion guarantee is not only an absence assertion against a compliant fixture.
A task carrying only free-form runtime detail is a second negative case whose issue title must degrade to the opaque label rather than that detail.
The fake GitHub boundary rejects a numeric-looking `owner` sent as a typed GraphQL variable exactly as the real API type checker would, so the all-digit login case exercises the coercion rather than asserting the flag.

Four guarantees were confirmed to fail when their implementation was neutralized on this revision, so they do not pass vacuously.
Dropping the intersection that keeps only notes the run both reported and still observed failed `a board move landing inside the reconcile window must still wake firstmate`.
Removing the skip that leaves an archived card alone failed `an archived card must produce one note and no operation at all`.
Removing the exclusion filter from the push loop failed `excluded task title must never reach GitHub (unexpected: 'CROWN_JEWELS')`.
Sending issue writes to the configured repository instead of the one a task's mapping records failed `issue writes must target the repository the mapping records (missing: 'repos/captain/legacy/issues/1')`.

The exact focused result for this revision is:

```text
board-sync tests: 35 passed
```

The affected projection, documentation, and runner surfaces were exercised together with:

```sh
bin/fm-test-run.sh tests/fm-board-sync.test.sh tests/fm-bearings-snapshot.test.sh tests/fm-fleet-snapshot-view.test.sh tests/fm-documentation-audiences.test.sh tests/fm-test-run.test.sh
```

The exact aggregate result was:

```text
FM_TEST_SUMMARY total=5 failed=0 skipped_gate=0 duration_ms=217774
FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=2 duration_ms=26212 failed=0
FM_TEST_SUMMARY_FAMILY family=snapshot-bearings count=3 duration_ms=191313 failed=0
```

Pinned lint and documentation classification returned:

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-doc-audience-check: ok surfaces=68 local_links=220
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
