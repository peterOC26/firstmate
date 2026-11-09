import os,pathlib,re,shutil,subprocess,sys,tempfile,json
root=pathlib.Path.cwd()
evidence=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M6ZCS9R68WB76FATEE4KBC8C')
lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.',dir=root/'.live-startup-validation'))
env=dict(os.environ)
for key in list(env):
    if key.startswith(('FM_','HERDR_','TASKS_AXI_')) or key in ('NO_MISTAKES_GATE','TMUX','CLAUDECODE','PI_CODING_AGENT','GROK_AGENT','REX_SESSION','REX_BLOCK'):
        env.pop(key,None)
env.update(FM_HOME=str(lab),FM_SESSION_START_QUEUED_LIMIT='1',PATH=sys.argv[1])
try:
    assert subprocess.run(['bash','-c','command -v tasks-axi'],env=env,stdout=subprocess.PIPE).returncode!=0
    subprocess.run([str(root/'bin/fm-lab-home.sh'),'create',str(lab)],env=env,check=True,stdout=subprocess.PIPE)
    (lab/'config/backend').write_text('tmux\n')
    original=(evidence/'live-backlog-before.md').read_bytes()
    (lab/'data/backlog.md').write_bytes(original)
    p=subprocess.run([str(root/'bin/fm-session-start.sh'),'--reemit'],env=env,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=145,check=True)
    (evidence/'live-startup-unavailable.txt').write_bytes(p.stdout)
    text=p.stdout.decode('utf-8','strict')
    assert 'tasks-axi unavailable or incompatible' in text
    assert '108 parked, 108 watch queued hold(s) shortened' in text
    assert text.count('queued hold(s) shortened;')==1
    assert 'QUIET-DETAIL-' not in text
    assert set(re.findall(r'^- \[ \] quiet-(\d+) - ',text,re.M))==set(map(str,range(1,217)))
    for detail in ['QUESTION-DETAIL (choose one)','second question line','Captain call CALL-DETAIL','Needs the captain NEEDS-DETAIL','watch lower case LOWERCASE-DETAIL','Please Watch NONPREFIX-DETAIL','BLOCKED-PARKED-DETAIL (all kept)','second blocked line','Watch BLOCKED-WATCH-DETAIL (all kept)','second watch line','LIVE-PARKED-DETAIL (all kept)','second live line','Wait LIVE-WATCH-DETAIL (all kept)','second watch live line','Watch EXTERNAL-DETAIL','Wait FUTURE-DETAIL','Watch LOAD-DETAIL']:
        assert detail in text,detail
    assert (lab/'data/backlog.md').read_bytes()==original
    begin=text.index('compact backlog listing (')
    end=text.find('\n\n',text.index('Full task bodies remain available on demand:',begin))
    (evidence/'live-backlog-rendered-unavailable.txt').write_text(text[begin:end if end!=-1 else len(text)])
    result={'tool_absent_from_path':True,'valid_utf8':True,'exact_counts':'108 parked, 108 watch','all_216_identities_present':True,'protected_rows':'all reasons retained in full','backlog_unchanged':True}
    (evidence/'missing-tool-results.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))
finally:
    shutil.rmtree(lab)
