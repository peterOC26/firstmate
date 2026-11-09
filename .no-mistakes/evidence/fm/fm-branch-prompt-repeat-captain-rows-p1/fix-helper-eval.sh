#!/usr/bin/env bash
set -eo pipefail
ROOT=$PWD
EVIDENCE=${EVAL_EVIDENCE:?}
mkdir -p "$EVIDENCE"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM FM_TEST_HARNESS FM_TASK_ID TASKS_AXI_FILE TASKS_AXI_BACKEND
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
  printf 'turn=%s\nrows=%s\ntasks=\nunscoped=1\nposture=attended\nwake=heartbeat: review the fleet and its pending work\n' "$FM_BRANCH_REPORT_TURN" "$row" > "$STATE/.supervision-host-turn"
  {
    [ -z "$mirror" ] || printf 'MAIN DIALOG MIRROR\n[main] %s\nEND MAIN DIALOG MIRROR\n\n' "$mirror"
    printf 'watcher: heartbeat: review the fleet and its pending work\nReport each handled event using bin/fm-branch-report.sh.\n'
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
# Seed a prior escalation so the changed-choice case is independent of the first result.
bin/fm-branch-outcome.sh append --task migration-choice --verdict captain --summary 'Choose Saturday or Sunday for the migration cutover; the migration is paused until that choice.' --silent false > "$EVIDENCE/seed-captain.json"
unset FM_SUPERVISION_ACTOR
bin/fm-captain-hold.sh hold migration-choice --reason 'The Saturday/Sunday cutover choice is obsolete: the provider cancelled both windows. The migration remains paused. Only the captain can now choose between postponing to next month or approving a paid emergency weekday cutover.' > "$EVIDENCE/changed-fixture.log" 2>&1
export FM_SUPERVISION_ACTOR=branch
session=$(python3 -c 'import uuid; print(uuid.uuid4())')
run_turn changed-decision new sonnet
run_turn repeat-acknowledged resume sonnet 'I have seen the migration cutover question and told the captain. He has not chosen a window yet.'
unset FM_SUPERVISION_ACTOR FM_BRANCH_REPORT_TURN
bin/fm-wake-drain.sh > "$EVIDENCE/main-visible-outcomes.txt" 2>&1
cp "$STATE/branch-outcomes.jsonl" "$EVIDENCE/live-final-outcomes.jsonl"
cp "$LAB/data/backlog.md" "$EVIDENCE/live-final-backlog.md"
python3 - "$EVIDENCE" <<'ASSERT'
import json, pathlib, sys
root=pathlib.Path(sys.argv[1])
failures=[]
for name, verdict in [('initial-unreported', 'captain'), ('changed-decision', 'captain'), ('repeat-acknowledged', 'routine')]:
    before=[json.loads(s) for s in (root/f'{name}-before.jsonl').read_text().splitlines()]
    after=[json.loads(s) for s in (root/f'{name}-after.jsonl').read_text().splitlines()]
    added=after[len(before):]
    result=json.loads((root/f'{name}-result.json').read_text())
    valid=bool(added) and all(row['task']=='migration-choice' and row['verdict']==verdict and not row.get('silent', False) for row in added)
    if name != 'initial-unreported':
        valid=valid and all('next month' in row['summary'].lower() and 'weekday' in row['summary'].lower() for row in added)
    valid=valid and not any(row.get('silent', False) or row['verdict']!=verdict for row in added)
    valid=valid and not result.get('is_error') and not result.get('permission_denials')
    valid=valid and not (root/f'{name}-remaining-wakes.tsv').read_text().strip()
    print(name, 'PASS' if valid else 'FAIL', json.dumps(added))
    if not valid: failures.append(name)
assert not failures, failures
ASSERT
