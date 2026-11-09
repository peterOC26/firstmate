import json, os, pathlib, shutil, subprocess, tempfile
root=pathlib.Path.cwd()
evidence=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M707X8CATVY2RTZPY1YDP8QC')
lab=pathlib.Path(tempfile.mkdtemp(prefix='.fm-lab-utf8-',dir=root))
fd,old_name=tempfile.mkstemp(prefix='.fm-start-before-utf8-',suffix='.sh',dir=root/'bin')
os.close(fd)
old_script=pathlib.Path(old_name)
env=os.environ.copy()
for key in list(env):
    if key.startswith(('FM_','HERDR_','REX_','TASKS_AXI_')) or key in ('TMUX','TERM_PROGRAM'): env.pop(key,None)
env.update(FM_HOME=str(lab),FM_BACKEND='tmux')
def run(args,timeout=150):
    return subprocess.check_output(args,cwd=root,env=env,stderr=subprocess.STDOUT,timeout=timeout)
try:
    run(['bin/fm-lab-home.sh','create',str(lab)])
    (lab/'config/backlog-backend').write_text('manual\n')
    (lab/'config/backend').write_text('tmux\n')
    lines=['# Backlog','','## Queued']
    for i,(glyph,boundary) in enumerate([('é',116),('€',116),('€',115),('🚢',116),('🚢',115),('🚢',114)],1):
        prefix=f'- [ ] quiet-{i} - '
        lines.append(prefix+'a'*(boundary-len(prefix.encode()))+glyph*5+' (hold: Long parked reason) (hold-kind: parked)')
    original=('\n'.join(lines)+'\n').encode()
    (lab/'data/backlog.md').write_bytes(original)
    old_script.write_bytes(subprocess.check_output(['git','show','c588acc4^:bin/fm-session-start.sh'],cwd=root))
    env['FM_SESSION_START_STAGE_FILE']=str(lab/'baseline-stage')
    before=run(['bash',str(old_script),'--reemit'])
    env.pop('FM_SESSION_START_STAGE_FILE')
    (evidence/'utf8-before-fix.bin').write_bytes(before)
    run(['bin/fm-startup-network.sh','wait','30'],40)
    try:
        before.decode('utf-8',errors='strict')
    except UnicodeDecodeError as err:
        old_error={'offset':err.start,'error':str(err),'nearby_hex':before[err.start-8:err.start+8].hex()}
    else: raise AssertionError('Expected invalid UTF-8 was not reproduced before the fix')
    after=run(['bin/fm-session-start.sh','--reemit'])
    (evidence/'utf8-after-fix.txt').write_bytes(after)
    text=after.decode('utf-8',errors='strict')
    for i in range(1,7):
        line=next(line for line in text.splitlines() if line.startswith(f'- [ ] quiet-{i} - '))
        assert '... (hold-kind: parked; reason omitted)' in line
        assert len(line.encode()) <= 162
    assert '6 parked, 0 watch queued hold(s) shortened' in text
    assert original == (lab/'data/backlog.md').read_bytes()
    run(['bin/fm-startup-network.sh','wait','30'],40)
    summary={'baseline_commit':'747c89c1','before_fix':old_error,'after_fix':'valid UTF-8; all six byte boundaries bounded; exact count; backlog unchanged'}
    (evidence/'utf8-regression.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(json.dumps(summary,indent=2))
finally:
    old_script.unlink(missing_ok=True)
    shutil.rmtree(lab)
    print('Temporary baseline executable and lab removed')
