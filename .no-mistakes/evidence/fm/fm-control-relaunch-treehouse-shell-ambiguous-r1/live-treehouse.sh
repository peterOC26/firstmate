#!/usr/bin/env bash
set -eu
ROOT=$PWD
EVIDENCE=/home/zabi/.no-mistakes/evidence/01M691YBCJ6J85RWW6JJRBTYM0
BASE=$ROOT/.fm-live-validation
LAB=$BASE/home
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE HERDR_SESSION HERDR_PANE_ID FM_TASK_ID
export FM_HOME=$LAB TREEHOUSE_ROOT=$BASE/pool
mkdir -p "$BASE/repo"
git -C "$BASE/repo" init -b main
git -C "$BASE/repo" -c user.name=Validation -c user.email=validation@example.invalid commit --allow-empty -m "Disposable validation repository"
bin/fm-lab-home.sh create "$LAB"
SOCKET_DIR=$(bin/fm-lab-home.sh tmux-dir "$LAB")
export TMUX_TMPDIR=$SOCKET_DIR
cleanup() {
  tmux -L fm-lab kill-server 2>/dev/null || true
  bin/fm-lab-home.sh teardown "$LAB" || true
  chmod -R u+w "$BASE"
  rm -rf "$BASE"
}
trap cleanup EXIT
printf 'manual\n' > "$LAB/config/backlog-backend"
printf 'tmux\n' > "$LAB/config/backend"
touch "$LAB/config/supervision-host-off"
cat > "$BASE/clean-shell" <<'CLEAN'
#!/bin/bash
pwd > "$FM_HOME/worktree-path"
kill -USR1 "$OUTER_PID"
exec /bin/bash --noprofile --norc -c 'while IFS= read -r line; do eval "$line"; done' 
CLEAN
chmod +x "$BASE/clean-shell"
export SHELL=$BASE/clean-shell
# The real Treehouse pool and repository both live within the gate worktree.
cat > "$BASE/repo/treehouse.toml" <<CFG
max_trees = 1
root = "$BASE/pool"
CFG
printf 'tmux=%s codex=%s treehouse=%s\n' "$(tmux -V)" "$(codex --version)" "$(treehouse --version)"
tmux -L fm-lab new-session -d -x 120 -y 40 -s lab -n fm-wrapped -c "$BASE/repo" -- /bin/bash --noprofile --norc -c 'trap '\''cd -- "$(cat "$FM_HOME/worktree-path")"'\'' USR1; export OUTER_PID=$BASHPID; treehouse get --no-fetch < /dev/tty & child=$!; while kill -0 "$child" 2>/dev/null; do wait "$child" || :; done; read -r _'
export TMUX=$(tmux -L fm-lab display-message -p -t lab:fm-wrapped '#{socket_path},#{pid},0')
. bin/fm-backend.sh
fm_backend_source tmux
for i in $(seq 1 60); do
 WT=$(cat "$LAB/worktree-path" 2>/dev/null || true)
 case "$WT" in "$BASE/pool/"*) break;; esac
 sleep .2
done
printf '\nReal Treehouse acquired: %s\n' "$WT"
tmux -L fm-lab capture-pane -p -t lab:fm-wrapped
case "$WT" in "$BASE/pool/"*) ;; *) echo 'SETUP FAILED: no isolated pool worktree'; exit 2;; esac
cat > "$LAB/state/wrapped.meta" <<META
window=lab:fm-wrapped
worktree=$WT
project=$BASE/repo
harness=codex
kind=scout
backend=tmux
META
printf 'preserve this uncommitted work\n' > "$WT/uncommitted.txt"
bin/fm-brief.sh wrapped repo --scout >/dev/null
python3 - "$LAB/data/wrapped/brief.md" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); t=p.read_text(); t=t.replace('{TASK}', 'This is a disposable runtime validation. Reply READY and wait. Do not run tools, edit files, or start validation.').replace('{FIRSTMATE_SPEC}', 'Wait for lifecycle commands.'); p.write_text(t)
PY
# Isolate all Codex writes. Reuse a private COPY of the existing machine login;
# the production credential store and user configuration are never changed.
export CODEX_HOME="$BASE/codex-home"
mkdir -m 700 "$CODEX_HOME"
python3 - "$CODEX_HOME" "$BASE/repo" "$WT" <<'PYCFG'
import json, os, shutil, sys
from pathlib import Path
home=Path(sys.argv[1]); auth=Path.home()/'.codex'/'auth.json'
if auth.is_file():
 shutil.copyfile(auth, home/'auth.json'); os.chmod(home/'auth.json', 0o600)
