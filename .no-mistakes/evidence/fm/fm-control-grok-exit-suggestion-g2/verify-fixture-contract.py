import os, subprocess, pathlib, html, re
root=pathlib.Path.cwd()
ev=pathlib.Path('/home/zabi/.no-mistakes/evidence/01M6CE2V3S2K05SQ401JZWGCA9')
base=root/'.test-tmp/composer-base.sh'
base.write_bytes(subprocess.check_output(['git','show','f89b73c5457bea9d17ae26a91e6cc19c0c4ec88a:bin/fm-composer-lib.sh']))
esc='\x1b'
top='  ╭'+'─'*74+'╮'
bottom='  ╰'+'─'*58+' Grok 4.6 (xhigh) ─╯'
idle='  Shift+Tab:mode │ Ctrl+.:shortcuts'
suggest='  Tab/→:accept suggestion │ Shift+Tab:mode │ Ctrl+.:shortcuts'
send='  Enter:send │ Shift+Enter/Alt+Enter:newline │ Shift+Tab:mode │ Ctrl+.:shortcuts'
def screen(body,footer=idle,style='',bot=bottom,gap=False):
    raw=' '+(style+body+esc+'[0m' if style else body)
    row='  │ ❯'+raw+' '*(72-1-len(re.sub(r'\x1b\[[0-9;]*m', '', body)))+'│'
    return '\n'.join([top,row,bot]+([''] if gap else [])+[footer])
cases=[
 ('Reported placeholder, idle footer',screen('Build anything'),'empty'),
 ('Reported dim accepted suggestion, adjacent footer',screen(': Firstmate instruction waiting',suggest,esc+'[2m'),'empty'),
 ('Reported dark truecolor suggestion, adjacent footer',screen(': Firstmate instruction waiting',suggest,esc+'[38;2;90;90;90m'),'empty'),
 ('Bright doorbell on suggestion footer',screen(': Firstmate instruction waiting',suggest),'pending'),
 ('Typed exact placeholder with send hint',screen('Build anything',send),'pending'),
 ('Typed ordinary draft with idle footer',screen('deploy the fix'),'pending'),
 ('Typed prefix with dim completion',screen('deploy '+esc+'[2mthe fix'+esc+'[0m',suggest),'pending'),
 ('Misleading suggestion-only footer',screen('Build anything','  Tab/→:accept suggestion'),'unknown'),
 ('Misleading prose footer',screen('Build anything','see the accept suggestion │ docs'),'unknown'),
 ('Unrecognised oversized title, empty body',screen('',bot=bottom.replace('Grok 4.6 (xhigh)','Grok 9.9 (some-very-long-title)')),'unknown'),
 ('Mismatched bottom indent, empty body',screen('',bot=' '+bottom),'unknown'),
]
def classify(lib,capture):
    env=os.environ.copy();env['CAPTURE']=capture;env['LIB']=str(lib)
    return subprocess.check_output(['bash','-c','. "$LIB"; fm_composer_classify_screen "styled=1\ncursor=0\nidentity=1\nrows=40" "$CAPTURE"'],env=env,text=True).strip()
with (ev/'fixture-contract-transcript.txt').open('w') as log:
    log.write('Behavioral classifier checks on constructed reported-screen fixtures. NOT LIVE GROK CAPTURES.\nBase: f89b73c5457bea9d17ae26a91e6cc19c0c4ec88a; head: 6b3e02c4d9a66c657104ce5822be004a658e0c06\n\n')
    for name,capture,expected in cases:
        before=classify(base,capture);after=classify(root/'bin/fm-composer-lib.sh',capture)
        log.write(name+'\n'+repr(capture)+'\nbase='+before+' head='+after+' expected='+expected+'\n\n')
        assert after==expected,(name,after)
        if name.startswith('Reported'):assert before!=after,(name,before,after)
print((ev/'fixture-contract-transcript.txt').read_text())
# Render the actual live Herdr viewport, preserving bold and dim SGR styling.
raw=(ev/'grok-startup.ansi').read_text()
parts=re.split(r'(\x1b\[[0-9;]*m)',raw)
bold=False;dim=False;out=[]
for part in parts:
    if part.startswith(esc+'['):
        for code in (part[2:-1] or '0').split(';'):
            if code=='0':bold=False;dim=False
            elif code=='1':bold=True
            elif code=='2':dim=True
            elif code=='22':bold=False;dim=False
    else:
        style=('font-weight:bold;' if bold else '')+('opacity:.65;' if dim else '')
        out.append('<span style="'+style+'">'+html.escape(part)+'</span>')
(ev/'grok-trust-screen.html').write_text('<!doctype html><meta charset="utf-8"><title>Live Grok 1.0.46 folder-trust screen</title><style>body{background:#16181c;color:#eee;padding:20px}pre{font:14px/1.4 monospace;white-space:pre}</style><h2>Live Grok 1.0.46 in isolated Herdr lab</h2><p>Actual ANSI viewport captured before any trust answer. Lab teardown and default-session tripwire passed.</p><pre>'+''.join(out)+'</pre>')
