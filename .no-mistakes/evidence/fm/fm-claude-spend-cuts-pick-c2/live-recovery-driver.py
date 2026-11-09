import traceback, shlex
import os, subprocess as sp, tempfile, pathlib, shutil, time, json, signal
ROOT=pathlib.Path.cwd()
EV=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M707ZYJDNYM24B7YH8M5C8GA')
records=[]
class Lab:
 def __init__(self,name):
  self.name=name; self.home=pathlib.Path(tempfile.mkdtemp(prefix='.l',dir=ROOT)); self.state=self.home/'state'; self.procs=[]
  self.env=os.environ.copy()
  for k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_TEST_SEAM','FM_TEST_HARNESS','FM_SUPERVISION_ACTOR','FM_BRANCH_REPORT_TURN','FM_LEASE_HOLDER_PID','FM_BACKEND','HERDR_ENV','HERDR_SESSION','HERDR_PANE_ID','HERDR_SOCKET_PATH']:
   self.env.pop(k,None)
  self.env.update(FM_HOME=str(self.home),TMUX_TMPDIR=str(self.home/'tmux'),FM_POLL='1',FM_SIGNAL_GRACE='0',FM_HEARTBEAT='3600',FM_HEARTBEAT_MAX='3600',FM_CHECK_INTERVAL='3600',FM_ARM_CONFIRM_TIMEOUT='15',FM_BACKEND='tmux')
  self.run(['bin/fm-lab-home.sh','create',str(self.home)])
  (self.home/'tmux').mkdir()
  self.run(['tmux','-L','fm-lab','new-session','-d','-s','watcher-lab','-x','120','-y','36','-c',str(ROOT),'bash'])
  self.env['TMUX']=self.run(['tmux','-L','fm-lab','display-message','-p','#{socket_path},#{pid},0']).stdout.strip()
  (self.state/'.wake-queue').touch()
 def log(self,cmd,p):
  records.append({'scenario':self.name,'command':cmd,'exit':p.returncode,'output':p.stdout})
 def run(self,args,input=None,ok=True,extra=None):
  p=sp.run(args,cwd=ROOT,env=self.env| (extra or {}),input=input,text=True,stdout=sp.PIPE,stderr=sp.STDOUT,timeout=25)
  self.log(args,p)
  if ok and p.returncode: raise AssertionError(f'{args}: {p.returncode}: {p.stdout}')
  return p
 def shell(self,script,ok=True):
  return self.run(['bash','-c',script],ok=ok)
 def marker(self):
  p=self.state/'.watcher-down'
  return p.read_text().strip() if p.exists() else ''
 def publish(self):
  self.shell('. bin/fm-wake-lib.sh; fm_recovery_marker_publish "$STATE/.watcher-down" downtime')
  return self.marker().split(':')[-1]
 def drain(self,extra=None):return self.run(['bin/fm-wake-drain.sh'],extra=extra).stdout
 def start(self,label):
  path=EV/(self.name+'-'+label+'.txt'); f=path.open('w')
  p=sp.Popen(['bin/fm-watch-arm.sh'],cwd=ROOT,env=self.env,stdout=f,stderr=sp.STDOUT,start_new_session=True)
  self.procs.append((p,f,path)); return p,path
 def wait(self,predicate,seconds=20):
  end=time.monotonic()+seconds
  while time.monotonic()<end:
   if predicate():return
   time.sleep(.1)
  raise AssertionError('timed out: '+self.name+'; marker='+self.marker())
 def stop(self):
  lock=self.state/'.watch.lock'
  pidfile=lock/'pid'
  if pidfile.is_file():
   self.run(['bin/fm-watch-arm.sh','--stop'],ok=False)
   try:os.kill(int(pidfile.read_text().strip()),signal.SIGTERM)
   except (ProcessLookupError,ValueError,FileNotFoundError):pass
   end=time.monotonic()+8
   while lock.exists() and time.monotonic()<end:time.sleep(.1)
  for p,f,path in self.procs:
   if p.poll() is None:
    os.killpg(p.pid,signal.SIGTERM)
    try:p.wait(timeout=8)
    except sp.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
   f.close()
  self.procs=[]
 def snapshot(self,label):
  files=['.watcher-down','.wake-queue','.status-presentation-cursor','.main-eligible-rows','.branch-eligible-rows']
  records.append({'scenario':self.name,'state':label,'files':{p:(self.state/p).read_text() for p in files if (self.state/p).is_file()}})
 def close(self):
  self.stop()
  self.run(['tmux','-L','fm-lab','kill-server'],ok=False)
  shutil.rmtree(self.home)

