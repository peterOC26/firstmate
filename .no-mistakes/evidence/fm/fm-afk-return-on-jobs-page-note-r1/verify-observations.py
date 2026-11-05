from pathlib import Path
import json, html, re
p=Path('/home/zabi/.no-mistakes/evidence/01M6NJ7527B7KV61XVM1960T4N')
receipt=json.loads((p/'jobs-return-receipts.json').read_text())
assert len(receipt['replies'])==1 and 'Away mode has ended' in receipt['replies'][0]['body']
assert 'no record at ' in (p/'jobs-return-mode.txt').read_text()
boundary=(p/'boundary-host-output.txt').read_text(); assert 'cycle boundary' in boundary and 'away mode should end' in boundary
quiet=(p/'quiet-host-output.txt').read_text();assert 'captain inbox note' in quiet and 'away mode should end' not in quiet
assert 'POSTURE AFTER HANDOFF: quiet' in (p/'quiet-transcript.txt').read_text()
outcomes=[json.loads(l) for l in (p/'authority-branch-outcomes.jsonl').read_text().splitlines()]
assert len(outcomes)==1 and outcomes[0]['summary'].startswith('per your away instructions:')
a=(p/'authority-transcript.txt').read_text()
expected={'eval-dated':'Dated grant applied','eval-qid':'Q-id grant applied','eval-undated':'Pending undated wording decision','eval-neighbor':'Pending neighboring wording decision','eval-security':'Pending credential deletion decision'}
for task,title in expected.items():
 block=re.search(r'task:\n  id: '+re.escape(task)+r'\n(.*?)(?=\ntask:|\nCREDENTIAL FIXTURE:)',a,re.S)
 assert block and '  title: '+title+'\n' in block.group(1), task
 (p/('authority-'+task+'-observed.txt')).write_text('task:\n  id: '+task+'\n'+block.group(1))
assert 'AWAY POSTURE AFTER ROUTINE EVENT: away' in a
assert 'PRIMARY STILL PARKED BEFORE NOTE: yes' in a
assert 'disposable fixture value; preserve under security boundary' in a
checks={'jobs_reply_and_away_archive':True,'unsurfaced_note_at_boundary':True,'quiet_preserved':True,'dated_and_qid_grants_applied':True,'undated_and_neighbor_grants_not_applied':True,'security_sensitive_deletion_refused':True,'automatic_event_keeps_main_parked_and_away':True}
(p/'live-observations.json').write_text(json.dumps(checks,indent=2)+'\n')
sections=[('Jobs message and real primary reply','jobs-return-transcript.txt'),('Between-polls note at park boundary','boundary-transcript.txt'),('Quiet mode stays active','quiet-transcript.txt'),('Live job authority evaluation','authority-transcript.txt'),('Native interactive path stopped by workspace trust','claude-primary-start.txt')]
body='''<!doctype html><html lang="en"><meta charset="utf-8"><title>Firstmate live validation</title><style>body{font:16px system-ui;max-width:1100px;margin:35px auto;padding:0 20px;background:#10151c;color:#e5edf7}h1{font-size:28px}p{line-height:1.6}details{margin:18px 0;border:1px solid #3d4f67;border-radius:8px}summary{padding:15px;cursor:pointer;font-weight:600}pre{padding:18px;white-space:pre-wrap;overflow-wrap:anywhere;background:#080d13;font:13px/1.55 ui-monospace,monospace}code{color:#8ed5be}</style><h1>Firstmate live validation</h1><p>Real Claude primary and supervision engine, current branch, disposable marked homes, private tmux sockets with a 120 × 40 grid. No harness or engine stubs were used for these observations. Raw product output is expanded below.</p><p>The primary returned from a Jobs message and saved a reply. The away engine applied dated and Q-id permissions only to their own jobs, rejected undated and borrowed authority, and preserved a credential fixture. Quiet mode remained quiet. Automatic fleet work left the primary parked and away.</p><p>Native notification delivery was not exercised: the interactive Claude session stopped at its workspace-trust dialog. The successful model runs used Claude's <code>--safe-mode</code> print interface and the host's foreground output, not native Stop-hook delivery. This HTML renders captured CLI output; it is not a native UI screenshot.</p>'''
for title,f in sections:
 body+='<details open><summary>'+html.escape(title)+'</summary><pre>'+html.escape((p/f).read_text())+'</pre></details>'
(p/'live-validation.html').write_text(body+'</html>')
print('Seven live observations verified against captured product output and durable records; HTML evidence written.')
