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

CONTROL="$ROOT/bin/fm-control.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
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

assert_lean_probe() { # <seen> <label> <expect-append>
  local seen=$1 label=$2 expect_append=$3
  assert_equals 1 "$(field_of "$seen" FORCE)" \
    "$label: the claude process must see FORCE_PROMPT_CACHING_5M=1"
  assert_equals 1 "$(field_of "$seen" AUTO)" \
    "$label: the claude process must see CLAUDE_CODE_DISABLE_AUTO_MEMORY=1"
  assert_equals 1 "$(field_of "$seen" COMPACT)" \
    "$label: the compact-adviser floor must stay on under a lean launch"
  assert_contains "$seen" ' --strict-mcp-config' \
    "$label: claude must be started with --strict-mcp-config"
  assert_not_contains "$seen" ' --bare' \
    "$label: a lean launch must not pass --bare"
  assert_not_contains "$seen" ' --mcp-config' \
    "$label: a lean launch must not pass an MCP config"
  assert_contains "$seen" ' --settings ' \
    "$label: session settings must still be passed"
  assert_contains "$seen" ' --dangerously-skip-permissions' \
    "$label: the permission flag must stay"
  if [ "$expect_append" = 1 ]; then
    assert_contains "$seen" ' --append-system-prompt ' \
      "$label: the task-channel statement must stay"
  else
    assert_not_contains "$seen" ' --append-system-prompt ' \
      "$label: a secondmate launch must not gain the task-channel statement"
  fi
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
  assert_not_contains "$seen" ' --bare' \
    "$label: an ordinary launch must not pass --bare"
  assert_contains "$seen" ' --settings ' \
    "$label: session settings must still be passed"
}

assert_lean_pane_export() { # <pane-log> <label>
  local panelog=$1 label=$2 compact lean
  [ "$(export_count "$panelog" 'export FORCE_PROMPT_CACHING_5M=1')" = 1 ] \
    || fail "$label: the pane should receive exactly one five-minute cache export"
  [ "$(export_count "$panelog" 'export COMPACT_ADVISER_DISABLE=1')" = 1 ] \
    || fail "$label: the compact-adviser pane export must stay"
  compact=$(grep -n -x -F 'export COMPACT_ADVISER_DISABLE=1' "$panelog" | tail -1 | cut -d: -f1)
  lean=$(grep -n -x -F 'export FORCE_PROMPT_CACHING_5M=1' "$panelog" | tail -1 | cut -d: -f1)
  [ -n "$compact" ] && [ -n "$lean" ] && [ "$lean" -gt "$compact" ] \
    || fail "$label: the five-minute cache export must follow the compact-adviser export"
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
      assert_lean_pane_export "$PANE_LOG" "$kind allowlist=$setting"
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
      assert_equals 1 "$(meta_lean_count "$HOME_DIR/state/$id.meta")" \
        "$kind allowlist=$setting: the task record must contain exactly one claude_lean=1"
      install_claude_probe "$FAKEBIN_DIR"
      seen=$(run_emitted_launch "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" 1) \
        || fail "$kind allowlist=$setting: the emitted launch failed to run"
      assert_lean_probe "$seen" "$kind allowlist=$setting" 1
      seen=$(run_emitted_launch "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" 0) \
        || fail "$kind allowlist=$setting: the launch command alone failed to run"
      assert_lean_probe "$seen" "$kind allowlist=$setting, launch command alone" 1
    done
  done
  pass "a lean ship or scout launch sets the five-minute cache and the smaller start, and keeps hooks, settings, and the task-channel statement"
}

