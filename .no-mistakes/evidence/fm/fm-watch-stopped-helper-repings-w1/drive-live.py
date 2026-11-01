import os, pathlib, subprocess, time, re, json, sys
ROOT=pathlib.Path.cwd()
E=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M6CE5PAXJHGPKDCHA416NJW2')
LAB=ROOT/'.watch-live-lab'; S=LAB/'state'
SESSION='fm-lab-watch-validation-01M6CE5PAXJH'; PANE='w1:p1'
env=os.environ.copy()
for k in list(env):
    if k.endswith('_OVERRIDE') or k in ['HERDR_ENV','HERDR_PANE_ID','HERDR_TAB_ID','HERDR_WORKSPACE_ID','HERDR_SOCKET_PATH','HERDR_SESSION','TMUX','FM_GATE_REFUSE_BYPASS','TASKS_AXI_FILE','TASKS_AXI_BACKEND']:
        env.pop(k,None)
env.update(FM_HOME=str(LAB), FM_POLL='1',FM_SIGNAL_GRACE='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_HOME_SUMMARY_INTERVAL='999999',FM_PAUSE_RESURFACE_SECS='4',FM_STALE_ESCALATE_SECS='4',FM_SECONDMATE_LIVENESS_SECS='99999999', FM_CONTROL_POLL='0.2')
log=open(E/'live-transcript.txt','a',buffering=1)
def note(s):
    print(s,flush=True);log.write(s+'\n')
def cmd(args,check=True,timeout=45):
    p=subprocess.run(args,cwd=ROOT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
    note('$ '+' '.join(map(str,args))+'\n'+p.stdout)
    if check: assert p.returncode==0,(args,p.returncode,p.stdout)
    return p.stdout
def herdr(*args):return cmd(['bin/fm-herdr-lab.sh','run',SESSION,*args])
def ack():
    out=cmd(['bin/fm-wake-drain.sh'])
    m=re.search(r'WAKE_ACK_REQUIRED:.*--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)',out)
    assert m, 'No acknowledgement recipe'
    cmd(['bin/fm-wake-drain.sh','--ack-through',m[1],'--recovery-generation',m[2]])
def watch(label,expect,seconds=16):
    path=E/(label+'.txt')
    with open(path,'w') as out:
        p=subprocess.Popen([env.get('LIVE_WATCH_BINARY','bin/fm-watch.sh')],env=env,cwd=ROOT,stdout=out,stderr=subprocess.STDOUT)
        try:
            if expect:
                p.wait(timeout=35)
            else:
                start=time.time(); beats=set()
                while time.time()-start<seconds:
                    
                    if p.poll() is not None:
                        out.flush()
                        if 'check: rearm-resurface' in path.read_text():
                            note(label+': acknowledging supervision-restart notice')
                            ack()
                            return watch(label,expect,seconds)
                        raise AssertionError('Watcher exited while expecting absorption: '+path.read_text())
                    beat=S/'.last-watcher-beat'
                    if beat.exists():beats.add(beat.stat().st_mtime_ns)
                    time.sleep(.25)
                assert len(beats)>=3,('Not enough completed polls',beats)
                note(label+': watcher stayed running across '+str(len(beats))+' observed poll beacons')
        finally:
            if p.poll() is None:p.terminate()
            try:p.wait(timeout=10)
            except subprocess.TimeoutExpired:p.kill();p.wait();raise
    text=path.read_text();note(label+':\n'+text)
    if expect and 'check: rearm-resurface' in text:
        ack()
        return watch(label,expect,seconds)
    if expect:assert expect in text,(expect,text)
    return text

def state():
    return cmd(['bash','-c','. bin/fm-backend.sh; fm_backend_agent_state herdr "$1"','_',SESSION+':'+PANE]).strip()
def marker():return (S/('.dead-reported-'+SESSION+'_w1_p1')).read_text()
def queue():return (S/'.wake-queue').read_text() if (S/'.wake-queue').exists() else ''

if sys.argv[1]=='initial':
    (S/'helper.meta').write_text(f'window={SESSION}:{PANE}\nendpoint_task_id=helper\nbackend=herdr\nherdr_session={SESSION}\nherdr_workspace_id=w1\nherdr_tab_id=w1:t1\nherdr_pane_id={PANE}\nharness=codex\nkind=scout\nworktree={ROOT}\nproject={ROOT}\nmode=local-only\n')
    assert state()=='alive'
    herdr('pane','read',PANE,'--format','text','--lines','35')
    (S/'helper.status').write_text('done: finished isolated watcher validation helper '+str(time.time())+'\n')
    watch('01-deliver-done','signal:')
    ack()
    cmd(['bin/fm-control.sh','helper','exit'])
    assert state()=='dead'
    assert not (S/'helper.busy-gen').exists()
    watch('02-stopped-done','agent dead')
    before=marker();note('PERSISTED DEAD MARKER: '+before)
    assert 'stale: '+SESSION+':'+PANE+'\n' not in queue()
    ack()
    watch('03-unchanged-done',None)
    assert not queue().strip(),queue()
    herdr('pane','run',PANE,'printf','"footer tick 1\\n"')
    watch('04-footer-done',None)
    assert marker()==before
    assert not queue().strip(),queue()
    note('PASS: delivered done + actual control exit reports once; unchanged and changed real pane displays stay absorbed beyond the 4-second cadence')

if sys.argv[1]=='resume-done':
    ack()
    before=marker()
    watch('04-footer-done-retry',None)
    assert marker()==before
    assert not queue().strip(),queue()
    note('PASS: actual stopped completion remains absorbed across real pane churn')

if sys.argv[1]=='live-pause':
    launch=['env','-u','NO_MISTAKES_GATE','-u','FM_GATE_REFUSE_BYPASS','-u','FM_ROOT_OVERRIDE','-u','FM_STATE_OVERRIDE','-u','FM_DATA_OVERRIDE','-u','FM_CONFIG_OVERRIDE','-u','FM_PROJECTS_OVERRIDE','FM_HOME='+str(LAB),'codex','--disable','hooks']
    herdr('pane','run',PANE,*launch)
    time.sleep(4)
    view=herdr('pane','read',PANE,'--format','text','--lines','40')
    if 'Update now' in view:
        herdr('pane','send-keys',PANE,'esc');time.sleep(3)
    view=herdr('pane','read',PANE,'--format','text','--lines','40')
    assert 'Ask Codex' in view,view
    assert state()=='alive'
    watch('05-live-return','stale:')
    assert not (S/('.dead-reported-'+SESSION+'_w1_p1')).exists()
    ack()
    (S/'helper.status').write_text('paused: waiting for upstream in live validation\n')
    text=watch('06-live-pause-first','') if False else None
    # This can deliver the status event first; continue to the actual cadence recheck.
    text=watch('06-live-pause-first','signal:')
    ack()
    text=watch('07-live-pause-recheck','awaiting external')
    assert 'agent dead' not in text
    ack()
    text=watch('08-live-pause-recheck-again','awaiting external')
    assert 'agent dead' not in text
    assert not (S/('.dead-reported-'+SESSION+'_w1_p1')).exists()
    ack()
    note('PASS: live helper returning clears once marker and raises ordinary stale; live paused helper rechecks twice')
    cmd(['bin/fm-control.sh','helper','exit'])
    assert state()=='dead'
    watch('09-stopped-pause','agent dead')
    before=marker();note('PERSISTED PAUSED DEAD MARKER: '+before)
    ack()
    watch('10-unchanged-pause',None)
    assert not queue().strip(),queue()
    herdr('pane','run',PANE,'printf','"footer tick paused\\n"')
    watch('11-footer-pause',None)
    assert marker()==before
    assert not queue().strip(),queue()
    note('PASS: delivered paused + actual control exit reports once; unchanged and changed real pane displays stay absorbed beyond the cadence')

if sys.argv[1]=='new-identity':
    before=marker()
    with (S/'helper.status').open('a') as f:f.write('done: later delivered completion is new work\n')
    watch('12-new-completion-signal','signal:');ack()
    watch('13-new-completion-dead','agent dead')
    assert marker()!=before
    note('NEW STATUS IDENTITY MARKER: '+marker());ack()
    watch('14-new-completion-absorbed',None)
    assert not queue().strip(),queue()
    note('PASS: new delivered completion is reported once even without a busy-generation token')

if sys.argv[1]=='undelivered':
    (S/'helper.status').write_text('done: a completion the watcher has never delivered\n')
    # Suppress only the signal path, leaving presentation cursor stale on purpose.
    cmd(['bash','-c','. bin/fm-wake-lib.sh; . bin/fm-classify-lib.sh; f="$FM_HOME/state/helper.status"; fm_wake_status_mark_current "$FM_HOME/state" "$f"'])
    herdr('pane','run',PANE,'printf','"undelivered footer\\n"')
    text=watch('15-undelivered-completion','stale:')
    assert 'agent dead' not in text,text
    ack()
    note('PASS: undelivered completion retains ordinary stale, so the once-report does not hide new output')

if sys.argv[1]=='missing-status':
    (S/'helper.status').rename(S/'helper.saved-status')
    try:
        herdr('pane','run',PANE,'printf','"missing log footer\\n"')
        text=watch('16-missing-status','stale:')
        assert 'agent dead' not in text,text
        ack()
        note('PASS: missing status file raises ordinary stale instead of a fabricated dead identity')
    finally:
        (S/'helper.saved-status').rename(S/'helper.status')

if sys.argv[1]=='baseline':
    base=ROOT/'bin/.fm-watch-live-baseline.sh'
    base.write_bytes(subprocess.check_output(['git','show','f89b73c5457bea9d17ae26a91e6cc19c0c4ec88a:bin/fm-watch.sh']))
    base.chmod(0o755)
    env['LIVE_WATCH_BINARY']=str(base)
    try:
        (S/('.dead-reported-'+SESSION+'_w1_p1')).unlink(missing_ok=True)
        for i in (1,2):
            herdr('pane','run',PANE,'printf',f'"baseline footer {i}\\n"')
            text=watch(f'17-baseline-done-{i}','stale:')
            assert text.strip()=='stale: '+SESSION+':'+PANE,text
            assert not (S/('.dead-reported-'+SESSION+'_w1_p1')).exists()
            ack()
        note('BASELINE REPRODUCED: delivered completion from a real stopped helper raises two bare stale wakes across display churn and never creates a dead marker')
    finally:base.unlink()
