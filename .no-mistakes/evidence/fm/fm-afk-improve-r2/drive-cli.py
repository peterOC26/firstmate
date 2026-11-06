import os, pathlib, subprocess, hashlib, json, shutil
R=pathlib.Path.cwd(); E=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M6Q1S6BCZ3DT0QKMCSE7DG31'); H=R/'.l'
base=os.environ.copy()
for k in ('FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_TEST_SEAM','FM_TEST_HARNESS'):
    base.pop(k,None)
base['FM_HOME']=str(H); base['TMPDIR']=str(R/'.test-tmp'); base['LC_ALL']='C.utf8'
f=(E/'cli-live.txt').open('w')
def run(args, *, env=None, ok=(0,), cwd=R):
    p=subprocess.run([str(a) for a in args], cwd=cwd,env=env or base,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=45)
    f.write('$ '+ ' '.join(str(a) for a in args)+'\n'+p.stdout+f'\n[exit {p.returncode}]\n'); f.flush()
    assert p.returncode in ok,(args,p.returncode,p.stdout)
    return p.stdout

def axi(*args): return run(['tasks-axi',*args,'--file','data/backlog.md'],cwd=H)
def script(n,*args,env=None,ok=(0,)): return run([R/'bin'/n,*args],env=env,ok=ok)
def meta(id,text):
    (H/'state'/f'{id}.meta').write_text(f'window=lab:{id}\nbackend=tmux\nkind=ship\n')
    (H/'state'/f'{id}.status').write_text(text+'\n')
def snapshot():
    return {str(p.relative_to(H)):hashlib.sha256(p.read_bytes()).hexdigest() for root in ('data','state') for p in (H/root).rglob('*') if p.is_file()}
