import os, pathlib, subprocess, tempfile, time, shutil, json
root=pathlib.Path.cwd()
evidence=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M6R9JQBC9XXM9G75QQXE88JY')
lab=pathlib.Path(tempfile.mkdtemp(prefix='.fm-lab-dwell-',dir=root))
env=os.environ.copy()
for k in list(env):
    if (k.startswith('FM_') and (k.endswith('_OVERRIDE') or k in ['FM_HOME','FM_TASK_ID','FM_TEST_SEAM','FM_GATE_REFUSE_BYPASS','FM_TASKS_AXI_COMPATIBLE'])) or k.startswith('TASKS_AXI_'):
        env.pop(k)
env['FM_HOME']=str(lab)
env['FM_AFK_BLOCKER_GRACE']='3'
log=(evidence/'live-cli-transcript.txt').open('w')
checks=[]
def note(s):
    log.write(s+'\n'); log.flush()
def run(args, allowed=(0,)):
    p=subprocess.run(args,cwd=root,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
    note('$ '+ ' '.join(str(a) for a in args)+'\n'+p.stdout+'\nexit='+str(p.returncode))
    assert p.returncode in allowed, (args,p.returncode,p.stdout)
    return p.stdout,p.returncode
def check(name,cond):
    checks.append({'name':name,'pass':bool(cond)})
    note(('PASS ' if cond else 'FAIL ')+name)
    assert cond,name
def status(task,verb,key='default',at=True):
    epoch=int(time.time())
    with (lab/'state'/f'{task}.status').open('a') as f:
        line=f'{verb} [key={key}]'+(f' [at={epoch}]' if at else '')+': live validation event\n'
        f.write(line)
    note(f'worker appends {task}: '+line.strip())
    return epoch
def task(name):
    (lab/'state'/f'{name}.meta').write_text('kind=ship\n')
def brief(mode='check',allowed=(0,3)):
    out,rc=run(['bin/fm-afk-return.sh',mode],allowed)
    body=out.split('Tried and failed, or could not be fixed:\n',1)[1].split('Landed, cleanup due:',1)[0]
    return out,body,rc
def steer(name):
    out,_=run(['bash','-c','. bin/fm-task-inbox-lib.sh; fm_task_inbox_write "$FM_HOME/state" "$1" "$2"','steer',name,'Continue the blocked task; prose at=1970-01-01T00:00:00Z is not a header'])
    return pathlib.Path(out.strip())
try:
    run(['bin/fm-lab-home.sh','create',str(lab)])
    (lab/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    (lab/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    run(['bin/fm-afk-contract.sh','enter','--words','Live validation of blocker response timing'])
    task('live-stall'); opened=status('live-stall','blocked')
    task('live-question'); status('live-question','needs-decision')
    time.sleep(1.1)
    status('live-stall','working'); status('live-stall','paused'); status('live-stall','blocked',at=False)
    while int(time.time())-opened<4: time.sleep(.2)
    (lab/'state/.last-watcher-beat').touch()
    out,body,rc=brief('begin')
    check('Live unresolved blocker reports no-action dwell despite working, paused and untimed reassertion',rc==3 and 'live-stall [key=default] blocked ' in body and 'no action for ' in body and 'still blocked, firstmate remediates' in body)
    check('Untimed event gets honesty note and a question produces no blocker dwell', '1 blocked event(s) carried no time stamp' in body and 'live-question [key=default] blocked' not in body)
    run(['bin/fm-afk-return.sh','guard'],(4,))
    before=(lab/'state/.afk-return-catchup').read_bytes()
    run(['bin/fm-afk-return.sh','catchup-summary'])
    check('Catchup-summary leaves gate bytes unchanged',before==(lab/'state/.afk-return-catchup').read_bytes())
    late=steer('live-stall')
    out,body,rc=brief()
    check('Late root steering reports first action and retains remediation gate',rc==3 and 'live-stall [key=default] blocked ' in body and 'first action ' in body)
    late.rename(late.parent/'handled'/late.name)
    task('live-boundary'); op=status('live-boundary','blocked','route')
    time.sleep(1.1)
    status('live-boundary','blocked','route')
    time.sleep(1.1)
    cl=status('live-boundary','resolved','route')
    gap=cl-op
    env['FM_AFK_BLOCKER_GRACE']=str(gap)
    out,body,rc=brief()
    check('Keyed closure exactly at grace reports true opening through timed reassertion', 'live-boundary [key=route] blocked ' in body and 'first action ' in next(x for x in body.splitlines() if 'live-boundary [key=route]' in x) and 'closed ' in body)
    env['FM_AFK_BLOCKER_GRACE']=str(gap+1)
    out,body,rc=brief()
    check('Same interval below configured grace is suppressed','live-boundary [key=route] blocked ' not in body)
    env['FM_AFK_BLOCKER_GRACE']='60'
    task('live-root'); status('live-root','blocked'); time.sleep(1.1); pending=steer('live-root')
    task('live-acked'); status('live-acked','blocked'); time.sleep(1.1); acknowledged=steer('live-acked'); acknowledged.rename(acknowledged.parent/'handled'/acknowledged.name)
    task('live-terminal'); status('live-terminal','blocked','build'); time.sleep(1.1); status('live-terminal','done')
    task('live-held'); status('live-held','blocked','review'); time.sleep(1.1); status('live-held','captain-held','review')
    out,body,rc=brief()
    check('Prompt root/acknowledged steers, ship done and captain-held closure add no dwell noise',all(f'{name} [key=' not in '\n'.join(x for x in body.splitlines() if ' blocked 20' in x) for name in ['live-root','live-acked','live-terminal','live-held']))
    # All dwell has already crossed the three-second threshold; sidecars cannot change action time.
    env['FM_AFK_BLOCKER_GRACE']='3'
    out,body,rc=brief(); base=[x for x in body.splitlines() if 'live-stall [key=default] blocked ' in x]
    for shape,filename in [('pi','branch-outcomes.jsonl'),('host','.supervision-host.log'),('daemon','.supervise-daemon.log')]:
        path=lab/'state'/filename
        # Valid empty outcome store; notices in host/daemon logs are display bookkeeping.
        path.write_text('' if shape=='pi' else f'{int(time.time())} escalated live-stall [key=default]\n')
        out,body,rc=brief()
        check(shape+' bookkeeping cannot alter measured live-stall action',base==[x for x in body.splitlines() if 'live-stall [key=default] blocked ' in x])
        path.rename(path.with_name(filename+'.rotated'))
    # Open the same key anew and supply a prompt closure, so the prior late interval is replaced.
    status('live-boundary','blocked','route'); time.sleep(1.1); status('live-boundary','resolved','route')
    env['FM_AFK_BLOCKER_GRACE']='60'
    out,body,rc=brief()
    check('Same-key reopening evaluates its latest interval','live-boundary [key=route] blocked ' not in body)
    task('live-missing')
    out,body,rc=brief()
    check('Missing status is named and gate retained',rc==3 and 'live-missing status log missing or unreadable' in body)
    (lab/'state/live-missing.status').symlink_to(lab/'state/live-stall.status')
    out,body,rc=brief()
    check('Unreadable symlink status is named and gate retained',rc==3 and 'live-missing status log missing or unreadable' in body)
    (lab/'state/live-missing.status').unlink(); status('live-missing','done')
    for name in ['live-stall','live-root','live-acked']:
        status(name,'resolved')
    out,body,rc=brief()
    check('Resolving open blockers clears gate while question remains',rc==0 and 'catch-up clear' in out and not (lab/'state/.afk-return-catchup').exists())
    run(['bin/fm-afk-return.sh','guard'])
finally:
    shutil.rmtree(lab)
    note('Removed disposable lab home; no harness or fleet endpoints were launched.')
    (evidence/'live-checks.json').write_text(json.dumps(checks,indent=2)+'\n')
    log.close()
print(json.dumps(checks,indent=2))
