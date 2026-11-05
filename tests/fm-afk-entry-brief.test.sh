#!/usr/bin/env bash
# Entry inventory, read-back checklist, and future-date registration.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-afk-entry-brief)
BRIEF="$ROOT/bin/fm-afk-entry-brief.sh"
LAUNCH="$ROOT/bin/fm-afk-launch.sh"
TODAY=2026-11-05

seed_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state" "$dir/data" "$dir/config"
  fm_test_tasks_toml "$dir/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
}

axi() {  # <dir> <args...>
  local dir=$1
  shift
  (cd "$dir" && tasks-axi "$@" --file data/backlog.md)
}

meta() {  # <dir> <id> <status-text>
  local dir=$1 id=$2
  printf 'window=synthetic:%s\nbackend=tmux\nkind=ship\n' "$id" > "$dir/state/$id.meta"
  printf '%s\n' "$3" > "$dir/state/$id.status"
}

snap() {  # <dir>
  (cd "$1" && find state data -printf '%P %s\n' | sort)
}

test_inventory_lists_live_held_cleared_green_dates_and_the_stop_point() {
  local dir out ids
  dir="$TMP_ROOT/inventory"
  seed_home "$dir"
  axi "$dir" add done-job 'finished work' >/dev/null
  axi "$dir" add queued-job 'start after the blocker' >/dev/null
  axi "$dir" add hold-a 'first hold' >/dev/null
  axi "$dir" add hold-b 'second hold' >/dev/null
  axi "$dir" add dated-job 'a passed date' >/dev/null
  axi "$dir" add future-job 'a future date' >/dev/null
  axi "$dir" add retired-job 'completed dependency follower' >/dev/null
  axi "$dir" block retired-job --by done-job >/dev/null
  axi "$dir" block queued-job --by done-job >/dev/null
  axi "$dir" "done" done-job --note 'landed' >/dev/null
  axi "$dir" "done" retired-job --note 'landed' >/dev/null
  axi "$dir" update retired-job --body 'Next: bin/fm-send.sh retired-job obsolete' >/dev/null
  axi "$dir" update done-job --body 'Next: bin/fm-send.sh done-job the follow-up' >/dev/null
  axi "$dir" hold hold-a --reason 'wait for captain' --kind captain >/dev/null
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    bash "$ROOT/bin/fm-captain-hold.sh" hold hold-b --reason 'Choose the public name' >/dev/null \
    || fail "the captain hold command failed"
  axi "$dir" hold dated-job --reason 'the date passed' --kind future --until 2026-11-01 >/dev/null
  axi "$dir" hold future-job --reason 'later' --kind future --until 2026-12-01 >/dev/null
  meta "$dir" paused-job 'paused: waiting on the suite'
  meta "$dir" running-job 'working: building'
  meta "$dir" done-job $'done: https://github.com/example/repo/pull/9 checks green'
  meta "$dir" stuck-job $'failed: one\nfailed check: two\ncheck failed: three'
  meta "$dir" blocked-job 'blocked [at=100] [key=stuck]: still waiting'
  printf 'window=synthetic:mate\nbackend=tmux\nkind=secondmate\n' > "$dir/state/mate.meta"
  printf 'working: persistent\n' > "$dir/state/mate.status"

  before=$(snap "$dir")
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_AFK_ENTRY_TODAY=$TODAY "$BRIEF") || fail "inventory exited nonzero: $out"
  after=$(snap "$dir")
  [ "$before" = "$after" ] || fail "inventory wrote state or backlog bytes"

  assert_contains "$out" '  paused-job: paused' "the paused live task was missing"
  assert_contains "$out" '  running-job: working' "the running live task was missing"
  assert_contains "$out" '  done-job: done; next: bin/fm-send.sh done-job the follow-up' "the done task lost its next command"
  assert_contains "$out" '  hold-a: wait for captain' "the first hold was missing"
  assert_contains "$out" '  hold-b: Choose the public name' "the captain hold reason was not decoded"
  assert_contains "$out" '  queued-job: blocked-by done-job is done' "a cleared blocker was not listed"
  assert_contains "$out" '  done-job: https://github.com/example/repo/pull/9' "the green pull request was missing"
  assert_contains "$out" '  dated-job: hold until 2026-11-01' "a passed hold date was missing"
  assert_contains "$out" '  future-job: hold until 2026-12-01; bin/fm-afk-entry-brief.sh --register-future future-job' "a future date was not offered"
  assert_contains "$out" '  stuck-job: 3 consecutive failed checks' "three failed checks were not the stop point"
  assert_contains "$out" 'Read-back checklist:' "the read-back checklist was missing"
  assert_contains "$out" 'Name every green pull request and the exact sentence that would permit its merge, or say that "no merges" is a valid reading.' "the merge sentence was missing"
  assert_contains "$out" 'A named merge still waits while a slower advisory suite has not reported.' "the slower-suite sentence was missing"
  assert_contains "$out" 'Name any sentence dropped when /afk is sent again with only a stop clause.' "the dropped-sentence line was missing"
  assert_contains "$out" 'Name any job the inventory shows with 3 or more consecutive failed checks on the same findings, and park that job.' "the stop-point sentence was missing"
  assert_not_contains "$out" 'retired-job:' "completed backlog item appeared as pending"
  assert_not_contains "$out" 'mate:'  "a secondmate was listed as live work"
  [ ! -e "$dir/state/fm-afk-future-future-job.check.sh" ] || fail "inventory registered a future check"

  ids=$(printf '%s\n' "$out" | sed -n 's/^  \([a-z0-9-]*\):.*/\1/p' | tr '\n' ' ')
  case "$ids" in
    *'blocked-job '*'done-job '*'paused-job '*'running-job '*'stuck-job '*'hold-a '*'hold-b '*'queued-job '*'done-job '*'dated-job '*'future-job '*'stuck-job '*) ;;
    *) fail "sections were not in inventory order: $ids" ;;
  esac

  meta "$dir" green-done 'done: https://github.com/example/repo/pull/10 checks green'
  meta "$dir" landed-done 'done: landed, awaiting cleanup'
  meta "$dir" explicit-done $'done: finished\nNext: bin/fm-teardown.sh explicit-done'
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_AFK_ENTRY_TODAY=$TODAY "$BRIEF" not-started) || fail "not-started exited nonzero: $out"
  assert_not_contains "$out" 'bin/fm-tasks-axi.sh show hold-a' "a held row with no next command was repeated"
  assert_not_contains "$out" 'bin/fm-tasks-axi.sh show hold-b' "a held row with no next command was repeated"
  assert_contains "$out" '  - done-job: bin/fm-send.sh done-job the follow-up' "a done task lost the recorded next command"
  assert_not_contains "$out" 'green-done' "green finished work acquired an invented next command"
  assert_not_contains "$out" 'landed-done' "landed work acquired an invented next command"
  assert_contains "$out" '  - explicit-done: bin/fm-teardown.sh explicit-done' "finished work lost its explicit status next command"
  assert_not_contains "$out" 'retired-job' "completed backlog item appeared as not started"
  assert_not_contains "$out" 'blocked-job'  "an open blocked task was listed as not started"
  assert_not_contains "$out" 'paused-job' "a paused task with no next step was listed as not started"
  assert_not_contains "$out" 'running-job' "a working task with no next step was listed as not started"
  pass "entry inventory lists every gate and leaves the home unchanged"
}

