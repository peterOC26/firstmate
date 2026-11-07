#!/usr/bin/env bash
# fm-spawn.sh on the Herdr backend: a fresh task copy is leased durably and the
# pane's TOP-LEVEL shell is moved into it.
#
# Herdr restores a pane from the cwd of its top-level shell, and the pane's
# `cwd` field does not follow a nested shell (only `foreground_cwd` does). The
# interactive `treehouse get` runs a subshell, so the later `cd` landed inside
# it and a host restart reopened every worker in the primary clone. These cases
# pin the replacement: `treehouse get --lease`, then a cd the stub applies to
# the top-level shell, never the interactive form.
#
# Canned/stateful fakes only - never a real herdr session or a real pool.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr-lease)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# make_lease_case <name>: a home, a project, and the leased task copy.
# The fake herdr models the two cwd fields: `cd` sent to the pane moves the
# restorable top-level cwd ($D/cwd) and, unless a nested shell is running,
# the foreground cwd with it. The fake treehouse opens that nested shell for
# the interactive form, which is exactly what must not be used.
make_lease_case() {
  local name=$1 harness=${2:-codex} dir home proj wt fb d
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/slot"
  d="$dir/fake"
  fb="$dir/fakebin"
  mkdir -p "$d" "$fb" "$dir/user-home"
  fm_test_spawn_home "$home" "$harness"
  fm_git_init_commit "$proj"
  git -C "$proj" worktree add -q --detach "$wt"
  fm_test_spawn_brief "$home" "$name" "Exercise the Herdr task-copy lease for $name."
  printf '%s' "$proj" > "$d/cwd"
  printf '%s' "$proj" > "$d/fg"
  : > "$d/treehouse-log"
  : > "$d/herdr-log"
  fm_test_fake_treehouse "$fb" "$wt"
  mv "$fb/treehouse" "$fb/treehouse-allocator"
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/treehouse-log"
case "$*" in
  'get --lease '*) [ ! -f "$D/lease-fails" ] || { echo 'lease failed' >&2; exit 1; } ;;
  'return --force '*)
    [ ! -e "$(dirname "$FM_FAKE_SLOT")/.fm-slot-owner" ] || : > "$D/claim-at-return"
    [ ! -f "$D/return-fails" ] || exit 1
    : > "$D/returned" ;;

esac
exec "$(dirname "$0")/treehouse-allocator" "$@"
SH
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/herdr-log"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":true}}\n'
  exit 0
