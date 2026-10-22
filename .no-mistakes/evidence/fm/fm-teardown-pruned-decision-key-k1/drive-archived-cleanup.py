import os, subprocess, pathlib, shutil, json, hashlib, time, sys
ROOT=pathlib.Path.cwd()
EVIDENCE=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M5HE5B2T4PX6W0SD17VS5PYR')
LABROOT=ROOT/'.lv'
BASE=ROOT/'bin/.fm-captain-hold-baseline.sh'
assert not LABROOT.exists() and not BASE.exists()
LABROOT.mkdir()
base_env=dict(os.environ)
for key in list(base_env):
    if (key.startswith('FM_') and (key.endswith('_OVERRIDE') or key in ['FM_HOME','FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','FM_TASK_ID'])) or key in ['TASKS_AXI_FILE','TASKS_AXI_BACKEND','TMUX']:
        base_env.pop(key,None)
prior=json.loads((EVIDENCE/"scenario-results.json").read_text()) if sys.argv[1:] else []
results=[]
log=None

def run(args,home,expected=0):
    env=dict(base_env,FM_HOME=str(home),TMPDIR=str(home/'tmp'),TMUX=str(LABROOT/'s')+',0,0')
    log.write('$ '+ ' '.join(map(str,args))+'\n');log.flush()
    p=subprocess.run(list(map(str,args)),cwd=home,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=45)
    log.write(p.stdout+'[exit '+str(p.returncode)+']\n');log.flush()
    if expected is not None:
        assert (p.returncode==0)==(expected==0), (args,p.returncode,p.stdout)
    return p

def cap(home,*args,expected=0,baseline=False):
    return run(['bash',BASE if baseline else ROOT/'bin/fm-captain-hold.sh',*args],home,expected)

def tasks(home,*args,expected=0):
    return run(['tasks-axi',*args],home,expected)

