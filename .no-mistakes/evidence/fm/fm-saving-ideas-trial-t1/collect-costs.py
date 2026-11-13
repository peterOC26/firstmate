import json,time,pathlib
B=pathlib.Path('.lean-live-6zhuxfbb');E=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M7A6XKEDE3MQDMAHTFHQPD5J');seen={}
for i in range(240):
 if not B.exists():break
 files=list((B/'claude').glob('.claude.json*'))+list((B/'claude/backups').glob('*'))
 for p in files:
  try:
   j=json.loads(p.read_text())
   for k,v in j.get('projects',{}).items():
    if str(B.name) not in k or 'lastSessionId' not in v or 'lastCost' not in v:continue
    q={a:b for a,b in v.items() if a in ['lastSessionId','lastCost','lastTotalInputTokens','lastTotalOutputTokens','lastTotalCacheCreationInputTokens','lastTotalCacheReadInputTokens','lastModelUsage']}
    seen[v['lastSessionId']]=q
  except (OSError,ValueError):pass
 (E/'product-costs.json').write_text(json.dumps(seen,indent=2))
 time.sleep(1)
print(json.dumps(seen,indent=2))
