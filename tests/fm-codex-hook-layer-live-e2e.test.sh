#!/usr/bin/env bash
# Live guard for the codex crewmate launch's hook and service-tier posture.
#
# The verdict here comes from the installed codex, not from a stub: a stub can
# only confirm the assumption already written into it, and what this guard
# protects is exactly a vendor-owned surface. Codex blocks a fresh crewmate
# launch on an unanswerable "Hooks need review" modal whenever the machine's
# ~/.codex/hooks.json or a project's .codex/hooks.json carries a hook it has no
# persisted trust for, so the crewmate launch disables codex's hook layer
# outright (bin/fm-spawn.sh's launch template owns the flag).
#
# The guard replays the REAL launch flags fm-spawn builds - captured from a
# spawn driven through a fake pane - against the installed codex and asks codex
# itself whether hooks ended up disabled. If a codex release renames or drops
# the feature, the flag becomes a hard "Unknown feature flag" error and this
# guard fails naming the harness and version instead of letting the modal
# silently come back.
#
# It spends no model tokens (`codex features list` resolves configuration only),
# so it runs by default wherever codex is installed.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate default-on FM_CODEX_HOOK_LAYER_LIVE codex python3

CODEX_VERSION=$(codex --version 2>&1)
TMP_ROOT=$(fm_test_tmproot fm-codex-hook-layer-live)

# capture_codex_launch <name> <extra fm-spawn args...>: spawns a codex crewmate
# against a fake pane and echoes the literal launch command firstmate sent.
capture_codex_launch() {
  local name=$1
  shift
  local case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  id="codex-hook-layer-$name"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  : > "$launchlog"
  FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" "$@" >/dev/null 2>&1 ||
    fail "codex $CODEX_VERSION: fm-spawn could not build a crewmate launch"
  cat "$launchlog"
}

# codex_global_flags <launch command>: the flags between the codex executable
# and the positional brief, which is everything codex itself is configured by.
codex_global_flags() {
  local launch=$1 flags
  flags=${launch#*codex }
  flags=${flags%%\"\$(*}
  printf '%s' "$flags"
}

test_installed_codex_disables_hooks_for_the_captured_crewmate_launch() {
  local launch flags state
  launch=$(capture_codex_launch ship --mode no-mistakes --yolo off)
  flags=$(codex_global_flags "$launch")

  # The whole point: every flag firstmate will launch with, handed to the real
  # codex, must leave the hook layer off. `features list` reports the effective
  # state after those flags are applied and contacts no model.
  state=$(eval "codex $flags features list" 2>&1) ||
    fail "codex $CODEX_VERSION rejected firstmate's crewmate launch flags: $state"
  case "$state" in
    *"Unknown feature flag"*)
      fail "codex $CODEX_VERSION no longer knows the hook feature firstmate disables: $state"
      ;;
  esac
  printf '%s\n' "$state" | awk '$1 == "hooks" { print $NF }' | grep -qx false ||
    fail "codex $CODEX_VERSION left hooks enabled for firstmate's crewmate launch flags, so a fresh launch can park on the hook-trust modal"

  printf 'ok - codex %s runs a firstmate crewmate launch with its hook layer disabled\n' "$CODEX_VERSION"
}

test_installed_codex_still_reports_the_hook_feature() {
  local listing
  listing=$(codex features list 2>&1) ||
    fail "codex $CODEX_VERSION could not list its feature flags: $listing"
  printf '%s\n' "$listing" | awk '{ print $1 }' | grep -qx hooks ||
    fail "codex $CODEX_VERSION no longer publishes a hook feature flag; firstmate's crewmate launch needs a new control"

  printf 'ok - codex %s still publishes the hook feature flag firstmate disables\n' "$CODEX_VERSION"
}

test_installed_codex_resolves_the_captured_service_tier() {
  local codex_home launch flags tier effective
  codex_home="$TMP_ROOT/tier-config"
  mkdir -p "$codex_home"
  printf 'service_tier = "fast"\n' > "$codex_home/config.toml"
  for tier in baseline default; do
    flags=
    case "$tier" in
      default) launch=$(capture_codex_launch tier-default --mode no-mistakes --yolo off); flags=$(codex_global_flags "$launch") ;;
    esac
    effective=$(CODEX_HOME="$codex_home" FM_TEST_CODEX_FLAGS="$flags" python3 - <<'PY'
import json
import os
import shlex
import signal
import subprocess

def timed_out(_signal, _frame):
    raise TimeoutError("Codex configuration probe exceeded 20 seconds")

signal.signal(signal.SIGALRM, timed_out)
signal.alarm(20)
command = ["codex", "--no-daemon", *shlex.split(os.environ["FM_TEST_CODEX_FLAGS"]), "app-server"]
process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, text=True)
try:
    requests = [
        {"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "firstmate-tier-guard", "version": "1"}}},
        {"id": 2, "method": "config/read", "params": {"includeLayers": False}},
    ]
    for request in requests:
        process.stdin.write(json.dumps(request) + "\n")
        process.stdin.flush()
        while True:
            line = process.stdout.readline()
            if not line:
                raise RuntimeError("Codex closed before returning configuration")
            message = json.loads(line)
            if message.get("id") == request["id"]:
                break
        if "error" in message:
            raise RuntimeError(message["error"])
        if request["id"] == 2:
            print(message["result"]["config"]["service_tier"])
finally:
    signal.alarm(0)
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
PY
    ) || fail "codex $CODEX_VERSION could not resolve the $tier service tier"
    case "$tier:$effective" in
      baseline:fast|default:default) ;;
      *) fail "codex $CODEX_VERSION resolved $tier service tier to '$effective'" ;;
    esac
  done
  printf 'ok - codex %s overrides a Fast preference with regular service\n' "$CODEX_VERSION"
}

test_installed_codex_still_reports_the_hook_feature
test_installed_codex_disables_hooks_for_the_captured_crewmate_launch
test_installed_codex_resolves_the_captured_service_tier

echo "# all fm-codex-hook-layer-live-e2e tests passed"
