#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB=$(mktemp -d "$ROOT/.test-phase-tmp/fm-lab.XXXXXX")
SOCKET=
cleanup() {
  if [ -n "$SOCKET" ] && [ -S "$SOCKET" ]; then tmux -S "$SOCKET" kill-server 2>/dev/null || true; fi
  bin/fm-lab-home.sh teardown "$LAB" || true
  chmod -R u+rwX "$LAB"
  rm -rf "$LAB"
}
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB"
SOCKET_DIR=$(bin/fm-lab-home.sh tmux-dir "$LAB")
SOCKET="$SOCKET_DIR/tmux-$(id -u)/fm-lab"
mkdir -p "$SOCKET_DIR/tmux-$(id -u)"
export TREEHOUSE_ROOT="$LAB/treehouse"
mkdir -p "$LAB/project" "$LAB/data/lease-live"
git -C "$LAB/project" init -q
printf 'lease validation fixture\n' > "$LAB/project/README.md"
git -C "$LAB/project" add README.md
git -C "$LAB/project" -c user.name='Validation' -c user.email='test@example.invalid' commit -qm initial
git clone -q --bare "$LAB/project" "$LAB/origin.git"
git -C "$LAB/project" remote add origin "file://$LAB/origin.git"
cat > "$LAB/data/lease-live/brief.md" <<'BRIEF'
# Task
## Captain's intent
Observe a real tmux worker retaining its isolated durable lease after its command exits.
## Firstmate spec
Use an idle shell command to exercise lease acquisition and cleanup.
BRIEF
printf 'manual\n' > "$LAB/config/backlog-backend"
touch "$LAB/state/.last-watcher-beat"
tmux -S "$SOCKET" new-session -d -s primary -x 120 -y 40 -c "$ROOT"
TMUX=$(tmux -S "$SOCKET" display-message -p -t primary '#{socket_path},#{pid},0')
export TMUX
export FM_HOME="$LAB" FM_SPAWN_NO_GUARD=1
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_BACKEND HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH
printf '\n$ fm-spawn.sh lease-live PROJECT "sh -c ..." --scout --backend tmux\n'
bin/fm-spawn.sh lease-live "$LAB/project" "sh -c 'printf LEASE_WORKER_STARTED; sleep 300'" --scout --backend tmux
printf '\n$ task metadata and acquisition identity\n'
cat "$LAB/state/lease-live.meta"
cat "$LAB/state/lease-live.treehouse-acquire/identity"
WT=$(sed -n 's/^worktree=//p' "$LAB/state/lease-live.meta")
TARGET=$(sed -n 's/^window=//p' "$LAB/state/lease-live.meta")
LEASE_ID=$(sed -n 's/^treehouse_lease_id=//p' "$LAB/state/lease-live.meta")
[ -n "$LEASE_ID" ]
[ "$(tmux -S "$SOCKET" display-message -p -t "$TARGET" '#{pane_current_path}')" = "$WT" ]
printf '\n$ tmux capture-pane (real shell endpoint)\n'
tmux -S "$SOCKET" capture-pane -p -t "$TARGET"
printf '\n$ kill exact worker window, then treehouse status --json\n'
tmux -S "$SOCKET" kill-window -t "$TARGET"
(cd "$LAB/project" && treehouse status --json) > "$LAB/pool-after-exit.json"
cat "$LAB/pool-after-exit.json"
jq -e --arg lease "$LEASE_ID" '.. | objects | select(.lease_id? == $lease and .status? == "leased")' "$LAB/pool-after-exit.json"
printf '\n$ repeat same-id spawn (must refuse)\n'
set +e
bin/fm-spawn.sh lease-live "$LAB/project" "sh -c 'sleep 300'" --scout --backend tmux > "$LAB/retry.log" 2>&1
RETRY_STATUS=$?
set -e
cat "$LAB/retry.log"
printf 'same-id retry exit=%s\n' "$RETRY_STATUS"
[ "$RETRY_STATUS" -ne 0 ]
printf 'Lease lifecycle observation complete.\n' > "$LAB/data/lease-live/report.md"
bin/fm-captain-hold.sh complete lease-live --none
printf '\n$ fm-teardown.sh lease-live\n'
bin/fm-teardown.sh lease-live
[ ! -e "$LAB/state/lease-live.meta" ]
[ ! -e "$LAB/state/lease-live.treehouse-acquire" ]
printf '\n$ treehouse status --json after guarded cleanup\n'
(cd "$LAB/project" && treehouse status --json) > "$LAB/pool-after-cleanup.json"
cat "$LAB/pool-after-cleanup.json"
! jq -e --arg lease "$LEASE_ID" '.. | objects | select(.lease_id? == $lease)' "$LAB/pool-after-cleanup.json"
printf '\nVerified real tmux cwd, durable lease after endpoint exit, duplicate refusal, and guarded lease release.\n'
