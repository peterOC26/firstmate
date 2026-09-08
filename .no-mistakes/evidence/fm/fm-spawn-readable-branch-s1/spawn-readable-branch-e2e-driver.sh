#!/usr/bin/env bash
# End-to-end demonstration of "ship and scout workers show a readable git name
# as soon as they launch". Drives the real bin/fm-spawn.sh against a real git
# project + bare origin + pooled worktree (the shape treehouse hands it), with
# only the terminal multiplexer and the pool provider stubbed out.
#
# Reproduce (produces spawn-readable-branch-e2e.txt):
#   mkdir -p /tmp/fm-demo/base /tmp/fm-demo/sandbox
#   git archive d08be9eeca8b18bf22f1acedf1f1e547e696778b | tar -x -C /tmp/fm-demo/base
#   TARGET_ROOT=<this worktree> BASE_ROOT=/tmp/fm-demo/base SANDBOX=/tmp/fm-demo/sandbox \
#     bash spawn-readable-branch-e2e-driver.sh
set -u

# This demo is run from inside a no-mistakes gate agent; use the same test-harness
# escape hatch tests/lib.sh uses so fm-spawn.sh is not refused as a gate driver.
export FM_GATE_REFUSE_BYPASS=1

TARGET_ROOT=${TARGET_ROOT:?}          # worktree under test
BASE_ROOT=${BASE_ROOT:?}              # pre-change tree, for the "before" panel
SANDBOX=${SANDBOX:?}

hr() { printf '\n%s\n' "------------------------------------------------------------------"; }
say() { printf '%s\n' "$*"; }
run() { printf '\n$ %s\n' "$*"; eval "$*" 2>&1 | sed 's/^/  /'; }

make_case() {  # <name> <id>  -> exports CASE HOME PROJECT ORIGIN POOL FAKEBIN
  local name=$1 id=$2 tip
  CASE="$SANDBOX/$name"; HOME_DIR="$CASE/home"; PROJECT="$CASE/project"
  ORIGIN="$CASE/origin.git"; POOL="$CASE/pool-slot-1"; FAKEBIN="$CASE/fakebin"
  mkdir -p "$HOME_DIR/data/$id" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config" "$FAKEBIN"
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  touch "$HOME_DIR/state/.last-watcher-beat"

  git init --quiet -b main "$PROJECT"
  printf 'base\n' > "$PROJECT/README.md"
  git -C "$PROJECT" add README.md
  git -C "$PROJECT" -c user.name=Demo -c user.email=demo@example.invalid commit -qm initial
  git clone --quiet --bare "$PROJECT" "$ORIGIN"
  git -C "$PROJECT" remote add origin "file://$ORIGIN"
  tip=$(git -C "$PROJECT" rev-parse HEAD)
  git -C "$PROJECT" worktree add --quiet --detach "$POOL" "$tip"

  # Stubs: a tmux that accepts every window/send-keys call, and a treehouse
  # (pool provider) that is already satisfied. Nothing about git is stubbed.
  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u

# This demo is run from inside a no-mistakes gate agent; use the same test-harness
# escape hatch tests/lib.sh uses so fm-spawn.sh is not refused as a gate driver.
export FM_GATE_REFUSE_BYPASS=1
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; esac
exit 0
SH
  cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$FAKEBIN/tmux" "$FAKEBIN/treehouse"
}

spawn() {  # <root> <id> [args...]
  local root=$1 id=$2; shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$POOL" TMUX=fake,1,0 \
    PATH="$FAKEBIN:$PATH" \
    "$root/bin/fm-spawn.sh" "$id" "$PROJECT" "$@" 2>&1
}

worker_view() {  # what a session list / the worker's own shell sees
  printf '  worktree HEAD .......... %s\n' \
    "$(git -C "$POOL" status --short --branch | head -1)"
  printf '  git branch --show-current : %s\n' \
    "$(git -C "$POOL" branch --show-current 2>/dev/null || true)"
  printf '  session-list label ..... %s:%s\n' \
    "$(basename "$PROJECT")" "$(git -C "$POOL" branch --show-current 2>/dev/null || echo 'HEAD+')"
}

################################################################################
say "== 1. BEFORE the change: a fresh ship worker launches at a detached HEAD =="
make_case before-ship demo-ship-101
say "(running bin/fm-spawn.sh from base commit d08be9e)"
out=$(spawn "$BASE_ROOT" demo-ship-101 --mode no-mistakes --yolo off); rc=$?
printf '\n$ fm-spawn.sh demo-ship-101 <project> --mode no-mistakes --yolo off   -> exit %s\n' "$rc"
printf '%s\n' "$out" | sed 's/^/  /' | tail -3
say ""
say "What the worker (and any session list keyed on project:branch) sees:"
worker_view

