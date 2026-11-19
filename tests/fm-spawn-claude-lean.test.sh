#!/usr/bin/env bash
# tests/fm-spawn-claude-lean.test.sh - Claude lean and Code Mode launch behavior.
#
# Assertions drive the real spawn against a fake pane, then execute the launch
# the pane received with the claude binary replaced by a probe. They never read
# bin/fm-spawn.sh's source. Without either opt-in, launches stay free of both
# postures' environment and task metadata.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-claude-lean)

# Contrary pane values. A lean launch has to override these rather than inherit
# them; an ordinary launch has to leave them alone.
CONTRARY_FORCE=0
CONTRARY_AUTO=0
CONTRARY_COMPACT=0

# make_case <name> <harness> <id>...
# Echoes "<case-dir>|<home>|<project>|<worktree>|<fakebin>|<launch-log>|<pane-log>".
make_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog panelog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  panelog="$case_dir/pane.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$panelog"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG <<EOF
$1
EOF
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# The probe is the claude process the launch starts. It reports the environment
# that process received and every argument, which is what a real claude would
# have seen.
install_claude_probe() { # <fakebin>
  cat > "$1/claude" <<'SH'
#!/bin/sh
printf 'FORCE=%s\n' "${FORCE_PROMPT_CACHING_5M-unset}"
printf 'AUTO=%s\n' "${CLAUDE_CODE_DISABLE_AUTO_MEMORY-unset}"
printf 'COMPACT=%s\n' "${COMPACT_ADVISER_DISABLE-unset}"
printf 'CODE_MODE=%s\n' "${CLAUDE_CODE_EXPERIMENTAL_CODE_MODE-unset}"
printf 'ARGS'
for arg in "$@"; do
  printf ' %s' "$arg"
done
printf '\n'
previous=
for arg in "$@"; do
  if [ "$previous" = --settings ]; then
    printf '%s\n' "$arg" | jq -r '"EMPTY_MCP_ALLOWLIST=\(has("allowedMcpServers") and .allowedMcpServers == [])"'
  fi
  previous=$arg
done
SH
  chmod +x "$1/claude"
}

# Replay the pane exports, then the launch, under a pane that already holds the
# contrary values. <with-preamble> is 1 to include the pane exports.
run_emitted_launch() { # <fakebin> <launch-log> <pane-log> <with-preamble>
  local fakebin=$1 launchlog=$2 panelog=$3 with_preamble=$4 launch preamble
  launch=$(cat "$launchlog")
  preamble=
  if [ "$with_preamble" = 1 ]; then
    preamble=$(grep '^export ' "$panelog" || true)
  fi
  env -i HOME="$TMP_ROOT/pane-home" PATH="$fakebin:$PATH" TERM=xterm \
    TMUX=synthetic-pane \
    FORCE_PROMPT_CACHING_5M="$CONTRARY_FORCE" \
    CLAUDE_CODE_DISABLE_AUTO_MEMORY="$CONTRARY_AUTO" \
    COMPACT_ADVISER_DISABLE="$CONTRARY_COMPACT" \
    CLAUDE_CODE_EXPERIMENTAL_CODE_MODE=0 \
    /bin/sh -c "$preamble
$launch"
}

field_of() { # <output> <name>
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1
}

export_count() { # <file> <line>
  grep -c -x -F -- "$2" "$1" || true
}

meta_lean_count() { # <meta>
  if [ ! -f "$1" ]; then
    printf '0\n'
    return 0
  fi
  grep -c -x 'claude_lean=1' "$1" || true
}

assert_hooks_installed() { # <file> <label>
  [ -f "$1" ] || fail "$2: busy hooks file was not written at $1"
  assert_grep 'UserPromptSubmit' "$1" "$2: the busy hooks must still include UserPromptSubmit"
}

