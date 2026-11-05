import os, pathlib, tempfile, subprocess, json, hashlib, shutil, datetime
ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('/home/zabi/.no-mistakes/evidence/01M6P7QKVE7DA9AXYNDHV9FXED')
HOME = pathlib.Path(tempfile.mkdtemp(prefix='.away-live-', dir=ROOT))
# The supported helper only stamps an empty directory.
HOME.rmdir()
env = os.environ.copy()
for key in list(env):
    if key.startswith('FM_') or key in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND'):
        env.pop(key)
env['FM_HOME'] = str(HOME)
log = []
def run(script, *args, codes=(0,), extra=None):
    command = [str(ROOT/'bin'/script), *args]
    cp = subprocess.run(command, cwd=ROOT, env=env | (extra or {}), text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=50)
    log.append('$ ' + ' '.join([script, *args]) + '\n' + cp.stdout + cp.stderr + f'[exit {cp.returncode}]\n')
    (EVIDENCE/'away-cli-transcript.txt').write_text('\n'.join(log))
    assert cp.returncode in codes, (script, cp.returncode, cp.stdout, cp.stderr)
    return cp.stdout + cp.stderr

def snapshot():
    return {str(p.relative_to(HOME)): hashlib.sha256(p.read_bytes()).hexdigest() for sub in ('data','state') for p in (HOME/sub).rglob('*') if p.is_file()}

def status(task, body):
    (HOME/'state'/f'{task}.meta').write_text(f'window=inventory:{task}\nbackend=tmux\nkind=ship\n')
    (HOME/'state'/f'{task}.status').write_text(body+'\n')