t='check_for_update_on_startup = false\n'
for project in sys.argv[2:]: t+='[projects.'+json.dumps(project)+']\ntrust_level = "trusted"\n'
(home/'config.toml').write_text(t)
PYCFG
# tmux's server inherited its original environment; set the worker's local home.
tmux -L fm-lab send-keys -t lab:fm-wrapped -l -- "export CODEX_HOME='$CODEX_HOME'"
tmux -L fm-lab send-keys -t lab:fm-wrapped Enter
sleep .3

tmux -L fm-lab send-keys -t lab:fm-wrapped -l -- 'codex --dangerously-bypass-approvals-and-sandbox -c features.codex_hooks=false -c check_for_update_on_startup=false'
tmux -L fm-lab send-keys -t lab:fm-wrapped Enter
sleep 5
printf '\nLIVE CODEX: state=%s\n' "$(fm_backend_agent_state tmux lab:fm-wrapped)"
tmux -L fm-lab capture-pane -p -t lab:fm-wrapped > "$EVIDENCE/codex-live-pane.txt"
cat "$EVIDENCE/codex-live-pane.txt"
printf '\nForeground names:\n'
fm_backend_tmux_foreground_comms lab:fm-wrapped
TTY=$(tmux -L fm-lab display-message -p -t lab:fm-wrapped '#{pane_tty}')
ps -t "${TTY#/dev/}" -o pid,ppid,pgid,tpgid,comm,args
[ "$(fm_backend_agent_state tmux lab:fm-wrapped)" = alive ] || { echo 'SETUP FAILED: Codex did not start'; exit 2; }
printf '\nDuplicate relaunch guard:\n' 
if bin/fm-spawn.sh wrapped --relaunch; then echo 'FAIL: allowed duplicate'; exit 3; fi
printf '\nControl exit:\n'
bin/fm-control.sh wrapped exit
printf '\nAFTER EXIT: state=%s\n' "$(fm_backend_agent_state tmux lab:fm-wrapped)"
fm_backend_tmux_foreground_comms lab:fm-wrapped
ps -t "${TTY#/dev/}" -o pid,ppid,pgid,tpgid,comm,args
tmux -L fm-lab capture-pane -p -t lab:fm-wrapped > "$EVIDENCE/codex-exited-pane.txt"
printf '\nControl exit repeated (must be already-stopped):\n'
bin/fm-control.sh wrapped exit
printf '\nCounterfactual: pre-fix classifier on the SAME live process tree:\n'
mkdir -p "$BASE/base-bin"
for lib in "$ROOT"/bin/*.sh; do ln -s "$lib" "$BASE/base-bin/$(basename "$lib")"; done
rm "$BASE/base-bin/fm-agent-process-lib.sh"
git show 658559719a56fdde9a069023d4b70415f5304289:bin/fm-agent-process-lib.sh > "$BASE/base-bin/fm-agent-process-lib.sh"
( . "$BASE/base-bin/fm-agent-process-lib.sh"; printf 'pre-fix state=%s\n' "$(fm_backend_agent_state tmux lab:fm-wrapped)" )
printf '\nAdversarial unrelated foreground tool:\n'
tmux -L fm-lab send-keys -t lab:fm-wrapped -l -- "sleep 300 & echo \$! > '$BASE/adversary.pid'; wait"
tmux -L fm-lab send-keys -t lab:fm-wrapped Enter
sleep .5
printf 'unrelated tool state=%s\n' "$(fm_backend_agent_state tmux lab:fm-wrapped)"
[ "$(fm_backend_agent_state tmux lab:fm-wrapped)" = ambiguous ]
if bin/fm-spawn.sh wrapped --relaunch; then echo 'FAIL: replaced unknown foreground tool'; exit 3; fi
if bin/fm-control.sh wrapped relaunch --note 'Do not modify files'; then echo 'FAIL: controlled unknown foreground tool'; exit 3; fi
kill "$(cat "$BASE/adversary.pid")"
sleep .5
[ "$(fm_backend_agent_state tmux lab:fm-wrapped)" = dead ]
printf '\nClaim the isolated legacy pool slot for relaunch:\n' 
. bin/fm-wake-lib.sh
fm_treehouse_slot_owner_claim "$WT" wrapped "$LAB"
printf '\nControl relaunch:\n' 
bin/fm-control.sh wrapped relaunch --note 'Runtime validation only: reply READY and wait; do not run tools or modify files.'
printf '\nAFTER RELAUNCH: state=%s\n' "$(fm_backend_agent_state tmux lab:fm-wrapped)"
sleep 3
tmux -L fm-lab capture-pane -p -t lab:fm-wrapped

[ "$(fm_backend_agent_state tmux lab:fm-wrapped)" = alive ]
sleep 8
printf '\nExit first replacement:\n'
bin/fm-control.sh wrapped exit
[ "$(fm_backend_agent_state tmux lab:fm-wrapped)" = dead ]
printf '\nSecond control relaunch after replacement exited:\n'
bin/fm-control.sh wrapped relaunch --note 'Runtime validation only: reply READY and wait; do not run tools or modify files.'
[ "$(fm_backend_agent_state tmux lab:fm-wrapped)" = alive ]
sleep 8
bin/fm-control.sh wrapped exit
[ "$(fm_backend_agent_state tmux lab:fm-wrapped)" = dead ]
printf '\nDirect spawn --relaunch after second replacement exited:\n'
bin/fm-spawn.sh wrapped --relaunch
sleep 5
[ "$(fm_backend_agent_state tmux lab:fm-wrapped)" = alive ]
printf '\nPreserved local changes and exact endpoint:\n'
cat "$WT/uncommitted.txt"
[ "$(cat "$WT/uncommitted.txt")" = 'preserve this uncommitted work' ]
cat "$LAB/state/wrapped.meta"
sleep 4
bin/fm-control.sh wrapped exit
[ "$(fm_backend_agent_state tmux lab:fm-wrapped)" = dead ]
printf '\nCrew current-state read after exit:\n'
FM_CREW_STATE_NO_FORGE=1 bin/fm-crew-state.sh wrapped
printf '\nReal watcher repeated cycles over unchanged dead wrapper:\n'
python3 - "$ROOT" "$LAB" <<'PYWATCH'
import os, re, subprocess, sys, time
from pathlib import Path
root,lab=map(Path,sys.argv[1:]);state=lab/'state'
env=dict(os.environ,FM_POLL='1',FM_STALE_ESCALATE_SECS='1',FM_HEARTBEAT='3600',FM_CHECK_INTERVAL='3600',FM_HOME_SUMMARY_INTERVAL='3600',FM_SIGNAL_GRACE='0')
for f in ['.last-check','.last-heartbeat','.last-home-summary']:(state/f).touch()
marker=state/'.dead-reported-lab_fm-wrapped'
for i in range(5):
 try:
  p=subprocess.run([str(root/'bin/fm-watch.sh')],env=env,capture_output=True,text=True,timeout=7)
  out=p.stdout+p.stderr
 except subprocess.TimeoutExpired as e:
  out=(e.stdout or b'').decode()+(e.stderr or b'').decode()
  print('Watcher remained running for bounded observation.',flush=True)
 print('cycle',i+1,out,flush=True)
 q=subprocess.run([str(root/'bin/fm-wake-drain.sh')],env=env,capture_output=True,text=True,timeout=10)
 print(q.stdout+q.stderr,flush=True)
 ack=re.search(r'--ack-through ([0-9]+) --recovery-generation ([A-Za-z0-9._-]+)',q.stdout+q.stderr)
 if ack:
  a=subprocess.run([str(root/'bin/fm-wake-drain.sh'),'--ack-through',ack[1],'--recovery-generation',ack[2]],env=env,capture_output=True,text=True,timeout=10)
  print(a.stdout+a.stderr,flush=True)
  assert a.returncode==0
 if marker.exists() and i>=3:break
 time.sleep(1.2)
print('dead-report marker:', marker.read_text() if marker.exists() else 'ABSENT',flush=True)
log=state/'.watch-triage.log'
if log.exists(): print('Triage log:\n'+log.read_text(),flush=True)
assert marker.exists(), 'watcher never classified wrapped exit as dead'
PYWATCH
printf '\nAll live tmux checks completed.\n'