test_unreadable_backlog_exits_zero_without_creating_one() {
  local dir out before after
  dir="$TMP_ROOT/unreadable"
  seed_home "$dir"
  printf 'keep\n' > "$dir/data/backlog.md"
  before=$(sha256sum "$dir/data/backlog.md" | awk '{print $1}')
  chmod 000 "$dir/data/backlog.md"
  set +e
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_AFK_ENTRY_TODAY=$TODAY "$BRIEF" 2>&1)
  local rc=$?
  set -e
  chmod 644 "$dir/data/backlog.md" || true
  [ "$rc" -eq 0 ] || fail "an unreadable backlog did not exit 0 (rc=$rc): $out"
  assert_contains "$out" 'entry inventory: backlog file is unreadable' "the unreadable backlog was not reported"
  after=$(sha256sum "$dir/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "the unreadable backlog was rewritten"
  pass "an unreadable backlog is reported and left untouched"
}

test_future_date_registers_once_and_a_passed_date_does_not() {
  local dir out
  dir="$TMP_ROOT/future"
  seed_home "$dir"
  axi "$dir" add future-job 'later' >/dev/null
  axi "$dir" add dated-job 'passed' >/dev/null
  axi "$dir" hold future-job --reason 'later' --kind future --until 2026-12-01 >/dev/null
  axi "$dir" hold dated-job --reason 'passed' --kind future --until 2026-11-01 >/dev/null

  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_AFK_ENTRY_TODAY=$TODAY "$BRIEF" --register-future dated-job) \
    || fail "registering an already-due date failed: $out"
  assert_contains "$out" 'dated-job hold until 2026-11-01 is already due' "an already-due date was not named"
  [ ! -e "$dir/state/fm-afk-future-dated-job.check.sh" ] || fail "an already-due date was registered"

  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_AFK_ENTRY_TODAY=$TODAY "$BRIEF" --register-future future-job) \
    || fail "registering a future date failed: $out"
  assert_contains "$out" 'registered: state/fm-afk-future-future-job.check.sh' "the future check was not registered"
  [ -f "$dir/state/fm-afk-future-future-job.check.sh" ] || fail "the future check shim is missing"
  [ "$(stat -c %a "$dir/state/fm-afk-future-future-job.check.sh")" = 700 ] || fail "the future check shim is not mode 700"
  [ -z "$(find "$dir/state" -name '*.status' -o -name '*.seen*' -o -name '.seen*' | head -1)" ] \
    || fail "future registration wrote a status or seen marker"

  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_AFK_ENTRY_TODAY=$TODAY "$BRIEF" future-check future-job)
  [ -z "$out" ] || fail "a future check fired before its date: $out"
  [ ! -e "$dir/state/.afk-future-fired" ] || fail "an early future check recorded a firing"

  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_AFK_ENTRY_TODAY=2026-12-01 "$BRIEF" future-check future-job) \
    || fail "a due future check failed: $out"
  assert_contains "$out" 'future-job hold until 2026-12-01 is due' "a due future check stayed silent"
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_AFK_ENTRY_TODAY=2026-12-02 "$BRIEF" future-check future-job)
  [ -z "$out" ] || fail "a future check fired twice: $out"
  pass "a future date registers one check and a passed date does not"
}

