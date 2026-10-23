#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EV=/home/zabi/.no-mistakes/evidence/01M5MJPW8RN2VW0AFEACSQK5GC
. "$ROOT/tests/git-config-helpers.sh"
export GIT_AUTHOR_NAME=Lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=Lab GIT_COMMITTER_EMAIL=lab@example.invalid
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM FM_TASK_ID TMUX HERDR_ENV HERDR_SESSION
export TREEHOUSE_ROOT="$ROOT/.l/pool" TMPDIR="$ROOT/.l" TMUX_TMPDIR="$ROOT/.l"
export FM_HOME="$ROOT/.l/h"
RUNNING_PID=
cleanup() {
  [ -z "$RUNNING_PID" ] || kill "$RUNNING_PID" 2>/dev/null || true
  tmux -L fm-lab kill-server 2>/dev/null || true
  python3 - "$ROOT/.l" <<'PYCLEAN'
from pathlib import Path
import shutil,sys
p=Path(sys.argv[1])
assert p.name == '.l' and p.parent == Path.cwd()
for d in p.rglob('*'):
    if d.is_dir() and not d.is_symlink(): d.chmod(d.stat().st_mode | 0o700)
shutil.rmtree(p)
PYCLEAN
}
trap cleanup EXIT
bash "$ROOT/bin/fm-lab-home.sh" create "$FM_HOME"
bash "$ROOT/bin/fm-lab-home.sh" create "$ROOT/.l/n"
bash "$ROOT/bin/fm-lab-home.sh" create "$ROOT/.l/child"
PROJECT="$ROOT/.l/project"
# Enlarge only this fixture's pool limit; this uncommitted config is in its primary checkout.
printf 'max_trees = 5\nroot = ""\n' > "$PROJECT/treehouse.toml"
S1=$(jq -r .path "$ROOT/.l/allocation-1.json")
S2=$(jq -r .path "$ROOT/.l/allocation-2.json")
S3=$(jq -r .path "$ROOT/.l/allocation-3.json")
POOLSTATE="$(dirname "$(dirname "$S1")")/treehouse-state.json"
snapshot() {
  for s in "$S1" "$S2" "$S3"; do
    printf 'COPY=%s\nBRANCH=%s\nHEAD=%s\n' "$s" "$(git -C "$s" symbolic-ref --short -q HEAD || echo detached)" "$(git -C "$s" rev-parse HEAD)"
    git -C "$s" status --porcelain
    [ ! -f "$s/unfinished.txt" ] || sha256sum "$s/unfinished.txt"
    cat "$(dirname "$s")/.fm-slot-owner"
    jq -c --arg p "$s" '.worktrees[] | select(.path==$p) | {path,leased,lease_id,lease_holder}' "$POOLSTATE"
  done
}
brief() {
  local home=$1 id=$2 kind=$3
  [ ! -f "$home/data/$id/brief.md" ] || return 0
  if [ "$kind" = scout ]; then
    FM_HOME="$home" bash "$ROOT/bin/fm-brief.sh" "$id" project --scout >/dev/null
  else
    FM_HOME="$home" bash "$ROOT/bin/fm-brief.sh" "$id" project --mode local-only --project "$PROJECT" >/dev/null
  fi
  python3 - "$home/data/$id/brief.md" <<'PYBRIEF'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); p.write_text(p.read_text().replace('{TASK}', 'Exercise a disposable allocation probe and wait.').replace('{FIRSTMATE_SPEC}', 'This lab uses a supervised raw shell process to verify allocation and preservation; no model task or publication is required.'))
PYBRIEF
}
spawn() {
  local home=$1 id=$2 kind=$3
  shift 3
  brief "$home" "$id" "$kind"
  if [ "$kind" = scout ]; then
    FM_HOME="$home" bash "$ROOT/bin/fm-spawn.sh" "$id" "$PROJECT" --scout --backend tmux "bash -c 'echo ALLOCATION_WORKER_READY; exec sleep 600'" "$@"
  else
    FM_HOME="$home" bash "$ROOT/bin/fm-spawn.sh" "$id" "$PROJECT" --mode local-only --yolo off --backend tmux "bash -c 'echo ALLOCATION_WORKER_READY; exec sleep 600'" "$@"
  fi
}
# A real tmux session gives every spawned process a 120x40 terminal.
tmux -L fm-lab new-session -d -s primary -x 120 -y 40 -c "$ROOT"
export TMUX="$(tmux -L fm-lab display-message -p '#{socket_path},#{pid}'),0"
printf 'REAL_TOOLS treehouse=%s tmux=%s\n' "$(treehouse --version)" "$(tmux -V)"
# Seed pre-update persisted records and claims, with no durable lease fields.
git -C "$S1" checkout -qb fm/legacy-paused
git -C "$S2" checkout -qb fm/legacy-dirty
git -C "$S3" checkout -qb fm/legacy-running
printf 'unfinished work from before the update\n' > "$S2/unfinished.txt"
for n in 1 2 3; do
  eval 's=$S'"$n"
  home=$FM_HOME
  [ "$n" != 2 ] || home="$ROOT/.l/child"
  printf 'task=legacy%s\nhome=%s\n' "$n" "$home" > "$(dirname "$s")/.fm-slot-owner"
  printf 'project=%s\nworktree=%s\nkind=ship\nstatus=paused\n' "$PROJECT" "$s" > "$home/state/legacy$n.meta"