assert_lean_probe() { # <seen> <label>
  local seen=$1 label=$2
  assert_equals 1 "$(field_of "$seen" FORCE)" \
    "$label: the claude process must see FORCE_PROMPT_CACHING_5M=1"
  assert_equals 1 "$(field_of "$seen" AUTO)" \
    "$label: the claude process must see CLAUDE_CODE_DISABLE_AUTO_MEMORY=1"
  assert_equals 1 "$(field_of "$seen" COMPACT)" \
    "$label: the compact-adviser floor must stay on under a lean launch"
  assert_contains "$seen" ' --strict-mcp-config' \
    "$label: claude must be started with --strict-mcp-config"
  assert_contains "$seen" ' --disallowedTools mcp__*' \
    "$label: plugin-registered MCP tools must also be denied"
  assert_equals true "$(field_of "$seen" EMPTY_MCP_ALLOWLIST)" \
    "$label: session settings must exclude plugin MCP servers"
  assert_not_contains "$seen" ' --bare' \
    "$label: a lean launch must not pass --bare"
  assert_not_contains "$seen" ' --mcp-config' \
    "$label: a lean launch must not pass an MCP config"
  assert_contains "$seen" ' --settings ' \
    "$label: session settings must still be passed"
  assert_contains "$seen" ' --dangerously-skip-permissions' \
    "$label: the permission flag must stay"
  assert_contains "$seen" ' --append-system-prompt ' \
    "$label: the task-channel statement must stay"
}

assert_plain_probe() { # <seen> <label>
  local seen=$1 label=$2 force auto
  force=$(field_of "$seen" FORCE)
  auto=$(field_of "$seen" AUTO)
  [ "$force" != 1 ] \
    || fail "$label: an ordinary launch set FORCE_PROMPT_CACHING_5M (saw $force)"
  [ "$auto" != 1 ] \
    || fail "$label: an ordinary launch set CLAUDE_CODE_DISABLE_AUTO_MEMORY (saw $auto)"
  assert_equals 1 "$(field_of "$seen" COMPACT)" \
    "$label: the compact-adviser floor must stay on"
  assert_not_contains "$seen" '--strict-mcp-config' \
    "$label: an ordinary launch must not pass --strict-mcp-config"
  assert_not_contains "$seen" '--disallowedTools' \
    "$label: an ordinary launch must not deny MCP tools"
  assert_equals false "$(field_of "$seen" EMPTY_MCP_ALLOWLIST)" \
    "$label: an ordinary launch must not restrict MCP servers"
  assert_not_contains "$seen" ' --bare' \
    "$label: an ordinary launch must not pass --bare"
  assert_contains "$seen" ' --settings ' \
    "$label: session settings must still be passed"
}

assert_no_lean_pane_export() { # <pane-log> <label>
  [ "$(export_count "$1" 'export FORCE_PROMPT_CACHING_5M=1')" = 0 ] \
    || fail "$2: an ordinary launch exported FORCE_PROMPT_CACHING_5M into the pane"
  [ "$(export_count "$1" 'export COMPACT_ADVISER_DISABLE=1')" = 1 ] \
    || fail "$2: the compact-adviser pane export must stay on an ordinary launch"
}

# --- fresh launches ----------------------------------------------------------

