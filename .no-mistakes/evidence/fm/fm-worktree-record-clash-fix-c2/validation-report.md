# Targeted CLI validation

The real Firstmate CLI was exercised against constructed persisted records in marked disposable homes, using real Git and private tmux endpoints without mock executables.
The checks used no live Treehouse pool acquisition, status, or return operation and no credentialed worker launch.

## Live results

- PASS: Spawn refuses before allocation when a finished, aliased, or registered-home record names an unleased copy ([transcript](live-cli-transcript.log)).
- PASS: Spawn explains missing local-home state and ambiguous records before allocation ([transcript](live-cli-transcript.log)).
- PASS: Retry with an unresolved acquisition journal refuses and prints never-acquired and orphan-claim recovery ([transcript](live-cli-transcript.log)).
- PASS: Forced cleanup of a missing leased copy preserves ownership records and prints exact recovery steps ([transcript](live-cli-transcript.log)).
- PASS: Owner-first cleanup refuses, then stale-record cleanup leaves the successor copy, process, endpoint, claim and lease untouched ([transcript](live-cli-transcript.log)).
- PASS: Forced cleanup cannot bypass an unreadable slot-owner claim ([transcript](live-cli-transcript.log)).
- PASS: Forced cleanup validates the exact lease before killing an endpoint or changing hooks and scratch files ([transcript](live-relaunch-transcript.log)).
- PASS: Records-only cleanup of an unclaimed legacy ship still refuses dirty unlanded work ([transcript](live-relaunch-transcript.log)).
- PASS: The installed Treehouse version supports JSON leases and identity-conditional return ([transcript](live-relaunch-transcript.log)).
- PASS: Relaunch refuses stale leases, claims, duplicate ownership and unreadable local-home records before endpoint mutation ([transcript](live-relaunch-rerun-transcript.log)).

The stale-record cleanup proof kept a real process running inside the successor copy and verified that its endpoint, dirty sentinel, metadata, claim and serialized pool lease remained unchanged.
The relaunch checks compared pane PID, window identity, current working directory, metadata, claim and pool state before and after refusal.

## Focused offline checks

Five selected scripts completed successfully: slot ownership, worktree settling, pooled-copy freshness, endpoint safety, and bootstrap.
The first baseline used TMPDIR inside the source worktree; two suites stopped at existing safety guards that forbid removing secondmate or worktree fixtures inside the Firstmate repository.
Rerunning only those two suites with the default temporary directory passed.
The initial live relaunch driver expected a different duplicate-record message; the product correctly refused, and the corrected assertion passed on rerun.

Logs: [baseline](targeted-tests.log), [slot ownership rerun](slot-ownership-rerun.log), [endpoint safety rerun](endpoint-safety-rerun.log).

## Live limits

- Full acquire / exit / relaunch / conditional return remains untested live under the accepted offline Treehouse boundary; mocked executable regressions passed.
- Real interrupted and unrecognized-copy acquisitions remain untested live under the same boundary; recovery-journal and publication guards passed with mocked Treehouse.
- Live descendant-home teardown needs a disposable home outside this worktree because the product refuses removal targets inside the Firstmate source repository; the workspace boundary does not permit creating that live home here. The direct missing-copy recovery path passed live, and both direct and descendant paths passed the mocked regression.

All private tmux servers and disposable lab homes were removed. No source or test files were changed.
