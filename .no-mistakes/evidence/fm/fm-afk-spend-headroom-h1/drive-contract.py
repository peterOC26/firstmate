from pathlib import Path
import json, os, shutil, subprocess, tempfile

ROOT = Path.cwd()
EVIDENCE = Path('/home/zabi/.no-mistakes/evidence/01M77978F36175B7GRV0CDSZPB')
TMP = Path(tempfile.mkdtemp(prefix='.afk-live-', dir=ROOT))
transcript = []
results = []
base_env = os.environ.copy()
for key in ['FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_GATE_REFUSE_BYPASS', 'FM_TEST_SEAM', 'FM_TEST_HARNESS', 'FM_AFK_MODE']:
    base_env.pop(key, None)

def home(name, workers=0):
    path = TMP / name
    subprocess.run(['bin/fm-lab-home.sh', 'create', str(path)], check=True, stdout=subprocess.DEVNULL)
    for i in range(workers):
        kind = 'scout' if i % 2 else 'ship'
        status = ['idle', 'parked', 'done'][i % 3]
        (path / f'state/worker-{i}.meta').write_text(f'kind={kind}\nwindow=fm-worker-{i}\n')
        (path / f'state/worker-{i}.status').write_text(f'2026-11-12T00:00:00Z {status}: prepared durable worker record\n')
    transcript.append(f'\n=== {name}: {workers} prepared ordinary worker records, mixed idle/parked/done ===\n')
    return path

def run(path, *args, script='bin/fm-afk-contract.sh', extra=None):
    env = dict(base_env, FM_HOME=str(path))
    env.update(extra or {})
    command = ['bash', script, *args]
    result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=40)
    transcript.append(f'$ FM_HOME=<{path.name}> {script} ' + ' '.join(args) + '\n' + result.stdout + result.stderr + f'[exit {result.returncode}]\n')
    assert result.returncode == 0, result.stderr
    return result.stdout

def check(name, action):
    action()
    results.append({'name':name,'result':'pass'})

def empty():
    path = home('empty')
    out = run(path, 'enter', '--words', 'Keep accepted work moving.', script='bin/fm-afk-launch.sh')
    assert run(path, 'live-workers').strip() == '0'
    assert run(path, 'field', 'spend_max_concurrent_workers').strip() == '5'
    assert 'new workers that can start: 5' in out
    assert 'warning: no new worker' not in out

def busy():
    for count in [3, 15]:
        path = home(f'workers-{count}', count)
        (path/'state/mate.meta').write_text('kind=secondmate\nwindow=remote:mate\n')
        out = run(path, 'enter', '--words', 'Keep accepted work moving.', script='bin/fm-afk-launch.sh')
        assert run(path, 'live-workers').strip() == str(count)
        assert run(path, 'field', 'spend_max_concurrent_workers').strip() == str(count + 5)
        assert 'new workers that can start: 5' in out
        assert 'warning: no new worker' not in out
        if count == 15:
            (EVIDENCE/'fifteen-worker-record.txt').write_text((path/'state/.afk-contract').read_text())

def zero():
    path = home('zero-room', 15)
    out = run(path, 'enter', '--words', 'Wait for room.', '--spend', '15', script='bin/fm-afk-launch.sh')
    assert run(path, 'field', 'spend_max_concurrent_workers').strip() == '15'
    assert 'new workers that can start: 0' in out
    assert 'send /afk again with new words and --spend' in out
    before = (path/'state/.afk-contract').read_bytes()
    for args in [('readback',), ('enter',), ('enter', '--spend', '25')]:
        out = run(path, *args)
        assert 'new workers that can start' not in out
        assert 'warning: no new worker' not in out
        assert (path/'state/.afk-contract').read_bytes() == before
    out = run(path, 'enter', '--words', 'Continue with more room.', '--spend', '25', script='bin/fm-afk-launch.sh')
    assert run(path, 'field', 'spend_max_concurrent_workers').strip() == '25'
    assert 'new workers that can start: 10' in out
    assert 'warning: no new worker' not in out

def over():
    path = home('over-cap', 6)
    out = run(path, 'enter', '--words', 'Hold the lane.', '--spend', '2', script='bin/fm-afk-launch.sh')
    assert run(path, 'field', 'spend_max_concurrent_workers').strip() == '2'
    assert 'new workers that can start: 0 (4 over the cap)' in out
    assert 'send /afk again with new words and --spend' in out
    assert 'new workers that can start: -' not in out

def quiet():
    path = home('quiet-to-away')
    out = run(path, 'enter', '--words', 'Stay quiet.', extra={'FM_AFK_MODE':'quiet'})
    assert 'new workers that can start' not in out
    assert 'warning: no new worker' not in out
    assert run(path, 'mode').strip() == 'quiet'
    out = run(path, 'enter')
    assert run(path, 'mode').strip() == 'away'
    assert 'new workers that can start: 5' in out

def baseline():
    path = home('baseline-fifteen', 15)
    bindir = TMP/'baseline-bin'
    bindir.mkdir()
    for source in (ROOT/'bin').iterdir():
        if source.name != 'fm-afk-contract.sh':
            (bindir/source.name).symlink_to(source)
    source = subprocess.run(['git','show','f3d13fbf15923a3656b60a7b4a9357efa2a55519:bin/fm-afk-contract.sh'],text=True,capture_output=True,check=True).stdout
    old = bindir/'fm-afk-contract.sh'
    old.write_text(source)
    run(path, 'enter', '--words', 'Keep accepted work moving.', script=str(old), extra={'FM_ROOT_OVERRIDE':str(ROOT)})
    cap = run(path, 'field', 'spend_max_concurrent_workers', script=str(old), extra={'FM_ROOT_OVERRIDE':str(ROOT)}).strip()
    assert cap == '15'
    transcript.append('BASELINE REPRODUCTION: 15 ordinary records, cap 15, available new workers 0. Target records cap 20 for the same count.\n')

try:
    check('Empty home enters with cap 5 and five available new workers', empty)
    check('Three and fifteen mixed-status ordinary records get five headroom, excluding secondmates', busy)
    check('Zero-room warning is entry-only; refresh preserves cap; new words plus spend raises cap', zero)
    check('Explicit cap below count prints zero and over-cap amount', over)
    check('Quiet entry omits away room; conversion to away prints room', quiet)
    check('Original 15-record stall reproduced at base commit', baseline)
finally:
    (EVIDENCE/'contract-cli-transcript.txt').write_text(''.join(transcript))
    (EVIDENCE/'contract-results.json').write_text(json.dumps(results,indent=2)+'\n')
    shutil.rmtree(TMP)
print(json.dumps(results,indent=2))
