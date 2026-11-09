import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile

ROOT = Path.cwd()
EVIDENCE = Path('/home/zabi/.no-mistakes/evidence/01M70A73E7BQY1C7RSTDRA7MAN')
base_env = {k: v for k, v in os.environ.items() if not k.startswith('FM_') and k not in {'STATE', 'CONFIG', 'TMUX', 'HERDR_ENV', 'HERDR_SESSION', 'HERDR_PANE_ID', 'HERDR_SOCKET_PATH', 'REX_SESSION', 'REX_BLOCK'}}
results = []

class Lab:
    def __init__(self, label):
        self.label = label
        self.home = Path(tempfile.mkdtemp(prefix='.fm-lab-', dir=ROOT))
        self.env = dict(base_env, FM_HOME=str(self.home))
        self.log = (EVIDENCE / (label + '.log')).open('w')
        self.run('bin/fm-lab-home.sh', 'create', str(self.home))
        (self.home / 'config/supervision-host').touch()
        harness = self.run('bin/fm-harness.sh')
        assert harness.strip() == 'codex', harness
        self.log.write('Real executable interfaces; actual Codex ancestry; no test seams or tool stubs.\n')
    def run(self, *args, expected=0):
        self.log.write('\n$ FM_HOME=<disposable-lab> ' + shlex.join(args) + '\n')
        proc = subprocess.run(args, cwd=ROOT, env=self.env, text=True, capture_output=True, timeout=45)
        self.log.write(proc.stdout)
        if proc.stderr:
            self.log.write('[stderr]\n' + proc.stderr)
        self.log.write('[exit %d]\n' % proc.returncode)
        self.log.flush()
        assert proc.returncode == expected, (args, proc.returncode, proc.stderr)
        return proc.stdout
    def append(self, task, summary, continuation=None, verdict='captain', silent=None):
        args = ['bin/fm-branch-outcome.sh', 'append', '--task', task, '--verdict', verdict, '--summary', summary]
        if continuation is not None:
            args += ['--continuation', continuation]
        if silent is not None:
            args += ['--silent', silent]
        return self.run(*args)
    def drain(self):
        return self.run('bin/fm-wake-drain.sh')
    def close(self):
        shutil.rmtree(self.home)
        self.log.write('\nDisposable lab removed. No fleet sessions were launched or accessed.\n')
        self.log.close()

lab = Lab('retained-handoffs')
try:
    lab.append('gamma', 'Implementation complete', 'Stage complete.\nStart\tthe authorized validation;\rthen report its result.')
    # Exercise the supported read/processed split: an already delivered row remains pending.
    lab.run('bin/fm-branch-outcome.sh', 'mark-read', '--through', '1')
    lab.append('gamma', 'CI note 1')
    lab.append('gamma', 'Validation complete', 'Hand the validation report to the assigned worker.')
    lab.append('gamma', 'CI note 2')
    lab.append('legacy', 'Needs a decision')
    lab.append('routine', 'Still working', verdict='routine')
    lab.append('silent', 'No change', verdict='routine', silent='true')
    before = hashlib.sha256((lab.home / 'state/branch-outcomes.jsonl').read_bytes()).hexdigest()
    first = lab.drain()
    for fragment in ('[seq 1,', '[seq 3,', 'MAIN continuation handoff: Stage complete. Start the authorized validation; then report its result.', 'MAIN continuation handoff: Hand the validation report to the assigned worker.', 'gamma: CI note 2', 'newest of 2 for this task', 'legacy: Needs a decision', 'routine: Still working', 'mark-processed --through 5;'):
        assert fragment in first, fragment
    assert 'gamma: CI note 1' not in first
    assert 'silent: No change' not in first
    second = lab.drain()
    assert 'routine: Still working' not in second
    for fragment in ('[seq 1,', '[seq 3,', 'gamma: CI note 2', 'legacy: Needs a decision'):
        assert fragment in second, fragment
    instructions = first.split('\n', 1)[0]
    for fragment in ('reconcile current task/stage state and existing authority', 'start the authorized spawn, steer, or handoff before acknowledging', 'if already started, do not duplicate it', 'Record the actual blocker, decision, or evidence that no further action is needed', 'read the full outcome using its lookup --seqs command before acting or acknowledging'):
        assert fragment in first, fragment
    (EVIDENCE / 'delivered-processing-instructions.txt').write_text(next(line for line in first.splitlines() if line.startswith('BRANCH OUTCOMES (')) + '\n')
    lab.run('bin/fm-branch-outcome.sh', 'mark-processed', '--through', '5')
    assert 'BRANCH OUTCOMES' not in lab.drain()
    assert hashlib.sha256((lab.home / 'state/branch-outcomes.jsonl').read_bytes()).hexdigest() == before
    results += ['retained-handoffs: pass', 'delivered-processing-instructions: pass', 'legacy-and-routine-compatibility: pass']