done
printf -- '- child - fixture (home: %s; scope: test; projects: project; added 2026-10-23)\n' "$ROOT/.l/child" > "$FM_HOME/data/secondmates.md"
ln -s "$S1" "$ROOT/.l/alias"
printf 'project=%s\nworktree=%s\nkind=scout\n' "$PROJECT" "$ROOT/.l/alias" > "$FM_HOME/state/alias.meta"
(cd "$S3"; exec bash -c 'while :; do date +%s%N > "$1"; sleep 0.2; done' _ "$FM_HOME/state/heartbeat") &
RUNNING_PID=$!
sleep 0.4
snapshot > "$EV/legacy-before.txt"
cp "$FM_HOME/state/legacy1.meta" "$ROOT/.l/legacy1.meta.before"
cp "$ROOT/.l/child/state/legacy2.meta" "$ROOT/.l/legacy2.meta.before"
# Give the unrelated empty home its own project and pool identity.
MAIN_PROJECT=$PROJECT
git clone -q --bare "$ROOT/.l/seed" "$ROOT/.l/n-origin.git"
git clone -q "$ROOT/.l/n-origin.git" "$ROOT/.l/n-project"
PROJECT="$ROOT/.l/n-project"
printf 'max_trees = 2\nroot = ""\n' > "$PROJECT/treehouse.toml"
# A fresh home has no legacy records; FIFO failure must be irrelevant.
mkfifo() { echo 'INJECTED_FIFO_FAILURE' >&2; return 1; }
export -f mkfifo
spawn "$ROOT/.l/n" empty-home scout > "$EV/no-legacy-first.txt" 2>&1
spawn "$ROOT/.l/n" durable-only scout > "$EV/no-legacy-second.txt" 2>&1
unset -f mkfifo
PROJECT=$MAIN_PROJECT
printf 'NO_LEGACY first=%s second=%s; both have durable lease identities\n' "$(sed -n 's/^worktree=//p' "$ROOT/.l/n/state/empty-home.meta")" "$(sed -n 's/^worktree=//p' "$ROOT/.l/n/state/durable-only.meta")"
grep '^treehouse_lease_' "$ROOT/.l/n/state/empty-home.meta" "$ROOT/.l/n/state/durable-only.meta"
# Legacy hold refusal must remove only the journal whose get never ran.
mkfifo() { echo 'INJECTED_FIFO_FAILURE' >&2; return 1; }
export -f mkfifo
if spawn "$FM_HOME" hold-failed scout > "$EV/hold-refusal.txt" 2>&1; then echo 'FAIL expected hold refusal'; exit 1; fi
unset -f mkfifo
[ ! -e "$FM_HOME/state/hold-failed.treehouse-acquire" ]
printf 'HOLD_REFUSAL journal_absent=true\n'
cat "$EV/hold-refusal.txt"
BEAT_BEFORE=$(cat "$FM_HOME/state/heartbeat")
spawn "$FM_HOME" retry scout > "$EV/fresh-scout.txt" 2>&1
spawn "$FM_HOME" ship ship > "$EV/fresh-ship.txt" 2>&1
BEAT_AFTER=$(cat "$FM_HOME/state/heartbeat")
kill -0 "$RUNNING_PID"
[ "$BEAT_BEFORE" != "$BEAT_AFTER" ]
for id in retry ship; do
  wt=$(sed -n 's/^worktree=//p' "$FM_HOME/state/$id.meta")
  [ "$wt" != "$S1" ] && [ "$wt" != "$S2" ] && [ "$wt" != "$S3" ]
  grep '^treehouse_lease_' "$FM_HOME/state/$id.meta"
  jq -e --arg p "$wt" '.worktrees[] | select(.path==$p) | .leased==true' "$POOLSTATE" >/dev/null
  tmux -L fm-lab capture-pane -p -t "primary:fm-$id" > "$EV/$id-pane.txt"
  grep -q '^ALLOCATION_WORKER_READY$' "$EV/$id-pane.txt"
  printf 'FRESH_%s allocated=%s ready=true\n' "$id" "$wt"
done
snapshot > "$EV/legacy-after.txt"
cmp "$EV/legacy-before.txt" "$EV/legacy-after.txt"
cmp "$ROOT/.l/legacy1.meta.before" "$FM_HOME/state/legacy1.meta"
cmp "$ROOT/.l/legacy2.meta.before" "$ROOT/.l/child/state/legacy2.meta"
printf 'PRESERVATION branches_heads_dirty_bytes_claims_pool_entries_records=unchanged running_pid=%s heartbeat_advanced=true\n' "$RUNNING_PID"
# All five slots are now protected by old records or new leases.
if spawn "$FM_HOME" exhausted scout > "$EV/exhausted.txt" 2>&1; then echo 'FAIL expected exhausted refusal'; exit 1; fi
[ ! -e "$FM_HOME/state/exhausted.meta" ]
[ -f "$FM_HOME/state/exhausted.treehouse-acquire/allocation.json" ]
snapshot > "$EV/legacy-exhausted.txt"
cmp "$EV/legacy-before.txt" "$EV/legacy-exhausted.txt"
printf 'EXHAUSTED no_worker_published=true acquisition_journal_retained=true legacy_copies_unchanged=true\n'
cat "$EV/exhausted.txt"
cp "$POOLSTATE" "$EV/pool-final.json"
printf 'LIVE_SCENARIOS_COMPLETE\n'
