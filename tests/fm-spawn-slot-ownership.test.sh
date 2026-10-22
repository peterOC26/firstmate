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

test_missing_leased_copy_recovery_messages() {
  local shape out rc task_home run_home task_id
  for shape in direct child; do
    make_case "missing-copy-$shape"
    out=$(spawn_task retained 1); rc=$?
    expect_code 0 "$rc" "setup spawn failed: $out"
    task_home=$HOME_DIR
    run_home=$HOME_DIR
    task_id=retained
    if [ "$shape" = child ]; then
      run_home="$CASE_DIR/parent"
      mkdir -p "$run_home/state" "$run_home/data" "$run_home/config"
      printf 'mate
' > "$task_home/.fm-secondmate-home"
      fm_write_meta "$run_home/state/mate.meta"         "window=firstmate:fm-mate" "endpoint_task_id=mate" "spawn_gen=fixture"         "worktree=$task_home" "home=$task_home" "project=$task_home"         "kind=secondmate" "mode=secondmate" "harness=echo"
      task_id=mate
    fi
    mv "$POOL/1/project" "$CASE_DIR/saved-copy"
    cp "$task_home/state/retained.meta" "$CASE_DIR/prior.meta"
    cp "$POOL/treehouse-state.json" "$CASE_DIR/prior-pool.json"
    : > "$CASE_DIR/treehouse.log"
    : > "$CASE_DIR/mutations"
    FM_HOME="$run_home" FM_MUTATION_LOG="$CASE_DIR/mutations" FM_FAKE_PANE_PATH="$POOL/1/project"       FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/treehouse.log" PATH="$FAKEBIN:$PATH"       bash "$ROOT/bin/fm-teardown.sh" "$task_id" --force > "$CASE_DIR/refusal" 2>&1; rc=$?
    [ "$rc" -ne 0 ] || fail "$shape missing leased copy was cleaned up"
    assert_grep 'Manual recovery: pause allocations and cleanup' "$CASE_DIR/refusal" "missing $shape recovery instructions: $(cat "$CASE_DIR/refusal")"
    assert_grep 'Read project=, treehouse_lease_id=, and treehouse_lease_holder=' "$CASE_DIR/refusal" "missing identity inspection"
    assert_grep 'Restore the original copy' "$CASE_DIR/refusal" "missing restore step"
    assert_grep 'Do not fabricate ownership evidence.' "$CASE_DIR/refusal" "missing ownership verification"
    assert_grep 'keep the records and lease and obtain operator reconciliation' "$CASE_DIR/refusal" "missing uncertain recovery instruction"
    assert_grep "FM_HOME=$task_home bash $ROOT/bin/fm-teardown.sh retained" "$CASE_DIR/refusal" "missing exact guarded retry"
    cmp -s "$CASE_DIR/prior.meta" "$task_home/state/retained.meta" || fail "$shape refusal changed metadata"
    cmp -s "$CASE_DIR/prior-pool.json" "$POOL/treehouse-state.json" || fail "$shape refusal changed lease"
    assert_present "$task_home/state/retained.treehouse-acquire" "missing copy refusal removed journal"
    [ ! -s "$CASE_DIR/treehouse.log" ] && [ ! -s "$CASE_DIR/mutations" ] || fail "$shape refusal mutated pool or endpoint"
  done
  pass "missing leased copies retain records and print recovery steps for direct and descendant teardown"
}

test_unrecognized_leased_copy_refuses_publication() {
  local out rc
  make_case unrecognized-copy
  git -C "$PROJECT" worktree remove "$POOL/1/project"
  git clone -q "$PROJECT" "$POOL/1/project"
  git -C "$POOL/1/project" remote set-url origin "$CASE_DIR/different-origin"
  out=$(spawn_task candidate 1); rc=$?
  [ "$rc" -ne 0 ] || fail "unrecognized leased copy published"
  assert_contains "$out" 'not a recognized Treehouse pool slot' "missing pool recognition refusal: $out"
  assert_absent "$HOME_DIR/state/candidate.meta" "unrecognized copy published metadata"
  assert_absent "$POOL/1/.fm-slot-owner" "unrecognized copy gained a claim"
  assert_present "$HOME_DIR/state/candidate.treehouse-acquire/allocation.json" "unrecognized copy lost journal"
  jq -e '.worktrees[] | select(.path | endswith("/1/project")) | .leased == true' "$POOL/treehouse-state.json" >/dev/null || fail "unrecognized copy lost lease"
  pass "unrecognized leased copies refuse before claim and publication while retaining recovery evidence"
}

