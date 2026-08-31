#!/usr/bin/env bash
# Behavior gate for .github/workflows/no-mistakes-required.yml.
#
# The job that decides whether a PR was raised through no-mistakes is a shell
# script embedded in a workflow. It has no local runner, so a change to it can
# only be discovered by a red required check on a PR that is already pushed.
#
# Regression origin: the upstream sync merged a hardened check that demands a
# `<!-- no-mistakes-pipeline-attestation:v1 ... -->` comment from no-mistakes
# >= 1.46.0. This fork's pipeline runs 1.45.x and emits the signature line
# only, so the merge made the required check refuse every PR the fork can
# raise, including the sync PR carrying the merge.
#
# These cases run the workflow's own step script through bash with the same
# environment GitHub gives it, and assert the exit status and operator-facing
# diagnostic. The script is lifted out of the workflow by reading the step's
# literal block scalar, so the behavior under test is the one CI executes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-required)
CHECK="$TMP_ROOT/check.sh"

MARKER='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'

# Lift the step's `run: |` literal block scalar out of the workflow. The block
# is located by indentation, which is all a literal block scalar encodes, and
# bin/fm-lint-workflows.sh owns proving the file is well-formed YAML.
extract_check_script() {
  python3 - "$WORKFLOW" "$CHECK" <<'PY'
import io
import sys

source, dest = sys.argv[1], sys.argv[2]
lines = io.open(source, encoding="utf-8").read().split("\n")

starts = [i for i, line in enumerate(lines) if line.strip() == "run: |"]
if len(starts) != 1:
    sys.exit("expected exactly one 'run: |' block, found %d" % len(starts))

start = starts[0]
key_indent = len(lines[start]) - len(lines[start].lstrip())

body = []
for line in lines[start + 1:]:
    if not line.strip():
        body.append("")
        continue
    if len(line) - len(line.lstrip()) <= key_indent:
        break
    body.append(line)

while body and not body[-1]:
    body.pop()
if not body:
    sys.exit("run block is empty")

pad = min(len(l) - len(l.lstrip()) for l in body if l)
io.open(dest, "w", encoding="utf-8").write(
    "\n".join(l[pad:] if l else "" for l in body) + "\n"
)
PY
}

# Run the lifted script exactly as the runner does: `bash -e <file>` with the
# step's four environment values bound.
run_check() {
  local body=$1 head=${2:-sample-sha} out rc=0
  out=$(PR_BODY="$body" PR_AUTHOR=sample-author PR_NUMBER=4242 \
    PR_HEAD_SHA="$head" \
    bash -e "$CHECK" 2>&1) || rc=$?
  printf '%s\n' "$out"
  return "$rc"
}

signature_body() {
  printf '## Pipeline\n\n%s\n' "$MARKER"
}

attested_body() {
  printf '## Pipeline\n\n%s\n\n<!-- no-mistakes-pipeline-attestation:v1 %s -->\n' \
    "$MARKER" "$1"
}

extract_check_script || fail "could not lift the check script out of $WORKFLOW"