try:
    run('fm-lab-home.sh', 'create', str(HOME))
    (HOME/'config'/'supervision-host-off').touch()
    (HOME/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    (HOME/'data'/'backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    for task, title in [('decision','Choose a name'),('finished','Completed dependency'),('queued','Ready after dependency'),('due','Past deferral'),('future','Future deferral')]:
        run('fm-tasks-axi.sh','add',task,title)
    run('fm-tasks-axi.sh','block','queued','--by','finished')
    run('fm-tasks-axi.sh','done','finished','--note','landed')
    run('fm-captain-hold.sh','hold','decision','--reason','Choose the public name')
    today = datetime.datetime.now(datetime.timezone.utc).date()
    past = str(today-datetime.timedelta(days=1))
    future = str(today+datetime.timedelta(days=1))
    for task, date in [('due',past),('future',future)]:
        run('fm-tasks-axi.sh','hold',task,'--reason','Revisit on the date','--kind','future','--until',date)
    run('fm-tasks-axi.sh','update','finished','--body','Next: bin/fm-send.sh finished prepare the follow-up')
    status('paused','paused: advisory suite still running\nNext: bin/fm-peek.sh paused')
    status('finished','done: https://github.com/example/away-demo/pull/9 checks green')
    status('other-green','done: https://github.com/example/away-demo/pull/10 checks green')
    status('working','working: building\nNext: bin/fm-peek.sh working')
    status('blocked','blocked [at=100] [key=dep]: missing dependency\nNext: bin/fm-send.sh blocked retry')
    status('repeated','failed [key=same]: failed check on same finding\nfailed [key=same]: failed check on same finding\nfailed [key=same]: failed check on same finding')
    before = snapshot()
    entry = run('fm-afk-launch.sh','enter','--words','Move ready jobs forward; no merges. Stop a job after three checks fail on the same finding.')
    assert 'Live work:' in entry and 'Read-back checklist:' in entry
    for expected in ['paused: paused; next: bin/fm-peek.sh paused','working: working; next: bin/fm-peek.sh working','finished: done; next: bin/fm-send.sh finished prepare the follow-up','decision:','queued: blocked-by finished is done','https://github.com/example/away-demo/pull/9','https://github.com/example/away-demo/pull/10','repeated: 3 consecutive failed checks',f'due: hold until {past}',f'future: hold until {future}']:
        assert expected in entry, expected
    after = snapshot()
    assert {k:v for k,v in before.items() if k.startswith('data/')} == {k:v for k,v in after.items() if k.startswith('data/')}
    assert (HOME/'state'/'.afk-contract').exists()
    assert not list((HOME/'state').glob('*.check.sh'))
    log.append('OBSERVED: away record exists; inventory contains every seeded job category, both green PRs, cleared dependency and dates; backlog bytes unchanged; no future check registered by entry.\n')
    shown = run('fm-tasks-axi.sh','show','decision')
    assert 'Choose the public name' in shown
    if 'decision: Choose the public name' not in entry:
        log.append('PRODUCT FAILURE: the normal captain-hold path displays an encoded fm-hold-v1 reason in the entry inventory, while fm-tasks-axi.sh show decodes the same persisted reason correctly.\n')
    run('fm-tasks-axi.sh','add','plain-hold','Plain held comparison')
    run('fm-tasks-axi.sh','hold','plain-hold','--reason','Plain held comparison','--kind','captain')
    comparison = run('fm-afk-entry-brief.sh')
    assert 'plain-hold: Plain held comparison' in comparison
    log.append('COUNTERFACTUAL: a plain tasks-axi hold displays its reason correctly in the same inventory; the normal captain-hold wrapper stores encoded reasons, which the new reader does not decode.\n')
    state_before = snapshot()
    inventory = run('fm-afk-entry-brief.sh')
    assert snapshot() == state_before, 'read-only inventory changed persisted bytes'
    log.append('OBSERVED: standalone inventory changed no state or data bytes.\n')
    unreadable = HOME/'data'/'backlog.md'
    unreadable.chmod(0)
    try:
        out = run('fm-afk-entry-brief.sh')
        assert 'backlog file is unreadable' in out
    finally:
        unreadable.chmod(0o644)
    assert snapshot() == state_before
    log.append('OBSERVED: unreadable backlog reported with exit 0 and no persisted byte changes.\n')
    out = run('fm-afk-entry-brief.sh','--register-future','due')
    assert 'already due' in out
    assert not (HOME/'state'/'fm-afk-future-due.check.sh').exists()
    out = run('fm-afk-entry-brief.sh','--register-future','future')
    assert 'registered:' in out
    shim = HOME/'state'/'fm-afk-future-future.check.sh'
    assert shim.exists() and shim.stat().st_mode & 0o777 == 0o700
    assert len(list((HOME/'state').glob('*.check.sh'))) == 1
    assert not list((HOME/'state').glob('*seen*'))
    assert all(v == snapshot()[k] for k,v in state_before.items() if k.endswith('.status') or k.startswith('data/'))
    for day, must_fire in [(str(today),False),(future,True),(future,False)]:
        cp = subprocess.run([str(shim)], env=env | {'FM_AFK_ENTRY_TODAY':day}, capture_output=True, text=True, timeout=30)
        log.append(f'$ registered future check (today={day})\n{cp.stdout}{cp.stderr}[exit {cp.returncode}]\n')
        assert cp.returncode == 0
        assert bool(cp.stdout.strip()) == must_fire
    log.append('OBSERVED: registered executable stays silent before its date, emits exactly once when due, and does not mark a job seen.\n')
    run('fm-afk-main-outcome.sh','--task','working','--summary','Reviewed progress and left the active build running','--wake','signal: working.status')
    rows = [json.loads(line) for line in (HOME/'state'/'branch-outcomes.jsonl').read_text().splitlines()]
    assert len(rows) == 1 and rows[0]['silent'] is True and rows[0]['verdict'] == 'routine'
    run('fm-afk-main-outcome.sh','--task','working','--summary','Decision requested','--verdict','captain',codes=(2,))
    assert len((HOME/'state'/'branch-outcomes.jsonl').read_text().splitlines()) == 1
    log.append('PERSISTED PUBLIC OUTCOME STORE:\n'+(HOME/'state'/'branch-outcomes.jsonl').read_text())
    # The real return/drain only scans this disposable home; no daemon was launched.
    returned = run('fm-afk-return.sh','begin',codes=(0,3))
    section = returned.split('Not started:\n',1)[1].split('Cost:',1)[0]
    for expected in ['decision: bin/fm-tasks-axi.sh show decision','paused: bin/fm-peek.sh paused','finished: bin/fm-send.sh finished prepare the follow-up','working: bin/fm-peek.sh working']:
        assert expected in section, expected
    assert 'blocked:' not in section and 'blocked [key=dep]' in returned
    budget = run('fm-afk-return.sh','check',codes=(0,3),extra={'FM_AFK_NOT_STARTED_BUDGET':'100'})
    body = budget.split('Not started:\n',1)[1].split('Cost:',1)[0]
    command_lines = [line for line in body.splitlines() if line.startswith('  - ')]
    assert sum(len(line)+1 for line in command_lines) <= 100
    assert 'more not shown' in body
    log.append('OBSERVED: return names exact pending commands; open blocker remains in blockers; 100-character subsection budget omits excess rows.\n')
    (EVIDENCE/'away-cli-transcript.txt').write_text('\n'.join(log))
    print('Manual CLI scenarios complete; encoded captain-hold reason defect retained in transcript: '+str(EVIDENCE/'away-cli-transcript.txt'))
finally:
    (EVIDENCE/'away-cli-transcript.txt').write_text('\n'.join(log))
    shutil.rmtree(HOME)
