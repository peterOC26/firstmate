from pathlib import Path
import json
E=Path('/home/zabi/.no-mistakes/evidence/01M7A6XKEDE3MQDMAHTFHQPD5J/round2')
m=json.loads((E/'measurements.json').read_text())
assert len(m['checks'])==4
for n,c in enumerate(m['checks'],1):
 assert c['main_model']==['claude-opus-5-5']
 assert c['transcript_matches_cli_cache_create']
 assert c['project_instructions_loaded'] and c['startup_hook_executed']
 assert 'state=idle' in c['normal_stop_hook'] and 'event=stop' in c['normal_stop_hook']
 report=(E/f'measured/check-{n}-report.md').read_text()
 assert all(v in report for v in ['PROJECT_CEDAR','SKILL_WILLOW','HOOK_BIRCH'])
 assert 'a - b' in report
 if n<=3:
  assert c['transcript_totals']['ephemeral_1h_input_tokens']==0
  assert c['transcript_totals']['ephemeral_5m_input_tokens']>0
  assert not c['loaded_mcp_tool_names'] and not c['auto_memory_loaded']
  assert c['process']['FORCE_PROMPT_CACHING_5M']=='1'
  assert c['process']['CLAUDE_CODE_DISABLE_AUTO_MEMORY']=='1'
  assert 'MEMORY_MAPLE' not in report
 else:
  assert c['transcript_totals']['ephemeral_5m_input_tokens']==0
  assert c['transcript_totals']['ephemeral_1h_input_tokens']>0
  assert 'mcp__easel__chart' in c['loaded_mcp_tool_names']
  assert 'mcp__validation-server__validation_probe' in c['loaded_mcp_tool_names']
  assert c['auto_memory_loaded'] and 'MEMORY_MAPLE' in report
  assert c['process']['FORCE_PROMPT_CACHING_5M']=='unset'
assert m['checks'][1]['allowlist']
assert m['lean_mean_cache_create_tokens']<190000
for c in json.loads((E/'refusals.json').read_text()):
 assert c['pass_'] and c['exit']==1 and not c['meta_created']
p=json.loads((E/'plugin-runtime-summary.json').read_text())
assert set(p[0]['mcp_tools'])=={'mcp__lean-probe__early','mcp__lean-probe__late'}
assert all(x['plugin_skill_visible'] and x['completed'] for x in p)
assert not p[1]['mcp_tools'] and not p[2]['mcp_tools']
assert not p[1]['mcp_instruction_servers']
r=json.loads((E/'measured/live-results.json').read_text())
assert len(r)==4 and not any(x['meta_lean'] for x in r)
(E/'verification.txt').write_text('Verified saved runtime transcripts, reports, process environment, native cost ledger, Stop-hook state, MCP tools, auto-memory loading, and public CLI refusals. All scenario assertions passed.\n')
print((E/'verification.txt').read_text())
