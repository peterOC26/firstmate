#!/usr/bin/env bash
set -eu
. tests/fixtures.sh
TMP_ROOT=$(fm_test_tmproot tier-secondmate-config)
H="$TMP_ROOT/home"
PROJ="$TMP_ROOT/project"
WT="$TMP_ROOT/wt"
SM="$TMP_ROOT/secondmate"
ID=tier-secondmate-proof
EVIDENCE=/home/zabi/.no-mistakes/evidence/01M69FH37Q1230T52YRHMGY8AD
fakebin=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fake")
fm_test_spawn_home "$H" codex
fm_test_spawn_brief "$H" "$ID"
fm_git_worktree "$PROJ" "$WT" tier-secondmate
mkdir -p "$SM/bin" "$SM/data"
printf '# Firstmate\n' > "$SM/AGENTS.md"
printf '%s\n' "$ID" > "$SM/.fm-secondmate-home"
printf 'Disposable launch proof\n' > "$SM/data/charter.md"
printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$SM/.gitignore"
git -C "$SM" init -q -b main
FM_FAKE_LAUNCH_LOG="$TMP_ROOT/launch.log" fm_test_run_spawn "$H" "$WT" "$fakebin" "$ID" "$SM" --secondmate > "$EVIDENCE/secondmate-generated-launch.log"
cp "$TMP_ROOT/launch.log" "$EVIDENCE/secondmate-launch-command.txt"
if rg -q '^service_tier=' "$H/state/$ID.meta"; then
  echo 'Unexpected configurable tier in metadata' >&2
  exit 1
fi