test_not_started_reports_an_unreadable_backlog_on_stdout() {
  local dir out rc
  dir="$TMP_ROOT/unreadable-not-started"
  seed_home "$dir"
  meta "$dir" live-job 'working: building'
  chmod 000 "$dir/data/backlog.md"
  set +e
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_AFK_ENTRY_TODAY=$TODAY "$BRIEF" not-started 2>/dev/null)
  rc=$?
  set -e
  chmod 644 "$dir/data/backlog.md" || true
  [ "$rc" -eq 0 ] || fail "not-started did not exit 0 when the backlog was unreadable (rc=$rc): $out"
  assert_contains "$out" 'backlog file is unreadable' "not-started hid the unreadable-backlog diagnostic"
  assert_not_contains "$out" '(nothing)' "not-started claimed nothing was pending while the backlog could not be read"
  pass "not-started reports an unreadable backlog on stdout"
}

test_redeferred_future_date_fires_when_it_comes_due() {
  local dir out
  dir="$TMP_ROOT/redefer"
  seed_home "$dir"
  axi "$dir" add job-x 'a deferred job' >/dev/null
  axi "$dir" hold job-x --reason 'later' --kind future --until 2026-12-01 >/dev/null

  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_AFK_ENTRY_TODAY=$TODAY "$BRIEF" --register-future job-x) \
    || fail "the first future registration failed: $out"
  assert_contains "$out" 'registered: state/fm-afk-future-job-x.check.sh' "the first future check was not registered"
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_AFK_ENTRY_TODAY=2026-12-02 "$BRIEF" future-check job-x) \
    || fail "the first due check failed: $out"
  assert_contains "$out" 'job-x hold until 2026-12-01 is due' "the first due date stayed silent"
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_AFK_ENTRY_TODAY=2026-12-02 "$BRIEF" future-check job-x)
  [ -z "$out" ] || fail "the same due date fired twice: $out"

  axi "$dir" hold job-x --reason 'later again' --kind future --until 2027-01-01 >/dev/null
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_AFK_ENTRY_TODAY=2026-12-02 "$BRIEF" --register-future job-x) \
    || fail "re-registering the new date failed: $out"
  assert_contains "$out" 'registered: state/fm-afk-future-job-x.check.sh' "the re-deferred date was not registered"
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_AFK_ENTRY_TODAY=2027-01-02 "$BRIEF" future-check job-x) \
    || fail "the re-deferred due check failed: $out"
  assert_contains "$out" 'job-x hold until 2027-01-01 is due' "a re-deferred hold date never fired"
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_AFK_ENTRY_TODAY=2027-01-02 "$BRIEF" future-check job-x)
  [ -z "$out" ] || fail "the re-deferred date fired twice: $out"
  pass "a re-deferred future date fires once when it comes due"
}

