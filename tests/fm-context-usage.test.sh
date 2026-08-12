#!/usr/bin/env bash
# Portable behavior tests for session-bound context usage and non-blocking warnings.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

READER="$ROOT/bin/fm-context-usage.sh"
BINDER="$ROOT/bin/fm-context-bind.sh"
WARNING="$ROOT/bin/fm-context-warning.sh"
LIB="$ROOT/bin/fm-context-usage-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-context-usage)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
CONFIG="$HOME_DIR/config"
CODEX_ROOT="$TMP_ROOT/alternate-codex-home"
CLAUDE_ROOT="$TMP_ROOT/alternate-claude-home"
WT="$TMP_ROOT/worktree"
mkdir -p "$STATE" "$CONFIG" "$HOME_DIR/data" "$HOME_DIR/projects" \
  "$CODEX_ROOT/sessions/2026/08/12" "$CLAUDE_ROOT/projects/worktree" "$WT"

EPOCH=11111111-1111-4111-8111-111111111111
CODEX_ID=22222222-2222-4222-8222-222222222222
CODEX_OTHER=33333333-3333-4333-8333-333333333333
CLAUDE_ID=44444444-4444-4444-8444-444444444444

threshold_read() {
  bash -c '. "$1"; fm_context_warning_threshold "$2"' _ "$LIB" "$1" 2>&1
}

test_threshold_is_preference_not_ceiling() {
  local out rc
  out=$(threshold_read "$CONFIG"); rc=$?
  expect_code 0 "$rc" "absent context warning should use the default"
  [ "$out" = 150000 ] || fail "absent context warning returned '$out'"
  printf '900000\n' > "$CONFIG/context-warning"
  out=$(threshold_read "$CONFIG"); rc=$?
  expect_code 0 "$rc" "a threshold above 150000 must be allowed"
  [ "$out" = 900000 ] || fail "raised context warning returned '$out'"
  printf '25000\n' > "$CONFIG/context-warning"
  [ "$(threshold_read "$CONFIG")" = 25000 ] || fail "lowered context warning was refused"
  for value in 0 -1 nope $'12\n13'; do
    printf '%s\n' "$value" > "$CONFIG/context-warning"
    out=$(threshold_read "$CONFIG"); rc=$?
    expect_code 1 "$rc" "invalid warning threshold '$value' should fail to read"
  done
  printf '120000' > "$CONFIG/context-warning"
  out=$(threshold_read "$CONFIG"); rc=$?
  expect_code 1 "$rc" "unterminated warning threshold should fail to read"
  rm -f "$CONFIG/context-warning"
  pass "context warning defaults to 150000 and is freely adjustable in either direction"
}

write_meta() {  # <id> <harness> <root> <sid> <version> [extra]
  local id=$1 harness=$2 root=$3 sid=$4 version=$5 extra=${6:-}
  cat > "$STATE/$id.meta" <<EOF
window=fixture:fm-$id
endpoint_task_id=$id
worktree=$WT
project=$TMP_ROOT/project
harness=$harness
kind=ship
harness_session_epoch=$EPOCH
harness_version=$version
harness_session_root=$root
harness_session_id=$sid
harness_session_cwd=$WT
$extra
EOF
}

field_of() {  # <id> <column>
  FM_HOME="$HOME_DIR" "$READER" "$1" | awk -F '\t' -v column="$2" 'NR==2 {print $column}'
}
tokens_of() { field_of "$1" 3; }
window_of() { field_of "$1" 5; }
status_of() { field_of "$1" 6; }
detail_of() { field_of "$1" 7; }

