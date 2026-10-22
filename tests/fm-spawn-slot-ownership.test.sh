#!/usr/bin/env bash
# Offline durable reservation regressions through spawn and guarded teardown.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-slot-ownership)

make_case() {
  CASE_DIR="$TMP_ROOT/$1"
  HOME_DIR="$CASE_DIR/home"
  PROJECT="$CASE_DIR/project"
  POOL="$CASE_DIR/pool"
  fm_test_spawn_home "$HOME_DIR" codex
  fm_git_init_commit "$PROJECT"
  mkdir -p "$POOL/1" "$POOL/2"
  git -C "$PROJECT" worktree add -q --detach "$POOL/1/project"
  git -C "$PROJECT" worktree add -q --detach "$POOL/2/project"
  jq -n --arg a "$POOL/1/project" --arg b "$POOL/2/project" \
    '{worktrees:[{path:$a},{path:$b}]}' > "$POOL/treehouse-state.json"
  FAKEBIN=$(make_spawn_fakebin "$CASE_DIR/fake" no-mistakes)
  fm_test_fake_sleep_noop "$FAKEBIN"
  mv "$FAKEBIN/tmux" "$FAKEBIN/tmux.base"
  cat > "$FAKEBIN/tmux" <<'TMUX'
#!/usr/bin/env bash
case "$*" in
  *pane_current_command*) echo bash; exit 0 ;;
  *pane_pid*) echo 99999999; exit 0 ;;
esac
case "$1" in
  new-window|send-keys|kill-window) printf '%s\n' "$*" >> "$FM_MUTATION_LOG" ;;
esac
exec "$(dirname "$0")/tmux.base" "$@"
TMUX
  chmod +x "$FAKEBIN/tmux"
  : > "$CASE_DIR/mutations"
  : > "$CASE_DIR/treehouse.log"
}
spawn_task() {  # <id> <slot> [args]
  local id=$1 slot=$2
  shift 2
  fm_test_spawn_brief "$HOME_DIR" "$id"
  FM_MUTATION_LOG="$CASE_DIR/mutations" FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/treehouse.log" \
    FM_FAKE_TREEHOUSE_POOL="$POOL" \
    fm_test_run_spawn "$HOME_DIR" "$POOL/$slot/project" "$FAKEBIN" \
    "$id" "$PROJECT" --scout "$@"
}
read_lease() {
  FM_HOME="$HOME_DIR" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-backend.sh"
    fm_treehouse_record_lease "$2" || exit
    printf "%s|%s\n" "$FM_TREEHOUSE_RECORD_LEASE_ID" "$FM_TREEHOUSE_RECORD_LEASE_HOLDER"
  ' _ "$ROOT" "$HOME_DIR/state/$1.meta"
}

test_reservation_survives_worker_exit_and_releases_at_cleanup() {
  local out rc before after
  make_case reserved
  out=$(spawn_task retained 1); rc=$?
  expect_code 0 "$rc" "first spawn failed: $out"
  before=$(read_lease retained)
  printf 'done: report ready\n' > "$HOME_DIR/state/retained.status"
  # Reboot/exit is modelled by dropping every endpoint in the fake inventory.
  : > "$FAKEBIN/.spawn-window"
  out=$(spawn_task successor 2); rc=$?
  expect_code 0 "$rc" "second spawn failed: $out"
  assert_grep "worktree=$POOL/2/project" "$HOME_DIR/state/successor.meta" "a retained copy was reused"
  after=$(read_lease retained)
  [ "$before" = "$after" ] || fail "worker exit changed acquisition identity"
  jq -e '.worktrees[] | select(.path | endswith("/1/project")) | .leased == true' "$POOL/treehouse-state.json" >/dev/null || fail "exit released the durable reservation"
  FM_HOME="$HOME_DIR" FM_MUTATION_LOG="$CASE_DIR/mutations" FM_FAKE_PANE_PATH="$POOL/1/project" \
    FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/treehouse.log" PATH="$FAKEBIN:$PATH" \
    bash "$ROOT/bin/fm-teardown.sh" retained --force > "$CASE_DIR/cleanup" 2>&1 \
    || fail "guarded mocked cleanup failed: $(cat "$CASE_DIR/cleanup")"
  assert_absent "$HOME_DIR/state/retained.meta" "cleanup left its task record"
  assert_absent "$HOME_DIR/state/retained.treehouse-acquire" "cleanup left its acquisition journal"
  grep -Eq 'return --force.*--if-lease-id.*--if-lease-holder' "$CASE_DIR/treehouse.log" || fail "cleanup did not condition release on both identity fields"
  jq -e '.worktrees[] | select(.path | endswith("/1/project")) | .leased != true' "$POOL/treehouse-state.json" >/dev/null || fail "cleanup kept the reservation"
  pass "retained records reserve their copies through exit; explicit cleanup releases exactly their lease"
}

