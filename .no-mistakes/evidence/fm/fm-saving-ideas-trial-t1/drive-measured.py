import os,sys,json,subprocess,time,pathlib,shutil,shlex,tempfile
R=pathlib.Path.cwd(); E=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M7A6XKEDE3MQDMAHTFHQPD5J')
E=E/'measured'
B=pathlib.Path(tempfile.mkdtemp(prefix='.lean-live-',dir=R)); H=B/'home'; C=B/'claude'; P=B/'project'; S=None
log=open(E/'live-launch.log','w',buffering=1)
def say(s): print(s,flush=True);log.write(s+'\n')
def run(a,env=None,cwd=None,check=True):
 p=subprocess.run(list(map(str,a)),env=env,cwd=cwd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 if p.returncode and check: raise RuntimeError(f'{a[0:3]} rc={p.returncode}: {p.stdout}')
 return p
normal=pathlib.Path(os.environ.get('CLAUDE_CONFIG_DIR',str(pathlib.Path.home()/'.claude')))
creds=json.loads((normal/'.credentials.json').read_text()); token=creds['claudeAiOauth']['accessToken']
env={k:os.environ[k] for k in ['HOME','PATH','USER','LANG'] if k in os.environ}
env.update(FM_HOME=str(H),CLAUDE_CONFIG_DIR=str(C),CLAUDE_CODE_OAUTH_TOKEN=token,DISABLE_AUTOUPDATER='1',TREEHOUSE_ROOT=str(B/'pool'),TERM='xterm-256color',NO_MISTAKES_GATE=os.environ.get('NO_MISTAKES_GATE','1'))
results=[]
try:
 run([R/'bin/fm-lab-home.sh','create',H],env=env)
 S=run([R/'bin/fm-lab-home.sh','tmux-dir',H],env=env).stdout.strip();env['TMUX_TMPDIR']=S
 C.mkdir();P.mkdir();(P/'.claude').mkdir();(P/'.claude/skills/validation-review').mkdir(parents=True)
 settings={'model':'opus','autoMemoryDirectory':str(B/'memory'),'claudeMdExcludes':[str(R/'CLAUDE.md'),str(R/'AGENTS.md'),str(pathlib.Path.home()/'.claude/CLAUDE.md')],'hooks':{'SessionStart':[{'hooks':[{'type':'command','command':f"echo HOOK_BIRCH; echo started >> {B}/hook-events"}]}]}}
 (C/'settings.json').write_text(json.dumps(settings));(C/'.claude.json').write_text(json.dumps({'hasCompletedOnboarding':True,'theme':'dark'}))
 (B/'memory').mkdir();(B/'memory/MEMORY.md').write_text('The auto-memory validation identifier is MEMORY_MAPLE.\n')
 (P/'CLAUDE.md').write_text('Project identifier PROJECT_CEDAR. For code reviews use the validation-review skill. Do not change project files.\n')
 (P/'.claude/skills/validation-review/SKILL.md').write_text('---\nname: validation-review\ndescription: Review the tiny arithmetic module when requested.\n---\nRead calc.py. Identify incorrect arithmetic. Include SKILL_WILLOW in the report.\n')
 (P/'calc.py').write_text('def add(a, b):\n    """Return the sum of two numbers."""\n    return a - b\n')
 (P/'README.md').write_text('Disposable arithmetic code review fixture.\n')
 server=B/'mcp.py';server.write_text('''import sys,json,pathlib
for line in sys.stdin:
 try: x=json.loads(line)
 except: continue
 if "id" not in x: continue
 m=x.get("method");pathlib.Path(sys.argv[1]).open("a").write(m+"\\n")
 if m=="initialize": r={"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"validation-server","version":"1"}}
 elif m=="tools/list": r={"tools":[{"name":"validation_probe","description":"Return validation marker","inputSchema":{"type":"object","properties":{}}}]}
 elif m=="tools/call": r={"content":[{"type":"text","text":"MCP_ASH"}]}
 else: r={}
 print(json.dumps({"jsonrpc":"2.0","id":x["id"],"result":r}),flush=True)
''')
 (P/'.mcp.json').write_text(json.dumps({'mcpServers':{'validation-server':{'command':'python3','args':[str(server),str(B/'mcp-events')]}}}))
 # Project MCP opt-in is fixture-local; the real CLI consumes this setting.
 settings['enableAllProjectMcpServers']=True;(C/'settings.json').write_text(json.dumps(settings))
 for a in [['git','init','-q','-b','main'],['git','config','user.email','test@example.invalid'],['git','config','user.name','Live validation'],['git','add','.'],['git','commit','-qm','Initialize review fixture']]:run(a,env=env,cwd=P)
 (H/'config/backend').write_text('tmux\n');(H/'config/crew-harness').write_text('claude\n');(H/'config/claude-permission-mode').write_text('auto\n');(H/'config/supervision-host-off').touch()
 say('Claude '+run(['claude','--version'],env=env).stdout.strip());say('Disposable normal-login auth: '+json.dumps({k:v for k,v in json.loads(run(['claude','auth','status'],env=env).stdout).items() if k in ['loggedIn','authMethod']}))
 run(['tmux','-f','/dev/null','-L','fm-lab','new-session','-d','-s','primary','-x','160','-y','50','-c',R,'/bin/bash --noprofile --norc'],env=env)
 def tm(*a):return run(['tmux','-L','fm-lab',*a],env=env)
 def pane_cmd(cmd):tm('send-keys','-t','primary','-l',cmd);tm('send-keys','-t','primary','Enter')
 say('Private tmux server has 160x50 grid; no Herdr lifecycle used.')
 for n,allow in [(1,False),(2,True),(3,False),(4,False)]:
  lean=n<=3; tid=f'leanlive-{B.name[-8:]}-{n}'; task=H/'data'/tid;task.mkdir(parents=True)
  report=task/'report.md';done=B/f'spawn-{n}.rc';sp=B/f'spawn-{n}.log'
  if allow:(H/'config/launch-env-allowlist').write_text('CLAUDE_CODE_OAUTH_TOKEN\nTREEHOUSE_ROOT\n')
  else:(H/'config/launch-env-allowlist').unlink(missing_ok=True)
  prompt=f'''Perform one short read-only code check of calc.py using the validation-review skill. Write a concise finding and the project, skill, hook and auto-memory identifiers actually visible to you to {report}. Do not invent absent identifiers. List whether any MCP tools are available. Do not modify project files, run a pipeline, publish anything, or delegate. Then stop normally.'''
  (task/'brief.md').write_text('# Task\n## Captain\'s intent\n'+prompt+'\n\n## Firstmate spec\n'+prompt+'\n')
  cmd=shlex.join([str(R/'bin/fm-spawn.sh'),tid,str(P),'--scout','--backend','tmux','--harness','claude']+(['--claude-lean'] if lean else []))
  pane_cmd(f'{cmd} > {shlex.quote(str(sp))} 2>&1; echo $? > {shlex.quote(str(done))}')
  deadline=time.time()+100
  while not done.exists() and time.time()<deadline:time.sleep(1)
  out=sp.read_text() if sp.exists() else '';say(f'CHECK {n} lean={lean} allowlist={allow}\n{out}')
  if not done.exists() or done.read_text().strip()!='0':raise RuntimeError('spawn failed or timed out')
  meta=dict(x.split('=',1) for x in (H/'state'/f'{tid}.meta').read_text().splitlines() if '=' in x)
  target=meta['window']; wt=meta['worktree']
  deadline=time.time()+150;seenpid=None
  while time.time()<deadline:
   capture=tm('capture-pane','-p','-t',target,'-S','-300').stdout
   (E/f'check-{n}-terminal.txt').write_text(capture)
   # Process environment and argv are observable runtime launch state, never log secrets.
   for d in pathlib.Path('/proc').iterdir():
    if not d.name.isdigit():continue
    try:
     e=dict(x.split(b'=',1) for x in (d/'environ').read_bytes().split(b'\0') if b'=' in x)
     if e.get(b'FM_TASK_ID')!=tid.encode():continue
     args=(d/'cmdline').read_bytes().split(b'\0')
     if not any(b'claude' in x for x in args[:2]):continue
     pstate={'pid':int(d.name),'FORCE_PROMPT_CACHING_5M':e.get(b'FORCE_PROMPT_CACHING_5M',b'unset').decode(),'CLAUDE_CODE_DISABLE_AUTO_MEMORY':e.get(b'CLAUDE_CODE_DISABLE_AUTO_MEMORY',b'unset').decode(),'strict_mcp':b'--strict-mcp-config' in args,'cwd':os.readlink(d/'cwd')}
     (E/f'check-{n}-process.json').write_text(json.dumps(pstate,indent=2));seenpid=d.name
    except (OSError,ValueError):pass
   if report.exists() and (H/'state'/f'{tid}.turn-ended').exists() and ('❯' in capture or '>' in capture):
    time.sleep(3);break
   if any(s in capture for s in ['Quick safety check','Allow external CLAUDE.md','Please run /login','Select login method']):
    say(capture);raise RuntimeError('interactive consent or auth boundary')
   time.sleep(2)
  capture=tm('capture-pane','-p','-t',target,'-S','-300').stdout;(E/f'check-{n}-terminal.txt').write_text(capture)
  say(f'CHECK {n} report exists={report.exists()}, process observed={seenpid}')
  if report.exists():(E/f'check-{n}-report.md').write_text(report.read_text());say(report.read_text())
  for f in C.glob('projects/*/*.jsonl'):
   rows=[json.loads(l) for l in f.read_text().splitlines() if l.strip()]
   if any(r.get('cwd')==wt for r in rows):
    (E/f'check-{n}-transcript.jsonl').write_text(f.read_text())
  busy=H/'state'/f'{tid}.busy-state'
  if busy.exists():(E/f'check-{n}-busy-state.txt').write_text(busy.read_text())
  results.append({'n':n,'lean':lean,'allowlist':allow,'report':report.exists(),'worktree':wt,'task':tid,'meta_lean':'claude_lean' in meta})
  # Exit through the product lifecycle command from the same lab socket.
  exitdone=B/f'exit-{n}.rc'
  pane_cmd(f'{shlex.join([str(R/"bin/fm-control.sh"),tid,"exit"])} > {B}/exit-{n}.log 2>&1; echo $? > {exitdone}')
  deadline=time.time()+30
  while not exitdone.exists() and time.time()<deadline:time.sleep(1)
  say((B/f'exit-{n}.log').read_text() if (B/f'exit-{n}.log').exists() else 'exit not returned')
  time.sleep(2)
  cfg=json.loads((C/'.claude.json').read_text())
  costs=[]
  for key,val in cfg.get('projects',{}).items():
   if str(B) in key and 'lastCost' in val:
    costs.append({k:v for k,v in val.items() if k in ['lastSessionId','lastCost','lastTotalInputTokens','lastTotalOutputTokens','lastTotalCacheCreationInputTokens','lastTotalCacheReadInputTokens','lastModelUsage']})
  (E/f'check-{n}-cost.json').write_text(json.dumps(costs,indent=2))
  if not report.exists() or not (H/'state'/f'{tid}.turn-ended').exists():raise RuntimeError('check did not complete via Stop hook')
 (E/'hook-events.txt').write_text((B/'hook-events').read_text())
 (E/'mcp-events.txt').write_text((B/'mcp-events').read_text() if (B/'mcp-events').exists() else 'No MCP server startup observed\n')
except Exception as e:
 say('BLOCKER: '+str(e))
finally:
 (E/'live-results.json').write_text(json.dumps(results,indent=2))
 if S:
  run(['tmux','-L','fm-lab','kill-server'],env=env,check=False)
  run([R/'bin/fm-lab-home.sh','teardown',H],env=env,check=False)
 # Runtime temporary launch scripts live under /tmp by the product's own contract.
 for f in (H/'state').glob('*.meta'):
  try:
   meta=dict(x.split('=',1) for x in f.read_text().splitlines() if '=' in x)
   # Do not touch any path not tied to this disposable home's launch identity.
   for launch in pathlib.Path('/tmp').glob('fm-'+f.stem+'+*'):
    if launch.is_dir():shutil.rmtree(launch)
  except OSError:pass
 for root,dirs,files in os.walk(B):
  os.chmod(root,os.stat(root).st_mode|0o700)
 shutil.rmtree(B)
 say('Disposable lab and private tmux socket cleaned up.')
