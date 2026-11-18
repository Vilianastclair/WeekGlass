import { createServer } from 'node:http';
import { readFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';

// No school server or browser profile is used. Serve the archived DOM with a
// per-run CSP that blocks every original script, form, frame and linked asset.
// Only the shipped projection below is allowed to execute.
const root = dirname(dirname(dirname(fileURLToPath(import.meta.url))));
const js = await readFile(join(root,'apps/client/assets/school_portal/read_timetable.js'),'utf8');
const file = process.argv[2];
const name = JSON.stringify(basename(file));
const body = await readFile(file,'utf8');
const nonce=randomUUID();
let resolveRead;
const captured=new Promise(res=>{resolveRead=res;});
const server=createServer((req,res)=>{
  if(req.method==='POST' && req.url==='/result'){
    let text=''; req.setEncoding('utf8');req.on('data',s=>text+=s);
    req.on('end',()=>{res.writeHead(200).end();resolveRead(text);}); return;
  }
  if(req.url!=='/'){res.writeHead(404).end();return;}
  res.writeHead(200,{'Content-Type':'text/html;charset=utf-8','Content-Security-Policy':
    "default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-"+nonce+"'; connect-src 'self'; base-uri 'none'; form-action 'none'"});
  res.end(body+'<script nonce="'+nonce+'">addEventListener("load",async()=>{try{const result=('+js+')(location.origin); await fetch("/result",{method:"POST",body:result})}catch(e){await fetch("/result",{method:"POST",body:JSON.stringify({error:String(e)})})}})</script>');
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const profile=await mkdtemp(join(tmpdir(),'wg-school-dom-'));
const chromium=process.env.WG_TEST_BROWSER || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const child=spawn(chromium,['--headless','--disable-gpu','--disable-extensions','--no-proxy-server','--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1','--disable-background-networking','--no-first-run','--user-data-dir='+profile,'http://127.0.0.1:'+server.address().port+'/'],{windowsHide:true,stdio:'ignore'});
const exited=new Promise((ok,no)=>{child.once('error',no);child.once('exit',ok);});
let timeout;
try{
  const data=await Promise.race([captured,exited.then(()=>{throw Error('Browser exited before reading '+name);}),
    new Promise((_,r)=>{timeout=setTimeout(()=>r(Error('Browser did not read '+name)),15000);})]);
  JSON.parse(data);process.stdout.write(data);
} finally {
  clearTimeout(timeout);server.closeAllConnections();server.close();
  if(child.pid && child.exitCode===null)child.kill();
  await exited.catch(()=>{});
  if(dirname(resolve(profile))===resolve(tmpdir())&&basename(profile).startsWith('wg-school-dom-')){
    await rm(profile,{recursive:true,force:true,maxRetries:6,retryDelay:200}).catch(()=>{});
  }
}
