import os, pathlib, subprocess, tempfile, shutil, json, hashlib, shlex

ROOT = pathlib.Path('/home/zabi/.no-mistakes/worktrees/7f0ec18181b6/01M5HG3T4R8EZNC83GMRF3JYZE')
EVIDENCE = pathlib.Path('/home/zabi/.no-mistakes/evidence/01M5HG3T4R8EZNC83GMRF3JYZE')
BASE = pathlib.Path(tempfile.mkdtemp(prefix='live-', dir=ROOT / '.test-tmp'))
HOME = BASE / 'home'
PROJECT = BASE / 'project'
COPY = BASE / 'pool/1/project'
SOCKET = '.test-tmp/fm-lab-safety.sock'
SESSION = 'fm-lab-safety'
env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_', 'GIT_')) and k not in ('TMUX', 'TMUX_PANE')}
env.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', TMPDIR=str(ROOT / '.test-tmp'))
log = (EVIDENCE / 'live-safety-transcript.txt').open('w')
results = []

def emit(s):
    log.write(str(s) + '\n'); log.flush()

def run(args, expected=None, quiet=False):
    args = [str(a) for a in args]
    p = subprocess.run(args, cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=45)
    if not quiet:
        emit('$ ' + shlex.join(args)); emit(p.stdout.rstrip()); emit('exit=' + str(p.returncode))
    if expected is not None:
        assert p.returncode == expected, p.stdout
    return p

def write_meta(id, home=HOME, lease=False, worktree=COPY):
    p = home / 'state' / (id + '.meta')
    p.write_text(f'window={SESSION}:fm-{id}\nendpoint_task_id={id}\nworktree={worktree}\nproject={PROJECT}\nkind=ship\nmode=local-only\nharness=codex\nspawn_gen=live-{id}\n' + (f'treehouse_lease_id=successor-acquisition\ntreehouse_lease_holder={HOME}/successor/acquisition\n' if lease else ''))
    return p

def snapshot():
    files = [x for x in (BASE / 'pool').rglob('*') if x.is_file()]
    files += list((PROJECT / '.git/worktrees').rglob('*'))
    return {str(x.relative_to(BASE)): hashlib.sha256(x.read_bytes()).hexdigest() for x in files if x.is_file()}

def windows():
    return run(['tmux', '-S', SOCKET, 'list-windows', '-a', '-F', '#{session_name}:#{window_name}:#{pane_pid}:#{pane_current_path}'], expected=0, quiet=True).stdout

def record(name, **details):
    item = dict(name=name, result='pass', **details)
    results.append(item); emit(json.dumps(item, sort_keys=True))

