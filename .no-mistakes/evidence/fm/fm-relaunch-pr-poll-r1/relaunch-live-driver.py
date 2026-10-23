import os, pathlib, subprocess, json, time
root=pathlib.Path.cwd(); scratch=root/'.nm-test-pr'; lab=scratch/'lifecycle'; ev=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M5MT6K4CYJM29EYMY18ZSE8S')
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k in ('TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND','HERDR_ENV','HERDR_SESSION'))}
env.update(FM_HOME=str(lab), FM_BACKEND='tmux', TMUX=str(scratch/'s')+',0,0', TREEHOUSE_ROOT=str(lab/'pool'), TMPDIR=str(scratch), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', FM_CONTROL_LAUNCH_WAIT='45', FM_CONTROL_EXIT_WAIT='20', FM_CONTROL_POLL='0.2')
log=[]
def run(args, cwd=root, timeout=65, check=True):
 p=subprocess.run([str(x) for x in args],cwd=cwd,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
 log.extend(['$ '+' '.join(str(x) for x in args),p.stdout.strip(),f'exit={p.returncode}'])
 (ev/'relaunch-live-transcript.txt').write_text('\n'.join(log)+'\n')
 if check: assert p.returncode==0,p.stdout
 return p
try:
 run([root/'bin/fm-lab-home.sh','create',lab])
 proj=lab/'repo'; proj.mkdir()
 run(['git','init','-q','-b','main',proj]); (proj/'README.md').write_text('Disposable relaunch live check.\n')
 run(['git','add','README.md'],proj); run(['git','-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-qm','initial'],proj)
 run(['git','clone','--bare','-q',proj,lab/'origin.git']); run(['git','remote','add','origin',lab/'origin.git'],proj)
 p=run(['treehouse','get','--lease','--lease-holder',str(lab)+'/a-live/live-validation','--json','--no-fetch'],proj)
 lease=json.loads(p.stdout.splitlines()[-1]); log.append('Treehouse lease: '+json.dumps(lease));
 wt=pathlib.Path(lease.get('path') or lease.get('worktree'))
 run(['git','switch','-c','fm/a-live'],wt)
 run(['tmux','-S',scratch/'s','new-session','-d','-s','relaunch-lab','-n','fm-a-live','-x','120','-y','40','-c',wt])
 # Claim the real leased slot using its production owner.
 run(['bash','-c','. "$1/bin/fm-wake-lib.sh"; fm_treehouse_slot_owner_claim "$2" a-live "$3"','bash',root,wt,lab])
 (lab/'data/a-live').mkdir()
 (lab/'data/a-live/brief.md').write_text('''# Task
## Captain's intent
This is a disposable lifecycle validation probe. Reply READY and wait. Do not execute tools, modify files, publish anything, or run any pipeline.
## Firstmate spec
Reply READY and wait. The supervisor alone validates the lifecycle and will stop this process.
''')
 meta=lab/'state/a-live.meta'
 lease_id=lease.get('lease_id'); holder=lease.get('lease_holder')
 assert lease_id and holder, lease
 meta.write_text(f'window=relaunch-lab:fm-a-live\nendpoint_task_id=a-live\nworktree={wt}\nproject={proj}\nharness=codex\nkind=ship\nmode=no-mistakes\nyolo=off\nbranch=fm/a-live\ntasktmp={lab}/tasktmp\nmodel=default\neffort=default\ntreehouse_lease_id={lease_id}\ntreehouse_lease_holder={holder}\n')
 (lab/'tasktmp').mkdir()
 # The initial process uses the real existing login and only per-process settings.
 command='codex --dangerously-bypass-approvals-and-sandbox --disable hooks "Reply READY and wait. Do not use tools or modify files. This is a disposable CLI lifecycle check."'
 run(['tmux','-S',scratch/'s','send-keys','-t','relaunch-lab:fm-a-live','-l',command]); run(['tmux','-S',scratch/'s','send-keys','-t','relaunch-lab:fm-a-live','Enter'])
 time.sleep(8)
 capture=run(['tmux','-S',scratch/'s','capture-pane','-p','-t','relaunch-lab:fm-a-live','-S','-80'])
 if 'Trust this folder?' in capture.stdout:
  raise RuntimeError('Codex is blocked at folder trust. Continuing saves trust in user tool configuration outside the worktree, which the workspace boundary forbids. Provide a pretrusted authenticated disposable CODEX_HOME inside the worktree, or authorize saving trust for this fixture.')
 run([root/'bin/fm-pr-check.sh','a-live','https://github.com/peterOC26/firstmate/pull/33'])
 run([root/'bin/fm-control.sh','a-live','relaunch','--note','Disposable runtime probe: reply READY and wait; no tools, edits, publication, or pipeline.'],timeout=110)
 log.append('persisted metadata after real relaunch:\n'+meta.read_text()); (ev/'relaunch-live-transcript.txt').write_text('\n'.join(log)+'\n')
 run(['tmux','-S',scratch/'s','capture-pane','-p','-t','relaunch-lab:fm-a-live','-S','-80'])
 env.update(FM_CHECK_INTERVAL='0', FM_POLL='0.1', FM_HEARTBEAT='999999', FM_SIGNAL_GRACE='0')
 # The originally armed PR poll must still authenticate; no re-arm after relaunch.
 p=run([root/'bin/fm-watch.sh'])
 assert ': merged' in p.stdout and 'rejected unauthenticated' not in p.stdout,p.stdout
 assert not (lab/'state/a-live.check.sh').exists()
 queue=(lab/'state/.wake-queue').read_text(); assert 'check: merge landed: a-live ' in queue,queue
 log.append('durable wake queue:\n'+queue)
except Exception as exc:
 log.append('BLOCKER: '+str(exc))
 raise
finally:
 run(['tmux','-S',scratch/'s','kill-server'],check=False)
 (ev/'relaunch-live-transcript.txt').write_text('\n'.join(log)+'\n')
print('\n'.join(log))
