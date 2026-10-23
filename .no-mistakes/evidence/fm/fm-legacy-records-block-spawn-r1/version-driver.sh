#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EV=/home/zabi/.no-mistakes/evidence/01M5MJPW8RN2VW0AFEACSQK5GC
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM FM_TASK_ID TMUX HERDR_ENV HERDR_SESSION
export TREEHOUSE_ROOT="$ROOT/.l/pool" TMPDIR="$ROOT/.l" TMUX_TMPDIR="$ROOT/.l" FM_HOME="$ROOT/.l/v"
cleanup() {
  tmux -L fm-lab kill-server 2>/dev/null || true
  python3 - "$ROOT/.l" <<'PYCLEAN'
from pathlib import Path
import shutil,sys
p=Path(sys.argv[1]); assert p.name=='.l' and p.parent==Path.cwd()
for d in p.rglob('*'):
    if d.is_dir() and not d.is_symlink(): d.chmod(d.stat().st_mode | 0o700)
shutil.rmtree(p)
PYCLEAN
}
trap cleanup EXIT
bash "$ROOT/bin/fm-lab-home.sh" create "$FM_HOME"
S1=$(jq -r .path "$ROOT/.l/allocation-1.json")
PROJECT="$ROOT/.l/project"
STATE="$(dirname "$(dirname "$S1")")/treehouse-state.json"
git -C "$S1" checkout -qb fm/legacy-guard
printf 'unfinished work\n' > "$S1/sentinel"
printf 'project=%s\nworktree=%s\nkind=ship\n' "$PROJECT" "$S1" > "$FM_HOME/state/legacy.meta"
printf 'task=legacy\nhome=%s\n' "$FM_HOME" > "$(dirname "$S1")/.fm-slot-owner"
bash "$ROOT/bin/fm-brief.sh" candidate project --scout >/dev/null
python3 - "$FM_HOME/data/candidate/brief.md" <<'PYBRIEF'
from pathlib import Path
import sys
p=Path(sys.argv[1]); p.write_text(p.read_text().replace('{TASK}','Exercise the unverified version refusal.').replace('{FIRSTMATE_SPEC}','Allocate nothing.'))
PYBRIEF
cp "$STATE" "$ROOT/.l/before.json"
cp "$FM_HOME/state/legacy.meta" "$ROOT/.l/before.meta"
BEFORE=$(git -C "$S1" symbolic-ref HEAD)
tmux -L fm-lab new-session -d -s primary -x 120 -y 40 -c "$ROOT"
export TMUX="$(tmux -L fm-lab display-message -p '#{socket_path},#{pid}'),0"
export PATH="$ROOT/.version-lab:$PATH"
printf 'REAL_UNVERIFIED_TREEHOUSE=%s\n' "$(treehouse --version)"
if bash "$ROOT/bin/fm-spawn.sh" candidate "$PROJECT" --scout --backend tmux "bash -c 'echo SHOULD_NOT_START; sleep 600'" > "$EV/unverified-refusal.txt" 2>&1; then
  echo 'FAIL unverified version admitted'; exit 1
fi
cat "$EV/unverified-refusal.txt"
grep -q "Treehouse version 'v3.1.5' is not verified" "$EV/unverified-refusal.txt"
cmp "$STATE" "$ROOT/.l/before.json"
cmp "$FM_HOME/state/legacy.meta" "$ROOT/.l/before.meta"
[ "$(git -C "$S1" symbolic-ref HEAD)" = "$BEFORE" ]
[ "$(cat "$S1/sentinel")" = 'unfinished work' ]
[ ! -e "$FM_HOME/state/candidate.treehouse-acquire" ]
[ ! -e "$FM_HOME/state/candidate.meta" ]
[ "$(tmux -L fm-lab list-windows -t primary -F '#{window_id}' | wc -l)" -eq 1 ]
printf 'VERSION_REFUSAL pool_state_records_branch_dirty_bytes=unchanged acquisition_journal=absent worker_endpoint=absent\n'
