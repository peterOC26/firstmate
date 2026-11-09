import json,os,pathlib,shutil,subprocess,tempfile
root=pathlib.Path.cwd(); e=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M6ZBQ4CZ3WC42Z1TBFHN3JK9')
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('PI_CODING_AGENT','CLAUDECODE','CURSOR_AGENT','CURSOR_INVOKED_AS','GEMINI_CLI','GROK_AGENT')}
h=pathlib.Path(tempfile.mkdtemp(prefix='.fm-lab-base-',dir=root))
b=root/'bin/.fm-wake-drain-before-live-test.sh'
try:
    b.write_bytes(subprocess.check_output(['git','show','b49691a1:bin/fm-wake-drain.sh']))
    with (e/'pre-review-counterfactual.log').open('w') as log:
        def run(*args):
            p=subprocess.run(list(map(str,args)),cwd=root,env={**env,'FM_HOME':str(h)},capture_output=True,text=True,timeout=45)
            log.write('$ '+' '.join(map(str,args))+'\n'+p.stdout+p.stderr+f'\n[exit {p.returncode}]\n');log.flush()
            assert p.returncode==0,p.stderr
            return p.stdout
        run('bin/fm-lab-home.sh','create',h);(h/'config/supervision-host').touch()
        run('bin/fm-branch-outcome.sh','append','--task','gamma','--verdict','captain','--summary','stage complete','--continuation','Start authorized validation.')
        run('bin/fm-branch-outcome.sh','append','--task','gamma','--verdict','captain','--summary','later CI note')
        out=run('bash',b)
        assert 'later CI note' in out and 'Start authorized validation.' not in out
        assert 'start the authorized spawn, steer, or handoff before acknowledging' not in out
        log.write('OBSERVED: newer plain captain row hides the older continuation; processing instruction omits continuation duty.\n')
        run('bin/fm-branch-outcome.sh','append','--task','delta','--verdict','captain','--summary','x'*250,'--continuation','y'*700+' Start authorized step at tail.')
        out=run('bash',b)
        assert '[truncated]' in out and 'lookup --seqs 3' not in out and 'Start authorized step at tail.' not in out
        log.write('OBSERVED: capped handoff loses the authorized tail and provides no full-outcome lookup.\n')
    print('Pre-review reproduction confirmed all three reported defects; evidence saved.')
finally:
    b.unlink(missing_ok=True);shutil.rmtree(h)
