import os, subprocess, tempfile, pathlib, json, time, shlex, shutil, tomllib
ROOT=pathlib.Path.cwd()
E=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M45JK2T8YBWNQFKRGCB50VWY')
lab=pathlib.Path(tempfile.mkdtemp(prefix='.l', dir=ROOT))
log=open(E/'live-away-relaunch.log','w',buffering=1)
env=os.environ.copy()
for k in list(env):
    if k.startswith(('FM_', 'HERDR_', 'TASKS_AXI_')) or k in ['TMUX','CLAUDECODE','PI_CODING_AGENT','GROK_AGENT']:
        env.pop(k,None)
env.update(FM_HOME=str(lab),TMPDIR=str(lab),TMUX_TMPDIR=str(lab/'tmux'),DISABLE_AUTOUPDATER='1')
results=[]
def run(args, check=True, timeout=60, local_env=None):
    p=subprocess.run([str(a) for a in args],env=local_env or env,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
    log.write('$ '+shlex.join([str(a) for a in args])+'\n'+p.stdout+'\nexit='+str(p.returncode)+'\n')
    if check and p.returncode: raise RuntimeError(p.stdout)
    return p

def tm(*args, **kw): return run(['tmux','-L','fm-lab',*args],**kw)
def capture(label,target):
    p=tm('capture-pane','-p','-t',target,'-S','-80')
    (E/(label+'.txt')).write_text(p.stdout)
    return p.stdout

def await_text(target,token,label,wait=90):
    until=time.monotonic()+wait
    while time.monotonic()<until:
        p=subprocess.run(['tmux','-L','fm-lab','capture-pane','-p','-t',target,'-S','-80'],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        if any(line.strip().removeprefix('• ').strip()==token for line in p.stdout.splitlines()): return capture(label,target)
        if any(t in p.stdout for t in ['Sign in with','rate limit exceeded','authentication failed']):
            capture(label,target); raise RuntimeError('CLI login or quota unavailable')
        time.sleep(1)
    capture(label,target); raise RuntimeError('Timed out waiting for '+token)

def result(name,passed,detail):
    results.append(dict(name=name,result='pass' if passed else 'fail',live=True,detail=detail))
    log.write('SCENARIO '+json.dumps(results[-1])+'\n')
    if not passed: raise RuntimeError(detail)
try:
    run([ROOT/'bin/fm-lab-home.sh','create',lab])
    (lab/'tmux').mkdir()
    (lab/'config/supervision-host').touch()
    # Use the existing genuine account in disposable per-run CLI storage.
    # The original credential and user configuration are read only.
    normal_codex=pathlib.Path(os.environ.get('CODEX_HOME',str(pathlib.Path.home()/'.codex')))
    codex_home=lab/'codex'
    codex_home.mkdir(mode=0o700)
    shutil.copyfile(normal_codex/'auth.json',codex_home/'auth.json')
    (codex_home/'auth.json').chmod(0o600)
    model=tomllib.loads((normal_codex/'config.toml').read_text()).get('model','gpt-5.4')
    (codex_home/'config.toml').write_text('model = '+json.dumps(model)+'\nmodel_reasoning_effort = "low"\n[projects.'+json.dumps(str(ROOT))+']\ntrust_level = "trusted"\n[projects.'+json.dumps(str(lab/'project'))+']\ntrust_level = "trusted"\n')
    env['CODEX_HOME']=str(codex_home)
    # The real CLI primary uses this lab's own socket; size is set before launch.
    primary_env=env.copy()
    primary_env.pop('NO_MISTAKES_GATE',None)
    tm('new-session','-d','-x','120','-y','40','-s','primary','-c',ROOT,'-e','FM_HOME='+str(lab),'codex --disable hooks --dangerously-bypass-approvals-and-sandbox', local_env=primary_env)
    env['TMUX']=tm('display-message','-p','-t','primary','#{socket_path},#{pid},0').stdout.strip()
    time.sleep(4)
    capture('primary-startup','primary')
    # Real backlog, record, git checkout and worker pane for an existing task.
    proj=lab/'project'; wt=lab/'worker'
    run(['git','init','-q',proj])
    (proj/'seed.txt').write_text('fixture project\n')
    run(['git','-C',proj,'add','seed.txt'])
    run(['git','-C',proj,'-c','user.name=Live Test','-c','user.email=live-test@example.invalid','commit','-qm','fixture'])
    run(['git','-C',proj,'worktree','add','-qb','fixture-worker',wt])
    (wt/'preserved.txt').write_text('unfinished stage work must survive\n')
    (lab/'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
    run([ROOT/'bin/fm-tasks-axi.sh','add','awayfresh','fresh In-flight row','--kind','ship'])
    run([ROOT/'bin/fm-tasks-axi.sh','start','awayfresh'])
    run([ROOT/'bin/fm-afk-contract.sh','enter','--spend','1','--words','you can move to other stages'])
    branch_env=env.copy(); branch_env['FM_SUPERVISION_ACTOR']='branch'
    before_windows=tm('list-windows','-t','primary','-F','#{window_id}:#{window_name}').stdout
    p=run([ROOT/'bin/fm-spawn.sh','awayfresh',proj,'--harness','codex','--mode','no-mistakes','--yolo','off'],check=False,local_env=branch_env)
    after_windows=tm('list-windows','-t','primary','-F','#{window_id}:#{window_name}').stdout
    row=run([ROOT/'bin/fm-tasks-axi.sh','show','awayfresh']).stdout
    result('Fresh away dispatch refuses an In-flight row without creating a worker',p.returncode==1 and 'queued unblocked work' in p.stdout and before_windows==after_windows and not (lab/'state/awayfresh.meta').exists() and 'state: in_flight' in row,'Queue-only refusal, unchanged endpoint inventory and In-flight row')
    task='awaylive-'+lab.name[2:]
    run([ROOT/'bin/fm-tasks-axi.sh','add',task,'existing stage worker','--kind','ship'])
    run([ROOT/'bin/fm-tasks-axi.sh','start',task])
    (lab/'data'/task).mkdir()
    (lab/'data'/task/'brief.md').write_text('# Task\n\n## Captain\'s intent\nReply exactly AFTER_AWAY_RELAUNCH and wait for further input. Do not edit any files, run tools, start validation, or create a PR.\n\n## Firstmate spec\nThis is a disposable real-worker lifecycle proof. Return the requested token only.\n')
    target='primary:fm-'+task
    tm('new-window','-d','-t','primary:','-n','fm-'+task,'-c',wt,'bash --noprofile --norc')
    tm('set-window-option','-t',target,'automatic-rename','off')
    tm('set-window-option','-t',target,'allow-rename','off')
    tm('send-keys','-t',target,'codex --disable hooks --dangerously-bypass-approvals-and-sandbox '+shlex.quote('Reply exactly BEFORE_AWAY_RELAUNCH and wait. Do not call any tools.'),'Enter')
    await_text(target,'BEFORE_AWAY_RELAUNCH','worker-before')
    time.sleep(4)
    meta=lab/'state'/f'{task}.meta'
    meta.write_text(f'window={target}\nendpoint_task_id={task}\nworktree={wt}\nproject={proj}\nharness=codex\nkind=ship\nmode=no-mistakes\nyolo=off\nmodel=default\neffort=default\nbackend=tmux\n')
    original_head=run(['git','-C',wt,'rev-parse','HEAD']).stdout
    p=run([ROOT/'bin/fm-control.sh',task,'relaunch','--note','Continue the next stage by replying exactly AFTER_AWAY_RELAUNCH. Do not call tools or change files.'],check=False,local_env=branch_env,timeout=180)
    capture('worker-after-launch',target)
    journal=(lab/'state'/f'{task}.control-relaunch').read_text() if (lab/'state'/f'{task}.control-relaunch').exists() else ''
    row=run([ROOT/'bin/fm-tasks-axi.sh','show',task]).stdout
    log.write('Persisted relaunch journal:\n'+journal+'\nPersisted task record:\n'+meta.read_text())
    ok=p.returncode==0 and 'phase=complete' in journal and f'window={target}\n' in meta.read_text() and f'worktree={wt}\n' in meta.read_text() and (wt/'preserved.txt').read_text()=='unfinished stage work must survive\n' and run(['git','-C',wt,'rev-parse','HEAD']).stdout==original_head and 'in_flight' in row
    result('Away supervisor relaunches an existing In-flight worker at the spend cap preserving its work',ok,p.stdout)
    await_text(target,'AFTER_AWAY_RELAUNCH','worker-after-response')
    time.sleep(3)
    run([ROOT/'bin/fm-tasks-axi.sh','hold',task,'--reason','decision pending','--kind','captain'])
    prior=meta.read_bytes()
    p=run([ROOT/'bin/fm-control.sh',task,'relaunch','--note','Attempt the held next stage'],check=False,local_env=branch_env,timeout=180)
    capture('worker-held-refusal',target)
    row=run([ROOT/'bin/fm-tasks-axi.sh','show',task]).stdout
    result('Away relaunch refuses a captain-held In-flight row',p.returncode==1 and 'state in_flight yes no' in p.stdout and meta.read_bytes()==prior and 'hold' in row and (wt/'preserved.txt').exists(),p.stdout)
except Exception as exc:
    log.write('DRIVER ERROR: '+str(exc)+'\n')
    results.append(dict(name='driver',result='error',detail=str(exc)))
finally:
    tm('kill-server',check=False)
    # Product-created task temporary data is incidental development-toolchain output.
    tasktmp=pathlib.Path('/tmp/fm-'+task) if 'task' in locals() else None
    if tasktmp is not None and tasktmp.is_dir() and not tasktmp.is_symlink(): shutil.rmtree(tasktmp)
    for directory, subdirs, files in os.walk(lab):
        os.chmod(directory, os.stat(directory).st_mode | 0o700)
    shutil.rmtree(lab)
    log.write('Private socket stopped and disposable lab removed.\n')
    (E/'live-away-relaunch-results.json').write_text(json.dumps(results,indent=2))
    log.close()
print(json.dumps(results,indent=2))