worker = None
try:
    run(['bin/fm-lab-home.sh', 'create', HOME], expected=0)
    (HOME / 'user-home').mkdir()
    env.update(FM_HOME=str(HOME), HOME=str(HOME / 'user-home'))
    (HOME / 'config/backlog-backend').write_text('manual\n')
    (HOME / 'config/crew-harness').write_text('codex\n')
    (HOME / 'config/supervision-host-off').touch()
    (HOME / 'state/.last-watcher-beat').touch()
    run(['git', 'init', '-q', '-b', 'main', PROJECT], expected=0)
    run(['git', '-C', PROJECT, '-c', 'user.name=Live validation', '-c', 'user.email=validation@example.invalid', 'commit', '--allow-empty', '-qm', 'Lab base'], expected=0)
    COPY.parent.mkdir(parents=True)
    run(['git', '-C', PROJECT, 'worktree', 'add', '-q', '--detach', COPY], expected=0)
    pool_state = BASE / 'pool/treehouse-state.json'
    pool_state.write_text(json.dumps({'worktrees':[{'path':str(COPY)}]}))
    run(['tmux', '-f', '/dev/null', '-S', SOCKET, 'new-session', '-d', '-x', '120', '-y', '40', '-s', SESSION, '-n', 'control', 'sleep 600'], expected=0)
    env['TMUX'] = run(['tmux', '-S', SOCKET, 'display-message', '-p', '-t', SESSION, '#{socket_path},#{pid},0'], expected=0, quiet=True).stdout.strip()
    run(['treehouse', '--version'], expected=0)
    get_help = run(['treehouse', 'get', '--help'], expected=0).stdout
    return_help = run(['treehouse', 'return', '--help'], expected=0).stdout
    assert all(x in get_help for x in ['--lease', '--lease-holder', '--json'])
    assert all(x in return_help for x in ['--if-lease-id', '--if-lease-holder'])
    record('Installed Treehouse v2.3.0 exposes lease JSON and conditional-return flags')

    retained = write_meta('retained')
    (HOME / 'state/retained.status').write_text('done: finished\n')
    before = snapshot(); before_windows = windows()
    p = run(['bin/fm-spawn.sh', 'candidate', PROJECT, '--scout', '--harness', 'codex', '--backend', 'tmux'])
    assert p.returncode != 0 and 'retained' in p.stdout and 'REFUSED' in p.stdout, p.stdout
    assert before == snapshot() and before_windows == windows()
    assert not (HOME / 'state/candidate.meta').exists()
    record('New spawn refuses a clean, finished retained legacy record before allocation', copy_and_pool_unchanged=True, endpoints_unchanged=True)

    mate = BASE / 'mate'
    run(['bin/fm-lab-home.sh', 'create', mate], expected=0)
    (HOME / 'data/secondmates.md').write_text(f'- mate - validation (home: {mate}; scope: test; projects: project; added 2026-10-22)\n')
    alias = BASE / 'copy-alias'; alias.symlink_to(COPY, target_is_directory=True)
    retained.unlink(); mate_record = write_meta('retained', home=mate, worktree=alias)
    p = run(['bin/fm-spawn.sh', 'candidate', PROJECT, '--scout', '--harness', 'codex', '--backend', 'tmux'])
    assert p.returncode != 0 and 'retained' in p.stdout and 'REFUSED' in p.stdout, p.stdout
    assert before == snapshot() and before_windows == windows()
    record('New spawn refuses an aliased retained copy in a registered local home', copy_and_pool_unchanged=True, endpoints_unchanged=True)
    mate_record.unlink(); (HOME / 'data/secondmates.md').unlink()

    stale = write_meta('stale'); successor = write_meta('successor', lease=True)
    claim = COPY.parent / '.fm-slot-owner'
    claim.write_text(f'task=successor\nhome={HOME}\n')
    pool_state.write_text(json.dumps({'worktrees':[{'path':str(COPY), 'leased':True, 'lease_id':'successor-acquisition', 'lease_holder':str(HOME)+'/successor/acquisition'}]}))
    for id in ['stale', 'successor']:
        command = 'bash --noprofile --norc -i' if id == 'stale' else 'sleep 600'
        run(['tmux', '-S', SOCKET, 'new-window', '-d', '-t', SESSION + ':', '-n', 'fm-' + id, '-c', COPY, command], expected=0)
    (COPY / 'unfinished').write_text('successor work must survive\n')
    (COPY / '.fm-grok-turnend').write_text('successor hook must survive\n')
    worker = subprocess.Popen(['sleep', '600'], cwd=COPY, env=env)
    before = snapshot(); before_windows = windows(); successor_bytes = successor.read_bytes()
    p = run(['bin/fm-teardown.sh', 'successor'])
    assert p.returncode != 0 and 'reconcile stale task stale first' in p.stdout, p.stdout
    assert before == snapshot() and before_windows == windows() and worker.poll() is None
    record('Owner-first cleanup refuses and identifies the stale task', copy_claim_lease_unchanged=True, successor_process_alive=True)

    p = run(['bin/fm-spawn.sh', 'stale', '--relaunch'])
    assert p.returncode != 0 and 'REFUSED' in p.stdout, p.stdout
    assert before == snapshot() and before_windows == windows() and stale.exists()
    record('Relaunch refuses a stale record without changing its endpoint or successor copy', copy_claim_lease_unchanged=True, endpoints_unchanged=True)

    p = run(['bin/fm-teardown.sh', 'stale'], expected=0)
    assert not stale.exists() and successor.read_bytes() == successor_bytes
    assert before == snapshot() and worker.poll() is None
    after_windows = windows()
    assert ':fm-stale:' not in after_windows and ':fm-successor:' in after_windows
    emit('Surviving runtime endpoints:\n' + after_windows)
    emit('Surviving owner claim:\n' + claim.read_text())
    emit('Surviving pool state:\n' + pool_state.read_text())
    record('Stale-first cleanup retires only the stale record and endpoint', copy_claim_lease_byte_identical=True, successor_process_alive=True, successor_endpoint_alive=True)

    # Isolate legacy cleanup checks from the preceding successor scenario.
    successor.unlink(); claim.unlink(); (COPY / 'unfinished').unlink(); (COPY / '.fm-grok-turnend').unlink()
    worker.terminate(); worker.wait(); worker = None
    pool_state.write_text(json.dumps({'worktrees':[{'path':str(COPY)}]}))
    legacy = write_meta('legacy')
    (COPY / 'uncommitted').write_text('must remain reserved\n')
    before = snapshot(); meta_bytes = legacy.read_bytes()
    p = run(['bin/fm-teardown.sh', 'legacy'])
    assert p.returncode != 0 and 'REFUSED: local-only worktree' in p.stdout, p.stdout
    assert before == snapshot() and legacy.read_bytes() == meta_bytes
    record('Unclaimed legacy copy with uncommitted work refuses plain cleanup and keeps its record', copy_byte_identical=True, record_unchanged=True)
    (COPY / 'uncommitted').unlink()
    (COPY / 'unpushed').write_text('must remain reserved\n')
    run(['git', '-C', COPY, 'add', 'unpushed'], expected=0)
    run(['git', '-C', COPY, '-c', 'user.name=Live validation', '-c', 'user.email=validation@example.invalid', 'commit', '-qm', 'Unlanded lab work'], expected=0)
    before = snapshot()
    p = run(['bin/fm-teardown.sh', 'legacy'])
    assert p.returncode != 0 and 'commits not yet on' in p.stdout, p.stdout
    assert before == snapshot() and legacy.read_bytes() == meta_bytes
    record('Unclaimed legacy copy with an unlanded commit refuses plain cleanup', copy_byte_identical=True, record_unchanged=True)

    # Corrupt the disposable Git index so a real read fails while a lock exists.
    index = pathlib.Path(run(['git', '-C', COPY, 'rev-parse', '--path-format=absolute', '--git-path', 'index'], expected=0, quiet=True).stdout.strip())
    good_index = index.read_bytes(); index.write_bytes(b'broken lab index')
    lock = index.with_name('index.lock'); lock.write_text('held lab lock\n')
    before = snapshot()
    p = run(['bin/fm-teardown.sh', 'legacy'])
    assert p.returncode != 0 and 'REFUSED: a Git lock blocks inspection of legacy unclaimed copy' in p.stdout, p.stdout
    assert 'left untouched' in p.stdout and 'explicit OK to discard' in p.stdout
    assert before == snapshot() and legacy.read_bytes() == meta_bytes
    record('Lock-blocked legacy cleanup explains refusal and recovery while leaving lock and copy untouched', copy_and_lock_byte_identical=True, record_unchanged=True)
    index.write_bytes(good_index); lock.unlink()
    run(['git', '-C', COPY, 'reset', '--hard', '-q', 'main'], expected=0)
    before = snapshot()
    p = run(['bin/fm-teardown.sh', 'legacy'], expected=0)
    assert 'was not returned and is left untouched' in p.stdout
    assert not legacy.exists() and before == snapshot()
    record('Clean unclaimed legacy cleanup removes its record and accurately reports an untouched copy', copy_byte_identical=True)
except Exception as e:
    emit('DRIVER_FAILURE: ' + repr(e))
    raise
finally:
    if worker is not None:
        worker.terminate(); worker.wait()
    run(['tmux', '-S', SOCKET, 'kill-server'])
    shutil.rmtree(BASE)
    socket = ROOT / SOCKET
    if socket.exists(): socket.unlink()
    (EVIDENCE / 'live-safety-results.json').write_text(json.dumps(results, indent=2) + '\n')
    emit('Disposable lab and private tmux server removed.'); log.close()
