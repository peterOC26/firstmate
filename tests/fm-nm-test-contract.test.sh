#!/usr/bin/env bash
# Contract: parsed .no-mistakes.yaml must leave commands.test absent or empty.
# Contract: commit subjects on this branch, read through git, must not greet.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"

test_nm_has_no_deterministic_test_command() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local val
  val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
cmds = doc["commands"] || {}
val = cmds.is_a?(Hash) ? cmds["test"] : nil
puts (val.nil? || val == false || val == "") ? "" : val.inspect
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  if [ -n "$val" ]; then
    fail "commands.test must be absent or empty so Test stays intent-targeted; got: $val"
  fi
  pass "no-mistakes does not configure commands.test"
}

# Recorded commit subjects are the pipeline's observable output. The oracle
# is the chat-address rule: a subject that greets is the failure. Commits
# already on origin/main stay out of the range, including older subjects.
test_branch_commit_subjects_do_not_greet() {
  local base subjects subject
  base=$(git -C "$ROOT" rev-parse --verify --quiet origin/main) \
    || fail "origin/main is required to list this branch's commit subjects"
  subjects=$(git -C "$ROOT" log --format=%s "${base}..HEAD") \
    || fail "failed to read commit subjects from ${base}..HEAD"
  while IFS= read -r subject; do
    [ -n "$subject" ] || continue
    case $subject in
      *"Aye, aye, captain"*|*"Captain,"*)
        fail "commit subject greets: $subject"
        ;;
    esac
  done <<< "$subjects"
  pass "commit subjects on this branch do not greet"
}

test_nm_has_no_deterministic_test_command
test_branch_commit_subjects_do_not_greet
