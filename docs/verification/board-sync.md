# GitHub fleet-board sync verification

Audience: maintainer verification.

This record holds reusable evidence for the board sync's active exposure, exclusion, baseline, and watcher-check guarantees.
`docs/configuration.md` owns the operating contract, while `bin/fm-board-sync.sh` owns exact formats and mechanics.

Verified on 2026-08-17 on macOS with the repository-pinned ShellCheck and the behavior suite in `tests/fm-board-sync.test.sh`.

The focused behavior command is:

```sh
bin/fm-test-run.sh tests/fm-board-sync.test.sh
```

Its twenty-two behavioral cases prove custom-check arm/status/disarm, withdrawal of a check whose trust binding fails, allowlisted issue bodies, exclusion-file enforcement, opaque titles for tasks with no structured title, reporting of excluded tasks that still hold a card, retirement of that report once the card is gone, single-instance reconcile locking, pending-create recovery, private-repository refusal, mutation-free dry runs for both new and already-mapped tasks, pointer-only poll deduplication, proposal-only pull, wake quiescence for a declined proposal, no silent suppression of a mapped board move that lands inside the reconcile window, no silent absorption of a foreign-card change or addition that lands in that same window, explained fleet-authoritative conflict snapback, a board read that survives an all-digit GitHub login, a foreign card that counts once and then only when it really moves, one stable proposal signature across a bare GitHub touch, and proposals that drain once their divergence is gone.

The security fixtures contain free-form hold detail, a private path, a credential-shaped value, an excluded confidential title, and internal task ids, all of them invented for the fixture and describing nothing real.
The fake GitHub boundary records every argument and fails the case if any forbidden fixture value reaches a GitHub call.
A missing, empty, unreadable, or symlinked `config/board-exclude` is a separate negative case that must exit nonzero before the first GitHub call, so the exclusion guarantee is not only an absence assertion against a compliant fixture.
A task carrying only free-form runtime detail is a second negative case whose issue title must degrade to the opaque correlation token rather than that detail.
Each of these guarantees was confirmed to fail when its implementation was neutralized, so none of them passes vacuously.
The four cases added for the all-digit login, the foreign-card baseline, the proposal drain, and the withdrawn check binding were each confirmed to fail against the code that preceded their fix, so each one reproduces the reported defect.
The three cases added for the mid-reconcile foreign-card window, the stable unmapped-card signature, and the retiring excluded-card report were confirmed the same way against the code that preceded each of those fixes.
The fake GitHub boundary rejects a numeric-looking `owner` sent as a typed GraphQL variable exactly as the real API type checker would, so the all-digit login case exercises the coercion rather than asserting the flag.

The exact focused result for this revision is:

```text
board-sync tests: 22 passed
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=26204
```

The affected projection, documentation, and runner surfaces were exercised together with:

```sh
bin/fm-test-run.sh tests/fm-board-sync.test.sh tests/fm-bearings-snapshot.test.sh tests/fm-fleet-snapshot-view.test.sh tests/fm-documentation-audiences.test.sh tests/fm-test-run.test.sh
```

The exact aggregate result was:

```text
FM_TEST_SUMMARY total=5 failed=0 skipped_gate=0 duration_ms=198064
FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=2 duration_ms=31041 failed=0
FM_TEST_SUMMARY_FAMILY family=snapshot-bearings count=3 duration_ms=166743 failed=0
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