test_empty_record_fields_name_no_copy() {
  local field shape out rc
  for field in worktree home project; do
    for shape in empty duplicate; do
      make_case "record-$field-$shape"
      fm_write_meta "$HOME_DIR/state/recovery.meta" "backend=orca" "$field="
      [ "$shape" != duplicate ] || printf '%s=
' "$field" >> "$HOME_DIR/state/recovery.meta"
      out=$(spawn_task candidate 1); rc=$?
      if [ "$shape" = duplicate ]; then
        [ "$rc" -ne 0 ] || fail "duplicate empty $field was accepted"
        [ ! -s "$CASE_DIR/treehouse.log" ] || fail "duplicate $field reached allocation"
      else
        expect_code 0 "$rc" "empty $field blocked allocation or exclusive publication: $out"
        out=$(FM_MUTATION_LOG="$CASE_DIR/mutations" fm_test_run_spawn "$HOME_DIR" "$POOL/1/project" "$FAKEBIN" candidate --relaunch); rc=$?
        expect_code 0 "$rc" "empty $field blocked relaunch: $out"
        FM_HOME="$HOME_DIR" FM_MUTATION_LOG="$CASE_DIR/mutations" FM_FAKE_PANE_PATH="$POOL/1/project"           FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/treehouse.log" PATH="$FAKEBIN:$PATH"           bash "$ROOT/bin/fm-teardown.sh" candidate --force > "$CASE_DIR/cleanup" 2>&1           || fail "empty $field blocked teardown exclusivity: $(cat "$CASE_DIR/cleanup")"
        assert_absent "$HOME_DIR/state/candidate.meta" "empty $field stranded candidate"
      fi
      assert_present "$HOME_DIR/state/recovery.meta" "record scan removed recovery record"
    done
  done
  pass "empty path fields permit allocation relaunch and cleanup; duplicate empty fields still refuse"
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
  for shape in owned stale other-home legacy-owned legacy-stale; do
    make_case "relaunch-$shape"
    out=$(spawn_task retained 1); rc=$?
    expect_code 0 "$rc" "setup spawn failed: $out"
    marker="$POOL/1/.fm-slot-owner"
    case "$shape" in
      legacy-*)
        # A record from before durable leases: no lease fields, unleased pool entry.
        sed -i '/^treehouse_lease_/d' "$HOME_DIR/state/retained.meta"
        rm -rf "$HOME_DIR/state/retained.treehouse-acquire"
        jq '.worktrees |= map(del(.leased, .lease_id, .lease_holder))' "$POOL/treehouse-state.json" > "$POOL/state.tmp"
        mv "$POOL/state.tmp" "$POOL/treehouse-state.json"
        ;;
    esac
    before=$(read_lease retained)
    case "$shape" in
      stale|legacy-stale) printf 'task=successor\nhome=%s\n' "$HOME_DIR" > "$marker" ;;
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
    if [ "$shape" = legacy-owned ]; then
      expect_code 0 "$rc" "a legacy record could not relaunch into its own claimed copy: $out"
      assert_grep "worktree=$POOL/1/project" "$HOME_DIR/state/retained.meta" "legacy relaunch moved its copy"
      ! grep -q '^treehouse_lease_' "$HOME_DIR/state/retained.meta" || fail "legacy relaunch invented a lease identity"
    elif [ "$shape" = owned ]; then
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
  pass "relaunch preserves the acquisition across spawn_gen, keeps legacy owners relaunchable, and rejects stale or cross-home claims before mutation"
}

