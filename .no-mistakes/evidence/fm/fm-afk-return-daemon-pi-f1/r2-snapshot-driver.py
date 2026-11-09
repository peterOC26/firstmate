import sys,json,subprocess,os
from pathlib import Path
kind,label=sys.argv[1:]
h=Path('.live-test',kind+'-home').read_text().strip(); home=Path(h); st=home/'state'
keep=['.afk','.afk-contract','.wake-queue','.wake-queue.ack','.wake-queue.surfaced','.supervise-daemon.log','.subsuper-escalations','.subsuper-escalations.since']
obj={p:(st/p).read_text(errors='replace') if (st/p).is_file() else None for p in keep}
obj['archived_contracts']=[p.name for p in (st/'afk-contracts').glob('*')]
obj['digest_records']={p.name:p.read_text(errors='replace') for p in (st/'.subsuper-digests').glob('*') if p.is_file()}
e=Path('/home/zabi/.no-mistakes/evidence/01M70A5P9C0RX9NZ5XGE0572MX')
(e/(label+'-state.json')).write_text(json.dumps(obj,indent=2))
env=dict(os.environ,TMUX_TMPDIR=h+'/tmux')
r=subprocess.run(['tmux','-L','fm-lab','capture-pane','-p','-S','-160','-t','primary'],env=env,text=True,capture_output=True)
(e/(label+'-terminal.txt')).write_text(r.stdout)
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']:env.pop(k,None)
env['FM_HOME']=h
r=subprocess.run(['bin/fm-inbox.sh','receipts'],env=env,text=True,capture_output=True)
(e/(label+'-receipts.json')).write_text(r.stdout)
print(label, 'away=',obj['.afk-contract'] is not None, 'queue=',obj['.wake-queue']);print(r.stdout)
