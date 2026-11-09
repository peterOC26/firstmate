import pathlib,tempfile,subprocess,shutil,os,base64,json,re
root=pathlib.Path.cwd(); evidence=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M6ZHHAZ0MNQPFEA26P70W0WH')
lab=pathlib.Path(tempfile.mkdtemp(prefix='.startup-boundary-',dir=root))
env=os.environ.copy()
for key in list(env):
    if key.startswith(('FM_','HERDR_','REX_','TASKS_AXI_')) or key in ('TMUX','CLAUDECODE','PI_CODING_AGENT','GROK_AGENT'): env.pop(key,None)
env.update(FM_HOME=str(lab),TASKS_AXI_BACKEND='markdown')
def run(args):
    p=subprocess.run(args,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=130)
    assert p.returncode==0,p.stdout
    return p.stdout
try:
    run(['bin/fm-lab-home.sh','create',str(lab)])
    (lab/'config/backend').write_text('tmux\n'); (lab/'config/supervision-host-off').touch()
    data='# Backlog\n\n## In flight\n\n## Queued\n'
    reasons={'control':'Needs the captain to choose a disposition',
             'metadata-prose':'Needs the captain to choose (hold-kind: parked) or keep active'}
    for i,reason in reasons.items():
        encoded='fm-hold-v1:'+base64.b64encode(reason.encode()).decode()
        data+=f'- [ ] {i} - Open captain question (hold: {encoded}) (hold-kind: captain)\n'
    data+='\n## Done\n'
    backlog=lab/'data/backlog.md'; backlog.write_text(data)
    evidence.joinpath('boundary-backlog.md').write_text(data)
    results=[]
    for mode in ('tasks-axi','manual'):
        (lab/'config/backlog-backend').write_text(mode+'\n')
        output=run(['bin/fm-session-start.sh','--reemit'])
        evidence.joinpath(f'boundary-{mode}-startup.txt').write_bytes(output)
        text=output.decode('utf8')
        assert not re.search(r'^●  STARTUP TRUNCATED',text,re.M)
        result={'mode':mode,'control_full':reasons['control'] in text,'metadata_prose_full':reasons['metadata-prose'] in text,
                'shortened_summary':[s for s in text.splitlines() if 'queued hold(s) shortened' in s],
                'rows':[s for s in text.splitlines() if s.startswith(('  control,','  metadata-prose,','- [ ] control -','- [ ] metadata-prose -'))]}
        results.append(result)
        assert backlog.read_text()==data
    evidence.joinpath('boundary-results.json').write_text(json.dumps(results,indent=2)+'\n')
    print(json.dumps(results,indent=2))
finally:
    shutil.rmtree(lab); print('Disposable adversarial home removed.')