write_codex_transcript() {  # <path> <id> <tokens> <window> [version]
  local path=$1 id=$2 tokens=$3 window=$4 version=${5:-0.147.0}
  cat > "$path" <<EOF
{"type":"session_meta","payload":{"id":"$id","cwd":"$WT","cli_version":"$version"}}
{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":$tokens},"total_token_usage":{"total_tokens":900000},"model_context_window":$window}}}
EOF
}

test_codex_exact_metric_multiple_sessions_and_statuses() {
  local file other
  file="$CODEX_ROOT/sessions/2026/08/12/rollout-bound-$CODEX_ID.jsonl"
  other="$CODEX_ROOT/sessions/2026/08/12/rollout-newer-$CODEX_OTHER.jsonl"
  write_codex_transcript "$file" "$CODEX_ID" 95284 258400
  write_codex_transcript "$other" "$CODEX_OTHER" 249999 258400
  write_meta codex-ok codex "$CODEX_ROOT" "$CODEX_ID" 0.147.0
  [ "$(tokens_of codex-ok)" = 95284 ] || fail "Codex reader did not use last_token_usage.total_tokens"
  [ "$(window_of codex-ok)" = 258400 ] || fail "Codex native context window was not reported"
  [ "$(status_of codex-ok)" = under ] || fail "Codex bound session should classify under"
  printf '90000\n' > "$CONFIG/context-warning"
  [ "$(status_of codex-ok)" = warning ] || fail "usage above the configured threshold should warn"
  write_codex_transcript "$file" "$CODEX_ID" 300000 258400
  [ "$(status_of codex-ok)" = over ] || fail "usage above the runtime-reported window should classify over"
  rm -f "$CONFIG/context-warning"
  pass "Codex selects the bound session, ignores cumulative usage, and keeps under/warning/over distinct"
}

test_truncated_and_malformed_jsonl() {
  local file
  file="$CODEX_ROOT/sessions/2026/08/12/rollout-bound-$CODEX_ID.jsonl"
  printf '%s\n%s\n%s' \
    "{\"type\":\"session_meta\",\"payload\":{\"id\":\"$CODEX_ID\",\"cwd\":\"$WT\",\"cli_version\":\"0.147.0\"}}" \
    '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":130000},"model_context_window":258400}}}' \
    '{"type":"event_msg"' > "$file"
  [ "$(tokens_of codex-ok)" = 130000 ] || fail "unterminated tail displaced the last complete record"
  printf '\n%s\n' '{broken-complete-line' >> "$file"
  [ "$(status_of codex-ok)" = unknown ] || fail "malformed complete JSON must be unknown"
  assert_contains "$(detail_of codex-ok)" "malformed complete JSON" "malformed detail was not explicit"
  pass "reader ignores an unterminated tail and rejects malformed complete JSON"
}

test_claude_finalized_conservative_metric() {
  local file
  file="$CLAUDE_ROOT/projects/worktree/$CLAUDE_ID.jsonl"
  cat > "$file" <<EOF
{"type":"assistant","sessionId":"$CLAUDE_ID","cwd":"$WT","version":"2.1.220","message":{"id":"msg-1","stop_reason":null,"usage":{"input_tokens":2,"cache_creation_input_tokens":30047,"cache_read_input_tokens":0,"output_tokens":1}}}
{"type":"assistant","sessionId":"$CLAUDE_ID","cwd":"$WT","version":"2.1.220","message":{"id":"msg-1","stop_reason":"end_turn","usage":{"input_tokens":2,"cache_creation_input_tokens":30047,"cache_read_input_tokens":5,"output_tokens":4}}}
EOF
  write_meta claude-ok claude "$CLAUDE_ROOT" "$CLAUDE_ID" 2.1.220
  [ "$(tokens_of claude-ok)" = 30058 ] || fail "Claude conservative finalized metric was not 30058"
  [ "$(status_of claude-ok)" = under ] || fail "Claude fixture should classify under"
  pass "Claude selects finalized usage and includes cache plus output tokens from an alternate config root"
}

test_unknown_identity_version_and_remote_cases() {
  write_meta missing-binding codex "$CODEX_ROOT" "$CODEX_ID" 0.147.0
  sed -i.bak '/^harness_session_id=/d' "$STATE/missing-binding.meta" && rm -f "$STATE/missing-binding.meta.bak"
  [ "$(status_of missing-binding)" = unknown ] || fail "missing binding must be unknown"
  write_meta conflict codex "$CODEX_ROOT" "$CODEX_ID" 0.147.0 'harness_session_conflict=1'
  [ "$(status_of conflict)" = unknown ] || fail "conflicting binding must be unknown"
  write_meta remote codex "$CODEX_ROOT" "$CODEX_ID" 0.147.0 'orca_remote=1'
  [ "$(status_of remote)" = unknown ] || fail "remote transcript must be unknown"
  assert_contains "$(detail_of remote)" "remote transcript" "remote unknown did not name reachability"
  write_meta new-version codex "$CODEX_ROOT" "$CODEX_ID" 0.148.0
  [ "$(status_of new-version)" = unknown ] || fail "unrecognized transcript version must be unknown"
  assert_contains "$(detail_of new-version)" "schema is unrecognized" "version detail was not explicit"
  pass "missing, conflicting, unrecognized-version, and remote bindings remain first-class unknown"
}

test_codex_notify_binding_relaunch_and_supervision_independence() {
  local id=bind-notify meta turn payload new_epoch new_id conflict_id out rc
  meta="$STATE/$id.meta"
  turn="$STATE/$id.turn-ended"
  cat > "$meta" <<EOF
window=fixture:fm-$id
endpoint_task_id=$id
worktree=$WT
harness=codex
harness_session_epoch=$EPOCH
pr=https://example.invalid/pull/1
x_request=relay-request-1
EOF
  payload=$(jq -cn --arg id "$CODEX_ID" --arg cwd "$WT" '{type:"agent-turn-complete","thread-id":$id,cwd:$cwd}')
  "$BINDER" codex-notify "$STATE" "$id" "$EPOCH" "$WT" "$turn" "$payload"
  assert_grep "harness_session_id=$CODEX_ID" "$meta" "notify did not bind thread id"
  assert_grep 'pr=https://example.invalid/pull/1' "$meta" "notify erased the PR metadata writer's field"
  assert_grep 'x_request=relay-request-1' "$meta" "notify erased the Relay metadata writer's field"
  [ -f "$turn" ] || fail "notify did not preserve turn-end signal"

  new_epoch=55555555-5555-4555-8555-555555555555
  new_id=66666666-6666-4666-8666-666666666666
  sed -e "s/harness_session_epoch=$EPOCH/harness_session_epoch=$new_epoch/" \
      -e '/^harness_session_/d' "$meta" > "$meta.new"
  printf 'harness_session_epoch=%s\n' "$new_epoch" >> "$meta.new"
  mv "$meta.new" "$meta"
  rm -f "$turn"
  out=$("$BINDER" codex-notify "$STATE" "$id" "$EPOCH" "$WT" "$turn" "$payload" 2>&1); rc=$?
  expect_code 1 "$rc" "stale notify should fail"
  assert_contains "$out" "stale Codex notification incarnation" "stale notify diagnostic lost incarnation cause"
  [ -f "$turn" ] || fail "binding failure must not suppress the turn-end notification"
  rm -f "$turn"
  payload=$(jq -cn --arg id "$new_id" --arg cwd "$WT" '{type:"agent-turn-complete","thread-id":$id,cwd:$cwd}')
  "$BINDER" codex-notify "$STATE" "$id" "$new_epoch" "$WT" "$turn" "$payload"
  assert_grep "harness_session_id=$new_id" "$meta" "new incarnation did not replace binding"
  conflict_id=77777777-7777-4777-8777-777777777777
  payload=$(jq -cn --arg id "$conflict_id" --arg cwd "$WT" '{type:"agent-turn-complete","thread-id":$id,cwd:$cwd}')
  out=$("$BINDER" codex-notify "$STATE" "$id" "$new_epoch" "$WT" "$turn" "$payload" 2>&1); rc=$?
  expect_code 1 "$rc" "a conflicting thread id should fail binding"
  assert_grep 'harness_session_conflict=1' "$meta" "thread conflict was not recorded"
  [ -f "$turn" ] || fail "thread conflict must not suppress the turn-end notification"
  pass "Codex notify binds atomically, rejects stale relaunch callbacks, and never couples binding failure to supervision"
}

test_warning_transition_and_dedup() {
  local file out pending
  file="$CODEX_ROOT/sessions/2026/08/12/rollout-bound-$CODEX_ID.jsonl"
  write_codex_transcript "$file" "$CODEX_ID" 160000 258400
  rm -f "$STATE/.codex-ok.context-warning"
  out=$(FM_HOME="$HOME_DIR" "$WARNING" codex-ok)
  assert_contains "$out" "context usage warning" "threshold crossing did not surface"
  [ -z "$(FM_HOME="$HOME_DIR" "$WARNING" codex-ok)" ] || fail "same warning state was not deduplicated"

  rm -f "$STATE/.codex-ok.context-warning"
  pending=$(printf '%s\t%s\t%s' "$STATE/.seen-codex-ok_turn-ended" '0:1' "$STATE/codex-ok.turn-ended")
  touch "$STATE/codex-ok.turn-ended"
  out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; context_warning_for_pending "$2"' \
    _ "$ROOT/bin/fm-watch.sh" "$pending")
  assert_contains "$out" "context usage warning" "watcher turn-end warning path did not surface"

  write_codex_transcript "$file" "$CODEX_ID" 100000 258400
  FM_HOME="$HOME_DIR" "$WARNING" codex-ok >/dev/null
  write_codex_transcript "$file" "$CODEX_ID" 170000 258400
  out=$(FM_HOME="$HOME_DIR" "$WARNING" codex-ok)
  assert_contains "$out" "context usage warning" "warning did not re-arm after returning under"
  pass "warning path surfaces a threshold transition, deduplicates it, and re-arms after usage falls under"
}

test_threshold_is_preference_not_ceiling
test_codex_exact_metric_multiple_sessions_and_statuses
test_truncated_and_malformed_jsonl
test_claude_finalized_conservative_metric
test_unknown_identity_version_and_remote_cases
test_codex_notify_binding_relaunch_and_supervision_independence
test_warning_transition_and_dedup
