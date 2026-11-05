#!/usr/bin/env bash
# Away-session liveness: zero turns, one turn, and an unhandled blocker.
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
  printf '[2026-11-05T00:00:01+0000] wake force-self (FM_INJECT_SKIP): heartbeat\n' > "$dir/state/.supervise-daemon.log"
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_AFK_LIVENESS_WINDOW=$WINDOW \
    FM_AFK_LIVENESS_NOW=$((epoch + WINDOW)) "$LIVE" check)
  [ -z "$out" ] || fail "a daemon heartbeat still fired the no-session line: $out"
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$LIVE" health)
  assert_contains "$out" 'away-session turns: 1' "a daemon heartbeat was not a turn"
  pass "one host or daemon turn keeps the no-session line silent"
}

test_old_unhandled_blocker_wakes_once_and_a_fresh_one_waits() {
  local dir out
  dir="$TMP_ROOT/blocked"
  seed "$dir" host
  printf 'window=synthetic:old-job\nbackend=tmux\nkind=ship\n' > "$dir/state/old-job.meta"
  printf 'blocked [at=%s] [key=dep]: waiting on the feed\n' "$ENTRY" > "$dir/state/old-job.status"
  printf 'window=synthetic:new-job\nbackend=tmux\nkind=ship\n' > "$dir/state/new-job.meta"
  printf 'blocked [at=%s] [key=fresh]: just opened\n' "$((ENTRY + WINDOW))" > "$dir/state/new-job.status"
  printf 'window=synthetic:job-extra\nbackend=tmux\nkind=ship\n' > "$dir/state/job-extra.meta"
  printf 'blocked [at=%s] [key=other]: named only as a longer id\n' "$ENTRY" > "$dir/state/job-extra.status"
  printf '%s\thandled\tjob-extra-more\tposture=away\n' "$((ENTRY + 1))" > "$dir/state/.supervision-host.log"
  out=$(run_live "$dir" env FM_AFK_LIVENESS_NOW=$((ENTRY + WINDOW)) "$LIVE" check) \
    || fail "the blocker check failed: $out"
  assert_contains "$out" 'old-job [key=dep] has had no away handling and no hand-back' "the old blocker was not named"
  assert_not_contains "$out" 'new-job' "a blocker inside the window was named"
  assert_contains "$out" 'job-extra [key=other] has had no away handling and no hand-back' "a longer id was treated as handled"
  out=$(run_live "$dir" env FM_AFK_LIVENESS_NOW=$((ENTRY + WINDOW + 5)) "$LIVE" check)
  assert_not_contains "$out" 'old-job' "the old blocker woke twice: $out"
  printf '%s\thandled\told-job\tposture=away\n' "$((ENTRY + 2))" >> "$dir/state/.supervision-host.log"
  rm -f "$dir/state/.afk-liveness-fired"
  out=$(run_live "$dir" env FM_AFK_LIVENESS_NOW=$((ENTRY + WINDOW + 5)) "$LIVE" unhandled)
  assert_not_contains "$out" 'old-job' "a later host line that names the task did not count as handling: $out"
  assert_contains "$out" $'job-extra\tother' "an unhandled blocker disappeared from the return list"
  assert_not_contains "$out" 'new-job' "return tagged a blocker before its window"
  out=$(run_live "$dir" env FM_AFK_LIVENESS_NOW=$((ENTRY + 2 * WINDOW - 1)) "$LIVE" unhandled)
  assert_not_contains "$out" 'new-job' "return tagged a blocker one second early"
  out=$(run_live "$dir" env FM_AFK_LIVENESS_NOW=$((ENTRY + 2 * WINDOW)) "$LIVE" unhandled)
  assert_contains "$out" $'new-job\tfresh' "return omitted a blocker at the window boundary"
  out=$(run_live "$dir" env FM_AFK_LIVENESS_NOW=$((ENTRY + 2 * WINDOW)) "$LIVE" check)
  assert_contains "$out" 'new-job [key=fresh]' "check disagreed with return at the window boundary"
  pass "check and return use the same blocker window"

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
  local dir out
  dir="$TMP_ROOT/windows"
  seed "$dir" host
  printf 'kind=ship\n' > "$dir/state/job.meta"
  printf 'blocked [at=1000] [key=dep]: waiting\n' > "$dir/state/job.status"
  out=$(run_live "$dir" env FM_AFK_LIVENESS_NOW=1900 "$LIVE" check)
  assert_contains "$out" 'no away session ran' "first window did not wake"
  assert_contains "$out" 'job [key=dep]' "first blocker did not wake"
  printf 'actor: host\nentry_epoch: 2000\nwindow: 900\n' > "$dir/state/.afk-away-actor"
  out=$(run_live "$dir" env FM_AFK_LIVENESS_NOW=2900 "$LIVE" check)
  assert_contains "$out" 'no away session ran' "second window inherited no-session suppression"
  assert_contains "$out" 'job [key=dep]' "second window inherited blocker suppression"
  out=$(run_live "$dir" env FM_AFK_LIVENESS_NOW=2901 "$LIVE" check)
  [ -z "$out" ] || fail "second window fired twice: $out"
  pass "each window gets its own no-session and blocker wakes"
}

