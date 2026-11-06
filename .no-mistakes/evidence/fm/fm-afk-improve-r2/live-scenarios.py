import datetime, hashlib, json, os, pathlib, shutil, subprocess, tempfile

ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('/home/zabi/.no-mistakes/evidence/01M6Q1S6BCZ3DT0QKMCSE7DG31')
BASE = dict(os.environ)
for key in list(BASE):
    if key.startswith(('FM_', 'TASKS_AXI_')) or key in ('TMUX', 'TMUX_PANE'):
        BASE.pop(key)
BASE['LC_ALL'] = 'C.utf8'
lab = pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.'))
log = open(EVIDENCE / 'live-cli-transcript.txt', 'w')
results = []

def note(s):
    print(s, flush=True)
    log.write(s + '\n'); log.flush()

def run(args, allowed=(0,), extra=None):
    env = dict(BASE, FM_HOME=str(lab))
    env.update(extra or {})
    p = subprocess.run([str(x) for x in args], cwd=ROOT, env=env, text=True, capture_output=True, timeout=60)
    note('$ ' + ' '.join(str(x).replace(str(lab), '$LAB') for x in args))
    note(p.stdout)
    if p.stderr: note('stderr: ' + p.stderr)
    note('exit: ' + str(p.returncode))
    assert p.returncode in allowed, (args, p.returncode, p.stdout, p.stderr)
    return p.stdout

def axi(*args): return run(['bin/fm-tasks-axi.sh', *args])
def meta(task, status):
    (lab/'state'/f'{task}.meta').write_text('window=primary:0\nbackend=tmux\nkind=ship\n')
    (lab/'state'/f'{task}.status').write_text(status + '\n')
def snapshot():
    return {str(p.relative_to(lab)): hashlib.sha256(p.read_bytes()).hexdigest()
            for d in ['state','data'] for p in (lab/d).rglob('*') if p.is_file()}
def section(output): return output.split('Not started:\n',1)[1].split('Cost:',1)[0]
def record(name):
    results.append({'name':name, 'result':'pass'})
    note('SCENARIO PASS: '+name)

