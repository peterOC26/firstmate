import os,subprocess,tempfile,time,pathlib,json,shutil
root=os.getcwd();E=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M6ZGFZ4MA04RTKC9RGZFD8DV');lab=tempfile.mkdtemp(prefix='fm-lab.',dir='/tmp');env=os.environ.copy();result={};log=[]
for k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']:env.pop(k,None)
env['TMUX_TMPDIR']=lab+'/tmux'
def run(a,**kw):return subprocess.run(a,env=env,text=True,capture_output=True,**kw)
def tm(*a):return run(['tmux','-L','fm-lab',*a])
def cap(label):p=tm('capture-pane','-p','-S','-220','-t','primary');log.append('\n'+label+'\n'+p.stdout+p.stderr)
def say(s):tm('send-keys','-t','primary','-l',s);time.sleep(1.3);tm('send-keys','-t','primary','Enter')
def wait(pred,secs):
 for _ in range(secs):
  if pred():return True
  time.sleep(1)
 return False
try:
 p=run(['bash','bin/fm-lab-home.sh','create',lab]);assert p.returncode==0,p.stderr
 pathlib.Path(lab+'/tmux').mkdir();pathlib.Path(lab+'/config/backlog-backend').write_text('manual\n')
 cli=['pi','--offline','--approve','--no-tools','--no-context-files','--no-skills','--no-extensions','-e',root+'/.pi/extensions/fm-primary-pi-watch.ts','--session-dir',lab+'/sessions']
 p=tm('new-session','-d','-s','primary','-x','160','-y','48','-c',root,'-e','FM_HOME='+lab,*cli);assert p.returncode==0,p.stderr
 time.sleep(4);say('!bin/fm-session-start.sh');state=pathlib.Path(lab+'/state')
 assert wait(lambda:(state/'.session-start-complete').exists(),60),'manual real primary sessionstart did not complete'
 time.sleep(3);say('/fm-watch-arm-pi')
 assert wait(lambda:(state/'.watch.lock').exists(),30),'real Pi watch did not arm';cap('real watcher armed')
 noteenv=env.copy();noteenv.update(FM_HOME=lab,FM_AFK_MODE='quiet')
 p=subprocess.run(['bash','bin/fm-afk-contract.sh','enter','--words','remain quiet while present'],env=noteenv,text=True,capture_output=True);assert p.returncode==0,p.stderr;log.append(p.stdout)
 p=subprocess.run(['bash','bin/fm-inbox.sh','note','--json','Quiet-mode note: stay present.'],env=noteenv,text=True,capture_output=True);assert p.returncode==0,p.stderr;log.append(p.stdout);note_id=json.loads(p.stdout)['id']
 def watcher_prompts():
  prompts=[]
  for f in pathlib.Path(lab+'/sessions').rglob('*.jsonl'):
   for line in f.read_text().splitlines():
    row=json.loads(line);m=row.get('message',{})
    if m.get('role')=='user':
     content=m.get('content',[]);text=content if isinstance(content,str) else '\n'.join(x.get('text','') for x in content if isinstance(x,dict))
     if 'FIRSTMATE WATCHER WAKE:' in text:prompts.append(text)
  return prompts
 assert wait(lambda:len(watcher_prompts())>0,45),'no real watcher follow-up delivered'
 prompts=watcher_prompts();log.append('ACTUAL GENERATED USER PROMPT\n'+'\n'.join(prompts));cap('quiet note delivered to main')
 assert all('the captain sent a note and away mode should end' not in x for x in prompts),'quiet note got away-return signal'
 assert (state/'.afk-contract').exists(),'quiet record was removed'
 result.update(no_away_return_signal=True,quiet_record_retained=True,note_id=note_id)
 for f in pathlib.Path(lab+'/sessions').rglob('*.jsonl'):shutil.copyfile(f,E/'pi-quiet-live-session.jsonl')
except Exception as e:result['error']=str(e);cap('error')
finally:
 tm('kill-server')
 for lock in ['.watch.lock','.supervise-daemon.lock']:
  f=pathlib.Path(lab+'/state/'+lock+'/pid')
  if f.exists():
   try:os.kill(int(f.read_text().strip()),15)
   except (ValueError,ProcessLookupError):pass
 time.sleep(1);shutil.rmtree(lab);log.append('CLEANUP: private tmux server stopped and disposable home removed.')
 (E/'pi-quiet-live.log').write_text('\n'.join(log));(E/'pi-quiet-live-result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
