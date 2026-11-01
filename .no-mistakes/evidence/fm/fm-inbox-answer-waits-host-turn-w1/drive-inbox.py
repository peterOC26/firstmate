import os, pathlib, subprocess, time, json, re, shutil
ROOT = pathlib.Path.cwd()
E = pathlib.Path('/home/zabi/.no-mistakes/evidence/01M6BPZF5TNYKZ47B19PMT18QZ')
L = E / 'inbox-lab'
subprocess.run(['bin/fm-lab-home.sh','create',str(L)],check=True,capture_output=True)
env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'HERDR_', 'TMUX', 'TASKS_AXI_'))}
env.update(FM_HOME=str(L), FM_POLL='0.2', FM_SIGNAL_GRACE='0', FM_CHECK_INTERVAL='999999', FM_HEARTBEAT='999999', FM_WATCH_HANDLING_SUCCESSOR='1')
log = (E/'inbox-live-transcript.txt').open('w')
processes=[]
def emit(s):
    log.write(time.strftime('%H:%M:%S')+' '+s+'\n'); log.flush(); print(s,flush=True)
def cli(*args):
    p=subprocess.run([str(ROOT/'bin'/args[0]),*args[1:]],env=env,text=True,capture_output=True,timeout=30)
    emit('$ '+' '.join(args)+'\n'+p.stdout+p.stderr)
    assert p.returncode==0, (args,p.returncode)
    return p.stdout+p.stderr

def start(name):
    out=(E/(name+'.txt')).open('w')
    p=subprocess.Popen([str(ROOT/'bin/fm-watch.sh')],env=env,stdout=out,stderr=subprocess.STDOUT)
    processes.append((p,out))
    emit('$ FM_HOME=<disposable lab> FM_WATCH_HANDLING_SUCCESSOR=1 bin/fm-watch.sh ['+name+']')
    end=time.monotonic()+20
    while time.monotonic()<end:
        lock=L/'state/.watch.lock/pid'
        if lock.exists() and lock.read_text().strip()==str(p.pid): return p
        assert p.poll() is None, (name,'watcher exited before lock')
        time.sleep(.1)
    raise AssertionError('no watcher lock')
def close(p,name):
    p.wait(timeout=20)
    output=(E/(name+'.txt')).read_text()
    emit(name+' exit='+str(p.returncode)+'\n'+output)
    assert p.returncode==0
    return output

def note(body,request):
    output=cli('fm-inbox.sh','note','--json','--request-id',request,body)
    return json.loads(output)['id']
def ack():
    output=cli('fm-wake-drain.sh')
    m=re.search(r'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh (.*)',output)
    assert m, 'no ack command'
    cli('fm-wake-drain.sh',*m.group(1).split())
    return output

def quiet(p,seconds=3):
    time.sleep(seconds)
    assert p.poll() is None, 'duplicate delivery closed watcher'
    emit('Watcher stayed running across multiple polls; no repeated close.')

try:
    p=start('inbox-first-close')
    t=time.monotonic(); first=note('q1599 t','live-first')
    out=close(p,'inbox-first-close')
    assert 'check: captain inbox note '+first in out
    emit('Observed answer close in %.2f seconds after submission.'%(time.monotonic()-t))
    drained=cli('fm-wake-drain.sh')
    assert 'inbox:'+first in drained
    pending=json.loads(cli('fm-inbox.sh','receipts','--all-pending'))
    assert first in json.dumps(pending)
    p=start('inbox-no-repeat')
    quiet(p)
    replay=note('q1599 t','live-first')
    assert replay==first
    quiet(p)
    second=note('q1600 y','live-second')
    out=close(p,'inbox-no-repeat')
    assert second in out and first not in out
    emit('A new answer closed the successor; replay of the first answer did not.')
    drained=ack()
    assert 'inbox:'+first in drained and 'inbox:'+second in drained
    cli('fm-inbox.sh','drain')
    cli('fm-inbox.sh','drain','--ack',first,second)
    p=start('inbox-after-ack')
    quiet(p)
    assert not list((L/'state').glob('.seen-inbox-*')), 'obsolete inbox marker remains'
    receipts=cli('fm-inbox.sh','receipts','--all-pending','--all-handled')
    assert first in receipts and second in receipts
    emit('Both acknowledged answers remain in receipts; delivery markers were pruned.')
    p.terminate(); p.wait(timeout=10)
    # An inbox-prefixed task signal must keep its separate marker.
    (L/'state/inbox-triage-w1.status').write_text('done [at=%d]: disposable fixture finished\n'%time.time())
    p=start('inbox-task-signal')
    out=close(p,'inbox-task-signal')
    assert 'signal: '+str(L/'state/inbox-triage-w1.status') in out
    ack()
    p=start('inbox-task-no-repeat')
    quiet(p)
    assert (L/'state/.seen-inbox-triage-w1_status').exists()
    emit('Inbox-prefixed task signal was delivered once; inbox pruning preserved its status marker.')
    emit('ALL LIVE CLI SCENARIOS PASSED')
finally:
    for p,out in processes:
        if p.poll() is None:
            p.terminate()
            try: p.wait(timeout=10)
            except subprocess.TimeoutExpired: p.kill(); p.wait()
        out.close()
    assert (L/'.fm-lab-home').read_text().strip()=='fm-lab-home v1'
    shutil.rmtree(L)
    emit('Stopped owned watcher processes and removed disposable home.')
    log.close()