test_inventory_reads_the_backlog_once() {
  local dir out log real wrap list_n show_n
  dir="$TMP_ROOT/one-read"
  seed_home "$dir"
  axi "$dir" add hold-a 'first hold' >/dev/null
  axi "$dir" add hold-b 'second hold' >/dev/null
  axi "$dir" add done-job 'finished work' >/dev/null
  axi "$dir" hold hold-a --reason 'wait for captain' --kind captain >/dev/null
  axi "$dir" update done-job --body 'Next: bin/fm-send.sh done-job the follow-up' >/dev/null
  axi "$dir" "done" done-job --note 'landed' >/dev/null
  meta "$dir" done-job 'done: finished'
  log="$dir/axi.log"
  : > "$log"
  real=$(command -v tasks-axi)
  wrap="$dir/wrap"
  mkdir -p "$wrap"
  cat > "$wrap/tasks-axi" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> $(printf '%q' "$log")
exec $(printf '%q' "$real") "\$@"
EOF
  chmod +x "$wrap/tasks-axi"

  out=$(PATH="$wrap:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_AFK_ENTRY_TODAY=$TODAY "$BRIEF") || fail "inventory exited nonzero: $out"
  assert_contains "$out" '  hold-a: wait for captain' "the single backlog read dropped a hold"
  assert_contains "$out" '  done-job: done; next: bin/fm-send.sh done-job the follow-up' "the single backlog read dropped a next command"
  list_n=$(grep -c '^list ' "$log" || true)
  show_n=$(grep -c '^show ' "$log" || true)
  [ "$list_n" -eq 1 ] || fail "inventory made $list_n backlog list calls, expected 1: $(cat "$log")"
  [ "$show_n" -eq 0 ] || fail "inventory made $show_n per-row backlog reads: $(cat "$log")"

  : > "$log"
  out=$(PATH="$wrap:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_AFK_ENTRY_TODAY=$TODAY "$BRIEF" not-started) || fail "not-started exited nonzero: $out"
  assert_contains "$out" '  - done-job: bin/fm-send.sh done-job the follow-up' "not-started dropped the next command"
  assert_not_contains "$out" 'bin/fm-tasks-axi.sh show hold-a' "not-started repeated a held row"
  list_n=$(grep -c '^list ' "$log" || true)
  show_n=$(grep -c '^show ' "$log" || true)
  [ "$list_n" -eq 1 ] || fail "not-started made $list_n backlog list calls, expected 1: $(cat "$log")"
  [ "$show_n" -eq 0 ] || fail "not-started made $show_n per-row backlog reads: $(cat "$log")"
  pass "entry inventory and not-started each read the backlog once"
}

test_enter_prints_live_ids_and_quiet_omits_inventory() {
  local dir out off
  dir="$TMP_ROOT/enter"
  seed_home "$dir"
  meta "$dir" paused-job 'paused: waiting on the suite'
  meta "$dir" running-job 'working: building'
  off=$(mktemp -d "$TMP_ROOT/off.XXXXXX")
  : > "$off/supervision-host-off"
  printf 'watch the fleet\n' > "$dir/words"
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$off" \
    CLAUDECODE=1 FM_TEST_HARNESS=claude FM_TEST_SEAM=1 \
    "$LAUNCH" enter --words-file "$dir/words" 2>&1) || fail "away enter failed: $out"
  assert_contains "$out" 'paused-job' "enter did not print a live task"
  assert_contains "$out" 'running-job' "enter did not print every live task"
  assert_contains "$out" 'Read-back checklist:' "enter did not print the checklist"

  dir="$TMP_ROOT/quiet"
  seed_home "$dir"
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$off" \
    FM_AFK_MODE=quiet CLAUDECODE=1 FM_TEST_HARNESS=claude FM_TEST_SEAM=1 \
    "$LAUNCH" enter --words 'stay quiet' 2>&1) || fail "quiet enter failed: $out"
  assert_not_contains "$out" 'Read-back checklist:' "quiet enter printed the away checklist"
  pass "away enter prints the inventory and quiet enter omits it"
}

test_not_started_reports_an_unreadable_backlog_on_stdout
test_redeferred_future_date_fires_when_it_comes_due
test_inventory_reads_the_backlog_once
test_inventory_lists_live_held_cleared_green_dates_and_the_stop_point
test_unreadable_backlog_exits_zero_without_creating_one
test_future_date_registers_once_and_a_passed_date_does_not
test_enter_prints_live_ids_and_quiet_omits_inventory
