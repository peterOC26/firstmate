import json, os, subprocess, tempfile, time
from pathlib import Path
ROOT=Path.cwd()
OUT=Path('/home/zabi/.no-mistakes/evidence/01M70ZWTQ5G7TSJS9ADMRENWFG')
report={'name':'A real primary receives plain /afk and records standing words without an additional confirmation','result':'untested','live':False,'evidence':'primary-transcript.txt','reason':''}
transcript=[]
# Private, disposable development-tool home and tmux socket, per the trusted lab runbook.
with tempfile.TemporaryDirectory(prefix='fm-lab.',dir='/tmp') as tmp:
    lab=Path(tmp)
    subprocess.run(['bin/fm-lab-home.sh','create',str(lab)],check=True,stdout=subprocess.PIPE)
    (lab/'tmux').mkdir()
    (lab/'config/supervision-host').touch()
    (lab/'config/afk-words').write_text('Keep routine work moving.\nDo not merge or discard anything.\n')
    env=dict(os.environ)
    for key in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']:
        env.pop(key,None)
    env['TMUX_TMPDIR']=str(lab/'tmux')
    def tmux(*args,check=True):
        return subprocess.run(['tmux','-L','fm-lab',*args],env=env,check=check,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    try:
        tmux('new-session','-d','-x','120','-y','42','-s','primary','-c',str(ROOT),'-e',f'FM_HOME={lab}','claude')
        sent=False
        for i in range(60):
            time.sleep(2)
            pane=tmux('capture-pane','-p','-t','primary').stdout
            transcript.append(f'--- {2*(i+1)}s ---\n{pane}')
            (OUT/'primary-transcript.txt').write_text('\n'.join(transcript))
            if any(s in pane for s in ['Quick safety check','trust this folder','Is this a project you created','Allow external CLAUDE.md','Do you trust the files']):
                report['reason']='Claude requires workspace trust or external-import approval for this fresh worktree. Accepting it would modify user-level Claude configuration outside the permitted workspace. Pre-approve this exact worktree in Claude, or authorize that one configuration change, then rerun.'
                break
            if any(s in pane for s in ['Select login method','Please run /login','Not logged in','Sign in to Claude']):
                report['reason']='The real Claude primary requested login despite the existing-login status probe; sign in outside this validation run and rerun.'
                break
            if not sent and ('❯' in pane or 'Try "' in pane):
                tmux('send-keys','-t','primary','-l','/afk')
                tmux('send-keys','-t','primary','Enter')
                sent=True
                report['live']=True
            record=lab/'state/.afk-contract'
            if sent and record.exists():
                time.sleep(8)
                pane=tmux('capture-pane','-p','-S','-500','-t','primary').stdout
                transcript.append('--- after entry ---\n'+pane)
                (OUT/'primary-transcript.txt').write_text('\n'.join(transcript))
                (OUT/'primary-entry.afk-contract').write_bytes(record.read_bytes())
                result=subprocess.run(['bin/fm-afk-contract.sh','words'],env=env|{'FM_HOME':str(lab)},stdout=subprocess.PIPE,stderr=subprocess.PIPE)
                source=subprocess.run(['bin/fm-afk-contract.sh','field','source'],env=env|{'FM_HOME':str(lab)},stdout=subprocess.PIPE,stderr=subprocess.PIPE)
                if result.returncode==0 and result.stdout==(lab/'config/afk-words').read_bytes() and source.stdout.strip()==b'config/afk-words':
                    report['result']='pass'
                    report['reason']=''
                else:
                    report['result']='fail'
                    report['reason']='The real primary created a record without the expected standing words and source.'
                break
        else:
            report['reason']='The Claude primary did not reach a usable input surface or create the away record within 120 seconds; see primary transcript.'
    except Exception as exc:
        report['reason']='Disposable primary setup failed: '+repr(exc)
    finally:
        tmux('kill-server',check=False)
        transcript.append('Cleanup: killed only the private fm-lab tmux server; disposable lab home removed on context exit.')
        (OUT/'primary-transcript.txt').write_text('\n'.join(transcript))
(OUT/'primary-result.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report),flush=True)