test_failed_receipts_are_not_handling() {
  local dir out actor
  for actor in host daemon branch; do
    dir="$TMP_ROOT/failed-$actor"
    seed "$dir" "$actor"
    printf 'kind=ship\n' > "$dir/state/job.meta"
    printf 'blocked [at=1000] [key=dep]: waiting\n' > "$dir/state/job.status"
    printf '1001\tfailed\tposture=away\tjob\n' > "$dir/state/.supervision-host.log"
    printf '[1970-01-01T00:16:41+0000] %s\n' 'daemon starting' 'startup failed: job not found' 'wake: signal: job.status' 'inject failed: job' > "$dir/state/.supervise-daemon.log"
    out=$(run_live "$dir" env FM_AFK_LIVENESS_NOW=1900 "$LIVE" check)
    assert_contains "$out" 'no away session ran' "$actor counted a failure as a turn"
    assert_contains "$out" 'job [key=dep]' "$actor counted a receipt as handling"
  done
  run_live "$dir" "$ROOT/bin/fm-afk-main-outcome.sh" --task job --summary handled >/dev/null || fail "main outcome failed"
  out=$(run_live "$dir" "$LIVE" health)
  assert_contains "$out" 'away-session turns: 0' "main outcome counted as branch turn"
  out=$(run_live "$dir" "$LIVE" unhandled)
  [ -z "$out" ] || fail "main handling failed to clear the blocker evidence"
  pass "failed receipts do not establish handling and main does not count as branch"
}

test_daemon_offsets_and_full_log() {
  local dir out i
  dir="$TMP_ROOT/offsets"
  seed "$dir" daemon
  printf 'actor: daemon\nentry_epoch: 1709251200\nwindow: 900\n' > "$dir/state/.afk-away-actor"
  printf 'kind=ship\n' > "$dir/state/job.meta"
  printf 'blocked [at=1709251200] [key=dep]: waiting\n' > "$dir/state/job.status"
  {
    printf '[2024-02-29T23:59:59+0000] self-handle: job\n'
    printf '[2024-03-01T01:00:00+0100] self-handle: signal: /home/fleet/state/job.status -> job.status: working: building\n'
    printf '[2024-02-29T19:00:00-0500] wake force-self (FM_INJECT_SKIP): heartbeat\n'
    for ((i=0;i<1997;i++)); do
      printf '[2024-03-01T00:00:01+0000] inject failed: job\n'
    done
  } > "$dir/state/.supervise-daemon.log"
  mkdir -p "$dir/fakebin"
  printf '#!/bin/sh\nexit 99\n' > "$dir/fakebin/date"
  chmod +x "$dir/fakebin/date"
  out=$(PATH="$dir/fakebin:$PATH" run_live "$dir" "$LIVE" health)
  assert_contains "$out" 'away-session turns: 2' "offsets or leap day parsed incorrectly"
  out=$(PATH="$dir/fakebin:$PATH" run_live "$dir" env FM_AFK_LIVENESS_NOW=1709252100 "$LIVE" check)
  assert_contains "$out" 'job [key=dep]' "unrelated progress hid the open blocker"
  pass "full daemon log handles offsets and leap day without date subprocesses"
}

test_daemon_status_names_and_escalations() {
  local dir out action name command
  for action in self-handle 'self-handle (paused)' escalate; do
    for name in job.status /home/fleet/state/job.status; do
      dir="$TMP_ROOT/daemon-shapes"
      seed "$dir" daemon
      printf 'kind=ship\n' > "$dir/state/job.meta"
      printf 'blocked [at=1000] [key=dep]: waiting\n' > "$dir/state/job.status"
      printf '[1970-01-01T00:16:41+0000] %s: signal: %s -> %s: blocked [key=dep]: waiting\n' "$action" "$name" "$name" > "$dir/state/.supervise-daemon.log"
      rm -f "$dir/state/.afk-liveness-fired"
      for command in check unhandled; do
        out=$(run_live "$dir" env FM_AFK_LIVENESS_NOW=1900 "$LIVE" "$command")
        [ -z "$out" ] || fail "$command missed $action for $name: $out"
      done
    done
  done
  for name in job-extra.status other-job.status job.status.old job.status-more jobjob.status; do
    printf '[1970-01-01T00:16:41+0000] escalate: signal: /home/fleet/state/%s -> %s: blocked\n' "$name" "$name" > "$dir/state/.supervise-daemon.log"
    out=$(run_live "$dir" env FM_AFK_LIVENESS_NOW=1900 "$LIVE" unhandled)
    assert_contains "$out" $'job\tdep' "a different status name $name counted as job"
  done
  printf '[1970-01-01T00:16:39+0000] escalate: signal: job.status -> job.status: blocked\n' > "$dir/state/.supervise-daemon.log"
  out=$(run_live "$dir" env FM_AFK_LIVENESS_NOW=1900 "$LIVE" unhandled)
  assert_contains "$out" $'job\tdep' "an older escalation handled the new blocker"
  pass "daemon handling and escalations recognize exact status basenames and paths"
}

