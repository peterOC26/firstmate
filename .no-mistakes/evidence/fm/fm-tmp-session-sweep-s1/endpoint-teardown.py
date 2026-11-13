import os, re, json, shutil, subprocess, time
from pathlib import Path
ROOT=Path.cwd()
E=Path('/home/zabi/.no-mistakes/evidence/01M79349T4PAQCW9F2AWM82KWT')
BASE=ROOT/'.phase-tmp/ep'
BASE.mkdir(parents=True,exist_ok=True)
CODE=BASE/'code-base'; CODE.mkdir(exist_ok=True)
shutil.copytree(ROOT/'bin',CODE/'bin',dirs_exist_ok=True)
shutil.copy2(ROOT/'.tasks.toml',CODE/'.tasks.toml')
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k in ('TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','HERDR_ENV','HERDR_SOCKET_PATH','HERDR_PANE_ID','REX_SESSION','REX_BLOCK'))}
env['TMPDIR']=str(BASE)
env['TMUX']=str(BASE/'s')+',0,0'
LOG=(E/'endpoint-teardown.log').open('w')
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

socket=BASE/'s'
try:
    run(['tmux','-S',socket,'-f','/dev/null','new-session','-d','-s','fm-lab-sweep','-n','keeper','-x','120','-y','40','-c',ROOT,'sleep 300'])
    for name in ['mate-success','mate-home-denied','mate-refused-live']:
        c,h,t,e=setup(name); worker=c/'worker-home'
        for child in ['state','data','config','projects']: (worker/child).mkdir(parents=True,exist_ok=True)
        (worker/'.fm-secondmate-home').write_text('task-live\n')
        own=plant(t,worker); other=plant(t,c/'unrelated-worker')
        run(['tmux','-S',socket,'new-window','-d','-t','fm-lab-sweep','-n','fm-task-live','-c',worker,'sleep 300'])
        pid=int(run(['tmux','-S',socket,'display-message','-p','-t','fm-lab-sweep:fm-task-live','#{pane_pid}']).stdout)
        assert Path('/proc',str(pid)).exists()
        LOG.write(f'BEFORE: endpoint pid {pid} exists; session output exists = {(own/"session/output.txt").exists()}\n')
        meta(h,worker,c/'project',kind='secondmate',extra={'home':str(worker)})
        expected=0
        if name=='mate-refused-live':
            (worker/'state/child.meta').write_text('kind=ship\nworktree=/unavailable-lab-child\n'); expected=1
        if name=='mate-home-denied': worker.chmod(0o555); expected=1
        r=teardown(h,e)
        if worker.exists(): worker.chmod(0o755)
        alive=run(['tmux','-S',socket,'has-session','-t','fm-lab-sweep:fm-task-live'],check=False).returncode==0
        # has-session scopes sessions, so inspect exact window membership separately.
        windows=run(['tmux','-S',socket,'list-windows','-t','fm-lab-sweep','-F','#{window_name}']).stdout.splitlines()
        alive='fm-task-live' in windows
        LOG.write(f'AFTER: endpoint window exists = {alive}; original pid exists = {Path("/proc",str(pid)).exists()}\n')
        record(name,r,{'expected exit':r.returncode==expected,'home removed only on success':worker.exists()==(expected!=0),'temp removed only on success':own.exists()==(expected!=0),'endpoint preserved on early refusal only':alive==(name=='mate-refused-live'),'unrelated preserved':(other/'session/output.txt').is_file(),'record removed only on success':(h/'state/task-live.meta').exists()==(expected!=0)})
        if alive: run(['tmux','-S',socket,'kill-window','-t','fm-lab-sweep:fm-task-live'])
finally:
    run(['tmux','-S',socket,'kill-server'],check=False)
    (E/'endpoint-results.json').write_text(json.dumps(results,indent=2)+'\n')
    LOG.close()
    shutil.rmtree(BASE)
