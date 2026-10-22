import os, pathlib, subprocess, tempfile, shutil, json, hashlib, time
ROOT=pathlib.Path.cwd()
EVIDENCE=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M5J1J041ZAMEAPEMVEM4AYB9')
LAB=pathlib.Path(tempfile.mkdtemp(prefix='.l', dir=ROOT))
LOG=(EVIDENCE/'live-relaunch-transcript.log').open('w')
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
        fn(); results.append({'name':name,'result':'pass','live':True,'evidence':'live-relaunch-transcript.log','reason':''});note('OBSERVED: scenario assertions satisfied')
    except Exception as ex:
        results.append({'name':name,'result':'fail','live':True,'evidence':'live-relaunch-transcript.log','reason':str(ex)});note('FAILED: '+repr(ex))

try:
    tmux('new-session','-d','-s','checks','-n','guard','-x','120','-y','40','-c',ROOT,'bash --noprofile --norc')
    socket=LAB/'tmux'/('tmux-'+str(os.getuid()))/'fm-lab'
    env['TMUX']=f'{socket},1,0'

    def relaunch_refusals():
        for shape in ('lease-mismatch','stale-claim','shared-record','missing-home','missing-state','ambiguous'):
            h,p,w,s=setup('relaunch-'+shape)
            task='task-'+shape
            m=meta(h,task,w,p,f'treehouse_lease_id=recorded-lease\ntreehouse_lease_holder=recorded-holder\n')
            claim=w.parent/'.fm-slot-owner'
            write(claim,f'task={task}\nhome={h}\n')
            lease_id='other-lease' if shape=='lease-mismatch' else 'recorded-lease'
            write(s,json.dumps({'worktrees':[{'path':str(w),'leased':True,'lease_id':lease_id,'lease_holder':'recorded-holder'}]}))
            if shape=='stale-claim': write(claim,f'task=successor\nhome={h}\n')
            if shape=='shared-record': meta(h,'stale',w,p)
            if shape.startswith('missing'):
                mate=h.parent/'mate'
                if shape=='missing-state': mate.mkdir()
                write(h/'data/secondmates.md',f'- mate - validation (home: {mate}; scope: test; projects: project; added 2026-10-22)\n')
            if shape=='ambiguous': write(h/'state/bad.meta','worktree=\nworktree=\n')
            tmux('new-window','-d','-t','checks:','-n','fm-'+task,'-c',w,'bash --noprofile --norc')
            before=preserved([m,s,claim,w/'sentinel'])
            panes=tmux('list-windows','-t','checks','-F','#{window_id}|#{window_name}|#{pane_current_path}|#{pane_pid}').stdout
            r=cli(h,'fm-spawn.sh',task,'--relaunch','--harness','codex')
            expected={'lease-mismatch':'durable lease cannot be verified','stale-claim':'not claimed by this home and task','shared-record':'also names pool copy','missing-home':'registered local Firstmate home is unavailable','missing-state':'missing or unreadable local state directory','ambiguous':'unreadable or ambiguous task record'}[shape]
            assert r.returncode!=0 and expected in r.stdout,(shape,r.stdout)
            assert before==preserved([m,s,claim,w/'sentinel'])
            assert panes==tmux('list-windows','-t','checks','-F','#{window_id}|#{window_name}|#{pane_current_path}|#{pane_pid}').stdout
            note(shape+': relaunch refused with cause; metadata, lease, claim, dirty copy, pane PID and cwd unchanged')
    scenario('Relaunch refuses stale leases, claims, duplicate ownership and unreadable local-home records before endpoint mutation',relaunch_refusals)

    def lease_cleanup():
        h,p,w,s=setup('mismatched-cleanup');task='lease-cleanup'
        m=meta(h,task,w,p,'treehouse_lease_id=recorded-lease\ntreehouse_lease_holder=recorded-holder\n')
        claim=w.parent/'.fm-slot-owner';write(claim,f'task={task}\nhome={h}\n')
        write(s,json.dumps({'worktrees':[{'path':str(w),'leased':True,'lease_id':'successor-lease','lease_holder':'successor-holder'}]}))
        write(w/'.claude/settings.local.json','{"keep":"hook"}\n')
        tmux('new-window','-d','-t','checks:','-n','fm-'+task,'-c',w,'bash --noprofile --norc')
        before=preserved([m,s,claim,w/'sentinel',w/'.claude/settings.local.json'])
        r=cli(h,'fm-teardown.sh',task,'--force')
        assert r.returncode!=0 and 'durable lease identity or holder does not match' in r.stdout,r.stdout
        assert before==preserved([m,s,claim,w/'sentinel',w/'.claude/settings.local.json'])
        tmux('has-session','-t','checks:fm-'+task)
        note('Forced mismatched-lease cleanup refused; endpoint, hook, dirty copy, claim, pool lease and task record preserved')
    scenario('Forced cleanup validates the exact lease before killing an endpoint or changing hooks and scratch files',lease_cleanup)

    def unlanded():
        h,p,w,s=setup('unlanded');task='unlanded'
        m=meta(h,task,w,p,'mode=local-only\nyolo=off\n',kind='ship')
        before=preserved([m,s,w/'sentinel'])
        r=cli(h,'fm-teardown.sh',task)
        assert r.returncode!=0 and 'REFUSED: local-only worktree' in r.stdout,r.stdout
        assert before==preserved([m,s,w/'sentinel'])
        note('An unclaimed legacy copy with dirty unlanded work retained both the record and edits')
    scenario('Records-only cleanup of an unclaimed legacy ship still refuses dirty unlanded work',unlanded)

    def cli_contract():
        r=run(['treehouse','--version'],0)
        assert 'v2.3.0' in r.stdout,r.stdout
        r=run(['treehouse','get','--help'],0)
        for flag in ('--lease','--lease-holder','--json'): assert flag in r.stdout
        r=run(['treehouse','return','--help'],0)
        for flag in ('--if-lease-id','--if-lease-holder'): assert flag in r.stdout
        note('Installed Treehouse v2.3.0 advertises JSON durable acquisition and both conditional-release guards; no pool operation invoked')
    scenario('The installed Treehouse version supports JSON leases and identity-conditional return',cli_contract)
finally:
    run(['tmux','-L','fm-lab','kill-server'],logged=True)
    shutil.rmtree(LAB)
    note('CLEANUP: private tmux server stopped; all disposable lab homes and Git copies removed')
    (EVIDENCE/'live-relaunch-scenarios.json').write_text(json.dumps(results,indent=2)+'\n')
    LOG.close()
print(json.dumps(results,indent=2))