try:
    run(['bin/fm-lab-home.sh','create',lab])
    (lab/'tmux').mkdir()
    run(['tmux','-L','fm-lab','new-session','-d','-s','primary','-x','120','-y','40','sleep','600'], extra={'TMUX_TMPDIR':str(lab/'tmux')})
    (lab/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    (lab/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    for task in ['done-job','queued-job','hold-a','hold-b','dated-job','future-job','cut-job','complete-job','short-job','status-job']:
        axi('add',task,'Live validation '+task)
    axi('block','queued-job','--by','done-job')
    axi('done','done-job','--note','landed')
    axi('hold','hold-a','--reason','wait for naming decision','--kind','captain')
    run(['bin/fm-captain-hold.sh','hold','hold-b','--reason','Choose the public name'])
    day = datetime.datetime.now(datetime.timezone.utc).date()
    future = str(day + datetime.timedelta(days=3))
    axi('hold','dated-job','--reason','date passed','--kind','future','--until',str(day-datetime.timedelta(days=1)))
    axi('hold','future-job','--reason','later','--kind','future','--until',future)
    meta('running-job','working: building\nNext: bin/fm-send.sh running-job continue')
    meta('paused-job','paused: waiting on advisory suite')
    meta('blocked-job','blocked [at=100] [key=dep]: waiting\nNext: bin/fm-send.sh blocked-job do not run')
    meta('done-job','done: https://github.com/example/repo/pull/9 checks green')
    meta('stuck-job','failed: one\nfailed check: two\ncheck failed: three')
    words = 'watch the fleet\nDo not merge anything. Stop after three failed checks.'
    out = run(['bin/fm-afk-launch.sh','enter','--words',words])
    assert (lab/'state/.afk-contract').is_file()
    assert words == run(['bin/fm-afk-contract.sh','words']).rstrip('\n')
    assert out.index('watch the fleet') < out.index('Live work:')
    before = snapshot()
    out = run(['bin/fm-afk-entry-brief.sh'])
    assert snapshot() == before, 'read-only inventory modified persisted data'
    for value in ['running-job: working','paused-job: paused','hold-a: wait for naming decision','hold-b: Choose the public name','queued-job: blocked-by done-job is done','done-job: https://github.com/example/repo/pull/9','dated-job: hold until','future-job: hold until','stuck-job: 3 consecutive failed checks']:
        assert value in out, value
    ids = [line.strip().split(':',1)[0] for line in out.splitlines() if line.startswith('  ') and ':' in line and not line.startswith('  Name')]
    headings = ['Live work:', 'Held for the captain:', 'Queued, blocker cleared:', 'Green, waiting on a merge sentence:', 'Dates that have passed:', 'Future dates, not registered:', 'Stop point, three failed checks:', 'Read-back checklist:']
    assert [out.index(x) for x in headings] == sorted(out.index(x) for x in headings)
    assert not list((lab/'state').glob('*.check.sh'))
    assert not list((lab/'state').glob('*seen*'))
    record('Enter away mode, preserve verbatim words, and print a stable read-only inventory with holds, cleared blockers, green PRs, dates, and failed checks')

    backlog = lab/'data/backlog.md'
    digest = hashlib.sha256(backlog.read_bytes()).hexdigest()
    backlog.chmod(0)
    try:
        for mode in [[],['not-started']]:
            out = run(['bin/fm-afk-entry-brief.sh',*mode])
            assert 'backlog file is unreadable' in out
    finally: backlog.chmod(0o644)
    assert hashlib.sha256(backlog.read_bytes()).hexdigest() == digest
    record('Read an unreadable backlog: report the error, exit zero, and preserve its contents')

    before = snapshot()
    out = run(['bin/fm-afk-entry-brief.sh','--register-future','dated-job'])
    assert 'already due' in out and snapshot() == before
    run(['bin/fm-afk-entry-brief.sh','--register-future','future-job'])
    shim = lab/'state/fm-afk-future-future-job.check.sh'
    assert shim.is_file() and shim.stat().st_mode & 0o777 == 0o700
    assert not run([shim]).strip()
    axi('hold','future-job','--reason','rescheduled for today','--kind','future','--until',str(day))
    out = run([shim]); assert 'is due' in out
    assert not run([shim]).strip()
    assert not list((lab/'state').glob('*seen*'))
    record('Offer future checks without registering; explicitly register one, refuse already-due registration, and fire once after the date becomes due')

    pad = '0'*480
    axi('update','cut-job','--body',pad+'\nNext: bin/fm-send.sh cut-job please continue the work')
    axi('update','complete-job','--body','Next: bin/fm-send.sh complete-job continue\n'+pad+' trailing text')
    axi('update','short-job','--body','Next: bin/fm-send.sh short-job continue')
    axi('update','status-job','--body',pad+'\nNext: bin/fm-send.sh status-job partial body')
    for task in ['cut-job','complete-job','short-job','status-job']: meta(task,'working: building')
    meta('status-job','working: Next: bin/fm-send.sh status-job use status instead')
    assert '... (truncated,' in axi('list','--fields','body')
    for mode in ['inventory','not-started']:
        out = run(['bin/fm-afk-entry-brief.sh',mode])
        assert 'cut-job: working; next:' not in out and '  - cut-job:' not in out
        for command in ['bin/fm-send.sh complete-job continue','bin/fm-send.sh short-job continue','bin/fm-send.sh status-job use status instead']:
            assert command in out,command
    record('Omit a Next command cut by real tasks-axi truncation while preserving complete earlier lines, short bodies, and status precedence')

    run(['bin/fm-afk-main-outcome.sh','--task','running-job','--summary','Reviewed pending advisory suite; continue waiting','--wake','signal: running-job.status'])
    rows = [json.loads(x) for x in (lab/'state/branch-outcomes.jsonl').read_text().splitlines()]
    assert len(rows)==1 and rows[0]['silent'] is True and rows[0]['verdict']=='routine'
    size = (lab/'state/branch-outcomes.jsonl').stat().st_size
    for args in [['--verdict','captain'],['--continuation','merge immediately']]:
        run(['bin/fm-afk-main-outcome.sh','--task','running-job','--summary','forbidden',*args],allowed=(2,))
    assert (lab/'state/branch-outcomes.jsonl').stat().st_size==size
    run(['bin/fm-captain-hold.sh','hold','naming-decision','--title','Choose the name','--reason','Choose the public name'])
    out = axi('show','naming-decision')
    assert 'held: yes' in out
    note('Persisted outcome contract:\n'+(lab/'state/branch-outcomes.jsonl').read_text())
    record('Record a silent routine outcome, refuse captain verdicts and continuations, and persist a captain-owned decision as a held task')

    out = run(['bin/fm-afk-return.sh','begin'], allowed=(0,3))
    ns = section(out)
    assert 'blocked-job' not in ns
    for task,cmd in [('running-job','continue'),('short-job','continue'),('status-job','use status instead')]:
        expected = f'  - {task}: bin/fm-send.sh {task} {cmd}'
        assert ns.count(expected)==1, ns
    assert 'cut-job' not in ns
    assert 'naming-decision' in out
    assert (lab/'state/.afk-return-catchup').is_file(), 'blocker should retain catchup gate'
    (lab/'state/blocked-job.status').write_text((lab/'state/blocked-job.status').read_text()+'resolved [key=dep]: test dependency resolved\n')
    run(['bin/fm-afk-return.sh','check'])
    record('Return with exact next commands once, omit open blocked work, and retain the catch-up gate until the blocker resolves')

    # Keep a long multibyte command first and a shorter ASCII command later.
    for p in (lab/'state').glob('*.meta'): p.unlink()
    meta('aaa-long','working: Next: bin/fm-send.sh aaa-long résumé — continue')
    meta('zzz-short','working: Next: bin/fm-send.sh zzz-short go')
    line = '  - aaa-long: bin/fm-send.sh aaa-long résumé — continue\n'
    short = '  - zzz-short: bin/fm-send.sh zzz-short go\n'
    byte_n = len(line.encode())
    note(f'UTF-8 line has {len(line)} characters and {byte_n} bytes including newline; shorter ASCII line has {len(short.encode())} bytes.')
    for budget in [1,byte_n-1,byte_n,byte_n+len(short.encode())]:
        out=run(['bin/fm-afk-return.sh','check'], extra={'FM_AFK_NOT_STARTED_BUDGET':str(budget)})
        ns=section(out)
        assert (line in ns)==(budget>=byte_n), (budget,ns)
        if budget==byte_n-1: assert short in ns, ns
        if budget==1: assert 'more not shown' in ns and 'bin/' not in ns
        command_bytes=sum(len(x.encode())+1 for x in ns.splitlines() if x.startswith('  - '))
        assert command_bytes<=budget,(budget,command_bytes)
    record('Enforce the return byte budget including newlines under UTF-8, omit oversized lines, and let later shorter commands fit')
finally:
    subprocess.run(['tmux','-L','fm-lab','kill-server'],env=dict(BASE,TMUX_TMPDIR=str(lab/'tmux')),capture_output=True)
    shutil.rmtree(lab)
    note('Disposable lab home and private tmux server removed.')
    (EVIDENCE/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
    log.close()
