import json,re
from pathlib import Path
E=Path('/home/zabi/.no-mistakes/evidence/01M70A5P9C0RX9NZ5XGE0572MX')
load=lambda n:json.loads((E/n).read_text())
d=load('r2-large-deferred-state.json');f=load('r2-large-final-state.json');r=load('r2-large-final-receipts.json')
assert len(d['.subsuper-escalations'].encode())>8192
assert d['.wake-queue'] and 'UNSUBMITTED LAB DRAFT' in (E/'r2-large-deferred-terminal.txt').read_text()
assert d['.supervise-daemon.log'].count('wake: check: rearm-resurface')==1
assert d['.supervise-daemon.log'].count('captain inbox hand-back deferred:')>=3
assert not f['.afk-contract'] and not f['.afk'] and not f['.wake-queue']
assert r['handled'][0]['reply']['body']=='LAB-LARGE-RETURN'
fulls=list(f['digest_records'].values());assert len(fulls)==1 and fulls[0]==d['.subsuper-escalations']
assert all('lab backlog event '+str(i)+':' in fulls[0] for i in range(1,6))
p=load('r2-pi-success-state.json');pr=load('r2-pi-success-receipts.json')
assert p['.afk-contract'] is None and p['.wake-queue']=='' and pr['replies'][0]['body']=='PI-LIVE-RETURN'
q=load('r2-pi-quiet-final-state.json');qr=load('r2-pi-quiet-final-receipts.json')
assert 'mode: quiet' in q['.afk-contract'] and qr['replies'][-1]['body']=='PI-QUIET-NOTE'
report={
 'daemon_large_backlog':{'buffer_bytes_while_deferred':len(d['.subsuper-escalations'].encode()),'deferred_attempts':d['.supervise-daemon.log'].count('captain inbox hand-back deferred:'),'watcher_closes_while_deferred':d['.supervise-daemon.log'].count('wake: check: rearm-resurface'),'draft_preserved':True,'note_retained_until_main':True,'entire_backlog_preserved_in_one_full_text_record':True,'away_record_archived':True,'queue_acknowledged_by_main':True,'published_reply':r['handled'][0]['reply']},
 'pi_away':{'away_record_archived':True,'queue_acknowledged':True,'published_reply':pr['replies'][0]},
 'pi_quiet':{'record_mode_retained':'quiet','published_reply':qr['replies'][-1]},
 'setup_corrections':['Initial Codex shell environment omitted FM_HOME; relaunched with shell_environment_policy.inherit=all.','Workspace sandbox denied private tmux socket with Operation not permitted; relaunched disposable lab CLI with --sandbox danger-full-access --ask-for-approval never. Global configuration was unchanged.'],
 'focused_fixture_checks':{'daemon':['captain hand-back with large backlog and composer deferral','retry digest/alarm globals','unchanged frozen generation','watcher parks until main drains'],'pi':['away routing matrix including quiet-note','note arrives after accept before branch prompt']}}
(E/'r2-live-observations.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