test_legacy_alias_cross_home_and_unreadable_refuse_before_get() {
  local shape out rc home meta
  for shape in legacy alias registered unreadable contradictory; do
    make_case "$shape"
    home=$HOME_DIR
    if [ "$shape" = registered ]; then
      home="$CASE_DIR/mate"
      mkdir -p "$home/state" "$home/data" "$home/config"
      printf -- '- mate - fixture (home: %s; scope: test; projects: project; added 2026-01-01)\n' "$home" > "$HOME_DIR/data/secondmates.md"
    fi
    meta="$home/state/retained.meta"
    if [ "$shape" = unreadable ]; then
      mkdir "$meta"
    else
      path="$POOL/1/project"
      if [ "$shape" = alias ]; then
        ln -s "$path" "$CASE_DIR/alias"
        path="$CASE_DIR/alias"
      fi
      fm_write_meta "$meta" "worktree=$path" "project=$PROJECT" "kind=scout"
      [ "$shape" != contradictory ] || printf 'worktree=%s\n' "$POOL/2/project" >> "$meta"
    fi
    : > "$POOL/1/project/dirty-sentinel"
    out=$(spawn_task candidate 2); rc=$?
    [ "$rc" -ne 0 ] || fail "$shape ownership was ignored"
    [ ! -s "$CASE_DIR/treehouse.log" ] || fail "$shape reached allocation/reset: $out"
    [ ! -s "$CASE_DIR/mutations" ] || fail "$shape changed an endpoint: $out"
    assert_present "$POOL/1/project/dirty-sentinel" "$shape reset a referenced copy"
  done
  pass "legacy, aliased, cross-home, and unreadable records refuse before allocation or endpoint mutation"
}

test_relaunch_keeps_acquisition_and_rejects_stale_claim() {
  local out rc before after shape marker
  for shape in owned stale other-home; do
    make_case "relaunch-$shape"
    out=$(spawn_task retained 1); rc=$?
    expect_code 0 "$rc" "setup spawn failed: $out"
    before=$(read_lease retained)
    marker="$POOL/1/.fm-slot-owner"
    case "$shape" in
      stale) printf 'task=successor\nhome=%s\n' "$HOME_DIR" > "$marker" ;;
      other-home)
        mkdir -p "$CASE_DIR/other-home"
        printf 'task=retained\nhome=%s\n' "$CASE_DIR/other-home" > "$marker"
        ;;
    esac
    cp "$HOME_DIR/state/retained.meta" "$CASE_DIR/prior.meta"
    : > "$CASE_DIR/mutations"
    : > "$CASE_DIR/treehouse.log"
    out=$(FM_MUTATION_LOG="$CASE_DIR/mutations" FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/treehouse.log" \
      fm_test_run_spawn "$HOME_DIR" "$POOL/1/project" "$FAKEBIN" retained --relaunch); rc=$?
    if [ "$shape" = owned ]; then
      expect_code 0 "$rc" "owned relaunch failed: $out"
      after=$(read_lease retained)
      [ "$before" = "$after" ] || fail "relaunch replaced the immutable acquisition"
      before=$(awk -F= '$1=="spawn_gen" {print $2}' "$CASE_DIR/prior.meta")
      after=$(awk -F= '$1=="spawn_gen" {print $2}' "$HOME_DIR/state/retained.meta")
      [ "$before" != "$after" ] || fail "relaunch did not produce a new incarnation"
    else
      [ "$rc" -ne 0 ] || fail "$shape relaunched into the successor copy"
      [ ! -s "$CASE_DIR/mutations" ] || fail "$shape mutated an endpoint before refusing: $out"
      cmp -s "$CASE_DIR/prior.meta" "$HOME_DIR/state/retained.meta" || fail "$shape rewrote its record"
    fi
    [ ! -s "$CASE_DIR/treehouse.log" ] || fail "relaunch acquired or returned a lease"
  done
  pass "relaunch preserves the acquisition across spawn_gen and rejects stale or cross-home claims before mutation"
}

test_unsupported_cli_and_failed_acquisition_preserve_reservations() {
  local out rc raw_id pool_id
  make_case old-cli
  mv "$FAKEBIN/treehouse" "$FAKEBIN/treehouse.base"
  cat > "$FAKEBIN/treehouse" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'get --help') echo '--lease --lease-holder'; exit 0 ;;
  'return --help') echo '--force'; exit 0 ;;
esac
exec "$(dirname "$0")/treehouse.base" "$@"
FAKE
  chmod +x "$FAKEBIN/treehouse"
  out=$(spawn_task candidate 1); rc=$?
  [ "$rc" -ne 0 ] || fail "an unsupported Treehouse CLI was accepted"
  assert_contains "$out" "durable task leases require" "missing capability diagnostic"
  [ ! -s "$CASE_DIR/treehouse.log" ] && [ ! -s "$CASE_DIR/mutations" ] || fail "old CLI reached allocation or endpoint mutation"

  make_case acquire-aborted
  mv "$FAKEBIN/treehouse" "$FAKEBIN/treehouse.base"
  cat > "$FAKEBIN/treehouse" <<'FAKE'