test_lean_secondmate() {
  local rec id sm out status seen settings
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
  expect_code 0 "$status" "secondmate lean spawn should succeed: $out"
  assert_lean_pane_export "$PANE_LOG" "secondmate"
  settings="$HOME_DIR/state/$id.claude-settings.json"
  assert_hooks_installed "$settings" "secondmate"
  assert_grep "$settings" "$LAUNCH_LOG" \
    "secondmate: the launch must still pass the session settings file"
  assert_equals 1 "$(meta_lean_count "$HOME_DIR/state/$id.meta")" \
    "secondmate: the task record must contain exactly one claude_lean=1"
  install_claude_probe "$FAKEBIN_DIR"
  seen=$(run_emitted_launch "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" 1) \
    || fail "secondmate: the emitted launch failed to run"
  assert_lean_probe "$seen" "secondmate" 0
  pass "a lean secondmate launch drops MCP servers and auto memory, and keeps its own hooks file"
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

# --- relaunch ---------------------------------------------------------------

# Enough pane lifecycle for bin/fm-control.sh relaunch: /exit leaves a shell,
# and a sourced launch that starts claude brings the agent back.
make_relaunch_stub() { # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
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
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'")
          staged=${payload#". '"}
          staged=${staged%"'"}
          [ ! -f "$staged" ] || { payload=$(cat "$staged"); printf '%s\n' "$payload" > "$D/launch"; }
          ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit) printf 'zsh' > "$D/command" ;;
        *" claude "*) printf 'claude' > "$D/command" ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
        *pane_tty*) printf '/dev/null\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

prepare_relaunch_case() { # <name> <id> <lean-line-or-empty>
  local name=$1 id=$2 lean_line=$3
  RL_DIR="$TMP_ROOT/$name"
  RL_HOME="$RL_DIR/home"
  RL_PROJ="$RL_DIR/proj"
  RL_WT="$RL_DIR/wt"
  mkdir -p "$RL_HOME/state" "$RL_HOME/data" "$RL_HOME/config" "$RL_HOME/projects" "$RL_DIR/fake" "$RL_DIR/user-home"
  touch "$RL_HOME/state/.last-watcher-beat"
  make_relaunch_stub "$RL_DIR"
  fm_test_fake_treehouse "$RL_DIR/fakebin"
  fm_git_worktree "$RL_PROJ" "$RL_WT" "wt-$name"
  fm_test_spawn_brief "$RL_HOME" "$id"
  : > "$RL_DIR/fake/literal"
  : > "$RL_DIR/fake/keys"
  printf 'claude' > "$RL_DIR/fake/command"
  printf '%s\n' "fm-$id" > "$RL_DIR/fake/windows"
  printf '%s' "$RL_WT" > "$RL_DIR/fake/cwd"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$RL_WT"
    echo "project=$RL_PROJ"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=$RL_DIR/tasktmp"
    echo "model=default"
    echo "effort=default"
    [ -z "$lean_line" ] || printf '%s\n' "$lean_line"
  } > "$RL_HOME/state/$id.meta"
  fm_test_lease_existing_worktree "$RL_WT" "$RL_HOME/state/$id.meta" "$id" "$RL_HOME"
}

run_control_relaunch() { # <id> [extra control args...]
  local id=$1
  shift
  env PATH="$RL_DIR/fakebin:$PATH" FM_HOME="$RL_HOME" FM_FAKE_DIR="$RL_DIR/fake" \
    HOME="$RL_DIR/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=2 \
    "$CONTROL" "$id" relaunch --note 'replacement continues the same task' "$@"
}

test_relaunch_keeps_recorded_lean() {
  local id out status seen
  id="relaunch-keep-a1"
  prepare_relaunch_case relaunch-keep "$id" 'claude_lean=1'
  out=$(run_control_relaunch "$id" 2>&1)
  status=$?
  expect_code 0 "$status" "relaunch without the flag should keep the recorded lean posture: $out"
  [ "$(export_count "$RL_DIR/fake/keys" 'export FORCE_PROMPT_CACHING_5M=1')" = 1 ] \
    || fail "relaunch did not re-export the five-minute cache into the pane"
  [ -s "$RL_DIR/fake/launch" ] || fail "relaunch sent no replacement launch command"
  assert_equals 1 "$(meta_lean_count "$RL_HOME/state/$id.meta")" \
    "relaunch must keep exactly one claude_lean=1 and not duplicate the line"
  install_claude_probe "$RL_DIR/fakebin"
  seen=$(env -i HOME="$RL_DIR/user-home" PATH="$RL_DIR/fakebin:$PATH" TERM=xterm \
    TMUX=synthetic-pane \
    FORCE_PROMPT_CACHING_5M="$CONTRARY_FORCE" \
    CLAUDE_CODE_DISABLE_AUTO_MEMORY="$CONTRARY_AUTO" \
    COMPACT_ADVISER_DISABLE="$CONTRARY_COMPACT" \
    /bin/sh -c "$(cat "$RL_DIR/fake/launch")") \
    || fail "relaunch: the replacement launch failed to run"
  assert_lean_probe "$seen" "relaunch keeps lean" 1
  pass "relaunch without --claude-lean keeps the recorded lean posture"
}

