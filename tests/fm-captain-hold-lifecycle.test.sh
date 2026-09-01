#!/usr/bin/env bash
# End-to-end tests for captain-held tasks: the one primitive behind "a decision
# is simply a task waiting on the captain", its completion gate, its recorded
# answers, the record-divergence guard over its two records, and the legacy
# compatibility for pre-collapse decision identities.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-hold)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

# The Lavish review adapter, run against this suite's isolated home. The
# machine-wide process-event claim root is redirected into the fixture so arming
# a review here can never contend with a real one on this machine.
run_lavish() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" "$@"
}

run_bearings() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-14T12:00:00Z \
    "$BEARINGS" --json
}

run_teardown() {  # <home> <id>
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_captain() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

# The retired command surface, kept for one release as a shim; in-flight
# pre-collapse work still drives the lifecycle through these spellings.
run_shim() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-decision-hold.sh" "$@"
}

write_origin_meta() {  # <home> <id> [kind]
  local home=$1 id=$2 kind=${3:-scout}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$kind" \
    "spawn_gen=fixture-$id"
}

# Reproduces the loss exactly with privacy-safe synthetic names: the investigation
# and visual review have ended, the only genuine unresolved captain call is report
# prose, no held backlog item or open status exists, and the authoritative
# Bearings view correctly omits it. Completion must now refuse before teardown can
# erase the source.
test_uninventoried_report_decision_refuses_completion() {
  local home id json rc
  home=$(make_home omitted-decision)
  id=sample-route-review
  mkdir -p "$home/data/$id"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $id - Investigate sample routing (repo: sample) (kind: scout) (since 2026-07-14)

## Queued

## Done
EOF
  write_origin_meta "$home" "$id"
  printf 'done: report and visual review complete\n' > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample route review

The evidence is complete.
The captain still needs to choose route north or route south before follow-up work starts.
EOF

  json=$(run_bearings "$home") || fail "Bearings failed for unresolved-call regression"
  printf '%s' "$json" | jq -e '
    (.decisions_open | length) == 0
      and (.gates | length) == 0
      and (.reports | any(.id == "sample-route-review"))
  ' >/dev/null || fail "the pre-policy omission shape was not reproduced: $json"

  set +e
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completed investigation teardown erased a report-only unresolved captain call"
  assert_present "$home/state/$id.meta" "refused completion must preserve investigation metadata"
  assert_grep "REFUSED" "$home/teardown.err" "refusal must be explicit"
  pass "report-only unresolved captain call is reproduced and completion refuses before loss"
}

# The completion gate on the collapsed primitive: an origin with open keyed
# status decisions refuses --none, refuses an inventory naming absent tasks,
# attests a verified inventory of captain-held task ids, and transfers every
# still-open status decision to that durable inventory.
test_completion_gate_attests_and_transfers() {
  local home id json open before after
  home=$(make_home completion-gate)
  id=sample-systems-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create investigation backlog fixture"
  write_origin_meta "$home" "$id"
  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=route]: choose route north or route south
needs-decision [key=access]: choose open or restricted sample access
EOF
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample systems review

Two choices remain unresolved: the route and the sample access level.
A separate recommendation is already resolved and requires no captain action.
EOF

  if run_captain "$home" complete "$id" --none > "$home/none.out" 2> "$home/none.err"; then
    fail "--none attested while captain calls were still open in the status stream"
  fi
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "failed completion recorded a false completion attestation"
  if run_captain "$home" complete "$id" sample-route-call > "$home/absent.out" 2> "$home/absent.err"; then
    fail "completion accepted an inventory entry that names no task"
  fi

  run_captain "$home" hold sample-route-call \
    --title "Choose route: north, south" --reason "captain route and access choices pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" hold sample-route-call \
    --title "Choose route: north, south" --reason "captain route and access choices pending" \
    --repo sample >/dev/null \
    || fail "idempotent hold retry failed"
  [ "$(grep -cE "^- \[ \] sample-route-call -" "$home/data/backlog.md")" = 1 ] \
    || fail "idempotent retry duplicated the captain-held task"
  if run_captain "$home" hold sample-route-call --title "A different title" \
    --reason "captain route and access choices pending" > "$home/title.out" 2> "$home/title.err"; then
    fail "hold accepted a changed title on an existing task"
  fi

  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/$id.status" \
    || fail "could not prime the announced decision baseline"
  run_captain "$home" complete "$id" sample-route-call >/dev/null \
    || fail "shared investigation completion gate failed"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/$id.status" \
    || fail "captain-held bookkeeping closes re-woke their own home"
  assert_grep "decisions_reviewed=1" "$home/state/$id.meta" "completion attestation missing"
  assert_grep "decision_keys=sample-route-call" "$home/state/$id.meta" "inventory was not recorded as task ids"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  [ -z "$open" ] || fail "captain-held transfer did not close the live status decisions: $open"
  grep -F 'captain-held [key=route]: tracked by sample-route-call' "$home/state/$id.status" >/dev/null \
    || fail "the transfer line does not name the tracking inventory"

  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  json=$(run_bearings "$home") || fail "Bearings failed with a captain-held task"
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "Bearings mutated the authoritative backlog"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-route-call" and .verb == "captain-hold" and .owner == "(main)"))
      and (.gates | any(.id == "sample-route-call") | not)
  ' >/dev/null || fail "Bearings did not surface the captain-held task: $json"

  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "reviewed investigation teardown failed: $(cat "$home/teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null \
    || fail "could not archive completed investigation"
  json=$(run_bearings "$home") || fail "Bearings failed after source teardown and archival"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-route-call" and .verb == "captain-hold"))
      and (.in_flight | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "teardown or archival erased a captain-held task: $json"
  pass "the completion gate attests captain-held inventory and transfers open status decisions"
}

# The recorded-answer rule: answering closes with the captain's exact words, an
# exact retry is idempotent, a drifted retry is rejected, dependent work routed
# behind the answered task is released by the close, and the completion gate is
# satisfied only by a recorded answer.
test_answer_records_and_closes() {
  local home id json show
  home=$(make_home answer-close)
  id=sample-guard-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Guard the answer path" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the answer-guard origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Guard review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-guard-call \
    --title "Choose the guard option" --reason "captain guard choice pending" --repo sample >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" complete "$id" sample-guard-call >/dev/null \
    || fail "completion failed for the held inventory"
  tasks_in "$home" add sample-guard-work "Apply the guard option" \
    --kind ship --repo sample --blocked-by sample-guard-call >/dev/null \
    || fail "could not route work behind the captain-held task"

  printf '' > "$home/empty.txt"
  if run_captain "$home" answer sample-guard-call --decision-file "$home/empty.txt" \
    > "$home/empty-answer.out" 2> "$home/empty-answer.err"; then
    fail "answer accepted an empty captain decision"
  fi
  if run_captain "$home" answer sample-guard-call > "$home/bare-answer.out" 2> "$home/bare-answer.err"; then
    fail "answer accepted a close with no captain decision file at all"
  fi
  printf 'An answer the captain never gave.\n' > "$home/invented.txt"
  if run_captain "$home" answer sample-absent-call --decision-file "$home/invented.txt" \
    > "$home/absent-answer.out" 2> "$home/absent-answer.err"; then
    fail "answer invented a resolution for a task that does not exist"
  fi
  if run_captain "$home" answer sample-guard-work --decision-file "$home/invented.txt" \
    > "$home/unheld-answer.out" 2> "$home/unheld-answer.err"; then
    fail "answer closed a task that is not held for the captain"
  fi
  show=$(tasks_in "$home" show sample-guard-call --full)
  assert_contains "$show" "state: queued" "a refused answer closed the captain-held task"
  assert_contains "$show" "held: yes" "a refused answer released the captain-held task"

  printf 'Captain chose the guard option.\n' > "$home/guard-decision.txt"
  run_captain "$home" answer sample-guard-call --decision-file "$home/guard-decision.txt" >/dev/null \
    || fail "answer could not close the captain-held task"
  show=$(tasks_in "$home" show sample-guard-call --full)
  assert_contains "$show" "state: done" "an answered captain-held task did not close"
  assert_contains "$show" "Resolution recorded by fm-captain-hold" "the answered task lost the decision record"
  assert_contains "$show" "Resolution mode: answered" "the answered task did not record its close path"
  assert_contains "$show" "Captain chose the guard option." \
    "the answered task did not record the captain decision text"
  run_captain "$home" answer sample-guard-call --decision-file "$home/guard-decision.txt" >/dev/null \
    || fail "identical answer retry was not idempotent"
  printf 'Captain chose something else entirely.\n' > "$home/drifted.txt"
  if run_captain "$home" answer sample-guard-call --decision-file "$home/drifted.txt" \
    > "$home/drifted-answer.out" 2> "$home/drifted-answer.err"; then
    fail "answer retry accepted a different captain decision"
  fi
  # The answered call releases the work routed behind it: a Done blocker reads
  # as resolved everywhere.
  show=$(tasks_in "$home" show sample-guard-work --full)
  assert_contains "$show" "blocked: no" "the recorded answer did not release dependent work"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "an answered captain call did not satisfy the completion gate"
  json=$(run_bearings "$home") || fail "Bearings failed after the answer"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-guard-call") | not)
      and (.gates | any(.id == "sample-guard-call") | not)
      and (.landed | any(.id == "sample-guard-call") | not)
  ' >/dev/null || fail "an answered captain call still renders somewhere it should not: $json"
  pass "answer records the captain's words, closes idempotently, and releases routed work"
}

