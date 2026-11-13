from pathlib import Path
E=Path('/home/zabi/.no-mistakes/evidence/01M7A6XKEDE3MQDMAHTFHQPD5J')
s=(E/'drive-measured.py').read_text()
s=s.replace("E=E/'measured'", "E=E/'round2'/'measured'; E.mkdir(parents=True,exist_ok=True)")
s=s.replace("results=[]", "(B/'tmp').mkdir(); env['TMPDIR']=str(B/'tmp')\nresults=[]")
s=s.replace("for d in pathlib.Path('/proc').iterdir():\n    if not d.name.isdigit():continue", "pane_pid=int(tm('display-message','-p','-t',target,'#{pane_pid}').stdout.strip())\n   process_rows=run(['ps','-eo','pid=,ppid=']).stdout.splitlines()\n   descendants={pane_pid}\n   pairs=[tuple(map(int,row.split())) for row in process_rows]\n   for _ in range(12):\n    descendants.update(pid for pid,parent in pairs if parent in descendants)\n   for pid in descendants:\n    d=pathlib.Path('/proc')/str(pid)")
s=s.replace("'strict_mcp':b'--strict-mcp-config' in args,", "'strict_mcp':b'--strict-mcp-config' in args,'disallow_mcp':b'mcp__*' in args,")
s=s.replace("deadline=time.time()+150", "deadline=time.time()+180")
start=s.index(' # Runtime temporary launch scripts')
end=s.index(' for root,dirs,files in os.walk(B):',start)
s=s[:start]+s[end:]
s=s.replace("  try:\n   meta=dict(x.split('=',1) for x in f.read_text().splitlines() if '=' in x)\n",'')
(E/'round2/drive-measured.py').write_text(s)