hr
say "== 2. AFTER the change: the same spawn lands on fm/<id> before launch =="
make_case after-ship demo-ship-101
out=$(spawn "$TARGET_ROOT" demo-ship-101 --mode no-mistakes --yolo off); rc=$?
printf '\n$ fm-spawn.sh demo-ship-101 <project> --mode no-mistakes --yolo off   -> exit %s\n' "$rc"
printf '%s\n' "$out" | sed 's/^/  /' | tail -3
say ""
say "What the worker (and any session list keyed on project:branch) sees:"
worker_view
say ""
say "Nothing was pushed - origin still carries only its own branches:"
run "git -C '$ORIGIN' for-each-ref --format='%(refname:short)' refs/heads"

hr
say "== 3. A scout gets the same readable name (its branch stays local scratch) =="
make_case after-scout demo-scout-202
out=$(spawn "$TARGET_ROOT" demo-scout-202 --scout); rc=$?
printf '\n$ fm-spawn.sh demo-scout-202 <project> --scout   -> exit %s\n' "$rc"
printf '%s\n' "$out" | sed 's/^/  /' | tail -3
worker_view
run "git -C '$ORIGIN' for-each-ref --format='%(refname:short)' refs/heads"

hr
say "== 4. A secondmate is deliberately NOT renamed (persistent home, not a task) =="
make_case secondmate demo-mate-303
MATE="$CASE/mate-home"
mkdir -p "$MATE/bin" "$MATE/data"
printf '# Firstmate\n' > "$MATE/AGENTS.md"
printf 'demo-mate-303\n' > "$MATE/.fm-secondmate-home"
printf 'charter\n' > "$MATE/data/charter.md"
git init --quiet -b main "$MATE"
git -C "$MATE" add -A
git -C "$MATE" -c user.name=Demo -c user.email=demo@example.invalid commit -qm mate
out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$POOL" \
  TMUX=fake,1,0 PATH="$FAKEBIN:$PATH" \
  "$TARGET_ROOT/bin/fm-spawn.sh" demo-mate-303 "$MATE" --secondmate 2>&1); rc=$?
printf '\n$ fm-spawn.sh demo-mate-303 <mate-home> --secondmate   -> exit %s\n' "$rc"
printf '%s\n' "$out" | sed 's/^/  /' | tail -2
printf '\n  secondmate home branches: %s\n' \
  "$(git -C "$MATE" for-each-ref --format='%(refname:short)' refs/heads | tr '\n' ' ')"
printf '  fm/demo-mate-303 created? %s\n' \
  "$(git -C "$MATE" rev-parse --verify --quiet refs/heads/fm/demo-mate-303 >/dev/null 2>&1 && echo YES || echo 'no (correct)')"

hr
say "== 5. Refuses rather than destroys: a diverged leftover fm/<id> =="
make_case diverged demo-ship-404
git -C "$POOL" checkout --quiet -b fm/demo-ship-404
printf 'work only on the task branch\n' > "$POOL/leftover.txt"
git -C "$POOL" add leftover.txt
git -C "$POOL" -c user.name=Demo -c user.email=demo@example.invalid commit -qm 'leftover task work'
LEFTOVER_TIP=$(git -C "$POOL" rev-parse fm/demo-ship-404)
git -C "$POOL" checkout --quiet --detach main
# origin moves on independently, so fm/demo-ship-404 now diverges from the base
PUB="$CASE/publisher"
git clone --quiet "$ORIGIN" "$PUB"
printf 'published later\n' > "$PUB/later.txt"
git -C "$PUB" add later.txt
git -C "$PUB" -c user.name=Demo -c user.email=demo@example.invalid commit -qm 'origin moved on'
git -C "$PUB" push --quiet origin main
say "  leftover fm/demo-ship-404 tip : $LEFTOVER_TIP"
out=$(spawn "$TARGET_ROOT" demo-ship-404 --mode no-mistakes --yolo off); rc=$?
printf '\n$ fm-spawn.sh demo-ship-404 <project> --mode no-mistakes --yolo off   -> exit %s\n' "$rc"
printf '%s\n' "$out" | sed 's/^/  /'
printf '\n  fm/demo-ship-404 tip after the refusal : %s  (%s)\n' \
  "$(git -C "$POOL" rev-parse fm/demo-ship-404)" \
  "$([ "$(git -C "$POOL" rev-parse fm/demo-ship-404)" = "$LEFTOVER_TIP" ] && echo unchanged || echo MOVED)"
