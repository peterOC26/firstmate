import os, re, json, shutil, subprocess, time
from pathlib import Path
ROOT=Path.cwd()
E=Path('/home/zabi/.no-mistakes/evidence/01M79349T4PAQCW9F2AWM82KWT')
BASE=ROOT/'.phase-tmp/live'
BASE.mkdir(parents=True,exist_ok=True)
CODE=BASE/'code-base'; CODE.mkdir(exist_ok=True)
shutil.copytree(ROOT/'bin',CODE/'bin',dirs_exist_ok=True)
shutil.copy2(ROOT/'.tasks.toml',CODE/'.tasks.toml')
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k in ('TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','HERDR_ENV','HERDR_SOCKET_PATH','HERDR_PANE_ID','REX_SESSION','REX_BLOCK'))}
env['TMPDIR']=str(BASE)
env['TMUX']=str(BASE/'s')+',0,0'
LOG=(E/'live-teardown.log').open('w')
results=[]
def run(args,cwd=ROOT,e=None,check=True):
    LOG.write('$ '+ ' '.join(map(str,args))+'\n'); LOG.flush()
    r=subprocess.run(list(map(str,args)),cwd=cwd,env=e or env,text=True,capture_output=True,timeout=90)
    LOG.write(r.stdout+r.stderr+f'[exit {r.returncode}]\n'); LOG.flush()
    if check and r.returncode: raise RuntimeError(r.stdout+r.stderr)
    return r
run(['git','init','-q','-b','main',CODE])
run(['git','-C',CODE,'-c','user.name=Test','-c','user.email=test@example.invalid','commit','-q','--allow-empty','-m','lab baseline'])
def setup(name):
    c=BASE/name; c.mkdir(exist_ok=True); h=c/'home'
    run([ROOT/'bin/fm-lab-home.sh','create',h])
    t=c/'tmp'; t.mkdir(); e=dict(env,FM_HOME=str(h),FM_CLAUDE_TEMP_ROOT=str(t),TREEHOUSE_ROOT=str(c/'pool'))
    return c,h,t,e

def plant(t,wt):
    slug=re.sub('[^A-Za-z0-9]','-',str(wt).rstrip('/'))
    d=t/f'claude-{os.getuid()}'/slug
    (d/'session').mkdir(parents=True)
    (d/'session/output.txt').write_bytes(b'worker output\n'*8192)
    return d

def meta(h,wt,project,kind='ship',extra=None):
    data=dict(window='fm-lab-sweep:fm-task-live',endpoint_task_id='task-live',backend='tmux',worktree=str(wt),project=str(project),kind=kind,mode='local-only',spawn_gen='live-test-session')
    data.update(extra or {})
    (h/'state/task-live.meta').write_text(''.join(f'{k}={v}\n' for k,v in data.items()))
    (h/'state/.last-watcher-beat').touch()

def teardown(h,e):
    return run([CODE/'bin/fm-teardown.sh','task-live'],e=e,check=False)

def record(name,r,checks):
    for desc,ok in checks.items(): LOG.write(f'OBSERVED {desc}: {ok}\n')
    passed=all(checks.values())
    results.append(dict(name=name,result='pass' if passed else 'fail',live=True,evidence='live-teardown.log',reason=''))
    LOG.flush()

