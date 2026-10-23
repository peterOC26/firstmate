import json, os, pathlib, subprocess, shutil
root = pathlib.Path.cwd()
evidence = pathlib.Path('/home/zabi/.no-mistakes/evidence/01M5MT6K4CYJM29EYMY18ZSE8S')
scratch = root / '.nm-test-pr'
url = 'https://github.com/peterOC26/firstmate/pull/33'
log = []
env = {k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k in ('TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND','HERDR_SESSION','HERDR_ENV'))}
env.update(TMUX=str(scratch/'s')+',0,0', FM_BACKEND='tmux')
def run(args, e=env, timeout=50):
    p=subprocess.run([str(x) for x in args],cwd=root,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
    return p
# A private socket prevents any inventory command from reaching the default server.
p=run(['tmux','-S',scratch/'s','new-session','-d','-s','pr-lab','-x','120','-y','40'])
assert p.returncode == 0, p.stdout
try:
    shutil.copytree(root/'bin', scratch/'base-bin', dirs_exist_ok=True)
    base=subprocess.run(['git','show','68e134632c78708bd3e25074ed853388ee231d99:bin/fm-pr-lib.sh'],cwd=root,check=True,stdout=subprocess.PIPE).stdout
    (scratch/'base-bin/fm-pr-lib.sh').write_bytes(base)
    for name, marker, trailing, baseline in [
        ('baseline-after', 'after', None, True),
        ('target-after', 'after', None, False),
        ('target-before', 'before', None, False),
        ('unknown-key', 'after', 'unrelated=value', False),
        ('forged-key', 'after', 'control_relaunch_tx_forged=value', False),
        ('duplicate-pr', 'after', 'pr='+url, False),
        ('invalid-head', 'after', 'pr_head=not-a-commit', False),
    ]:
        home=scratch/name
        p=run([root/'bin/fm-lab-home.sh','create',home]); assert p.returncode==0,p.stdout
        e=env|{'FM_HOME':str(home),'FM_CHECK_INTERVAL':'0','FM_POLL':'0.1','FM_HEARTBEAT':'999999','FM_SIGNAL_GRACE':'0'}
        meta=home/'state/a-pr.meta'
        # Task metadata is a persisted public protocol, seeded without starting a worker.
        meta.write_text(f'window=pr-lab:worker\nworktree={root}\nproject={root}\nkind=ship\nmode=no-mistakes\n')
        p=run([root/'bin/fm-pr-check.sh','a-pr',url],e); assert p.returncode==0,(name,p.stdout)
        lines=meta.read_text().splitlines()
        assert any(x.startswith('pr_head=') for x in lines), 'real forge head missing'
        tx='control_relaunch_tx=12345.20261023T120000Z.6789'
        if marker=='before': lines.insert(next(i for i,x in enumerate(lines) if x.startswith('pr=')),tx)
        else: lines.append(tx)
        if trailing: lines.append(trailing)
        meta.write_text('\n'.join(lines)+'\n')
        log.extend([f'=== {name} ===',f'$ FM_HOME=<lab> bin/fm-pr-check.sh a-pr {url}',f'exit={p.returncode}', 'persisted PR identity and relaunch transaction:', '\n'.join(x for x in lines if x.startswith(('pr=','pr_head=','control_relaunch','unrelated=')))])
        watcher=(scratch/'base-bin' if baseline else root/'bin')/'fm-watch.sh'
        if baseline: e['FM_ROOT_OVERRIDE']=str(root)
        p=run([watcher],e)
        log.extend([f'$ FM_HOME=<lab> {"base" if baseline else "target"}/bin/fm-watch.sh',p.stdout.strip(),f'exit={p.returncode}'])
        assert p.returncode==0,(name,p.stdout)
        rejected='rejected unauthenticated state checks' in p.stdout
        expected_rejected=baseline or trailing is not None
        assert rejected==expected_rejected,(name,p.stdout)
        if not expected_rejected:
            assert ': merged' in p.stdout,(name,p.stdout)
            assert not (home/'state/a-pr.check.sh').exists()
            notified=home/'state/a-pr.pr-poll-merge-notified'
            assert notified.exists()
            queue=(home/'state/.wake-queue').read_text()
            assert 'check: merge landed: a-pr '+url+' external' in queue, queue
            log.extend(['persisted canonical merge notification:',notified.read_text().strip(),'poll artifacts retired: yes'])
        else:
            assert (home/'state/a-pr.check.sh').exists()
            assert not (home/'state/a-pr.pr-poll-merge-notified').exists()
            log.append('poll retained; no merge notification published')
        log.append('durable wake queue:\n'+(home/'state/.wake-queue').read_text())
        (evidence/'pr-poll-live-transcript.txt').write_text('\n'.join(log)+'\n')
finally:
    p=run(['tmux','-S',scratch/'s','kill-server'])
    log.append('private tmux server stopped; no default socket used')
    (evidence/'pr-poll-live-transcript.txt').write_text('\n'.join(log)+'\n')
print('\n'.join(log))
