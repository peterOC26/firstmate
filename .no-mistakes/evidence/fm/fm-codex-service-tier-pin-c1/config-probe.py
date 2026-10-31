import json, os, pathlib, signal, subprocess, tempfile, shlex
E = pathlib.Path('/home/zabi/.no-mistakes/evidence/01M69FH37Q1230T52YRHMGY8AD')
signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(TimeoutError('config/read timed out')))
rows = json.loads((E/'live-tmux-processes.json').read_text())
results=[]
with tempfile.TemporaryDirectory(prefix='.tier-config.',dir=pathlib.Path.cwd()) as scratch:
    config_home=pathlib.Path(scratch)
    (config_home/'config.toml').write_text('service_tier = "fast"\n[features]\nhooks = true\n')
    cases=[('Fast preference without launch pin', [])]
    for row in rows:
        native=next(p for p in row['processes'] if pathlib.Path(p['argv'][0]).name=='codex')
        cases.append((row['task'],native['argv'][1:-1]))
    worker_flags=cases[1][1]
    counterfactual=[]
    i=0
    while i<len(worker_flags):
        if worker_flags[i:i+2]==['-c','service_tier="default"']:
            i+=2
        else:
            counterfactual.append(worker_flags[i]);i+=1
    cases.append(('same worker launch without the pin (counterfactual)', counterfactual))
    secondmate=(E/'secondmate-launch-command.txt').read_text()
    secondmate_flags=shlex.split(secondmate.split('codex ',1)[1].split('"$(',1)[0])
    cases.append(('secondmate generated launch flags (mock transport; real Codex configuration)', secondmate_flags))
    for name, flags in cases:
        env={**os.environ,'CODEX_HOME':scratch}
        process=subprocess.Popen(['codex','--no-daemon',*flags,'app-server'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,env=env)
        try:
            signal.alarm(20)
            for request in [
                {'id':1,'method':'initialize','params':{'clientInfo':{'name':'tier-live-evidence','version':'1'}}},
                {'id':2,'method':'config/read','params':{'includeLayers':False}},
            ]:
                process.stdin.write(json.dumps(request)+'\n');process.stdin.flush()
                while True:
                    line=process.stdout.readline()
                    if not line: raise RuntimeError('Codex exited before config/read')
                    response=json.loads(line)
                    if response.get('id')==request['id']: break
                if 'error' in response: raise RuntimeError(response['error'])
            config=response['result']['config']
            actual=config['service_tier']
            expected='default' if 'service_tier="default"' in flags else 'fast'
            assert actual==expected,(name,actual,expected)
            listing=subprocess.check_output(['codex','--no-daemon',*flags,'features','list'],env=env,text=True,stderr=subprocess.DEVNULL)
            hooks=next(line.split()[-1] for line in listing.splitlines() if line.split()[0]=='hooks')
            assert hooks==('false' if '--disable' in flags else 'true'),(name,hooks)
            results.append({'scenario':name,'hooks_enabled':hooks=='true','request':request,'response':{'id':2,'result':{'config':{'service_tier':actual}}},'launch_flags':flags})
        finally:
            signal.alarm(0);process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill();process.wait()
(E/'effective-service-tier.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
