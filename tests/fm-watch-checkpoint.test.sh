#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

write_terminal_footer_case() {
  local home=$1 delivered=$2 fakebin key sig hash
  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  capture-pane) cat "$FM_HOME/state/pane.txt"; exit 0 ;;
  display-message) printf '\n'; exit 0 ;;
  list-windows)
    [ -n "${FM_FAKE_TMUX_WINDOW:-}" ] && printf '%s\n' "$FM_FAKE_TMUX_WINDOW"
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf 'window=test:fm-footer\nkind=ship\n' > "$home/state/footer.meta"
  printf 'done: PR https://example.test/pr/footer\n' > "$home/state/footer.status"
  sig=$(FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_wake_signal_sig "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state/footer.status")
  printf '%s' "$sig" > "$home/state/.seen-footer_status"
  printf 'finished, awaiting review\n⏱  16m | 12%% context\n' > "$home/state/pane.txt"
  key=test_fm-footer
  hash=$(printf '%s' $'finished, awaiting review\n⏱  15m | 12% context' | md5 -q)
  printf '%s' "$hash" > "$home/state/.hash-$key"
  printf '1\n' > "$home/state/.count-$key"
  if [ "$delivered" = 1 ]; then
    printf 'done: PR https://example.test/pr/footer' > "$home/state/.hb-surfaced-footer"
  fi
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

test_delivered_terminal_footer_checkpoint_is_quiet() {
  local home out status
  home=$(make_home terminal-footer-delivered)
  out="$home/out.txt"
  write_terminal_footer_case "$home" 1
  status=0
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_WINDOW=test:fm-footer \
    FM_POLL=0.2 FM_SIGNAL_GRACE=0.1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds 2 >"$out" 2>&1 || status=$?
  expect_code 124 "$status" "delivered changing-footer checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 2s" "quiet delivered checkpoint line missing"
  assert_absent "$home/state/.wake-queue" "delivered changing-footer checkpoint queued a wake"
  assert_absent "$home/state/.watch.lock/pid" "delivered changing-footer checkpoint left a lock"
  pass "delivered changing-footer state stays quiet through the Codex checkpoint"
}

test_undelivered_terminal_footer_checkpoint_wakes_once() {
  local home out status
  home=$(make_home terminal-footer-undelivered)
  out="$home/out.txt"
  write_terminal_footer_case "$home" 0
  status=0
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_WINDOW=test:fm-footer \
    FM_POLL=0.2 FM_SIGNAL_GRACE=0.1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds 8 >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "undelivered changing-footer checkpoint exit"
  [ "$(grep -c '^stale: test:fm-footer$' "$out")" -eq 1 ] \
    || fail "undelivered changing-footer checkpoint did not pass through exactly one stale wake: $(cat "$out")"
  pass "the first undelivered changing-footer state wakes the Codex checkpoint once"
}

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_delivered_terminal_footer_checkpoint_is_quiet
test_undelivered_terminal_footer_checkpoint_wakes_once
