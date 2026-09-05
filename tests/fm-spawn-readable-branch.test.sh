#!/usr/bin/env bash
# Regression tests for fm-spawn.sh naming a fresh ship/scout worktree fm/<id>
# before the worker starts, and fm-brief.sh's matching first-action step.
#
# ccmux and similar session lists render "project:branch"; a worktree left at
# detached HEAD reads as an unhelpful "HEAD+". fm-spawn.sh now puts a fresh
# ship or scout worktree on branch fm/<id> - never pushed, never forced -
# before it sends any launch text, and fm-brief.sh's first-action step is
# worded so a spawn that already created the branch makes it a no-op.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-readable-branch)
REAL_GIT_FOR_TEST=$(command -v git)
export REAL_GIT_FOR_TEST

# A git wrapper that logs every invocation (one line per call, in real
# invocation order) to $FM_TEST_EVENTS_LOG before delegating to real git, so a
# test can prove what happened and in what order without guessing from
# side effects alone. ensure_spawn_task_branch is the only place in
# fm-spawn.sh that calls `git ... checkout`, so a logged "checkout" line can
# only come from it.
make_logging_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_test_fake_tmux_spawn "$fakebin"
  fm_fake_exit0 "$fakebin" treehouse
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
if [ -n "${FM_TEST_EVENTS_LOG:-}" ]; then
  printf 'GIT %s\n' "$*" >> "$FM_TEST_EVENTS_LOG"
