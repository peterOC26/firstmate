import base64, hashlib, json, os, pathlib, re, shutil, subprocess, tempfile, time
ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('/home/zabi/.no-mistakes/evidence/01M707X8CATVY2RTZPY1YDP8QC')
lab = pathlib.Path(tempfile.mkdtemp(prefix='.fm-lab-startup-', dir=ROOT))
env = os.environ.copy()
for key in list(env):
    if key.startswith(('FM_', 'HERDR_', 'REX_', 'TASKS_AXI_')) or key in ('TMUX','TERM_PROGRAM'):
        env.pop(key, None)
env.update(FM_HOME=str(lab), FM_BACKEND='tmux', TASKS_AXI_BACKEND='markdown', FM_SESSION_START_QUEUED_LIMIT='1')
commands = []
def run(args, timeout=60, record=True):
    p = subprocess.run([str(a) for a in args], cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    if record:
        commands.append({'command': [str(a).replace(str(lab), '<LAB>') for a in args], 'exit': p.returncode})
    if p.returncode:
        raise RuntimeError(f'{args[:4]}: exit {p.returncode}: {p.stdout.decode(errors="replace")}')
    return p.stdout

def task(*args):
    if os.environ.get('REUSE_SEEDED_BACKLOG') and args[0] in ('add','start','hold','block','done'): return b''
    return run(['bin/fm-tasks-axi.sh', *args])
def encode(s):
    return 'fm-hold-v1:' + base64.b64encode(s.encode()).decode()
def add(id, title, reason=None, kind=None, state='queued', blocked=False):
    task('add', id, title, '--kind', 'ship', '--body', 'BODY-PRIVATE-' + id)
    if state == 'in_flight': task('start', id)
    if reason is not None: task('hold', id, '--kind', kind, '--reason', encode(reason))
    if blocked: task('block', id, '--by', 'dependency')

results = []
try:
    run(['bin/fm-lab-home.sh','create',lab])
    (lab/'config'/'backend').write_text('tmux\n')
    (lab/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    task('--version')
    add('dependency','Required dependency')
    quiet_reason = 'QUIET-REASON-OMITTED ' * 80
    titles = {}
    for i in range(1,217):
        kind = 'parked' if i <= 108 else 'captain'
        reason = quiet_reason if i <= 108 else ('Watch ' if i <= 162 else 'Wait ') + quiet_reason
        title = f'Quiet, "quoted" job {i}'
        k = (i-1) % 108
        if k < 6:
            glyph, boundary = [('é',116),('€',116),('€',115),('🚢',116),('🚢',115),('🚢',114)][k]
            prefix = f'- [ ] quiet-{i} - '
            title = 'a' * (boundary-len(prefix.encode())) + glyph*5
        titles[f'quiet-{i}'] = title
        add(f'quiet-{i}', title, reason, kind)
    protected = {
      'captain-call': ('Captain call DETAILS-KEPT','captain','queued',False),
      'captain-needs': ('Needs the captain DETAILS-KEPT','captain','queued',False),
      'captain-question': ('Which option? DETAILS-KEPT (hold-kind: parked)\nsecond question line','captain','queued',False),
      'captain-prose': ('Needs a decision about (hold: Watch) DETAILS-KEPT','captain','queued',False),
      'blocked-parked': ('BLOCKED-PARKED-DETAILS-KEPT','parked','queued',True),
      'blocked-watch': ('Watch BLOCKED-WATCH-DETAILS-KEPT','captain','queued',True),
      'live-parked': ('LIVE-PARKED-DETAILS-KEPT (even parked)\nsecond live line','parked','in_flight',False),
      'live-watch': ('Wait LIVE-WATCH-DETAILS-KEPT','captain','in_flight',False),
      'external': ('Watch EXTERNAL-DETAILS-KEPT','external','queued',False),
      'future': ('Wait FUTURE-DETAILS-KEPT','future','queued',False),
      'lowercase': ('watch LOWERCASE-DETAILS-KEPT','captain','queued',False),
    }
    for id,(reason,kind,state,blocked) in protected.items():
        add(id, id+' protected title', reason, kind, state, blocked)
    add('completed','Done history omitted')
    task('done','completed')
    for i in range(1,5): add(f'ready-{i}',f'Ready unheld job {i}')
    if os.environ.get('REUSE_SEEDED_BACKLOG'):
        shutil.copyfile(EVIDENCE/'seeded-backlog.md', lab/'data/backlog.md')
    original = (lab/'data/backlog.md').read_bytes()
    (EVIDENCE/'seeded-backlog.md').write_bytes(original)
    held = task('list','--state','held','--fields','blocked_by,hold_kind,hold_reason')
    (EVIDENCE/'held-before-compaction.toon').write_bytes(held)
    summary = {'seeded_rows': 233, 'shortenable_parked':108,'shortenable_watch':108, 'backlog_bytes':len(original), 'modes':{}}
    for mode in ['tasks-axi','manual']:
        if mode == 'manual': (lab/'config/backlog-backend').write_text('manual\n')
        start = time.monotonic()
        output = run(['bin/fm-session-start.sh','--reemit'], timeout=150)
        (EVIDENCE/f'startup-{mode}.txt').write_bytes(output)
        text = output.decode('utf-8',errors='strict')
        fleet = text.split('=== FLEET STATE ===',1)[-1]
        # The full digest is retained as evidence; assertions use emitted public output only.
        assert ('compact backlog listing (tasks-axi' if mode == 'tasks-axi' else 'compact backlog listing (manual backend') in text, f'{mode}: expected renderer was not used'
        assert '●  STARTUP TRUNCATED' not in text, f'{mode}: incomplete digest'
        assert text.count('108 parked, 108 watch queued hold(s) shortened') == 1, f'{mode}: wrong shortened count'
        assert text.count('queued hold(s) shortened') == 1, f'{mode}: overlap double counted'
        assert 'QUIET-REASON-OMITTED' not in text, f'{mode}: quiet reasons leaked'
        assert 'bin/fm-tasks-axi.sh show <id> --full' in text
        for id in titles:
            if mode == 'tasks-axi': assert re.search(r'^  '+re.escape(id)+r',',text,re.M), f'{mode}: missing {id}'
            else: assert re.search(r'^- \[ \] '+re.escape(id)+r' - ',text,re.M), f'{mode}: missing {id}'
        for id,(reason,kind,state,blocked) in protected.items():
            encoded = json.dumps(reason, ensure_ascii=False)[1:-1]
            assert encoded in text, f'{mode}: protected reason omitted for {id}'
        for id in ('blocked-parked','blocked-watch','live-parked','live-watch'):
            reason = protected[id][0]
            expected = 2 if mode == 'tasks-axi' else 1
            assert text.count(json.dumps(reason,ensure_ascii=False)[1:-1]) == expected, f'{mode}: lost full overlapping row {id}'
        assert 'Done history omitted' not in text
        assert 'BODY-PRIVATE' not in text
        assert (lab/'data/backlog.md').read_bytes() == original, f'{mode}: backlog was mutated'
        if mode == 'manual':
            for i in [1,2,3,4,5,6,109,110,111,112,113,114]:
                line = next(line for line in text.splitlines() if line.startswith(f'- [ ] quiet-{i} - '))
                assert '... (hold-kind:' in line, f'{mode}: title not truncated'
                assert len(line.encode()) <= 164, f'{mode}: line exceeds bound'
        summary['modes'][mode] = {'digest_bytes':len(output),'duration_seconds':round(time.monotonic()-start,2),'valid_utf8':True,'shortened_rows':216,'shortened_summary_lines':1,'protected_rows_preserved':True,'backlog_unchanged':True}
        results.append(mode + ': PASS')
        # Finish the script-owned asynchronous read-only stage before deleting the lab.
        run(['bin/fm-startup-network.sh','wait','30'],timeout=40)
    details = task('show','quiet-109','--full')
    (EVIDENCE/'full-watch-details.txt').write_bytes(details)
    assert quiet_reason in details.decode(), 'full details unavailable after compaction'
    assert 'BODY-PRIVATE-quiet-109' in details.decode()
    summary['full_details_recoverable']=True
    (EVIDENCE/'live-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(json.dumps(summary,indent=2))
finally:
    (EVIDENCE/'live-commands.json').write_text(json.dumps(commands,indent=2)+'\n')
    shutil.rmtree(lab)
    print('Disposable lab removed:',lab.name)