# --release lifts the hold instead of closing, preserving the work item's own
# body under the record; a re-held task later accepts a new answer.
test_release_frees_held_work() {
  local home show out
  home=$(make_home release-work)
  tasks_in "$home" add sample-widget "Ship the sample widget" --kind ship --repo sample \
    --body 'The widget plan body. Literal escape: \n. Unicode: café.' >/dev/null \
    || fail "could not create the held work item"
  run_captain "$home" hold sample-widget --reason "captain go needed before shipping" >/dev/null \
    || fail "could not hold the work item for the captain"
  printf 'Go: ship it as planned.\n' > "$home/go.txt"
  run_captain "$home" answer sample-widget --decision-file "$home/go.txt" --release >/dev/null \
    || fail "answer --release failed on the held work item"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: queued" "a released work item did not stay queued"
  assert_contains "$show" "held: no" "a released work item kept its hold"
  assert_contains "$show" "Resolution mode: released" "the release did not record its close path"
  assert_contains "$show" "Go: ship it as planned." "the release lost the captain's words"
  assert_contains "$show" "The widget plan body." "the release destroyed the work item body"
  assert_contains "$show" 'Literal escape: \\n. Unicode: café.' \
    "the release corrupted escaped or Unicode body text"
  run_captain "$home" answer sample-widget --decision-file "$home/go.txt" --release >/dev/null \
    || fail "identical release retry was not idempotent"
  if run_captain "$home" answer sample-widget --decision-file "$home/go.txt" \
    > "$home/wrong-mode.out" 2> "$home/wrong-mode.err"; then
    fail "a released answer replay without --release reported completion"
  fi
  assert_grep "mode released" "$home/wrong-mode.err" \
    "the mismatched replay did not name the recorded release mode"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: queued" "a mismatched release replay closed the work item"
  assert_contains "$show" "held: no" "a mismatched release replay re-held the work item"

  tasks_in "$home" add sample-empty-label-widget "Ship without a display label" \
    --kind ship --repo sample >/dev/null
  run_captain "$home" hold sample-empty-label-widget --reason "captain go needed" >/dev/null
  out=$(printf 'sample-empty-label-widget\tgo\t\trelease\n' \
    | run_captain "$home" answers --source "empty-label release fixture") \
    || fail "an empty answer label shifted the release close mode"
  assert_contains "$out" "closed: sample-empty-label-widget" \
    "the empty-label release was not accepted"
  show=$(tasks_in "$home" show sample-empty-label-widget --full)
  assert_contains "$show" "state: queued" "an empty-label release completed its work item"
  assert_contains "$show" "held: no" "an empty-label release did not lift the hold"
  assert_contains "$show" "Resolution mode: released" \
    "an empty-label release recorded the wrong close mode"

  # A NEW captain gate on the same task later takes a NEW answer.
  run_captain "$home" hold sample-widget --reason "captain pricing call needed" >/dev/null \
    || fail "could not re-hold the released work item"
  printf 'Price it at nine dollars.\n' > "$home/price.txt"
  run_captain "$home" answer sample-widget --decision-file "$home/price.txt" --release >/dev/null \
    || fail "a re-held task refused a new answer"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "Price it at nine dollars." "the new answer was not recorded"
  assert_contains "$show" "Go: ship it as planned." "the new answer erased the earlier record"

  tasks_in "$home" "done" sample-widget >/dev/null \
    || fail "could not complete the released work item normally"
  if run_captain "$home" answer sample-widget --decision-file "$home/price.txt" \
    > "$home/closed-wrong-mode.out" 2> "$home/closed-wrong-mode.err"; then
    fail "a completed release replay without --release reported an answer"
  fi
  assert_grep "mode released" "$home/closed-wrong-mode.err" \
    "the completed replay did not name the recorded release mode"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: done" "a refused completed replay changed task state"
  pass "release frees held work with the captain's words recorded and the body preserved"
}

# Deferral is a date, not a live card: hold --until keeps the task out of
# captain_actionable until due, tasks-axi's own date-gate expiry keeps the task
# answerable, and Bearings renders the wait as a dated gate.
test_deferral_leaves_captains_call_until_due() {
  local home json snap show
  home=$(make_home deferral)
  run_captain "$home" hold sample-later-call --title "Revisit the sample plan" \
    --reason "captain deferred revisit later" --repo sample --until 2026-08-01 >/dev/null \
    || fail "could not register the deferred captain call"
  run_captain "$home" hold sample-now-call --title "Decide the sample cut" \
    --reason "captain cut choice pending" --repo sample >/dev/null \
    || fail "could not register the live captain call"
  if run_captain "$home" hold sample-bad-date --title "Bad date" \
    --reason "captain choice" --until 2026-8-1 > "$home/bad-date.out" 2> "$home/bad-date.err"; then
    fail "hold accepted a malformed --until date"
  fi

  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-07-14T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed"
  printf '%s' "$snap" | jq -e '
    ([.backlog.records[] | select(.id == "sample-later-call")][0]) as $later
    | ([.backlog.records[] | select(.id == "sample-now-call")][0]) as $now
    | $later.captain_actionable == false and $later.hold_until == "2026-08-01"
      and $now.captain_actionable == true and $now.hold_until == null
      and ($later.title | contains("hold-until") | not)
  ' >/dev/null || fail "the due gate or hold-until parsing is wrong: $snap"

  json=$(run_bearings "$home") || fail "Bearings failed with a deferred call"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-now-call"))
      and (.decisions_open | any(.id == "sample-later-call") | not)
      and (.gates | any(.id == "sample-later-call" and (.reason | startswith("until 2026-08-01"))))
  ' >/dev/null || fail "the deferred call did not render as a dated gate: $json"

  # On its date the call is due again - and still answerable even though
  # tasks-axi reports the expired hold as no longer held.
  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-08-01T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed at the due date"
  printf '%s' "$snap" | jq -e '
    [.backlog.records[] | select(.id == "sample-later-call")][0].captain_actionable == true
  ' >/dev/null || fail "a due deferral did not resurface as captain-actionable"
  show=$(tasks_in "$home" show sample-later-call --full)
  assert_contains "$show" "hold_kind: captain" "the expired deferral lost its captain-hold annotations"
  printf 'Answered on the due date.\n' > "$home/due.txt"
  run_captain "$home" answer sample-later-call --decision-file "$home/due.txt" >/dev/null \
    || fail "an expired deferral was not answerable"
  pass "a deferred captain call leaves the live Captain's Call until its date and stays answerable"
}

# The recorded-answer guard survives an out-of-band close: a bare tasks-axi done
# fails verify until answer records the captain's word, and an ordinary finished
# task can never be dressed up as an answered captain call.
test_out_of_band_close_is_recordable() {
  local home id show
  home=$(make_home out-of-band)
  id=sample-fullrun-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the sample full run" --kind scout --repo sample --start >/dev/null \
    || fail "could not create out-of-band origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample full run review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-submission-call --title "Choose the sample submission" \
    --reason "captain submission choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" complete "$id" sample-submission-call >/dev/null \
    || fail "completion failed before the out-of-band close"

  tasks_in "$home" "done" sample-submission-call >/dev/null \
    || fail "could not reproduce the direct out-of-band close"
  if run_captain "$home" verify "$id" > "$home/broken-verify.out" 2> "$home/broken-verify.err"; then
    fail "verification passed a captain call closed with no recorded answer"
  fi
  if run_teardown "$home" "$id" > "$home/broken-teardown.out" 2> "$home/broken-teardown.err"; then
    fail "teardown proceeded while a captain call had no recorded answer"
  fi
  assert_present "$home/state/$id.meta" "refused teardown removed investigation metadata"

  printf 'Declined: do not submit the sample full run upstream.\n' > "$home/submission.txt"
  run_captain "$home" answer sample-submission-call --decision-file "$home/submission.txt" >/dev/null \
    || fail "answer could not record the missing captain decision on the closed task"
  show=$(tasks_in "$home" show sample-submission-call --full)
  assert_contains "$show" "state: done" "recording the answer reopened the closed task"
  assert_contains "$show" "Resolution mode: repaired" "the retroactive record did not name its path"
  assert_contains "$show" "Declined: do not submit the sample full run upstream." \
    "the retroactive record lost the captain decision text"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "the recorded answer did not satisfy the completion gate"
  run_captain "$home" answer sample-submission-call --decision-file "$home/submission.txt" >/dev/null \
    || fail "identical retroactive retry was not idempotent"
  printf 'A different answer entirely.\n' > "$home/drifted.txt"
  if run_captain "$home" answer sample-submission-call --decision-file "$home/drifted.txt" \
    > "$home/drifted.out" 2> "$home/drifted.err"; then
    fail "a drifted retry overwrote the recorded captain decision"
  fi
  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "teardown still refused after the answer was recorded: $(cat "$home/teardown.err")"

  # An ordinary finished task was never the captain's item; recording an
  # invented answer on it must be refused.
  tasks_in "$home" add sample-ordinary-work "Ordinary finished work" --kind ship --repo sample >/dev/null
  tasks_in "$home" "done" sample-ordinary-work >/dev/null
  printf 'An answer the captain never gave.\n' > "$home/invented.txt"
  if run_captain "$home" answer sample-ordinary-work --decision-file "$home/invented.txt" \
    > "$home/never-held.out" 2> "$home/never-held.err"; then
    fail "an ordinary finished task was dressed up as an answered captain call"
  fi
  assert_grep "never held for the captain" "$home/never-held.err" \
    "the refusal must say the task carries no captain-hold provenance"
  pass "an out-of-band close is recordable with the captain's word and nothing else"
}

# A post-teardown visual review completes against the surviving report and
# durable tasks, with no volatile task metadata and no second decision database.
test_visual_review_uses_shared_completion_owner() {
  local home id json
  home=$(make_home visual-review)
  id=sample-board-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review the sample board" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: investigation complete\n' > "$home/state/$id.status"
  printf '# Sample board investigation\n\nThe initial findings need no captain choice.\n' > "$home/data/$id/report.md"
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "initial investigation could not pass the shared completion owner"
  run_teardown "$home" "$id" >/dev/null 2> "$home/visual-teardown.err" \
    || fail "completed investigation teardown failed: $(cat "$home/visual-teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null

  mkdir -p "$home/.lavish"
  printf '<html><body>Synthetic sample board</body></html>\n' > "$home/.lavish/sample-board.html"
  run_captain "$home" hold sample-layout-call --title "Choose the sample layout" \
    --reason "captain layout choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "post-teardown visual review could not use the shared hold owner"
  run_captain "$home" complete "$id" sample-layout-call >/dev/null \
    || fail "post-teardown visual review could not use the shared completion owner"
  json=$(run_bearings "$home") || fail "Bearings failed after the ended visual review"
  printf '%s' "$json" | jq -e '
    .decisions_open | any(.id == "sample-layout-call" and .verb == "captain-hold")
  ' >/dev/null || fail "ended visual review did not leave its durable Captain Call: $json"
  [ ! -e "$home/data/visual-review-decisions.json" ] \
    || fail "visual review created a second decision database"
  pass "ended visual review follows the same captain-hold completion owner"
}

