#!/usr/bin/env bash
# Live driver: real Herdr lab session + real Treehouse pool + real fm-spawn and
# fm-control relaunch with the real claude CLI, all in disposable state.
# Usage: live-relaunch-herdr-lease.sh <repo-root> <case: adopt|foreign>
set -u
ROOT=$1 CASE=$2
ID="lease-$CASE"
. "$ROOT/tests/fixtures.sh"
HELPER="$ROOT/bin/fm-herdr-lab.sh"
SESSION=$("$HELPER" name "relaunch-$CASE")
export HERDR_LAB_HELPER=$HELPER HERDR_LAB_SESSION=$SESSION ORIGINAL_PATH=$PATH
TMP=$(mktemp -d /tmp/fm-relaunch-lease.XXXXXX)
LAB="$TMP/home"
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
cleanup() {
  local st=$?
  log "teardown"
  "$HELPER" teardown "$SESSION" || st=1
  (cd "$TMP/project" 2>/dev/null && TREEHOUSE_ROOT="$TMP/pool" treehouse destroy --help >/dev/null 2>&1) || true
  find "$TMP" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$TMP"
  exit "$st"
}
trap cleanup EXIT
"$HELPER" provision "$SESSION" >/dev/null || { echo "provision failed"; exit 1; }
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/herdr" <<'EOF'
#!/usr/bin/env bash
set -eu
args=("$@")
if [ "${1:-}" = --version ]; then
  PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" status --json | jq -r '"herdr " + .client.version'
  exit
fi
n=${#args[@]}
[ "$n" -lt 2 ] || {
  [ "${args[n-2]}" != --session ] || {
    [ "${args[n-1]}" = "$HERDR_LAB_SESSION" ] || exit 1
    unset 'args[n-1]' 'args[n-2]'
  }
}
exec env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${args[@]}"
EOF
chmod +x "$TMP/fakebin/herdr"
lab() { "$HELPER" run "$SESSION" "$@"; }
HERDR_SOCKET_PATH=$(lab session list --json | jq -er --arg s "$SESSION" '.sessions[] | select(.name == $s) | .socket_path')
export HERDR_SOCKET_PATH

# Disposable project with a bare origin; disposable Treehouse pool root.
git init -q --bare "$TMP/origin.git"
fm_git_init_commit "$TMP/project"
git -C "$TMP/project" remote add origin "$TMP/origin.git"
git -C "$TMP/project" push -q origin HEAD:main
git -C "$TMP/origin.git" symbolic-ref HEAD refs/heads/main
git -C "$TMP/project" fetch -q origin
git -C "$TMP/project" remote set-head origin main >/dev/null
export TREEHOUSE_ROOT="$TMP/pool"

"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
fm_test_spawn_home "$LAB" claude
fm_test_spawn_brief "$LAB" "$ID" 'Idle worker used to exercise relaunch lease adoption.'
PARENT=$(lab workspace create --cwd "$TMP/project" --label firstmate --focus)
export HERDR_PANE_ID=$(printf '%s' "$PARENT" | jq -er '.result.root_pane.pane_id')

FMENV=(env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE
  PATH="$TMP/fakebin:$ORIGINAL_PATH" FM_HOME="$LAB" FM_SPAWN_NO_GUARD=1 HERDR_SESSION="$SESSION" TREEHOUSE_ROOT="$TMP/pool")

log "== real fm-spawn (herdr backend, claude, real treehouse lease) =="
"${FMENV[@]}" bash "$ROOT/bin/fm-spawn.sh" "$ID" "$TMP/project" --harness claude --backend herdr --mode local-only --yolo off 2>&1 | tail -5
META="$LAB/state/$ID.meta"
[ -f "$META" ] || { echo "spawn produced no meta"; exit 1; }
WT=$(sed -n 's/^worktree=//p' "$META" | head -1)
PANE=$(sed -n 's/^herdr_pane_id=//p' "$META")
STATE_JSON="$(dirname "$(dirname "$WT")")/treehouse-state.json"
log "worktree=$WT pane=$PANE"
log "meta lease fields after spawn:"; grep '^treehouse_lease_' "$META"
log "pool entry after spawn:"; jq -c --arg p "$WT" '.worktrees[] | select(.path==$p) | {leased,lease_id,lease_holder}' "$STATE_JSON"

agent_status() { lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent // "none"'; }
for _ in $(seq 1 60); do [ "$(agent_status)" = claude ] && break; sleep 1; done
agent_state() { lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // "none"'; }
for _ in $(seq 1 120); do [ "$(agent_state)" = idle ] && break; sleep 1; done
sleep 3
log "agent on pane before relaunch: $(agent_status) state=$(agent_state)"
log "fm-ps classification: $("${FMENV[@]}" bash -c '. "$1/bin/fm-control-lib.sh" 2>/dev/null; true' _ "$ROOT")"

log "== simulate a pre-PR53 Herdr record: strip treehouse_lease_* from the meta =="
grep -v '^treehouse_lease_' "$META" > "$META.x" && mv "$META.x" "$META"
if [ "$CASE" = adopt ]; then
  log "== pre-PR53 Herdr-native shape: pool lease (real lease_id) held by the task id =="
  jq --arg p "$WT" --arg id "$ID" '.worktrees |= map(if .path == $p then .lease_holder = $id else . end)' "$STATE_JSON" > "$STATE_JSON.x" && mv "$STATE_JSON.x" "$STATE_JSON"
fi
cp "$META" "$TMP/meta-before"
log "pool entry before relaunch:"; jq -c --arg p "$WT" '.worktrees[] | select(.path==$p) | {leased,lease_id,lease_holder}' "$STATE_JSON"

log "== real fm-control relaunch =="
"${FMENV[@]}" bash "$ROOT/bin/fm-control.sh" "$ID" relaunch --note "live lease check $CASE" 2>&1 | tail -8
rc=${PIPESTATUS[0]}
log "fm-control exit=$rc"
sleep 3
NEWPANE=$(sed -n 's/^herdr_pane_id=//p' "$META")
PANE=$NEWPANE
for _ in $(seq 1 30); do [ "$(agent_status)" = claude ] && break; sleep 1; done
for _ in $(seq 1 60); do [ "$(agent_state)" = idle ] && break; sleep 1; done
log "agent on pane after relaunch: $(agent_status) state=$(agent_state) (pane $PANE)"
log "meta lease fields after relaunch:"; grep '^treehouse_lease_' "$META" || echo "(none)"
log "meta unchanged vs before: $(cmp -s "$TMP/meta-before" "$META" && echo yes || echo no)"
log "relaunch checkpoint present: $( [ -e "$LAB/state/$ID.control-relaunch" ] && echo yes || echo no)"
log "pool entry after relaunch:"; jq -c --arg p "$WT" '.worktrees[] | select(.path==$p) | {leased,lease_id,lease_holder}' "$STATE_JSON"
log "pool entries total: $(jq '.worktrees|length' "$STATE_JSON")"
# stop the agent and release the pool copy so teardown leaves nothing
"${FMENV[@]}" bash "$ROOT/bin/fm-control.sh" "$ID" exit >/dev/null 2>&1 || true
