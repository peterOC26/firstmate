import { spawn } from 'node:child_process';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
const [html, out, profile, marker] = process.argv.slice(2);
await mkdir(profile, {recursive:true});
const browser=spawn('/usr/bin/chromium',['--headless','--no-sandbox','--disable-dev-shm-usage','--remote-debugging-port=0',`--user-data-dir=${profile}`,'about:blank'],{env:{...process.env,TMPDIR:'/tmp'},stdio:['ignore','ignore','pipe']});
let err=''; browser.stderr.on('data',d=>{err+=d});
let ws;
try {
  let port;
  for(let i=0;i<100;i++) { try {port=(await readFile(`${profile}/DevToolsActivePort`,'utf8')).split('\n')[0];break} catch{} await new Promise(r=>setTimeout(r,50)); }
  if(!port) throw Error('Chromium did not open remote debugging: '+err);
  const pages=await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  ws=new WebSocket(pages.find(p=>p.type==='page').webSocketDebuggerUrl);
  await new Promise((resolve,reject)=>{ws.addEventListener('open',resolve,{once:true});ws.addEventListener('error',reject,{once:true})});
  let id=0; const pending=new Map();
  ws.addEventListener('message',e=>{const m=JSON.parse(e.data); if(pending.has(m.id)){const [resolve,reject]=pending.get(m.id);pending.delete(m.id);m.error?reject(Error(JSON.stringify(m.error))):resolve(m.result)}});
  const send=(method,params={})=>new Promise((resolve,reject)=>{const i=++id;pending.set(i,[resolve,reject]);ws.send(JSON.stringify({id:i,method,params}))});
  await send('Emulation.setDeviceMetricsOverride',{width:1440,height:1100,deviceScaleFactor:1,mobile:false});
  await send('Page.navigate',{url:pathToFileURL(html).href});
  const expression=`(()=>{const root=document.querySelector('#messages'); if(!root) return null; const marker=${JSON.stringify(marker)}; const candidates=[...root.querySelectorAll('*')].filter(e=>e.textContent.includes(marker)&&e.getBoundingClientRect().height>0&&getComputedStyle(e).display!=='none'); const el=candidates.reverse().find(e=>![...e.children].some(c=>c.textContent.includes(marker)&&c.getBoundingClientRect().height>0)); if(!el) return null; el.scrollIntoView({block:'center'}); return {marker,text:el.textContent,tools:[...root.querySelectorAll('*')].filter(e=>['grep','find','fm_branch_outcomes'].some(s=>e.textContent.trim()===s)).map(e=>e.textContent)};})()`;
  let visible;
  for(let i=0;i<100;i++){const r=await send('Runtime.evaluate',{expression,returnByValue:true});visible=r.result.value;if(visible)break;await new Promise(r=>setTimeout(r,50))}
  if(!visible)throw Error('marker not visibly rendered in exported conversation: '+marker);
  await new Promise(r=>setTimeout(r,100));
  const shot=await send('Page.captureScreenshot',{format:'png',captureBeyondViewport:false});
  await writeFile(out,Buffer.from(shot.data,'base64'));
  console.log(JSON.stringify({html,screenshot:out,visible}));
} finally {if(ws)ws.close();browser.kill('SIGTERM');await new Promise(r=>browser.once('exit',r));}
