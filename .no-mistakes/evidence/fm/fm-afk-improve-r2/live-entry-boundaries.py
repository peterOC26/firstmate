import os, pathlib, shutil, subprocess, tempfile
root=pathlib.Path.cwd()
evidence=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M6Q1S6BCZ3DT0QKMCSE7DG31')
lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.'))
env=dict(os.environ)
for key in list(env):
    if key.startswith(('FM_','TASKS_AXI_')): env.pop(key)
env['FM_HOME']=str(lab)
with (evidence/'entry-boundaries.txt').open('w') as log:
    def run(args,extra=None):
        p=subprocess.run(args,cwd=root,env=dict(env,**(extra or {})),capture_output=True,text=True,timeout=30)
        log.write('$ '+' '.join(args).replace(str(lab),'$LAB')+'\n'+p.stdout+p.stderr+f'exit: {p.returncode}\n')
        assert p.returncode==0,(args,p.stdout,p.stderr)
        return p.stdout
    try:
        run(['bin/fm-lab-home.sh','create',str(lab)])
        (lab/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
        (lab/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
        run(['bin/fm-tasks-axi.sh','list','--fields','held,hold_reason,hold_until,blocked,blocked_by,deps,body'])
        empty_output=run(['bin/fm-afk-entry-brief.sh'])
        assert not list((lab/'state').iterdir())
        empty_next=run(['bin/fm-afk-entry-brief.sh','not-started'])
        run(['bin/fm-afk-return.sh','check'])
        run(['bin/fm-tasks-axi.sh','add','one-job','One ordinary task'])
        one_output=run(['bin/fm-afk-entry-brief.sh'])
        assert 'entry inventory:' not in one_output
        log.write('Adding one task removes the diagnostic without changing tool configuration.\n')
        out=run(['bin/fm-afk-launch.sh','enter','--words','stay quiet'],{'FM_AFK_MODE':'quiet'})
        assert 'Read-back checklist:' not in out and 'Live work:' not in out
        assert run(['bin/fm-afk-contract.sh','mode']).strip()=='quiet'
        assert run(['bin/fm-afk-contract.sh','words']).strip()=='stay quiet'
        log.write('Quiet entry preserves quiet posture and does not print the away inventory.\n')
        assert 'entry inventory:' not in empty_output and not empty_next.strip(), 'Healthy empty backlog produces a spurious error in entry and Not started'
    finally:
        shutil.rmtree(lab)
        log.write('Disposable lab removed.\n')
print((evidence/'entry-boundaries.txt').read_text())
