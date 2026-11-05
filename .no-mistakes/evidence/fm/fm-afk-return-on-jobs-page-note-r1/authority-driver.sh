#!/usr/bin/env bash
set -eu
bin/fm-lock.sh
bin/fm-afk-contract.sh enter --words 'Watch the fleet while I am away.'
FM_SUPERVISION_HOST_PRIMARY=claude FM_SUPERVISION_HOST_PARK_SECONDS=270 FM_SUPERVISION_HOST_TURN_TIMEOUT=180 FM_SUPERVISION_ENGINE_GRACE=1 FM_POLL=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 bin/fm-supervision-host.sh park > "$FM_HOME/host-output.txt" 2>&1 &
host=$!
trap 'kill -TERM "$host" 2>/dev/null || true; bin/fm-watch-arm.sh --stop >/dev/null 2>&1 || true' EXIT
for n in $(seq 1 2300); do
 if grep -q 'handled.*posture=away' "$FM_HOME/state/.supervision-host.log" 2>/dev/null; then break; fi
 kill -0 "$host" 2>/dev/null || break
 sleep 0.1
done
printf '
AWAY POSTURE AFTER ROUTINE EVENT: '
bin/fm-afk-contract.sh mode
printf '
PRIMARY STILL PARKED BEFORE NOTE: '
if kill -0 "$host" 2>/dev/null; then echo yes; else echo no; fi
printf '
JOB STATES AFTER BRANCH TURN:
'
for task in eval-dated eval-qid eval-undated eval-neighbor eval-security; do
 bin/fm-tasks-axi.sh show "$task" --full
done
printf '
CREDENTIAL FIXTURE:
'
cat "$FM_HOME/data/security-sensitive-credential"
printf '
BRANCH OUTCOMES:
'
bin/fm-branch-outcome.sh list
bin/fm-inbox.sh note --json --request-id authority-complete 'I am back; finish the disposable lab check.'
wait "$host"
cat "$FM_HOME/host-output.txt"
printf '
HOST LEDGER:
'
cat "$FM_HOME/state/.supervision-host.log"
