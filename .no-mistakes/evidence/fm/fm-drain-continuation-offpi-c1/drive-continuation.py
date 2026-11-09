import os, pathlib, subprocess, tempfile, json, re, hashlib
ROOT = pathlib.Path('/home/zabi/.no-mistakes/worktrees/7f0ec18181b6/01M70GTNYFBFR3KQHVN2KVHAEZ')
EVIDENCE = pathlib.Path('/home/zabi/.no-mistakes/evidence/01M70GTNYFBFR3KQHVN2KVHAEZ')
log = (EVIDENCE / 'continuation-cli-transcript.txt').open('w')
env = os.environ.copy()
for key in list(env):
    if key.startswith('FM_') or key in ('STATE', 'HERDR_ENV', 'HERDR_SESSION', 'HERDR_SOCKET_PATH'):
        env.pop(key)

def run(home, script, *args):
    local = dict(env, FM_HOME=str(home))
    command = ['bash', str(ROOT / 'bin' / script), *args]
    display = ' '.join([script, *[a if len(a) < 240 else f'<{len(a.encode())} UTF-8 bytes>' for a in args]])
    result = subprocess.run(command, cwd=ROOT, env=local, text=True, capture_output=True, timeout=30)
    log.write(f'\n$ FM_HOME=<disposable lab> bash bin/{display}\n{result.stdout}{result.stderr}[exit {result.returncode}]\n')
    log.flush()
    assert result.returncode == 0, (display, result.stdout, result.stderr)
    return result.stdout

def append(home, task, summary, continuation=None, verdict='captain', silent=False):
    args = ['append', '--task', task, '--verdict', verdict, '--summary', summary]
    if continuation is not None: args += ['--continuation', continuation]
    if silent: args += ['--silent', 'true']
    return int(run(home, 'fm-branch-outcome.sh', *args).strip())

def drain(home):
    return run(home, 'fm-wake-drain.sh')

def ack(home, n):
    return run(home, 'fm-branch-outcome.sh', 'mark-processed', '--through', str(n))

def lines(output):
    return [x for x in output.splitlines() if x.startswith('[seq ')]

def stored(home, name):
    path = home / 'state' / name
    return path.read_text().strip() if path.exists() else None

