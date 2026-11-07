import os, subprocess, time, json, pathlib, tempfile, html
root=pathlib.Path.cwd(); evidence=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M6W1RCVXS15VZT05F5RDMYXZ')
lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.'))
subprocess.run(['bin/fm-lab-home.sh','create',str(lab)],check=True,stdout=subprocess.DEVNULL)
(lab/'tmux').mkdir()
(lab/'config'/'supervision-host').touch()
env=os.environ.copy()
for key in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','TMUX','TMUX_PANE']:
 env.pop(key,None)
env.update(TMUX_TMPDIR=str(lab/'tmux'),FM_HOME=str(lab))
report={}
def tmux(*args,check=True):
 return subprocess.run(['tmux','-L','fm-lab',*args],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=check)
try:
 for cli in ['claude']:
  tmux('new-session','-d','-s',cli,'-x','160','-y','45','-c',str(root),'-e','FM_HOME='+str(lab),cli)
  screen=''
  for i in range(20):
   time.sleep(1)
   out=tmux('capture-pane','-p','-t',cli,check=False)
   screen=out.stdout
   if cli=='codex' and 'Update available' in screen:
    tmux('send-keys','-t',cli,'Escape')
    continue
   if any(x.lower() in screen.lower() for x in ['trust the','one you trust','help improve','sign in','sign-in','log in','Hooks need review']):break
   if cli=='codex' and any(x in screen for x in ['›','Ask Codex','OpenAI Codex']):break
   if cli=='grok' and 'Shift+Tab:mode' in screen:break
  (evidence/(cli+'-live-pane.txt')).write_text(screen)
  ansi=tmux('capture-pane','-e','-p','-t',cli,check=False).stdout
  (evidence/(cli+'-live-pane.ansi')).write_text(ansi)
  report[cli]={'pane':screen,'dimensions':tmux('display-message','-p','-t',cli,'#{pane_width}x#{pane_height}').stdout.strip()}
  print(cli+': '+report[cli]['dimensions']+'\n'+screen)
 (evidence/'claude-primary-live.json').write_text(json.dumps(report,indent=2))
finally:
 tmux('kill-server',check=False)
 import shutil
 shutil.rmtree(lab)
 print('Private tmux server stopped; disposable lab removed.')
