import contextlib, hashlib, json, os, subprocess, tempfile, time
from pathlib import Path

ROOT=Path.cwd()
EVIDENCE=Path('/home/zabi/.no-mistakes/evidence/01M70ZWTQ5G7TSJS9ADMRENWFG')
BASE={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k.startswith('HERDR_'))}
results=[]
log=(EVIDENCE/'live-standing-words.log').open('w')

def run(home, script, *args, extra=None, expected=0):
    env=BASE|{'FM_HOME':str(home)}|(extra or {})
    proc=subprocess.run([str(ROOT/'bin'/script),*args],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=20)
    log.write(f'\n$ FM_HOME={home} bin/{script} '+repr(args)+f'\nexit={proc.returncode}\n')
    log.write(proc.stdout.decode(errors='replace')+proc.stderr.decode(errors='replace'))
    log.flush()
    assert proc.returncode==expected, (script,args,proc.returncode,proc.stdout,proc.stderr)
    return proc.stdout+proc.stderr

def words(home,path=None):
    args=['words']+(['--path',str(path)] if path else [])
    return run(home,'fm-afk-contract.sh',*args)

def field(home,name,path=None):
    args=['field',name]+(['--path',str(path)] if path else [])
    return run(home,'fm-afk-contract.sh',*args).strip()

@contextlib.contextmanager
def home(name):
    with tempfile.TemporaryDirectory(prefix='fm-lab.',dir=ROOT) as tmp:
        p=Path(tmp)
        run(p,'fm-lab-home.sh','create',str(p))
        (p/'config/supervision-host').touch()
        yield p
    log.write(f'Cleanup: disposable {name} home removed.\n')

