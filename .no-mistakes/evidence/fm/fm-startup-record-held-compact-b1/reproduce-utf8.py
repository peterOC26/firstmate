import os, pathlib, shutil, subprocess, tempfile, json
root=pathlib.Path.cwd()
evidence=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M6ZCS9R68WB76FATEE4KBC8C')
lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.',dir=root/'.live-startup-validation'))
env=dict(os.environ)
for key in list(env):
    if key.startswith(('FM_','HERDR_','TASKS_AXI_')) or key in ('NO_MISTAKES_GATE','TMUX','CLAUDECODE','PI_CODING_AGENT','GROK_AGENT','REX_SESSION','REX_BLOCK'):
        env.pop(key,None)
env.update(FM_HOME=str(lab),FM_ROOT_OVERRIDE=str(root))
try:
    subprocess.run([str(root/'bin/fm-lab-home.sh'),'create',str(lab)],env=env,check=True,stdout=subprocess.PIPE)
    (lab/'config/backlog-backend').write_text('manual\n')
    (lab/'config/backend').write_text('tmux\n')
    rows=['# Backlog','','## In flight','','## Queued']
    for group,kind,reason in [('parked','parked','Parked reason'),('watch','captain','Watch reason')]:
        for i,(glyph,boundary) in enumerate([('é',116),('€',116),('€',115),('🚢',116),('🚢',115),('🚢',114)],1):
            prefix=f'- [ ] {group}-{i} - '
            rows.append(prefix+'a'*(boundary-len(prefix.encode()))+glyph*5+f' (hold: {reason}) (hold-kind: {kind})')
    rows+=['','## Done','']
    (lab/'data/backlog.md').write_text('\n'.join(rows))
    oldbin=lab/'bin'
    oldbin.mkdir()
    for source in (root/'bin').iterdir():
        if source.name != 'fm-session-start.sh': (oldbin/source.name).symlink_to(source)
    old=oldbin/'fm-session-start.sh'
    old.write_bytes(subprocess.check_output(['git','show','216161d6:bin/fm-session-start.sh'],cwd=root))
    old.chmod(0o755)
    summary={}
    for version,script in [('before-fix',old),('after-fix',root/'bin/fm-session-start.sh')]:
        p=subprocess.run([str(script),'--reemit'],env=env,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=145,check=True)
        (evidence/f'utf8-{version}-startup.txt').write_bytes(p.stdout)
        try:
            text=p.stdout.decode('utf-8','strict')
            valid=True
        except UnicodeDecodeError as error:
            valid=False
            summary[version]={'valid_utf8':False,'first_invalid_byte_offset':error.start,'hex_context':p.stdout[error.start-8:error.end+8].hex(' ')}
        if version=='before-fix':
            assert not valid,'Counterfactual unexpectedly emitted valid UTF-8'
        else:
            assert valid
            assert '6 parked, 6 watch queued hold(s) shortened' in text
            rendered=[line for line in text.splitlines() if line.startswith('- [ ]')]
            assert len(rendered)==12
            assert all(len(line.encode())<=160 and '... (hold-kind:' in line for line in rendered)
            summary[version]={'valid_utf8':True,'short_rows':len(rendered),'counts':'6 parked, 6 watch','maximum_row_bytes':max(len(line.encode()) for line in rendered)}
    (evidence/'utf8-counterfactual.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(json.dumps(summary,indent=2))
finally:
    shutil.rmtree(lab)
