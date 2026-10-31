import json, os, pathlib, signal, subprocess, sys
home = pathlib.Path(os.environ['CODEX_HOME'])
home.mkdir()
(home / 'config.toml').write_text('service_tier = "fast"\n')
def timeout(sig, frame):
    raise TimeoutError('config/read exceeded 20 seconds')
signal.signal(signal.SIGALRM, timeout)
def read_config(flags):
    signal.alarm(20)
    process = subprocess.Popen(['codex', '--no-daemon', *flags, 'app-server'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    try:
        for request in [
            {'id': 1, 'method': 'initialize', 'params': {'clientInfo': {'name': 'firstmate-live-tier-proof', 'version': '1'}}},
            {'id': 2, 'method': 'config/read', 'params': {'includeLayers': False}}
        ]:
            process.stdin.write(json.dumps(request) + '\n')
            process.stdin.flush()
            while True:
                line = process.stdout.readline()
                if not line:
                    raise RuntimeError('Codex closed before returning config')
                message = json.loads(line)
                if message.get('id') == request['id']:
                    break
            if 'error' in message:
                raise RuntimeError(message['error'])
        return message['result']['config']['service_tier']
    finally:
        signal.alarm(0)
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
records = json.load(open(sys.argv[1]))
result = {'codex_version': subprocess.check_output(['codex', '--version'], text=True).strip(), 'baseline': read_config([]), 'launches': []}
assert result['baseline'] == 'fast', result
for record in records:
    args = record['argv']
    # Native executable only; exclude the npm shim duplicate.
    if os.path.basename(args[0]) != 'codex':
        continue
    flags = args[1:-1]
    kind = 'worker' if '--disable' in flags else 'secondmate'
    tier = read_config(flags)
    assert tier == 'default', (kind, tier)
    result['launches'].append({'kind': kind, 'pid': record['pid'], 'actual_process_flags': flags, 'config_read_service_tier': tier})
assert {r['kind'] for r in result['launches']} == {'worker', 'secondmate'}, result
assert len([r for r in result['launches'] if r['kind'] == 'worker']) == 2, result
print(json.dumps(result, indent=2))
