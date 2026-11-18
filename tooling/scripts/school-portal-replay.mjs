// Isolated browser transport for Flutter integration tests. stdin/stdout carry
// only local test commands, never an exposed debugging socket or browser profile.
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {createInterface} from 'node:readline';
import {readFile,mkdtemp,rm} from 'node:fs/promises';
import {dirname,basename,join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
const source=await readFile(process.argv[2]);
const server=createServer((req,res)=>{
  if(req.url!=='/' || req.method!=='GET'){res.writeHead(404).end();return;}
  res.writeHead(200,{'Content-Type':'text/html;charset=utf-8','Content-Security-Policy':"default-src 'none'; style-src 'unsafe-inline'; form-action 'none'; base-uri 'none'"}).end(source);
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const url='http://127.0.0.1:'+server.address().port+'/';
const profile=await mkdtemp(join(tmpdir(),'wg-school-replay-'));
const exe=process.env.WG_TEST_BROWSER||'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const chrome=spawn(exe,['--headless','--disable-gpu','--disable-extensions','--no-proxy-server','--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1','--disable-background-networking','--no-first-run','--disable-component-update','--remote-debugging-pipe','--user-data-dir='+profile],{stdio:['ignore','ignore','ignore','pipe','pipe'],windowsHide:true});
const exited=new Promise(r=>{chrome.once('exit',r);chrome.once('error',r);});
const send=value=>process.stdout.write(JSON.stringify(value)+'\n');
const inflight=new Map();let serial=0,buffer='',sessionId;
chrome.stdio[4].setEncoding('utf8');
chrome.stdio[4].on('data',part=>{
  buffer+=part; let end;
  while((end=buffer.indexOf('\0'))>=0){
    const msg=JSON.parse(buffer.slice(0,end));buffer=buffer.slice(end+1);
    const done=inflight.get(msg.id);if(!done)continue;
    inflight.delete(msg.id);done(msg);
  }
});
async function call(method,params={},session=sessionId){
  const id=++serial;
  const response=new Promise((r,j)=>{
    const timeout=setTimeout(()=>{inflight.delete(id);j(Error('Chromium timeout: '+method));},12000);
    inflight.set(id,msg=>{clearTimeout(timeout);msg.error?j(Error(msg.error.message)):r(msg.result);});
  });
  chrome.stdio[3].write(JSON.stringify({id,method,params,sessionId:session})+'\0');
  return response;
}
async function evaluate(expression){
  const r=await call('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:false});
  if(r.exceptionDetails)throw Error('Page script failed');
  return r.result.value??null;
}
try{
  const {targetId}=await call('Target.createTarget',{url:'about:blank'});
  ({sessionId}=await call('Target.attachToTarget',{targetId,flatten:true}));
  await call('Page.navigate',{url});
  const deadline=Date.now()+8000;
  while(!await evaluate('location.href==='+JSON.stringify(url)+' && document.readyState==="complete"')){
    if(Date.now()>deadline)throw Error('Browser did not load saved page');
    await new Promise(r=>setTimeout(r,25));
  }
  send({url});
  for await(const line of createInterface({input:process.stdin,crlfDelay:Infinity})) {
    try{send({value:await evaluate(JSON.parse(line))});}catch{send({error:'Could not execute page read'});}
  }
} finally{
  if(chrome.pid && chrome.exitCode===null)chrome.kill();
  await exited;
  server.closeAllConnections();server.close();
  if(dirname(resolve(profile))===resolve(tmpdir()) && basename(profile).startsWith('wg-school-replay-')){
    await rm(profile,{recursive:true,force:true,maxRetries:6,retryDelay:200}).catch(()=>{});
  }
}
