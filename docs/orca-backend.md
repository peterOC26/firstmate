# Orca runtime backend

Orca is an experimental backend in which the Orca app owns both the task worktree and terminal endpoint.
Firstmate itself runs on macOS, and by default a task is placed on that same machine; a project that lives on a remote Orca host can be targeted explicitly, in which case the worktree and the agent process are on that host and only the CLI runs locally.
The crewmate harness remains the agent process launched inside that endpoint.
Firstmate agents load [`firstmate-orca`](../.agents/skills/firstmate-orca/SKILL.md) before operating or recovering this backend.

## Setup

Pick Orca when you already use the Orca macOS app and want Orca-managed worktrees and terminals instead of Treehouse plus a session multiplexer.
Firstmate runs Orca from macOS, selects it explicitly, and does not support secondmate spawns on it.

Prerequisites:

- `/Applications/Orca.app` installed, running, and ready.
- The `orca` CLI, installed with `brew install orca`.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

Select Orca with local `config/backend` containing `orca`, `FM_BACKEND=orca` for one launch, or an explicit request to Firstmate.
It is never auto-detected.

Before any spawn mutates repository state, Firstmate requires `orca status --json` to report `reachable=true` and `state="ready"`.
The first task for a project registers that repository with `orca repo add --path` when needed.
No manual repository registration is required.

Open the Orca app to watch a task's terminal.
Routine supervision uses the recorded endpoint through `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'`.
Enter and Ctrl-C are supported; Escape is not.

## Task shape and metadata

Each task has one Orca-managed git worktree and one Orca terminal.
`fm-spawn.sh` does not call Treehouse for Orca tasks.
The normal isolation and unlanded-work refusal rules still apply.

```text
backend=orca
window=fm-<id>
terminal=<orca terminal handle>
orca_worktree_id=<orca worktree id>
worktree=<absolute Orca worktree path>
orca_host=<orca host id>                        # only for an orca: selector spawn
orca_project_host_setup=<project host setup id> # only for an orca: selector spawn
orca_remote=1                                   # only when the host is not local
orca_remote_tasktmp=<path on host>              # only when the host is not local
```

`window=` remains the caller-facing Firstmate alias.
`terminal=` and `orca_worktree_id=` are the backend authority used by operation and cleanup paths.
`orca_host=` and `orca_project_host_setup=` record which host the task was placed on, so recovery and cleanup read that from the task's own record instead of re-deriving it from a path.
A spawn writes them whenever it named an `orca:` selector, a `local` host included; a spawn that named a plain project directory is on this machine by construction and records neither.
`orca_remote=1` is what tells every later step that the recorded paths are not on this machine.

## Current lifecycle and safety

Spawn registers the repository, creates an independent worktree, reuses only the verified `result.terminal.handle` returned by Orca or creates a terminal explicitly, installs harness hooks, records metadata, and launches the selected harness.
Exact command flags and response parsing are owned by `bin/backends/orca.sh` and script help.

`fm-peek.sh` reads with `orca terminal read`.
`fm-send.sh` types and verifies composer clearance, follows `oldestCursor` when Orca returns a limited page, and retries Enter without retyping when a slash popup first fills an argument placeholder.
A bare shell row is `unknown`, not an empty agent composer.
The watcher has no native Orca busy signal, so each harness adapter's semantic lifecycle supplies worker state.
Grok alone retains its isolated rendered-tail fallback.

Cleanup keeps all shared Firstmate safety checks.
A scout still requires its report and completed decision inventory.
A ship still refuses dirty or unlanded work.
Before release, cleanup resolves the recorded Orca worktree id and verifies its path matches the recorded worktree path.
A missing, unreadable, or mismatched identity preserves metadata and stops rather than deleting anything.
After those checks, Firstmate closes the exact terminal and releases the exact worktree with Orca's worktree command.
It never raw-deletes an Orca worktree.

## Active limits

- Firstmate drives Orca from macOS and selects it explicitly.
- The app must be running and report ready.
- Secondmate spawns are unsupported.
- Escape is unsupported.
- Orca exposes no stable CLI version or protocol marker, so readiness is the compatibility gate rather than a version floor.
- Only the verified terminal-handle and worktree result fields are accepted; speculative response shapes are rejected.
- Remote hosts carry the further limits in "Remote Orca hosts" below.

## Remote Orca hosts