test_none_inventory_and_resolved_prose_do_not_create_holds() {
  local home id json
  home=$(make_home no-false-holds)
  id=sample-resolved-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a resolved sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'resolved [key=old-choice]: the sample choice was already recorded\ndone: report complete\n' \
    > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Resolved sample finding

Decision record: the earlier choice is resolved.
The recommendation is informational and needs no captain action.
EOF
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "explicit no-call inventory failed"
  json=$(run_bearings "$home") || fail "Bearings failed for no-call inventory"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id | startswith("sample-resolved-review")) | not)
  ' >/dev/null || fail "resolved findings or decision-like prose created a false captain call: $json"
  pass "resolved findings and decision-like prose do not create captain-held tasks"
}

test_terminal_single_owner_status_decision_does_not_block_empty_inventory() {
  local home id open secondmate
  home=$(make_home stale-terminal-decision)
  id=sample-terminal-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a terminal sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=default]: choose route A or route B\ndone: report complete\n' \
    > "$home/state/$id.status"
  printf '# Terminal sample review\n\nNo unresolved captain choice remains.\n' > "$home/data/$id/report.md"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  assert_contains "$open" "default" "fixture must retain the raw stale status decision"
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "terminal single-owner stale status decision blocked empty inventory completion"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "terminal single-owner stale status decision blocked inventory verification"
  run_teardown "$home" "$id" >/dev/null 2> "$home/terminal-teardown.err" \
    || fail "terminal single-owner stale status decision blocked teardown: $(cat "$home/terminal-teardown.err")"

  secondmate=sample-secondmate
  write_origin_meta "$home" "$secondmate" secondmate
  printf 'needs-decision [key=route]: choose route A or route B\ndone: heartbeat complete\n' \
    > "$home/state/$secondmate.status"
  if run_captain "$home" complete "$secondmate" --none \
    > "$home/secondmate-terminal.out" 2> "$home/secondmate-terminal.err"; then
    fail "secondmate terminal status decision was incorrectly cleared"
  fi
  pass "terminal single-owner stale status decisions do not block empty inventory"
}

test_secondmate_hold_stays_in_authoritative_home() {
  local parent mate fakebin origin json
  parent=$(make_home main-routing)
  mate="$TMP_ROOT/sample-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'sample-mate\n' > "$mate/.fm-secondmate-home"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  origin=sample-mate-review
  mkdir -p "$mate/data/$origin"
  tasks_in "$mate" add "$origin" "Investigate secondmate sample" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$mate" "$origin"
  printf 'done: report and visual review complete\n' > "$mate/state/$origin.status"
  printf '# Sample secondmate review\n\nOne captain choice remains.\n' > "$mate/data/$origin/report.md"
  run_captain "$mate" hold sample-release-call --title "Choose the sample release" \
    --reason "captain release choice pending" --repo sample --origin "$origin" >/dev/null \
    || fail "secondmate-owned hold creation failed"
  run_captain "$mate" complete "$origin" sample-release-call >/dev/null \
    || fail "secondmate-owned completion failed"
  run_teardown "$mate" "$origin" >/dev/null 2> "$mate/teardown.err" \
    || fail "secondmate investigation teardown failed: $(cat "$mate/teardown.err")"
  tasks_in "$mate" "done" "$origin" --report "data/$origin/report.md" --keep 0 >/dev/null

  printf -- '- sample-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/sample-mate.meta" "$mate" \
    "firstmate:fm-sample-mate" sample
  json=$(run_bearings "$parent") || fail "parent Bearings could not read the secondmate captain call"
  printf '%s' "$json" | jq -e '
    .decisions_open | any(.owner == "sample-mate" and .verb == "captain-hold"
      and (.id | endswith("sample-release-call")))
  ' >/dev/null || fail "secondmate captain call did not surface with authoritative owner: $json"
  assert_no_grep "sample-release-call" "$parent/data/backlog.md" "secondmate call leaked into the main backlog"
  assert_grep "sample-release-call" "$mate/data/backlog.md" "secondmate call left its authoritative backlog"
  pass "main-home and secondmate-home captain calls remain correctly routed"
}

