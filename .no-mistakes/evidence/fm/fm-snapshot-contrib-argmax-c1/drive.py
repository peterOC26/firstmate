import os, pathlib, subprocess, tempfile, json, shutil
root=pathlib.Path.cwd()
evidence=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M3AW9WA03WFB8Z3P57KX132C')
home=pathlib.Path(tempfile.mkdtemp(prefix='.snapshot-live-',dir=root))
base=root/'bin/.snapshot-before-live.sh'
log=[]
try:
    for d in ('data','state','config','projects'): (home/d).mkdir()
    env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_'))}
    env.update(FM_HOME=str(home),FM_ROOT_OVERRIDE=str(root),FM_BACKEND='tmux')
    base.write_bytes(subprocess.check_output(['git','show','33e290ed35c76af91d13db1886950c73e2ee7493:bin/fm-fleet-snapshot.sh']))
    def run(name, script):
        p=subprocess.run(['bash',str(script),'--contribution-input'],env=env,capture_output=True,text=True,timeout=60)
        (evidence/(name+'.json')).write_text(p.stdout)
        (evidence/(name+'.stderr')).write_text(p.stderr)
        log.append(f'{name}: bash {script.relative_to(root)} --contribution-input; exit={p.returncode}; stdout_bytes={len(p.stdout.encode())}; stderr={p.stderr.strip()!r}')
        return p
    target=root/'bin/fm-fleet-snapshot.sh'
    p=run('empty',target); obj=json.loads(p.stdout)
    assert p.returncode==0 and not p.stderr and obj=={'backlog':{'path':str(home/'data/backlog.md'),'present':False,'records':[]},'tasks':[]}
    (home/'state/owned.meta').write_text('kind=ship\npr=https://github.com/example/repo/pull/42\npr_head=abc123\n')
    def backlog(n):
        (home/'data/backlog.md').write_text('## Queued\n'+''.join(f'- [ ] queued-{i} - Queued contribution {i} (repo: sample) (kind: ship)\n' for i in range(1,n+1)))
    backlog(2)
    small=run('small',target); oldsmall=run('before-small',base)
    assert small.returncode==0 and not small.stderr and json.loads(small.stdout)==json.loads(oldsmall.stdout)
    expected=[{'id':'owned','kind':'ship','pr':{'url':'https://github.com/example/repo/pull/42','head':'abc123'},'merge_authority':'attended'}]
    assert json.loads(small.stdout)['tasks']==expected
    backlog(500)
    before=run('before-large',base)
    assert 'Argument list too long' in before.stderr and not before.stdout.strip()
    after=run('large',target); obj=json.loads(after.stdout)
    assert after.returncode==0 and not after.stderr and sorted(obj)==['backlog','tasks']
    assert obj['backlog']['present'] and obj['backlog']['path']==str(home/'data/backlog.md')
    assert [r['id'] for r in obj['backlog']['records']]==[f'queued-{i}' for i in range(1,501)]
    assert all(r['state']=='queued' and r['kind']=='ship' for r in obj['backlog']['records'])
    assert obj['tasks']==expected
    size=len(json.dumps(obj['backlog'],separators=(',',':')).encode())
    assert size>131072
    log.append(f'Large snapshot: backlog JSON {size} bytes (>131072); all 500 ordered records and PR ownership preserved.')
    log.append('Empty snapshot contract and small snapshot semantic equality with base verified; oversized backlog reproduces base error and succeeds on target.')
finally:
    base.unlink(missing_ok=True)
    shutil.rmtree(home)
    (evidence/'transcript.txt').write_text('\n'.join(log)+'\n')
    print('\n'.join(log))