fi
exec "$real" "$@"
SH
  chmod +x "$fakebin/git"
  # Overlay send-keys so every line/literal sent to the pane is also logged,
  # in the same file and the same real order as the git calls above.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  send-keys)
    shift
    if [ "${1:-}" = "-t" ]; then shift 2; fi
    if [ -n "${FM_TEST_EVENTS_LOG:-}" ]; then
      printf 'TMUX %s\n' "${1:-}" >> "$FM_TEST_EVENTS_LOG"
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# make_case <name> <id>: a project, a bare origin, and a pooled worktree
# detached at origin's tip - the same shape a treehouse pool hands fm-spawn.sh.
make_case() {
  local name=$1 id=$2 case_dir home project origin pool fakebin initial
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  pool="$case_dir/pool"
  fakebin=$(make_logging_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$pool" "$initial"

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local id=$1
  shift
  FM_TEST_EVENTS_LOG="$CASE_DIR/events.log" \
    fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" "$@"
}

test_ship_spawn_creates_branch_before_launch() {
  local rec id out status branch checkout_line gotmp_line
  id='readable-branch-ship-r1'
  rec=$(make_case ship-spawn "$id")
  read_case_record "$rec"
  : > "$CASE_DIR/events.log"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "ship spawn should succeed"
  assert_contains "$out" "spawned $id" "spawn did not report success"

  branch=$(git -C "$POOL_DIR" symbolic-ref --quiet --short HEAD)
  [ "$branch" = "fm/$id" ] || fail "spawn left the worktree on '$branch', not fm/$id"

  assert_grep "GIT -C $POOL_DIR checkout --quiet -b fm/$id" "$CASE_DIR/events.log" \
    "spawn did not create the fm/$id branch"
  checkout_line=$(grep -n -F "GIT -C $POOL_DIR checkout --quiet -b fm/$id" "$CASE_DIR/events.log" | head -1 | cut -d: -f1)
  gotmp_line=$(grep -n -F "TMUX export GOTMPDIR=/tmp/fm-$id/gotmp" "$CASE_DIR/events.log" | head -1 | cut -d: -f1)
  [ -n "$checkout_line" ] && [ -n "$gotmp_line" ] \
    || fail "could not locate both the branch checkout and the GOTMPDIR export in the event log"
  [ "$checkout_line" -lt "$gotmp_line" ] \
    || fail "branch was created at line $checkout_line, not before GOTMPDIR export at line $gotmp_line (which precedes the worker launch)"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed order: checkout at line %s, GOTMPDIR export (pre-launch) at line %s\n' "$checkout_line" "$gotmp_line"
  fi
  pass "fm-spawn: a fresh ship worktree is put on fm/<id> before the worker's launch text is sent"
}

test_scout_spawn_creates_branch_before_launch() {
  local rec id out status branch
  id='readable-branch-scout-r2'
  rec=$(make_case scout-spawn "$id")
  read_case_record "$rec"
  : > "$CASE_DIR/events.log"

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "scout spawn should succeed"
  assert_contains "$out" "spawned $id" "scout spawn did not report success"

  branch=$(git -C "$POOL_DIR" symbolic-ref --quiet --short HEAD)
  [ "$branch" = "fm/$id" ] || fail "scout spawn left the worktree on '$branch', not fm/$id"
  assert_grep "GIT -C $POOL_DIR checkout --quiet -b fm/$id" "$CASE_DIR/events.log" \
    "scout spawn did not create the fm/$id branch"
  pass "fm-spawn: a fresh scout worktree also lands on fm/<id>, not a detached HEAD"
}

test_already_named_worktree_is_left_alone() {
  local rec id out status before_head after_head
  id='readable-branch-idem-r3'
  rec=$(make_case idem-spawn "$id")
  read_case_record "$rec"
  # Simulate a worktree that already carries this task's branch (e.g. a
  # recovered slot): put it there before spawn ever runs.
  git -C "$POOL_DIR" checkout --quiet -b "fm/$id"
  before_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  : > "$CASE_DIR/events.log"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should succeed when the worktree is already on fm/$id"
  assert_contains "$out" "spawned $id" "spawn did not report success"

  after_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$after_head" = "$before_head" ] \
    || fail "an already-named worktree's history changed (expected only the unrelated origin-freshen fast-forward, if any, not a branch switch)"
  [ "$(git -C "$POOL_DIR" symbolic-ref --quiet --short HEAD)" = "fm/$id" ] \
    || fail "spawn moved an already-named worktree off its branch"
  assert_no_grep "checkout --quiet -b fm/$id" "$CASE_DIR/events.log" \
    "spawn re-created a branch that already existed and was already checked out"
  assert_no_grep "checkout --quiet fm/$id" "$CASE_DIR/events.log" \
    "spawn switched branches on a worktree that was already on the right one"
  pass "fm-spawn: a worktree already on fm/<id> is left alone, not re-checked-out"
}

test_scout_brief_includes_the_branch_step() {
  local home id brief
  home="$TMP_ROOT/scout-brief-home"
  id='readable-branch-brief-r4'
  mkdir -p "$home/data" "$home/state"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" alpha --scout >/dev/null 2>&1 \
    || fail "scout brief scaffold should succeed"
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_grep "git checkout fm/$id 2>/dev/null || git checkout -b fm/$id" "$brief" \
    "scout brief is missing the idempotent branch-confirmation step ships already have"
  assert_grep "a no-op if fm-spawn already created it" "$brief" \
    "scout brief does not say the branch step is a no-op when fm-spawn already ran it"
  pass "fm-brief.sh: a scout brief now carries the same first-action branch step as a ship brief"
}

test_ship_brief_branch_step_is_idempotent() {
  local home id brief
  home="$TMP_ROOT/ship-brief-home"
  id='readable-branch-ship-brief-r5'
  mkdir -p "$home/data" "$home/state"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" alpha --mode no-mistakes >/dev/null 2>&1 \
    || fail "ship brief scaffold should succeed"
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "ship brief was not scaffolded"
  assert_grep "git checkout fm/$id 2>/dev/null || git checkout -b fm/$id" "$brief" \
    "ship brief's first action is no longer worded to be a no-op when fm-spawn already created the branch"
  assert_no_grep "at a detached HEAD" "$brief" \
    "ship brief still claims the worker starts detached, but fm-spawn now puts it on fm/<id> first"
  pass "fm-brief.sh: a ship brief's first action is a no-op when fm-spawn already created the branch"
}

test_ship_spawn_creates_branch_before_launch
test_scout_spawn_creates_branch_before_launch
test_already_named_worktree_is_left_alone
test_scout_brief_includes_the_branch_step
test_ship_brief_branch_step_is_idempotent

echo "# all fm-spawn-readable-branch tests passed"
