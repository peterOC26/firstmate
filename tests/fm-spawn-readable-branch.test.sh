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
  *"#{pane_current_command}"*) printf '%s\n' "${FM_FAKE_PANE_COMMAND:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    [ -z "${FM_FAKE_LIST_WINDOWS:-}" ] || printf '%s\n' "$FM_FAKE_LIST_WINDOWS"
    exit 0
    ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
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
  # Deterministic stand-in for the two lsof queries fm_lock_has_live_holder
  # makes ("does any process hold this exact path open?" and the system-wide
  # `-n -P -l -Fpn` listing of every process's open paths), so a case states which
  # holders are busy instead of inheriting the host's lsof and whatever else is
  # running on it. Empty output plus exit 1 is lsof's "provably nobody"; exit 0
  # with a listing is a live holder. FM_FAKE_LSOF_HOLDERS carries paths held as
  # a cwd, FM_FAKE_LSOF_OPEN_FILES paths held only as an ordinary open fd by a
  # process whose cwd is elsewhere; both are one per line and default to none.
  # FM_FAKE_LSOF_WARN=1 reproduces an unprivileged lsof on a host with an
  # unstatable mount: a WARNING block on stderr alongside whatever the query
  # found, still exit 1 when it found nothing - unless -w was passed, which
  # real lsof honours by printing no warnings at all.
  cat > "$fakebin/lsof" <<'SH'
#!/usr/bin/env bash
set -u
target=""
path_scan=0
cwd_only=0
warn=0
prev=""
for arg in "$@"; do
  case "$arg" in
    -Fpn) path_scan=1 ;;
    -w) warn=1 ;;
    cwd) [ "$prev" != -d ] || cwd_only=1 ;;
    -*) ;;
    *) target=$arg ;;
  esac
  prev=$arg
done
if [ "${FM_FAKE_LSOF_WARN:-0}" = 1 ] && [ "$warn" -eq 0 ]; then
  printf "lsof: WARNING: can't stat() overlay file system /var/lib/docker/rootfs/overlayfs/deadbeef\n      Output information may be incomplete.\n" >&2
fi
found=0
pid=4242
while IFS= read -r held; do
  [ -n "$held" ] || continue
  if [ "$path_scan" -eq 1 ]; then
    printf 'p%s\nfcwd\nn%s\n' "$pid" "$held"
    pid=$((pid + 1))
    found=1
    continue
  fi
  [ "$held" = "$target" ] || continue
  printf 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n'
  printf 'sleep 4242 tester cwd DIR 0,1 64 1 %s\n' "$target"
  exit 0
done <<HOLDERS
${FM_FAKE_LSOF_HOLDERS:-}
HOLDERS
while IFS= read -r open_file; do
  [ -n "$open_file" ] || continue
  if [ "$path_scan" -eq 1 ]; then
    if [ "$cwd_only" -eq 1 ]; then
      printf 'p%s\nfcwd\nn/elsewhere/home\n' "$pid"
    else
      printf 'p%s\nfcwd\nn/elsewhere/home\nf7\nn%s\n' "$pid" "$open_file"
    fi
    pid=$((pid + 1))
    found=1
    continue
  fi
  [ "$open_file" = "$target" ] || continue
  printf 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n'
  printf 'vim 4343 tester 7r REG 0,1 64 1 %s\n' "$target"
  exit 0
done <<OPEN_FILES
${FM_FAKE_LSOF_OPEN_FILES:-}
OPEN_FILES
[ "$found" -eq 1 ] && exit 0
exit 1
SH
  chmod +x "$fakebin/lsof"
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