fi
[ "${1:-}" != server ] || exit 0
case "${1:-} ${2:-}" in
  'session list')
    [ ! -f "$D/session-lockable" ] || printf '{"sessions":[{"name":"default","running":true,"socket_path":"%s/herdr.sock"}]}\n' "$D"
    exit 0 ;;
  'pane close')
    [ ! -f "$(dirname "$FM_FAKE_SLOT")/.fm-slot-owner" ] || cp "$(dirname "$FM_FAKE_SLOT")/.fm-slot-owner" "$D/claim-at-close"
    if [ -f "$D/conflicting-claim" ]; then
      printf 'task=another-task\nhome=%s\n' "$FM_HOME" > "$(dirname "$FM_FAKE_SLOT")/.fm-slot-owner"
    fi
    if [ -f "$D/contend-project-lock" ]; then
      bash -c '
        . "$1/bin/fm-wake-lib.sh"
        lock=$(fm_treehouse_project_lock_path "$2/project") || exit 1
        fm_lock_try_acquire "$lock" || exit 1
        printf "%s\n" "$BASHPID" > "$2/fake/contender-pid"
        : > "$2/fake/contender-ready"
        /bin/sleep 65
        fm_lock_release "$lock" || exit 1
        : > "$2/fake/contender-released"
      ' _ "$FM_TEST_CODE_ROOT" "$(dirname "$D")" > "$D/contender.log" 2>&1 &
      contender=$!
      for ((i=0; i<100; i++)); do
        [ ! -f "$D/contender-ready" ] || break
        /bin/sleep 0.01
      done
      [ -f "$D/contender-ready" ] || { kill "$contender" 2>/dev/null; exit 1; }
    fi
    : > "$D/pane-gone"; exit 0 ;;
  'pane get')
    [ ! -f "$D/pane-gone" ] || { printf '{"error":{"code":"pane_not_found"}}\n'; exit 0; }
    if [ -f "$D/cd-sent" ] && [ -f "$D/delay-reads" ]; then
      reads=$(cat "$D/reads" 2>/dev/null || printf 0)
      reads=$((reads + 1)); printf '%s' "$reads" > "$D/reads"
      if [ "$reads" -ge "$(cat "$D/delay-reads")" ]; then
        bash -c 'cd -- "$1" && pwd -P > "$2"' bash "$FM_FAKE_SLOT" "$D/fg"
      fi
    fi
    printf '{"result":{"pane":{"pane_id":"%s","cwd":"%s","foreground_cwd":"%s"}}}\n' \
      "${3:-}" "$(cat "$D/cwd")" "$(cat "$D/fg")"
    exit 0 ;;
  'pane run' | 'pane send-text')
    payload=${4:-}
    case "$payload" in
      ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
    esac
    case "$payload" in
      'export FM_TASK_ID='*) [ ! -f "$D/prelaunch-export-fails" ] || exit 1 ;;
      'cd -- '*) path=${payload#cd -- }; path=${path#\'}; path=${path%\'}
        sends=$(cat "$D/cd-sends" 2>/dev/null || printf 0)
        sends=$((sends + 1)); printf '%s' "$sends" > "$D/cd-sends"
        : > "$D/cd-sent"
        [ ! -f "$D/never-moves" ] || exit 0
        [ ! -f "$D/delay-reads" ] || exit 0
        [ ! -f "$D/drop-first-cd" ] || [ "$sends" -gt 1 ] || exit 0
        bash -c 'cd -- "$1" && pwd -P > "$2"' bash "$path" "$D/cwd"
        cp "$D/cwd" "$D/fg" ;;
      *'encode launch-brief'* | *'Firstmate operational input waiting: read'*)
        [ ! -f "$D/launch-send-fails" ] || exit 1
        printf '%s\n' "$payload" > "$D/launched-command"
        : > "$D/herdr-agent-live" ;;
    esac
    exit 0 ;;
  'agent get')
    if [ -f "$D/herdr-agent-live" ]; then
      printf '{"result":{"agent":{"agent_status":"idle"}}}\n'
    else
      printf '{"result":{"agent":{"agent_status":"shell-starting"}}}\n'
    fi
    exit 0 ;;
  'workspace list') printf '{"result":{"workspaces":[]}}\n'; exit 0 ;;
  'workspace create')
    printf '{"result":{"workspace":{"workspace_id":"wsnew"},"tab":{"tab_id":"seedtab"},"root_pane":{"pane_id":"%%1"}}}\n'
    exit 0 ;;
  'tab list') printf '{"result":{"tabs":[]}}\n'; exit 0 ;;
  'tab create')
    printf '{"result":{"tab":{"tab_id":"tabnew"},"root_pane":{"pane_id":"%%9"}}}\n'
    exit 0 ;;
esac
exit 0
SH
  cat > "$fb/polytoken" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"print models"*) printf 'zai/glm-5.3-flash\nzai/glm-5.3-flash(low)\n' ;;
esac
exit 0
SH
  chmod +x "$fb/treehouse" "$fb/herdr" "$fb/polytoken"
  fm_test_fake_sleep_noop "$fb"
  printf '%s\n' "$dir"
}

run_lease_spawn() {  # <case-dir> <id> [extra spawn args...]
  local dir=$1 id=$2
  shift 2
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_FAKE_SLOT="$dir/slot" HOME="$dir/user-home" XDG_CONFIG_HOME="$dir/user-home/.config" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 FM_TEST_CODE_ROOT="$ROOT" \
    "$SPAWN" "$id" "$dir/project" --backend herdr --mode no-mistakes --yolo off "$@" 2>&1
}

