#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=/home/zabi/.no-mistakes/evidence/01M69FH37Q1230T52YRHMGY8AD
SCRATCH=$(mktemp -d "$ROOT/.tier-live.XXXXXX")
LAB="$SCRATCH/home"
SOCKET_DIR=
cleanup() {
  if [ -n "$SOCKET_DIR" ]; then
    TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab kill-server 2>/dev/null || true
    bash "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" || true
  fi
  chmod -R u+w "$SCRATCH"
  rm -rf "$SCRATCH"
}
trap cleanup EXIT
bash bin/fm-lab-home.sh create "$LAB"
SOCKET_DIR=$(bash bin/fm-lab-home.sh tmux-dir "$LAB")
export TMUX_TMPDIR="$SOCKET_DIR"
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME="$LAB" TREEHOUSE_ROOT="$SCRATCH/pool"
printf 'codex\n' > "$LAB/config/crew-harness"
touch "$LAB/state/.last-watcher-beat"
PROJECT="$SCRATCH/project"
mkdir -p "$PROJECT"
git -C "$PROJECT" init -q -b main
printf '# Disposable tier probe\n' > "$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" -c user.name='Tier lab' -c user.email='tier-lab@example.invalid' commit -qm 'Create disposable tier fixture'
for id in tier-batch-a tier-batch-b tier-scout; do
  mkdir -p "$LAB/data/$id"
  cat > "$LAB/data/$id/brief.md" <<'BRIEF'
# Task
## Captain's intent
Verify a regular-service Codex worker can start.

## Firstmate spec
This is an isolated launch probe. Do not run any tools or modify any files. Reply exactly TIER_LAB_OK and wait. Do not start validation, open a PR, or push.
BRIEF
done
env -u NO_MISTAKES_GATE tmux -L fm-lab new-session -d -s lab-host -x 120 -y 40 -c "$ROOT" 'bash --noprofile --norc'
export TMUX=$(tmux -L fm-lab display-message -p -t lab-host '#{socket_path},#{pid},0')
timeout 70 bash bin/fm-spawn.sh "tier-batch-a=$PROJECT" "tier-batch-b=$PROJECT" --mode local-only --yolo off --harness codex --backend tmux > "$EVIDENCE/live-tmux-spawn.log" 2>&1
timeout 45 bash bin/fm-spawn.sh tier-scout "$PROJECT" --scout --harness codex --backend tmux >> "$EVIDENCE/live-tmux-spawn.log" 2>&1
sleep 2
python3 - "$LAB" "$EVIDENCE" <<'PY'
import json, os, subprocess, sys
lab, evidence = sys.argv[1:]
rows=[]
for name in ('tier-batch-a', 'tier-batch-b', 'tier-scout'):
    meta=dict(line.rstrip('\n').split('=',1) for line in open(f'{lab}/state/{name}.meta') if '=' in line)
    target=meta['window']
    pane=subprocess.check_output(['tmux','-L','fm-lab','capture-pane','-p','-t',target,'-S','-100'],text=True)
    open(f'{evidence}/{name}-pane.txt','w').write(pane)
    table=subprocess.check_output(['ps','-eo','pid=,ppid=,args='],text=True)
    candidates=[]
    for line in table.splitlines():
        parts=line.strip().split(None,2)
        if len(parts)<3 or 'service_tier="default"' not in parts[2] or 'codex' not in parts[2]: continue
        try:
            cwd=os.readlink(f'/proc/{parts[0]}/cwd')
        except OSError: continue
        if cwd==meta['worktree']:
            candidates.append({'pid':int(parts[0]),'argv':open(f'/proc/{parts[0]}/cmdline','rb').read().decode().split('\0')[:-1], 'cwd':cwd})
    candidates=[p for p in candidates if 'service_tier="default"' in p['argv']]
    assert candidates, f'{name}: no running Codex with the regular service-tier pin'
    assert 'service_tier' not in meta, 'fixed tier leaked into task metadata'
    rows.append({'task':name,'harness':meta['harness'],'backend':meta.get('backend','tmux'),'window':target,'grid':subprocess.check_output(['tmux','-L','fm-lab','display-message','-p','-t',target,'#{pane_width}x#{pane_height}'],text=True).strip(),'processes':candidates,'saved_service_tier':None})
json.dump(rows,open(f'{evidence}/live-tmux-processes.json','w'),indent=2)
print('Both real batch workers and the scout started with service_tier="default"; no configurable tier persisted.')
PY
