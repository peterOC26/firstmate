#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=/home/zabi/.no-mistakes/evidence/01M692VAWS4BNY1S3C7BH8G545
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
MATE=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
cleanup() {
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true
  python3 - "$LAB" "$MATE" <<'CLEAN'
import glob, os, shutil, stat, sys
paths = sys.argv[1:] + glob.glob('/tmp/fm-codex-tier-worker*') + glob.glob('/tmp/fm-codex-tier-mate*')
for path in paths:
    if os.path.isdir(path) and not os.path.islink(path):
        for root, dirs, files in os.walk(path):
            os.chmod(root, os.stat(root).st_mode | stat.S_IWUSR | stat.S_IXUSR)
        shutil.rmtree(path)
print('Private terminal stopped; disposable labs and task launch files removed.')
CLEAN
}
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB"
bin/fm-lab-home.sh create "$MATE"
mkdir -p "$LAB/tmux" "$LAB/projects/probe" "$MATE/bin"
printf 'codex\n' > "$LAB/config/crew-harness"
touch "$LAB/state/.last-watcher-beat"
printf '# Launch validation fixture\nDo not use tools or change files.\n' > "$MATE/AGENTS.md"
printf 'codex-tier-mate\n' > "$MATE/.fm-secondmate-home"
printf 'Launch validation only. Reply LAB_CODEX_MATE_READY and wait. Do not use tools or change files or start supervision.\n' > "$MATE/data/charter.md"
printf 'state/\ndata/\nconfig/\nprojects/\n.fm-lab-home\n.fm-secondmate-home\n' > "$MATE/.gitignore"
git -C "$MATE" init -q -b main
git -C "$MATE" add AGENTS.md .gitignore
git -C "$MATE" -c user.name=Lab -c user.email=lab@example.invalid commit -qm fixture
PROJ="$LAB/projects/probe"
git -C "$PROJ" init -q -b main
printf 'Codex launch verification fixture.\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=Lab -c user.email=lab@example.invalid commit -qm fixture
git clone -q --bare "$PROJ" "$LAB/origin.git"
git -C "$PROJ" remote add origin "$LAB/origin.git"
git -C "$PROJ" fetch -q origin
git -C "$PROJ" remote set-head origin main
mkdir -p "$LAB/data/codex-tier-worker"
cat > "$LAB/data/codex-tier-worker/brief.md" <<'BRIEF'
# Task
## Captain's intent
This is a launch verification only. Reply LAB_CODEX_WORKER_READY and wait. Do not call tools, edit files, invoke validation, publish anything, or launch other agents.

## Firstmate spec
Observe the launch-only instruction above. No implementation work is assigned.
BRIEF
mkdir -p "$LAB/data/codex-tier-worker2"
cp "$LAB/data/codex-tier-worker/brief.md" "$LAB/data/codex-tier-worker2/brief.md"
cat > "$LAB/drive.sh" <<'DRIVE'
#!/usr/bin/env bash
set -u
cd "$PROOF_ROOT"
export TREEHOUSE_ROOT="$FM_HOME/pool"
bin/fm-spawn.sh "codex-tier-worker=$FM_HOME/projects/probe" "codex-tier-worker2=$FM_HOME/projects/probe" --harness codex --mode local-only --yolo off > "$FM_HOME/worker-spawn.log" 2>&1
printf '%s\n' "$?" > "$FM_HOME/worker.exit"
bin/fm-spawn.sh codex-tier-mate "$PROOF_MATE" --secondmate --harness codex > "$FM_HOME/mate-spawn.log" 2>&1
printf '%s\n' "$?" > "$FM_HOME/mate.exit"
touch "$FM_HOME/drive.done"
exec bash --noprofile --norc
DRIVE
# The real terminal has a nonzero grid before Codex starts. All subprocesses
# inherit TMUX from this private socket, so bare tmux calls stay inside the lab.
env -i HOME="$HOME" USER="${USER:-zabi}" LOGNAME="${USER:-zabi}" PATH="$PATH" SHELL=/bin/bash TERM=xterm-256color LANG=C.UTF-8 \
  TMUX_TMPDIR="$LAB/tmux" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  CODEX_HOME="${CODEX_HOME:-$HOME/.codex}" \
  tmux -f /dev/null -L fm-lab new-session -d -s primary -x 140 -y 45 -c "$ROOT" \
  -e FM_HOME="$LAB" -e PROOF_ROOT="$ROOT" -e PROOF_MATE="$MATE" "bash '$LAB/drive.sh'"
for _ in $(seq 1 100); do
  [ ! -f "$LAB/drive.done" ] || break
  sleep 1
done
for type in worker mate; do
  cat "$LAB/$type-spawn.log" | tee "$EVIDENCE/live-$type-spawn.log"
  [ ! -f "$LAB/$type.exit" ] || printf '%s exit=%s\n' "$type" "$(cat "$LAB/$type.exit")"
done
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab list-panes -a -F '#{window_name} pane=#{pane_id} pid=#{pane_pid} grid=#{pane_width}x#{pane_height} cwd=#{pane_current_path}' | tee "$EVIDENCE/live-terminal-inventory.txt"
sleep 5
for type in worker worker2 mate; do
  meta="$LAB/state/codex-tier-$type.meta"
  [ -f "$meta" ] || continue
  cp "$meta" "$EVIDENCE/live-$type.meta"
  target=$(sed -n 's/^window=//p' "$meta")
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -t "$target" -S -150 > "$EVIDENCE/live-$type-pane.txt"
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -ep -t "$target" > "$EVIDENCE/live-$type-pane.ansi"
done
LAB_PATH="$LAB" MATE_PATH="$MATE" python3 - <<'PY' > "$EVIDENCE/live-process-argv.json"
import json, os
labs = [os.environ['LAB_PATH'].encode(), os.environ['MATE_PATH'].encode()]
found = []
# Enumerate the process table, retaining only processes containing this lab's
# exact path and Codex's executable name; no host filesystem search is used.
import subprocess
pids = subprocess.check_output(['ps', '-eo', 'pid='], text=True).split()
for pid in pids:
    try:
        data = open('/proc/' + pid + '/cmdline', 'rb').read()
        args = [s.decode(errors='replace') for s in data.split(b'\0') if s]
        if args and ('codex' in os.path.basename(args[0]) or (len(args)>1 and 'codex' in args[1])) and any(os.readlink('/proc/' + pid + '/cwd').encode().startswith(lab) for lab in labs):
            found.append({'pid': int(pid), 'argv': args})
    except (OSError, PermissionError):
        pass
print(json.dumps(found, indent=2))
PY
cat "$EVIDENCE/live-process-argv.json"

CODEX_HOME="$LAB/tier-config" python3 "$EVIDENCE/live-config-probe.py" "$EVIDENCE/live-process-argv.json" > "$EVIDENCE/live-effective-config.json"
cat "$EVIDENCE/live-effective-config.json"

python3 - "$EVIDENCE" <<'META'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
records = {}
for kind in ('worker', 'worker2', 'mate'):
    path = root / ('live-' + kind + '.meta')
    record = dict(line.split('=', 1) for line in path.read_text().splitlines())
    assert record['harness'] == 'codex', record
    assert 'service_tier' not in record, record
    records[kind] = {'harness': record['harness'], 'kind': record['kind'], 'service_tier_metadata_present': False}
(root / 'live-metadata-check.json').write_text(json.dumps(records, indent=2) + '\n')
print(json.dumps(records, indent=2))
META