One Orca runtime can be federated with others, so a single local `orca` CLI addresses projects on remote hosts as well as local ones.
Firstmate uses that to place a task where its project already lives, which is the point for a project whose source of truth is a server rather than this Mac.

Target a remote project by passing an explicit selector in place of `<project-dir>`:

```sh
bin/fm-spawn.sh <id> orca:setup:<project-host-setup-id> --backend orca ...
bin/fm-spawn.sh <id> orca:project:<project-id> --backend orca ...
```

`orca project setups` lists both ids.
The selector is required and never inferred: a plain path that happens not to exist locally still fails as a bad path, so a typo or an unmounted disk can never be read as a request for a remote host.
A selector requires `--backend orca`, must resolve to exactly one setup whose state is `ready`, and refuses when it matches none or several.
A selector naming a `local` host resolves to that setup's directory and behaves exactly like passing the path.

A remote host needs the chosen harness installed, `git` for the task's own worktree, `base64` for the reply transport below, and `sha256sum` or `shasum` for the digest-verified copies.
The per-backend toolchain check in [`configuration.md`](configuration.md#toolchain) inspects this machine only, so a tool missing on the host shows up as a spawn refusal from that host rather than as a bootstrap warning.

Placement is verified rather than requested.
The worktree is created with `--project-host-setup`, then the created worktree's own host and non-primary status, and the terminal's execution host, are each checked against the requested host.
Any mismatch removes what was created and refuses, because a task that quietly landed on this Mac would defeat the whole point of targeting the host.

The isolation assertion, the dirty and unlanded-work checks, and the recorded-identity check all still run; they run on the host, through a throwaway Orca shell terminal there, and every comparison is made on that host so terminal rendering cannot flip a verdict.
A check that cannot be obtained refuses and preserves the task: a path that is merely absent from this machine is never read as "nothing to protect".

That last guarantee extends to how a remote answer is read back.
A terminal is a bounded scrollback, not a pipe: a reply longer than the host retains loses its start while its trailing exit status survives, which would otherwise read as "succeeded, printed nothing" - and to the work-protection checks, as "nothing to protect".
Raising the read limit does not fix that, because the limit is not the constraint; measured against a live host, an 8,192,000-row request still returned only about 6 KB of a 145 KB reply, with no truncation flag set.
Every reply is therefore length-declared and length-verified: the command's output is staged in a file on the host, its exact length returns with the exit status, short replies ride inline, and longer ones are fetched in bounded slices and reassembled.
A reply that still cannot be recovered whole is reported as a transport failure, which refuses.
An empty answer is never itself the failure signal, so a check that genuinely finds nothing still succeeds.
The stage directory is named from the caller's own per-invocation nonce and created on the host with an atomic fail-if-exists `mkdir -m 700`, so a stale or hostile directory at that path is refused rather than adopted, and every transport failure - including one where the reply itself never arrives to name it - can still sweep the stage back off the host.

The landed-work half of the cleanup check asks the host too, so a remote task whose work has already landed can be released normally rather than only through `--force`.
Its two forge lookups stay on this machine, since they query GitHub rather than a filesystem.
For a REMOTE task they name the repository explicitly - forge host included, so an enterprise origin works the same as a github.com one - because there is no worktree here for gh to resolve one from.
An origin that names no resolvable forge host, such as an ssh alias that resolves through ssh config, is not guessed at: the PR lookup reports no match and cleanup falls back to the content check, exactly as it does for any other lookup failure.
A local task is untouched by that: it still asks gh from inside its own worktree, so gh's own base-repository resolution - a fork whose pull requests live on the parent, or a `gh repo set-default` - keeps deciding which repository the lookup is about.
Cleanup additionally proves the worktree Orca would remove still sits on the recorded host.
A forced secondmate teardown proves the same thing for each remote crew child it releases, reading the host and the recorded path from that child's own metadata: this machine cannot see a path that belongs to another host, so "absent here" is never taken as permission to remove it.
It also sweeps that child's own `/tmp/fm-<child-id>` on the host before deleting the record, since that record is the only thing that knows the path.
For an http or https origin the repository named in the PR lookup keeps the port, which is the forge's own endpoint; under `ssh://`, `git://`, or the scp-like form the colon carries a transport port or the path separator and is dropped.

Instructions reach the worker by copying the brief and the operational-input encoder to `/tmp/fm-<id>/` on the host and verifying both by digest, after which the ordinary launch line reads them from there.
That directory is created `0700` before anything is written into it: unlike a local spawn, whose brief stays under the firstmate home, it sits in the host's shared `/tmp`, and the brief is the task's whole instruction set.
That route was chosen over Orca's own `--agent`/`--prompt` because Firstmate must keep control of the harness, model, effort, and encoded launch brief, and over SSH because it needs no transport or credentials beyond the Orca connection the backend already depends on.
The delivered brief carries a short addendum telling the worker its status-log path is unreachable from that host and to report in its terminal instead.
A spawn that refuses after that copy sweeps `/tmp/fm-<id>` back off the host, reopening an inspection shell when it has already closed its own, since a refused spawn records no metadata for cleanup to work from later.
That sweep is best effort: a host that cannot be reached is named on stderr with the path to remove by hand, and the abort still completes.

The harness is resolved to an absolute path on the host and launched by that path, never by bare name.
A remote host can have an agent installed somewhere its shells leave off `PATH`, and a launch line that trusted `PATH` would leave a terminal sitting at a prompt looking like a worker that has not started yet.
An unresolvable harness refuses and reports the `PATH` the host actually had.
Resolution asks the task's own shell first and then a login shell; a host whose login profile prints a banner answers with that banner alongside the path, so the resolved path is taken from the reply rather than the whole reply being read as "not installed".
A line beginning with `/` only nominates a candidate: each one is proven on the host to be an executable that is not a directory before it is accepted, so a profile that prints a path-shaped line can never stand in for an agent the host does not have.

### Remote limits

- Turn-end and busy-state hooks are not installed.
  They write into the task worktree and point at absolute paths in this firstmate home, and neither exists on another host.
  A remote task is therefore supervised by reading its pane (`bin/fm-peek.sh`, `bin/fm-crew-state.sh`) rather than by waiting for turn-end wakes, and the spawn says so out loud.
- For the same reason the worker cannot append to `state/<id>.status`; it reports in its terminal instead.
- `pi`, `pi-signed`, `muse`, and `kimi` are refused: each needs an extension file, harness store, or post-launch handshake that only exists in this firstmate home.
  `codex` re-resolves onto its verified hook-free launch form.
- No local no-mistakes run is attributed to a remote task, and cleanup skips the local process reap, because neither has anything on this machine.
- Secondmate spawns remain unsupported, on remote hosts as on local ones.
- Steering delivers, but `bin/fm-send.sh` reports its delivery verdict from the Orca composer classifier, which has no verified idle pattern for `codex`; a `codex` worker receives the steer while the command still reports it unconfirmed.
  That is a pre-existing gap in the Orca composer contract, identical for local and remote tasks.
- Every remote command is bounded by a poll budget, and exceeding it is a transport failure that refuses rather than a silent pass.
  Verdict checks use `FM_BACKEND_ORCA_EXEC_POLLS` (120) x `FM_BACKEND_ORCA_EXEC_INTERVAL` (0.5s), which is also how quickly a genuinely dead host is noticed, so it is deliberately short.
  Network-bound git commands (`fetch`, `pull`, `push`, `clone`, `ls-remote`) get their own budget instead, `FM_BACKEND_ORCA_EXEC_FETCH_POLLS` (1200 polls, about 10 minutes), because they are bounded by the host's link to its forge rather than by the host being alive.
  Raise `FM_BACKEND_ORCA_EXEC_FETCH_POLLS` when a slow host fetch makes cleanup refuse a task whose work has landed; raising `FM_BACKEND_ORCA_EXEC_POLLS` is not the knob for that and only slows dead-host detection.
  The best-effort sweep that takes a staged reply back off the host keeps its own short bound, `FM_BACKEND_ORCA_EXEC_SWEEP_POLLS` (20), rather than the budget of the call it is cleaning up after: it runs only once that call has already given up, so waiting a network-sized budget again would just delay the refusal that is already decided.
- `--force` on a host that is genuinely gone still completes: Orca's own records answer from here, so the recorded host and the exact recorded path are still proven, and only the on-host path canonicalization is skipped, with a line saying so.
  A worktree Orca reports at a different path than the task recorded is still refused, `--force` or not.

## Regression entry points

```sh
tests/fm-backend-orca.test.sh
tests/fm-backend.test.sh
tests/fm-bootstrap.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#orca) records the real readiness and response-shape smoke.
