#!/usr/bin/env bash
# Away-session liveness: zero turns, one turn, and window lifecycle.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-afk-liveness)
LIVE="$ROOT/bin/fm-afk-liveness.sh"
ENTRY=1000
WINDOW=900

seed() {  # <dir> <actor>
  local dir=$1
  mkdir -p "$dir/state" "$dir/config"
  : > "$dir/config/supervision-host-off"
  printf 'actor: %s\nentry_epoch: %s\nwindow: %s\n' "$2" "$ENTRY" "$WINDOW" > "$dir/state/.afk-away-actor"
}

run_live() {  # <dir> <args...>
  local dir=$1
  shift
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_AFK_LIVENESS_WINDOW=$WINDOW "$@"
}

test_check_stays_silent_until_the_window_and_fires_once() {
  local dir out
  dir="$TMP_ROOT/zero"
  seed "$dir" host
  out=$(run_live "$dir" env FM_AFK_LIVENESS_NOW=$((ENTRY + WINDOW - 1)) "$LIVE" check)
  [ -z "$out" ] || fail "the check fired before the window: $out"
  out=$(run_live "$dir" env FM_AFK_LIVENESS_NOW=$((ENTRY + WINDOW)) "$LIVE" check) \
    || fail "the zero-turn check failed: $out"
  [ "$out" = 'no away session ran; main handled the window itself' ] \
    || fail "the zero-turn line was wrong: $out"
  out=$(run_live "$dir" env FM_AFK_LIVENESS_NOW=$((ENTRY + WINDOW + 10)) "$LIVE" check)
  [ -z "$out" ] || fail "the zero-turn line fired twice: $out"
  out=$(run_live "$dir" "$LIVE" health) || fail "health failed: $out"
  assert_contains "$out" 'away-session turns: 0' "health did not count zero turns"
  assert_contains "$out" 'no away session ran; main handled the window itself' "health omitted the zero-turn line"
  pass "a silent window wakes once and the return lines still name it"
}

test_one_away_turn_keeps_the_check_silent() {
  local dir out epoch
  dir="$TMP_ROOT/host-turn"
  seed "$dir" host
  printf '%s\tstart\tno posture\n' "$ENTRY" > "$dir/state/.supervision-host.log"
  out=$(run_live "$dir" env FM_AFK_LIVENESS_NOW=$((ENTRY + WINDOW)) "$LIVE" check)
  [ "$out" = 'no away session ran; main handled the window itself' ] \
    || fail "a host row without posture counted as an away turn: $out"
  rm -f "$dir/state/.afk-liveness-fired"
  printf '%s\thandled\tposture=away\n' "$ENTRY" > "$dir/state/.supervision-host.log"
  out=$(run_live "$dir" env FM_AFK_LIVENESS_NOW=$((ENTRY + WINDOW)) "$LIVE" check)
  [ -z "$out" ] || fail "one away host turn still fired: $out"
  out=$(run_live "$dir" "$LIVE" health)
  assert_contains "$out" 'away-session turns: 1' "health did not count the away turn"
  assert_not_contains "$out" 'no away session ran' "one turn still read as no session"

  dir="$TMP_ROOT/daemon-turn"
  seed "$dir" daemon
  epoch=1793836800
  printf 'actor: daemon\nentry_epoch: %s\nwindow: %s\n' "$epoch" "$WINDOW" > "$dir/state/.afk-away-actor"
  printf '[2026-11-05T00:00:01+0000] wake: heartbeat\n' > "$dir/state/.supervise-daemon.log"
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_AFK_LIVENESS_WINDOW=$WINDOW \
    FM_AFK_LIVENESS_NOW=$((epoch + WINDOW)) "$LIVE" check)
  [ -z "$out" ] || fail "a daemon heartbeat still fired the no-session line: $out"
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$LIVE" health)
  assert_contains "$out" 'away-session turns: 1' "a daemon heartbeat was not a turn"
  pass "one host or daemon turn keeps the no-session line silent"
}

test_arm_records_the_actor_and_disarm_drops_only_the_check() {
  local dir out home
  dir="$TMP_ROOT/arm"
  mkdir -p "$dir/state" "$dir/config"
  : > "$dir/config/supervision-host-off"
  printf 'mode: away\nentered_epoch: 1700000000\n' > "$dir/state/.afk-contract"
  home=$dir
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_TEST_SEAM=1 FM_TEST_HARNESS=claude "$LIVE" arm) || fail "arm failed: $out"
  assert_contains "$out" 'armed: state/fm-afk-liveness.check.sh' "arm did not name the check"
  assert_contains "$(cat "$dir/state/.afk-away-actor")" 'actor: daemon' "a host-off home was not recorded as the daemon"
  assert_contains "$(cat "$dir/state/.afk-away-actor")" 'entry_epoch: 1700000000' "arm did not keep the record entry"
  [ -f "$dir/state/fm-afk-liveness.check.sh" ] || fail "the check shim is missing"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$dir/state" "$LIVE" disarm) || fail "disarm failed: $out"
  [ ! -e "$dir/state/fm-afk-liveness.check.sh" ] || fail "disarm left the check shim"
  [ -f "$dir/state/.afk-away-actor" ] || fail "disarm removed the actor record"
  pass "arm records the actor and disarm removes only the check"
}

