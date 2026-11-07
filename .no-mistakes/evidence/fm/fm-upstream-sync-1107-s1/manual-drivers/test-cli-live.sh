#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=/home/zabi/.no-mistakes/evidence/01M6W1RCVXS15VZT05F5RDMYXZ
LAB="$ROOT/.test-cli-home"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
export FM_HOME="$LAB"
trap 'rm -rf "$LAB"' EXIT
touch "$LAB/config/supervision-host-off"
printf '# Backlog\n\n## Queued\n' > "$LAB/data/backlog.md"
printf 'done: upstream-update CLI event reached the operator\n' > "$LAB/state/delivery.status"
sleep 1
"$ROOT/bin/fm-wake-drain.sh" > "$EVIDENCE/wake-live-first.txt"
"$ROOT/bin/fm-wake-drain.sh" > "$EVIDENCE/wake-live-second.txt"
grep -F 'upstream-update CLI event reached the operator' "$EVIDENCE/wake-live-first.txt"
if grep -Fq 'upstream-update CLI event reached the operator' "$EVIDENCE/wake-live-second.txt"; then
  echo 'Repeated an already presented event' >&2; exit 1
fi
printf 'blocked: local CLI needs a decision\n' > "$LAB/state/decision.status"
sleep 1
"$ROOT/bin/fm-wake-drain.sh" > "$EVIDENCE/wake-live-decision.txt"
grep -F 'local CLI needs a decision' "$EVIDENCE/wake-live-decision.txt"
"$ROOT/bin/fm-bearings-snapshot.sh" --json > "$EVIDENCE/bearings-live.json"
jq '{schema, prs, in_flight, charted_next, contributions, omitted}' "$EVIDENCE/bearings-live.json"
printf 'CLI backstop presented a terminal event once and retained the open decision.\n'