test_fresh_spawn_leases_and_moves_the_top_level_shell() {
  local id=lease-top-level dir out status
  dir=$(make_lease_case "$id")
  out=$(run_lease_spawn "$dir" "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed"$'\n'"$out"
  assert_grep "get --lease --lease-holder $dir/home/$id/a" "$dir/fake/treehouse-log" \
    "the task copy was not leased durably under the task id"
  ! grep -qx 'get' "$dir/fake/treehouse-log" \
    || fail "the interactive treehouse get opened a nested shell the restore cannot see"
  [ "$(cat "$dir/fake/cwd")" = "$dir/slot" ] \
    || fail "the pane's restorable top-level cwd is '$(cat "$dir/fake/cwd")', not the task copy"
  [ "$(cat "$dir/fake/cd-sends")" = 1 ] || fail "an immediately ready pane received a redundant cd"
  assert_grep "worktree=$dir/slot" "$dir/home/state/$id.meta" "meta did not record the leased copy"
  FM_HOME="$dir/home" bash -c '
    . "$1/bin/fm-backend.sh"
    . "$1/bin/fm-wake-lib.sh"
    fm_treehouse_record_lease "$2/home/state/$3.meta" &&
      fm_treehouse_lease_matches "$2/slot" "$FM_TREEHOUSE_RECORD_LEASE_ID" "$FM_TREEHOUSE_RECORD_LEASE_HOLDER" &&
      fm_treehouse_records_reserved "$2/project" "$2/home/state"
  ' _ "$ROOT" "$dir" "$id" || fail "published lease cannot pass reservation checks"
  pass "a fresh herdr spawn leases the copy and moves the pane's top-level shell into it"
}

test_failed_lease_refuses_without_a_record() {
  local id=lease-refused dir out status
  dir=$(make_lease_case "$id")
  : > "$dir/fake/lease-fails"
  out=$(run_lease_spawn "$dir" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn went on without a leased copy"$'\n'"$out"
  assert_contains "$out" "durable Treehouse acquisition failed" "the refusal did not name the failed lease"
  [ ! -e "$dir/home/state/$id.meta" ] || fail "refused spawn published task metadata"
  ! grep -qx 'get' "$dir/fake/treehouse-log" || fail "a refused lease fell back to the interactive form"
  pass "a failed lease refuses the spawn and falls back to nothing"
}

test_aborted_spawn_names_the_lease_it_keeps() {
  local id=lease-aborted dir out status
  dir=$(make_lease_case "$id")
  echo dirty >> "$dir/slot/README.md"
  out=$(run_lease_spawn "$dir" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched into a dirty leased copy"$'\n'"$out"
  [ ! -e "$dir/home/state/$id.meta" ] || fail "refused spawn published task metadata"
  assert_contains "$out" "stays leased to $id" "an abort did not name the lease that outlives the pane"
  assert_contains "$out" "treehouse return --if-lease-id" "an abort did not name the command that releases it"
  [ ! -e "$dir/fake/returned" ] || fail "an abort with the endpoint still open returned a slot the operator may want to inspect"
  pass "an aborted spawn keeps the lease and names the command that releases it"
}

test_rolled_back_spawn_after_launch_names_the_lease_it_keeps() {
  local id=lease-after-launch dir out status
  dir=$(make_lease_case "$id")
  : > "$dir/fake/launch-send-fails"
  out=$(run_lease_spawn "$dir" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded although its launch was not delivered"$'\n'"$out"
  [ ! -e "$dir/home/state/$id.meta" ] || fail "the failed spawn kept its task record"
  assert_contains "$out" "stays leased to $id" "a rolled-back spawn after its launch left the lease unnamed"
  assert_contains "$out" "treehouse return --if-lease-id" "a rolled-back spawn after its launch did not name the command that releases it"
  [ ! -e "$dir/fake/returned" ] || fail "an abort with the endpoint still open returned a slot the operator may want to inspect"
  pass "a spawn rolled back after its launch keeps the lease and names the command that releases it"
}

# abort_polytoken_spawn <id> <dirty|launch-fails> [session-lockable]: a
# polytoken spawn aborts, either before its launch into a dirty copy or after a
# launch that was not delivered into a clean copy, and asks Herdr to close its
# own pane. Herdr closes it only when the session's presentation lock can be
# taken, which needs the session's socket; without it the kill refuses and the
# pane stays.
abort_polytoken_spawn() {
  local id=$1 dir
  dir=$(make_lease_case "$id" polytoken)
  case "$2" in
    dirty) echo dirty >> "$dir/slot/README.md" ;;
    launch-fails) : > "$dir/fake/launch-send-fails" ;;
  esac
  [ -z "${3:-}" ] || : > "$dir/fake/session-lockable"
  LEASE_OUT=$(run_lease_spawn "$dir" "$id" --model zai/glm-5.3-flash --effort low)
  LEASE_STATUS=$?
  LEASE_DIR=$dir
}

test_abort_returns_a_clean_lease_once_the_pane_is_gone() {
  local id=lease-pane-gone
  abort_polytoken_spawn "$id" launch-fails session-lockable
  [ "$LEASE_STATUS" -ne 0 ] || fail "spawn succeeded although its launch was not delivered"$'\n'"$LEASE_OUT"
  [ ! -e "$LEASE_DIR/home/state/$id.meta" ] || fail "the failed spawn kept its task record"
  assert_grep 'pane close' "$LEASE_DIR/fake/herdr-log" "the abort did not close its pane"$'\n'"$LEASE_OUT"
  [ -e "$LEASE_DIR/fake/returned" ] || fail "the abort kept a clean lease although its pane is gone"$'\n'"$LEASE_OUT"
  [ ! -e "$LEASE_DIR/home/state/$id.treehouse-acquire" ] || fail "successful return retained its acquisition journal"
  assert_grep "task=$id" "$LEASE_DIR/fake/claim-at-close" "the abort did not exercise a claimed copy"
  [ ! -e "$LEASE_DIR/.fm-slot-owner" ] || fail "successful return retained its slot claim"
  [ ! -e "$LEASE_DIR/fake/claim-at-return" ] || fail "copy was returned before its claim was removed"
  grep -Eq '^return --force .* --if-lease-id .+ --if-lease-holder .+' "$LEASE_DIR/fake/treehouse-log" || fail "return omitted its lease identity"
  jq -e --arg path "$LEASE_DIR/slot" '.worktrees[] | select(.path == $path) | .leased != true' \
    "$TMP_ROOT/treehouse-state.json" >/dev/null || fail "successful return left the copy leased"
  pass "an abort whose pane Herdr reports gone returns a clean lease"
}

test_abort_waits_for_a_contended_project_lock() {
  local id=lease-lock-contention dir out status
  dir=$(make_lease_case "$id" polytoken)
  mkdir -p "$dir/user-home/.config/polytoken"
  printf 'version: 4\n' > "$dir/user-home/.config/polytoken/config.yaml"
  touch "$dir/fake/prelaunch-export-fails" "$dir/fake/session-lockable" "$dir/fake/contend-project-lock"
  out=$(run_lease_spawn "$dir" "$id" --model zai/glm-5.3-flash --effort low)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn unexpectedly succeeded"
  [ -f "$dir/fake/contender-ready" ] || fail "a competing process never held the project lock: $(cat "$dir/fake/contender.log" 2>/dev/null); $out"
  [ ! -f "$dir/fake/returned" ] || fail "timed-out lock returned a still-claimed slot"
  [ -d "$dir/home/state/$id.treehouse-acquire" ] || fail "timeout dropped the recovery journal"
  [ -f "$dir/.fm-slot-owner" ] || fail "timeout dropped the protected claim"
  [ ! -e "$dir/home/state/$id.meta" ] || fail "timeout retained the rolled-back record"
  assert_contains "$out" "Manual recovery:" "timeout omitted recovery instructions"
  kill "$(cat "$dir/fake/contender-pid")" 2>/dev/null || true
  printf '%s\n' "$out"
  pass "bounded project-lock timeout retains the lease, claim, and recovery journal"

}

test_conflicting_claim_keeps_lease_journal() {
  local id=lease-claim-conflict dir out status
  dir=$(make_lease_case "$id" polytoken)
  touch "$dir/fake/launch-send-fails" "$dir/fake/session-lockable" "$dir/fake/conflicting-claim"
  out=$(run_lease_spawn "$dir" "$id" --model zai/glm-5.3-flash --effort low)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn unexpectedly succeeded"
  assert_grep "task=$id" "$dir/fake/claim-at-close" "spawn never owned the slot"
  assert_grep 'task=another-task' "$dir/.fm-slot-owner" "abort removed another task's claim"
  [ ! -e "$dir/fake/returned" ] || fail "abort returned a copy with an unreleased claim"
  [ -d "$dir/home/state/$id.treehouse-acquire" ] || fail "unreleased claim lost its acquisition journal"
  assert_contains "$out" "Manual recovery:" "unreleased claim omitted recovery steps"
  pass "an unreleased claim preserves the lease and journal"
}

test_failed_return_keeps_lease_journal() {
  local id=lease-return-refused dir out status
  dir=$(make_lease_case "$id" polytoken)
  touch "$dir/fake/launch-send-fails" "$dir/fake/session-lockable" "$dir/fake/return-fails"
  out=$(run_lease_spawn "$dir" "$id" --model zai/glm-5.3-flash --effort low)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn unexpectedly succeeded"
  [ -d "$dir/home/state/$id.treehouse-acquire" ] || fail "failed return lost its acquisition journal"
  [ ! -e "$dir/fake/returned" ] || fail "failed return released its lease"
  jq -e --arg path "$dir/slot" '.worktrees[] | select(.path == $path) | .leased == true' \
    "$TMP_ROOT/treehouse-state.json" >/dev/null || fail "failed return lost the pool lease"
  assert_contains "$out" "Manual recovery:" "failed return omitted journal recovery steps"
  pass "a failed conditional return preserves the lease and journal"
}

test_abort_keeps_a_dirty_lease_once_the_pane_is_gone() {
  local id=lease-pane-gone-dirty
  abort_polytoken_spawn "$id" dirty session-lockable
  [ "$LEASE_STATUS" -ne 0 ] || fail "spawn launched into a dirty leased copy"$'\n'"$LEASE_OUT"
  assert_grep 'pane close' "$LEASE_DIR/fake/herdr-log" "the abort did not close its pane"$'\n'"$LEASE_OUT"
  [ ! -e "$LEASE_DIR/fake/returned" ] || fail "the abort returned a copy holding uncommitted work"
  assert_grep dirty "$LEASE_DIR/slot/README.md" "the abort discarded the copy's uncommitted work"
  assert_contains "$LEASE_OUT" "stays leased to $id" "an abort that kept a dirty copy did not name the lease it keeps"
  pass "an abort whose pane Herdr reports gone keeps a copy with uncommitted work leased"
}

test_abort_keeps_the_lease_while_the_pane_is_present() {
  local id=lease-close-refused
  abort_polytoken_spawn "$id" dirty
  [ "$LEASE_STATUS" -ne 0 ] || fail "spawn launched into a dirty leased copy"$'\n'"$LEASE_OUT"
  ! grep -q 'pane close' "$LEASE_DIR/fake/herdr-log" || fail "the kill closed the pane without its presentation lock"
  [ ! -e "$LEASE_DIR/fake/returned" ] || fail "the abort returned the lease while its pane is still present"
  assert_contains "$LEASE_OUT" "stays leased to $id" "an abort with its pane still present did not name the lease it keeps"
  pass "an abort whose pane is still present keeps the lease and names it"
}

test_delayed_worktree_entry() {
  local id=lease-delayed-cd dir out status
  dir=$(make_lease_case "$id")
  printf 25 > "$dir/fake/delay-reads"
  out=$(run_lease_spawn "$dir" "$id"); status=$?
  expect_code 0 "$status" "delayed cwd should settle after the old 20-read limit"$'\n'"$out"
  [ "$(cat "$dir/fake/reads")" -ge 25 ] || fail "the delay was not exercised"
  [ "$(cat "$dir/fake/cd-sends")" = 2 ] || fail "cd was not resent exactly once"
  pass "Herdr waits past the former deadline for a delayed shell cwd"
}

test_dropped_worktree_entry() {
  local id=lease-dropped-cd dir out status
  dir=$(make_lease_case "$id")
  : > "$dir/fake/drop-first-cd"
  out=$(run_lease_spawn "$dir" "$id"); status=$?
  expect_code 0 "$status" "a dropped first cd should recover"$'\n'"$out"
  [ "$(cat "$dir/fake/cd-sends")" = 2 ] || fail "cd was not resent exactly once"
  pass "Herdr recovers a dropped initial cd with one resend"
}

test_never_moving_worktree_entry() {
  local id=lease-stuck-cd dir out status
  dir=$(make_lease_case "$id")
  : > "$dir/fake/never-moves"
  out=$(run_lease_spawn "$dir" "$id"); status=$?
  [ "$status" -ne 0 ] || fail "a pane that never moves was accepted"
  assert_contains "$out" "not its recorded worktree" "wrong cwd did not refuse"
  assert_contains "$out" "Herdr pane 'default:%9'" "refusal did not identify the pane"
  assert_contains "$out" "last foreground_cwd='$dir/project'" "refusal lost the last cwd"
  assert_contains "$out" "agent_status='shell-starting'" "refusal lost agent status"
  [ "$(cat "$dir/fake/cd-sends")" = 2 ] || fail "a stuck pane received more than one retry"
  [ ! -e "$dir/fake/launched-command" ] || fail "a harness started outside its copy"
  [ ! -e "$dir/home/state/$id.meta" ] || fail "refused spawn published metadata"
  pass "Herdr refuses a never-moving pane with diagnostic context and no launch"
}

test_abort_waits_for_a_contended_project_lock