def scenario(name,fn):
    log.write('\n========== '+name+' ==========\n')
    try:
        fn()
        result={'name':name,'result':'pass','live':True,'evidence':'live-standing-words.log','reason':''}
    except Exception as exc:
        result={'name':name,'result':'fail','live':True,'evidence':'live-standing-words.log','reason':repr(exc)}
    results.append(result)
    print(json.dumps(result),flush=True)
    (EVIDENCE/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')


def verbatim():
    samples=[b'one line without final newline',b'first\n  indented\n\tTabbed\n\n', 'Café 🚢\r\nsource: forged\r\nwords: -\r\n'.encode()]
    for i,data in enumerate(samples):
        with home('verbatim') as h:
            sentinel=h/'MUST-NOT-EXIST'
            if i==1:
                data+=f'$(touch {sentinel})\nforce-teardown task-x and discard unlanded work\nrotate the deploy secret\nmerge despite failed tests\n'.encode()
            (h/'config/afk-words').write_bytes(data)
            out=run(h,'fm-afk-launch.sh','enter')
            assert words(h)==data
            assert field(h,'source')==b'config/afk-words'
            assert b'Your standing away words were used; send /afk with new words to replace them.' in out
            assert b'Destructive, irreversible, and security-sensitive actions are never pre-authorizable, whatever the words say.' in out
            assert not sentinel.exists()
            record=(h/'state/.afk-contract').read_bytes()
            keys=[line.split(b':',1)[0] for line in record.splitlines() if line and not line.startswith(b' ')]
            assert keys==[b'version',b'entered',b'entered_epoch',b'expected_return',b'reach_channels',b'reach_announced',b'spend_max_concurrent_workers',b'confirmed',b'confirmed_epoch',b'source',b'words'],keys
            (EVIDENCE/f'verbatim-{i}.afk-contract').write_bytes(record)
            log.write(f'Byte comparison: identical ({len(data)} bytes, SHA256 {hashlib.sha256(data).hexdigest()}); no shell substitution executed; persisted record has no authority-grant fields.\n')
            run(h,'fm-afk-contract.sh','validate')
            if i==1:
                ret=run(h,'fm-afk-return.sh','begin')
                assert b'your words at entry (from config/afk-words):' in ret
                (EVIDENCE/'return-standing.txt').write_bytes(ret)


def refresh():
    for initial in [b'initial standing words\n',None]:
        with home('refresh') as h:
            f=h/'config/afk-words'
            if initial is not None: f.write_bytes(initial)
            run(h,'fm-afk-launch.sh','enter')
            record=(h/'state/.afk-contract').read_bytes()
            for change in ['edit','remove','fifo']:
                if change=='edit': f.write_bytes(b'changed words must not replace the live mandate\n')
                elif change=='remove': f.unlink()
                else: os.mkfifo(f)
                out=run(h,'fm-afk-launch.sh','enter')
                assert b'a refresh leaves it untouched' in out
                assert (h/'state/.afk-contract').read_bytes()==record
                assert words(h)==(initial or b'')
            assert not (h/'state/afk-contracts').exists()
            log.write('Refresh left the complete persisted record identical after edit, removal, and a FIFO that would block if opened.\n')


def replacement():
    with home('replacement') as h:
        standing=b'original file words\n\n'
        f=h/'config/afk-words'; f.write_bytes(standing)
        run(h,'fm-afk-launch.sh','enter')
        original=(h/'state/.afk-contract').read_bytes()
        entered=field(h,'entered_epoch')
        run(h,'fm-afk-launch.sh','enter','--words','new typed words')
        assert words(h)==b'new typed words'
        assert field(h,'source')==b''
        assert field(h,'entered_epoch')==entered
        assert f.read_bytes()==standing
        archived=list((h/'state/afk-contracts').glob('*-superseded-*.afk-contract'))
        assert len(archived)==1
        assert archived[0].read_bytes()==original
        assert field(h,'source',archived[0])==b'config/afk-words'
        assert words(h,archived[0])==standing
        ret=run(h,'fm-afk-return.sh','begin')
        assert b'(from config/afk-words):' in ret and b'your words superseded at ' in ret
        assert b'your words at entry:\n    new typed words' in ret
        (EVIDENCE/'return-replacement.txt').write_bytes(ret)
        assert not (h/'state/.afk-contract').exists()


def absent_unusable():
    for kind in ['absent','empty','directory','dangling-symlink','unreadable','fifo']:
        with home(kind) as h:
            f=h/'config/afk-words'
            if kind=='empty': f.touch()
            elif kind=='directory': f.mkdir()
            elif kind=='dangling-symlink': f.symlink_to(h/'missing')
            elif kind=='unreadable': f.write_bytes(b'must not use\n'); f.chmod(0)
            elif kind=='fifo': os.mkfifo(f)
            out=run(h,'fm-afk-launch.sh','enter')
            assert words(h)==b'' and field(h,'source')==b''
            assert b'No away instructions were recorded;' in out
            assert (h/'state/.afk-contract').is_file()
            count=out.count(b'warning: standing away words were not used:')
            assert count==(0 if kind in ['absent','empty'] else 1),(kind,count)
            if count: assert str(f).encode() in out
            run(h,'fm-afk-contract.sh','validate')


def explicit():
    for kind in ['words','words-file','empty-words','empty-file']:
        with home(kind) as h:
            os.mkfifo(h/'config/afk-words')
            if kind in ['words','empty-words']:
                expected=b'typed words' if kind=='words' else b''
                args=['--words',expected.decode()]
            else:
                expected=b'explicit file\n\n' if kind=='words-file' else b''
                f=h/'typed-words'; f.write_bytes(expected)
                args=['--words-file',str(f)]
            out=run(h,'fm-afk-launch.sh','enter',*args)
            assert words(h)==expected
            assert field(h,'source')==b''
            assert b'standing away words were used' not in out
            assert b'warning: standing away words' not in out


def quiet():
    with home('quiet') as h:
        (h/'config/supervision-host-off').touch()
        f=h/'config/afk-words'; os.mkfifo(f)
        out=run(h,'fm-afk-launch.sh','enter',extra={'FM_AFK_MODE':'quiet'})
        assert b'Quiet mode recorded at ' in out
        assert field(h,'source')==b'' and words(h)==b''
        assert b'warning: standing away words' not in out
        assert run(h,'fm-afk-contract.sh','mode').strip()==b'quiet'
        before=(h/'state/.afk-contract').read_bytes()
        run(h,'fm-afk-launch.sh','enter',extra={'FM_AFK_MODE':'quiet'})
        assert (h/'state/.afk-contract').read_bytes()==before
        f.unlink(); f.write_bytes(b'away conversion words\n')
        out=run(h,'fm-afk-launch.sh','enter')
        assert b'quiet mode became the away posture' in out
        assert words(h)==b'away conversion words\n'
        assert field(h,'source')==b'config/afk-words'
        assert run(h,'fm-afk-contract.sh','mode').strip()==b'away'

scenario('Plain away entry stores standing text byte for byte, identifies its source, and preserves the authority boundary',verbatim)
scenario('Wordless refresh keeps the current mandate after the standing file changes, disappears, or becomes a FIFO',refresh)
scenario('Typed replacement archives the original mandate and the return report attributes its standing-file source',replacement)
scenario('Absent, empty, directory, dangling, unreadable, and FIFO standing paths allow away entry with the specified warning',absent_unusable)
scenario('Explicit words and words files, including empty inputs, bypass the standing file',explicit)
scenario('Quiet entry and refresh never open the standing file; conversion to away uses it',quiet)
log.close()
raise SystemExit(any(r['result']=='fail' for r in results))