results=[]
with tempfile.TemporaryDirectory(prefix='fm-lab.', dir=ROOT) as parent:
    parent = pathlib.Path(parent)
    def home(name):
        h=parent/name
        run(h, 'fm-lab-home.sh', 'create', str(h))
        (h/'config'/'supervision-host').touch()
        return h

    h=home('mixed')
    detected=run(h,'fm-harness.sh').strip()
    assert detected not in ('pi','pi-signed','unknown'), detected
    log.write(f'Actual current harness detected without test seams: {detected}\n')
    continuation='Implementation complete.\nStart\tthe authorized validation;\rthen report its result.'
    append(h,'gamma','implementation complete',continuation)
    # Use the public read interface as a prior presenter would. No processing acknowledgement.
    run(h,'fm-branch-outcome.sh','mark-read','--through','1')
    append(h,'gamma','older CI note')
    append(h,'gamma','second stage complete','Start authorized stage two.')
    append(h,'gamma','newest CI note')
    append(h,'legacy','needs a decision')
    append(h,'routine','still working',verdict='routine')
    append(h,'silent','unchanged',verdict='routine',silent=True)
    digest=hashlib.sha256((h/'state'/'branch-outcomes.jsonl').read_bytes()).hexdigest()
    first=drain(h)
    for seq in (1,3,4,5): assert any(x.startswith(f'[seq {seq},') for x in lines(first))
    assert 'MAIN continuation handoff: Implementation complete. Start the authorized validation; then report its result.' in first
    assert 'MAIN continuation handoff: Start authorized stage two.' in first
    assert 'gamma: newest CI note' in first and 'gamma: older CI note' not in first
    assert 'newest of 2 for this task' in first
    assert 'legacy: needs a decision' in first
    assert 'routine: still working' in first and 'silent: unchanged' not in first
    assert 'mark-processed --through 5;' in first
    assert stored(h,'.branch-outcomes-processed') is None
    second=drain(h)
    for seq in (1,3,4,5): assert any(x.startswith(f'[seq {seq},') for x in lines(second))
    assert 'BRANCH OUTCOMES, ROUTINE' not in second
    duty=[
        'reconcile current task/stage state and existing authority',
        'start the authorized spawn, steer, or handoff before acknowledging',
        'if already started, do not duplicate it',
        'Record the actual blocker, decision, or evidence that no further action is needed',
        'read the full outcome using its lookup --seqs command before acting or acknowledging',
        'a settled one without a pending continuation needs only the acknowledgement',
    ]
    for instruction in duty: assert instruction in first
    # This driver validates the emitted processing contract, not LLM interpretation or a real spawn.
    ack(h,5)
    after=drain(h)
    assert 'BRANCH OUTCOMES' not in after
    assert stored(h,'.branch-outcomes-processed') == '5'
    assert hashlib.sha256((h/'state'/'branch-outcomes.jsonl').read_bytes()).hexdigest()==digest
    log.write('Persisted state: processed=5; immutable outcome-log digest preserved; next drain has no outcomes.\n')
    results += ['older and newer continuations survive plain-row collapse and repeat until acknowledged',
                'emitted processing contract requires reconciliation, authorized action, duplicate prevention and blocker/no-action evidence',
                'legacy rows and visible/silent routine presentation remain compatible']

    h=home('bounded')
    padding='界'*700
    expected={}
    for n in range(1,9):
        expected[n]=padding+f' Start authorized step {n}.'
        append(h,'gamma','stage complete' if n%2 else padding,expected[n])
    append(h,'gamma','later CI note')
    first=drain(h)
    rowlines=lines(first)
    assert len(rowlines)==6
    sizes=[len((x+'\n').encode('utf-8')) for x in rowlines]
    assert max(sizes)<=600 and sum(sizes)<=4000
    assert '3 newer captain outcome(s) are held back' in first
    assert 'mark-processed --through 6;' in first
    assert not any(x.startswith('[seq 7,') or x.startswith('[seq 8,') or x.startswith('[seq 9,') for x in rowlines)
    for n,line in enumerate(rowlines,1):
        match=re.search(r'full MAIN continuation handoff: (bin/fm-branch-outcome.sh lookup --seqs (\d+))$',line)
        assert match and int(match[2])==n
        full=json.loads(run(h,'fm-branch-outcome.sh','lookup','--seqs',str(n)))
        assert full['continuation']==expected[n]
    assert stored(h,'.branch-outcomes-processed') is None
    again=drain(h)
    assert lines(again)==rowlines
    ack(h,6)
    unprocessed=[json.loads(x)['seq'] for x in run(h,'fm-branch-outcome.sh','unprocessed').splitlines()]
    assert unprocessed==[7,8,9]
    second=drain(h)
    assert len(lines(second))==3
    for n in (7,8):
        assert f'lookup --seqs {n}' in second
        full=json.loads(run(h,'fm-branch-outcome.sh','lookup','--seqs',str(n)))
        assert full['continuation']==expected[n]
    assert 'later CI note' in second and 'mark-processed --through 9;' in second
    ack(h,9)
    assert 'BRANCH OUTCOMES' not in drain(h)
    log.write(f'Observed UTF-8 row byte lengths including newline: {sizes}; total={sum(sizes)}; after first acknowledgement unprocessed seqs={unprocessed}; final processed=9.\n')
    results.append('UTF-8 handoffs keep executable full-outcome lookups and contiguous bounded acknowledgement')

    h=home('opt-out')
    append(h,'gamma','pending handoff','Start authorized validation.')
    (h/'config'/'supervision-host-off').touch()
    assert 'BRANCH OUTCOMES' not in drain(h)
    assert stored(h,'.branch-outcomes-cursor') is None
    (h/'config'/'supervision-host-off').unlink()
    output=drain(h)
    assert 'MAIN continuation handoff: Start authorized validation.' in output
    ack(h,1)
    results.append('host opt-out leaves the handoff unread for later presentation')
log.write('\nAll disposable lab directories removed on exit.\n')
log.close()
(EVIDENCE/'continuation-scenario-results.json').write_text(json.dumps({'harness':detected,'live_cli_scenarios':results},indent=2)+'\n')
print(json.dumps({'harness':detected,'results':results,'transcript':str(EVIDENCE/'continuation-cli-transcript.txt')},indent=2))
