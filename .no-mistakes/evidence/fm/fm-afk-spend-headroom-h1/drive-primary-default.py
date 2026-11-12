from pathlib import Path
import os, subprocess, tempfile, shutil, time, shlex, json
root=Path.cwd()
evidence=Path('/home/zabi/.no-mistakes/evidence/01M77978F36175B7GRV0CDSZPB')
lab=Path(tempfile.mkdtemp(prefix='.l',dir=root))
env=os.environ.copy()
for key in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_TEST_SEAM','FM_TEST_HARNESS','FM_AFK_MODE']:
    env.pop(key,None)
env.update(TMUX_TMPDIR=str(lab/'tmux'),FM_HOME=str(lab))
log=evidence/'primary-default-stream.jsonl'
status=evidence/'primary-default-exit.txt'
def tmux(*args,**kw):
    return subprocess.run(['tmux','-L','fm-lab',*args],env=env,text=True,**kw)
try:
    subprocess.run(['bin/fm-lab-home.sh','create',str(lab)],check=True,stdout=subprocess.DEVNULL)
    (lab/'tmux').mkdir()
    (lab/'config/supervision-host').touch()
    for i in range(15):
        (lab/f'state/worker-{i}.meta').write_text(f'kind=ship\nwindow=fm-worker-{i}\n')
        (lab/f'state/worker-{i}.status').write_text('2026-11-12T00:00:00Z done: previously completed work\n')
    instruction=f'This is a disposable live-validation primary with FM_HOME={lab}. Confine every intentional source, config, data, and state write to that marked lab home or the current worktree. Do not edit tracked source or tests, change global or user tool settings, sign in or out, install anything, spawn workers, contact people, push, open a PR, or control no-mistakes. Use the repository afk skill normally for the supplied captain request; only the CLI print surface differs from an interactive primary. Do not fabricate output. Do not start independent agents. Return after the entry announcement and read-back.'
    command=['claude','-p','/afk Wait for my return.','--allowedTools','Bash,Read','--output-format','stream-json','--verbose','--append-system-prompt',instruction]
    shell_command=shlex.join(command)+' > '+shlex.quote(str(log))+' 2>&1; printf "%s\\n" "$?" > '+shlex.quote(str(status))
    tmux('new-session','-d','-s','primary','-x','120','-y','40','-c',str(root),'-e',f'FM_HOME={lab}',shell_command,check=True)
    deadline=time.monotonic()+90
    while time.monotonic()<deadline and not status.exists():
        time.sleep(1)
    if not status.exists():
        print('Primary did not finish within 90 seconds')
        result=tmux('capture-pane','-p','-S','-1000','-t','primary',capture_output=True)
        (evidence/'primary-default-pane.txt').write_text(result.stdout+result.stderr)
    if log.exists():
        lines=log.read_text().splitlines()
        for line in lines:
            try: item=json.loads(line)
            except json.JSONDecodeError:
                print(line[:1500]); continue
            if item.get('type')=='result': print(json.dumps(item))
    record=lab/'state/.afk-contract'
    if record.exists(): (evidence/'primary-default-record.txt').write_text(record.read_text())
finally:
    if (lab/'tmux').is_dir(): tmux('kill-server',capture_output=True)
    shutil.rmtree(lab)
