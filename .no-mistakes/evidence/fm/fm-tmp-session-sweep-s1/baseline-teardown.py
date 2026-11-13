import os, re, json, shutil, subprocess, time
from pathlib import Path
ROOT=Path.cwd()
E=Path('/home/zabi/.no-mistakes/evidence/01M79349T4PAQCW9F2AWM82KWT')
BASE=ROOT/'.phase-tmp/baseline'
BASE.mkdir(parents=True,exist_ok=True)
CODE=BASE/'code-base'; CODE.mkdir(exist_ok=True)
shutil.copytree(ROOT/'bin',CODE/'bin',dirs_exist_ok=True)
shutil.copy2(ROOT/'.tasks.toml',CODE/'.tasks.toml')
(CODE/'bin/fm-teardown.sh').write_bytes(subprocess.check_output(['git','show','c9d779b114d28b10015870a74b49b819fac530bc:bin/fm-teardown.sh']))
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k in ('TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','HERDR_ENV','HERDR_SOCKET_PATH','HERDR_PANE_ID','REX_SESSION','REX_BLOCK'))}
env['TMPDIR']=str(BASE)
env['TMUX']=str(BASE/'s')+',0,0'
LOG=(E/'baseline-teardown.log').open('w')
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

finally:
    (E/'baseline-results.json').write_text(json.dumps(results,indent=2)+'\n')
    LOG.close()
    shutil.rmtree(BASE)