# The one keyed-answer intake, fed through the real process-event runner by a
# fixture channel that knows nothing about captain holds: task-id keys close at
# answer time, a card-declared release mode frees held work, freeform prose can
# forge nothing, and a replayed capture is idempotent.
test_bound_channel_answers_close_at_answer_time() {
  local home id sid artifact result out show rc
  home=$(make_home channel-answer-closure)
  id=sample-eval-proposal
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Propose sample eval changes" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the review origin"
  write_origin_meta "$home" "$id"
  printf 'done: proposal deck ready for the captain\n' > "$home/state/$id.status"
  printf '# Sample eval proposal\n\nThree captain choices remain.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-membership-call --title "Captain call: membership" \
    --reason "captain membership choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-headline-call --title "Captain call: headline" \
    --reason "captain headline choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-forged-call --title "Captain call: forged" \
    --reason "captain forged choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-invalid-close-call --title "Captain call: invalid close" \
    --reason "captain close mode validation pending" --repo sample --origin "$id" >/dev/null
  tasks_in "$home" add sample-gated-work "Gated sample work" --kind ship --repo sample \
    --body 'Gated work plan.' >/dev/null
  run_captain "$home" hold sample-gated-work --reason "captain go needed" >/dev/null
  run_captain "$home" complete "$id" \
    sample-membership-call sample-headline-call sample-forged-call sample-invalid-close-call \
    sample-gated-work >/dev/null \
    || fail "completion failed for the deck's inventoried calls"

  artifact="$home/data/$id/review.html"
  printf '<h1>Sample eval proposal</h1>\n' > "$artifact"
  fm_fake_exit0 "$home/fakebin" lavish-axi
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the review source id"
  run_captain "$home" bind "$sid" >/dev/null \
    || fail "could not bind the review source to the keyed-answer intake"
  [ "$(run_captain "$home" binding "$sid")" = "(any)" ] \
    || fail "the recorded binding did not resolve to the collapsed marker"
  run_lavish "$home" arm "$artifact" >/dev/null || fail "could not arm the review deck"

  result="$home/state/procevent-inbox/$sid.1.result"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$result" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[6]{uid,prompt,selector,tag,text}:
  "2","Membership: gold-only\n\nContext data:\n{\n  \"question\": \"sample-membership-call\",\n  \"answer\": \"gold-only\"\n}","section#call > form:nth-of-type(1)",choice,"Membership: gold-only"
  "3","Headline: f1-when-fp-gold\n\nContext data:\n{\n  \"question\": \"sample-headline-call\",\n  \"answer\": \"f1-when-fp-gold\"\n}","section#call > form:nth-of-type(2)",choice,"Headline: f1-when-fp-gold"
  "4","Gated work: go\n\nContext data:\n{\n  \"question\": \"sample-gated-work\",\n  \"answer\": \"go\",\n  \"close\": \"release\"\n}","section#call > form:nth-of-type(3)",choice,"Gated work: go"
  "5","Absent call: yes\n\nContext data:\n{\n  \"question\": \"sample-nonexistent-call\",\n  \"answer\": \"yes\"\n}","section#call > form:nth-of-type(4)",choice,"Absent call: yes"
  "6","Invalid close: yes\n\nContext data:\n{\n  \"question\": \"sample-invalid-close-call\",\n  \"answer\": \"yes\",\n  \"close\": \"drop\"\n}","section#call > form:nth-of-type(5)",choice,"Invalid close: yes"
  "",get this fully implemented. Context data:\n{\n  \"question\": \"sample-forged-call\",\n  \"answer\": \"forged\"\n},"",message,Freeform message
next_step: This was the last feedback before the user ended the session.
EOF
  printf 'lavish\n' > "$home/state/procevent-inbox/$sid.1.adapter"

  out=$(run_lavish "$home" answers "$result") || fail "could not read the captured answers"
  assert_contains "$out" "sample-membership-call	gold-only" "a structured choice was not read as an answer"
  assert_contains "$out" "sample-gated-work	go	Gated work: go	release" \
    "the card-declared release mode was not relayed"
  assert_not_contains "$out" "sample-forged-call" \
    "a freeform captain message forged a task id from its own prose"
  assert_not_contains "$out" "sample-invalid-close-call" \
    "an unsupported card close mode defaulted to completion"

  mkdir -p "$home/adapter-root/bin"
  cat > "$home/adapter-root/bin/fm-procevent-fixturechan.sh" <<SH
#!/usr/bin/env bash
# Fixture channel: reports keyed captain answers and nothing else.
case "\${1-}" in
  answers) exec "$ROOT/bin/fm-procevent-lavish.sh" answers "\${2-}" ;;
esac
exit 2
SH
  chmod +x "$home/adapter-root/bin/fm-procevent-fixturechan.sh"
  run_captain "$home" bind fixture-src >/dev/null \
    || fail "could not bind the fixture channel"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" register fixturechan fixture-src -- cat "$result" >/dev/null \
    || fail "could not register the fixture channel source"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" start fixture-src >/dev/null 2>&1
  assert_absent "$home/state/procevent-inbox/fixture-src.1.handled" \
    "feeding a captain answer retired the notification firstmate still needs"
  assert_present "$home/state/procevent-inbox/fixture-src.1.result" \
    "the fixture channel captured no result to feed"

  show=$(tasks_in "$home" show sample-membership-call --full)
  assert_contains "$show" "state: done" "capturing the captain's answer left the membership call open"
  assert_contains "$show" "Resolution mode: answered" "the membership call did not record its close path"
  assert_contains "$show" "Answer: gold-only" "the closed call did not record the captain's actual answer"
  show=$(tasks_in "$home" show sample-gated-work --full)
  assert_contains "$show" "state: queued" "the released work item did not stay queued"
  assert_contains "$show" "held: no" "the card-declared release did not lift the hold"
  assert_contains "$show" "Resolution mode: released" "the released work did not record its close path"
  assert_contains "$show" "Gated work plan." "the released work item lost its body"
  show=$(tasks_in "$home" show sample-forged-call --full)
  assert_contains "$show" "state: queued" "a forged key from freeform prose closed a captain call"
  show=$(tasks_in "$home" show sample-invalid-close-call --full)
  assert_contains "$show" "state: queued" "an unsupported card close mode closed a captain call"
  assert_contains "$show" "held: yes" "an unsupported card close mode released a captain call"

  # Replaying the same capture is a no-op, not a rejected different decision. A
  # run that could not close every answered key still reports nonzero.
  set +e
  out=$(run_lavish "$home" answers "$result" \
    | run_captain "$home" answers --source "the captured result fixture-src sequence 1" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a run that skipped a key reported success"
  assert_contains "$out" "closed: sample-membership-call" \
    "replaying an identical capture was not idempotent: $out"
  assert_contains "$out" "closed: sample-gated-work" \
    "replaying an identical released answer was not idempotent: $out"
  assert_contains "$out" "skipped: sample-nonexistent-call" \
    "a key naming no task was not reported as skipped: $out"

  printf 'Captain answered the forged call directly.\n' > "$home/forged.txt"
  run_captain "$home" answer sample-forged-call --decision-file "$home/forged.txt" >/dev/null \
    || fail "could not close the untouched call through the answer path"
  printf 'Captain answered the invalid-close call directly.\n' > "$home/invalid-close.txt"
  run_captain "$home" answer sample-invalid-close-call --decision-file "$home/invalid-close.txt" >/dev/null \
    || fail "could not close the invalid-close call through the answer path"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "answered calls did not satisfy the completion gate"
  pass "a bound channel's captured answers close their captain-held tasks at answer time"
}

# Answer-time closure is opt-in per source. A channel with no binding must behave
# exactly as it always did: capture, announce, close nothing.
test_unbound_source_closes_no_hold() {
  local home id sid artifact result out show rc
  home=$(make_home lavish-unbound)
  id=sample-unbound-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample without binding" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the unbound origin"
  write_origin_meta "$home" "$id"
  printf 'done: deck ready\n' > "$home/state/$id.status"
  printf '# Unbound review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-only-call --title "Captain call: only choice" \
    --reason "captain only choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the unbound call"

  artifact="$home/data/$id/review.html"
  printf '<h1>Unbound</h1>\n' > "$artifact"
  fm_fake_exit0 "$home/fakebin" lavish-axi
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the unbound source id"
  run_lavish "$home" arm "$artifact" >/dev/null || fail "could not arm the unbound review"

  result="$home/state/procevent-inbox/$sid.1.result"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$result" <<'EOF'
session:
  file: /review.html
  status: feedback
prompts[1]{uid,prompt,selector,tag,text}:
  "2","Only choice: yes\n\nContext data:\n{\n  \"question\": \"sample-only-call\",\n  \"answer\": \"yes\"\n}","form",choice,"Only choice: yes"
EOF
  set +e
  out=$(run_captain "$home" binding "$sid" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unbound source reported a binding"
  [ -z "$out" ] || fail "an unbound source printed a binding: $out"
  show=$(tasks_in "$home" show sample-only-call --full)
  assert_contains "$show" "state: queued" "an unbound review closed a captain call"
  assert_contains "$show" "held: yes" "an unbound review released a captain call"
  pass "a channel source with no decision binding closes nothing"
}

# Everything a pre-collapse install already has keeps working: composed
# identities through the shim, short decision keys in recorded metadata, a
# concrete-origin binding, and the chat fallback for old rows.
test_legacy_identities_keep_working() {
  local home id hold out show legacy_text legacy_digest old_hold
  home=$(make_home legacy-compat)
  id=sample-legacy-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Legacy-shaped review" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Legacy review\n\nTwo captain choices remain.\n' > "$home/data/$id/report.md"

  hold=$(run_shim "$home" id "$id" pick-one)
  [ "$hold" = "$id-decision-pick-one" ] || fail "the shim identity was not deterministic: $hold"
  out=$(run_shim "$home" hold "$id" pick-one \
    --title "Pick one" --reason "captain choice pending" --repo sample) \
    || fail "the shim hold path failed"
  [ "$out" = "$hold" ] || fail "the shim hold did not print the composed identity: $out"
  run_shim "$home" hold "$id" keep-two \
    --title "Keep two" --reason "captain second choice pending" --repo sample >/dev/null \
    || fail "the shim second hold failed"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "hold_kind: captain" "the shim-created row is not a plain captain-held task"

  # A pre-collapse metadata attestation records SHORT keys; verify must resolve
  # them through the legacy composed identity.
  printf 'decisions_reviewed=1\ndecision_keys=keep-two,pick-one\n' >> "$home/state/$id.meta"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "legacy short-key metadata did not verify against composed identities"

  # The shim's routed close records the routed work inside the captain decision
  # and clears the recorded edge.
  tasks_in "$home" add sample-legacy-work "Apply the legacy choice" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null
  tasks_in "$home" add sample-unrouted-work "Unrouted legacy work" \
    --kind ship --repo sample >/dev/null
  printf 'Use route north.\n' > "$home/route.txt"
  if run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-missing-work > "$home/missing-route.out" 2> "$home/missing-route.err"; then
    fail "the shim resolve accepted a missing routed task"
  fi
  if run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-unrouted-work > "$home/unrouted.out" 2> "$home/unrouted.err"; then
    fail "the shim resolve accepted work not blocked by the legacy decision"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "invalid shim routing closed the legacy decision"
  assert_not_contains "$show" "Resolution recorded" "invalid shim routing recorded an answer"
  run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-legacy-work >/dev/null \
    || fail "the shim resolve path failed"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "the shim resolve did not close the row"
  assert_contains "$show" "Use route north." "the shim resolve lost the captain decision"
  assert_contains "$show" "- sample-legacy-work" "the shim resolve lost the routed identities"
  show=$(tasks_in "$home" show sample-legacy-work --full)
  assert_contains "$show" "blocked: no" "the shim resolve did not release the routed work"

  old_hold=$(run_shim "$home" hold "$id" old-route \
    --title "Old routed choice" --reason "captain old route pending" --repo sample)
  tasks_in "$home" add sample-old-routed-work "Apply the old routed choice" \
    --kind ship --repo sample --blocked-by "$old_hold" >/dev/null
  printf 'Use the historical route.\n' > "$home/old-route.txt"
  legacy_text=$(cat "$home/old-route.txt")
  if command -v shasum >/dev/null 2>&1; then
    legacy_digest=$(printf '%s' "$legacy_text" | shasum -a 256 | awk '{print $1}')
  else
    legacy_digest=$(printf '%s' "$legacy_text" | sha256sum | awk '{print $1}')
  fi
  printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: sample-old-routed-work\nResolution mode: routed\n\nCaptain decision:\n%s\n\nRouted work:\n- sample-old-routed-work\n' \
    "$legacy_digest" "$legacy_text" > "$home/old-route-body.txt"
  tasks_in "$home" update "$old_hold" --body-file "$home/old-route-body.txt" --archive-body >/dev/null
  run_shim "$home" resolve "$id" old-route --decision-file "$home/old-route.txt" \
    --routed-to sample-old-routed-work >/dev/null \
    || fail "the shim did not replay a matching pre-collapse routed record"
  show=$(tasks_in "$home" show "$old_hold" --full)
  assert_contains "$show" "state: done" "the replayed legacy resolve did not close its hold"
  show=$(tasks_in "$home" show sample-old-routed-work --full)
  assert_contains "$show" "blocked_by: none" "the replayed legacy resolve did not clear its recorded edge"

  # The shim decline path maps onto the same recorded answer.
  printf 'Declined: keep the current shape.\n' > "$home/decline.txt"
  run_shim "$home" decline "$id" keep-two --decision-file "$home/decline.txt" >/dev/null \
    || fail "the shim decline path failed"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "shim-closed rows did not satisfy the completion gate"

  # A concrete-origin binding (a pre-collapse record) makes short channel keys
  # resolve through the composed identity.
  run_shim "$home" hold "$id" third-choice \
    --title "Third choice" --reason "captain third choice pending" --repo sample >/dev/null
  run_shim "$home" bind legacy-src "$id" >/dev/null || fail "the shim bind path failed"
  [ "$(run_captain "$home" binding legacy-src)" = "$id" ] \
    || fail "the concrete-origin binding was not preserved"
  printf 'third-choice\toption b\t\n' \
    | run_captain "$home" answers "$(run_captain "$home" binding legacy-src)" \
        --source "legacy channel" >/dev/null \
    || fail "a short key did not resolve through the concrete-origin binding"
  show=$(tasks_in "$home" show "$id-decision-third-choice" --full)
  assert_contains "$show" "state: done" "the legacy-keyed answer did not close its row"

  run_shim "$home" hold "$id" fourth-choice \
    --title "Fourth choice" --reason "captain fourth choice pending" --repo sample >/dev/null
  legacy_text=$(printf 'Captain answered this decision through legacy replay.\nDecision key: fourth-choice\nAnswer: option c\n')
  if command -v shasum >/dev/null 2>&1; then
    legacy_digest=$(printf '%s' "$legacy_text" | shasum -a 256 | awk '{print $1}')
  else
    legacy_digest=$(printf '%s' "$legacy_text" | sha256sum | awk '{print $1}')
  fi
  printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: none\nResolution mode: answered\n\nCaptain decision:\n%s\n' \
    "$legacy_digest" "$legacy_text" > "$home/legacy-body.txt"
  tasks_in "$home" update "$id-decision-fourth-choice" --body-file "$home/legacy-body.txt" --archive-body >/dev/null
  tasks_in "$home" "done" "$id-decision-fourth-choice" >/dev/null
  out=$(printf 'fourth-choice\toption c\t\n' \
    | run_captain "$home" answers "$id" --source "legacy replay") \
    || fail "an identical pre-collapse keyed answer was not idempotent"
  assert_contains "$out" "closed: $id-decision-fourth-choice" \
    "the pre-collapse keyed answer digest was treated as drift"
  out=$(printf '%s-decision-fourth-choice\toption c\t\n' "$id" \
    | run_captain "$home" answers --source "legacy replay") \
    || fail "a full legacy task-id replay without an origin was not idempotent"
  assert_contains "$out" "closed: $id-decision-fourth-choice" \
    "the origin-free legacy replay digest was treated as drift"
  pass "legacy identities, metadata, bindings, and the shim keep working"
}

# The intake is channel-agnostic, so chat must reach it the same way a captured
# review does - for a task-id key, and for a legacy composed identity.
test_chat_channel_feeds_the_same_keyed_answer_intake() {
  local home id fb show
  home=$(make_home chat-channel)
  id=sample-chat-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample chat routing" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the chat-channel origin"
  write_origin_meta "$home" "$id" ship
  printf 'needs-decision [key=chat-choice]: pick option A or option B\n' > "$home/state/$id.status"
  printf '# Chat review\n\nTwo captain choices remain.\n' > "$home/data/$id/report.md"
  run_shim "$home" hold "$id" chat-choice \
    --title "Choose the sample chat option" --reason "captain chat choice pending" --repo sample >/dev/null \
    || fail "could not register the legacy chat row"
  run_captain "$home" hold sample-chat-followup --title "Choose the chat follow-up" \
    --reason "captain follow-up choice pending" --repo sample >/dev/null \
    || fail "could not register the task-id chat call"
  run_captain "$home" complete "$id" "$id-decision-chat-choice" sample-chat-followup >/dev/null \
    || fail "completion failed for the chat calls"
  grep -F 'captain-held [key=chat-choice]' "$home/state/$id.status" >/dev/null \
    || fail "precondition: completion did not transfer the decision to its durable owner"

  fb="$home/fakebin"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"

  : > "$home/send.log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key chat-choice "go with option A" >/dev/null 2>&1 \
    || fail "an answer to a transferred legacy decision was refused by the chat channel"
  # The answer rides fm-send's durable inbox plane: the record carries the
  # text while the typed channel carries only the doorbell.
  grep -qF "go with option A" "$home/state/$id.inbox/001.msg" \
    || fail "the answer text never reached the worker's durable inbox record"
  show=$(tasks_in "$home" show "$id-decision-chat-choice" --full)
  assert_contains "$show" "state: done" "a chat answer left the legacy row open"
  assert_contains "$show" "Answer: go with option A" "the chat-answered row lost the captain answer"

  : > "$home/send.log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key sample-chat-followup "take the second option" >/dev/null 2>&1 \
    || fail "an answer keyed by a task id was refused by the chat channel"
  show=$(tasks_in "$home" show sample-chat-followup --full)
  assert_contains "$show" "state: done" "a chat answer left the task-id call open"
  assert_contains "$show" "Resolution mode: answered" "the chat-answered call did not record its close path"
  assert_contains "$show" "Answer: take the second option" "the chat-answered call lost the captain answer"
  assert_contains "$show" "answer sent to $id" "the chat-answered call lost its channel provenance"

  if env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key sample-chat-followup "again" \
    > "$home/closed-key.out" 2> "$home/closed-key.err"; then
    fail "a key already closed in both ledgers was accepted"
  fi
  run_captain "$home" verify "$id" >/dev/null \
    || fail "chat-answered calls did not satisfy the completion gate"
  pass "the chat channel feeds the same keyed-answer intake a captured review does"
}

test_origin_slug_validation_precedes_path_construction() {
  local home
  home=$(make_home slug-validation)
  if run_captain "$home" complete "../escape" --none > "$home/escape.out" 2> "$home/escape.err"; then
    fail "complete accepted a path-escaping origin id"
  fi
  assert_grep "privacy-safe slug" "$home/escape.err" "the refusal must name the slug contract"
  if run_captain "$home" verify "../escape" > "$home/escape-verify.out" 2> "$home/escape-verify.err"; then
    fail "verify accepted a path-escaping origin id"
  fi
  if run_captain "$home" hold "bad id" --title "x" --reason "y" > "$home/bad-hold.out" 2> "$home/bad-hold.err"; then
    fail "hold accepted an invalid task id"
  fi
  pass "completion and verification validate origins before constructing paths"
}

# --- record divergence ------------------------------------------------------

run_drain() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null
}

# Reconstructs the 2026-08-06 loss with synthetic names: the answer was posted
# as a `resolved [key=...]` line and nothing else, so the status fold went quiet
# while the durable captain-held task stayed open and kept reading as if the
# captain had never spoken. Both identities that can carry a captain call must
# be caught - the collapsed one (the key IS the task id) and the legacy derived
# one a pre-collapse origin minted - and the report must reach the drain, which
# is where firstmate actually looks.
test_status_resolution_over_an_open_hold_is_signalled() {
  local home id out drain
  home=$(make_home divergence-signalled)
  id=sample-route-review
  tasks_in "$home" add "$id" "Investigate sample routing" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"
  run_captain "$home" hold sample-route-call \
    --title "Choose route: north or south" --reason "captain route choice pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the collapsed-identity captain call"
  run_captain "$home" hold "$id-decision-access" \
    --title "Open or restricted sample access" --reason "captain access choice pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the legacy-identity captain call"
  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=sample-route-call]: north or south
resolved [key=sample-route-call]: answered: north
needs-decision [key=access]: open or restricted sample access
resolved [key=access]: answered: restricted
done: report complete
EOF

  out=$(run_captain "$home" diverged) || fail "diverged failed on the reconstructed loss"
  printf '%s\n' "$out" | grep -F "sample-route-call	$id	sample-route-call" >/dev/null \
    || fail "the collapsed-identity divergence was not signalled: $out"
  printf '%s\n' "$out" | grep -F "$id-decision-access	$id	access" >/dev/null \
    || fail "the legacy-identity divergence was not signalled: $out"

  drain=$(run_drain "$home") || fail "the drain failed while reporting divergence"
  printf '%s\n' "$drain" | grep -F 'RECORD DIVERGENCE' >/dev/null \
    || fail "the divergence never reached the drain: $drain"
  printf '%s\n' "$drain" | grep -F 'sample-route-call [key=sample-route-call]' >/dev/null \
    || fail "the drain section omitted the collapsed-identity divergence: $drain"
  printf '%s\n' "$drain" | grep -F "$id-decision-access [key=access]" >/dev/null \
    || fail "the drain section omitted the legacy-identity divergence: $drain"

  # It signals; it never closes. Both records must survive the report unchanged,
  # because closing a captain call wrongly removes it from review entirely.
  assert_grep "sample-route-call" "$home/data/backlog.md" "the report must not remove the captain-held task"
  tasks_in "$home" show sample-route-call --full | grep -E '^  held: yes' >/dev/null \
    || fail "the report released or closed the captain-held task"
  [ "$(grep -c '^resolved \[key=sample-route-call\]' "$home/state/$id.status")" = 1 ] \
    || fail "the report rewrote the status log"

  # And it names BOTH reconciliation directions. A status resolution is not proof
  # the captain ruled: one of the real cases dissolved because its premise was
  # false and another was a question of fact whose first reading was wrong, so
  # the only safe instruction is "reconcile with what actually happened".
  printf '%s\n' "$drain" | grep -F 'fm-captain-hold.sh answer' >/dev/null \
    || fail "the drain section does not say how to record the captain's answer: $drain"
  printf '%s\n' "$drain" | grep -F 're-open the status decision' >/dev/null \
    || fail "the drain section does not offer the re-open direction: $drain"
  pass "a status resolution over a still-open captain-held task is signalled, not closed"
}

