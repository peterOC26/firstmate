#!/bin/bash
set -eu
ROOT=$PWD
EVIDENCE=/home/zabi/.no-mistakes/evidence/01M691YBCJ6J85RWW6JJRBTYM0
BASE=$ROOT/.fm-herdr-live-validation
export FM_HERDR_LAB_STATE_DIR=$BASE/lab-records
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE HERDR_PANE_ID HERDR_WORKSPACE_ID TMUX
mkdir -p "$BASE/repo"
export FM_HOME=$BASE/home
bin/fm-lab-home.sh create "$FM_HOME"
SESSION=$(bin/fm-herdr-lab.sh name wrapped)
export HERDR_SESSION=$SESSION
PREPARED=0
cleanup() {
 if [ "$PREPARED" = 1 ]; then "$ROOT/bin/fm-herdr-lab.sh" teardown "$SESSION" || return 1; fi
 rm -rf "$BASE"
}
trap cleanup EXIT
# provision invokes the helper's prepare contract for a new lab.
bin/fm-herdr-lab.sh provision "$SESSION"
PREPARED=1
h() { "$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" "$@"; }
h status --json
h workspace create --cwd "$BASE/repo" --label wrapped-validation --no-focus > "$BASE/workspace.json"
PANE=$(jq -r .result.root_pane.pane_id "$BASE/workspace.json")
git -C "$BASE/repo" init -b main >/dev/null
git -C "$BASE/repo" -c user.name=Validation -c user.email=validation@example.invalid commit --allow-empty -m 'Disposable Herdr validation' >/dev/null
cat > "$BASE/clean-shell" <<'CLEAN'
#!/bin/bash
exec /bin/bash --noprofile --norc -c 'while IFS= read -r line; do eval "$line"; done'
CLEAN
chmod +x "$BASE/clean-shell"
COMMAND=$(printf 'env SHELL=%q TREEHOUSE_ROOT=%q /bin/bash --noprofile --norc -c %q' "$BASE/clean-shell" "$BASE/pool" 'treehouse get --no-fetch; read -r _')
h pane run "$PANE" "$COMMAND"
sleep 3
h pane process-info --pane "$PANE"
CMD=$(printf 'codex --no-daemon --dangerously-bypass-approvals-and-sandbox -c features.codex_hooks=false -c check_for_update_on_startup=false -c %q' "projects.\"$BASE/repo\".trust_level=\"trusted\"")
h pane send-text "$PANE" "$CMD"
h pane send-keys "$PANE" enter
sleep 5
h pane report-agent "$PANE" --source live-validation --agent codex --state idle
# Route the real adapter's calls through the same mandatory guarded helper.
REAL_PATH=$PATH
mkdir -p "$BASE/bin"
cat > "$BASE/bin/herdr" <<WRAP
#!/bin/bash
set -eu
args=("\$@")
for ((i=0;i<\${#args[@]};i++)); do
 if [ "\${args[i]}" = --session ]; then
   [ "\${args[i+1]}" = "$SESSION" ] || exit 97
   args=("\${args[@]:0:i}" "\${args[@]:i+2}")
   break
 fi
done
PATH='$REAL_PATH' exec '$ROOT/bin/fm-herdr-lab.sh' run '$SESSION' "\${args[@]}"
WRAP
chmod +x "$BASE/bin/herdr"
export PATH=$BASE/bin:$PATH
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr
printf '\nHerdr wrapped Codex running: %s\n' "$(fm_backend_agent_state herdr "$SESSION:$PANE")"
h pane process-info --pane "$PANE"
# Quit whichever native startup/prompt screen is currently rendered.
h pane send-keys "$PANE" escape
sleep 1
h pane send-text "$PANE" /quit
sleep 1.3
h pane send-keys "$PANE" enter
sleep 3
printf '\nHerdr after Codex exit, with registry retained: %s\n' "$(fm_backend_agent_state herdr "$SESSION:$PANE")"
h agent get "$PANE"
h pane process-info --pane "$PANE"
[ "$(fm_backend_agent_state herdr "$SESSION:$PANE")" = dead ]
printf '\nHerdr non-agent foreground must refuse recovery:\n'
h pane send-text "$PANE" 'sleep 300'
h pane send-keys "$PANE" enter
sleep 1
h pane process-info --pane "$PANE"
printf 'state=%s\n' "$(fm_backend_agent_state herdr "$SESSION:$PANE")"
[ "$(fm_backend_agent_state herdr "$SESSION:$PANE")" = alive ]
printf '\nLab teardown will check default-session tripwire.\n'
# Restore real PATH for helper calls; the wrapper itself is a routing adapter.
PATH=$REAL_PATH
export PATH