test_lean_ship_and_scout() {
  local kind setting id rec out status seen hooks
  for kind in ship scout; do
    for setting in absent enabled; do
      id="lean-$kind-$setting-a1"
      rec=$(make_case "lean-$kind-$setting" claude "$id")
      read_case "$rec"
      [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
      if [ "$kind" = scout ]; then
        out=$(run_case_spawn "$id" "$PROJ_DIR" --scout --claude-lean)
      else
        out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --claude-lean)
      fi
      status=$?
      expect_code 0 "$status" "$kind allowlist=$setting lean spawn should succeed: $out"
      assert_no_lean_pane_export "$PANE_LOG" "$kind allowlist=$setting"
      if [ "$setting" = enabled ]; then
        assert_grep '/usr/bin/env -i' "$LAUNCH_LOG" \
          "$kind: an enabled allowlist should still launch under a cleared environment"
        assert_grep 'FORCE_PROMPT_CACHING_5M=1' "$LAUNCH_LOG" \
          "$kind: the allowlist pin must include the five-minute cache"
        assert_grep 'COMPACT_ADVISER_DISABLE=1' "$LAUNCH_LOG" \
          "$kind: the allowlist floor pin must stay"
      fi
      hooks="$WT_DIR/.claude/settings.local.json"
      assert_hooks_installed "$hooks" "$kind allowlist=$setting"
      assert_equals 0 "$(meta_lean_count "$HOME_DIR/state/$id.meta")" \
        "$kind allowlist=$setting: the task record must not persist the lean choice"
      install_claude_probe "$FAKEBIN_DIR"
      seen=$(run_emitted_launch "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" 1) \
        || fail "$kind allowlist=$setting: the emitted launch failed to run"
      assert_lean_probe "$seen" "$kind allowlist=$setting"
      seen=$(run_emitted_launch "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" 0) \
        || fail "$kind allowlist=$setting: the launch command alone failed to run"
      assert_lean_probe "$seen" "$kind allowlist=$setting, launch command alone"
    done
  done
  pass "a lean ship or scout launch sets the five-minute cache and the smaller start, and keeps hooks, settings, and the task-channel statement"
}

test_secondmate_refuses() {
  local rec id sm out status flag
  id="lean-sm-a1"
  rec=$(make_case secondmate-on claude "$id")
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$sm/.gitignore"
  git -C "$sm" init -q -b main
  for flag in --claude-lean --claude-code-mode; do
    out=$(run_case_spawn "$id" "$sm" --secondmate "$flag")
    status=$?
    expect_code 1 "$status" "secondmate $flag spawn must refuse: $out"
    assert_contains "$out" 'does not apply to secondmate' "the refusal must name supervision"
    assert_absent "$HOME_DIR/state/$id.meta" "a refused secondmate must not write a task record"
    [ ! -s "$LAUNCH_LOG" ] || fail "a refused secondmate must not launch an agent"
  done
  pass "secondmate supervision refuses lean and Code Mode launches"
}

test_ordinary_launch_is_unchanged() {
  local setting id rec out status seen
  for setting in absent enabled; do
    id="plain-$setting-a1"
    rec=$(make_case "plain-$setting" claude "$id")
    read_case "$rec"
    [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
    out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
    status=$?
    expect_code 0 "$status" "ordinary allowlist=$setting spawn should succeed: $out"
    assert_no_lean_pane_export "$PANE_LOG" "ordinary allowlist=$setting"
    assert_no_grep 'FORCE_PROMPT_CACHING_5M' "$LAUNCH_LOG" \
      "ordinary allowlist=$setting: the launch command must not mention the five-minute cache"
    assert_no_grep 'CLAUDE_CODE_DISABLE_AUTO_MEMORY' "$LAUNCH_LOG" \
      "ordinary allowlist=$setting: the launch command must not disable auto memory"
    assert_no_grep 'CLAUDE_CODE_EXPERIMENTAL_CODE_MODE' "$LAUNCH_LOG" \
      "ordinary allowlist=$setting: the launch must not enable Code Mode"
    assert_no_grep 'claude_code_mode=' "$HOME_DIR/state/$id.meta" \
      "ordinary allowlist=$setting: the task record must not gain a Code Mode choice"
    assert_no_grep '--strict-mcp-config' "$LAUNCH_LOG" \
      "ordinary allowlist=$setting: the launch command must not pass --strict-mcp-config"
    assert_no_grep '--bare' "$LAUNCH_LOG" \
      "ordinary allowlist=$setting: the launch command must not pass --bare"
    assert_grep 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude ' "$LAUNCH_LOG" \
      "ordinary allowlist=$setting: the claude command prefix must stay the pre-lean text"
    assert_hooks_installed "$WT_DIR/.claude/settings.local.json" "ordinary allowlist=$setting"
    assert_equals 0 "$(meta_lean_count "$HOME_DIR/state/$id.meta")" \
      "ordinary allowlist=$setting: the task record must not gain a claude_lean line"
    install_claude_probe "$FAKEBIN_DIR"
    seen=$(run_emitted_launch "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" 1) \
      || fail "ordinary allowlist=$setting: the emitted launch failed to run"
    assert_plain_probe "$seen" "ordinary allowlist=$setting"
    seen=$(run_emitted_launch "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" 0) \
      || fail "ordinary allowlist=$setting: the launch command alone failed to run"
    assert_plain_probe "$seen" "ordinary allowlist=$setting, launch command alone"
  done
  pass "without --claude-lean the launch, the pane exports, and the task record stay free of the lean posture"
}

# --- refusals ---------------------------------------------------------------

test_non_claude_refuses() {
  local rec id out status
  id="lean-codex-a1"
  rec=$(make_case lean-codex codex "$id")
  read_case "$rec"
  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --harness codex --claude-lean)
  status=$?
  expect_code 1 "$status" "a codex launch with --claude-lean must refuse: $out"
  assert_contains "$out" 'applies only to the claude harness' \
    "the refusal should name the claude-only scope"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "a refused non-claude launch must not write a task record"
  pass "--claude-lean on a non-claude harness refuses before a task record exists"
}