try:
    script('fm-lab-home.sh','create',H)
    shutil.copyfile(R/'.tasks.toml',H/'.tasks.toml')
    (H/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    (H/'config/supervision-host-off').touch()
    f.write('\n=== Healthy empty backlog ===\n')
    s=snapshot(); out=script('fm-afk-entry-brief.sh'); assert 'entry inventory:' not in out
    assert script('fm-afk-entry-brief.sh','not-started')==''
    out=script('fm-afk-return.sh','check'); assert 'Not started:\n  (nothing)' in out and 'entry inventory:' not in out
    f.write('\n=== Inventory with gates and read-only proof ===\n')
    for id in ('done-job','queued-job','hold-job','dated-job','future-job','retired-job','short-job','cut-job','complete-job','status-job'):
        axi('add',id,id)
    axi('block','queued-job','--by','done-job'); axi('done','done-job','--note','landed')
    axi('done','retired-job','--note','landed')
    script('fm-captain-hold.sh','hold','hold-job','--reason','Choose the public name')
    axi('hold','dated-job','--reason','earlier','--kind','future','--until','2026-11-01')
    axi('hold','future-job','--reason','later','--kind','future','--until','2026-12-01')
    meta('blocked-job','blocked [at=100] [key=dep]: waiting\nNext: bin/fm-send.sh blocked-job continue')
    meta('green-job','done: https://github.com/example/repo/pull/9 checks green')
    meta('failed-job','failed: one\nfailed check: two\ncheck failed: three')
    for id in ('short-job','cut-job','complete-job','status-job'): meta(id,'working: building')
    axi('update','short-job','--body','Next: bin/fm-send.sh short-job continue')
    padding='0'*480
    axi('update','cut-job','--body',padding+'\nNext: bin/fm-send.sh cut-job please continue the work')
    axi('update','complete-job','--body','Next: bin/fm-send.sh complete-job continue\n'+padding+' trailing text')
    axi('update','status-job','--body',padding+'\nNext: bin/fm-send.sh status-job cut body command')
    meta('status-job','working: building\nNext: bin/fm-send.sh status-job café')
    listing=axi('list','--fields','body'); assert '... (truncated,' in listing
    s=snapshot(); out=script('fm-afk-entry-brief.sh'); assert s==snapshot()
    for text in ('queued-job: blocked-by done-job is done','hold-job: Choose the public name','green-job: https://github.com/example/repo/pull/9','dated-job: hold until 2026-11-01','future-job: hold until 2026-12-01','failed-job: 3 consecutive failed checks'):
        assert text in out,text
    assert not list((H/'state').glob('*.check.sh'))
    f.write('Read-only proof: data/state file paths and SHA-256 contents identical before and after inventory. No future check registered by inventory.\n')
    f.write('\n=== Exact next commands and truncation ===\n')
    out=script('fm-afk-entry-brief.sh','not-started')
    assert 'cut-job:' not in out and 'blocked-job:' not in out and 'retired-job:' not in out
    for text in ('bin/fm-send.sh complete-job continue','bin/fm-send.sh short-job continue','bin/fm-send.sh status-job café'):
        assert out.count(text)==1,text
    f.write('\n=== Entry records words then prints inventory; replaces words verbatim ===\n')
    words='A green PR may merge only with my explicit sentence. Await the slower advisory suite. Stop after three failed checks.'
    out=script('fm-afk-launch.sh','enter','--words',words)
    assert 'Read-back checklist:' in out
    assert words in (H/'state/.afk-contract').read_text()
    out=script('fm-afk-launch.sh','enter','--words','Stop after three failed checks.')
    assert 'Stop after three failed checks.' in (H/'state/.afk-contract').read_text()
    f.write('\n=== Future-date opt-in and one-shot behavior ===\n')
    before=(H/'data/backlog.md').read_bytes()
    out=script('fm-afk-entry-brief.sh','--register-future','dated-job'); assert 'already due' in out
    assert not (H/'state/fm-afk-future-dated-job.check.sh').exists()
    out=script('fm-afk-entry-brief.sh','--register-future','future-job'); assert 'registered:' in out
    assert script('fm-afk-entry-brief.sh','future-check','future-job')==''
    due=base.copy(); due['FM_AFK_ENTRY_TODAY']='2026-12-01'
    out=script('fm-afk-entry-brief.sh','future-check','future-job',env=due); assert 'is due' in out
    assert script('fm-afk-entry-brief.sh','future-check','future-job',env=due)==''
    assert before==(H/'data/backlog.md').read_bytes()
    assert not list((H/'state').glob('*.seen*'))
    f.write('\n=== Silent routine outcome and rejected authority expansion ===\n')
    script('fm-afk-main-outcome.sh','--task','short-job','--summary','Reviewed the next action','--wake','signal: short-job.status')
    rows=[json.loads(x) for x in (H/'state/branch-outcomes.jsonl').read_text().splitlines()]
    assert rows[-1]['verdict']=='routine' and rows[-1]['silent'] is True
    f.write((H/'state/branch-outcomes.jsonl').read_text()+'\n')
    n=len(rows)
    script('fm-afk-main-outcome.sh','--task','short-job','--summary','request authority','--verdict','captain',ok=(2,))
    assert len((H/'state/branch-outcomes.jsonl').read_text().splitlines())==n
    f.write('\n=== Return preserves blockers and omits them from Not started ===\n')
    out=script('fm-afk-return.sh','begin',ok=(3,)); section=out.split('Not started:\n')[1].split('Cost:')[0]
    assert 'blocked-job:' not in section and 'cut-job:' not in section
    assert section.count('bin/fm-send.sh short-job continue')==1
    with (H/'state/blocked-job.status').open('a') as p:p.write('resolved [key=dep]: recovered\n')
    script('fm-afk-return.sh','check')
    f.write('\n=== UTF-8 byte budget including newline; skip long line and admit shorter ===\n')
    for p in (H/'state').glob('*.meta'):p.unlink()
    meta('a-job','working: building\nNext: bin/fm-send.sh a-job café')
    meta('z-job','working: building\nNext: bin/go')
    line='  - a-job: bin/fm-send.sh a-job café'; size=len((line+'\n').encode())
    for budget in (size-1,size,1):
        env=base.copy(); env['FM_AFK_NOT_STARTED_BUDGET']=str(budget)
        out=script('fm-afk-return.sh','check',env=env); section=out.split('Not started:\n')[1].split('Cost:')[0]
        lines=[x for x in section.splitlines() if x.startswith('  - ')]
        assert sum(len((x+'\n').encode()) for x in lines)<=budget
        assert (line in lines)==(budget==size)
        if budget==size-1: assert '  - z-job: bin/go' in lines
        f.write(f'Measured emitted command bytes: {sum(len((x+chr(10)).encode()) for x in lines)}; configured budget: {budget}; multibyte line requires: {size}\n')
    f.write('\n=== Unreadable backlog preserves exit 0 and does not invent an empty list ===\n')
    old=(H/'data/backlog.md').read_bytes(); os.chmod(H/'data/backlog.md',0)
    out=script('fm-afk-entry-brief.sh'); assert 'backlog file is unreadable' in out
    out=script('fm-afk-entry-brief.sh','not-started'); assert 'backlog file is unreadable' in out
    os.chmod(H/'data/backlog.md',0o644); assert old==(H/'data/backlog.md').read_bytes()
    f.write('\n=== Quiet entry omits away inventory ===\n')
    env=base.copy(); env['FM_AFK_MODE']='quiet'
    out=script('fm-afk-launch.sh','enter','--words','stay quiet',env=env); assert 'Read-back checklist:' not in out
    script('fm-afk-return.sh','begin')
    f.write('\nAll direct CLI scenarios passed; no mocked executable was used. Metadata and backlog records were seeded in the disposable lab; no fleet endpoint or forge operation was performed.\n')
finally:
    shutil.rmtree(H,ignore_errors=True); f.write('Disposable CLI lab removed.\n'); f.close()