test_new_window_gets_new_wakes() {
  local dir out entry
  dir="$TMP_ROOT/windows"
  seed "$dir" daemon
  printf 'older-window:no-session\n' > "$dir/state/.afk-liveness-fired"
  for entry in 2000 3000; do
    printf 'mode: away\nentered_epoch: %s\n' "$entry" > "$dir/state/.afk-contract"
    out=$(run_live "$dir" env FM_TEST_HARNESS=claude "$LIVE" arm) || fail "new entry arm failed: $out"
    [ ! -e "$dir/state/.afk-liveness-fired" ] || fail "new entry retained the fired ledger"
    out=$(run_live "$dir" env FM_AFK_LIVENESS_NOW=$((entry + WINDOW)) "$LIVE" check)
    assert_contains "$out" 'no away session ran' "new window did not wake"
    [ -s "$dir/state/.afk-liveness-fired" ] || fail "check did not persist the wake"
    out=$(run_live "$dir" env FM_TEST_HARNESS=claude "$LIVE" arm) || fail "refresh failed: $out"
    [ -s "$dir/state/.afk-liveness-fired" ] || fail "same-entry refresh discarded the wake"
    out=$(run_live "$dir" env FM_AFK_LIVENESS_NOW=$((entry + WINDOW + 1)) "$LIVE" check)
    [ -z "$out" ] || fail "refreshed window fired twice: $out"
  done
  out=$(run_live "$dir" "$LIVE" disarm) || fail "disarm failed: $out"
  [ ! -e "$dir/state/.afk-liveness-fired" ] || fail "disarm retained the fired ledger"
  pass "new entries reset wake history, refreshes preserve it, and disarm removes it"
}

test_failed_receipts_are_not_turns() {
  local dir out actor
  for actor in host daemon branch; do
    dir="$TMP_ROOT/failed-$actor"
    seed "$dir" "$actor"
    printf '1001\tfailed\tposture=away\tjob\n' > "$dir/state/.supervision-host.log"
    printf '[1970-01-01T00:16:41+0000] %s\n' 'daemon starting' 'startup failed: job not found' 'wake: signal: job.status' 'inject failed: job' 'self-handle: signal: job.status -> job.status: working' 'escalate: signal: job.status -> job.status: failed' > "$dir/state/.supervise-daemon.log"
    out=$(run_live "$dir" env FM_AFK_LIVENESS_NOW=1900 "$LIVE" check)
    assert_contains "$out" 'no away session ran' "$actor counted a failure as a turn"
  done
  run_live "$dir" "$ROOT/bin/fm-afk-main-outcome.sh" --task job --summary handled >/dev/null || fail "main outcome failed"
  out=$(run_live "$dir" "$LIVE" health)
  assert_contains "$out" 'away-session turns: 0' "main outcome counted as branch turn"
  pass "failed receipts and main outcomes do not count as away turns"
}

test_daemon_offsets_and_full_log() {
  local dir out i
  dir="$TMP_ROOT/offsets"
  seed "$dir" daemon
  printf 'actor: daemon\nentry_epoch: 1709251200\nwindow: 900\n' > "$dir/state/.afk-away-actor"
  {
    printf '[2024-02-29T23:59:59+0000] wake: heartbeat\n'
    printf '[2024-03-01T01:00:00+0100] wake: heartbeat: scan\n'
    printf '[2024-02-29T19:00:00-0500] wake: heartbeat\n'
    printf '[2024-03-01T00:00:00+0000] wake force-self (FM_INJECT_SKIP): heartbeat\n'
    for ((i=0;i<1996;i++)); do
      printf '[2024-03-01T00:00:01+0000] inject failed: job\n'
    done
  } > "$dir/state/.supervise-daemon.log"
  mkdir -p "$dir/fakebin"
  printf '#!/bin/sh\nexit 99\n' > "$dir/fakebin/date"
  chmod +x "$dir/fakebin/date"
  out=$(PATH="$dir/fakebin:$PATH" run_live "$dir" "$LIVE" health)
  assert_contains "$out" 'away-session turns: 2' "offsets or leap day parsed incorrectly"
  out=$(PATH="$dir/fakebin:$PATH" run_live "$dir" env FM_AFK_LIVENESS_NOW=1709252100 "$LIVE" check)
  [ -z "$out" ] || fail "recorded daemon turns still triggered a no-session wake: $out"
  pass "full daemon log handles offsets and leap day without date subprocesses"
}

test_new_window_gets_new_wakes
test_failed_receipts_are_not_turns
test_daemon_offsets_and_full_log

test_check_stays_silent_until_the_window_and_fires_once
test_one_away_turn_keeps_the_check_silent
test_arm_records_the_actor_and_disarm_drops_only_the_check