test_cleanup_rerun_after_released_lease_is_records_only() {
  local shape out rc
  for shape in released held legacy-alone legacy-shared-worktree legacy-shared-home; do
    make_case "rerun-$shape"
    out=$(spawn_task retained 1); rc=$?
    expect_code 0 "$rc" "setup spawn failed: $out"
    # An earlier cleanup returned the copy and dropped its claim, then failed.
    rm -f "$POOL/1/.fm-slot-owner"
    if [ "$shape" != held ]; then
      jq '.worktrees |= map(del(.leased, .lease_id, .lease_holder))' "$POOL/treehouse-state.json" > "$POOL/state.tmp"
      mv "$POOL/state.tmp" "$POOL/treehouse-state.json"
    fi
    case "$shape" in
      legacy-*)
        sed -i '/^treehouse_lease_/d' "$HOME_DIR/state/retained.meta"
        rm -rf "$HOME_DIR/state/retained.treehouse-acquire"
        if [ "$shape" != legacy-alone ]; then
          mkdir -p "$CASE_DIR/mate/state" "$CASE_DIR/mate/data" "$CASE_DIR/mate/config"
          printf -- '- mate - fixture (home: %s; scope: test; projects: project; added 2026-01-01)\n' "$CASE_DIR/mate" > "$HOME_DIR/data/secondmates.md"
          fm_write_meta "$CASE_DIR/mate/state/other.meta" "${shape##legacy-shared-}=$POOL/1/project" "project=$PROJECT" "kind=scout"
        fi
        ;;
    esac
    : > "$POOL/1/project/dirty-sentinel"
    printf 'preserve wiring\n' > "$POOL/1/project/.fm-grok-turnend"
    cp "$POOL/treehouse-state.json" "$CASE_DIR/pool-before.json"
    : > "$CASE_DIR/treehouse.log"
    FM_HOME="$HOME_DIR" FM_MUTATION_LOG="$CASE_DIR/mutations" FM_FAKE_PANE_PATH="$POOL/1/project" \
      FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/treehouse.log" PATH="$FAKEBIN:$PATH" \
      bash "$ROOT/bin/fm-teardown.sh" retained --force > "$CASE_DIR/cleanup" 2>&1; rc=$?
    if [ "$shape" = released ] || [ "$shape" = legacy-alone ]; then
      expect_code 0 "$rc" "a re-run after the lease was released was stranded: $(cat "$CASE_DIR/cleanup")"
      assert_absent "$HOME_DIR/state/retained.meta" "the re-run left its task record"
      if [ "$shape" = released ]; then
        assert_grep 'already released' "$CASE_DIR/cleanup" "the re-run did not name the released lease"
      else
        assert_grep 'records-only cleanup' "$CASE_DIR/cleanup" "legacy cleanup did not name its records-only scope"
        assert_grep 'was not returned and is left untouched' "$CASE_DIR/cleanup" "legacy completion incorrectly claimed release"
      fi
    else
      [ "$rc" -ne 0 ] || fail "an unclaimed copy still holding this lease was cleaned up"
      assert_present "$HOME_DIR/state/retained.meta" "a refused cleanup removed its task record"
    fi
    [ ! -s "$CASE_DIR/treehouse.log" ] || fail "$shape cleanup returned a copy it could not prove was its own"
    assert_present "$POOL/1/project/dirty-sentinel" "$shape cleanup touched the copy"
    assert_grep 'preserve wiring' "$POOL/1/project/.fm-grok-turnend" "$shape cleanup removed harness wiring"
    cmp -s "$CASE_DIR/pool-before.json" "$POOL/treehouse-state.json" || fail "$shape cleanup changed pool state"
  done
  pass "a cleanup re-run after its lease was released retires records only; an unclaimed held lease still refuses"
}