test_body_without_signature_is_refused() {
  # Control. This also proves the lifted script is the real gate rather than an
  # empty or mis-sliced fixture that would pass everything by accident.
  local out rc=0
  out=$(run_check "## Intent

A pull request opened by hand.") || rc=$?
  expect_code 1 "$rc" "a PR body with no no-mistakes signature must be refused"
  assert_contains "$out" "This PR was not raised through no-mistakes." \
    "refusal did not name the missing signature"
  assert_contains "$out" "$MARKER" "refusal did not show the required marker"
  pass "a PR body without the no-mistakes signature is refused"
}

test_signature_without_attestation_passes() {
  # The regression: no-mistakes 1.45.x signs the body but emits no attestation
  # comment. That body must satisfy the required check.
  local out rc=0
  out=$(run_check "$(signature_body)") || rc=$?
  expect_code 0 "$rc" \
    "a signature-only body from a pre-1.46.0 pipeline must satisfy the check"
  assert_contains "$out" "Accepting signature-only compliance" \
    "the pass did not explain why signature-only compliance was accepted"
  pass "a signed body with no attestation comment passes the required check"
}

test_attested_completed_steps_pass() {
  local out rc=0
  out=$(run_check "$(attested_body '{"head_sha":"sample-sha","steps":[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]}')") || rc=$?
  expect_code 0 "$rc" "an attestation with all required steps completed must pass"
  assert_contains "$out" "Pipeline step attestation is valid" \
    "a valid attestation was not reported as verified"
  pass "an attestation with review, test, and document completed passes"
}

test_attested_stale_head_is_refused() {
  local out rc=0
  out=$(run_check "$(attested_body '{"head_sha":"old-sha","steps":[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]}')" current-sha) || rc=$?
  expect_code 1 "$rc" "an attestation from an older PR head must be refused"
  assert_contains "$out" "old-sha" "refusal did not name the attested head"
  assert_contains "$out" "current-sha" "refusal did not name the current PR head"
  pass "an attestation from an older PR head is refused"
}

test_attested_missing_head_is_refused() {
  local out rc=0
  out=$(run_check "$(attested_body '{"steps":[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]}')") || rc=$?
  expect_code 1 "$rc" "an attestation without head_sha must be refused"
  assert_contains "$out" "Attested head: <missing>" \
    "refusal did not identify the missing attested head"
  pass "an attestation without head_sha is refused"
}

test_attested_skip_is_refused() {
  # Upstream's substantive control has to survive the relaxation above: when a
  # pipeline does attest, a skipped required step still fails the check.
  local out rc=0
  out=$(run_check "$(attested_body '{"head_sha":"sample-sha","steps":[{"step":"review","status":"skipped"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]}')") || rc=$?
  expect_code 1 "$rc" "an attested but skipped required step must be refused"
  assert_contains "$out" "review=skipped" "refusal did not name the skipped step"
  pass "an attested quota or agent skip is still refused"
}

test_attested_later_duplicate_skip_is_refused() {
  local out rc=0
  out=$(run_check "$(attested_body '{"head_sha":"sample-sha","steps":[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"},{"step":"review","status":"skipped"}]}')") || rc=$?
  expect_code 1 "$rc" "a later duplicate skipped status must override completed"
  assert_contains "$out" "review=skipped" \
    "refusal did not use the later duplicate review status"
  pass "the last duplicate status controls attestation compliance"
}

test_attested_malformed_extra_step_is_refused() {
  local out rc=0
  out=$(run_check "$(attested_body '{"head_sha":"sample-sha","steps":[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"},{}]}')") || rc=$?
  expect_code 1 "$rc" "a malformed extra step record must invalidate the attestation"
  assert_contains "$out" "malformed step records" \
    "refusal did not identify the malformed extra step record"
  pass "a malformed unrelated step invalidates the attestation"
}

test_attested_missing_step_is_refused() {
  local out rc=0
  out=$(run_check "$(attested_body '{"head_sha":"sample-sha","steps":[{"step":"review","status":"completed"}]}')") || rc=$?
  expect_code 1 "$rc" "an attestation omitting required steps must be refused"
  assert_contains "$out" "test=missing" "refusal did not name the absent test step"
  assert_contains "$out" "document=missing" \
    "refusal did not name the absent document step"
  pass "an attestation that omits a required step is refused"
}

test_unparseable_attestation_is_refused() {
  # A present-but-broken attestation must never fall through to the relaxed
  # signature-only path, or hand-editing the comment would weaken the gate.
  local out rc=0
  out=$(run_check "$(attested_body '{"head_sha":"sample-sha","steps":[')") || rc=$?
  expect_code 1 "$rc" "a malformed attestation payload must be refused"
  assert_contains "$out" "present but unparseable" \
    "refusal did not identify the attestation as unparseable"
  pass "a present but malformed attestation is refused rather than ignored"
}

test_body_without_signature_is_refused
test_signature_without_attestation_passes
test_attested_completed_steps_pass
test_attested_stale_head_is_refused
test_attested_missing_head_is_refused
test_attested_skip_is_refused
test_attested_later_duplicate_skip_is_refused
test_attested_malformed_extra_step_is_refused
test_attested_missing_step_is_refused
test_unparseable_attestation_is_refused
