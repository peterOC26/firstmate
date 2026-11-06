import os,pathlib,subprocess,tempfile,shutil,time,json
root=pathlib.Path.cwd(); ev=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M6R9JQBC9XXM9G75QQXE88JY')
lab=pathlib.Path(tempfile.mkdtemp(prefix='.fm-lab-boundaries-',dir=root)); env=os.environ.copy()
for k in list(env):
    if (k.startswith('FM_') and (k.endswith('_OVERRIDE') or k in ['FM_HOME','FM_TASK_ID','FM_TEST_SEAM','FM_GATE_REFUSE_BYPASS','FM_TASKS_AXI_COMPATIBLE'])) or k.startswith('TASKS_AXI_'):env.pop(k)
env.update(FM_HOME=str(lab),FM_AFK_BLOCKER_GRACE='3')
f=(ev/'live-boundaries-transcript.txt').open('w'); results=[]
def run(args,allowed=(0,)):
    p=subprocess.run(args,env=env,cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
    f.write('$ '+' '.join(map(str,args))+'\n'+p.stdout+f'\nexit={p.returncode}\n');f.flush()
    assert p.returncode in allowed,(p.returncode,p.stdout)
    return p.stdout
def event(name,verb,epoch=None):
    if epoch is None: epoch=int(time.time())
    (lab/'state'/f'{name}.meta').write_text('kind=ship\n')
    with (lab/'state'/f'{name}.status').open('a') as s:s.write(f'{verb} [at={epoch}]: validation event\n')
    f.write(f'worker appends {name}: {verb} [at={epoch}]: validation event\n');f.flush()
    return epoch
def check(name,condition):
    results.append({'name':name,'pass':bool(condition)});f.write(('PASS ' if condition else 'FAIL ')+name+'\n');f.flush();assert condition,name
try:
    run(['bin/fm-lab-home.sh','create',str(lab)])
    (lab/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    (lab/'.tasks.toml').write_text('backend="markdown"\n[markdown]\npath="data/backlog.md"\narchive="data/done-archive.md"\ndone_keep=10\n')
    event('before-entry','blocked');time.sleep(1.1)
    run(['bin/fm-afk-contract.sh','enter','--words','Live boundary validation'])
    oldrec=run(['bash','-c','. bin/fm-task-inbox-lib.sh; fm_task_inbox_write "$FM_HOME/state" prose-only "A message body mentions at=2099-01-01T00:00:00Z; it is not action during the blocked interval"']).strip()
    time.sleep(1.1)
    opened=event('prose-only','blocked');time.sleep(1.1)
    event('younger','blocked');event('future-event','blocked',int(time.time())+3600)
    (lab/'state/before-entry.status').touch() # freshly observed mtime cannot put this event in-window
    (lab/'state/.supervise-daemon.log.rotated').write_text(f'{int(time.time())} escalated prose-only\n')
    while int(time.time())-opened<4:time.sleep(.2)
    (lab/'state/.last-watcher-beat').touch()
    out=run(['bin/fm-afk-return.sh','begin'],(3,))
    body=out.split('Tried and failed, or could not be fixed:\n',1)[1].split('Landed, cleanup due:',1)[0]
    rows=[x for x in body.splitlines() if '] blocked 20' in x]
    check('Pre-entry event stays excluded despite fresh status mtime',not any('before-entry [key=' in x for x in rows))
    check('Future event cannot be attributed to this window',not any('future-event [key=' in x for x in rows))
    check('Pre-block inbox, body timestamps and rotated daemon ledger are not real action',any('prose-only [key=default] blocked ' in x and 'no action for ' in x for x in rows))
    check('Longest wait comes first and is marked exactly once',len(rows)==2 and 'prose-only [key=default]' in rows[0] and body.count('the longest wait this window')==1)
    # A live terminal after a wait is late action, even though the task has closed.
    ended=event('prose-only','failed')
    out=run(['bin/fm-afk-return.sh','check'],(3,))
    body=out.split('Tried and failed, or could not be fixed:\n',1)[1].split('Landed, cleanup due:',1)[0]
    row=next(x for x in body.splitlines() if 'prose-only [key=default] blocked ' in x)
    check('A late ship failure preserves earlier wait and shows closed context','first action ' in row and '; closed ' in row)
finally:
    shutil.rmtree(lab);f.write('Removed disposable lab home.\n');f.close()
    (ev/'live-boundary-checks.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