#!/usr/bin/env bash
"$(dirname "$0")/treehouse.base" "$@" || exit
# Model a failed/interrupted drive after Treehouse committed the allocation.
[ "$*" != "get --help" ] && [ "$1" = get ] && exit 23
exit 0
FAKE
  chmod +x "$FAKEBIN/treehouse"
  out=$(spawn_task interrupted 1); rc=$?
  [ "$rc" -ne 0 ] || fail "a failed acquisition response was accepted"
  assert_absent "$HOME_DIR/state/interrupted.meta" "failed acquisition published a task record"
  raw_id=$(jq -er .lease_id "$HOME_DIR/state/interrupted.treehouse-acquire/allocation.json") || fail "abort lost its raw lease identity"
  pool_id=$(jq -r '.worktrees[] | select(.leased == true) | .lease_id' "$POOL/treehouse-state.json")
  [ "$raw_id" = "$pool_id" ] || fail "abort recovery identity disagrees with the reserved slot"
  assert_grep 'treehouse_lease_holder=' "$HOME_DIR/state/interrupted.treehouse-acquire/identity" "abort lost its acquisition holder"
  : > "$CASE_DIR/treehouse.log"
  : > "$CASE_DIR/mutations"
  out=$(spawn_task later 2); rc=$?
  [ "$rc" -ne 0 ] || fail "a partial acquisition journal was silently bypassed"
  [ ! -s "$CASE_DIR/treehouse.log" ] && [ ! -s "$CASE_DIR/mutations" ] || fail "unknown acquisition recovery reached get or endpoint mutation"
  pass "unsupported CLIs refuse before mutation; interrupted acquisitions retain exact lease evidence and block unsafe reuse"
}

test_another_project_record_does_not_block_this_pool() {
  local out rc other="$TMP_ROOT/foreign-project"
  make_case unrelated-project
  fm_git_init_commit "$other"
  mkdir -p "$CASE_DIR/foreign-pool/1"
  git -C "$other" worktree add -q --detach "$CASE_DIR/foreign-pool/1/foreign"
  jq -n --arg path "$CASE_DIR/foreign-pool/1/foreign" '{worktrees:[{path:$path}]}' > "$CASE_DIR/foreign-pool/treehouse-state.json"
  fm_write_meta "$HOME_DIR/state/foreign.meta" "worktree=$CASE_DIR/foreign-pool/1/foreign" "project=$other" "kind=scout"
  out=$(spawn_task candidate 1); rc=$?
  expect_code 0 "$rc" "an unrelated project's retained record blocked this pool: $out"
  pass "retained copies of another repository do not block this project's allocation"
}

test_separate_clones_share_the_origin_pool_reservation() {
  local shape out rc clone original
  for shape in legacy leased; do
    make_case "separate-clone-$shape"
    original=$PROJECT
    git clone -q --bare "$PROJECT" "$CASE_DIR/origin.git"
    git -C "$PROJECT" remote add origin "file://$CASE_DIR/origin.git"
    mkdir -p "$CASE_DIR/mate"
    clone="$CASE_DIR/mate/project"
    git clone -q "file://$CASE_DIR/origin.git" "$clone"
    if [ "$shape" = legacy ]; then
      fm_write_meta "$HOME_DIR/state/retained.meta" "worktree=$POOL/1/project" "project=$original" "kind=scout"
      PROJECT=$clone
      out=$(spawn_task candidate 2); rc=$?
      [ "$rc" -ne 0 ] || fail "a second clone bypassed a retained legacy pool reference"
      [ ! -s "$CASE_DIR/treehouse.log" ] && [ ! -s "$CASE_DIR/mutations" ] || fail "a second clone reached get before legacy reconciliation: $out"
    else
      out=$(spawn_task retained 1); rc=$?
      expect_code 0 "$rc" "first clone spawn failed: $out"
      PROJECT=$clone
      out=$(spawn_task candidate 2); rc=$?
      expect_code 0 "$rc" "a second clone could not use another leased pool copy: $out"
      assert_grep 'task=candidate' "$POOL/2/.fm-slot-owner" "a separate Git common directory bypassed the slot claim"
      FM_HOME="$HOME_DIR" FM_MUTATION_LOG="$CASE_DIR/mutations" FM_FAKE_PANE_PATH="$POOL/2/project" \
        FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/treehouse.log" PATH="$FAKEBIN:$PATH" \
        bash "$ROOT/bin/fm-teardown.sh" candidate --force > "$CASE_DIR/cleanup" 2>&1 \
        || fail "cross-clone guarded cleanup failed: $(cat "$CASE_DIR/cleanup")"
      assert_present "$HOME_DIR/state/retained.meta" "cross-clone cleanup retired the other task"
      jq -e '.worktrees[] | select(.path | endswith("/1/project")) | .leased == true' "$POOL/treehouse-state.json" >/dev/null || fail "cross-clone cleanup released the other task's lease"
    fi
  done
  pass "separate clones sharing an origin honor legacy references and keep lease claims and cleanup scoped to one copy"
}

test_reservation_survives_worker_exit_and_releases_at_cleanup
test_legacy_alias_cross_home_and_unreadable_refuse_before_get
test_relaunch_keeps_acquisition_and_rejects_stale_claim
test_unsupported_cli_and_failed_acquisition_preserve_reservations
test_another_project_record_does_not_block_this_pool
test_separate_clones_share_the_origin_pool_reservation