printf '  committed work still reachable        : %s\n' \
  "$(git -C "$POOL" show fm/demo-ship-404:leftover.txt 2>/dev/null || echo LOST)"
printf '  worker launched?                      : %s\n' \
  "$(printf '%s' "$out" | grep -q 'spawned demo-ship-404' && echo yes || echo 'no - refused before launch')"

hr
say "== 6. Freshening never rewinds a clean fm/<id> that is ahead of origin =="
make_case preserve demo-ship-505
git -C "$POOL" checkout --quiet -b fm/demo-ship-505
printf 'committed task work that must survive\n' > "$POOL/keep.txt"
git -C "$POOL" add keep.txt
git -C "$POOL" -c user.name=Demo -c user.email=demo@example.invalid commit -qm 'task work'
KEEP_TIP=$(git -C "$POOL" rev-parse HEAD)
out=$(spawn "$TARGET_ROOT" demo-ship-505 --mode no-mistakes --yolo off); rc=$?
printf '\n$ fm-spawn.sh demo-ship-505 <project> --mode no-mistakes --yolo off   -> exit %s\n' "$rc"
printf '%s\n' "$out" | sed 's/^/  /' | tail -3
printf '\n  fm/demo-ship-505 tip : %s  (%s)\n' "$(git -C "$POOL" rev-parse HEAD)" \
  "$([ "$(git -C "$POOL" rev-parse HEAD)" = "$KEEP_TIP" ] && echo 'preserved, not rewound' || echo REWOUND)"
printf '  keep.txt content     : %s\n' "$(cat "$POOL/keep.txt" 2>/dev/null || echo LOST)"
worker_view

hr
say "== 7. The brief the scout worker actually receives (generated prompt) =="
BRIEF_HOME="$SANDBOX/brief-home"
mkdir -p "$BRIEF_HOME/data" "$BRIEF_HOME/state"
FM_HOME="$BRIEF_HOME" "$TARGET_ROOT/bin/fm-brief.sh" demo-scout-202 alpha --scout >/dev/null 2>&1
say ""
say "--- data/demo-scout-202/brief.md (Setup section) ---"
sed -n '/^# Setup/,/^# Rules/p' "$BRIEF_HOME/data/demo-scout-202/brief.md" | sed 's/^/  /'

hr
say "== 8. Scout teardown is still scratch/discard: the named branch changes nothing =="
make_case scout-teardown demo-scout-606
out=$(spawn "$TARGET_ROOT" demo-scout-606 --scout); rc=$?
printf '\n$ fm-spawn.sh demo-scout-606 <project> --scout   -> exit %s\n' "$rc"
printf '%s\n' "$out" | sed 's/^/  /' | tail -1
printf '  scout worktree branch: %s\n' "$(git -C "$POOL" branch --show-current)"
# The scout does what a scout does: scratch commits on its own branch, never pushed.
printf 'scratch experiment\n' > "$POOL/scratch.txt"
git -C "$POOL" add scratch.txt
git -C "$POOL" -c user.name=Demo -c user.email=demo@example.invalid commit -qm 'scratch experiment'
printf '  unpushed scratch commits on fm/demo-scout-606: %s\n' \
  "$(git -C "$POOL" rev-list --count origin/main..HEAD)"
printf 'the report\n' > "$HOME_DIR/data/demo-scout-606/report.md"
# Satisfy the pre-existing scout completion gates (report present + captain-call
# inventory reviewed) so what is left under test is the branch, not those gates.
printf 'decisions_reviewed=1\n' >> "$HOME_DIR/state/demo-scout-606.meta"
out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_SPAWN_NO_GUARD=1 TMUX=fake,1,0 \
  PATH="$FAKEBIN:$PATH" "$TARGET_ROOT/bin/fm-teardown.sh" demo-scout-606 2>&1); rc=$?
printf '\n$ fm-teardown.sh demo-scout-606   -> exit %s\n' "$rc"
printf '%s\n' "$out" | sed 's/^/  /'
printf '\n  refused over unlanded work on the named branch? %s\n' \
  "$(printf '%s' "$out" | grep -q 'REFUSED' && echo 'YES - regression' || echo 'no (scout stays scratch/discard)')"
printf '  origin branches after scout teardown          : %s\n' \
  "$(git -C "$ORIGIN" for-each-ref --format='%(refname:short)' refs/heads | tr '\n' ' ')"
printf '  task record removed                           : %s\n' \
  "$([ -e "$HOME_DIR/state/demo-scout-606.meta" ] && echo 'no' || echo 'yes')"
printf '  report survives teardown                      : %s\n' \
  "$([ -f "$HOME_DIR/data/demo-scout-606/report.md" ] && echo yes || echo LOST)"
