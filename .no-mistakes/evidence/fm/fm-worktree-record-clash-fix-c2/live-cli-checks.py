import os, pathlib, subprocess, tempfile, shutil, json, hashlib, time
ROOT=pathlib.Path.cwd()
EVIDENCE=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M5J1J041ZAMEAPEMVEM4AYB9')
LAB=pathlib.Path(tempfile.mkdtemp(prefix='.l', dir=ROOT))
LOG=(EVIDENCE/'live-cli-transcript.log').open('w')
results=[]
env=os.environ.copy()
for key in list(env):
    if key.startswith('FM_') or key in ('TMUX','TMUX_PANE','HERDR_ENV','HERDR_SESSION','CLAUDE_CONFIG_DIR'):
        env.pop(key,None)
env.update(TMPDIR=str(LAB), GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null',TMUX_TMPDIR=str(LAB/'tmux'))
(LAB/'tmux').mkdir()
(LAB/'user').mkdir()
env['HOME']=str(LAB/'user')

def run(args, expected=None, timeout=45, cwd=ROOT, logged=True, use_env=None):
    r=subprocess.run([str(a) for a in args],env=use_env or env,cwd=cwd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
    if logged:
        LOG.write('$ '+' '.join(map(str,args))+'\n'+r.stdout+f'[exit={r.returncode}]\n'); LOG.flush()
    if expected is not None: assert r.returncode==expected,(args,r.returncode,r.stdout)
    return r

def tmux(*args,expected=0):
    return run(['tmux','-L','fm-lab',*args],expected=expected)

def write(path,text):
    path.parent.mkdir(parents=True,exist_ok=True);path.write_text(text)

def meta(home,id,wt,proj,extra='',kind='scout'):
    p=home/'state'/f'{id}.meta'
    write(p,f'window=checks:fm-{id}\nendpoint_task_id={id}\nspawn_gen=live-check\nworktree={wt}\nproject={proj}\nkind={kind}\nharness=codex\n{extra}')
    return p

def setup(name):
    case=LAB/name; home=case/'home'; proj=case/'project'; wt=case/'pool'/'1'/'project'
    run(['bash',ROOT/'bin/fm-lab-home.sh','create',home],0)
    write(home/'config/backlog-backend','manual\n');write(home/'config/crew-harness','codex\n');write(home/'state/.last-watcher-beat','')
    run(['git','init','-q',proj],0,logged=False)
    run(['git','-C',proj,'-c','user.name=Validation','-c','user.email=validation@example.invalid','commit','--allow-empty','-qm','initial'],0,logged=False)
    wt.parent.mkdir(parents=True)
    run(['git','-C',proj,'worktree','add','-q','--detach',wt],0,logged=False)
    state=case/'pool/treehouse-state.json'
    write(state,json.dumps({'worktrees':[{'path':str(wt)}]}))
    write(wt/'sentinel','keep successor edits\n')
    write(home/'data/candidate/brief.md',"# Task\n## Captain's intent\nCheck isolated refusal.\n\n## Firstmate spec\nRefuse before acquiring a copy.\n")
    return home,proj,wt,state

def cli(home,script,*args):
    e=env.copy();e['FM_HOME']=str(home)
    return run(['bash',ROOT/'bin'/script,*args],use_env=e)

def preserved(paths):
    return {str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}

def note(text): LOG.write(text+'\n');LOG.flush()

def scenario(name,fn):
    note('\nSCENARIO: '+name)
    try:
        fn(); results.append({'name':name,'result':'pass','live':True,'evidence':'live-cli-transcript.log','reason':''});note('OBSERVED: scenario assertions satisfied')
    except Exception as ex:
        results.append({'name':name,'result':'fail','live':True,'evidence':'live-cli-transcript.log','reason':str(ex)});note('FAILED: '+repr(ex))

try:
    tmux('new-session','-d','-s','checks','-n','guard','-x','120','-y','40','-c',ROOT,'bash --noprofile --norc')
    socket=LAB/'tmux'/('tmux-'+str(os.getuid()))/'fm-lab'
    env['TMUX']=f'{socket},1,0'

    def retained():
        for shape in ('done','alias','registered'):
            h,p,w,s=setup('retained-'+shape); target=h
            if shape=='registered':
                target=h.parent/'mate';run(['bash',ROOT/'bin/fm-lab-home.sh','create',target],0)
                write(h/'data/secondmates.md',f'- mate - validation (home: {target}; scope: test; projects: project; added 2026-10-22)\n')
            path=w
            if shape=='alias':
                path=h.parent/'alias';path.symlink_to(w,target_is_directory=True)
            m=meta(target,'retained',path,p)
            write(target/'state/retained.status','done: report ready\n')
            before=preserved([m,s,w/'sentinel'])
            r=cli(h,'fm-spawn.sh','candidate',p,'--scout','--backend','tmux','--harness','codex')
            assert r.returncode!=0 and 'without a verified matching durable lease' in r.stdout,r.stdout
            assert 'No Treehouse allocation was attempted' in r.stdout,r.stdout
            assert preserved([m,s,w/'sentinel'])==before
            assert not (h/'state/candidate.meta').exists()
            assert not (h/'state/candidate.treehouse-acquire').exists()
            note(f'{shape}: retained record, pool JSON and dirty sentinel unchanged; no allocation journal or candidate record')
    scenario('Spawn refuses before allocation when a finished, aliased, or registered-home record names an unleased copy',retained)

    def scans():
        for shape in ('missing-home','missing-state','duplicate','unreadable'):
            h,p,w,s=setup('diagnostic-'+shape)
            if shape.startswith('missing'):
                mate=h.parent/'mate'
                if shape=='missing-state': mate.mkdir()
                write(h/'data/secondmates.md',f'- mate - validation (home: {mate}; scope: test; projects: project; added 2026-10-22)\n')
                expected='registered local Firstmate home is unavailable' if shape=='missing-home' else 'missing or unreadable local state directory'
            else:
                bad=h/'state/bad.meta'
                if shape=='duplicate': write(bad,'worktree=\nworktree=\n')
                else: bad.mkdir()
                expected='unreadable or ambiguous task record'
            r=cli(h,'fm-spawn.sh','candidate',p,'--scout','--backend','tmux','--harness','codex')
            assert r.returncode!=0 and 'REFUSED:' in r.stdout and expected in r.stdout,r.stdout
            assert not (h/'state/candidate.treehouse-acquire').exists()
    scenario('Spawn explains missing local-home state and ambiguous records before allocation',scans)

    def journal():
        h,p,w,s=setup('journal');j=h/'state/candidate.treehouse-acquire'
        write(j/'identity',f'project={p}\ntreehouse_lease_holder={h}/candidate/known-acquisition\n')
        write(j/'allocation.json','')
        before=preserved([j/'identity',j/'allocation.json',s,w/'sentinel'])
        r=cli(h,'fm-spawn.sh','candidate',p,'--scout','--backend','tmux','--harness','codex')
        assert r.returncode!=0 and 'retained Treehouse acquisition journal' in r.stdout,r.stdout
        for text in ('If no pool entry carries the recorded lease holder','no live task record in any local home','--if-lease-id','--if-lease-holder','Keep the journal and claim if return fails'):
            assert text in r.stdout,text
        assert before==preserved([j/'identity',j/'allocation.json',s,w/'sentinel'])
        note('Existing recovery identity and empty response preserved byte-for-byte; never-acquired and orphan-claim manual steps printed')
    scenario('Retry with an unresolved acquisition journal refuses and prints never-acquired and orphan-claim recovery',journal)

    def missing():
        h,p,w,s=setup('missing-copy');m=meta(h,'retained',w,p,'treehouse_lease_id=recorded-lease\ntreehouse_lease_holder=recorded-holder\n')
        j=h/'state/retained.treehouse-acquire';write(j/'identity',f'project={p}\ntreehouse_lease_id=recorded-lease\ntreehouse_lease_holder=recorded-holder\n')
        shutil.move(str(w),str(w.parent/'saved-copy'))
        before=preserved([m,s,j/'identity'])
        r=cli(h,'fm-teardown.sh','retained','--force')
        assert r.returncode!=0 and 'leased task copy is unavailable' in r.stdout,r.stdout
        for text in ('Manual recovery: pause allocations','Restore the original copy','Do not fabricate ownership evidence.','keep the records and lease and obtain operator reconciliation',f'fm-teardown.sh retained'):
            assert text in r.stdout,text
        assert before==preserved([m,s,j/'identity'])
        note('Missing-copy refusal keeps metadata, acquisition journal and pool state unchanged')
    scenario('Forced cleanup of a missing leased copy preserves ownership records and prints exact recovery steps',missing)

    def clash():
        h,p,w,s=setup('clash');claim=w.parent/'.fm-slot-owner'
        write(claim,f'task=successor\nhome={h}\n')
        write(s,json.dumps({'worktrees':[{'path':str(w),'leased':True,'lease_id':'successor-lease','lease_holder':f'{h}/successor/acquisition'}]}))
        owner=meta(h,'successor',w,p,f'treehouse_lease_id=successor-lease\ntreehouse_lease_holder={h}/successor/acquisition\n')
        stale=meta(h,'stale',w,p)
        tmux('new-window','-d','-t','checks:','-n','fm-successor','-c',w,'bash --noprofile --norc')
        tmux('new-window','-d','-t','checks:','-n','fm-stale','-c',p,'bash --noprofile --norc')
        worker=subprocess.Popen(['sleep','240'],cwd=w,env=env)
        try:
            before=preserved([s,claim,owner,w/'sentinel'])
            r=cli(h,'fm-teardown.sh','successor','--force')
            assert r.returncode!=0 and 'stale' in r.stdout and 'REFUSED:' in r.stdout,r.stdout
            assert stale.exists() and before==preserved([s,claim,owner,w/'sentinel'])
            assert worker.poll() is None
            tmux('has-session','-t','checks:fm-successor')
            note('Owner-first cleanup refused; successor process and window still alive; successor copy, lease, claim and metadata unchanged')
            r=cli(h,'fm-teardown.sh','stale','--force')
            assert r.returncode==0 and 'reassigned' in r.stdout and 'left untouched' in r.stdout,r.stdout
            assert not stale.exists() and before==preserved([s,claim,owner,w/'sentinel'])
            assert worker.poll() is None
            tmux('has-session','-t','checks:fm-successor')
            note('Stale metadata retired; successor process and window still alive; successor copy, lease, claim and metadata unchanged')
        finally:
            worker.terminate();worker.wait(timeout=5)
    scenario('Owner-first cleanup refuses, then stale-record cleanup leaves the successor copy, process, endpoint, claim and lease untouched',clash)

    def unsafe_claim():
        h,p,w,s=setup('unsafe-claim');m=meta(h,'retained',w,p)
        claim=w.parent/'.fm-slot-owner';write(claim,'invalid claim\n')
        before=preserved([m,s,claim,w/'sentinel'])
        r=cli(h,'fm-teardown.sh','retained','--force')
        assert r.returncode!=0 and 'slot-owner claim that cannot be read' in r.stdout,r.stdout
        assert before==preserved([m,s,claim,w/'sentinel'])
        note('Force did not override unreadable claim; record, copy and ownership evidence unchanged')
    scenario('Forced cleanup cannot bypass an unreadable slot-owner claim',unsafe_claim)
finally:
    run(['tmux','-L','fm-lab','kill-server'],logged=True)
    shutil.rmtree(LAB)
    note('CLEANUP: private tmux server stopped; all disposable lab homes and Git copies removed')
    (EVIDENCE/'live-scenarios.json').write_text(json.dumps(results,indent=2)+'\n')
    LOG.close()
print(json.dumps(results,indent=2))
