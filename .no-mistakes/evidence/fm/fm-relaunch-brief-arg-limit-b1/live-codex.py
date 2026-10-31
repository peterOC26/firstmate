import os, subprocess, pathlib, json, time, shutil, hashlib, secrets, traceback
ROOT=pathlib.Path.cwd()
E=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M691RDTZQKJTBP1EPEQSTMY0')
LAB=E/'lab space'
SOCK=E/'s'
env=os.environ.copy()
for k in list(env):
    if k.startswith(('FM_', 'HERDR_', 'TASKS_AXI_', 'GIT_')) or k in ('TMUX','TMUX_PANE','NO_MISTAKES_GATE'):
        env.pop(k)
env.update(FM_HOME=str(LAB), TMUX_TMPDIR=str(SOCK), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', FM_CONTROL_POLL='0.3', FM_CONTROL_LAUNCH_WAIT='40')
ID='lv'+secrets.token_hex(4)
log=open(E/'live-codex-transcript.log','w',buffering=1)
results=[]
def run(args,cwd=ROOT,check=True,timeout=90):
    log.write('$ '+repr([str(x) for x in args])+'\n')
    p=subprocess.run([str(x) for x in args],cwd=cwd,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
    log.write(p.stdout+p.stderr+'\nexit='+str(p.returncode)+'\n')
    if check and p.returncode: raise RuntimeError(p.stdout)
    return p

def tmux(*args,**kw):return run(['tmux','-L','fm-lab',*args],**kw)
def capture(name):
    p=tmux('capture-pane','-p','-S','-2000','-t','fm-lab:fm-'+ID,check=False)
    (E/(name+'-terminal.txt')).write_text(p.stdout)
    return p.stdout

def observe_args():
    pane=int(tmux('display-message','-p','-t','fm-lab:fm-'+ID,'#{pane_pid}').stdout.strip())
    queue=[pane]; prompts=[]
    while queue:
        pid=queue.pop()
        try:
            queue.extend(int(x) for x in pathlib.Path(f'/proc/{pid}/task/{pid}/children').read_text().split())
            args=pathlib.Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
            for arg in args:
                if b'FIRSTMATE_OP:' in arg:
                    prompts.append({'pid':pid,'bytes':len(arg),'text':arg.decode()})
        except (FileNotFoundError,PermissionError):pass
    return prompts

def scenario(name,expected):
    if report.exists():report.unlink()
    before=brief.read_bytes()
    p=run([ROOT/'bin/fm-control.sh',ID,'relaunch','--note',f'LATEST_TOKEN={expected["latest"]}\nFor this launch, read the complete instructions and write the requested JSON report at {report}.'],check=False,timeout=140)
    capture(name+'-launch')
    deadline=time.monotonic()+180
    trusted=False
    while not report.exists() and time.monotonic()<deadline:
        screen=tmux('capture-pane','-p','-t','fm-lab:fm-'+ID).stdout
        if not trusted and 'Trust and continue' in screen:
            tmux('send-keys','-t','fm-lab:fm-'+ID,'Enter')
            trusted=True
        time.sleep(2)
    prompts=observe_args()
    (E/(name+'-argv.json')).write_text(json.dumps(prompts,indent=2))
    terminal=capture(name+'-completed')
    result={'name':name,'control_exit':p.returncode,'original_bytes':len(before),'launch_brief_bytes':(LAB/'data'/ID/'launch-brief.md').stat().st_size,'source_prefix_preserved':brief.read_bytes().startswith(before),'prompts':[{k:v for k,v in a.items() if k!='text'} for a in prompts]}
    if report.exists():
        shutil.copyfile(report,E/(name+'-report.json'))
        result['observed_report']=json.loads(report.read_text())
        result['expected_report']=expected
        result['pass']=p.returncode==0 and result['observed_report']==expected and result['source_prefix_preserved'] and bool(prompts) and all(x['bytes']<65536 for x in prompts)
    else:
        result.update({'pass':False,'reason':'No model-written report before deadline; inspect terminal evidence.'})
    results.append(result)
    (E/'live-results.json').write_text(json.dumps(results,indent=2))
    log.write(json.dumps(result)+'\n')
    if not result['pass']:raise RuntimeError('Scenario did not pass: '+name)

try:
    run([ROOT/'bin/fm-lab-home.sh','create',LAB])
    SOCK.mkdir(mode=0o700)
    # Reuse the existing genuine login in an isolated disposable CLI home; never change the operator's trust or credential stores.
    cli_home=LAB/'codex-home';cli_home.mkdir(mode=0o700)
    shutil.copyfile(pathlib.Path('/home/zabi/.codex/auth.json'),cli_home/'auth.json')
    (cli_home/'auth.json').chmod(0o600)
    env['CODEX_HOME']=str(cli_home)
    run(['codex','login','status'])
    (LAB/'config'/'backlog-backend').write_text('manual\n')
    (LAB/'config'/'keep-ai-trailers').touch()
    project=LAB/'projects'/'sample'; project.mkdir()
    run(['git','init','-q',project])
    (project/'README.md').write_text('Disposable launch verification.\n')
    run(['git','-C',project,'add','README.md'])
    run(['git','-C',project,'-c','user.name=Live Test','-c','user.email=live@example.invalid','commit','-qm','initial'])
    pool=LAB/'pool'
    allocation=json.loads(run(['treehouse','get','--lease','--json','--no-fetch','--lease-holder',str(LAB/ID),'--root',pool],cwd=project).stdout)
    (E/'allocation-shape.json').write_text(json.dumps(allocation,indent=2))
    wt=pathlib.Path(allocation['path'])
    home_data=LAB/'data'/ID;home_data.mkdir()
    brief=home_data/'brief.md';report=home_data/'report.json'
    intent=secrets.token_hex(8)
    brief.write_text(f'''# Task
## Captain's intent
Verify complete instruction delivery to this disposable Codex task.
INTENT_TOKEN={intent}

## Firstmate spec
This is a read-and-report live launch verification, requiring no project changes, no delegation, no external messages, and no pipeline commands.
Read the entire launch instructions and the progress notes, then write a JSON object at `{report}` with these exact keys: "intent", "early", "late", "latest". The intent value is INTENT_TOKEN's value. The early and late values are EARLY_TOKEN and LATE_TOKEN if present, otherwise null. The latest value is the LAST occurrence of LATEST_TOKEN in the progress notes. Output actual observed values, not variable names. Do not create or edit any other files. Then stop and wait.
''')
    meta=LAB/'state'/(ID+'.meta')
    meta.write_text(f'window=fm-lab:fm-{ID}\nendpoint_task_id={ID}\nworktree={wt}\nproject={project}\nharness=codex\nkind=scout\nmodel=default\neffort=low\ntreehouse_lease_id={allocation["lease_id"]}\ntreehouse_lease_holder={allocation["lease_holder"]}\n')
    (wt.parent/'.fm-slot-owner').write_text(f'task={ID}\nhome={LAB}\n')
    tmux('new-session','-d','-s','fm-lab','-n','fm-'+ID,'-x','120','-y','40','-c',str(wt),'bash --noprofile --norc')
    env['TMUX']=tmux('display-message','-p','-t','fm-lab:fm-'+ID,'#{socket_path},#{pid},0').stdout.strip()
    time.sleep(1)
    scenario('short-inline',dict(intent=intent,early=None,late=None,latest=secrets.token_hex(8)))
    early=secrets.token_hex(8); late=secrets.token_hex(8)
    with brief.open('a') as f:
        f.write('\n# Accumulated relaunch progress\nEARLY_TOKEN='+early+'\n')
        f.write('Older checkpoint retained verbatim for the next replacement.\n'*2400)
        f.write('LATE_TOKEN='+late+'\n')
    original=brief.read_bytes()
    (E/'oversized-source-sha256.txt').write_text(f'{len(original)} bytes\nsha256 {hashlib.sha256(original).hexdigest()}\n')
    scenario('oversized-relaunch',dict(intent=intent,early=early,late=late,latest=secrets.token_hex(8)))
    encoded=run([ROOT/'bin/fm-operational-input.sh','encode','launch-brief'],check=False) if False else subprocess.run([str(ROOT/'bin/fm-operational-input.sh'),'encode','launch-brief'],input=(LAB/'data'/ID/'launch-brief.md').read_bytes(),stdout=subprocess.PIPE,env=env,check=True).stdout
    try:
        subprocess.run(['codex','--dangerously-bypass-approvals-and-sandbox','--disable','hooks',encoded.decode()],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=5)
        raise RuntimeError('Oversized inline counterfactual unexpectedly launched')
    except OSError as exc:
        import errno
        if exc.errno!=errno.E2BIG:raise
        (E/'inline-counterfactual.txt').write_text(f'Real codex exec with the entire encoded launch brief ({len(encoded)} bytes) was refused by Linux: errno={exc.errno} {exc.strerror}. The same brief succeeded through fm-control relaunch using its generated pointer.\n')
    scenario('oversized-second-relaunch',dict(intent=intent,early=early,late=late,latest=secrets.token_hex(8)))
    log.write('All live scenarios passed.\n')
except Exception as exc:
    log.write(traceback.format_exc())
    (E/'live-error.txt').write_text(traceback.format_exc())
    raise
finally:
    tmux('kill-server',check=False)
    shutil.rmtree(LAB,ignore_errors=True)
    shutil.rmtree(SOCK,ignore_errors=True)
    log.write('Disposable lab and private tmux server removed.\n')
    log.close()