# The false-signal boundary, driven by the shapes that are genuinely fine. A
# captain call whose deliverable IS the decision has no routed work item at all,
# and that is legitimate: routed work must never be part of the test. Nor may a
# verified `captain-held` transfer, a still-open status decision, an already
# answered call, or an ordinary task that merely had a keyed question answered.
test_legitimate_holds_produce_no_divergence_signal() {
  local home id out drain answer
  home=$(make_home divergence-no-false-signal)
  id=sample-systems-review
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"

  # (1) The decision IS the deliverable: held for the captain, nothing routed,
  # no status line anywhere naming it.
  run_captain "$home" hold sample-standalone-call \
    --title "Adopt the sample naming convention" --reason "captain call with no routed work" \
    --repo sample >/dev/null || fail "could not register the deliverable-is-the-decision call"
  # (2) The verified transfer: still open structurally, closed on the status side
  # by the captain-held verb command_complete writes.
  run_captain "$home" hold sample-transfer-call \
    --title "Choose the sample retention window" --reason "captain retention choice pending" \
    --repo sample >/dev/null || fail "could not register the transferred call"
  # (4) An already answered call whose status line reads resolved.
  run_captain "$home" hold sample-answered-call \
    --title "Choose the sample export format" --reason "captain export choice pending" \
    --repo sample >/dev/null || fail "could not register the answered call"
  answer="$home/answer.txt"
  printf 'Export as CSV.\n' > "$answer"
  run_captain "$home" answer sample-answered-call --decision-file "$answer" >/dev/null \
    || fail "could not record the captain answer fixture"
  # (5) An ordinary in-flight work item that is not held for the captain.
  tasks_in "$home" add sample-plain-work "Ordinary sample work" --kind ship --repo sample --start >/dev/null \
    || fail "could not create the ordinary work fixture"

  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=sample-transfer-call]: choose the retention window
