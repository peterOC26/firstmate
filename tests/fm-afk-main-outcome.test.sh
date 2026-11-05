#!/usr/bin/env bash
# Main-handled away outcomes stay routine and silent, and the prompt says so.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-afk-main-outcome)
HELPER="$ROOT/bin/fm-afk-main-outcome.sh"
PROMPT="$ROOT/bin/fm-branch-prompt.sh"

test_helper_appends_a_silent_routine_row_and_refuses_a_captain_verdict() {
  local dir out rc store
  dir="$TMP_ROOT/outcome"
  mkdir -p "$dir/state"
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$HELPER" \
    --task job-1 --summary 'kept the window moving' --wake 'signal: job-1.status') \
    || fail "a routine append failed: $out"
  store=$(cat "$dir/state/branch-outcomes.jsonl")
  assert_contains "$store" '"verdict":"routine"' "the row was not routine"
  assert_contains "$store" '"silent":true' "the row was not silent"
  assert_contains "$store" '"task":"job-1"' "the row was not task-scoped"
  set +e
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$HELPER" \
    --task job-1 --verdict captain --summary 'ask the captain' 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a captain verdict was accepted: $out"
  assert_contains "$out" 'bin/fm-captain-hold.sh' "the refusal did not name the hold command"
  [ "$(grep -c '"task":"job-1"' "$dir/state/branch-outcomes.jsonl")" -eq 1 ] \
    || fail "a refused captain verdict still wrote a row"
  set +e
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$HELPER" \
    --task job-1 --summary 'again' --continuation 'keep going' 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a continuation was accepted: $out"
  [ "$(wc -l < "$dir/state/branch-outcomes.jsonl" | tr -d ' ')" -eq 1 ] \
    || fail "a refused continuation still wrote a row"
  pass "main records a silent routine outcome and refuses a captain verdict"
}

test_prompt_names_the_main_actor_contract_and_stays_byte_stable() {
  local first second
  first=$("$PROMPT") || fail "the branch prompt failed"
  second=$("$PROMPT") || fail "the branch prompt failed on the second run"
  [ "$first" = "$second" ] || fail "the branch prompt changed between runs"
  assert_contains "$first" 'Do not send the captain a message for routine work' "the prompt still sends routine work to the captain"
  assert_contains "$first" 'bin/fm-afk-main-outcome.sh' "the prompt does not name the outcome helper"
  assert_contains "$first" 'bin/fm-captain-hold.sh' "the prompt does not keep captain calls on the hold command"
  pass "the prompt states the main-actor contract and stays stable"
}

test_helper_appends_a_silent_routine_row_and_refuses_a_captain_verdict
test_prompt_names_the_main_actor_contract_and_stays_byte_stable
