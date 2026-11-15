#!/usr/bin/env bash
# A Claude-authored no-mistakes run pins its reviewer with per-run flags.
# The pin command must not rewrite the shared no-mistakes config, and a
# generated no-mistakes brief must tell the worker the same rule.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-nm-reviewer-pin)
PIN="$ROOT/bin/fm-nm-reviewer-pin.sh"
EXPECTED='--reviewer codex --reviewer-model gpt-5.6-sol --reviewer-effort medium'

install_fake_nm() {  # <help-body>
  local fake help_file
  fake=$(fm_fakebin "$TMP_ROOT/fake-$$")
  help_file="$TMP_ROOT/help-$$.txt"
  printf '%s\n' "$1" >"$help_file"
  cat >"$fake/no-mistakes" <<SH
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = axi ] && [ "\${2:-}" = run ] && [ "\${3:-}" = --help ]; then
  cat "$help_file"
  exit 0
fi
printf 'unexpected no-mistakes args: %s\\n' "\$*" >&2
exit 2
SH
  chmod +x "$fake/no-mistakes"
  printf '%s\n' "$fake"
}

empty_home() {  # <name>
  local dir="$TMP_ROOT/$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

assert_untouched() {  # <dir> <label>
  local found
  found=$(find "$1" -mindepth 1 -print)
  [ -z "$found" ] || fail "$2 wrote under the no-mistakes home: $found"
}

test_claude_writer_prints_reviewer_flags_without_touching_config() {
  local fake home out rc
  fake=$(install_fake_nm "$(printf '%s\n' \
    'Usage: no-mistakes axi run' \
    '      --intent string' \
    '      --reviewer string' \
    '      --reviewer-model string' \
    '      --reviewer-effort string')")
  home=$(empty_home success-home)
  out=$(PATH="$fake:$PATH" HOME="$home" NM_HOME="$home" "$PIN" --writer claude)
  rc=$?
  expect_code 0 "$rc" "claude writer with --reviewer advertised"
  [ "$out" = "$EXPECTED" ] || fail "claude writer printed '$out', want '$EXPECTED'"
  assert_untouched "$home" "a successful pin"
  pass "claude writer prints the Codex reviewer flags and writes no config"
}

test_reviewer_model_alone_is_not_a_reviewer_flag() {
  local fake home out err rc
  fake=$(install_fake_nm "$(printf '%s\n' \
    '      --model string' \
    '      --reviewer-model string' \
    '      --reviewer-effort string')")
  home=$(empty_home refuse-home)
  err="$TMP_ROOT/refuse.err"
  out=$(PATH="$fake:$PATH" HOME="$home" NM_HOME="$home" "$PIN" --writer claude 2>"$err")
  rc=$?
  expect_code 1 "$rc" "claude writer without a --reviewer flag"
  [ -z "$out" ] || fail "a refusal printed a pin on stdout: $out"
  assert_grep '--reviewer' "$err" "a refusal did not name the missing --reviewer flag"
  assert_grep 'refusing to pin by editing the shared' "$err" "a refusal did not say it will not edit the shared config"
  assert_no_grep 'agent:' "$err" "a refusal told the caller to set agent:"
  assert_no_grep 'agent_args_override' "$err" "a refusal told the caller to set agent_args_override"
  assert_no_grep 'config.yaml' "$err" "a refusal named a config file to edit"
  assert_untouched "$home" "a refusal"
  pass "without --reviewer the claude writer is refused and no config recipe is printed"
}

test_other_writers_print_nothing() {
  local fake writer out rc
  fake=$(install_fake_nm '      --model string')
  for writer in codex grok '' 'Claude'; do
    out=$(PATH="$fake:$PATH" "$PIN" --writer "$writer")
    rc=$?
    expect_code 0 "$rc" "writer '$writer'"
    [ -z "$out" ] || fail "writer '$writer' printed '$out'"
  done
  pass "a non-claude writer prints nothing even when --reviewer is absent"
}

test_missing_no_mistakes_refuses_claude_writer() {
  local home out err rc path
  path=$(fm_test_base_path_sans "${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" no-mistakes)
  home=$(empty_home missing-home)
  err="$TMP_ROOT/missing.err"
  out=$(PATH="$path" HOME="$home" NM_HOME="$home" "$PIN" --writer claude 2>"$err")
  rc=$?
  expect_code 1 "$rc" "claude writer with no no-mistakes on PATH"
  [ -z "$out" ] || fail "a missing binary still printed '$out'"
  assert_grep '--reviewer' "$err" "a missing binary did not name --reviewer"
  assert_grep 'refusing to pin by editing the shared' "$err" "a missing binary offered another pin path"
  assert_untouched "$home" "a missing binary"
  pass "a missing no-mistakes binary refuses the claude writer"
}

test_usage_rejects_extra_arguments() {
  local out rc
  out=$("$PIN" --help)
  rc=$?
  expect_code 0 "$rc" "--help"
  assert_contains "$out" '--writer' "--help did not document --writer"
  assert_contains "$out" 'refusing to pin by editing the shared' "--help did not state the refusal"
  out=$("$PIN" --writer claude extra 2>"$TMP_ROOT/usage.err")
  rc=$?
  expect_code 2 "$rc" "extra arguments"
  out=$("$PIN" 2>"$TMP_ROOT/usage-none.err")
  rc=$?
  expect_code 2 "$rc" "no arguments"
  pass "usage accepts --help and rejects a bad argument list"
}

test_no_mistakes_brief_forbids_shared_config_rewrite() {
  local home brief
  home="$TMP_ROOT/brief-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" pin-ship some-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "fm-brief.sh ship scaffold exited non-zero"
  brief="$home/data/pin-ship/brief.md"
  assert_grep 'Never rewrite the shared no-mistakes config' "$brief" \
    "the brief did not forbid rewriting the shared no-mistakes config"
  assert_grep 'omit those flags when reattaching' "$brief" \
    "the brief did not say to omit reviewer flags when reattaching"
  assert_grep 'background the drive call' "$brief" \
    "the brief dropped the backgrounded drive call"
  mkdir -p "$home/config"
  : >"$home/config/wait-no-turns"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" pin-wait some-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "fm-brief.sh foreground scaffold exited non-zero"
  brief="$home/data/pin-wait/brief.md"
  assert_grep 'Never rewrite the shared no-mistakes config' "$brief" \
    "the foreground brief did not forbid rewriting the shared no-mistakes config"
  assert_grep 'issue the same foreground call again' "$brief" \
    "the foreground brief dropped its reattach wording"
  assert_no_grep 'background the drive call' "$brief" \
    "the foreground brief still backgrounds the drive call"
  pass "a no-mistakes brief forbids a shared-config reviewer pin in both drive shapes"
}

test_claude_writer_prints_reviewer_flags_without_touching_config
test_reviewer_model_alone_is_not_a_reviewer_flag
test_other_writers_print_nothing
test_missing_no_mistakes_refuses_claude_writer
test_usage_rejects_extra_arguments
test_no_mistakes_brief_forbids_shared_config_rewrite

echo "all fm-nm-reviewer-pin tests passed"