captain-held [key=sample-transfer-call]: tracked by sample-transfer-call
needs-decision [key=sample-open-call]: still open on both sides
needs-decision [key=sample-answered-call]: choose the export format
resolved [key=sample-answered-call]: answered: CSV
needs-decision [key=sample-plain-work]: worker question about the sample fixture
resolved [key=sample-plain-work]: answered: go ahead
EOF
  # (3) A still-open status decision whose structured twin is also still open.
  run_captain "$home" hold sample-open-call \
    --title "Choose the sample refresh cadence" --reason "captain cadence choice pending" \
    --repo sample >/dev/null || fail "could not register the still-open call"

  out=$(run_captain "$home" diverged) || fail "diverged failed on the legitimate shapes"
  [ -z "$out" ] || fail "legitimate captain holds produced a false divergence signal: $out"

  drain=$(run_drain "$home") || fail "the drain failed on the legitimate shapes"
  if printf '%s\n' "$drain" | grep -F 'RECORD DIVERGENCE' >/dev/null; then
    fail "the drain printed a divergence section with nothing diverging: $drain"
  fi
  printf '%s\n' "$drain" | grep -F 'sample-open-call' >/dev/null \
    || fail "setup error: the still-open decision should still reach OPEN DECISIONS: $drain"
  pass "a captain call with no routed work, a verified transfer, an open decision, and an answered call all stay silent"
}

# --- the configured Done archive as a lookup fallback ------------------------
# Pre-collapse coverage carried over from the retired
# tests/fm-decision-hold-lifecycle.test.sh: every `tasks-axi done` prunes, so an
# answered call can leave the live backlog for the configured archive while the
# completion gate still has to read it. These drive the retired command surface
# through the shim deliberately, because that is the surface they were written
# against and it must keep resolving to the same guards.

test_archived_decisions_keep_the_scout_completion_gate_strong() {
  local home id hold decision_key
  home=$(make_home archived-completion-gate)
  cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/decisions/closed.md"
done_keep = 10
EOF

  id=sample-archived-resolved-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review an archived resolved choice" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Archived resolved review\n\nThe captain choice is recorded.\n' > "$home/data/$id/report.md"
  hold=$(run_shim "$home" hold "$id" route \
    --title "Choose the archived route" --reason "captain archived route pending" --repo sample)
  run_shim "$home" complete "$id" route >/dev/null
  printf 'Use the archived north route.\n' > "$home/resolved-decision.txt"
  run_shim "$home" answer "$id" route --decision-file "$home/resolved-decision.txt" >/dev/null
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null
  assert_no_grep "$hold" "$home/data/backlog.md" "the resolved hold remained in the live Done window"
  assert_grep "$hold" "$home/data/decisions/closed.md" "the configured archive did not receive the resolved hold"
  run_shim "$home" verify "$id" >/dev/null \
    || fail "a durable decision in the configured archive did not satisfy verification"
  run_teardown "$home" "$id" >/dev/null 2> "$home/resolved-teardown.err" \
    || fail "a durable decision in the configured archive blocked teardown: $(cat "$home/resolved-teardown.err")"

  id=sample-archived-unrepaired-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review an archived unrepaired choice" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Archived unrepaired review\n\nThe answer still needs a durable body.\n' > "$home/data/$id/report.md"
  hold=$(run_shim "$home" hold "$id" submission \
    --title "Choose the archived submission" --reason "captain archived submission pending" --repo sample)
  run_shim "$home" complete "$id" submission >/dev/null
  tasks_in "$home" "done" "$hold" >/dev/null
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null
  if run_shim "$home" verify "$id" > "$home/unrepaired-verify.out" 2> "$home/unrepaired-verify.err"; then
    fail "an archived hold without a durable captain decision satisfied verification"
  fi
  if run_teardown "$home" "$id" > "$home/unrepaired-teardown.out" 2> "$home/unrepaired-teardown.err"; then
    fail "an archived hold without a durable captain decision allowed teardown"
  fi
  assert_present "$home/state/$id.meta" "the archived unresolved refusal removed task metadata"
  printf 'Do not submit the archived sample.\n' > "$home/repaired-decision.txt"
  run_shim "$home" repair "$id" submission --decision-file "$home/repaired-decision.txt" >/dev/null \
    || fail "repair could not update a closed hold in the configured archive"
  assert_grep "Resolution mode: repaired" "$home/data/decisions/closed.md" \
    "archive repair did not record its durable resolution body"
  run_shim "$home" verify "$id" >/dev/null \
    || fail "the repaired archived decision did not satisfy verification"
  run_teardown "$home" "$id" >/dev/null 2> "$home/repaired-teardown.err" \
    || fail "the repaired archived decision still blocked teardown: $(cat "$home/repaired-teardown.err")"

  id=sample-missing-archived-review
  decision_key=missing-choice
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$decision_key" >> "$home/state/$id.meta"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Missing archived review\n\nNo durable decision record exists.\n' > "$home/data/$id/report.md"
  if run_teardown "$home" "$id" > "$home/missing-teardown.out" 2> "$home/missing-teardown.err"; then
    fail "a decision absent from both the live backlog and configured archive allowed teardown"
  fi
  assert_grep "absent from the active backlog and configured archive" "$home/missing-teardown.err" \
    "the missing decision refusal did not name both lookup locations"
  assert_present "$home/state/$id.meta" "the absent-from-both refusal removed task metadata"
  pass "archived durable decisions satisfy teardown, while missing or unresolved archived decisions still refuse and remain repairable"
}

# Retention prunes a section, not only closed work, so a captain call that is
# still OPEN and unanswered can leave the live backlog for the archive as an
# unchecked `- [ ]` row. That row keeps its `hold-kind: captain` annotation, so
# reading it as an active hold would pass the durability gate on a question
# nobody ever answered and let teardown erase the scout's source under it.
test_archived_open_hold_is_never_read_as_actively_held() {
  local home id hold
  home=$(make_home archived-open-hold)
  id=sample-archived-open-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review an archived open choice" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Archived open review\n\nThe captain question is still unanswered.\n' > "$home/data/$id/report.md"
  hold=$(run_shim "$home" hold "$id" route \
    --title "Choose the archived open route" --reason "captain archived open route pending" --repo sample)
  run_shim "$home" complete "$id" route >/dev/null
  tasks_in "$home" prune --state queued --keep 0 >/dev/null
  assert_no_grep "$hold" "$home/data/backlog.md" "the unanswered open hold remained in the live backlog"
  assert_grep "- [ ] $hold" "$home/data/done-archive.md" \
    "the unanswered open hold did not reach the archive as an unchecked row"
  if run_shim "$home" verify "$id" > "$home/open-verify.out" 2> "$home/open-verify.err"; then
    fail "an archived captain call nobody answered satisfied verification"
  fi
  assert_grep "archived and not closed" "$home/open-verify.err" \
    "the refusal did not distinguish an archived unanswered hold from an unfinished one"
  assert_grep "restore it to the active backlog" "$home/open-verify.err" \
    "the archived unanswered refusal did not name its recovery"
  if run_teardown "$home" "$id" > "$home/open-teardown.out" 2> "$home/open-teardown.err"; then
    fail "an archived captain call nobody answered allowed teardown"
  fi
  assert_present "$home/state/$id.meta" "the archived unanswered refusal removed task metadata"
  pass "an archived captain call that was never answered refuses instead of passing as still held"
}

# The archive is shared writable state: tasks-axi appends a `## Archived <stamp>`
# block to it from inside a hold of the LIVE BACKLOG's lock every time a prune
# runs, and every `tasks-axi done <id>` prunes. Archive repair rewrites the whole
# file, so it has to take that same lock or a concurrent append is read before
# and overwritten after - losing archived history for good.
# <home> <origin> - the origin task a captain hold hangs off, in the shape the
# rescue below needs: a started scout with a completed decision inventory.
seed_decision_origin() {  # <home> <origin> <title>
  local home=$1 origin=$2 title=$3
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "$title" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# %s\n\nThe captain choice is recorded.\n' "$title" > "$home/data/$origin/report.md"
}

# Raise the same decision key again after its previous record was pruned. This
# is the ordinary path, not a contrivance: `hold` only consults the live
# backlog, so a pruned identity has no live record and a fresh one is created
# under the very same deterministic id.
rehold_after_prune() {  # <home> <origin> <key> <title> <reason> <repo>
  run_shim "$1" hold "$2" "$3" --title "$4" --reason "$5" --repo "$6" >/dev/null
}