finally:
    lab.close()

lab = Lab('bounded-handoffs')
try:
    pad = '界' * 700
    continuations = {}
    for n in range(1, 9):
        continuations[n] = pad + f' Start authorized step {n}.'
        lab.append('gamma', 'Stage complete' if n % 2 else pad, continuations[n])
    lab.append('gamma', 'Later CI note')
    out = lab.drain()
    lines = [line for line in out.splitlines() if line.startswith('[seq ')]
    assert len(lines) == 6, len(lines)
    assert sum(len((line + '\n').encode()) for line in lines) <= 4000
    for n, line in enumerate(lines, 1):
        assert line.startswith(f'[seq {n},'), line
        assert len((line + '\n').encode()) <= 600
        assert '[truncated]' in line
        lookup = line.split('; full MAIN continuation handoff: ')[1]
        assert shlex.split(lookup) == ['bin/fm-branch-outcome.sh', 'lookup', '--seqs', str(n)]
        full = json.loads(lab.run(*shlex.split(lookup)))
        assert full['continuation'] == continuations[n]
    assert '3 newer captain outcome(s) are held back' in out
    assert 'mark-processed --through 6;' in out
    assert 'Later CI note' not in out
    lab.run('bin/fm-branch-outcome.sh', 'mark-processed', '--through', '6')
    pending = [json.loads(line) for line in lab.run('bin/fm-branch-outcome.sh', 'unprocessed').splitlines()]
    assert [row['seq'] for row in pending] == [7, 8, 9]
    rest = lab.drain()
    for fragment in ('lookup --seqs 7', 'lookup --seqs 8', 'Later CI note', 'mark-processed --through 9;'):
        assert fragment in rest, fragment
    lab.run('bin/fm-branch-outcome.sh', 'mark-processed', '--through', '9')
    assert 'BRANCH OUTCOMES' not in lab.drain()
    lab.log.write('\nObserved row bytes including newline: ' + repr([len((line + '\n').encode()) for line in lines]) + '\n')
    results += ['bounded-handoffs-and-full-lookups: pass']
finally:
    lab.close()

lab = Lab('host-opt-out')
try:
    lab.append('gamma', 'Stage complete', 'Start authorized validation.')
    (lab.home / 'config/supervision-host-off').touch()
    assert 'BRANCH OUTCOMES' not in lab.drain()
    assert not (lab.home / 'state/.branch-outcomes-cursor').exists()
    assert not (lab.home / 'state/.branch-outcomes-processed').exists()
    (lab.home / 'config/supervision-host-off').unlink()
    assert 'MAIN continuation handoff: Start authorized validation.' in lab.drain()
    assert not (lab.home / 'state/.branch-outcomes-processed').exists()
    lab.run('bin/fm-branch-outcome.sh', 'mark-processed', '--through', '1')
    assert 'BRANCH OUTCOMES' not in lab.drain()
    results += ['host-opt-out-preserves-pending-handoff: pass']
finally:
    lab.close()

(EVIDENCE / 'live-results.json').write_text(json.dumps(results, indent=2) + '\n')
print('\n'.join(results))
