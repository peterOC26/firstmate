import os, pathlib, subprocess, tempfile, shutil, json, shlex
root = pathlib.Path.cwd()
ev = pathlib.Path(__file__).parent
lab = pathlib.Path(tempfile.mkdtemp(prefix='cli-lab.', dir=ev))
env = os.environ.copy()
for key in ['FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_SUPERVISION_ACTOR', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND']:
    env.pop(key, None)
env['FM_HOME'] = str(lab)
lines = []
def run(*args, expected=0):
    p = subprocess.run([str(a) for a in args], env=env, text=True, capture_output=True)
    lines.append('$ ' + shlex.join(map(str, args)) + '\n' + p.stdout + p.stderr + 'exit=' + str(p.returncode) + '\n')
    assert p.returncode == expected, lines[-1]
    return p.stdout
try:
    run('bin/fm-lab-home.sh', 'create', lab)
    run('bin/fm-afk-contract.sh', 'enter', '--words', 'Finish the queued local checks; keep review decisions for my return.')
    assert run('bin/fm-afk-contract.sh', 'field', 'spend_max_concurrent_workers').strip() == '4'
    run('bin/fm-afk-contract.sh', 'archive')
    for n in range(5):
        (lab / f'state/worker-{n}.meta').write_text('kind=ship\n')
    (lab / 'state/secondmate.meta').write_text('kind=secondmate\n')
    assert run('bin/fm-afk-contract.sh', 'live-workers').strip() == '5'
    run('bin/fm-afk-contract.sh', 'enter', '--words', 'Continue the existing workers.')
    assert run('bin/fm-afk-contract.sh', 'field', 'spend_max_concurrent_workers').strip() == '5'
    run('bin/fm-afk-contract.sh', 'readback')
    run('bin/fm-afk-contract.sh', 'archive')
    run('bin/fm-afk-contract.sh', 'enter', '--spend', '3', '--words', 'Keep the explicit cap of three.')
    assert run('bin/fm-afk-contract.sh', 'field', 'spend_max_concurrent_workers').strip() == '3'
    run('bin/fm-afk-contract.sh', 'archive')
    run('bin/fm-afk-contract.sh', 'enter', '--spend', '0', expected=2)
    assert not (lab / 'state/.afk-contract').exists()
    run('bin/fm-role.sh', 'report')
    run('bin/fm-role.sh', 'check', root, expected=1)
    run('bin/fm-brief.sh', 'publish-guard', 'firstmate', '--project', root, '--mode', 'direct-PR', expected=1)
    assert not (lab / 'data/publish-guard/brief.md').exists()
    run('bin/fm-brief.sh', 'local-draft', 'firstmate', '--project', root, '--mode', 'local-only')
    run('bin/fm-role.sh', 'report')
    for path in (lab / 'state').glob('*.meta'):
        path.unlink()
    # Generate a real backlog and have the fleet CLI produce its canonical input.
    count = 450
    url = 'https://github.com/peterOC26/firstmate/pull/26'
    rows = ['# Backlog', '', '## Queued', ''] + [f'- [ ] large-{i:04d} - Contribution {i}: ' + ('context ' * 100) + f'{url} (repo: sample) (kind: ship)' for i in range(count)]
    (lab / 'data/backlog.md').write_text('\n'.join(rows) + '\n')
    canonical = run('bin/fm-fleet-snapshot.sh', '--contribution-input')
    inp = lab / 'input.json'
    inp.write_text(canonical)
    data = json.loads(canonical)
    assert len(canonical.encode()) > 131072, len(canonical)
    assert len(data['backlog']['records']) == count, len(data['backlog']['records'])
    result = json.loads(run('bin/fm-contributions.sh', 'snapshot', inp, '--all'))
    assert result['known'] == 1, result['known']
    assert len(result['rows'][0]['tasks']) == count
    assert result['checked'] == 0 and not result['complete']
    (ev / 'large-contribution-snapshot.json').write_text(json.dumps({'input_bytes': len(canonical.encode()), 'backlog_records': count, 'snapshot': result}, indent=2))
    print('Away cap, invalid-cap guard, publication refusal, local brief, and large snapshot passed.')
finally:
    (ev / 'public-cli-transcript.txt').write_text('\n'.join(lines))
    shutil.rmtree(lab)
