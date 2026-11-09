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
bin/fm-captain-hold.sh hold migration-choice --title 'Choose migration cutover window' --reason 'The migration is paused. Only the captain can choose Saturday or Sunday for the cutover; no work may resume before that choice.' > "$EVIDENCE/live-fixture-setup.log" 2>&1
bin/fm-branch-outcome.sh append --task migration-choice --verdict routine --summary 'The migration is paused pending the choice of Saturday or Sunday for cutover.' --silent false >> "$EVIDENCE/live-fixture-setup.log"
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
run_turn initial-unreported new sonnet
# Acknowledge the actual escalation through the public store consumer.
unset FM_SUPERVISION_ACTOR FM_BRANCH_REPORT_TURN
bin/fm-wake-drain.sh > "$EVIDENCE/initial-main-drain.txt"
seq=$(python3 -c 'import json,sys; print(max((r["seq"] for r in map(json.loads,open(sys.argv[1])) if r["verdict"]=="captain"),default=0))' "$STATE/branch-outcomes.jsonl")
if [ "$seq" -gt 0 ]; then bin/fm-branch-outcome.sh mark-processed --through "$seq"; fi
export FM_SUPERVISION_ACTOR=branch
run_turn repeat-acknowledged resume sonnet 'I have seen the migration cutover question and told the captain. He has not chosen a window yet.'
run_turn repeat-again resume sonnet
for i in $(seq 1 25); do
  bin/fm-branch-outcome.sh append --task "unrelated-$i" --verdict routine --summary 'Background housekeeping completed; no decision or next action.' --silent true >/dev/null
done
session=$(python3 -c 'import uuid; print(uuid.uuid4())')
run_turn repeat-buried-history new opus
unset FM_SUPERVISION_ACTOR
bin/fm-captain-hold.sh hold migration-choice --reason 'The Saturday/Sunday cutover choice is obsolete: the provider cancelled both windows. The migration remains paused. Only the captain can now choose between postponing to next month or approving a paid emergency weekday cutover.' > "$EVIDENCE/changed-fixture.log" 2>&1
export FM_SUPERVISION_ACTOR=branch
session=$(python3 -c 'import uuid; print(uuid.uuid4())')
run_turn changed-decision new sonnet
run_turn changed-repeat resume sonnet
# The following answer is synthetic scenario input in this disposable lab only.
unset FM_SUPERVISION_ACTOR FM_BRANCH_REPORT_TURN
printf '%s\n' 'Postpone until next month.' > "$LAB/fixture-answer.txt"
bin/fm-captain-hold.sh answer migration-choice --decision-file "$LAB/fixture-answer.txt" > "$EVIDENCE/resolved-fixture.log"
export FM_SUPERVISION_ACTOR=branch
session=$(python3 -c 'import uuid; print(uuid.uuid4())')
run_turn resolved-idle new sonnet
# Re-use the empty lab to exercise away posture without any live primary.
unset FM_SUPERVISION_ACTOR FM_BRANCH_REPORT_TURN
bin/fm-captain-hold.sh hold budget-choice --title 'Choose migration budget' --reason 'Only the captain can choose whether to approve the paid emergency cutover or keep the free next-month window.' > "$EVIDENCE/away-fixture.log"
bin/fm-afk-contract.sh enter --words 'Hold any question that needs my choice for my return. Do not choose a cutover window for me.' > "$EVIDENCE/away-record.txt"
export FM_SUPERVISION_ACTOR=branch POSTURE=away
session=$(python3 -c 'import uuid; print(uuid.uuid4())')
run_turn away-initial new opus
run_turn away-repeat resume opus
unset FM_SUPERVISION_ACTOR FM_BRANCH_REPORT_TURN
bin/fm-wake-drain.sh > "$EVIDENCE/main-visible-outcomes.txt" 2>&1
cp "$STATE/branch-outcomes.jsonl" "$EVIDENCE/live-final-outcomes.jsonl"
cp "$LAB/data/backlog.md" "$EVIDENCE/live-final-backlog.md"
printf 'Disposable lab removed by EXIT trap.\n'