test_preentry_blocker_gets_a_full_window() {
  local dir out command
  dir="$TMP_ROOT/preentry"
  seed "$dir" host
  printf 'kind=ship\n' > "$dir/state/job.meta"
  printf 'blocked [at=100] [key=dep]: waiting\n' > "$dir/state/job.status"
  for command in check unhandled; do
    out=$(run_live "$dir" env FM_AFK_LIVENESS_NOW=$((ENTRY + WINDOW - 1)) "$LIVE" "$command")
    [ -z "$out" ] || fail "$command reported a pre-entry blocker early: $out"
    [ ! -e "$dir/state/.afk-liveness-fired" ] || fail "early check spent the wake"
  done
  out=$(run_live "$dir" env FM_AFK_LIVENESS_NOW=$((ENTRY + WINDOW)) "$LIVE" check)
  assert_contains "$out" 'job [key=dep]' "pre-entry blocker missed its due wake"
  out=$(run_live "$dir" env FM_AFK_LIVENESS_NOW=$((ENTRY + WINDOW)) "$LIVE" unhandled)
  assert_contains "$out" $'job\tdep' "pre-entry blocker missed its due return tag"
  out=$(run_live "$dir" env FM_AFK_LIVENESS_NOW=$((ENTRY + WINDOW + 1)) "$LIVE" check)
  [ -z "$out" ] || fail "due blocker woke twice: $out"
  pass "pre-entry blockers receive a full away window before either report"
}

test_daemon_self_handling_requires_the_open_key() {
  local dir out message command
  dir="$TMP_ROOT/keyed-handling"
  seed "$dir" daemon
  printf 'kind=ship\n' > "$dir/state/job.meta"
  printf 'blocked [at=100] [key=dep]: waiting\nworking: retrying\n' > "$dir/state/job.status"
  for message in \
    'self-handle: signal: /state/job.status -> job.status: working: building' \
    'self-handle: stale: window:job -> stale + terminal (already escalated by signal)' \
    'self-handle (paused): stale: window:job -> declared wait' \
    'self-handle: signal: job.status -> job.status: blocked [key=dep-other]: waiting' \
    'self-handle: signal: job.status -> job.status: blocked [key=other-dep]: waiting'; do
    printf '[1970-01-01T00:01:41+0000] escalate: signal: job.status -> job.status: blocked [key=dep]\n[1970-01-01T00:16:41+0000] %s\n' "$message" > "$dir/state/.supervise-daemon.log"
    rm -f "$dir/state/.afk-liveness-fired"
    for command in check unhandled; do
      out=$(run_live "$dir" env FM_AFK_LIVENESS_NOW=1900 "$LIVE" "$command")
      assert_contains "$out" 'job' "$command treated unrelated self-handling as blocker handling: $message"
    done
  done
  for message in \
    'self-handle: stale: window:job -> blocked [key=dep]: waiting' \
    'self-handle (paused): stale: window:job -> blocked [key=dep]: waiting' \
    'escalate: signal: /state/job.status -> job.status: blocked: waiting'; do
    printf '[1970-01-01T00:16:41+0000] %s\n' "$message" > "$dir/state/.supervise-daemon.log"
    rm -f "$dir/state/.afk-liveness-fired"
    for command in check unhandled; do
      out=$(run_live "$dir" env FM_AFK_LIVENESS_NOW=1900 "$LIVE" "$command")
      [ -z "$out" ] || fail "$command missed keyed handling or hand-back: $message: $out"
    done
  done
  pass "daemon self-handling requires the exact open key while escalations count as hand-back"
}

test_preentry_blocker_gets_a_full_window
test_daemon_self_handling_requires_the_open_key

test_daemon_status_names_and_escalations

test_new_window_gets_new_wakes
test_failed_receipts_are_not_handling
test_daemon_offsets_and_full_log

test_check_stays_silent_until_the_window_and_fires_once
test_one_away_turn_keeps_the_check_silent
test_old_unhandled_blocker_wakes_once_and_a_fresh_one_waits
test_arm_records_the_actor_and_disarm_drops_only_the_check
