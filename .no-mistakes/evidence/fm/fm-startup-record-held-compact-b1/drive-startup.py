import base64, csv, hashlib, json, os, pathlib, shutil, subprocess, tempfile, time
root = pathlib.Path.cwd()
evidence = pathlib.Path('/home/zabi/.no-mistakes/evidence/01M6ZCS9R68WB76FATEE4KBC8C')
lab = pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.', dir=root/'.live-startup-validation'))
env = dict(os.environ)
for key in list(env):
    if key.startswith(('FM_', 'HERDR_', 'TASKS_AXI_')) or key in ('NO_MISTAKES_GATE','TMUX','CLAUDECODE','PI_CODING_AGENT','GROK_AGENT','REX_SESSION','REX_BLOCK'):
        env.pop(key, None)
env.update(FM_HOME=str(lab), FM_SESSION_START_QUEUED_LIMIT='1')

def command(args, *, save=None):
    p = subprocess.run([str(x) for x in args], cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=145)
    if save:
        (evidence/save).write_bytes(p.stdout)
    if p.returncode:
        raise RuntimeError(f'{args[0:3]} exited {p.returncode}: {p.stdout.decode(errors="replace")}')
    return p.stdout

def axi(*args):
    return command([root/'bin/fm-tasks-axi.sh', *args])

def encoded(reason):
    return 'fm-hold-v1:' + base64.b64encode(reason.encode()).decode()

def add(id, title, kind=None, reason=None, start=False, blocked=False):
    args=['add',id,title,'--kind','ship','--repo','lab']
    if blocked: args += ['--blocked-by','dependency']
    axi(*args)
    if kind: axi('hold',id,'--kind',kind,'--reason',encoded(reason))
    if start: axi('start',id)

try:
    command([root/'bin/fm-lab-home.sh','create',lab])
    (lab/'config/backend').write_text('tmux\n')
    (lab/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    add('dependency','Unfinished dependency')
    for i in range(1,217):
        kind='parked' if i <= 108 else 'captain'
        reason=('Parked ' if i <= 108 else ('Watch ' if i <= 162 else 'Wait '))+'QUIET-DETAIL-'+('long preserved prose (with punctuation)\n'*12)
        title=f'Quiet, "quoted" job {i}'
        n=(i-1)%108
        if n<6:
            glyph,boundary=[('é',116),('€',116),('€',115),('🚢',116),('🚢',115),('🚢',114)][n]
            prefix=f'- [ ] quiet-{i} - '
            title='a'*(boundary-len(prefix.encode()))+glyph*5
        add(f'quiet-{i}',title,kind,reason)
    protected = {
        'captain-question':('captain','Which option? QUESTION-DETAIL (choose one)\nsecond question line',False,False),
        'captain-call':('captain','Captain call CALL-DETAIL',False,False),
        'captain-needs':('captain','Needs the captain NEEDS-DETAIL',False,False),
        'captain-lowercase':('captain','watch lower case LOWERCASE-DETAIL',False,False),
        'captain-nonprefix':('captain','Please Watch NONPREFIX-DETAIL',False,False),
        'blocked-parked':('parked','BLOCKED-PARKED-DETAIL (all kept)\nsecond blocked line',False,True),
        'blocked-watch':('captain','Watch BLOCKED-WATCH-DETAIL (all kept)\nsecond watch line',False,True),
        'live-parked':('parked','LIVE-PARKED-DETAIL (all kept)\nsecond live line',True,False),
        'live-watch':('captain','Wait LIVE-WATCH-DETAIL (all kept)\nsecond watch live line',True,False),
        'external':('external','Watch EXTERNAL-DETAIL',False,False),
        'future':('future','Wait FUTURE-DETAIL',False,False),
        'load':('load','Watch LOAD-DETAIL',False,False),
    }
    for id,(kind,reason,start,blocked) in protected.items():
        add(id,id+' title',kind,reason,start,blocked)
    add('plain-second','Another ready item')
    add('completed','Completed item')
    axi('done','completed')
    original=(lab/'data/backlog.md').read_bytes()
    (evidence/'live-backlog-before.md').write_bytes(original)
    results={}
    for mode in ('tasks-axi','manual'):
        if mode=='manual': (lab/'config/backlog-backend').write_text('manual\n')
        data=command([root/'bin/fm-session-start.sh','--reemit'],save=f'live-startup-{mode}.txt')
        text=data.decode('utf-8',errors='strict')
        assert '(108 parked, 108 watch queued hold(s) shortened;' in text, mode
        assert text.count('queued hold(s) shortened;')==1, mode
        assert 'QUIET-DETAIL-' not in text, mode
        for i in range(1,217):
            assert f'quiet-{i}' in text, (mode,i)
        for id,(_,reason,_,_) in protected.items():
            for line in reason.splitlines(): assert line in text, (mode,id,line)
        assert 'bin/fm-tasks-axi.sh show <id> --full' in text
        assert 'completed title' not in text
        assert (lab/'data/backlog.md').read_bytes()==original, mode
        backlog=text.split('compact backlog listing (',1)[1].split('\nlearnings',1)[0]
        # The executable labels its context sections with rules; keep the full
        # digest as evidence and measure just the public backlog subsection.
        begin=text.index('compact backlog listing (')
        end=text.find('\n\n',text.index('Full task bodies remain available on demand:',begin))
        rendered=text[begin:end if end!=-1 else len(text)]
        (evidence/f'live-backlog-rendered-{mode}.txt').write_text(rendered)
        if mode=='tasks-axi':
            assert text.count('BLOCKED-PARKED-DETAIL')==2
            assert text.count('BLOCKED-WATCH-DETAIL')==2
            assert 'tasks-axi;' in rendered
        else:
            assert 'manual backend;' in rendered
            for i in [1,2,3,4,5,6,109,110,111,112,113,114]:
                row=next(line for line in text.splitlines() if line.startswith(f'- [ ] quiet-{i} - '))
                assert '... (hold-kind:' in row, (i,row)
                assert len(row.encode())<=160, (i,len(row.encode()))
        results[mode]={'stored_backlog_bytes':len(original),'rendered_backlog_bytes':len(rendered.encode()),'exact_counts':'108 parked, 108 watch','protected_rows':'all original decoded reasons retained','backlog_unchanged':True,'valid_utf8':True}
    (lab/'config/backlog-backend').write_text('tasks-axi\n')
    detail=axi('show','quiet-109','--full')
    (evidence/'live-full-details.txt').write_bytes(detail)
    assert b'QUIET-DETAIL-' in detail and b'with punctuation' in detail
    results['detail_retrieval']='full encoded multiline Watch reason remains available through fm-tasks-axi.sh show quiet-109 --full'
    (evidence/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
    print(json.dumps(results,indent=2))
finally:
    shutil.rmtree(lab)
