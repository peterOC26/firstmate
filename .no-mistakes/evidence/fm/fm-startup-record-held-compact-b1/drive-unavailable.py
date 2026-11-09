import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
root = Path.cwd()
evidence = Path('/home/zabi/.no-mistakes/evidence/01M6ZHHAZ0MNQPFEA26P70W0WH')
lab = Path(tempfile.mkdtemp(prefix='.fm-live-unavailable-', dir=root))
env = os.environ.copy()
for key in list(env):
    if key.startswith(('FM_', 'HERDR_', 'TASKS_AXI_')) or key in ('NO_MISTAKES_GATE', 'TMUX', 'TMUX_PANE', 'CLAUDECODE', 'PI_CODING_AGENT', 'GROK_AGENT'):
        env.pop(key, None)
try:
    subprocess.run(['bin/fm-lab-home.sh', 'create', str(lab)], cwd=root, env=env, check=True, stdout=subprocess.PIPE)
    (lab / 'tmp').mkdir()
    env['TMPDIR'] = str(lab / 'tmp')
    (lab / 'config/supervision-host-off').touch()
    (lab / '.tasks.toml').write_bytes((root / '.tasks.toml').read_bytes())
    original = (evidence / 'live-input-backlog.md').read_bytes()
    (lab / 'data/backlog.md').write_bytes(original)
    command = r'''
lab=$1
. tests/lib.sh
masked=$(fm_test_base_path_sans /usr/bin:/bin:/usr/sbin:/sbin tasks-axi quota-axi)
PATH="$masked" command -v tasks-axi && exit 91
env -u FM_GATE_REFUSE_BYPASS -u FM_TEST_SEAM FM_HOME="$lab" PATH="$masked" FM_SESSION_START_QUEUED_LIMIT=1 bin/fm-session-start.sh --reemit
'''
    p = subprocess.run(['bash', '-c', command, '--', str(lab)], cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    (evidence / 'live-startup-unavailable.log').write_bytes(p.stdout)
    assert p.returncode == 0, p.stdout.decode('utf-8', 'replace')
    text = p.stdout.decode('utf-8', 'strict')
    assert 'tasks-axi unavailable or incompatible' in text
    assert '●  STARTUP TRUNCATED -' not in text
    assert 'The digest above is complete for this session start.' in text
    assert '108 parked, 108 watch queued hold(s) shortened' in text
    assert text.count('queued hold(s) shortened') == 1
    assert 'PRIVATE-LONG-DETAILS-' not in text
    assert 'Needs the captain to choose (hold-kind: parked) or keep active' in text
    for marker in ('LIVE-PARKED-DETAILS-KEPT', 'Wait LIVE-WATCH-DETAILS-KEPT', 'second live line', 'Captain call DETAILS-KEPT', 'Needs the captain DETAILS-KEPT', 'EXTERNAL-DETAILS-KEPT', 'BLOCKED-PARKED-DETAILS-KEPT', 'Watch BLOCKED-WATCH-DETAILS-KEPT'):
        assert marker in text, marker
    for i in range(1, 217):
        rows = [line for line in text.splitlines() if re.search(rf'(?<![\w-])quiet-{i}(?![\w-])', line)]
        assert len(rows) == 1 and len(rows[0].encode()) < 240, (i, rows)
    assert 'ready-1' in text and 'ready-2' not in text and 'ready-3' not in text
    assert 'DONE-ROW-OMITTED' not in text
    assert (lab / 'data/backlog.md').read_bytes() == original
    start = text.index('compact backlog listing (')
    (evidence / 'live-backlog-unavailable.txt').write_text(text[start:].split('\nWork under way (state/*.meta)', 1)[0])
    print(json.dumps({'scenario': 'Absent real tasks-axi uses compact fallback with exact counts, valid UTF-8, full protected holds, bounded ready rows, and unchanged backlog', 'result': 'pass', 'sha256_before_and_after': hashlib.sha256(original).hexdigest()}, indent=2))
finally:
    shutil.rmtree(lab)
    print('Disposable unavailable-tool lab home removed.')
