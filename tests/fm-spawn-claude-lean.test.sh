#!/usr/bin/env bash
# tests/fm-spawn-claude-lean.test.sh - opt-in --claude-lean on a Claude launch.
#
# Assertions drive the real spawn against a fake pane, then execute the launch
# the pane received with the claude binary replaced by a probe. They never read
# bin/fm-spawn.sh's source. Absent the flag, the launch must not grow the lean
# environment, the lean flag, or a claude_lean= record line.
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
  local rec id sm out status
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
  out=$(run_case_spawn "$id" "$sm" --secondmate --claude-lean)
  status=$?
  expect_code 1 "$status" "secondmate lean spawn must refuse: $out"
  assert_contains "$out" 'does not apply to secondmate' "the refusal must name supervision"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused secondmate must not write a task record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused secondmate must not launch an agent"
  pass "secondmate supervision refuses lean launches"
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

test_lean_ship_and_scout
test_secondmate_refuses
test_ordinary_launch_is_unchanged
test_non_claude_refuses
test_raw_command_refuses
test_t3code_refuses_before_runtime_check

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