test_legacy_unclaimed_ship_preserves_unlanded_work() {
  local shape out rc before
  for shape in dirty unpushed clean; do
    make_case "legacy-safety-$shape"
    out=$(spawn_task retained 1); rc=$?
    expect_code 0 "$rc" "setup spawn failed: $out"
    sed -i '/^treehouse_lease_/d; s/^kind=scout$/kind=ship/; /^mode=/d' "$HOME_DIR/state/retained.meta"
    printf 'mode=local-only\n' >> "$HOME_DIR/state/retained.meta"
    rm -rf "$HOME_DIR/state/retained.treehouse-acquire"
    rm -f "$POOL/1/.fm-slot-owner"
    jq '.worktrees |= map(del(.leased, .lease_id, .lease_holder))' "$POOL/treehouse-state.json" > "$POOL/state.tmp"
    mv "$POOL/state.tmp" "$POOL/treehouse-state.json"
    case "$shape" in
      dirty) printf 'unfinished
' > "$POOL/1/project/unfinished" ;;
      unpushed)
        printf 'unlanded
' > "$POOL/1/project/unlanded"
        git -C "$POOL/1/project" add unlanded
        git -C "$POOL/1/project" -c user.name=Test -c user.email=test@example.invalid commit -qm 'Unlanded work' || fail "could not create unlanded commit"
        ;;
    esac
    before=$(git -C "$POOL/1/project" rev-parse HEAD)
    cp "$HOME_DIR/state/retained.meta" "$CASE_DIR/prior.meta"
    cp "$POOL/treehouse-state.json" "$CASE_DIR/prior-pool.json"
    : > "$CASE_DIR/mutations"
    : > "$CASE_DIR/treehouse.log"
    FM_HOME="$HOME_DIR" FM_MUTATION_LOG="$CASE_DIR/mutations" FM_FAKE_PANE_PATH="$POOL/1/project"       FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/treehouse.log" PATH="$FAKEBIN:$PATH"       bash "$ROOT/bin/fm-teardown.sh" retained > "$CASE_DIR/cleanup" 2>&1; rc=$?
    if [ "$shape" = clean ]; then
      expect_code 0 "$rc" "clean legacy cleanup failed: $(cat "$CASE_DIR/cleanup")"
      assert_absent "$HOME_DIR/state/retained.meta" "clean legacy record was stranded"
      assert_grep 'was not returned and is left untouched' "$CASE_DIR/cleanup" "clean legacy completion claimed release"
    else
      [ "$rc" -ne 0 ] || fail "$shape legacy copy lost its record without --force"
      assert_grep 'REFUSED: local-only worktree' "$CASE_DIR/cleanup" "$shape legacy cleanup missed its safety refusal: $(cat "$CASE_DIR/cleanup")"
      cmp -s "$CASE_DIR/prior.meta" "$HOME_DIR/state/retained.meta" || fail "$shape refusal changed its record"
      [ ! -s "$CASE_DIR/mutations" ] || fail "$shape refusal changed the endpoint"
      if [ "$shape" = dirty ]; then
        assert_grep unfinished "$POOL/1/project/unfinished" "dirty work was modified"
      else
        assert_grep 'commits not yet on' "$CASE_DIR/cleanup" "unpushed refusal did not identify unlanded commits"
        assert_grep unlanded "$POOL/1/project/unlanded" "unpushed work was modified"
      fi
    fi
    [ "$before" = "$(git -C "$POOL/1/project" rev-parse HEAD)" ] || fail "$shape cleanup changed HEAD"
    cmp -s "$CASE_DIR/prior-pool.json" "$POOL/treehouse-state.json" || fail "$shape cleanup changed pool state"
    [ ! -s "$CASE_DIR/treehouse.log" ] || fail "$shape cleanup returned its copy"
  done
  pass "unclaimed legacy ships retain dirty and unpushed work; clean copies retire records without return"
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
  # shellcheck disable=SC2016
  assert_contains "$out" 'treehouse return --if-lease-id "$lease_id" --if-lease-holder "$lease_holder" "$worktree"' "abort omitted guarded manual return"
  # shellcheck disable=SC2016
  assert_contains "$out" 'rm -f -- "$(dirname "$worktree")/.fm-slot-owner"' "abort omitted claim removal"
  # shellcheck disable=SC2016
  assert_contains "$out" 'rm -rf -- "$journal"' "abort omitted journal removal"
  assert_contains "$out" "$HOME_DIR/state/interrupted.treehouse-acquire" "abort omitted journal path"
  assert_absent "$HOME_DIR/state/interrupted.meta" "failed acquisition published a task record"
  raw_id=$(jq -er .lease_id "$HOME_DIR/state/interrupted.treehouse-acquire/allocation.json") || fail "abort lost its raw lease identity"
  pool_id=$(jq -r '.worktrees[] | select(.leased == true) | .lease_id' "$POOL/treehouse-state.json")
  [ "$raw_id" = "$pool_id" ] || fail "abort recovery identity disagrees with the reserved slot"
  assert_grep 'treehouse_lease_holder=' "$HOME_DIR/state/interrupted.treehouse-acquire/identity" "abort lost its acquisition holder"
  : > "$CASE_DIR/treehouse.log"
  : > "$CASE_DIR/mutations"
  out=$(spawn_task interrupted 2); rc=$?
  [ "$rc" -ne 0 ] || fail "a same-task retry bypassed its journal"
  # shellcheck disable=SC2016
  assert_contains "$out" 'treehouse return --if-lease-id "$lease_id" --if-lease-holder "$lease_holder" "$worktree"' "retry omitted guarded manual return"
  # shellcheck disable=SC2016
  assert_contains "$out" 'rm -f -- "$(dirname "$worktree")/.fm-slot-owner"' "retry omitted claim removal"
  # shellcheck disable=SC2016
  assert_contains "$out" 'rm -rf -- "$journal"' "retry omitted journal removal"
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

