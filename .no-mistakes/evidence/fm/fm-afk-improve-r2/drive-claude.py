import subprocess,os,pathlib,time,shutil
r=pathlib.Path.cwd(); lab=r/'.c'; e=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M6Q1S6BCZ3DT0QKMCSE7DG31/claude-live-launch.txt'); env=os.environ.copy()
for k in ('NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE'):
    env.pop(k,None)
env['TMUX_TMPDIR']=str(lab/'t')
def tmux(*args):return subprocess.run(['tmux','-L','fm-lab',*args],env=env,cwd=r,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=20)
try:
    subprocess.run(['bin/fm-lab-home.sh','create',str(lab)],check=True)
    (lab/'t').mkdir(); (lab/'config/supervision-host').touch()
    p=tmux('new-session','-d','-s','primary','-x','120','-y','40','-c',str(r),'-e','FM_HOME='+str(lab),'claude')
    assert p.returncode==0,p.stdout
    time.sleep(5)
    p=tmux('capture-pane','-p','-S','-200','-t','primary')
    e.write_text('Real Claude launch in a private fm-lab tmux server, 120 columns x 40 rows.\n'+p.stdout)
    print(p.stdout)
finally:
    p=tmux('kill-server'); shutil.rmtree(lab,ignore_errors=True)
    with e.open('a') as f:f.write('\nPrivate tmux server stopped and disposable lab removed. No trust choice was submitted.\n')
