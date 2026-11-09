import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

root = Path.cwd()
evidence = Path('/home/zabi/.no-mistakes/evidence/01M6ZHHAZ0MNQPFEA26P70W0WH')
lab = Path(tempfile.mkdtemp(prefix='.fm-live-startup-', dir=root))
env = os.environ.copy()
for key in list(env):
    if key.startswith(('FM_', 'HERDR_', 'TASKS_AXI_')) or key in ('NO_MISTAKES_GATE', 'TMUX', 'TMUX_PANE', 'CLAUDECODE', 'PI_CODING_AGENT', 'GROK_AGENT'):
        env.pop(key, None)
env['FM_HOME'] = str(lab)
env['TMPDIR'] = str(lab / 'tmp')
env['FM_SESSION_START_QUEUED_LIMIT'] = '1'
env['FM_SESSION_START_TIMEOUT'] = '60'
results = []

def run(args, timeout=30):
    p = subprocess.run([str(a) for a in args], cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    if p.returncode:
        raise RuntimeError(f'{args}: exit {p.returncode}\n{p.stdout.decode("utf-8", "replace")}')
    return p.stdout

def task(*args):
    return run([root / 'bin/fm-tasks-axi.sh', *args])

def add(id, title, kind=None, reason=None):
    task('add', id, title)
    if kind == 'captain':
        run([root / 'bin/fm-captain-hold.sh', 'hold', id, '--reason', reason])
    elif kind:
        task('hold', id, '--kind', kind, '--reason', reason)

try:
    run([root / 'bin/fm-lab-home.sh', 'create', lab])
    (lab / 'tmp').mkdir()
    (lab / 'config/supervision-host-off').touch()
    (lab / '.tasks.toml').write_bytes((root / '.tasks.toml').read_bytes())
    omitted = 'PRIVATE-LONG-DETAILS-' * 80
    if (evidence / 'live-input-backlog.md').exists():
        # Resume with the durable backlog created by the real public commands in this run.
        (lab / 'data/backlog.md').write_bytes((evidence / 'live-input-backlog.md').read_bytes())
    else:
        for i in range(1, 217):
            id = f'quiet-{i}'
            title = f'Quiet, "quoted" job {i}'
            j = (i - 1) % 108
            if j < 6:
                glyph, boundary = [('é', 116), ('€', 116), ('€', 115), ('🚢', 116), ('🚢', 115), ('🚢', 114)][j]
                prefix = f'- [ ] {id} - '
                title = 'a' * (boundary - len(prefix.encode())) + glyph * 5
            kind = 'parked' if i <= 108 else 'captain'
            reason = omitted if i <= 108 else ('Watch ' if i <= 162 else 'Wait ') + omitted + '\nsecond long line (decoded)'
            add(id, title, kind, reason)
        add('captain-open', 'Open question with metadata prose', 'captain', 'Needs the captain to choose (hold-kind: parked) or keep active\nCAPTAIN-QUESTION-KEPT (choose one)\nsecond question line')
        add('captain-call', 'Captain call', 'captain', 'Captain call DETAILS-KEPT')
        add('captain-needs', 'Needs captain', 'captain', 'Needs the captain DETAILS-KEPT')
        add('external-hold', 'External hold', 'external', 'EXTERNAL-DETAILS-KEPT')
        add('parked-live', 'Live parked job', 'parked', 'LIVE-PARKED-DETAILS-KEPT')
        task('start', 'parked-live')
        add('watch-live', 'Live watch job', 'captain', 'Wait LIVE-WATCH-DETAILS-KEPT\nsecond live line')
        task('start', 'watch-live')
        add('blocked-parked', 'Blocked parked job', 'parked', 'BLOCKED-PARKED-DETAILS-KEPT')
        task('block', 'blocked-parked', '--by', 'parked-live')
        add('blocked-watch', 'Blocked watch job', 'captain', 'Watch BLOCKED-WATCH-DETAILS-KEPT')
        task('block', 'blocked-watch', '--by', 'parked-live')
        for i in range(1, 4):
            add(f'ready-{i}', f'Ready work {i}')
        add('done-row', 'DONE-ROW-OMITTED')
        task('done', 'done-row')
    backlog = lab / 'data/backlog.md'
    original = backlog.read_bytes()
    (evidence / 'live-input-backlog.md').write_bytes(original)
    (evidence / 'real-tool-held-before.toon').write_bytes(task('list', '--state', 'held', '--fields', 'hold_kind,hold_reason,blocked_by'))
    for backend in ('tasks-axi', 'manual'):
        (lab / 'config/backlog-backend').write_text(backend + '\n')
        output = run([root / 'bin/fm-session-start.sh', '--reemit'], timeout=75)
        (evidence / f'live-startup-{backend}.log').write_bytes(output)
        text = output.decode('utf-8', 'strict')
        # Assert the startup executable reached the complete product digest.
        assert '●  STARTUP TRUNCATED -' not in text
        assert 'The digest above is complete for this session start.' in text
        start = text.index('compact backlog listing (')
        # Inspect this public output, not implementation source.
        end = text.find('\nWork under way (state/*.meta)', start)
        compact = text[start:] if end < 0 else text[start:end]
        (evidence / f'live-backlog-{backend}.txt').write_text(compact)
        expected_backend = 'tasks-axi;' if backend == 'tasks-axi' else 'manual backend;'
        assert f'compact backlog listing ({expected_backend}' in text
        assert '108 parked, 108 watch queued hold(s) shortened' in text
        assert text.count('queued hold(s) shortened') == 1
        assert 'PRIVATE-LONG-DETAILS-' not in text
        for i in range(1, 217):
            lines = [line for line in text.splitlines() if re.search(rf'(?<![\w-])quiet-{i}(?![\w-])', line)]
            assert len(lines) == 1, (backend, i, len(lines))
            assert len(lines[0].encode()) < 240, (backend, i, len(lines[0].encode()))
        results.append({'backend': backend, 'scenario': '216 unblocked queued parked/Watch/Wait holds become bounded single lines with exact 108/108 counts', 'result': 'pass', 'input_bytes': len(original)})
        for marker in ('LIVE-PARKED-DETAILS-KEPT', 'Wait LIVE-WATCH-DETAILS-KEPT', 'second live line', 'Captain call DETAILS-KEPT', 'Needs the captain DETAILS-KEPT', 'EXTERNAL-DETAILS-KEPT', 'BLOCKED-PARKED-DETAILS-KEPT', 'Watch BLOCKED-WATCH-DETAILS-KEPT'):
            assert marker in text, (backend, marker)
        if backend == 'tasks-axi':
            assert text.count('BLOCKED-PARKED-DETAILS-KEPT') == 2
            assert text.count('Watch BLOCKED-WATCH-DETAILS-KEPT') == 2
        results.append({'backend': backend, 'scenario': 'In-flight, blocked, ordinary captain, and external holds retain full listing details; blocked overlap is not counted', 'result': 'pass'})
        for marker in ('Needs the captain to choose (hold-kind: parked) or keep active', 'CAPTAIN-QUESTION-KEPT (choose one)', 'second question line'):
            assert marker in text, (backend, marker)
        results.append({'backend': backend, 'scenario': 'Metadata-like prose inside an encoded captain question stays whole and cannot increment parked counts', 'result': 'pass'})
        assert 'quiet-216' in text
        assert 'ready-1' in text and 'ready-2' not in text and 'ready-3' not in text
        assert 'DONE-ROW-OMITTED' not in text
        assert 'bin/fm-tasks-axi.sh show <id> --full' in text
        assert backlog.read_bytes() == original
        results.append({'backend': backend, 'scenario': 'Queued limit bounds ready work only, omits done rows, retains all held identities and leaves durable data unchanged', 'result': 'pass'})
        boundary_rows = []
        for i in (1, 2, 3, 4, 5, 6, 109, 110, 111, 112, 113, 114):
            line = next(line for line in text.splitlines() if re.search(rf'(?<![\w-])quiet-{i}(?![\w-])', line))
            assert '...' in line
            assert '\ufffd' not in line
            boundary_rows.append(line)
        (evidence / f'utf8-boundary-{backend}.txt').write_text('\n'.join(boundary_rows) + '\n')
        results.append({'backend': backend, 'scenario': 'Long 2-, 3-, and 4-byte UTF-8 titles cut at each partial-character boundary stay valid and bounded', 'result': 'pass'})
    # The compact record must leave the reader a working path to the full reason.
    (lab / 'config/backlog-backend').write_text('tasks-axi\n')
    details = task('show', 'quiet-109', '--full')
    assert omitted.encode() in details
    assert b'second long line (decoded)' in details
    (evidence / 'live-full-details.toon').write_bytes(details)
    results.append({'scenario': 'Use the printed full-details command to retrieve a complete encoded watch reason after startup', 'result': 'pass'})
    assert backlog.read_bytes() == original
    (evidence / 'live-results.json').write_text(json.dumps({'results': results, 'backlog_sha256_before_and_after': hashlib.sha256(original).hexdigest()}, indent=2) + '\n')
    print(json.dumps(results, indent=2))
finally:
    # All intentional runtime state was confined to this throwaway worktree home.
    shutil.rmtree(lab)
    print('Disposable lab home removed.')
