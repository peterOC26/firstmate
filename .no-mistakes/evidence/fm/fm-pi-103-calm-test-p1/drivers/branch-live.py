import os, sys, json, shutil, subprocess, time, pathlib, shlex, re
root=pathlib.Path.cwd(); version=sys.argv[1]; cli=sys.argv[2]
lab=root/'.test-live'/('branch-live-'+version); lab.mkdir()
project=lab/'project'; extension_dir=project/'.pi/extensions'; extension_dir.mkdir(parents=True)
shutil.copytree(root/'.pi/extensions/lib',extension_dir/'lib')
for name in ['fm-calm.ts','fm-branch-supervision.ts']: shutil.copy(root/'.pi/extensions'/name,extension_dir/name)
home=lab/'home'; (home/'config').mkdir(parents=True); (home/'state').mkdir()
agent=lab/'agent'; agent.mkdir(); (agent/'keybindings.json').write_text(json.dumps({'tui.input.submit':'alt+s'}))
(project/'AGENTS.md').write_text('')
evidence=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M45RE5DJ7B3MS5TT4S6FF568')/('branch-'+version); evidence.mkdir(exist_ok=True)
now='2026-10-05T12:00:00.000Z'; session=lab/'session.jsonl'
usage={'input':1,'output':1,'cacheRead':0,'cacheWrite':0,'totalTokens':2,'cost':dict.fromkeys(['input','output','cacheRead','cacheWrite','total'],0)}
rows=[{'type':'session','version':3,'id':'22222222-2222-4222-8222-222222222222','timestamp':now,'cwd':str(project)}]
def append(message):
    n=len(rows); rows.append({'type':'message','id':str(n),'parentId':str(n-1) if n>1 else None,'timestamp':now,'message':message})
def assistant(content,reason): return {'role':'assistant','content':content,'api':'anthropic-messages','provider':'anthropic','model':'claude-sonnet-4-5','usage':usage,'stopReason':reason,'timestamp':2}
append({'role':'user','content':[{'type':'text','text':'Show recent supervision outcomes.'}],'timestamp':1})
append(assistant([{'type':'toolCall','id':'branch-outcomes','name':'fm_branch_outcomes','arguments':{'recent':2}},{'type':'toolCall','id':'branch-processed','name':'fm_branch_processed','arguments':{'through':1}}],'toolUse'))
append({'role':'toolResult','toolCallId':'branch-outcomes','toolName':'fm_branch_outcomes','content':[{'type':'text','text':'LIVE_BRANCH_OUTCOME_ONE\nLIVE_BRANCH_OUTCOME_TWO'}],'details':{'ok':True},'isError':False,'timestamp':3})
append({'role':'toolResult','toolCallId':'branch-processed','toolName':'fm_branch_processed','content':[{'type':'text','text':'acknowledged through 1'}],'details':{},'isError':False,'timestamp':4})
append(assistant([{'type':'text','text':'Recent outcomes are ready.'}],'stop'))
session.write_text(''.join(json.dumps(r)+'\n' for r in rows))
socket='fm-lab-branch-'+version+'-'+str(os.getpid())
def tmux(*args): return subprocess.run(['tmux','-L',socket,*args],check=True,capture_output=True,text=True).stdout
def capture(): return tmux('capture-pane','-p','-t','branch','-S','-400')
def wait(text,filename):
    for _ in range(160):
        output=capture()
        if text in output:
            (evidence/filename).write_text(output); return output
        time.sleep(.05)
    (evidence/filename).write_text(output); raise RuntimeError('never saw '+text)
def command(text,key='M-s'):
    tmux('send-keys','-t','branch','-l',text); tmux('send-keys','-t','branch',key)
env=os.environ.copy(); env.update(FM_HOME=str(home),PI_CODING_AGENT_DIR=str(agent),PI_OFFLINE='1')
for k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']: env.pop(k,None)
args=[cli,'--approve','--no-skills','--no-prompt-templates','--no-context-files','--session',str(session)]
if version=='103': args.extend(['--tui-mode','regular'])
launch='cd '+shlex.quote(str(project))+' && '+shlex.join(['env',*[k+'='+env[k] for k in ['FM_HOME','PI_CODING_AGENT_DIR','PI_OFFLINE']],*args])
try:
    tmux('new-session','-d','-s','branch','-x','180','-y','44',launch)
    out=wait('Recent outcomes are ready.','stock.txt')
    assert 'LIVE_BRANCH_OUTCOME_ONE' in out and 'fm-branch-supervision.ts' in out, out
    command('/calm'); time.sleep(.5); out=capture(); (evidence/'calm.txt').write_text(out)
    assert (home/'config/calm').read_text().strip()=='on'
    assert 'LIVE_BRANCH_OUTCOME_ONE' not in out, out
    exported=lab/'branch-export.html'
    command('/export '+str(exported),'Enter'); time.sleep(.5)
    assert not exported.exists(), 'non-submit Enter exported despite Alt+S mapping'
    out=capture(); (evidence/'non-submit.txt').write_text(out)
    assert 'LIVE_BRANCH_OUTCOME_ONE' not in out, 'non-submit Enter disclosed hidden outcome'
    tmux('send-keys','-t','branch','M-s')
    wait('Session exported to:','export.txt')
    html=exported.read_text(); m=re.search(r'<script id="session-data" type="application/json">([^<]+)</script>',html)
    import base64
    data=json.loads(base64.b64decode(m.group(1)))
    for id in ['branch-outcomes','branch-processed']:
        assert not (data.get('renderedTools') or {}).get(id), data.get('renderedTools')
    assert 'LIVE_BRANCH_OUTCOME_ONE' in json.dumps(data) and 'acknowledged through 1' in json.dumps(data)
    shutil.copy(exported,evidence/'export.html')
    time.sleep(.5); out=capture(); (evidence/'after-export.txt').write_text(out)
    assert 'LIVE_BRANCH_OUTCOME_ONE' not in out, 'export did not restore Calm hiding'
    command('/calm'); out=wait('LIVE_BRANCH_OUTCOME_ONE','restored.txt')
    assert (home/'config/calm').read_text().strip()=='off'
    print('Pi '+version+': stock branch outputs visible; Calm hides; non-submit Enter neither exports nor reveals; Alt+S exports persisted outcomes with stock HTML fallback; Calm hiding restores; toggle off reveals outcomes.')
finally:
    subprocess.run(['tmux','-L',socket,'kill-server'],capture_output=True)
