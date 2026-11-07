#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=/home/zabi/.no-mistakes/evidence/01M6W1RCVXS15VZT05F5RDMYXZ
export FM_HERDR_LAB_STATE_DIR="$PWD/.test-lab-herdr"
SESSION=fm-lab-upstream-gate-1107
HELPER="$PWD/bin/fm-herdr-lab.sh"
cleanup() { "$HELPER" teardown "$SESSION"; }
trap cleanup EXIT
"$HELPER" provision "$SESSION"
lab() { "$HELPER" run "$SESSION" "$@"; }
lab status --json
workspace=$(lab workspace create --cwd "$ROOT" --label upstream-sync-validation --no-focus)
printf '%s\n' "$workspace"
pane=$(jq -er '.result.root_pane.pane_id' <<< "$workspace")
ws=$(jq -er '.result.workspace.workspace_id' <<< "$workspace")
"$HELPER" viewer start "$SESSION"
lab pane run "$pane" 'printf "FM_LIVE_UPSTREAM_TRANSPORT_OK\n"; pwd'
for i in {1..30}; do
  screen=$(lab pane read "$pane" --source visible)
  case "$screen" in *FM_LIVE_UPSTREAM_TRANSPORT_OK*) break ;; esac
  sleep .1
done
printf '%s\n' "$screen" | tee "$EVIDENCE/herdr-live-pane.txt"
case "$screen" in *"$ROOT"*) ;; *) exit 1 ;; esac
lab pane get "$pane"
lab pane close "$pane"
lab pane get "$pane" > "$EVIDENCE/herdr-closed-pane.json" 2>&1 || true
cat "$EVIDENCE/herdr-closed-pane.json"
jq -e '.error.code == "pane_not_found"' "$EVIDENCE/herdr-closed-pane.json"
printf 'Lab pane ran the command in the intended local copy, then was confirmed gone.\n'