test_relaunch_without_a_record_stays_ordinary() {
  local id out status seen
  id="relaunch-plain-a1"
  prepare_relaunch_case relaunch-plain "$id" ''
  out=$(run_control_relaunch "$id" 2>&1)
  status=$?
  expect_code 0 "$status" "relaunch of an ordinary task should succeed: $out"
  [ "$(export_count "$RL_DIR/fake/keys" 'export FORCE_PROMPT_CACHING_5M=1')" = 0 ] \
    || fail "relaunch of an ordinary task exported the five-minute cache"
  assert_no_grep 'FORCE_PROMPT_CACHING_5M' "$RL_DIR/fake/launch" \
    "relaunch of an ordinary task must not put the five-minute cache in the launch"
  assert_no_grep '--strict-mcp-config' "$RL_DIR/fake/launch" \
    "relaunch of an ordinary task must not pass --strict-mcp-config"
  assert_equals 0 "$(meta_lean_count "$RL_HOME/state/$id.meta")" \
    "relaunch of an ordinary task must not invent a claude_lean line"
  install_claude_probe "$RL_DIR/fakebin"
  seen=$(env -i HOME="$RL_DIR/user-home" PATH="$RL_DIR/fakebin:$PATH" TERM=xterm \
    TMUX=synthetic-pane \
    FORCE_PROMPT_CACHING_5M="$CONTRARY_FORCE" \
    CLAUDE_CODE_DISABLE_AUTO_MEMORY="$CONTRARY_AUTO" \
    COMPACT_ADVISER_DISABLE="$CONTRARY_COMPACT" \
    /bin/sh -c "$(cat "$RL_DIR/fake/launch")") \
    || fail "ordinary relaunch: the replacement launch failed to run"
  assert_plain_probe "$seen" "ordinary relaunch"
  pass "relaunch of a task with no claude_lean line stays an ordinary Claude launch"
}

test_relaunch_refuses_a_bad_record_and_a_harness_switch() {
  local id out status
  id="relaunch-bad-a1"
  prepare_relaunch_case relaunch-bad "$id" 'claude_lean=maybe'
  out=$(run_control_relaunch "$id" 2>&1)
  status=$?
  expect_code 1 "$status" "a relaunch of a garbage claude_lean line must refuse: $out"
  assert_contains "$out" 'records claude_lean=maybe' \
    "the refusal should quote the recorded value"
  assert_grep 'claude_lean=maybe' "$RL_HOME/state/$id.meta" \
    "a refused relaunch must leave the existing task record in place"

  id="relaunch-switch-a1"
  prepare_relaunch_case relaunch-switch "$id" 'claude_lean=1'
  out=$(run_control_relaunch "$id" --harness codex 2>&1)
  status=$?
  expect_code 1 "$status" "a lean task relaunched onto codex must refuse: $out"
  assert_contains "$out" 'applies only to the claude harness' \
    "the refusal should name the claude-only scope"
  assert_grep 'claude_lean=1' "$RL_HOME/state/$id.meta" \
    "a refused harness switch must leave the recorded lean line in place"
  assert_grep 'harness=claude' "$RL_HOME/state/$id.meta" \
    "a refused harness switch must leave the recorded harness in place"
  pass "relaunch refuses a garbage claude_lean line and a switch off the claude harness"
}

test_lean_ship_and_scout
test_lean_secondmate
test_ordinary_launch_is_unchanged
test_non_claude_refuses
test_raw_command_refuses
test_t3code_refuses_before_runtime_check
test_relaunch_keeps_recorded_lean
test_relaunch_without_a_record_stays_ordinary
test_relaunch_refuses_a_bad_record_and_a_harness_switch
