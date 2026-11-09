#!/usr/bin/env bash
set -eo pipefail
ROOT=$PWD
EVIDENCE=${EVAL_EVIDENCE:?}
mkdir -p "$EVIDENCE"
unset FM_BACKEND HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION REX_SESSION REX_BLOCK FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM FM_TEST_HARNESS FM_TASK_ID TASKS_AXI_FILE TASKS_AXI_BACKEND
LAB=$(mktemp -d "$ROOT/.helper-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB"
export FM_HOME="$LAB" FM_ROOT="$ROOT" STATE="$LAB/state"
printf 'claude sonnet\n' > "$LAB/config/supervision-host"
. bin/fm-wake-lib.sh
. bin/fm-timeout-lib.sh
. bin/fm-supervision-engine-lib.sh
bin/fm-branch-prompt.sh --supervision-host > "$EVIDENCE/live-host-prompt.txt"
export FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ FM_SUPERVISION_PRIMARY_HARNESS=claude
session=$(python3 -c 'import uuid; print(uuid.uuid4())')
run_turn() {
  local name=$1 mode=$2 model=$3 mirror=${4:-}
  export FM_BRANCH_REPORT_TURN="eval-$name"
  local gen="eval-$name"
  fm_wake_append heartbeat "$name" 'heartbeat: review the fleet and its pending work'
  local row
  row=$(tail -n 1 "$FM_WAKE_QUEUE" | cut -f2)
  bin/fm-wake-grant.sh activate $$ "$gen"
  bin/fm-wake-grant.sh publish "$gen" "$row"
  printf 'turn=%s\nrows=%s\ntasks=\nunscoped=1\nposture=%s\nwake=heartbeat: review the fleet and its pending work\n' "$FM_BRANCH_REPORT_TURN" "$row" "${POSTURE:-attended}" > "$STATE/.supervision-host-turn"
  {
    [ -z "$mirror" ] || printf 'MAIN DIALOG MIRROR\n[main] %s\nEND MAIN DIALOG MIRROR\n\n' "$mirror"
    printf 'watcher: heartbeat: review the fleet and its pending work\nReport each handled event using bin/fm-branch-report.sh.\n'
    if [ "${POSTURE:-attended}" = away ]; then bin/fm-afk-contract.sh readback; fi
  } > "$EVIDENCE/$name-message.txt"
  bin/fm-branch-outcome.sh list --recent 100 > "$EVIDENCE/$name-before.jsonl"
  printf 'Starting %s (%s)\n' "$name" "$model"
  local rc=0
  fm_supervision_engine_turn claude "$model" "$EVIDENCE/live-host-prompt.txt" "$EVIDENCE/$name-message.txt" "$session" "$mode" 240 "$EVIDENCE/$name-result.json" "$EVIDENCE/$name-errors.log" || rc=$?
  printf '%s engine exit=%s\n' "$name" "$rc"
  fm_supervision_engine_result claude "$EVIDENCE/$name-result.json" || true
  bin/fm-branch-outcome.sh list --recent 100 > "$EVIDENCE/$name-after.jsonl"
  cp "$STATE/.supervision-host-receipts" "$EVIDENCE/$name-receipts.tsv" 2>/dev/null || true
  cp "$FM_WAKE_QUEUE" "$EVIDENCE/$name-remaining-wakes.tsv"
  bin/fm-wake-grant.sh deactivate $$ "$gen"
  [ "$rc" -eq 0 ]
}
run_turn idle-empty new sonnet
