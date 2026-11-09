import os, pathlib, subprocess, time, json, shutil, signal
root = pathlib.Path.cwd()
evidence = pathlib.Path('/home/zabi/.no-mistakes/evidence/01M6ZH33R26FD539A9M8MN0VCX')
labs = root / '.test-lab'
log = open(evidence / 'live-recovery-transcript.log', 'a', buffering=1)
processes = []

def record(text):
    print(text, file=log, flush=True)
    print(text, flush=True)

def env(home, **extra):
    e = os.environ.copy()
    for k in list(e):
        if k.startswith('FM_') or k in ('TMUX','TMUX_PANE','HERDR_SESSION','HERDR_SOCKET'):
            e.pop(k)
    e.update(FM_HOME=str(home), FM_POLL='1', FM_HEARTBEAT='3600', FM_SIGNAL_GRACE='0', DISABLE_AUTOUPDATER='1')
    e.update(extra)
    return e

def run(home, *args, input=None, ok=(0,), **extra):
    r = subprocess.run(args, cwd=root, env=env(home, **extra), text=True, input=input, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=35)
    record('$ ' + ' '.join(args) + '\n' + r.stdout + f'[exit {r.returncode}]')
    assert r.returncode in ok, (args, r.returncode)
    return r

def home(name):
    p=labs/name
    run(p, 'bin/fm-lab-home.sh','create',str(p))
    return p

def state(p, name): return p/'state'/name

def read(p, name):
    f=state(p,name)
    return f.read_text() if f.exists() else ''

def watcher(p):
    f=open(p/'watch.log','w')
    proc=subprocess.Popen(['bash','bin/fm-watch.sh'], cwd=root, env=env(p), stdout=f,stderr=subprocess.STDOUT, start_new_session=True)
    processes.append(proc)
    return proc

def waitfor(f, timeout=20):
    start=time.monotonic()
    while time.monotonic()-start<timeout:
        if f(): return
        time.sleep(.2)
    raise AssertionError('timed out waiting for live state')

def stop(proc,p):
    if proc.poll() is None:
        proc.terminate()
        proc.wait(timeout=15)
    record('watcher output:\n'+(p/'watch.log').read_text())
    record('recovery marker: '+read(p,'.watcher-down').strip())

def drain(p): return run(p,'bin/fm-wake-drain.sh').stdout

def seed_downtime(p):
    proc=watcher(p)
    waitfor(lambda: state(p,'.last-watcher-beat').exists())
    stop(proc,p)
    assert read(p,'.watcher-down').startswith('pending:downtime:')
    return read(p,'.watcher-down').strip().split(':')[-1]

results=json.loads((evidence/'live-recovery-results.json').read_text())
try:
    p=home('guards-live-v3')
    state(p,'demo.status').write_text('blocked [key=capacity]: unavailable\nworking: newer prose\n')
    drain(p)
    run(p,'node','bin/fm-branch-dispatch.mjs','recovery-settled',ok=(1,))
    with state(p,'demo.status').open('a') as f: f.write('resolved [key=capacity]: available\n')
    run(p,'node','bin/fm-branch-dispatch.mjs','recovery-settled',ok=(1,))
    run(p,'bash','-c','. bin/fm-wake-lib.sh; fm_wake_append signal demo.status \"signal: $STATE/demo.status\"')
    drain(p)
    run(p,'node','bin/fm-branch-dispatch.mjs','recovery-settled')
    run(p,'bin/fm-branch-outcome.sh','append','--task','demo','--verdict','captain','--summary','decision pending')
    run(p,'node','bin/fm-branch-dispatch.mjs','recovery-settled',ok=(1,))
    run(p,'bin/fm-branch-outcome.sh','mark-read','--through','1')
    run(p,'node','bin/fm-branch-dispatch.mjs','recovery-settled',ok=(1,))
    run(p,'bin/fm-branch-outcome.sh','mark-processed','--through','1')
    run(p,'node','bin/fm-branch-dispatch.mjs','recovery-settled')
    record('Open decision, unseen resolution, unread and unprocessed captain outcome all refused settlement.')
    results.append('uncertain or unhandled recovery evidence cannot silently settle')

    p=home('scope-live-v3')
    state(p,'demo.meta').write_text('project=demo\nwindow=fm-demo\n')
    run(p,'bash','-c','. bin/fm-wake-lib.sh; fm_wake_append signal demo.status "signal: $STATE/demo.status"; fm_wake_append check merge "check: merge landed: lab"')
    out=run(p,'node','bin/fm-branch-dispatch.mjs','offer',input='check: rearm-resurface\n').stdout
    assert 'eligible=1' in out and 'rows=1\n' in out and 'tasks=demo\n' in out and 'unscoped=0' in out
    out=run(p,'node','bin/fm-branch-dispatch.mjs','offer',input='check: arbitrary attended check\n').stdout
    assert 'eligible=0' in out
    run(p,'bin/fm-wake-grant.sh','activate',str(os.getpid()),'live-scope')
    run(p,'bin/fm-wake-grant.sh','publish','live-scope','1')
    out=run(p,'bin/fm-wake-drain.sh', FM_SUPERVISION_ACTOR='branch').stdout
    record('Branch grant drain only: '+out)
    run(p,'bin/fm-wake-drain.sh','--ack-through','2',FM_SUPERVISION_ACTOR='branch')
    queue=read(p,'.wake-queue')
    record('Persisted queue after branch acknowledgement through 2:\n'+queue)
    assert '\t2\tcheck\tmerge\t' in queue and '\t1\tsignal\t' not in queue
    run(p,'bin/fm-wake-grant.sh','release','live-scope')
    run(p,'bin/fm-wake-grant.sh','deactivate',str(os.getpid()),'live-scope')
    state(p,'demo.status').write_text('needs-decision [key=choice]: choose\n')
    run(p,'bash','-c','. bin/fm-wake-lib.sh; fm_wake_append signal demo.status "signal: $STATE/demo.status"')
    out=run(p,'node','bin/fm-branch-dispatch.mjs','offer',input='check: rearm-resurface\n').stdout
    assert 'eligible=0' in out
    out=run(p,'node','bin/fm-branch-dispatch.mjs','offer','--afk',input='check: rearm-resurface\n').stdout
    assert 'eligible=1' in out
    state(p,'.wake-queue').open('a').write('corrupt\n')
    out=run(p,'node','bin/fm-branch-dispatch.mjs','offer','--afk',input='check: rearm-resurface\n').stdout
    assert 'eligible=0' in out
    record('Recovery offered original row 1 only, branch ack left main row 2 durable, generic attended check refused, decision partition and corrupt-queue refusal preserved.')
    results.append('recovery preserves original row grants and main ownership')
finally:
    for proc in processes:
        if proc.poll() is None:
            proc.terminate()
            try: proc.wait(timeout=15)
            except subprocess.TimeoutExpired: os.killpg(proc.pid, signal.SIGKILL)
    record('Completed: '+json.dumps(results))
    (evidence/'live-recovery-results.json').write_text(json.dumps(results,indent=2)+'\n')
    log.close()
