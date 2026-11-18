#!/usr/bin/env bash
# tests/fm-spawn-home-env-scrub.test.sh - a launched worker must not inherit the
# supervising home's wake-queue or state-path overrides from its pane.
#
# Drives the real spawn against a fake pane, then executes the launch command
# the pane received under a synthetic pane environment that carries the
# supervisor's values, with the harness replaced by a probe that prints what it
# was started with.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-home-env-scrub)
SUPERVISOR="$TMP_ROOT/supervisor"
mkdir -p "$SUPERVISOR/state"

SCRUBBED='FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK FM_ROOT_OVERRIDE FM_STATE_OVERRIDE'
PRESERVED='FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE FM_SNAPSHOT_CACHE_DIR FM_CREW_STATE_META_OVERRIDE FM_CREW_STATE_STATUS_OVERRIDE'

install_probe() {  # <fakebin>
  cat > "$1/codex" <<SH
#!/bin/sh
for name in $SCRUBBED $PRESERVED FM_HOME FM_TASK_INBOX; do
  eval "printf '%s=%s\n' \"\$name\" \"\\\${\$name:-unset}\""
done
SH
  chmod +x "$1/codex"
}

# The pane a backend server hands out when that server was started from inside
# the supervising firstmate's shell.
run_in_supervisor_pane() {  # <fakebin> <launch> [preamble]
  env -i HOME="$TMP_ROOT/pane-home" PATH="$1:$PATH" TERM=xterm TMUX=synthetic-pane \
    FM_HOME="$SUPERVISOR" \
    FM_WAKE_QUEUE="$SUPERVISOR/state/.wake-queue" \
    FM_WAKE_QUEUE_LOCK="$SUPERVISOR/state/.wake-queue.lock" \
    FM_ROOT_OVERRIDE="$SUPERVISOR" FM_STATE_OVERRIDE="$SUPERVISOR/state" \
    FM_DATA_OVERRIDE="$SUPERVISOR/data" FM_PROJECTS_OVERRIDE="$SUPERVISOR/projects" \
    FM_CONFIG_OVERRIDE="$SUPERVISOR/config" \
    FM_SNAPSHOT_CACHE_DIR="$SUPERVISOR/data/cache" \
    FM_CREW_STATE_META_OVERRIDE="$SUPERVISOR/state/other.meta" \
    FM_CREW_STATE_STATUS_OVERRIDE="$SUPERVISOR/state/other.status" \
    "$4" -c "${3:-}
$2"
}

assert_scrubbed() {  # <seen> <label> <want-home> <want-inbox>
  local seen=$1 label=$2 name
  for name in $SCRUBBED; do
    assert_contains "$seen" "$name=unset" "$label: the worker must not inherit $name"
  done
  assert_contains "$seen" "FM_HOME=$3" "$label: the worker must keep FM_HOME"
  assert_contains "$seen" "FM_TASK_INBOX=$4" "$label: the worker must keep its steering inbox"
}

spawn_and_probe() {  # <kind> <allowlist absent|enabled>
  local kind=$1 setting=$2 dir home proj wt fakebin id out status sm want_home seen pane_shell pair name value
  id="scrub-$kind-$setting-a1"
  dir="$TMP_ROOT/$kind-$setting"
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$dir/fake")
  fm_test_spawn_home "$home" codex
  [ "$setting" = absent ] || : > "$home/config/launch-env-allowlist"
  fm_git_worktree "$proj" "$wt" "wt-$kind-$setting"
  fm_test_spawn_brief "$home" "$id"
  : > "$dir/launch.log"
  : > "$dir/pane.log"
  if [ "$kind" = ship ]; then
    want_home=$SUPERVISOR
    out=$(FM_FAKE_LAUNCH_LOG="$dir/launch.log" FM_FAKE_PANE_LOG="$dir/pane.log" \
      fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off)
  else
    sm="$dir/secondmate-home"
    want_home=$sm
    mkdir -p "$sm/bin" "$sm/data"
    printf '# Firstmate\n' > "$sm/AGENTS.md"
    printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
    printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
    printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$sm/.gitignore"
    git -C "$sm" init -q -b main
    out=$(FM_FAKE_LAUNCH_LOG="$dir/launch.log" FM_FAKE_PANE_LOG="$dir/pane.log" \
      fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$sm" --secondmate)
  fi
  status=$?
  expect_code 0 "$status" "$kind spawn with allowlist=$setting should succeed: $out"
  # Under the allowlist the pane's FM_HOME is filtered out like everything else,
  # so only the ambient launch can show that it survives.
  [ "$setting" = absent ] || want_home='unset'
  install_probe "$fakebin"
  for pane_shell in /bin/sh fish; do
    if ! command -v "$pane_shell" >/dev/null 2>&1; then
      printf 'skip: %s is not installed; pane scrub not exercised in that shell\n' "$pane_shell"
      continue
    fi
    seen=$(run_in_supervisor_pane "$fakebin" "$(cat "$dir/launch.log")" "$(grep '^export ' "$dir/pane.log")" "$pane_shell" 2>"$dir/probe.stderr") \
      || fail "$kind, allowlist $setting, $pane_shell: the emitted launch failed to run"
    assert_not_contains "$(cat "$dir/probe.stderr")" "Unknown command" "$pane_shell: launch used an unsupported command"
    assert_scrubbed "$seen" "$kind, allowlist $setting, $pane_shell" "$want_home" \
      "$(cd "$home/state" && pwd -P)/$id.inbox"
    for pair in FM_DATA_OVERRIDE=data FM_PROJECTS_OVERRIDE=projects FM_CONFIG_OVERRIDE=config FM_SNAPSHOT_CACHE_DIR=data/cache FM_CREW_STATE_META_OVERRIDE=state/other.meta FM_CREW_STATE_STATUS_OVERRIDE=state/other.status; do
      name=${pair%%=*}
      value="$SUPERVISOR/${pair#*=}"
      if [ "$setting" = enabled ]; then
        value=unset
      elif [ "$kind" = secondmate ]; then
        case "$name" in
          FM_DATA_OVERRIDE | FM_PROJECTS_OVERRIDE | FM_CONFIG_OVERRIDE) value=unset ;;
        esac
      fi
      assert_contains "$seen" "$name=$value" "$kind, allowlist $setting, $pane_shell: unrelated override changed"
    done
  done
}

test_ship_launch_drops_supervisor_paths() {
  spawn_and_probe ship absent
  spawn_and_probe ship enabled
  pass "a ship worker starts without the supervising home's queue or state-path overrides"
}

test_secondmate_launch_drops_supervisor_paths() {
  spawn_and_probe secondmate absent
  pass "a secondmate starts without the supervising home's queue or state-path overrides"
}

test_ship_launch_drops_supervisor_paths
test_secondmate_launch_drops_supervisor_paths
