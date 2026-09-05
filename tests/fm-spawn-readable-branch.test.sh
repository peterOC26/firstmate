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

# advance_origin <case_dir> <default>: publish one more commit to origin's
# default branch from a separate clone, so the base freshen_spawn_worktree_base
# establishes moves past whatever the pool (and any leftover branch) points at.
advance_origin() {
  local case_dir=$1 default=$2 publisher
  publisher="$case_dir/publisher"
  git clone --quiet "file://$case_dir/origin.git" "$publisher"
  printf 'origin moved on\n' > "$publisher/advanced.txt"
  git -C "$publisher" add advanced.txt
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm advance
  git -C "$publisher" push --quiet origin "$default"
}

test_stale_leftover_branch_is_refused_not_reused() {
  local rec id out status stale_tip fresh_tip
  id='readable-branch-stale-r6'
  rec=$(make_case stale-leftover "$id")
  read_case_record "$rec"
  # A leftover fm/<id> from an earlier spawn of the same id that died after
  # naming its slot: not checked out anywhere, pointing at a base origin has
  # since moved past. Reusing it would walk the worker back onto stale history.
  stale_tip=$(git -C "$PROJECT_DIR" rev-parse HEAD)
  git -C "$PROJECT_DIR" branch "fm/$id" "$stale_tip"
  advance_origin "$CASE_DIR" main
  : > "$CASE_DIR/events.log"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded by silently reusing a stale leftover fm/$id"
  assert_contains "$out" "branch 'fm/$id' already exists at $stale_tip" \
    "spawn did not name the leftover branch and tip it refused"
  assert_contains "$out" "refusing to move the worktree off its current base" \
    "spawn did not clearly refuse the stale leftover branch"
  fresh_tip=$(git -C "$POOL_DIR" rev-parse origin/main)
  [ "$fresh_tip" != "$stale_tip" ] || fail "fixture did not prove origin/main advanced past the leftover branch"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$fresh_tip" ] \
    || fail "spawn moved the worktree off its freshened base while refusing"
  [ -z "$(git -C "$POOL_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" ] \
    || fail "spawn attached the worktree to a branch despite refusing"
  [ "$(git -C "$POOL_DIR" rev-parse "refs/heads/fm/$id")" = "$stale_tip" ] \
    || fail "spawn moved or deleted the leftover fm/$id instead of leaving it for inspection"
  assert_no_grep "checkout" "$CASE_DIR/events.log" \
    "spawn ran a git checkout while refusing the stale leftover branch"
  assert_no_grep "TMUX export GOTMPDIR" "$CASE_DIR/events.log" \
    "spawn sent launch text to the pane despite refusing the branch"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed stale-leftover refusal: %s\n' "$(printf '%s\n' "$out" | grep -F "already exists at" | head -n 1)"
  fi
  pass "fm-spawn: a leftover fm/<id> behind the freshened base refuses the spawn instead of silently reusing it"
}

test_leftover_branch_at_freshened_base_is_reused() {
  local rec id out status tip
  id='readable-branch-reuse-r7'
  rec=$(make_case reuse-leftover "$id")
  read_case_record "$rec"
  # The same leftover, but origin never moved: fm/<id> already points at the
  # freshened base, so switching onto it changes no history and is allowed.
  tip=$(git -C "$PROJECT_DIR" rev-parse HEAD)
  git -C "$PROJECT_DIR" branch "fm/$id" "$tip"
  : > "$CASE_DIR/events.log"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should reuse an fm/$id that already sits at the freshened base"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  [ "$(git -C "$POOL_DIR" symbolic-ref --quiet --short HEAD)" = "fm/$id" ] \
    || fail "spawn did not switch the worktree onto the existing fm/$id"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$tip" ] \
    || fail "switching onto the existing fm/$id changed the worktree's history"
  assert_grep "GIT -C $POOL_DIR checkout --quiet fm/$id" "$CASE_DIR/events.log" \
    "spawn did not switch onto the existing branch"
  assert_no_grep "checkout --quiet -b fm/$id" "$CASE_DIR/events.log" \
    "spawn tried to re-create a branch that already existed"
  pass "fm-spawn: an existing fm/<id> already at the freshened base is switched onto, not refused or re-created"
}

test_fresh_spawn_reuses_branch_checked_out_in_another_worktree() {
  local rec id out status tip other retry_line gotmp_line
  id='readable-branch-other-worktree-r8'
  rec=$(make_case reuse-other-worktree "$id")
  read_case_record "$rec"
  tip=$(git -C "$PROJECT_DIR" rev-parse HEAD)
  other="$CASE_DIR/other-worktree"
  git -C "$PROJECT_DIR" worktree add --quiet -b "fm/$id" "$other" "$tip"
  : > "$CASE_DIR/events.log"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "fresh spawn should reuse fm/$id when another worktree already has it checked out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  [ "$(git -C "$POOL_DIR" symbolic-ref --quiet --short HEAD)" = "fm/$id" ] \
    || fail "fresh spawn did not attach its worktree to fm/$id"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$tip" ] \
    || fail "fresh spawn moved the shared branch away from the freshened base"
  [ "$(git -C "$other" symbolic-ref --quiet --short HEAD)" = "fm/$id" ] \
    || fail "fresh spawn disturbed the existing worktree using fm/$id"
  [ "$(git -C "$other" rev-parse HEAD)" = "$tip" ] \
    || fail "fresh spawn changed the existing worktree's checked-out commit"
  assert_grep "GIT -C $POOL_DIR checkout --quiet --ignore-other-worktrees fm/$id" "$CASE_DIR/events.log" \
    "spawn did not retry the same-tip branch checkout for a branch held by another worktree"
  retry_line=$(grep -n -F "GIT -C $POOL_DIR checkout --quiet --ignore-other-worktrees fm/$id" "$CASE_DIR/events.log" | head -1 | cut -d: -f1)
  gotmp_line=$(grep -n -F "TMUX export GOTMPDIR=/tmp/fm-$id/gotmp" "$CASE_DIR/events.log" | head -1 | cut -d: -f1)
  [ -n "$retry_line" ] && [ -n "$gotmp_line" ] \
    || fail "could not locate both the shared-branch retry and the pre-launch GOTMPDIR export"
  [ "$retry_line" -lt "$gotmp_line" ] \
    || fail "shared-branch retry happened at line $retry_line, not before pre-launch export at line $gotmp_line"
  pass "fm-spawn: a fresh reclaim can share its same-tip fm/<id> branch with an inactive prior worktree"
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
test_stale_leftover_branch_is_refused_not_reused
test_leftover_branch_at_freshened_base_is_reused
test_fresh_spawn_reuses_branch_checked_out_in_another_worktree
test_scout_brief_includes_the_branch_step
test_ship_brief_branch_step_is_idempotent

echo "# all fm-spawn-readable-branch tests passed"