# The record shape a hand rescue leaves behind: retention pruned a closed
# captain hold out of the live backlog while a scout's teardown gate still
# needed it, so the record was restored into the backlog and the pruned copy
# stayed in the archive. Both files then carry the same identity with different
# bodies, and only the live one is current.
test_live_backlog_record_outranks_its_archived_copy() {
  local home origin key hold title reason repo
  origin=sample-consolidate-plan
  key=sample-round-limit
  hold="$origin-decision-$key"
  title="Choose how to unblock the sample consolidation plan"
  reason="captain sample consolidation choice pending"
  repo=sample

  # Live copy closed with no durable decision, archived copy durable. Reading
  # the archive here would pass the gate on a body belonging to a previous
  # incarnation of this identity, so live precedence has to refuse.
  home=$(make_home live-outranks-archive)
  seed_decision_origin "$home" "$origin" "$title"
  run_shim "$home" hold "$origin" "$key" --title "$title" --reason "$reason" --repo "$repo" >/dev/null
  run_shim "$home" complete "$origin" "$key" >/dev/null
  printf 'Take option 1 and install the missing deploy-gate unit first.\n' > "$home/archived-decision.txt"
  run_shim "$home" answer "$origin" "$key" --decision-file "$home/archived-decision.txt" >/dev/null
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null
  assert_grep "$hold" "$home/data/done-archive.md" "the durable decision never reached the archive"
  rehold_after_prune "$home" "$origin" "$key" "$title" "$reason" "$repo"
  tasks_in "$home" "done" "$hold" >/dev/null
  assert_grep "$hold" "$home/data/backlog.md" "the restored live record is not in the live backlog"
  if run_shim "$home" verify "$origin" > "$home/live-invalid.out" 2> "$home/live-invalid.err"; then
    fail "a live record with no durable decision passed the gate on its archived copy's body"
  fi
  assert_grep "neither held for the captain nor closed with a recorded captain answer" "$home/live-invalid.err" \
    "the refusal did not come from the live record"
  assert_no_grep "absent from the active backlog" "$home/live-invalid.err" \
    "a record present in both files was reported as absent"

  # The mirror: the live copy carries the durable decision and the archived one
  # does not. Preferring the archive would refuse work that is genuinely done.
  home=$(make_home live-outranks-stale-archive)
  seed_decision_origin "$home" "$origin" "$title"
  run_shim "$home" hold "$origin" "$key" --title "$title" --reason "$reason" --repo "$repo" >/dev/null
  run_shim "$home" complete "$origin" "$key" >/dev/null
  tasks_in "$home" "done" "$hold" >/dev/null
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null
  assert_grep "$hold" "$home/data/done-archive.md" "the undecided copy never reached the archive"
  rehold_after_prune "$home" "$origin" "$key" "$title" "$reason" "$repo"
  printf 'Take option 1 and install the missing deploy-gate unit first.\n' > "$home/live-decision.txt"
  run_shim "$home" answer "$origin" "$key" --decision-file "$home/live-decision.txt" >/dev/null
  assert_grep "$hold" "$home/data/backlog.md" "the durable live record is not in the live backlog"
  run_shim "$home" verify "$origin" >/dev/null 2> "$home/live-valid.err" \
    || fail "a durable live record was refused because its archived copy is stale: $(cat "$home/live-valid.err")"
  run_teardown "$home" "$origin" >/dev/null 2> "$home/live-valid-teardown.err" \
    || fail "the durable live record still blocked teardown: $(cat "$home/live-valid-teardown.err")"
  pass "a hold identity in both the live backlog and the archive is decided by the live record alone"
}

test_live_backlog_read_errors_never_fall_back_to_archive() {
  local home origin key hold title reason
  origin=sample-live-read-error
  key=route
  hold="$origin-decision-$key"
  title="Choose the live error route"
  reason="captain live error route pending"
  home=$(make_home live-read-error)
  seed_decision_origin "$home" "$origin" "$title"
  run_shim "$home" hold "$origin" "$key" --title "$title" --reason "$reason" --repo sample >/dev/null
  run_shim "$home" complete "$origin" "$key" >/dev/null
  printf 'Use the archived route from the previous incarnation.\n' > "$home/archived-decision.txt"
  run_shim "$home" answer "$origin" "$key" --decision-file "$home/archived-decision.txt" >/dev/null
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null
  rehold_after_prune "$home" "$origin" "$key" "$title" "$reason" sample
  tasks_in "$home" "done" "$hold" >/dev/null
  assert_grep "$hold" "$home/data/backlog.md" "the current unresolved hold is not live"
  assert_grep "$hold" "$home/data/done-archive.md" "the older durable hold is not archived"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show ]; then
  printf 'error: could not parse the live backlog configuration\ncode: CONFIG_ERROR\n' >&2
  exit 1
fi
exec "${REAL_TASKS_AXI:?}" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"
  if run_shim "$home" verify "$origin" > "$home/verify.out" 2> "$home/verify.err"; then
    fail "a live backlog read error passed verification through an older archive record"
  fi
  assert_grep "could not read captain-held task $hold from the active backlog" "$home/verify.err" \
    "the live backlog error was reported as an absent record"
  assert_grep "code: CONFIG_ERROR" "$home/verify.err" \
    "the live backlog error details were not preserved"
  assert_no_grep "absent from the active backlog and configured archive" "$home/verify.err" \
    "the live backlog error was collapsed into archive absence"
  pass "live backlog read errors refuse without consulting older archive records"
}

# The archive is append-only and hold ids are deterministic, so one identity can
# legitimately be archived more than once. The newest occurrence is the current
# record; the older ones are previous incarnations and must be left alone.
test_newest_archived_occurrence_decides_and_repair_touches_only_it() {
  local home origin key hold archive lock title reason
  origin=sample-duplicate-archive
  key=route
  hold="$origin-decision-$key"
  title="Choose the duplicated route"
  reason="captain duplicated route pending"

  home=$(make_home duplicate-archive-newest)
  archive="$home/data/done-archive.md"
  lock="$home/data/backlog.md.lock"
  seed_decision_origin "$home" "$origin" "$title"
  run_shim "$home" hold "$origin" "$key" --title "$title" --reason "$reason" --repo sample >/dev/null
  run_shim "$home" complete "$origin" "$key" >/dev/null
  printf 'First captain answer under duplicate archive.\n' > "$home/first-decision.txt"
  run_shim "$home" answer "$origin" "$key" --decision-file "$home/first-decision.txt" >/dev/null
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null

  # A second incarnation of the same identity, closed with no captain decision,
  # archived after the first. It is the newest, so it is the one that decides.
  rehold_after_prune "$home" "$origin" "$key" "$title" "$reason" sample
  tasks_in "$home" "done" "$hold" >/dev/null
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null
  assert_no_grep "$hold" "$home/data/backlog.md" "both incarnations should have been pruned out of the live backlog"
  [ "$(grep -c "^- \[x\] $hold - " "$archive")" -eq 2 ] \
    || fail "the archive should now carry two occurrences of $hold"

  if run_shim "$home" verify "$origin" > "$home/dup.out" 2> "$home/dup.err"; then
    fail "an older durable occurrence satisfied the gate for a newest occurrence that has no decision"
  fi
  assert_grep "neither held for the captain nor closed with a recorded captain answer" "$home/dup.err" \
    "the refusal did not come from the newest archived occurrence"
  assert_no_grep "absent from the active backlog" "$home/dup.err" \
    "a duplicated archived identity was reported as absent"

  printf 'Repaired captain answer for the newest occurrence.\n' > "$home/repair-decision.txt"
  printf 'another-tasks-axi-holder\n' > "$lock"
  before=$(cat "$archive")
  if run_shim "$home" repair "$origin" "$key" --decision-file "$home/repair-decision.txt" \
      > "$home/dup-locked.out" 2> "$home/dup-locked.err"; then
    rm -f "$lock"
    fail "repair rewrote a duplicated archive while another writer held the backlog lock"
  fi
  [ "$(cat "$archive")" = "$before" ] \
    || { rm -f "$lock"; fail "a refused repair still modified the duplicated archive"; }
  rm -f "$lock"

  run_shim "$home" repair "$origin" "$key" --decision-file "$home/repair-decision.txt" >/dev/null \
    || fail "repair could not record the captain decision on the newest archived occurrence"
  [ "$(grep -c "Resolution mode: repaired" "$archive")" -eq 1 ] \
    || fail "repair did not record exactly one repaired resolution"
  [ "$(grep -c "Resolution mode: answered" "$archive")" -eq 1 ] \
    || fail "repair changed an older archived occurrence's resolution"
  assert_grep "First captain answer under duplicate archive." "$archive" \
    "repair overwrote the older occurrence's captain decision"
  assert_grep "Repaired captain answer for the newest occurrence." "$archive" \
    "repair did not record the new captain decision"
  [ ! -f "$lock" ] || fail "repair left the backlog lock behind"
  run_shim "$home" verify "$origin" >/dev/null 2> "$home/dup-verify.err" \
    || fail "the repaired newest occurrence did not satisfy the gate: $(cat "$home/dup-verify.err")"

  # Two occurrences inside ONE archived block carry no ordering between them, so
  # there is no newest to read. That is ambiguity, not absence, and the refusal
  # has to say which identity and how many of it.
  home=$(make_home duplicate-archive-ambiguous)
  archive="$home/data/done-archive.md"
  seed_decision_origin "$home" "$origin" "$title"
  run_shim "$home" hold "$origin" "$key" --title "$title" --reason "$reason" --repo sample >/dev/null
  run_shim "$home" complete "$origin" "$key" >/dev/null
  printf 'Only captain answer before the ambiguous archive.\n' > "$home/amb-decision.txt"
  run_shim "$home" answer "$origin" "$key" --decision-file "$home/amb-decision.txt" >/dev/null
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null
  {
    printf '\n## Archived 2026-08-23\n'
    printf -- '- [x] %s - %s (repo: sample) (kind: captain) (done 2026-08-23) (hold: %s) (hold-kind: captain)\n' \
      "$hold" "$title" "$reason"
    printf '  Origin: %s\n' "$origin"
    printf -- '- [x] %s - %s (repo: sample) (kind: captain) (done 2026-08-23) (hold: %s) (hold-kind: captain)\n' \
      "$hold" "$title" "$reason"
    printf '  Origin: %s\n' "$origin"
  } >> "$archive"
  if run_shim "$home" verify "$origin" > "$home/amb.out" 2> "$home/amb.err"; then
    fail "an archive with no single newest occurrence satisfied the gate"
  fi
  assert_grep "$hold" "$home/amb.err" "the ambiguity refusal did not name the identity"
  assert_grep "3 occurrences" "$home/amb.err" "the ambiguity refusal did not name the occurrence count"
  assert_no_grep "absent from the active backlog" "$home/amb.err" \
    "an ambiguous archive was reported as an absent record"
  pass "duplicated archived occurrences are decided by the newest one, repaired in place, and refused as ambiguous when there is no newest"
}

