import os, subprocess, time, json, pathlib, tempfile, html
root=pathlib.Path.cwd(); evidence=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M6W1RCVXS15VZT05F5RDMYXZ')
lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.'))
subprocess.run(['bin/fm-lab-home.sh','create',str(lab)],check=True,stdout=subprocess.DEVNULL)
(lab/'tmux').mkdir()
env=os.environ.copy()
for key in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','TMUX','TMUX_PANE']:
 env.pop(key,None)
env.update(TMUX_TMPDIR=str(lab/'tmux'),FM_HOME=str(lab))
report={}
def tmux(*args,check=True):
 return subprocess.run(['tmux','-L','fm-lab',*args],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=check)
try:
 for cli in ['codex']:
  tmux('new-session','-d','-s',cli,'-x','160','-y','45','-c',str(root),'-e','FM_HOME='+str(lab),'codex --disable hooks')
  screen=''
  for i in range(20):
   time.sleep(1)
   out=tmux('capture-pane','-p','-t',cli,check=False)
   screen=out.stdout
   if cli=='codex' and 'Update available' in screen:
    tmux('send-keys','-t',cli,'Escape')
    continue
   if any(x.lower() in screen.lower() for x in ['trust the','help improve','sign in','sign-in','log in','Hooks need review']):break
   if cli=='codex' and any(x in screen for x in ['›','Ask Codex','OpenAI Codex']):break
   if cli=='grok' and 'Shift+Tab:mode' in screen:break
  (evidence/(cli+'-worker-live-pane.txt')).write_text(screen)
  ansi=tmux('capture-pane','-e','-p','-t',cli,check=False).stdout
  (evidence/(cli+'-worker-live-pane.ansi')).write_text(ansi)
  report[cli]={'pane':screen,'dimensions':tmux('display-message','-p','-t',cli,'#{pane_width}x#{pane_height}').stdout.strip()}
  print(cli+': '+report[cli]['dimensions']+'\n'+screen)
 (evidence/'codex-worker-live.json').write_text(json.dumps(report,indent=2))
 # Classify the running worker surface through the same tmux transport as the product.
 shim=root/'.test-tmux-shim'; shim.mkdir(exist_ok=True)
 import shutil
 (shim/'tmux').write_text('#!/bin/sh\nexec '+shutil.which('tmux')+' -L fm-lab "$@"\n')
 (shim/'tmux').chmod(0o755)
 classify_env=env.copy();classify_env['PATH']=str(shim)+':'+env['PATH']
 code='. "$1/bin/fm-tmux-lib.sh"; . "$1/bin/fm-composer-lib.sh"; fm_tmux_composer_state codex'
 before=subprocess.run(['bash','-c',code,'_',str(root)],env=classify_env,text=True,capture_output=True).stdout.strip()
 tmux('send-keys','-t','codex','-l','FM_LIVE_PENDING_DRAFT_DO_NOT_SUBMIT')
 time.sleep(1)
 after=subprocess.run(['bash','-c',code,'_',str(root)],env=classify_env,text=True,capture_output=True).stdout.strip()
 pending_screen=tmux('capture-pane','-p','-t','codex').stdout
 (evidence/'codex-worker-pending-pane.txt').write_text(pending_screen)
 print('Composer before typing: '+before+'; after typing: '+after)
 (evidence/'codex-worker-composer-result.json').write_text(json.dumps({'before':before,'after':after,'dimensions':report['codex']['dimensions']}))
 if before!='empty' or after!='pending':raise RuntimeError('worker composer proof did not reach empty then pending')
 shutil.rmtree(shim)
finally:
 tmux('kill-server',check=False)
 import shutil
 shutil.rmtree(lab)
 print('Private tmux server stopped; disposable lab removed.')
