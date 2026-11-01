import os, subprocess, pathlib, json, time, uuid, tempfile
root=pathlib.Path.cwd()
evidence=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M6CE2V3S2K05SQ401JZWGCA9')
env=os.environ.copy()
for k in ('FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','HERDR_PANE_ID','HERDR_WORKSPACE_ID','HERDR_TAB_ID'):
    env.pop(k,None)
env['FM_HERDR_LAB_STATE_DIR']=str(root/'.test-tmp/herdr-lab')
log=(evidence/'live-lab.log').open('a')
def command(args, check=True, timeout=30):
    p=subprocess.run([str(x) for x in args],env=env,cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
    log.write('$ '+' '.join(str(x) for x in args)+'\n'+p.stdout+'\nrc='+str(p.returncode)+'\n');log.flush()
    if check and p.returncode: raise RuntimeError(p.stdout)
    return p
helper=root/'bin/fm-herdr-lab.sh'
session=command([helper,'name','grok-composer']).stdout.strip()
lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.',dir=root/'.test-tmp'))
env['FM_HOME']=str(lab)
command([root/'bin/fm-lab-home.sh','create',lab])
started=False
try:
    # provision performs prepare itself for an absent session.
    command([helper,'provision',session],timeout=75);started=True
    command([helper,'run',session,'workspace','create','--cwd',root,'--no-focus','--env','FM_HOME='+str(lab),'--env','GROK_PROMPT_SUGGESTIONS=1'])
    pane='w1:p1'
    command([helper,'run',session,'pane','run',pane,'env','-u','NO_MISTAKES_GATE','-u','FM_GATE_REFUSE_BYPASS','-u','FM_ROOT_OVERRIDE','-u','FM_STATE_OVERRIDE','-u','FM_DATA_OVERRIDE','-u','FM_CONFIG_OVERRIDE','-u','FM_PROJECTS_OVERRIDE','grok','--model','grok-4.7','--reasoning-effort','low','--always-approve','--leader-socket',str(lab/'grok.sock'),'--session-id',str(uuid.uuid4())])
    def capture(name):
        raw=command([helper,'run',session,'pane','read',pane,'--source','visible','--format','ansi']).stdout
        (evidence/(name+'.ansi')).write_text(raw)
        return raw
    for n in range(20):
        time.sleep(1)
        raw=capture('grok-startup')
        if 'Shift+Tab' in raw or 'trust' in raw.lower() or 'sign in' in raw.lower(): break
    print(raw)
    def classify(name, raw):
        env['FM_LIVE_SCREEN']=raw
        out=command(['bash','-c','. bin/fm-composer-lib.sh; fm_composer_classify_screen "styled=1\ncursor=0\nidentity=1\nrows=40" "$FM_LIVE_SCREEN"']).stdout
        with (evidence/'live-verdicts.txt').open('a') as f:f.write(name+': '+out+'\n')
        return out
    idle=classify('initial idle',raw)
    if idle!='empty':
        print('BLOCKED: startup did not reach an empty composer');raise SystemExit(3)
    meta='\n'.join(['window='+session+':'+pane,'endpoint_task_id=lab','worktree='+str(root),'project='+str(root),'harness=grok','kind=ship','backend=herdr','herdr_session='+session,'herdr_workspace_id=w1','herdr_tab_id=t1','herdr_pane_id='+pane])+'\n'
    (lab/'state/lab.meta').write_text(meta)
    for label,draft in [('draft','KEEP UNSENT DRAFT'),('placeholder-typed','Build anything'),('doorbell-typed',': Firstmate instruction waiting')]:
        command([helper,'run',session,'pane','send-text',pane,draft]);time.sleep(.5)
        before=capture(label)
        assert classify(label,before)=='pending'
        refused=command([root/'bin/fm-control.sh','lab','exit'],check=False)
        assert refused.returncode!=0 and 'pending text' in refused.stdout,refused.stdout
        after=capture(label+'-after-refusal')
        assert before==after, 'refusal changed viewport'
        command([helper,'run',session,'pane','send-keys',pane]+['backspace']*len(draft));time.sleep(.5)
        assert classify(label+' cleared',capture(label+'-cleared'))=='empty'
    result=command([root/'bin/fm-control.sh','lab','exit'])
    assert result.stdout.startswith('stopped lab '),result.stdout
    capture('grok-stopped')
    print('PASS: idle empty; three unsent drafts pending and preserved on exit refusal; cleared composer exits')
finally:
    if started:
        result=command([helper,'teardown',session],check=False,timeout=45)
        print('teardown_rc='+str(result.returncode))
        if result.returncode:raise RuntimeError('lab teardown failed')
    import shutil
    shutil.rmtree(lab)
    log.close()