def scenario(name,fn):
 lab=Lab(name)
 try:
  fn(lab);records.append({'scenario':name,'result':'pass'});print(name+': PASS',flush=True)
 except Exception as e:
  lab.snapshot('failure');records.append({'scenario':name,'result':'fail','error':traceback.format_exc()});print(name+': FAIL '+str(e),flush=True)
 finally:
  lab.close();(EV/'live-recovery-transcript.json').write_text(json.dumps(records,indent=2)+'\n')

def settled(l):
 l.drain();(l.state/'.status-presentation-cursor').touch();g=l.publish();p,path=l.start('watcher')
 l.wait(lambda:l.marker()=='acked:downtime:'+g)
 time.sleep(2)
 assert p.poll() is None, path.read_text()
 assert 'check: rearm-resurface' not in path.read_text()
 assert not (l.state/'.wake-queue').read_text()
 l.snapshot('empty recovery retired while watcher remains live')

def unsafe(l):
 # Each case is a fresh generation with an empty queue; uncertainty must wake main.
 for case in [l.name.split('--')[1]]:
  l.stop()
  for p in ['.status-presentation-cursor','demo.status','branch-outcomes.jsonl','.branch-outcomes-cursor','.branch-outcomes-processed']:
   q=l.state/p
   if q.exists():q.unlink()
  (l.state/'.wake-queue').write_text('')
  if case!='no-cursor':(l.state/'.status-presentation-cursor').touch()
  if case=='unread-status':(l.state/'demo.status').write_text('failed: deployment stopped\n')
  if case=='open-decision':
   (l.state/'demo.status').write_text('blocked [key=capacity]: no capacity\nworking: newer prose\n');l.drain()
  if case=='unprocessed-outcome':
   l.run(['bin/fm-branch-outcome.sh','append','--task','demo','--verdict','captain','--summary','choose deployment window'])
   l.run(['bin/fm-branch-outcome.sh','mark-read','--through','1'])
  if case=='corrupt-outcome':(l.state/'branch-outcomes.jsonl').write_text('broken\n')
  g=l.publish();p,path=l.start(case);l.wait(lambda:p.poll() is not None)
  assert 'check: rearm-resurface' in path.read_text(),path.read_text()
  assert not l.marker().startswith('acked:'),l.marker()
  l.snapshot(case+' retained recovery and emitted main wake')

def interrupted(l):
 (l.state/'demo.status').write_text('note: deployment failed and stopped\n')
 # Let the real watcher observe this existing status before the empty recovery.
 p,path=l.start('seed-status');l.wait(lambda:p.poll() is not None)
 out=l.drain()
 ack=next(line.split('run bin/fm-wake-drain.sh ',1)[1] for line in out.splitlines() if line.startswith('WAKE_ACK_REQUIRED:'))
 l.run(['bin/fm-wake-drain.sh']+shlex.split(ack))
 assert not (l.state/'.wake-queue').read_text()
 (l.state/'.status-presentation-cursor').unlink()
 g=l.publish();p,path=l.start('initial-close');l.wait(lambda:p.poll() is not None)
 assert 'check: rearm-resurface' in path.read_text()
 out=l.drain();assert '--recovery-generation '+g in out
 assert l.marker()=='announced:handling:'+g
 assert l.run(['node','bin/fm-branch-dispatch.mjs','recovery-settled']).returncode==0
 p,path=l.start('handling-watcher')
 l.wait(lambda:(l.state/'.watch.lock/pid').exists() and 'watcher: started' in path.read_text() and p.poll() is None)
 time.sleep(1);l.snapshot('before watcher close');l.stop();l.snapshot('after watcher close')
 assert l.marker()=='pending:interrupted:'+g,l.marker()
 p,path=l.start('recovered-close');l.wait(lambda:p.poll() is not None)
 assert 'check: rearm-resurface' in path.read_text()
 assert l.marker()=='announced:interrupted:'+g,l.marker()
 l.snapshot('presentation alone cannot settle interrupted handling')
 out=l.drain();assert '--recovery-generation '+g in out
 l.run(['bin/fm-wake-drain.sh','--ack-through','0','--recovery-generation',g])
 assert l.marker()=='acked:handling:'+g,l.marker()
 l.snapshot('only generation-bound post-handling acknowledgement retires recovery')