test_freshen_preserves_named_branch_commits() {
  local rec id out status before after branch_tip
  id='readable-branch-preserve-r12'
  rec=$(make_case preserve-named-branch "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" checkout --quiet -b "fm/$id"
  printf 'keep this committed work\n' > "$POOL_DIR/preserved.txt"
  git -C "$POOL_DIR" add preserved.txt
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm preserved
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should preserve a clean named task branch"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  after=$(git -C "$POOL_DIR" rev-parse HEAD)
  branch_tip=$(git -C "$POOL_DIR" rev-parse "fm/$id")
  [ "$after" = "$before" ] || fail "freshening rewound the named task branch"
  [ "$branch_tip" = "$before" ] || fail "freshening moved the named task branch ref"
  [ "$(git -C "$POOL_DIR" symbolic-ref --quiet --short HEAD)" = "fm/$id" ] \
    || fail "spawn left the preserved task branch"
  assert_grep 'keep this committed work' "$POOL_DIR/preserved.txt" \
    "freshening discarded committed work on the named task branch"
  pass "fm-spawn: freshening preserves committed work on a clean named fm/<id> branch"
}

test_freshen_fast_forwards_named_branch_behind_origin() {
  local rec id out status before origin_tip
  id='readable-branch-behind-r15'
  rec=$(make_case behind-named-branch "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" checkout --quiet -b "fm/$id"
  before=$(git -C "$POOL_DIR" rev-parse "fm/$id")
  advance_origin "$CASE_DIR" main
  origin_tip=$(git -C "$CASE_DIR/publisher" rev-parse HEAD)
  [ "$origin_tip" != "$before" ] || fail "fixture did not move origin past the named task branch"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should fast-forward a clean named task branch that is behind origin"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  [ "$(git -C "$POOL_DIR" symbolic-ref --quiet --short HEAD)" = "fm/$id" ] \
    || fail "spawn left the named task branch while fast-forwarding it"
  [ "$(git -C "$POOL_DIR" rev-parse "fm/$id")" = "$origin_tip" ] \
    || fail "freshening did not fast-forward the named task branch to origin's tip"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$origin_tip" ] \
    || fail "the worktree did not land on origin's tip after the fast-forward"
  git -C "$POOL_DIR" merge-base --is-ancestor "$before" "$origin_tip" \
    || fail "the fast-forward moved the named task branch somewhere other than forward"
  assert_grep 'origin moved on' "$POOL_DIR/advanced.txt" \
    "the fast-forward did not bring origin's new commit into the worktree"
  pass "fm-spawn: a clean named fm/<id> behind origin is fast-forwarded, moving the ref only forward"
}

test_freshen_refuses_diverged_named_branch() {
  local rec id out status before origin_tip
  id='readable-branch-diverged-r16'
  rec=$(make_case diverged-named-branch "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" checkout --quiet -b "fm/$id"
  printf 'local task work\n' > "$POOL_DIR/diverged.txt"
  git -C "$POOL_DIR" add diverged.txt
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm diverged
  before=$(git -C "$POOL_DIR" rev-parse "fm/$id")
  advance_origin "$CASE_DIR" main
  origin_tip=$(git -C "$CASE_DIR/publisher" rev-parse HEAD)
  : > "$CASE_DIR/events.log"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched on a named task branch that diverges from origin"
  assert_contains "$out" "named task branch 'fm/$id' diverges from 'origin/main'" \
    "spawn did not name the diverging task branch it refused"
  assert_contains "$out" "refusing to rewind it" \
    "spawn did not say it refused to rewind the diverging branch"
  [ "$(git -C "$POOL_DIR" rev-parse "fm/$id")" = "$before" ] \
    || fail "the refusal moved the diverging task branch ref"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "the refusal moved the worktree off the diverging task branch"
  [ "$(git -C "$POOL_DIR" symbolic-ref --quiet --short HEAD)" = "fm/$id" ] \
    || fail "the refusal detached the worktree from its task branch"
  [ "$(git -C "$POOL_DIR" rev-parse origin/main)" = "$origin_tip" ] \
    || fail "fixture did not fetch the advanced origin before the divergence check"
  assert_grep 'local task work' "$POOL_DIR/diverged.txt" \
    "the refusal discarded committed work on the diverging task branch"
  assert_no_grep "TMUX export GOTMPDIR" "$CASE_DIR/events.log" \
    "spawn sent launch text to the pane despite refusing the diverging branch"
  pass "fm-spawn: a named fm/<id> that diverges from origin is refused with its ref untouched"
}

test_freshen_does_not_seed_from_unrelated_named_branch() {
  local rec old_id new_id out status old_tip origin_tip
  old_id='readable-branch-old-r14'
  new_id='readable-branch-new-r14'
  rec=$(make_case cross-id-branch "$old_id")
  read_case_record "$rec"
  mkdir -p "$HOME_DIR/data/$new_id"
  printf 'brief for %s\n' "$new_id" > "$HOME_DIR/data/$new_id/brief.md"
  git -C "$POOL_DIR" checkout --quiet -b "fm/$old_id"
  printf 'old task history\n' > "$POOL_DIR/old-task.txt"
  git -C "$POOL_DIR" add old-task.txt
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm old-task
  old_tip=$(git -C "$POOL_DIR" rev-parse "fm/$old_id")
  origin_tip=$(git -C "$PROJECT_DIR" rev-parse HEAD)

  out=$(run_spawn "$new_id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should refresh from origin when a pooled slot is on another task branch"
  assert_contains "$out" "spawned $new_id" "cross-id spawn did not report success"
  [ "$(git -C "$POOL_DIR" symbolic-ref --quiet --short HEAD)" = "fm/$new_id" ] \
    || fail "cross-id spawn did not create the new task branch"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$origin_tip" ] \
    || fail "cross-id spawn seeded the new task from the unrelated branch"
  [ "$(git -C "$POOL_DIR" rev-parse "fm/$old_id")" = "$old_tip" ] \
    || fail "cross-id freshening moved the unrelated task branch ref"
  [ ! -e "$POOL_DIR/old-task.txt" ] \
    || fail "cross-id spawn carried the unrelated task's committed file into the new worktree"
  pass "fm-spawn: a pooled slot on another fm/<id> returns to origin without moving that branch"
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

# leave_leftover_branch_with_commit <id> <file>: an fm/<id> nobody has checked
# out that carries one commit of the task's own work on top of the current
# base - what an earlier spawn of the same id leaves behind after its slot
# was returned or its worktree registration pruned.
leave_leftover_branch_with_commit() {
  local id=$1 file=$2
  git -C "$PROJECT_DIR" checkout --quiet -b "fm/$id"
  printf 'committed task work\n' > "$PROJECT_DIR/$file"
  git -C "$PROJECT_DIR" add "$file"
  git -C "$PROJECT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm leftover-work
  git -C "$PROJECT_DIR" checkout --quiet main
  git -C "$PROJECT_DIR" rev-parse "fm/$id"
}

test_leftover_branch_ahead_of_freshened_base_is_recovered() {
  local rec id out status base_tip leftover_tip
  id='readable-branch-ahead-r17'
  rec=$(make_case ahead-leftover "$id")
  read_case_record "$rec"
  # The leftover carries the task's committed work ahead of a base origin never
  # moved past; the pooled slot is clean at that base. This is the cross-slot
  # twin of freshening's preserve rule: switching onto the branch discards
  # nothing and only carries the worktree forward onto the task's own commits.
  base_tip=$(git -C "$PROJECT_DIR" rev-parse HEAD)
  leftover_tip=$(leave_leftover_branch_with_commit "$id" ahead.txt)
  [ "$leftover_tip" != "$base_tip" ] || fail "fixture did not put the leftover branch ahead of the base"
  : > "$CASE_DIR/events.log"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a leftover fm/$id ahead of the freshened base must not block recovery"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  [ "$(git -C "$POOL_DIR" symbolic-ref --quiet --short HEAD)" = "fm/$id" ] \
    || fail "spawn did not switch the worktree onto the existing fm/$id"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$leftover_tip" ] \
    || fail "the worktree did not land on the leftover branch's committed work"
  [ "$(git -C "$POOL_DIR" rev-parse "refs/heads/fm/$id")" = "$leftover_tip" ] \
    || fail "recovering the leftover branch moved its ref"
  assert_grep 'committed task work' "$POOL_DIR/ahead.txt" \
    "the recovered worktree does not carry the branch's committed work"
  assert_grep "GIT -C $POOL_DIR checkout --quiet fm/$id" "$CASE_DIR/events.log" \
    "spawn did not switch onto the existing branch"
  assert_no_grep "checkout --quiet -b fm/$id" "$CASE_DIR/events.log" \
    "spawn tried to re-create a branch that already existed"
  pass "fm-spawn: a leftover fm/<id> carrying committed work ahead of the freshened base is switched onto, not refused"
}

test_leftover_branch_ahead_held_by_abandoned_slot_is_reclaimed() {
  local rec id out status leftover_tip other
  id='readable-branch-ahead-abandoned-r18'
  rec=$(make_case ahead-abandoned-slot "$id")
  read_case_record "$rec"
  # The same committed work, but still checked out in a leaked slot no record
  # claims and no process holds: the holder proof clears it, and the branch's
  # commits come along rather than stranding in the leaked directory.
  other="$CASE_DIR/leaked-slot"
  git -C "$PROJECT_DIR" worktree add --quiet -b "fm/$id" "$other"
  printf 'committed task work\n' > "$other/ahead.txt"
  git -C "$other" add ahead.txt
  git -C "$other" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm leftover-work
  leftover_tip=$(git -C "$other" rev-parse HEAD)
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "fixture left a task record claiming the abandoned slot"
  : > "$CASE_DIR/events.log"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "an abandoned slot holding fm/$id with commits must not block recovery"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  [ "$(git -C "$POOL_DIR" symbolic-ref --quiet --short HEAD)" = "fm/$id" ] \
    || fail "fresh spawn did not attach its worktree to the reclaimed fm/$id"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$leftover_tip" ] \
    || fail "reclaiming the branch did not carry its committed work into the worktree"
  [ "$(git -C "$POOL_DIR" rev-parse "refs/heads/fm/$id")" = "$leftover_tip" ] \
    || fail "reclaiming the branch moved its ref"
  assert_grep "GIT -C $POOL_DIR checkout --quiet --ignore-other-worktrees fm/$id" "$CASE_DIR/events.log" \
    "spawn did not reclaim the branch from the abandoned slot"
  pass "fm-spawn: a leaked slot holding fm/<id> with committed work is reclaimed across slots"
}

test_diverged_leftover_branch_is_refused_without_moving_its_ref() {
  local rec id out status leftover_tip fresh_tip
  id='readable-branch-diverged-leftover-r19'
  rec=$(make_case diverged-leftover "$id")
  read_case_record "$rec"
  # The leftover holds committed work on a base origin has since moved past:
  # neither side contains the other, so there is no safe direction to move.
  leftover_tip=$(leave_leftover_branch_with_commit "$id" diverged.txt)
  advance_origin "$CASE_DIR" main
  : > "$CASE_DIR/events.log"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched onto a leftover fm/$id that diverges from the freshened base"
  assert_contains "$out" "branch 'fm/$id' already exists at $leftover_tip and diverges from the freshened base" \
    "spawn did not name the diverging leftover branch it refused"
  assert_contains "$out" "refusing to move the worktree onto it or rewind its ref" \
    "spawn did not say it refused both the switch and the rewind"
  fresh_tip=$(git -C "$POOL_DIR" rev-parse origin/main)
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$fresh_tip" ] \
    || fail "spawn moved the worktree off its freshened base while refusing"
  [ -z "$(git -C "$POOL_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" ] \
    || fail "spawn attached the worktree to a branch despite refusing"
  [ "$(git -C "$POOL_DIR" rev-parse "refs/heads/fm/$id")" = "$leftover_tip" ] \
    || fail "spawn moved or deleted the diverging fm/$id instead of leaving it for inspection"
  assert_no_grep "checkout" "$CASE_DIR/events.log" \
    "spawn ran a git checkout while refusing the diverging leftover branch"
  assert_no_grep "TMUX export GOTMPDIR" "$CASE_DIR/events.log" \
    "spawn sent launch text to the pane despite refusing the branch"
  pass "fm-spawn: a leftover fm/<id> that diverges from the freshened base is refused with its ref untouched"
}

test_fresh_spawn_reclaims_a_branch_held_by_an_abandoned_worktree() {
  local rec id out status tip other
  id='readable-branch-abandoned-worktree-r8'
  rec=$(make_case reclaim-abandoned-worktree "$id")
  read_case_record "$rec"
  # A slot leaked by an earlier spawn of this id that named its branch and then
  # failed before publishing a record: the directory is still on disk with
  # fm/<id> checked out, no record claims it, and - with no holder declared to
  # the lsof stub - no process is working in it. Nothing returns such a slot
  # automatically, so refusing it would make the id unspawnable until a human
  # removed the worktree by hand.
  tip=$(git -C "$PROJECT_DIR" rev-parse HEAD)
  other="$CASE_DIR/leaked-slot"
  git -C "$PROJECT_DIR" worktree add --quiet -b "fm/$id" "$other" "$tip"
  [ -d "$other" ] || fail "fixture did not leave the abandoned slot on disk"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "fixture left a task record claiming the abandoned slot"
  : > "$CASE_DIR/events.log"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "an abandoned slot no live record claims must not block a fresh spawn"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  [ "$(git -C "$POOL_DIR" symbolic-ref --quiet --short HEAD)" = "fm/$id" ] \
    || fail "fresh spawn did not attach its worktree to the reclaimed fm/$id"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$tip" ] \
    || fail "reclaiming the branch moved the worktree off the freshened base"
  assert_grep "GIT -C $POOL_DIR checkout --quiet --ignore-other-worktrees fm/$id" "$CASE_DIR/events.log" \
    "spawn did not reclaim the branch from the abandoned slot"
  pass "fm-spawn: an on-disk slot no live record claims is reclaimed, not mistaken for a live copy"
}

test_fresh_spawn_refuses_a_branch_held_by_a_live_task_copy() {
  local rec id out status tip other
  id='readable-branch-live-worktree-r9'
  rec=$(make_case refuse-live-worktree "$id")
  read_case_record "$rec"
  tip=$(git -C "$PROJECT_DIR" rev-parse HEAD)
  other="$CASE_DIR/live-copy"
  git -C "$PROJECT_DIR" worktree add --quiet -b "fm/$id" "$other" "$tip"
  # The same on-disk holder, but this home's durable record names it and its
  # recorded endpoint still runs an agent. Sharing the ref would let two agents
  # commit onto one branch and silently overwrite each other.
  {
    echo "window=firstmate:fm-$id-prev"
    echo "endpoint_task_id=$id"
    echo "worktree=$other"
    echo "project=$PROJECT_DIR"
    echo "harness=claude"
    echo "kind=ship"
  } > "$HOME_DIR/state/$id.meta"
  : > "$CASE_DIR/events.log"

  out=$(FM_FAKE_LIST_WINDOWS="fm-$id-prev" FM_FAKE_PANE_COMMAND=claude \
    run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "fresh spawn attached a second copy to a branch a live copy holds"
  assert_contains "$out" "already checked out in '$other'" \
    "the refusal did not name the copy holding the branch"
  assert_contains "$out" "cannot be proven to be an abandoned worker copy" \
    "the refusal did not say the holder could not be proven abandoned"
  assert_contains "$out" "two copies committing on one branch" \
    "the refusal did not say why sharing the branch is unsafe"
  [ -z "$(git -C "$POOL_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" ] \
    || fail "the refusal still attached the pooled worktree to a branch"
  [ "$(git -C "$other" symbolic-ref --quiet --short HEAD)" = "fm/$id" ] \
    || fail "the refusal disturbed the live copy that already held fm/$id"
  [ "$(git -C "$other" rev-parse HEAD)" = "$tip" ] \
    || fail "the refusal changed the live copy's checked-out commit"
  assert_no_grep "TMUX export GOTMPDIR" "$CASE_DIR/events.log" \
    "spawn sent launch text to the pane despite refusing the shared branch"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed live-copy refusal: %s\n' "$(printf '%s\n' "$out" | grep -F "cannot be proven to be an abandoned worker copy" | head -n 1)"
  fi
  pass "fm-spawn: a fresh spawn refuses fm/<id> while a live copy of the same task still has it checked out"
}

test_fresh_spawn_refuses_a_branch_the_primary_checkout_holds() {
  local rec id out status tip primary
  id='readable-branch-primary-holder-r10'
  rec=$(make_case refuse-primary-holder "$id")
  read_case_record "$rec"
  # A crewmate ignored its brief's isolation check and branched inside the
  # project's own checkout - the worktree tangle fm-guard.sh exists to surface.
  # No task record names the primary, so it is exactly the holder a
  # record-only rule reads as abandoned; it must be refused on identity.
  tip=$(git -C "$PROJECT_DIR" rev-parse HEAD)
  git -C "$PROJECT_DIR" checkout --quiet -b "fm/$id"
  primary=$(git -C "$PROJECT_DIR" rev-parse --show-toplevel)
  : > "$CASE_DIR/events.log"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "fresh spawn shared fm/$id with the project's primary checkout"
  assert_contains "$out" "cannot be proven to be an abandoned worker copy" \
    "the refusal did not say the holder could not be proven abandoned"
  assert_contains "$out" "already checked out in '$primary'" \
    "the refusal did not name the primary checkout as the holder"
  assert_no_grep "checkout --quiet --ignore-other-worktrees" "$CASE_DIR/events.log" \
    "spawn overrode git's own refusal to share the primary checkout's branch"
  [ "$(git -C "$PROJECT_DIR" symbolic-ref --quiet --short HEAD)" = "fm/$id" ] \
    || fail "the refusal moved the primary checkout off its branch"
  [ "$(git -C "$PROJECT_DIR" rev-parse HEAD)" = "$tip" ] \
    || fail "the refusal changed the primary checkout's commit"
  [ -z "$(git -C "$POOL_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" ] \
    || fail "the refusal still attached the pooled worktree to a branch"
  assert_no_grep "TMUX export GOTMPDIR" "$CASE_DIR/events.log" \
    "spawn sent launch text to the pane despite refusing the shared branch"
  pass "fm-spawn: a fresh spawn never overrides git to share fm/<id> with the project's primary checkout"
}

test_fresh_spawn_refuses_a_branch_held_by_a_worktree_someone_is_working_in() {
  local rec id out status tip other
  id='readable-branch-busy-worktree-r11'
  rec=$(make_case refuse-busy-worktree "$id")
  read_case_record "$rec"
  tip=$(git -C "$PROJECT_DIR" rev-parse HEAD)
  other="$CASE_DIR/busy-worktree"
  git -C "$PROJECT_DIR" worktree add --quiet -b "fm/$id" "$other" "$tip"
  # An operator's own ad-hoc worktree on fm/<id> is named by no task record
  # either; the only thing separating it from a leaked slot is that somebody is
  # working in it right now, which the lsof stub reports for this path alone.
  : > "$CASE_DIR/events.log"

  out=$(FM_FAKE_LSOF_HOLDERS="$other" run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "fresh spawn reclaimed fm/$id from a worktree somebody is working in"
  assert_contains "$out" "cannot be proven to be an abandoned worker copy" \
    "the refusal did not say the holder could not be proven abandoned"
  assert_no_grep "checkout --quiet --ignore-other-worktrees" "$CASE_DIR/events.log" \
    "spawn overrode git's own refusal for a worktree with a live process in it"
  [ "$(git -C "$other" symbolic-ref --quiet --short HEAD)" = "fm/$id" ] \
    || fail "the refusal disturbed the worktree that already held fm/$id"
  [ -z "$(git -C "$POOL_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" ] \
    || fail "the refusal still attached the pooled worktree to a branch"
  pass "fm-spawn: a holder with a live process in it is refused, not reclaimed as abandoned"
}

test_fresh_spawn_refuses_a_branch_held_by_a_subdirectory_process() {
  local rec id out status tip other subdir
  id='readable-branch-subdir-holder-r13'
  rec=$(make_case refuse-subdir-holder "$id")
  read_case_record "$rec"
  tip=$(git -C "$PROJECT_DIR" rev-parse HEAD)
  other="$CASE_DIR/subdir-holder"
  subdir="$other/src"
  git -C "$PROJECT_DIR" worktree add --quiet -b "fm/$id" "$other" "$tip"
  mkdir -p "$subdir"

  out=$(FM_FAKE_LSOF_HOLDERS="$subdir" run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "fresh spawn reclaimed fm/$id while a process held a subdirectory"
  assert_contains "$out" "cannot be proven to be an abandoned worker copy" \
    "the refusal did not account for a process in a holder subdirectory"
  assert_no_grep "checkout --quiet --ignore-other-worktrees" "$CASE_DIR/events.log" \
    "spawn overrode git's own refusal for a process in a holder subdirectory"
  [ -z "$(git -C "$POOL_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" ] \
    || fail "the refusal attached the pooled worktree to the shared branch"
  pass "fm-spawn: a process in a holder subdirectory prevents branch reclamation"
}

test_fresh_spawn_refuses_a_branch_held_by_a_process_with_a_file_open_under_it() {
  local rec id out status tip other open_file
  id='readable-branch-open-file-holder-r20'
  rec=$(make_case refuse-open-file-holder "$id")
  read_case_record "$rec"
  tip=$(git -C "$PROJECT_DIR" rev-parse HEAD)
  other="$CASE_DIR/open-file-holder"
  git -C "$PROJECT_DIR" worktree add --quiet -b "fm/$id" "$other" "$tip"
  mkdir -p "$other/src"
  open_file="$other/src/main.go"
  : > "$open_file"
  # An editor or build started from $HOME with only a file under the holder
  # open: nothing has its cwd there, so a cwd-only proof would read the slot
  # as abandoned and hand its branch to a second copy.

  out=$(FM_FAKE_LSOF_OPEN_FILES="$open_file" run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "fresh spawn reclaimed fm/$id while a process held a file under the holder open"
  assert_contains "$out" "cannot be proven to be an abandoned worker copy" \
    "the refusal did not account for an open file under the holder"
  assert_no_grep "checkout --quiet --ignore-other-worktrees" "$CASE_DIR/events.log" \
    "spawn overrode git's own refusal for a holder with a file open under it"
  [ "$(git -C "$other" symbolic-ref --quiet --short HEAD)" = "fm/$id" ] \
    || fail "the refusal disturbed the worktree that already held fm/$id"
  [ -z "$(git -C "$POOL_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" ] \
    || fail "the refusal attached the pooled worktree to the shared branch"
  pass "fm-spawn: a file held open under a holder by a process whose cwd is elsewhere prevents branch reclamation"
}

test_fresh_spawn_reclaims_an_abandoned_slot_despite_lsof_warnings() {
  local rec id out status tip other
  id='readable-branch-lsof-warning-r22'
  rec=$(make_case reclaim-despite-lsof-warnings "$id")
  read_case_record "$rec"
  # The same abandoned slot as the reclaim case, on a host where every lsof
  # query also prints a WARNING block to stderr (an unprivileged lsof meeting
  # an unstatable overlay mount does exactly this). Nobody holds the slot, so
  # the warnings must not turn "provably nobody" into "cannot tell".
  tip=$(git -C "$PROJECT_DIR" rev-parse HEAD)
  other="$CASE_DIR/leaked-slot"
  git -C "$PROJECT_DIR" worktree add --quiet -b "fm/$id" "$other" "$tip"
  : > "$CASE_DIR/events.log"

  out=$(FM_FAKE_LSOF_WARN=1 run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "benign lsof warnings must not make an abandoned slot unreclaimable"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_not_contains "$out" "lsof check failed" \
    "spawn reported lsof's benign warnings as a failed liveness check"
  [ "$(git -C "$POOL_DIR" symbolic-ref --quiet --short HEAD)" = "fm/$id" ] \
    || fail "fresh spawn did not attach its worktree to the reclaimed fm/$id"
  assert_grep "GIT -C $POOL_DIR checkout --quiet --ignore-other-worktrees fm/$id" "$CASE_DIR/events.log" \
    "spawn did not reclaim the branch from the abandoned slot"
  pass "fm-spawn: benign lsof warnings on stderr do not block reclaiming an abandoned slot"
}

test_fresh_spawn_refuses_when_any_of_several_holders_is_live() {
  local rec id out status tip first second live abandoned line
  id='readable-branch-two-holders-r21'
  rec=$(make_case refuse-two-holders "$id")
  read_case_record "$rec"
  tip=$(git -C "$PROJECT_DIR" rev-parse HEAD)
  # Two slots hold fm/<id> at once - what an earlier reclaim of an abandoned
  # slot (this script's own --ignore-other-worktrees retry) leaves behind once
  # the reclaiming copy goes live. The holder git lists first is abandoned;
  # the one it lists second has a live process. A proof that stops at the
  # first holder would hand a third copy the branch the live one is on.
  first="$CASE_DIR/holder-one"
  second="$CASE_DIR/holder-two"
  git -C "$PROJECT_DIR" worktree add --quiet -b "fm/$id" "$first" "$tip"
  git -C "$PROJECT_DIR" worktree add --quiet --detach "$second" "$tip"
  git -C "$second" checkout --quiet --ignore-other-worktrees "fm/$id"
  abandoned=""; live=""
  while IFS= read -r line; do
    case $line in
      "worktree $first"|"worktree $second")
        if [ -z "$abandoned" ]; then abandoned=${line#worktree }; else live=${line#worktree }; fi
        ;;
    esac
  done <<EOF
$(git -C "$PROJECT_DIR" worktree list --porcelain)
EOF
  [ -n "$abandoned" ] && [ -n "$live" ] || fail "fixture could not find both holders in git worktree list"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "fixture left a task record claiming a holder"
  : > "$CASE_DIR/events.log"

  out=$(FM_FAKE_LSOF_HOLDERS="$live" run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "fresh spawn reclaimed fm/$id although a second holder ('$live') still had a live process"
  assert_contains "$out" "already checked out in '$live', which cannot be proven to be an abandoned worker copy" \
    "the refusal did not name the live holder that git listed after the abandoned one"
  assert_no_grep "checkout --quiet --ignore-other-worktrees" "$CASE_DIR/events.log" \
    "spawn overrode git's own refusal while one of two holders was live"
  [ "$(git -C "$live" symbolic-ref --quiet --short HEAD)" = "fm/$id" ] \
    || fail "the refusal disturbed the live holder"
  [ -z "$(git -C "$POOL_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" ] \
    || fail "the refusal attached the pooled worktree to the shared branch"
  pass "fm-spawn: every worktree holding fm/<id> must be provably abandoned, not just the first git lists"
}

test_fresh_spawn_reclaims_a_branch_held_only_by_a_missing_worktree() {
  local rec id out status tip other retry_line gotmp_line
  id='readable-branch-missing-worktree-r9'
  rec=$(make_case reclaim-missing-worktree "$id")
  read_case_record "$rec"
  # The same registration, but the copy it names is gone from disk, so no agent
  # can be working in it and there is nothing to race.
  tip=$(git -C "$PROJECT_DIR" rev-parse HEAD)
  other="$CASE_DIR/missing-worktree"
  git -C "$PROJECT_DIR" worktree add --quiet -b "fm/$id" "$other" "$tip"
  rm -rf "$other"
  [ ! -e "$other" ] || fail "fixture did not remove the abandoned worktree directory"
  : > "$CASE_DIR/events.log"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "fresh spawn should reclaim fm/$id from a worktree that no longer exists"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  [ "$(git -C "$POOL_DIR" symbolic-ref --quiet --short HEAD)" = "fm/$id" ] \
    || fail "fresh spawn did not attach its worktree to the reclaimed fm/$id"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$tip" ] \
    || fail "reclaiming the branch moved the worktree off the freshened base"
  assert_grep "GIT -C $POOL_DIR checkout --quiet --ignore-other-worktrees fm/$id" "$CASE_DIR/events.log" \
    "spawn did not reclaim the branch from the missing worktree registration"
  retry_line=$(grep -n -F "GIT -C $POOL_DIR checkout --quiet --ignore-other-worktrees fm/$id" "$CASE_DIR/events.log" | head -1 | cut -d: -f1)
  gotmp_line=$(grep -n -F "TMUX export GOTMPDIR=/tmp/fm-$id/gotmp" "$CASE_DIR/events.log" | head -1 | cut -d: -f1)
  [ -n "$retry_line" ] && [ -n "$gotmp_line" ] \
    || fail "could not locate both the reclaim checkout and the pre-launch GOTMPDIR export"
  [ "$retry_line" -lt "$gotmp_line" ] \
    || fail "the reclaim happened at line $retry_line, not before pre-launch export at line $gotmp_line"
  pass "fm-spawn: a fresh spawn reclaims fm/<id> when the only worktree holding it is gone from disk"
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
  assert_grep "an operation in progress (rebase, merge, cherry-pick, revert, or bisect)" "$brief" \
    "scout brief's branch step does not tell the worker to leave an in-progress git operation alone"
  assert_grep "leave HEAD exactly where it is" "$brief" \
    "scout brief's branch step does not tell the worker to leave the spawn-preserved HEAD alone"
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
  # fm-spawn leaves a mid-rebase (or extra-commit) worktree exactly as the
  # previous agent left it on relaunch; the same brief is the replacement's
  # launch prompt, so its first action must not undo that.
  assert_grep "an operation in progress (rebase, merge, cherry-pick, revert, or bisect)" "$brief" \
    "ship brief's branch step does not tell the worker to leave an in-progress git operation alone"
  assert_grep "holds commits \`fm/$id\` does not" "$brief" \
    "ship brief's branch step does not tell the worker to leave commits fm/<id> lacks where they are"
  assert_grep "leave HEAD exactly where it is" "$brief" \
    "ship brief's branch step does not tell the worker to leave the spawn-preserved HEAD alone"
  pass "fm-brief.sh: a ship brief's first action is a no-op when fm-spawn already created the branch"
}

test_ship_spawn_creates_branch_before_launch
test_scout_spawn_creates_branch_before_launch
test_already_named_worktree_is_left_alone
test_freshen_preserves_named_branch_commits
test_freshen_fast_forwards_named_branch_behind_origin
test_freshen_refuses_diverged_named_branch
test_freshen_does_not_seed_from_unrelated_named_branch
test_stale_leftover_branch_is_refused_not_reused
test_leftover_branch_at_freshened_base_is_reused
test_leftover_branch_ahead_of_freshened_base_is_recovered
test_leftover_branch_ahead_held_by_abandoned_slot_is_reclaimed
test_diverged_leftover_branch_is_refused_without_moving_its_ref
test_fresh_spawn_reclaims_a_branch_held_by_an_abandoned_worktree
test_fresh_spawn_refuses_a_branch_held_by_a_live_task_copy
test_fresh_spawn_refuses_a_branch_the_primary_checkout_holds
test_fresh_spawn_refuses_a_branch_held_by_a_worktree_someone_is_working_in
test_fresh_spawn_refuses_a_branch_held_by_a_subdirectory_process
test_fresh_spawn_refuses_a_branch_held_by_a_process_with_a_file_open_under_it
test_fresh_spawn_reclaims_an_abandoned_slot_despite_lsof_warnings
test_fresh_spawn_refuses_when_any_of_several_holders_is_live
test_fresh_spawn_reclaims_a_branch_held_only_by_a_missing_worktree
test_scout_brief_includes_the_branch_step
test_ship_brief_branch_step_is_idempotent

echo "# all fm-spawn-readable-branch tests passed"