test_acquisition_journals_are_project_scoped() {
  local location shape out rc state journal journal_project
  for location in local registered; do
    for shape in foreign same unknown symlink non-directory; do
      make_case "journal-$location-$shape"
      state="$HOME_DIR/state"
      if [ "$location" = registered ]; then
        state="$CASE_DIR/mate/state"
        mkdir -p "$state" "$CASE_DIR/mate/data" "$CASE_DIR/mate/config"
        printf -- '- mate - fixture (home: %s; scope: test; projects: project; added 2026-01-01)\n' "$CASE_DIR/mate" > "$HOME_DIR/data/secondmates.md"
      fi
      journal="$state/pending.treehouse-acquire"
      journal_project=$PROJECT
      if [ "$shape" = foreign ]; then
        journal_project="$CASE_DIR/foreign"
        fm_git_init_commit "$journal_project"
      fi
      if [ "$shape" = non-directory ]; then
        : > "$journal"
      else
        mkdir "$journal"
        [ "$shape" = unknown ] || printf 'project=%s\n' "$journal_project" > "$journal/identity"
        printf '{' > "$journal/allocation.json"
        if [ "$shape" = symlink ]; then
          mv "$journal" "$CASE_DIR/journal-target"
          ln -s "$CASE_DIR/journal-target" "$journal"
        fi
      fi
      out=$(spawn_task candidate 1); rc=$?
      if [ "$shape" = foreign ]; then
        expect_code 0 "$rc" "an unrelated partial journal blocked spawn: $out"
        assert_present "$HOME_DIR/state/candidate.meta" "foreign journal prevented publication"
      else
        [ "$rc" -ne 0 ] || fail "$shape journal allowed allocation"
        assert_contains "$out" "$journal" "$shape refusal omitted the journal needing reconciliation"
        [ ! -s "$CASE_DIR/treehouse.log" ] && [ ! -s "$CASE_DIR/mutations" ] || fail "$shape journal reached allocation or endpoint mutation"
      fi
      [ -e "$journal" ] || fail "spawn removed $shape journal"
    done
  done
  pass "partial journals block their own project; unknown and unsafe journals diagnose refusal across local homes"
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
test_cleanup_rerun_after_released_lease_is_records_only
test_unsupported_cli_and_failed_acquisition_preserve_reservations
test_another_project_record_does_not_block_this_pool
test_separate_clones_share_the_origin_pool_reservation

test_acquisition_journals_are_project_scoped

test_legacy_unclaimed_ship_preserves_unlanded_work

test_missing_leased_copy_recovery_messages
test_unrecognized_leased_copy_refuses_publication
test_empty_record_fields_name_no_copy