test_raw_command_refuses() {
  local rec id out status
  id="lean-raw-a1"
  rec=$(make_case lean-raw claude "$id")
  read_case "$rec"
  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --claude-lean "echo lean-raw")
  status=$?
  expect_code 1 "$status" "a raw launch command with --claude-lean must refuse: $out"
  assert_contains "$out" 'not a raw launch command' \
    "the refusal should name the raw-command limit"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "a refused raw launch must not write a task record"
  pass "--claude-lean on a raw launch command refuses before a task record exists"
}

test_t3code_refuses_before_runtime_check() {
  local rec id out status
  id="lean-t3-a1"
  rec=$(make_case lean-t3 claude "$id")
  read_case "$rec"
  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --backend t3code --claude-lean)
  status=$?
  expect_code 1 "$status" "backend=t3code with --claude-lean must refuse: $out"
  assert_contains "$out" 'cannot run on backend=t3code' \
    "the refusal should name the t3code backend"
  assert_contains "$out" '--strict-mcp-config' \
    "the refusal should say why T3 cannot carry the lean start"
  assert_not_contains "$out" 'token' \
    "the refusal must happen before the T3 runtime check asks for a token"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "a refused t3code launch must not write a task record"
  pass "--claude-lean on backend=t3code refuses before the T3 runtime check"
}

test_code_mode_ship_and_scout() {
  local kind setting id rec out status seen
  local -a args
  for kind in ship scout; do
    for setting in absent enabled; do
      id="code-$kind-$setting-a1"
      rec=$(make_case "code-$kind-$setting" claude "$id")
      read_case "$rec"
      args=(--claude-code-mode)
      if [ "$kind" = scout ]; then
        args+=(--scout)
      else
        args+=(--mode no-mistakes --yolo off)
      fi
      if [ "$setting" = enabled ]; then
        : > "$HOME_DIR/config/launch-env-allowlist"
        args+=(--claude-lean)
      fi
      out=$(run_case_spawn "$id" "$PROJ_DIR" "${args[@]}")
      status=$?
      expect_code 0 "$status" "Code Mode $kind allowlist=$setting spawn failed: $out"
      assert_equals 1 "$(export_count "$HOME_DIR/state/$id.meta" 'claude_code_mode=1')" \
        "Code Mode choice must be recorded exactly once"
      assert_no_grep 'CLAUDE_CODE_EXPERIMENTAL_CODE_MODE' "$PANE_LOG" \
        "Code Mode must stay in this worker's launch, outside pane exports"
      assert_hooks_installed "$WT_DIR/.claude/settings.local.json" 'Code Mode'
      install_claude_probe "$FAKEBIN_DIR"
      seen=$(run_emitted_launch "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" 0) \
        || fail "Code Mode launch failed to run"
      assert_equals 1 "$(field_of "$seen" CODE_MODE)" \
        "Code Mode must override the inherited value with allowlist=$setting"
      if [ "$setting" = enabled ]; then
        assert_lean_probe "$seen" 'Code Mode with lean'
      else
        assert_plain_probe "$seen" 'Code Mode without lean'
      fi
    done
  done
  pass "Code Mode reaches only the opted-in worker, including with lean and an environment allowlist"
}

