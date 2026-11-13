import pathlib,tempfile,subprocess,os,shutil,json
R=pathlib.Path.cwd();E=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M7A6XKEDE3MQDMAHTFHQPD5J');B=pathlib.Path(tempfile.mkdtemp(prefix='.lean-refusals-',dir=R));H=B/'home';P=B/'project';SM=B/'secondmate';cases=[]
env={k:os.environ[k] for k in ['HOME','PATH','USER','LANG','NO_MISTAKES_GATE'] if k in os.environ};env['FM_HOME']=str(H)
def run(a,cwd=R):return subprocess.run(list(map(str,a)),cwd=cwd,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
try:
 assert run([R/'bin/fm-lab-home.sh','create',H]).returncode==0
 (H/'config/backend').write_text('tmux\n');(H/'config/crew-harness').write_text('claude\n')
 P.mkdir();SM.mkdir()
 for p in [P,SM]:
  assert run(['git','init','-q','-b','main'],p).returncode==0
 (SM/'bin').mkdir();(SM/'data').mkdir();(SM/'AGENTS.md').write_text('# Firstmate\n');(SM/'.fm-secondmate-home').write_text('lean-sm\n');(SM/'data/charter.md').write_text('Refusal fixture\n');(SM/'.gitignore').write_text('projects/\nstate/\ndata/\nconfig/\n.no-mistakes/\n')
 tests=[('secondmate supervision',['lean-sm',str(SM),'--secondmate','--claude-lean'],'does not apply to secondmate'),('non-Claude harness',['lean-codex',str(P),'--scout','--harness','codex','--claude-lean'],'applies only to the claude harness'),('raw command',['lean-raw',str(P),'--scout','--claude-lean','echo unsafe'],'not a raw launch command'),('T3 unsupported backend',['lean-t3',str(P),'--scout','--backend','t3code','--claude-lean'],'cannot run on backend=t3code'),('flag value',['lean-value',str(P),'--scout','--claude-lean=1'],'takes no value')]
 for name,args,expected in tests:
  tid=args[0];d=H/'data'/tid;d.mkdir(parents=True);(d/'brief.md').write_text("# Task\n## Captain's intent\nExercise the refusal boundary.\n\n## Firstmate spec\nDo not launch.\n")
  p=run([R/'bin/fm-spawn.sh',*args]);m=(H/'state'/f'{tid}.meta').exists();ok=p.returncode!=0 and expected in p.stdout and not m
  cases.append(dict(name=name,command='bin/fm-spawn.sh '+' '.join(args),exit=p.returncode,output=p.stdout,meta_created=m,pass_=ok))
 (E/'refusals.json').write_text(json.dumps(cases,indent=2));print(json.dumps(cases,indent=2))
finally:shutil.rmtree(B)