test_archive_repair_serializes_on_the_backlog_lock() {
  local home id hold lock archive before
  home=$(make_home archive-repair-lock)
  cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/decisions/closed.md"
done_keep = 10
EOF
  archive="$home/data/decisions/closed.md"
  lock="$home/data/backlog.md.lock"

  id=sample-archive-lock-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review under archive lock" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Archive lock review\n\nThe answer still needs a durable body.\n' > "$home/data/$id/report.md"
  hold=$(run_shim "$home" hold "$id" submission \
    --title "Choose under the archive lock" --reason "captain archive lock pending" --repo sample)
  run_shim "$home" complete "$id" submission >/dev/null
  tasks_in "$home" "done" "$hold" >/dev/null
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null
  assert_grep "$hold" "$archive" "the configured archive did not receive the closed hold"
  printf 'Do not submit under the lock.\n' > "$home/locked-decision.txt"

  # Another tasks-axi writer holds the backlog lock, exactly as a prune does
  # while it is appending to this archive.
  printf 'another-tasks-axi-holder\n' > "$lock"
  before=$(cat "$archive")
  if run_shim "$home" repair "$id" submission --decision-file "$home/locked-decision.txt" \
      > "$home/locked-repair.out" 2> "$home/locked-repair.err"; then
    rm -f "$lock"
    fail "archive repair rewrote the archive while another writer held the backlog lock"
  fi
  [ "$(cat "$archive")" = "$before" ] \
    || { rm -f "$lock"; fail "a refused archive repair still modified the archive"; }
  assert_grep "could not record the captain decision" "$home/locked-repair.err" \
    "the lock refusal did not report that the decision was not recorded"
  [ -f "$lock" ] \
    || fail "archive repair removed a lock it never acquired"
  [ "$(cat "$lock")" = "another-tasks-axi-holder" ] \
    || fail "archive repair overwrote another writer's lock token"

  # What that other writer was doing: appending a freshly pruned block. A repair
  # that snapshots the archive before the append and renames after it would drop
  # this block entirely.
  printf '\n## Archived 2026-08-23T00:00:00Z\n- [x] sample-concurrently-archived - Pruned by another agent\n' \
    >> "$archive"
  rm -f "$lock"

  run_shim "$home" repair "$id" submission --decision-file "$home/locked-decision.txt" >/dev/null \
    || fail "archive repair could not proceed once the backlog lock was released"
  assert_grep "Resolution mode: repaired" "$archive" \
    "the unblocked archive repair did not record its durable resolution body"
  assert_grep "sample-concurrently-archived" "$archive" \
    "the archive repair discarded a block another writer appended while it was waiting"
  [ ! -f "$lock" ] || fail "archive repair left the backlog lock behind"
  run_shim "$home" verify "$id" >/dev/null \
    || fail "the repaired decision did not satisfy verification after the lock round trip"
  pass "archive repair takes tasks-axi's own backlog lock, so a concurrent archive append is never lost"
}

test_archive_repair_honors_tasks_axi_file_lock_override() {
  local home origin key hold override lock archive before
  home=$(make_home archive-repair-file-override)
  origin=sample-file-override-review
  key=route
  hold="$origin-decision-$key"
  override="$home/data/override-backlog.md"
  lock="$override.lock"
  archive="$home/data/done-archive.md"
  cp "$home/data/backlog.md" "$override"
  TASKS_AXI_FILE="$override" seed_decision_origin "$home" "$origin" "Review the override lock"
  TASKS_AXI_FILE="$override" run_shim "$home" hold "$origin" "$key" \
    --title "Choose under the override lock" --reason "captain override route pending" --repo sample >/dev/null
  TASKS_AXI_FILE="$override" run_shim "$home" complete "$origin" "$key" >/dev/null
  TASKS_AXI_FILE="$override" tasks_in "$home" "done" "$hold" >/dev/null
  TASKS_AXI_FILE="$override" tasks_in "$home" prune --state "done" --keep 0 >/dev/null
  printf 'Repair the captain answer under the override lock.\n' > "$home/decision.txt"
  printf 'another-tasks-axi-holder\n' > "$lock"
  before=$(cat "$archive")
  if TASKS_AXI_FILE="$override" run_shim "$home" repair "$origin" "$key" \
      --decision-file "$home/decision.txt" > "$home/repair.out" 2> "$home/repair.err"; then
    rm -f "$lock"
    fail "archive repair ignored the TASKS_AXI_FILE lock"
  fi
  [ "$(cat "$archive")" = "$before" ] \
    || { rm -f "$lock"; fail "a refused override-lock repair modified the archive"; }
  [ "$(cat "$lock")" = "another-tasks-axi-holder" ] \
    || { rm -f "$lock"; fail "archive repair changed the override lock token"; }
  printf '\n## Archived 2026-08-23T01:00:00Z\n- [x] sample-override-concurrent - Concurrent archive append\n' \
    >> "$archive"
  rm -f "$lock"
  TASKS_AXI_FILE="$override" run_shim "$home" repair "$origin" "$key" \
    --decision-file "$home/decision.txt" >/dev/null \
    || fail "archive repair failed after the TASKS_AXI_FILE lock was released"
  assert_grep "sample-override-concurrent" "$archive" \
    "archive repair discarded an append protected by the override lock"
  [ ! -f "$lock" ] || fail "archive repair left the TASKS_AXI_FILE lock behind"
  pass "archive repair serializes on the TASKS_AXI_FILE backlog lock"
}

test_archive_body_boundaries_preserve_column_zero_content() {
  local home origin key hold archive raw expected_size
  origin=sample-raw-archive
  key=route
  hold="$origin-decision-$key"
  home=$(make_home archive-raw-reader)
  write_origin_meta "$home" "$origin"
  printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$key" >> "$home/state/$origin.meta"
  archive="$home/data/done-archive.md"
  cat > "$archive" <<EOF
## Archived 2026-08-23
- [x] $hold - Choose the raw route (repo: sample) (kind: captain) (done 2026-08-23) (hold: captain raw route pending) (hold-kind: captain)
Resolution recorded by fm-decision-hold.
Routed work:
(none)
EOF
  if run_shim "$home" verify "$origin" > "$home/raw-verify.out" 2> "$home/raw-verify.err"; then
    fail "column-zero archive text was accepted as a captain decision body"
  fi
  assert_grep "neither held for the captain nor closed with a recorded captain answer" "$home/raw-verify.err" \
    "column-zero archive text did not remain outside the task body"

  home=$(make_home archive-raw-repair)
  seed_decision_origin "$home" "$origin" "Review raw archive preservation"
  run_shim "$home" hold "$origin" "$key" --title "Choose the raw route" \
    --reason "captain raw route pending" --repo sample >/dev/null
  run_shim "$home" complete "$origin" "$key" >/dev/null
  tasks_in "$home" "done" "$hold" >/dev/null
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null
  archive="$home/data/done-archive.md"
  raw="$home/raw.expected"
  printf 'Operator column-zero note with trailing spaces  \nSecond raw line\t' > "$raw"
  cat "$raw" >> "$archive"
  printf 'Repair while preserving adjacent raw archive text.\n' > "$home/decision.txt"
  run_shim "$home" repair "$origin" "$key" --decision-file "$home/decision.txt" >/dev/null \
    || fail "archive repair failed beside column-zero raw content"
  expected_size=$(LC_ALL=C wc -c < "$raw" | tr -d ' ')
  tail -c "$expected_size" "$archive" > "$home/raw.actual"
  cmp -s "$raw" "$home/raw.actual" \
    || fail "archive repair changed or deleted adjacent column-zero content"
  pass "archive parsing and repair preserve column-zero content outside task bodies"
}

# The completion attestation shares the task metadata file with the harness
# session binder, which republishes the whole record on every completed turn.
# Appending outside that shared lock writes into the replaced inode, so the
# attestation silently disappears and the review gate re-fires.
test_completion_attestation_waits_for_the_task_metadata_lock() {
  local home id meta lock holder completer waited
  home=$(make_home attestation-lock)
  id=sample-lock-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample metadata locking" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the locking fixture"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample locking review\n\nNothing needs a captain decision.\n' > "$home/data/$id/report.md"
  meta="$home/state/$id.meta"
  lock="$home/state/.meta-$id.lock"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash -c \
    '. "$1"; fm_lock_acquire_wait "$2"; while [ -e "$3" ]; do sleep 0.1; done' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$lock" "$home/hold-open" &
  holder=$!
  : > "$home/hold-open"
  waited=0
  while [ ! -d "$lock" ] && [ ! -L "$lock" ]; do
    sleep 0.1
    waited=$((waited + 1))
    [ "$waited" -lt 50 ] || { kill "$holder" 2>/dev/null || true; fail "the metadata lock was never taken"; }
  done

  run_shim "$home" complete "$id" --none > "$home/complete.out" 2> "$home/complete.err" &
  completer=$!
  sleep 1
  if grep -q 'decisions_reviewed=1' "$meta"; then
    rm -f "$home/hold-open"
    kill "$holder" "$completer" 2>/dev/null || true
    wait "$holder" "$completer" 2>/dev/null || true
    fail "the completion attestation was appended while another writer held the task metadata lock"
  fi
  rm -f "$home/hold-open"
  wait "$holder" 2>/dev/null || true
  wait "$completer" || fail "completion failed once the metadata lock was released: $(cat "$home/complete.err")"
  assert_grep "decisions_reviewed=1" "$meta" "the attestation was not recorded after the lock was released"
  assert_grep "decision_keys=" "$meta" "the attestation recorded no decision inventory"
  pass "the completion attestation serializes on the shared task metadata lock"
}

test_uninventoried_report_decision_refuses_completion
test_completion_gate_attests_and_transfers
test_answer_records_and_closes
test_release_frees_held_work
test_deferral_leaves_captains_call_until_due
test_out_of_band_close_is_recordable
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
test_secondmate_hold_stays_in_authoritative_home
test_bound_channel_answers_close_at_answer_time
test_unbound_source_closes_no_hold
test_legacy_identities_keep_working
test_chat_channel_feeds_the_same_keyed_answer_intake
test_origin_slug_validation_precedes_path_construction
test_status_resolution_over_an_open_hold_is_signalled
test_legitimate_holds_produce_no_divergence_signal
test_archived_decisions_keep_the_scout_completion_gate_strong
test_archived_open_hold_is_never_read_as_actively_held
test_live_backlog_record_outranks_its_archived_copy
test_live_backlog_read_errors_never_fall_back_to_archive
test_newest_archived_occurrence_decides_and_repair_touches_only_it
test_archive_repair_serializes_on_the_backlog_lock
test_archive_repair_honors_tasks_axi_file_lock_override
test_archive_body_boundaries_preserve_column_zero_content
test_completion_attestation_waits_for_the_task_metadata_lock