def remote(l):
 (l.home/'.fm-secondmate-home').write_text('mate\n')
 (l.home/'.fm-secondmate-parent').write_text('schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=remote.example\n')
 (l.state/'parent-replies.status').write_text('needs-decision [key=parent]: parent chooses\n')
 (l.state/'demo.status').write_text('note: deployment probe complete\n')
 l.drain();g=l.publish();p,path=l.start('parent-excluded')
 l.wait(lambda:l.marker()=='acked:downtime:'+g)
 assert p.poll() is None
 l.snapshot('remote parent channel excluded while local status is presented')
 l.stop()
 (l.state/'demo.status').open('a').write('failed: new local failure\n')
 g=l.publish();p,path=l.start('local-failure');l.wait(lambda:p.poll() is not None)
 assert 'check: rearm-resurface' in path.read_text()
 assert not l.marker().startswith('acked:')
 l.snapshot('new local failure remains recoverable')

def scope(l):
 (l.state/'demo.meta').write_text('project=demo\nwindow=fm-demo\n')
 l.shell('. bin/fm-wake-lib.sh; fm_wake_append signal demo.status "signal: $STATE/demo.status"; fm_wake_append check merge "check: merge landed: manual check"')
 out=l.run(['node','bin/fm-branch-dispatch.mjs','offer'],input='check: rearm-resurface\n').stdout
 assert 'eligible=1\n' in out and 'rows=1\n' in out and 'tasks=demo\n' in out and 'unscoped=0' in out
 assert 'eligible=0\n' in l.run(['node','bin/fm-branch-dispatch.mjs','offer'],input='check: unrelated\n').stdout
 # Execute the same Pi caller interface without the host flag, for both postures.
 js='import {branchOfferForWake} from "./.pi/extensions/lib/fm-branch-dispatch.ts"; for(const afk of [false,true]) console.log(JSON.stringify({afk,...branchOfferForWake(process.env.FM_HOME+"/state","check: rearm-resurface",afk)}));'
 result=l.run(['node','--input-type=module','-e',js]).stdout
 a,b=[json.loads(x) for x in result.splitlines()]
 assert not a['eligible'] and b['eligible'] and b['awayOnly']
 l.run(['bin/fm-wake-grant.sh','activate',str(os.getpid()),'live-scope'])
 l.run(['bin/fm-wake-grant.sh','publish','live-scope','1'])
 out=l.drain(extra={'FM_SUPERVISION_ACTOR':'branch'})
 assert 'merge landed' not in out
 l.run(['bin/fm-wake-drain.sh','--ack-through','2','--recovery-generation',l.marker().split(':')[-1]],extra={'FM_SUPERVISION_ACTOR':'branch'})
 rows=(l.state/'.wake-queue').read_text()
 assert '\t2\tcheck\tmerge\t' in rows and '\t1\tsignal\t' not in rows
 l.snapshot('branch ack preserves original main-owned row 2')
 l.run(['bin/fm-wake-grant.sh','deactivate',str(os.getpid()),'live-scope'])
 # Active decision and malformed queue must defeat recovery eligibility.
 (l.state/'demo.status').write_text('needs-decision [key=choice]: choose deployment\n')
 l.shell('. bin/fm-wake-lib.sh; fm_wake_append signal demo.status "signal: $STATE/demo.status"')
 assert 'eligible=0\n' in l.run(['node','bin/fm-branch-dispatch.mjs','offer'],input='check: rearm-resurface\n').stdout
 (l.state/'.wake-queue').open('a').write('corrupt\n')
 assert 'eligible=0\n' in l.run(['node','bin/fm-branch-dispatch.mjs','offer','--afk'],input='check: rearm-resurface\n').stdout

scenario('settled-empty-no-wake',settled)
for case in ['no-cursor','unread-status','open-decision','unprocessed-outcome','corrupt-outcome']:
 scenario('uncertain-recovery--'+case,unsafe)
scenario('interrupted-handling-needs-ack',interrupted)
scenario('remote-parent-channel-exclusion',remote)
scenario('host-only-scope-and-actor-grants',scope)
assert all(x.get('result')!='fail' for x in records)
