import json,pathlib,statistics,html
E=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M7A6XKEDE3MQDMAHTFHQPD5J');E=E/'round2';M=E/'measured';result=[]
for n in range(1,5):
 rows=[json.loads(x) for x in (M/f'check-{n}-transcript.jsonl').read_text().splitlines()]
 messages={};deltas=[];hook=False;instructions=[]
 for row in rows:
  if row.get('type')=='assistant':
   msg=row.get('message',{})
   if 'usage' in msg:messages[msg['id']]=msg
  a=row.get('attachment',{})
  if a.get('type')=='deferred_tools_delta':deltas.append(a)
  if a.get('type')=='hook_success' and a.get('hookEvent')=='SessionStart':hook=True
  if a.get('type')=='instructions':instructions.extend(a['files'])
 totals={k:0 for k in ['input_tokens','output_tokens','cache_creation_input_tokens','cache_read_input_tokens','ephemeral_5m_input_tokens','ephemeral_1h_input_tokens']}
 for msg in messages.values():
  u=msg['usage']
  for key in totals:totals[key]+=u.get(key,u.get('cache_creation',{}).get(key,0))
 first=next(iter(messages.values()))['usage'];costs=json.loads((M/f'check-{n}-cost.json').read_text());sid=next(r['sessionId'] for r in rows if 'sessionId' in r);cost=next(c for c in costs if c['lastSessionId']==sid);main=cost['lastModelUsage']['claude-opus-5-5']
 # Aggregate split assistant content blocks by message id before counting calls.
 out={'check':n,'lean':n<=3,'allowlist':n==2,'main_model':list({m.get('model') for m in messages.values()}),'main_model_calls':len(messages),'first_call_total_input':sum(first.get(k,0) for k in ['input_tokens','cache_creation_input_tokens','cache_read_input_tokens']),'first_call_cache_create':first['cache_creation_input_tokens'],'first_call_cache_read':first['cache_read_input_tokens'],'transcript_totals':totals,'cli_total_session_dollars':cost['lastCost'],'cli_main_model_dollars':main['costUSD'],'main_model_dollars_per_call':main['costUSD']/len(messages),'cli_main_model_cache_create':main['cacheCreationInputTokens'],'transcript_matches_cli_cache_create':totals['cache_creation_input_tokens']==main['cacheCreationInputTokens'],'loaded_mcp_tool_names':sorted({t for d in deltas for t in d.get('addedNames',[]) if t.startswith('mcp__')}),'native_artifact_tool_names':sorted({t for d in deltas for t in d.get('addedNames',[]) if t.startswith('Artifact')}),'auto_memory_loaded':any(f['type']=='AutoMem' for f in instructions),'project_instructions_loaded':any(f['type']=='Project' for f in instructions),'startup_hook_executed':hook,'normal_stop_hook':(M/f'check-{n}-busy-state.txt').read_text().strip(),'process':json.loads((M/f'check-{n}-process.json').read_text())}
 result.append(out)
summary={'environment':'Real Claude Code 2.1.323 using the existing OAuth login, isolated config, actual Treehouse worktrees and private 160x50 tmux server. Same fixture and review request throughout; unique report paths/task IDs differ. No model or effort overrides between lean and ordinary launches.','measurement_notes':'Calls deduplicated by API message ID. Session dollars are the Claude CLI runtime ledger, including automatic permission classifier usage. Dollars/call use only the unchanged main model. These tiny fixture checks measure behavior, not a representative production cost comparison.','checks':result,'lean_mean_cache_create_tokens':statistics.mean(r['cli_main_model_cache_create'] for r in result[:3]),'lean_main_model_dollars_per_call':sum(r['cli_main_model_dollars'] for r in result[:3])/sum(r['main_model_calls'] for r in result[:3])}
(E/'measurements.json').write_text(json.dumps(summary,indent=2))
print(json.dumps(summary,indent=2))
body=['<!doctype html><meta charset="utf-8"><title>Claude lean live validation</title><style>body{font:16px system-ui;margin:36px;background:#fff;color:#18212b}pre{white-space:pre-wrap;background:#101821;color:#eff4fa;padding:18px;font:13px monospace}td,th{padding:10px;border:1px solid #bbb}table{border-collapse:collapse}code{background:#eee;padding:3px}</style><h1>Claude lean live validation</h1><p>All three lean reviews completed with five-minute cache writes and no runtime MCP tools. Ordinary launch restores MCP and auto-memory loading. Same Claude model and effort throughout.</p><p>'+html.escape(summary['environment'])+'</p><table><tr><th>Check</th><th>Mode</th><th>First input</th><th>5m writes</th><th>1h writes</th><th>Calls</th><th>Main $/call</th><th>MCP tools</th></tr>']
for r in result:
 body.append('<tr>'+''.join('<td>'+html.escape(str(x))+'</td>' for x in [r['check'],'lean' if r['lean'] else 'ordinary',r['first_call_total_input'],r['transcript_totals']['ephemeral_5m_input_tokens'],r['transcript_totals']['ephemeral_1h_input_tokens'],r['main_model_calls'],round(r['main_model_dollars_per_call'],6),', '.join(r['loaded_mcp_tool_names']) or 'none'])+'</tr>')
body.append('</table><p>'+html.escape(summary['measurement_notes'])+'</p>')
for n in range(1,5):
 body.append(f'<details><summary>Measured check {n}: actual terminal capture and report</summary><pre>'+html.escape((M/f'check-{n}-terminal.txt').read_text())+'</pre><pre>'+html.escape((M/f'check-{n}-report.md').read_text())+'</pre></details>')
(E/'live-validation.html').write_text(''.join(body))
