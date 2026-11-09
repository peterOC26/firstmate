import os, subprocess, tempfile, time, pathlib, json, shutil, html, shlex
root=os.getcwd(); E=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M6ZGFZ4MA04RTKC9RGZFD8DV'); lab=tempfile.mkdtemp(prefix='fm-lab.',dir='/tmp'); env=os.environ.copy()
for k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']:env.pop(k,None)
env.update(TMUX_TMPDIR=lab+'/tmux',FM_HOUSEKEEPING_TICK='1',FM_POLL='1',FM_ESCALATE_BATCH_SECS='0')
log=open(E/'codex-guard-live-return.log','w');last='';outcome={};panes=[]
def run(a,**kw):return subprocess.run(a,env=env,text=True,capture_output=True,**kw)
def tm(*a):return run(['tmux','-L','fm-lab',*a])
def cap(label):
 global last
 p=tm('capture-pane','-p','-S','-450','-t','primary');last=p.stdout;log.write('\n--- '+label+' ---\n'+last+p.stderr);log.flush();panes.append((label,last));return last
def waitfor(label,pred,budget):
 start=time.monotonic()
 while time.monotonic()-start<budget:
  time.sleep(3)
  p=tm('capture-pane','-p','-t','primary')
  if p.returncode or any(x in p.stdout.lower() for x in ['not logged in','please run /login','quick safety check','allow external claude.md','select login method']):cap('startup blocker');return False
  if pred():cap(label);return True
 cap(label+' TIMED OUT');return False
def say(s):
 tm('send-keys','-t','primary','-l',s);time.sleep(1);tm('send-keys','-t','primary','Enter')
try:
 p=run(['bash','bin/fm-lab-home.sh','create',lab]);assert p.returncode==0,p.stderr
 pathlib.Path(lab+'/tmux').mkdir();pathlib.Path(lab+'/config/backlog-backend').write_text('manual\n');pathlib.Path(lab+'/config/supervision-host-off').touch()
 pathlib.Path(lab+'/afk-policy.md').write_text(pathlib.Path('.agents/skills/afk/SKILL.md').read_text()+'\nThis is an isolated live validation home. Never change code, install tools, launch workers, or access another Firstmate home. All operational data is under FM_HOME.\n')
 prompt='You are a real primary in a marked disposable lab home for live Firstmate validation. All state belongs under FM_HOME; never alter code, install tools, launch workers, or touch other homes. Read .agents/skills/afk/SKILL.md for later away/return behavior. Run bin/fm-session-start.sh exactly once to initialize this empty isolated home, then wait for my next message. Do not arm a separate watcher.'
 launch='exec codex --dangerously-bypass-approvals-and-sandbox --disable hooks --no-alt-screen '+shlex.quote(prompt)
 p=tm('new-session','-d','-s','primary','-x','160','-y','48','-c',root,'-e','FM_HOME='+lab,launch);assert p.returncode==0,p.stderr
 state=pathlib.Path(lab+'/state')
 assert waitfor('primary initialized',lambda:(state/'.session-start-complete').exists(),100),'Codex initialization blocked or timed out'
 time.sleep(10);say('I am going afk. Watch the empty fleet; do not launch any workers.')
 assert waitfor('away daemon running',lambda:(state/'.afk-contract').exists() and (state/'.supervise-daemon.pid').exists(),120),'away daemon did not start'
 time.sleep(10);cap('away posture before note')
 tm('send-keys','-t','primary','-l','unfinished human draft, do not submit');time.sleep(1)
 noteenv=env.copy();noteenv['FM_HOME']=lab
 p=subprocess.run(['bash','bin/fm-inbox.sh','note','--json','Jobs note: I am back. Please reply with the word BLUEBELL.'],env=noteenv,text=True,capture_output=True)
 log.write('\nINBOX PUBLICATION\n'+p.stdout+p.stderr);log.flush();assert p.returncode==0,p.stderr
 outcome['note_id']=json.loads(p.stdout)['id']
 time.sleep(10);cap('occupied composer after note publication')
 queued=(state/'.wake-queue').read_text();daemonlog=(state/'.supervise-daemon.log').read_text()
 log.write('\nDEFERRED QUEUE\n'+queued+'\nDAEMON BEFORE CLEAR\n'+daemonlog);log.flush()
 outcome['composer_guard_retained_rows']=(state/'.afk-contract').exists() and '\tcheck\tinbox:' in queued
 outcome['deferred_delivery_logged']='captain inbox hand-back deferred:' in daemonlog
 assert outcome['composer_guard_retained_rows'] and outcome['deferred_delivery_logged'],'composer guard did not retain the pending note'
 tm('send-keys','-t','primary','C-u');log.write('\nHuman cleared the unfinished composer draft with C-u; no submit.\n');log.flush()
 assert waitfor('away record archived',lambda:not (state/'.afk-contract').exists(),150),'inbox note did not end away mode'
 outcome['away_ended']=True
 # Give main time to drain and answer after the archive boundary.
 waitfor('answer visible',lambda:'BLUEBELL' in tm('capture-pane','-p','-S','-300','-t','primary').stdout and not (state/'.afk-return-pending').exists(),80)
 time.sleep(12);cap('main after return')
 outcome['archived_records']=len(list((state/'afk-contracts').glob('*')))
except Exception as e:
 outcome['error']=str(e);cap('error')
finally:
 for name in ['.supervise-daemon.log','.wake-queue','.wake-recovery']:
  f=pathlib.Path(lab+'/state/'+name)
  if f.is_file():log.write('\nSTATE '+name+'\n'+f.read_text())
 tm('kill-server')
 for lock in ['.watch.lock','.supervise-daemon.lock']:
  f=pathlib.Path(lab+'/state/'+lock+'/pid')
  if f.exists():
   try:os.kill(int(f.read_text().strip()),15)
   except (ValueError,ProcessLookupError):pass
 time.sleep(1);shutil.rmtree(lab);log.write('\nCLEANUP: private fm-lab tmux stopped; lab removed.\n');log.close()
 (E/'codex-guard-live-result.json').write_text(json.dumps(outcome,indent=2)+'\n')
 (E/'codex-guard-live-terminal.html').write_text('<!doctype html><meta charset="utf-8"><title>Actual Codex primary terminal captures</title><style>body{background:#171717;color:#eee;font:14px monospace}pre{white-space:pre-wrap;border:1px solid #555;padding:16px}</style>'+''.join('<h2>'+html.escape(label)+'</h2><pre>'+html.escape(body)+'</pre>' for label,body in panes))
 print(json.dumps(outcome));print(last[-5500:])