try:
    # A genuine leased Treehouse worktree, clean and with no new commits.
    c,h,t,e=setup('retired'); p=c/'project'
    run(['git','init','-q','-b','main',p],e=e)
    run(['git','-C',p,'-c','user.name=Test','-c','user.email=test@example.invalid','commit','-q','--allow-empty','-m','landed baseline'],e=e)
    lease=json.loads(run(['treehouse','get','--lease','--json','--lease-holder','task-live','--no-fetch'],cwd=p,e=e).stdout)
    LOG.write('lease='+json.dumps(lease)+'\n'); LOG.flush()
    wt=Path(lease['path'])
    run(['bash','-c','. "$1/bin/fm-wake-lib.sh"; fm_treehouse_slot_owner_claim "$2" task-live "$3"','claim',CODE,wt,h],e=e)
    meta(h,wt,p,extra={'treehouse_lease_id':lease['lease_id'],'treehouse_lease_holder':lease['lease_holder']})
    own=plant(t,wt); other=plant(t,c/'other-task'); parent=own.parent
    r=teardown(h,e)
    record('Clean up a retired worker: its own temp disappears, another task and the parent remain, and freed bytes are reported',r,{'exit 0':r.returncode==0,'own removed':not own.exists(),'other preserved':(other/'session/output.txt').is_file(),'parent preserved':parent.is_dir(),'freed bytes reported':'removed claude session temp for task-live (' in r.stderr,'task record retired':not (h/'state/task-live.meta').exists()})

    for name in ['missing','relative','symlink','parent-symlink','invalid-root','long-path','protected','refused','removal-denied']:
        c,h,t,e=setup(name); wt=c/'finished-worker'; project=c/'project'
        if name=='relative': wt='relative/wt'
        if name=='long-path': wt=c/('a'*110)
        if name=='protected': wt=BASE/'code_base' # absent alias with the code root's protected slug
        own=plant(t,wt); other=plant(t,c/'unrelated-worker')
        expected=0; warning=''; preserve=True
        if name=='missing': shutil.rmtree(own); preserve=False
        if name=='removal-denied':
            (own/'session').chmod(0o555); warning='could not remove claude session temp for task-live'
        if name=='relative': warning='could not derive the claude session slug'
        if name=='long-path': warning='could not derive the claude session slug'
        if name=='protected': warning='is the firstmate home or primary checkout'
        if name=='symlink':
            target=c/'symlink-target'; own.rename(target); own.symlink_to(target,target_is_directory=True); warning='is a symlink'
        if name=='parent-symlink':
            parent=own.parent; target=c/'claude-parent'; parent.rename(target); parent.symlink_to(target,target_is_directory=True); warning='is not a real directory'
        if name=='invalid-root': e['FM_CLAUDE_TEMP_ROOT']='relative-tmp'; warning='FM_CLAUDE_TEMP_ROOT is not absolute'
        if name=='refused':
            run(['git','init','-q','-b','main',wt],e=e)
            run(['git','-C',wt,'-c','user.name=Test','-c','user.email=test@example.invalid','commit','-q','--allow-empty','-m','baseline'],e=e)
            (wt/'uncommitted.txt').write_text('preserve uncommitted work\n'); project=wt; expected=1; warning='REFUSED'
        meta(h,wt,project)
        r=teardown(h,e)
        if name=='removal-denied': (own/'session').chmod(0o755)
        record(name,r,{'expected exit':r.returncode==expected,'required warning':warning in r.stderr,'temp preserved or absent as expected':(own/'session/output.txt').exists()==preserve,'unrelated preserved':(other/'session/output.txt').is_file(),'no false removal line':'removed claude session temp' not in r.stderr,'task record retirement':(h/'state/task-live.meta').exists()==(expected!=0)})
    for name in ['mate-success','mate-home-denied','mate-refused-live']:
        c,h,t,e=setup(name); worker=c/'worker-home'
        for child in ['state','data','config','projects']: (worker/child).mkdir(parents=True,exist_ok=True)
        (worker/'.fm-secondmate-home').write_text('task-live\n')
        own=plant(t,worker); other=plant(t,c/'unrelated-worker')
        meta(h,worker,c/'project',kind='secondmate',extra={'home':str(worker)})
        expected=0
        # A secondmate with an unsafe local child is refused while its endpoint stays alive.
        if name=='mate-refused-live':
            (worker/'state/child.meta').write_text('kind=ship\nworktree=/unavailable-lab-child\n')
            expected=1
        if name=='mate-home-denied': worker.chmod(0o555); expected=1
        r=teardown(h,e)
        if worker.exists(): worker.chmod(0o755)
        record(name,r,{'expected exit':r.returncode==expected,'home removed only on success':worker.exists()==(expected!=0),'temp removed only on success':own.exists()==(expected!=0),'unrelated preserved':(other/'session/output.txt').is_file(),'record removed only on success':(h/'state/task-live.meta').exists()==(expected!=0)})
finally:
    (E/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
    LOG.close()
    shutil.rmtree(BASE)
