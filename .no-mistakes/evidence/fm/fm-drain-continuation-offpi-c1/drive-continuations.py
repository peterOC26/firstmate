import json, os, pathlib, re, shutil, subprocess, tempfile
ROOT=pathlib.Path.cwd()
E=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M6ZBQ4CZ3WC42Z1TBFHN3JK9')
log=(E/'live-cli-transcript.log').open('w')
results=[]
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ('PI_CODING_AGENT','CLAUDECODE','CURSOR_AGENT','CURSOR_INVOKED_AS','GEMINI_CLI','GROK_AGENT'):
        env.pop(k,None)

def run(home,*args,ok=True):
    cmd=list(map(str,args))
    p=subprocess.run(cmd,cwd=ROOT,env={**env,'FM_HOME':str(home)},capture_output=True,text=True,timeout=45)
    log.write('$ '+ ' '.join(cmd)+'\n'+p.stdout+p.stderr+f'\n[exit {p.returncode}]\n')
    log.flush()
    if ok: assert p.returncode==0,(cmd,p.returncode,p.stderr)
    return p

def append(home,task,summary,cont=None,verdict='captain',silent=False):
    args=['bin/fm-branch-outcome.sh','append','--task',task,'--verdict',verdict,'--summary',summary]
    if cont is not None: args+=['--continuation',cont]
    if silent: args+=['--silent','true']
    return int(run(home,*args).stdout.strip())

def drain(home): return run(home,'bin/fm-wake-drain.sh').stdout

def ack(home,n): return run(home,'bin/fm-branch-outcome.sh','mark-processed','--through',str(n))

def scenario(name,fn):
    home=pathlib.Path(tempfile.mkdtemp(prefix='.fm-lab-drain-',dir=ROOT))
    log.write('\nSCENARIO: '+name+'\n')
    try:
        run(home,'bin/fm-lab-home.sh','create',home)
        (home/'config/supervision-host').touch()
        fn(home)
        results.append({'name':name,'result':'pass','live':True,'evidence':'live-cli-transcript.log','reason':''})
    except Exception as ex:
        results.append({'name':name,'result':'fail','live':True,'evidence':'live-cli-transcript.log','reason':str(ex)})
        log.write('FAIL: '+repr(ex)+'\n')
    finally:
        shutil.rmtree(home)
        log.write('[disposable home removed]\n')
        log.flush()


def repeated(h):
    c='Stage complete.\nStart\tthe authorized validation;\rthen report its result.'
    append(h,'gamma','implementation complete',c)
    append(h,'legacy','needs a decision')
    append(h,'routine','visible progress',verdict='routine')
    append(h,'routine','private no-change',verdict='routine',silent=True)
    for i in range(2):
        out=drain(h)
        assert 'gamma: implementation complete; MAIN continuation handoff: Stage complete. Start the authorized validation; then report its result.' in out
        assert re.search(r'^\[seq 2, recorded .*\] legacy: needs a decision$',out,re.M)
        assert ('visible progress' in out)==(i==0)
        assert 'private no-change' not in out
        assert 'mark-processed --through 2;' in out
        assert not (h/'state/.branch-outcomes-processed').exists()
    ack(h,2)
    assert 'BRANCH OUTCOMES' not in drain(h)
    assert run(h,'bin/fm-branch-outcome.sh','unprocessed').stdout==''
    assert run(h,'bin/fm-branch-outcome.sh','mark-processed','--through','2',ok=False).returncode!=0


def collapsed(h):
    append(h,'gamma','stage 1 complete','Start authorized step 1.')
    append(h,'gamma','CI note 1')
    append(h,'gamma','stage 2 complete','Start authorized step 2.')
    append(h,'gamma','CI note 2')
    for i in range(2):
        out=drain(h)
        assert 'MAIN continuation handoff: Start authorized step 1.' in out
        assert 'MAIN continuation handoff: Start authorized step 2.' in out
        assert 'gamma: CI note 2' in out and 'gamma: CI note 1' not in out
        assert len(re.findall(r'^\[seq ',out,re.M))==3
        assert 'mark-processed --through 4;' in out
    ack(h,4)
    assert 'BRANCH OUTCOMES' not in drain(h)


def overflow(h):
    pad='界'*700
    for n in range(1,9): append(h,'gamma','stage complete' if n%2 else pad,pad+f' Start authorized step {n}.')
    append(h,'gamma','later CI note')
    out=drain(h)
    lines=re.findall(r'^\[seq .*$',out,re.M)
    assert len(lines)==6 and sum(len((x+'\n').encode()) for x in lines)<=4000
    for n,line in enumerate(lines,1):
        assert len((line+'\n').encode())<=600
        assert '[truncated]' in line and line.endswith(f'bin/fm-branch-outcome.sh lookup --seqs {n}')
        full=json.loads(run(h,'bin/fm-branch-outcome.sh','lookup','--seqs',str(n)).stdout)
        assert full['continuation']==pad+f' Start authorized step {n}.'
    assert '3 newer captain outcome(s) are held back' in out
    assert 'mark-processed --through 6;' in out and 'later CI note' not in out
    ack(h,6)
    out=drain(h)
    assert 'lookup --seqs 7' in out and 'lookup --seqs 8' in out and 'later CI note' in out
    assert 'mark-processed --through 9;' in out
    ack(h,9)
    assert 'BRANCH OUTCOMES' not in drain(h)


def instructions(h):
    append(h,'gamma','stage complete','Start authorized validation.')
    out=drain(h)
    for s in ['reconcile current task/stage state and existing authority','start the authorized spawn, steer, or handoff before acknowledging','if already started, do not duplicate it','Record the actual blocker, decision, or evidence that no further action is needed','read the full outcome using its lookup --seqs command before acting or acknowledging']:
        assert s in out
    assert not (h/'state/.branch-outcomes-processed').exists()

scenario('Drain repeats a multiline continuation until acknowledged and preserves legacy/routine behavior',repeated)
scenario('Newer plain notes and another handoff cannot hide an older continuation for the same task',collapsed)
scenario('Long UTF-8 handoffs stay bounded, resolve through full lookups, and overflow follows contiguous acknowledgements',overflow)
scenario('The delivered processing prompt requires authorized continuation handling before acknowledgement',instructions)
(E/'live-scenario-results.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
log.close()
raise SystemExit(any(x['result']!='pass' for x in results))