test_code_mode_refusals() {
  local rec id out status scenario expected
  local -a args
  for scenario in codex raw t3code value; do
    id="code-refuse-$scenario-a1"
    rec=$(make_case "code-refuse-$scenario" claude "$id")
    read_case "$rec"
    args=(--claude-code-mode)
    case "$scenario" in
      codex) args+=(--harness codex); expected='applies only to the claude harness' ;;
      raw) args+=('echo raw'); expected='not a raw launch command' ;;
      t3code) args+=(--backend t3code); expected='cannot run on backend=t3code' ;;
      value) args=(--claude-code-mode=1); expected='takes no value' ;;
    esac
    out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off "${args[@]}")
    status=$?
    expect_code 1 "$status" "Code Mode $scenario must refuse: $out"
    assert_contains "$out" "$expected" "Code Mode $scenario should name the refusal"
    assert_absent "$HOME_DIR/state/$id.meta" "refused Code Mode launch must not write a task record"
    [ ! -s "$LAUNCH_LOG" ] || fail "refused Code Mode launch must not launch an agent"
  done
  pass "Code Mode refuses non-Claude harnesses, raw commands, T3, and values"
}

test_code_mode_relaunch() {
  local setting id rec out status seen round target
  local -a args
  for setting in plain code; do
    id="code-relaunch-$setting-a1"
    rec=$(make_case "code-relaunch-$setting" claude "$id")
    read_case "$rec"
    args=(--mode no-mistakes --yolo off)
    [ "$setting" = plain ] || args+=(--claude-code-mode)
    out=$(run_case_spawn "$id" "$PROJ_DIR" "${args[@]}")
    expect_code 0 "$?" "initial relaunch fixture failed: $out"
    mv "$FAKEBIN_DIR/tmux" "$FAKEBIN_DIR/tmux-original"
    cat > "$FAKEBIN_DIR/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'#{pane_current_command}'*) printf 'bash\n'; exit 0 ;;
esac
exec "$(dirname "$0")/tmux-original" "$@"
SH
    chmod +x "$FAKEBIN_DIR/tmux"
    for round in 1 2; do
      out=$(run_case_spawn "$id" --relaunch)
      status=$?
      expect_code 0 "$status" "Code Mode $setting relaunch $round failed: $out"
      install_claude_probe "$FAKEBIN_DIR"
      seen=$(run_emitted_launch "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" 0) \
        || fail "relaunched Code Mode command failed to run"
      if [ "$setting" = code ]; then
        assert_equals 1 "$(field_of "$seen" CODE_MODE)" "relaunch must restore Code Mode"
        assert_equals 1 "$(export_count "$HOME_DIR/state/$id.meta" 'claude_code_mode=1')" \
          "relaunch must persist Code Mode exactly once"
      else
        assert_equals 0 "$(field_of "$seen" CODE_MODE)" "ordinary relaunch must leave Code Mode off"
        assert_no_grep 'claude_code_mode=' "$HOME_DIR/state/$id.meta" \
          "ordinary relaunch must not record Code Mode"
      fi
    done
    [ "$setting" = code ] || continue
    for target in codex 'claude --raw-probe'; do
      out=$(run_case_spawn "$id" --relaunch --harness "$target")
      expect_code 0 "$?" "Code Mode harness switch to $target failed: $out"
      assert_no_grep 'claude_code_mode=' "$HOME_DIR/state/$id.meta" \
        "switching away from a built Claude launch must clear the recorded choice"
      assert_no_grep 'CLAUDE_CODE_EXPERIMENTAL_CODE_MODE' "$LAUNCH_LOG" \
        "switching harness must not inject Code Mode into the emitted launch"
      out=$(run_case_spawn "$id" --relaunch --harness claude)
      expect_code 0 "$?" "return to Claude failed: $out"
      seen=$(run_emitted_launch "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" 0) \
        || fail "returned Claude launch failed to run"
      assert_equals 0 "$(field_of "$seen" CODE_MODE)" \
        "returning to Claude must not resurrect the discarded choice"
      out=$(run_case_spawn "$id" --relaunch --claude-code-mode)
      expect_code 0 "$?" "explicit Code Mode re-enable failed: $out"
    done
  done
  pass "relaunch restores the Code Mode opt-in and keeps legacy tasks unchanged"
}

