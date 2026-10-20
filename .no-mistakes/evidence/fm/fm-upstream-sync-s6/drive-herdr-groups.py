import os, pathlib, subprocess, json, tempfile, shutil, shlex
root = pathlib.Path.cwd()
ev = pathlib.Path(__file__).parent
helper = root / 'bin/fm-herdr-lab.sh'
session = 'fm-lab-sync-groups'
env = os.environ.copy()
for key in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','HERDR_ENV','HERDR_PANE_ID','HERDR_TAB_ID','HERDR_WORKSPACE_ID','HERDR_SOCKET_PATH','HERDR_SESSION','FM_HERDR_GROUPS_AGENT_VIEW']:
    env.pop(key, None)
env['FM_HERDR_LAB_STATE_DIR'] = str(ev / 'herdr-lab')
original_path = env['PATH']
lab = pathlib.Path(tempfile.mkdtemp(prefix='group-lab.', dir=ev))
env['FM_HOME'] = str(lab)
trans = []
def run(args, expected=0, env_=None):
    p = subprocess.run(list(map(str,args)),env=env_ or env,text=True,capture_output=True)
    trans.append('$ '+shlex.join(map(str,args))+'\n'+p.stdout+p.stderr+'exit='+str(p.returncode)+'\n')
    assert p.returncode == expected, trans[-1]
    return p.stdout
def h(*args):
    return run([helper,'run',session,*args])
try:
    run([root/'bin/fm-lab-home.sh','create',lab])
    # provision owns prepare for a new named session.
    run([helper,'provision',session])
    status = json.loads(h('status','--json'))
    print('Herdr status:',json.dumps(status),flush=True)
    objects = []
    for task in ['web-lab','api-lab']:
        out = json.loads(h('workspace','create','--cwd',root,'--label',task,'--no-focus'))['result']
        pane = out['root_pane']
        objects.append(pane)
        (lab/f'state/{task}.meta').write_text(f'kind=scout\nproject={root}/sample\nbackend=herdr\nherdr_session={session}\nherdr_workspace_id={pane["workspace_id"]}\nherdr_pane_id={pane["pane_id"]}\n')
    # Transparent routing only: every production Herdr CLI request still reaches
    # the real binary through the guarded helper and this exact named session.
    bindir = lab/'routing-bin'; bindir.mkdir()
    wrapper = bindir/'herdr'
    wrapper.write_text('#!/usr/bin/env python3\nimport os,sys,subprocess\na=sys.argv[1:]\nassert a[-2:]==["--session",'+repr(session)+']\na=a[:-2]\ne=os.environ.copy();e["PATH"]='+repr(original_path)+'\nr=subprocess.run(['+repr(str(helper))+',"run",'+repr(session)+',*a],env=e)\nsys.exit(r.returncode)\n')
    wrapper.chmod(0o700)
    product_env = env.copy(); product_env['PATH'] = str(bindir)+':'+original_path
    groups = root/'bin/fm-herdr-groups.sh'
    # The default is off, including an explicit direct sync.
    run([groups,'sync'],env_=product_env)
    before = json.loads(h('pane','list'))
    assert all('fm_group' not in p.get('tokens',{}) for p in before['result']['panes'])
    (lab/'config/herdr-project-groups').write_text('Frontend task:web\nBackend task:api\nOther *\n')
    (lab/'state/api-lab.status').write_text('blocked: local lab check\n')
    run([groups,'plan'],env_=product_env)
    run([groups,'sync'],env_=product_env)
    after = json.loads(h('pane','list'))
    (ev/'herdr-group-tokens.json').write_text(json.dumps(after,indent=2))
    by_id = {p['pane_id']:p for p in after['result']['panes']}
    for pane,group,state in zip(objects,['Frontend','Backend'],['running','problem']):
        tokens = by_id[pane['pane_id']]['tokens']
        assert tokens['fm_group']==group and tokens['fm_state']==state, tokens
    # Update status and check the next sync changes the live token.
    (lab/'state/web-lab.status').write_text('done: local lab report\n')
    run([groups,'sync'],env_=product_env)
    done = json.loads(h('pane','list'))
    assert next(p for p in done['result']['panes'] if p['pane_id']==objects[0]['pane_id'])['tokens']['fm_state']=='done'
    run([groups,'clear'],env_=product_env)
    cleared = json.loads(h('pane','list'))
    assert all(not any(k.startswith('fm_') for k in p.get('tokens',{})) for p in cleared['result']['panes'])
    (ev/'herdr-group-cleared.json').write_text(json.dumps(cleared,indent=2))
    print('Herdr groups default-off, sync, status refresh, and clear passed.',flush=True)
finally:
    try:
        run([helper,'teardown',session])
    finally:
        (ev/'herdr-groups-transcript.txt').write_text('\n'.join(trans))
        shutil.rmtree(lab)
