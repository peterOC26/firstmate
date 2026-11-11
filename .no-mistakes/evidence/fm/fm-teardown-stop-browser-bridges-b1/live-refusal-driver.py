import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import time

root = Path.cwd()
evidence = Path('/home/zabi/.no-mistakes/evidence/01M75HG71DW0AXQEVWWFWAR53K')
lab = Path(tempfile.mkdtemp(prefix='fm-lab.', dir=root / '.phase-test-tmp'))
logfile = (evidence / 'live-refusal-transcript.log').open('w', buffering=1)
groups = []
sessions = []

def log(text):
    print(text, flush=True)
    print(text, file=logfile, flush=True)

def proc(pid):
    try:
        stat = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
        cmd = Path(f'/proc/{pid}/cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace')
        return {'pid': pid, 'state': stat[0], 'ppid': int(stat[1]), 'pgid': int(stat[2]), 'start': stat[19], 'command': cmd}
    except FileNotFoundError:
        return None

def running(pid):
    p = proc(pid)
    return p is not None and p['state'] not in ('Z', 'X')

env = dict(os.environ)
for key in list(env):
    if key.startswith(('FM_', 'HERDR_', 'CHROME_DEVTOOLS_AXI_', 'TASKS_AXI_')) or key in ('BASH_ENV', 'ENV', 'TMUX', 'TERM_PROGRAM'):
        env.pop(key)
# These child processes have a disposable runtime home; the operator's home
# and its browser-session files are never addressed by this verification.
env.update(HOME=str(lab / 'runtime-home'), FM_HOME=str(lab),
           TMPDIR=str(lab / 'tmp'), XDG_CACHE_HOME=str(lab / 'cache'),
           XDG_CONFIG_HOME=str(lab / 'xdg-config'), XDG_DATA_HOME=str(lab / 'xdg-data'),
           npm_config_cache=str(lab / 'npm-cache'), GIT_CONFIG_GLOBAL='/dev/null',
           GIT_CONFIG_NOSYSTEM='1', NM_HOME=str(lab / 'nm'),
           TMUX=str(lab / 'absent.sock') + ',0,0')

def run(args, command_env=None, timeout=90):
    result = subprocess.run(args, cwd=root, env=command_env or env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    log('$ ' + ' '.join(map(str, args)))
    log(result.stdout.rstrip())
    log(f'exit={result.returncode}')
    return result

def record(task, worktree=None):
    path = lab / 'state' / f'{task}.meta'
    path.write_text(f'worktree={worktree or lab / "gone-worktree"}\nproject={lab / "project"}\nkind=ship\nmode=local-only\nharness=codex\n')
    assert run(['tasks-axi', 'add', task, 'Disposable live bridge validation', '--kind', 'ship', '--file', str(lab / 'data' / 'backlog.md')]).returncode == 0
    assert run(['tasks-axi', 'start', task, '--file', str(lab / 'data' / 'backlog.md')]).returncode == 0
    return path

def start_bridge(label, task='bridge-live-b1', inbox='own'):
    bridge_env = dict(env)
    bridge_env.update(CHROME_DEVTOOLS_AXI_SESSION=f'fm-phase-{label}-{os.getpid()}',
                      CHROME_DEVTOOLS_AXI_EXECUTABLE_PATH='/usr/bin/chromium',
                      CHROME_DEVTOOLS_AXI_USER_DATA_DIR=str(lab / f'chrome-{label}'),
                      CHROME_DEVTOOLS_AXI_CHROME_ARGS='--no-sandbox --disable-dev-shm-usage',
                      CHROME_DEVTOOLS_AXI_BRIDGE_TIMEOUT_MS='60000')
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        bridge_env['CHROME_DEVTOOLS_AXI_PORT'] = str(sock.getsockname()[1])
    if task is not None:
        bridge_env['FM_TASK_ID'] = task
    if inbox != 'missing':
        inbox_task = task if task == 'bridge-refused-b1' else 'bridge-live-b1'
        bridge_env['FM_TASK_INBOX'] = str((lab / 'state' if inbox == 'own' else lab / 'other-home' / 'state') / f'{inbox_task}.inbox')
    sessions.append(bridge_env)
    result = run(['chrome-devtools-axi', 'start'], bridge_env, timeout=85)
    pidfile = lab / 'runtime-home' / '.chrome-devtools-axi' / 'sessions' / bridge_env['CHROME_DEVTOOLS_AXI_SESSION'] / 'bridge.pid'
    if pidfile.exists():
        pid = json.loads(pidfile.read_text())['pid']
        groups.append((pid, proc(pid)['start']))
    else:
        raise RuntimeError(f'{label}: real bridge wrote no pid file')
    if result.returncode:
        raise RuntimeError(f'{label}: real bridge failed to start')
    p = proc(pid)
    assert p and p['pgid'] == pid and 'chrome-devtools-axi-bridge.js' in p['command'], p
    log(f'BRIDGE {label}: {json.dumps(p)}')
    return pid, bridge_env

def state(label, pid):
    p = proc(pid)
    log(f'{label}: ' + json.dumps(p or {'pid': pid, 'state': 'absent'}))


try:
    assert run(['bash', 'bin/fm-lab-home.sh', 'create', str(lab)]).returncode == 0
    for directory in ('runtime-home', 'tmp', 'project', 'tmux'):
        (lab / directory).mkdir()
    (lab / 'data' / 'backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
    (lab / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    project = lab / 'project'
    assert run(['git', '-C', str(project), 'init', '-q', '-b', 'main']).returncode == 0
    assert run(['git', '-C', str(project), '-c', 'user.name=Lab', '-c', 'user.email=lab@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'baseline']).returncode == 0
    wt = lab / 'unlanded'
    assert run(['git', 'clone', '-q', str(project), str(wt)]).returncode == 0
    assert run(['git', '-C', str(wt), 'checkout', '-q', '-b', 'task-unlanded']).returncode == 0
    (wt / 'uncommitted.txt').write_text('work must survive\n')
    rejected_task = 'bridge-refused-b1'
    rejected, rejected_env = start_bridge('refused', task=rejected_task)
    meta = record(rejected_task, wt)
    before = meta.read_bytes()
    result = run(['bash', 'bin/fm-teardown.sh', rejected_task])
    assert result.returncode == 1 and 'REFUSED' in result.stdout and ('uncommitted' in result.stdout or 'untracked' in result.stdout)
    assert meta.read_bytes() == before
    assert (wt / 'uncommitted.txt').read_text() == 'work must survive\n'
    assert running(rejected)
    state('After dirty-worktree refusal bridge', rejected)
    assert run(['chrome-devtools-axi', 'pages'], rejected_env).returncode == 0
    log('OBSERVED: dirty-worktree refusal preserved the byte-identical task record, uncommitted file, and responsive real bridge.')
    log('LIVE DIRTY REFUSAL PASS')
finally:
    for bridge_env in sessions:
        try:
            run(['chrome-devtools-axi', 'stop'], bridge_env, timeout=15)
        except Exception as error:
            log(f'Cleanup stop: {error}')
    for pid, start in groups:
        p = proc(pid)
        if p and p['start'] == start and p['pgid'] == pid:
            try:
                os.killpg(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    shutil.rmtree(lab)
    log('Disposable lab and owned bridge groups removed.')
    logfile.close()
