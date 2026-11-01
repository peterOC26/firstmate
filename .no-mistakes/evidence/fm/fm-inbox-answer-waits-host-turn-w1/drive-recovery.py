import pathlib,os,subprocess,time,shutil,re
R=pathlib.Path.cwd(); E=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M6BPZF5TNYKZ47B19PMT18QZ'); L=E/'recovery-lab'
subprocess.run(['bin/fm-lab-home.sh','create',str(L)],capture_output=True,check=True)
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TMUX','HERDR_','TASKS_AXI_'))}
env.update(FM_HOME=str(L),FM_PROCEVENT_CLAIM_ROOT=str(L/'claims'),FM_POLL='0.2',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_WATCH_HANDLING_SUCCESSOR='1')
log=(E/'recovery-live-transcript.txt').open('w'); procs=[]
def emit(s): print(s,flush=True); log.write(s+'\n'); log.flush()
def cli(*args):
 p=subprocess.run([str(R/'bin'/args[0]),*args[1:]],env=env,text=True,capture_output=True,timeout=20)
 emit('$ '+' '.join(args)+'\n'+p.stdout+p.stderr); assert p.returncode==0,(args,p.returncode)
 return p.stdout+p.stderr

def watcher(name,broken=False):
 out=(E/(name+'.txt')).open('w')
 p=subprocess.Popen([str(R/'bin/fm-watch.sh')],env=env,stdout=subprocess.PIPE if broken else out,stderr=out)
 if broken: p.stdout.close()
 procs.append((p,out)); return p

def result(p,name):
 p.wait(timeout=20); output=(E/(name+'.txt')).read_text(); emit(name+' exit='+str(p.returncode)+'\n'+output); return output

def ack():
 s=cli('fm-wake-drain.sh'); m=re.search(r'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh (.*)',s); assert m
 cli('fm-wake-drain.sh',*m.group(1).split()); return s

try:
 # Actual output failure (no command substitution or tool stub).
 note=cli('fm-inbox.sh','note','--json','q1603 a')
 import json
 noteid=json.loads(note)['id']
 p=watcher('closed-consumer',True); out=result(p,'closed-consumer')
 assert p.returncode!=0
 assert not list((L/'state').glob('.seen-inbox-*'))
 assert noteid in (L/'state/.wake-queue').read_text()
 emit('Closed stdout consumer did not commit a delivery marker or consume the answer.')
 p=watcher('replayed-answer'); out=result(p,'replayed-answer')
 assert p.returncode==0 and noteid in out
 ack(); cli('fm-inbox.sh','drain','--ack',noteid)
 emit('The next real watcher replayed the same answer successfully.')
 # Real deterministic process event via the supported built-in adapter.
 cli('fm-procevent-when.sh','arm','delivery-proof','--interval','0.2','--stable','1','--deadline','10','--condition','/usr/bin/true','--action','/usr/bin/printf','%s','local completion reached firstmate')
 p=watcher('process-event-close'); out=result(p,'process-event-close')
 assert p.returncode==0 and 'process-event result captured:' in out and 'procevent:when-delivery-proof:1' in out
 drained=ack()
 assert 'procevent when when-delivery-proof 1' in drained
 results=list((L/'state/procevent-inbox').glob('*.result'))
 assert len(results)==1, results
 resultfile=results[0]
 text=resultfile.read_text(); emit('Captured public result:\n'+text)
 assert 'local completion reached firstmate' in text
 assert cli('fm-procevent.sh','classify',str(resultfile)).strip().endswith('fired')
 cli('fm-procevent.sh','handled','when-delivery-proof','1')
 cli('fm-procevent-when.sh','retire','delivery-proof')
 p=watcher('after-completion-ack'); time.sleep(3); assert p.poll() is None
 emit('Handled completion did not reappear across successor polls.\nALL LIVE RECOVERY SCENARIOS PASSED')
finally:
 for p,out in procs:
  if p.poll() is None: p.terminate(); p.wait(timeout=10)
  out.close()
 cli('fm-procevent.sh','sweep-home')
 shutil.rmtree(L)
 emit('Stopped owned processes and removed disposable home.'); log.close()
