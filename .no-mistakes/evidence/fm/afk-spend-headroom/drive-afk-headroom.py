import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path.cwd()
EVIDENCE = Path('/home/zabi/.no-mistakes/evidence/01M77F5H0HXT2FQP6RKSWDKNFJ')
CLI = ROOT / 'bin/fm-afk-contract.sh'
BASE = 'afc5b7607319aeac55bc00c07c39c989584b9659'
ENV = dict(os.environ)
for key in list(ENV):
    if key.startswith('FM_') or key.startswith('HERDR_') or key in ('NO_MISTAKES_GATE', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND'):
        ENV.pop(key)
work = Path(tempfile.mkdtemp(prefix='.afk-headroom-live-', dir=ROOT))
base_file = None
transcript = []
results = []

def log(message):
    transcript.append(message)

def home(name, count=0, secondmates=0):
    path = work / name
    subprocess.run(['bash', str(ROOT / 'bin/fm-lab-home.sh'), 'create', str(path)], env=ENV, check=True, capture_output=True, text=True)
    for i in range(count):
        kind = 'ship' if i % 2 == 0 else 'scout'
        (path / 'state' / f'task-{i}.meta').write_text(f'window=retained-worker-{i}\nkind={kind}\n')
    for i in range(secondmates):
        (path / 'state' / f'mate-{i}.meta').write_text(f'window=remote:mate-{i}\nkind=secondmate\n')
    log(f'\nSETUP {name}: marked disposable home; {count} retained ordinary worker records (ships/scouts), {secondmates} secondmate records; no worker endpoints launched.')
    return path

def run(path, *args, cli=CLI, quiet=False, expected=0):
    env = {**ENV, 'FM_HOME': str(path)}
    if quiet:
        env['FM_AFK_MODE'] = 'quiet'
    command = ['bash', str(cli), *args]
    proc = subprocess.run(command, cwd=ROOT, env=env, text=True, capture_output=True, timeout=30)
    log(f"$ FM_HOME=<lab:{path.name}> {'FM_AFK_MODE=quiet ' if quiet else ''}bash {cli.relative_to(ROOT)} {' '.join(args)}\n{proc.stdout}{proc.stderr}[exit {proc.returncode}]")
    assert proc.returncode == expected, (args, proc.stdout, proc.stderr)
    return proc.stdout + proc.stderr

def cap(path, value, cli=CLI):
    assert run(path, 'field', 'spend_max_concurrent_workers', cli=cli).strip() == str(value)
    run(path, 'validate', cli=cli)
    log('PERSISTED PUBLIC RECORD:\n' + (path / 'state/.afk-contract').read_text())

def room(output, number, warning=False):
    assert f'new workers that can start: {number}' in output, output
    assert ('warning: no new worker can start while away;' in output) == warning, output
    if warning:
        assert 'send /afk again with new words and --spend to raise the limit.' in output

def passed(name):
    results.append({'name': name, 'result': 'pass', 'live': True})
    log('SCENARIO PASS: ' + name)

try:
    # Execute the previous revision, rather than infer its behavior from source text.
    fd, name = tempfile.mkstemp(prefix='.afk-before-live-', suffix='.sh', dir=ROOT / 'bin')
    os.close(fd)
    base_file = Path(name)
    base_file.write_bytes(subprocess.check_output(['git', 'show', f'{BASE}:bin/fm-afk-contract.sh']))
    before = home('baseline-six', 6, 1)
    run(before, 'enter', '--words', 'Continue the queued overnight work.', cli=base_file)
    cap(before, 6, cli=base_file)
    assert run(before, 'live-workers', cli=base_file).strip() == '6'
    log('BASELINE REPRODUCED: saved cap 6 equals 6 retained ordinary records; no headroom.')

    empty = home('empty')
    out = run(empty, 'enter', '--words', 'Continue the queued overnight work.')
    cap(empty, 5)
    room(out, 5)
    passed('Empty-home away entry records cap 5 and announces five new workers')

    for count, expected_cap in ((3, 8), (6, 11), (15, 20)):
        populated = home(f'ordinary-{count}', count, 2)
        assert run(populated, 'live-workers').strip() == str(count)
        out = run(populated, 'enter', '--words', 'Continue the queued overnight work.')
        cap(populated, expected_cap)
        room(out, 5)
    passed('Away entry with 3, 6, or 15 retained workers adds five slots and excludes secondmates')

    explicit = home('explicit', 6, 1)
    out = run(explicit, 'enter', '--words', 'Keep the current cap.', '--spend', '6')
    cap(explicit, 6)
    room(out, 0, warning=True)
    passed('Explicit limit equal to six workers stays six and warns with a remedy')

    out = run(explicit, 'enter', '--words', 'Constrain the overnight work.', '--spend', '2')
    cap(explicit, 2)
    room(out, 0, warning=True)
    assert '0 (4 over the cap)' in out
    passed('Explicit limit below worker count stays two and shows zero room plus overage')

    out = run(explicit, 'enter', '--spend', '10')
    cap(explicit, 2)
    assert 'new workers that can start' not in out
    assert 'enter new words to replace the mandate' in out
    out = run(explicit, 'readback')
    assert 'new workers that can start' not in out
    assert 'warning: no new worker' not in out
    out = run(explicit, 'enter', '--words', 'Continue with more room.', '--spend', '10')
    cap(explicit, 10)
    room(out, 4)
    passed('Refresh preserves the cap; following the warning with new words and --spend 10 opens four slots')

    quiet = home('quiet-to-away', 3, 1)
    out = run(quiet, 'enter', '--words', 'Reduce routine updates.', quiet=True)
    assert 'Quiet mode (recorded)' in out
    assert 'new workers that can start' not in out
    assert 'Spend cap' not in out
    out = run(quiet, 'enter')
    cap(quiet, 8)
    room(out, 5)
    assert run(quiet, 'mode').strip() == 'away'
    passed('Quiet entry omits away-room messaging; conversion to away reports five new slots')
finally:
    if base_file is not None:
        base_file.unlink(missing_ok=True)
    shutil.rmtree(work)
    log('CLEANUP: disposable lab homes and prior-version executable removed; no backend or fleet session was used.')
    (EVIDENCE / 'afk-headroom-cli-transcript.txt').write_text('\n'.join(transcript) + '\n')
    (EVIDENCE / 'afk-headroom-scenarios.json').write_text(json.dumps(results, indent=2) + '\n')

print(json.dumps(results, indent=2))
