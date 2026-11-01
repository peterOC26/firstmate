import pathlib,os,subprocess,time,shutil
R=pathlib.Path.cwd(); E=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M6BPZF5TNYKZ47B19PMT18QZ')
L=E/'negative-lab'; B=R/'.inbox-base-watch-test'
subprocess.run(['bin/fm-lab-home.sh','create',str(L)],check=True,capture_output=True)
B.mkdir()
p=None
try:
    for src in (R/'bin').iterdir():
        if src.name!='fm-watch.sh': (B/src.name).symlink_to(src)
    script=B/'fm-watch.sh'
    script.write_bytes(subprocess.check_output(['git','show','38786955e2b2e20fd8aa978291d3fee71651fceb:bin/fm-watch.sh']))
    script.chmod(0o700)
    env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TMUX','HERDR_','TASKS_AXI_'))}
    env.update(FM_HOME=str(L),FM_POLL='0.2',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_WATCH_HANDLING_SUCCESSOR='1')
    with (E/'negative-control.txt').open('w') as log, (E/'negative-watcher-output.txt').open('w') as out:
        p=subprocess.Popen([str(script)],env=env,stdout=out,stderr=subprocess.STDOUT)
        deadline=time.monotonic()+20
        while not (L/'state/.watch.lock/pid').exists():
            assert p.poll() is None
            assert time.monotonic()<deadline
            time.sleep(.1)
        n=subprocess.run(['bin/fm-inbox.sh','note','--json','q1599 t'],env=env,text=True,capture_output=True,check=True)
        log.write('Control: original fm-watch.sh at base commit, all other tools at target.\n$ bin/fm-inbox.sh note --json "q1599 t"\n'+n.stdout)
        time.sleep(5)
        assert p.poll() is None, 'negative control unexpectedly surfaced answer'
        assert (E/'negative-watcher-output.txt').read_text()==''
        log.write('After five seconds and multiple polls, the original handling successor is still running and has emitted no close.\nPersisted queue:\n'+(L/'state/.wake-queue').read_text())
        log.write('The same live CLI scenario on target emitted the answer close after approximately one second; see inbox-live-transcript.txt.\n')
        print(log.name)
finally:
    if p is not None and p.poll() is None: p.terminate(); p.wait(timeout=10)
    shutil.rmtree(B)
    shutil.rmtree(L)
