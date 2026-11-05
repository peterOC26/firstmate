#!/usr/bin/env bash
set -eu
bin/fm-lock.sh
bin/fm-afk-contract.sh enter --words 'Watch the fleet.'
FM_SUPERVISION_HOST_PRIMARY=claude FM_SUPERVISION_HOST_PARK_SECONDS=5 FM_SUPERVISION_HOST_TURN_TIMEOUT=1 FM_SUPERVISION_ENGINE_GRACE=1 FM_POLL=15 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 bin/fm-supervision-host.sh park > "$FM_HOME/host-output.txt" 2>&1 &
host=$!
trap 'kill -TERM "$host" 2>/dev/null || true; bin/fm-watch-arm.sh --stop >/dev/null 2>&1 || true' EXIT
for n in $(seq 1 100); do
 [ ! -f "$FM_HOME/state/.last-watcher-beat" ] || break
 sleep 0.1
done
sleep 1
bin/fm-inbox.sh note --json --request-id live-boundary 'Hello from Jobs during this lab check.'
wait "$host"
cat "$FM_HOME/host-output.txt"
printf '
POSTURE AFTER HANDOFF: '
bin/fm-afk-contract.sh mode
printf '
QUEUED NOTE AND REPLIES:
'
bin/fm-inbox.sh receipts --all-pending
printf '
HOST LEDGER:
'
cat "$FM_HOME/state/.supervision-host.log"