test_lean_ship_and_scout
test_secondmate_refuses
test_ordinary_launch_is_unchanged
test_non_claude_refuses
test_raw_command_refuses
test_t3code_refuses_before_runtime_check
test_code_mode_ship_and_scout
test_code_mode_refusals
test_code_mode_relaunch

# This credentialed guard consumes emitted launches with the installed Claude,
# including a mod that registers tools without an MCP configuration file.
# It stays opt-in because it submits short model turns.
fm_live_gate opt-in FM_CLAUDE_LEAN_LIVE claude python3
REAL_CLAUDE=$(command -v claude)
CLAUDE_VERSION=$(claude --version)

test_plugin_mcp_live() {
  local mode rec id out
  for mode in plain lean lean-allowlisted; do
    id="plugin-$mode-a1"
    rec=$(make_case "plugin-$mode" claude "$id")
    read_case "$rec"
    if [ "$mode" = plain ]; then
      out=$(run_case_spawn "$id" "$PROJ_DIR" --scout)
    else
      out=$(run_case_spawn "$id" "$PROJ_DIR" --scout --claude-lean)
    fi
    expect_code 0 "$?" "live fixture spawn failed: $out"
    python3 - "$CASE_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$REAL_CLAUDE" "$mode" <<'PY' \
      || fail "Claude Code $CLAUDE_VERSION: plugin MCP exclusion failed ($mode)"
import json
import os
from pathlib import Path
import subprocess
import sys

case, worktree, fakebin, launchlog, claude, mode = sys.argv[1:]
case, worktree = Path(case), Path(worktree)
plugin = case / 'plugin'
(plugin / '.claude-plugin').mkdir(parents=True)
(plugin / '.claude-plugin/plugin.json').write_text(json.dumps({'name': 'lean-probe', 'version': '1.0.0'}))
(plugin / 'hooks').mkdir()
# Both startup and mid-turn registrations must be excluded. Mark the attempts
# independently, so disabling the plugin cannot make this test pass vacuously.
(plugin / 'hooks/hooks.json').write_text(json.dumps({'modules': ['./register.js']}))
(plugin / 'hooks/register.js').write_text('''
export function register(on) {
  on('session.start', async ($, e, next) => {
    await $.tool.register({name: 'early', description: 'Startup probe', inputSchema: {type: 'object', properties: {}}});
    await $.fs.write('registered-early', 'attempted');
    return next(e);
  });
  on('tool.call', {tool: 'Bash'}, async ($, e, next) => {
    await $.tool.register({name: 'late', description: 'Mid-turn probe', inputSchema: {type: 'object', properties: {}}});
    await $.fs.write('registered-late', 'attempted');
    return next(e);
  });
}
''')
(plugin / 'skills/probe').mkdir(parents=True)
(plugin / 'skills/probe/SKILL.md').write_text('---\nname: probe\ndescription: Local regression skill.\n---\nReply concisely.\n')
(worktree / 'CLAUDE.md').write_text('Local read-only regression project.\n')
config = case / 'claude-config'
config.mkdir()
root = Path.cwd()
settings = {'claudeMdExcludes': [str(root / 'CLAUDE.md'), str(root / 'AGENTS.md'), str(Path.home() / '.claude/CLAUDE.md')]}
if mode == 'lean-allowlisted':
    # Claude merges server allowlists across settings sources. This must not
    # re-enable tools even when the plugin's synthetic server is allowlisted.
    settings['allowedMcpServers'] = [{'serverName': 'lean-probe'}]
(config / 'settings.json').write_text(json.dumps(settings))
env = os.environ.copy()
normal = Path(env.get('CLAUDE_CONFIG_DIR') or Path.home() / '.claude')
if not env.get('CLAUDE_CODE_OAUTH_TOKEN') and (normal / '.credentials.json').is_file():
    env['CLAUDE_CODE_OAUTH_TOKEN'] = json.loads((normal / '.credentials.json').read_text())['claudeAiOauth']['accessToken']
env.update(CLAUDE_CONFIG_DIR=str(config), DISABLE_AUTOUPDATER='1', CLAUDE_CODE_ENABLE_FUNCTION_HOOKS='1',
           PATH=f'{fakebin}:' + env['PATH'])
env.pop('CLAUDECODE', None)
# The wrapper preserves every emitted launch option and replaces only the
# task doorbell with a bounded fixture prompt, adding print-mode transport.
wrapper = Path(fakebin) / 'claude'
prompt = 'Use Bash exactly once to run true. Then reply OK. Do not read or change files, call other tools, delegate, or run any pipeline.'
wrapper.write_text('#!/usr/bin/env python3\nimport os, sys\nos.execv(' + repr(claude) + ', [' + repr(claude) +
                  ', "--plugin-dir", ' + repr(str(plugin)) + ', "--print", "--verbose", "--output-format", "stream-json", *sys.argv[1:-1], "--", ' + repr(prompt) + '])\n')
wrapper.chmod(0o755)
p = subprocess.run(['/bin/sh', '-c', Path(launchlog).read_text()], cwd=worktree, env=env,
                   text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
(case / 'stream.jsonl').write_text(p.stdout)
assert p.returncode == 0, p.stdout[-2000:]
stream = [json.loads(line) for line in p.stdout.splitlines() if line.startswith('{')]
init = next(row for row in stream if row.get('subtype') == 'init')
result = next(row for row in stream if row.get('type') == 'result')
assert not result.get('is_error'), result
assert 'lean-probe:probe' in init['skills'], 'plugin skill disappeared'
assert (worktree / 'registered-early').is_file(), 'startup plugin hook did not run'
assert (worktree / 'registered-late').is_file(), 'mid-turn plugin hook did not run'
assert list((case / 'home/state').glob('*.turn-ended')), 'Firstmate Stop hook did not run'
# The init event alone misses tools registered after the first call. Inspect
# Claude's persisted runtime attachment protocol across the whole session too.
transcripts = list(config.glob('projects/*/*.jsonl'))
assert transcripts, 'Claude did not persist a runtime transcript'
names = set(init['tools'])
instructions = set()
for transcript in transcripts:
    for line in transcript.read_text().splitlines():
        row = json.loads(line)
        attachment = row.get('attachment', {})
        if attachment.get('type') == 'deferred_tools_delta':
            names.update(attachment.get('addedNames', []))
        elif attachment.get('type') == 'mcp_instructions_delta':
            instructions.update(attachment.get('addedNames', []))
mcp = sorted(name for name in names if name.startswith('mcp__'))
if mode == 'plain':
    assert 'mcp__lean-probe__early' in mcp and 'mcp__lean-probe__late' in mcp, mcp
else:
    assert not mcp, f'MCP tools leaked: {mcp}'
    if mode == 'lean':
        assert 'lean-probe' not in instructions, 'plugin MCP instructions leaked'
print(f'{mode}: MCP exclusion and retained hooks/skills verified')
PY
  done
  pass "Claude Code $CLAUDE_VERSION excludes startup and mid-turn plugin MCP tools only on lean launches, keeping hooks and skills"
}

test_plugin_mcp_live