try:
    BASE.write_bytes(subprocess.check_output(['git','show','9a124ef969e2a20d33fa66e92ce0dddd93fda254:bin/fm-captain-hold.sh']))
    cases=['answered-program','answered-sibilant','released-custom','legacy','unanswered','held-annotation','missing','live-shadow','wrong-origin','duplicate','active-live']
    if sys.argv[1:]: cases=sys.argv[1:]
    for case in cases:
        start=time.time()
        home=LABROOT/case
        logpath=EVIDENCE/(case+'.log')
        log=logpath.open('w')
        try:
            run(['bash',ROOT/'bin/fm-lab-home.sh','create',home],ROOT)
        except FileNotFoundError:
            raise
        (home/'tmp').mkdir()
        archive=home/'data'/('retained calls #1.md' if case=='released-custom' else 'done-archive.md')
        (home/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "'+str(archive.relative_to(home))+'"\ndone_keep = 10\n')
        (home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
        origin={'answered-program':'pv-voice-reliability-program-p1','answered-sibilant':'pv-voice-sibilant-listen-l1'}.get(case,'review-'+case)
        call={'answered-program':'pv-voice-reliability-program-approve-a1','answered-sibilant':'pv-voice-sibilant-listen-l1-review'}.get(case,'call-'+case)
        if case=='legacy':call=origin+'-decision-choice'
        tasks(home,'add',origin,'Completed scout awaiting cleanup','--kind','scout','--repo','sample','--start')
        meta=home/'state'/(origin+'.meta')
        scratch=home/'projects'/('departed-'+origin)
        if case=='missing':
            scratch.mkdir()
            (scratch/'uncommitted-research.txt').write_text('Preserve this unfinished scratch work.\n')
        meta.write_text('window=fm-lab-cleanup:fm-'+origin+'\nworktree='+str(home/'projects'/('departed-'+origin))+'\nproject='+str(home/'projects/sample')+'\nharness=codex\nkind=scout\nspawn_gen=lab-'+origin+'\ndecisions_reviewed=1\ndecision_keys='+('choice' if case=='legacy' else call)+'\n')
        report=home/'data'/origin/'report.md'
        report.parent.mkdir()
        report.write_text('# Scout report\n\nInvestigation complete; keep this report after cleanup.\n')
        digest=hashlib.sha256(report.read_bytes()).hexdigest()
        (home/'state'/(origin+'.status')).write_text('done: report complete\n')
        positive=case in ['answered-program','answered-sibilant','released-custom','legacy','active-live']
        if case!='missing':
            cap(home,'hold',call,'--title','Choose the review outcome','--reason','Captain choice pending','--repo','sample','--origin','another-review' if case=='wrong-origin' else origin)
            if case not in ['unanswered','held-annotation','active-live']:
                decision=home/'answer.txt';decision.write_text('Close it, keep the report.\n')
                cap(home,'answer',call,'--decision-file',decision,*(['--release'] if case=='released-custom' else []))
                if case=='released-custom':tasks(home,'done',call)
            elif case!='active-live':tasks(home,'done',call)
            if case!='active-live':
                if case in ['answered-program','answered-sibilant','released-custom','legacy']:
                    cap(home,'complete',origin,call)
                    cap(home,'verify',origin)
                tasks(home,'prune','--keep','0')
                tasks(home,'show',call,'--full',expected=1)
                log.write('PERSISTED DONE ARCHIVE:\n'+archive.read_text()+'\n')
                if case=='held-annotation':archive.write_text(archive.read_text().replace('- [x]','- [ ]'))
                if case=='live-shadow':tasks(home,'add',call,'Reopened call without recorded answer','--repo','sample')
                if case=='duplicate':archive.write_text(archive.read_text()+'\n'+archive.read_text())
        archive_before=archive.read_bytes() if archive.exists() else None
        if case=='answered-program':
            old=cap(home,'complete',origin,'--none',baseline=True,expected=1)
            assert 'no captain-held task' in old.stdout,old.stdout
            old=run(['bash',ROOT/'bin/fm-remote-job-reap-orphans.sh','--dry-run'],home)
            assert not old.stdout.strip(),'Unsafe external orphan cleanup candidates: '+old.stdout
        want=0 if positive else 1
        cap(home,'verify',origin,expected=want)
        cap(home,'complete',origin,'--none',expected=want)
        if case=='answered-program':
            # Archive lookup is read-only inventory support, not an answer mutation path.
            cap(home,'answer',call,'--decision-file',home/'answer.txt',expected=1)
        p=run(['bash',ROOT/'bin/fm-teardown.sh',origin],home,expected=want)
        if positive:
            assert not meta.exists(),'cleanup retained task metadata'
            tasks(home,'show',origin,'--full')
            assert 'state: done' in tasks(home,'show',origin,'--full').stdout
            log.write('PERSISTED RESULT: task metadata removed; origin is done.\n')
        else:
            assert 'has not passed the captain-call completion gate' in p.stdout,p.stdout
            assert meta.exists(),'refusal removed task metadata'
            log.write('PERSISTED RESULT: refusal preserved task metadata.\n')
        if case=='missing':
            assert (scratch/'uncommitted-research.txt').read_text()=='Preserve this unfinished scratch work.\n'
            log.write('PERSISTED RESULT: refused cleanup preserved the existing scratch directory and its uncommitted file.\n')
        assert hashlib.sha256(report.read_bytes()).hexdigest()==digest,'report changed'
        assert (archive.read_bytes() if archive.exists() else None)==archive_before,'inventory/cleanup mutated archive'
        log.write('PERSISTED RESULT: report bytes preserved; done archive unchanged.\n')
        results.append({'case':case,'result':'pass','live':True,'evidence':str(logpath)})
        log.close();log=None
        print(case+': PASS ('+str(round(time.time()-start,1))+'s)',flush=True)
        shutil.rmtree(home)
except Exception as e:
    if log:
        log.write('DRIVER FAILURE: '+repr(e)+'\n');log.close();log=None
    results.append({'case':locals().get('case','setup'),'result':'fail','live':True,'error':repr(e)})
    print('FAILED: '+repr(e),flush=True)
finally:
    if BASE.exists():BASE.unlink()
    shutil.rmtree(LABROOT)
    merged={r['case']:r for r in prior}
    merged.update({r['case']:r for r in results})
    (EVIDENCE/'scenario-results.json').write_text(json.dumps(list(merged.values()),indent=2)+'\n')
if any(r['result']=='fail' for r in results):raise SystemExit(1)
