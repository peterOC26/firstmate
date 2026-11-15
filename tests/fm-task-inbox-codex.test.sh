#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

expected_doorbell=': Firstmate instruction waiting: read the steering inbox'
footer=$'GPT-6.1-Sol high · ~/project · Read worker role contract\n← for agents · ? for shortcuts ⚠ 1 warning · f2 to view'
test_screen=$'transcript\n\n› : Firstmate instruction waiting:\nread the steering inbox\n'"$footer"
submits=0
fm_backend_source() { :; }
fm_backend_capture() { printf '%s\n' "$test_screen"; }
fm_backend_agent_state() { printf live; }
fm_backend_busy_state() { printf idle; }
fm_backend_composer_state() {
  fm_composer_classify_screen $'styled=1\ncursor=0\nidentity=0' "$test_screen"
}
fm_task_inbox_doorbell_line() { printf '%s' "$expected_doorbell"; }
fm_backend_send_key() {
  [ "$3" = Enter ] || return 1
  submits=$((submits + 1))
  test_screen=$'transcript\n\n›\n'"$footer"
}
fm_backend_send_text_submit() { return 1; }

fm_task_inbox_composer_holds mock pane "$expected_doorbell" \
  || fail 'wrapped doorbell followed by Codex status and hints was not recognized'
fm_task_inbox_ring mock pane record \
  || fail 're-ring did not submit the recognized doorbell'
[ "$submits" = 1 ] || fail "expected one Enter, got $submits"
for extra in 'and a draft' $'and a draft\n12k tokens'; do
  test_screen=$'transcript\n\n› '"$expected_doorbell"$'\n'"$extra"$'\n'"$footer"
  if fm_task_inbox_composer_holds mock pane "$expected_doorbell"; then
    fail 'additional draft text was accepted as our doorbell'
  fi
  rc=0
  fm_task_inbox_ring mock pane record || rc=$?
  [ "$rc" = 1 ] || fail "additional draft must skip re-ring, got $rc"
  [ "$submits" = 1 ] || fail 'additional draft was submitted'
done
test_screen=$'transcript\n\n› '"$expected_doorbell"
fm_task_inbox_composer_holds mock pane "$expected_doorbell" || fail 'plain doorbell no longer matches'
pass 'Codex stuck-doorbell recovery ignores trailing footers and preserves draft protection'
