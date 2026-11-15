#!/usr/bin/env bash
# Contracts for parsed .no-mistakes.yaml:
# - commands.test stays absent or empty.
# - document, test, and CI instruction fields carry the commit-subject
#   boundary, because those prompts store the summary field as the commit
#   subject and repository hooks never see that commit.
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

# The pipeline stores each step's summary field as the commit subject.
# Document, test, and CI prompts are the steps whose repository instruction
# fields are copied into that same prompt. Review fix prompts have no such
# field. The oracle is the chat-address boundary: a greeting in the subject
# is the failure this contract rejects.
COMMIT_SUBJECT_BOUNDARY="The summary field is the git commit subject, not a chat message, so it must not greet or address anyone."

test_nm_commit_summary_is_not_a_chat_message() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local missing
  missing=$(ruby -ryaml -e '
boundary = ARGV[0]
doc = YAML.load_file(ARGV[1]) || {}
fields = {
  "document.instructions" => (doc["document"].is_a?(Hash) ? doc["document"]["instructions"] : nil),
  "test.instructions" => (doc["test"].is_a?(Hash) ? doc["test"]["instructions"] : nil),
  "ci.instructions" => (doc["ci"].is_a?(Hash) ? doc["ci"]["instructions"] : nil),
}
missing = fields.select { |_name, text| !text.is_a?(String) || !text.include?(boundary) }.keys
puts missing.join(" ")
' "$COMMIT_SUBJECT_BOUNDARY" "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  if [ -n "$missing" ]; then
    fail "pipeline instruction fields omit the commit-subject boundary: $missing"
  fi
  pass "document, test, and CI prompts forbid a greeting in the commit summary"
}

test_nm_has_no_deterministic_test_command
test_nm_commit_summary_is_not_a_chat_message
