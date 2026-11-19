(async (origin, root, term) => {
  if (location.origin !== origin || location.pathname !== root+'/*default/index.do') return {error:'origin'};
  const here=location.href;
  const isLogin=()=>/(?:^|[?&#])(?:ticket|code|(?:access|id)_token|SAMLResponse|SAMLRequest)=/i.test(location.search+location.hash) ||
    document.querySelector('input[type=password],input[autocomplete="one-time-code"]');
  if(isLogin()) return {error:'login'};
  const headers={Accept:'application/json','X-Requested-With':'XMLHttpRequest'};
  const jlu=origin==='https://iedu.jlu.edu.cn', heu=origin==='https://jwgl.hrbeu.edu.cn';
  const fail=code=>{throw new Error(code);};
  let bytes=0;
  async function read(module, action, changes=false) {
    if(location.href!==here||isLogin()) fail('origin');
    const endpoint=root+'/modules/'+module+'/'+action+'.do';
    const body=new URLSearchParams({XNXQDM:term});
    if(changes) body.set('*order','-SQSJ');
    const response=await fetch(endpoint,{method:'POST',mode:'same-origin',credentials:'same-origin',redirect:'error',
      signal:AbortSignal.timeout(8000),headers,body});
    if(!response.ok || response.url!==origin+endpoint || !/\bjson\b/i.test(response.headers.get('Content-Type')||'')) fail('endpoint');
    const reader=response.body.getReader(), decoder=new TextDecoder();
    let text='';
    for (;;) {
      const part=await reader.read(); if(part.done) break;
      if((bytes+=part.value.byteLength)>4*1024*1024){await reader.cancel(); fail('large');}
      text+=decoder.decode(part.value,{stream:true});
    }
    if(location.href!==here||isLogin()) fail('origin');
    const data=JSON.parse(text+decoder.decode()), table=data?.datas?.[action], rows=table?.rows;
    if((data.code!=null && String(data.code)!=='0') || table?.extParams?.code!=null && String(table.extParams.code)!=='1' ||
        !Array.isArray(rows)) fail('shape');
    // -1 with a zero page size is the school's unpaged response (BIT101).
    if(rows.length>500 || table.totalSize!=null && !(Number(table.totalSize)===rows.length ||
      Number(table.totalSize)===-1 && Number(table.pageSize)===0)) fail('incomplete');
    if(rows.some(r=>!r || r.XNXQDM!=null && r.XNXQDM!==term)) fail('term');
    return rows;
  }
  const field=v=>typeof v==='string' && v.length<=512 ? v.trim() : '';
  const number=v=>(typeof v==='string'||typeof v==='number') && /^\d{1,2}$/.test(String(v)) ? Number(v) : null;
  const validBits=s=>/^[01]{1,53}$/.test(s) && s.includes('1');
  const project=r=>({
    name:field(r.KCM),teacher:field(r.SKJS)||field(r.JSM),course:field(r.KCH),section:field(r.KXH),room:field(r.JASMC)||field(r.JAS),
    bits:field(r.SKZC),weekText:field(r.ZCMC),day:number(r.SKXQ),first:number(r.KSJC),last:number(r.JSJC)
  });
  try {
    const base=await read('xskcb','cxxszhxqkb');
    const inputs=[['',base]];
    if(heu) inputs.push(['experiment',await read('syjxkcb','cxsyjxxskb')]);
    const schedules=[];
    for(const [kind,rows] of inputs) for(const raw of rows) {
      const r=project(raw);
      if(kind==='experiment' && field(raw.SYXMMC)) r.name+='（'+field(raw.SYXMMC)+'）';
      else if(field(raw.TYXMDM_DISPLAY)) r.name+='（'+field(raw.TYXMDM_DISPLAY)+'）';
      schedules.push({id:field(raw.KBID),r});
    }
    let pending=0;
    if (jlu || heu) {
      const changes=await read('xskcb','xsdkkc',true);
      // The school orders latest first. Apply earlier changes before moves
      // that affect the same meeting later in the term.
      for(const ch of [...changes].reverse()){
        const id=field(ch.KBID), mask=field(ch.SKZC);
        if(!id || !validBits(mask)) fail('incomplete');
        const candidates=schedules.filter(x=>x.id===id && (!heu ||
          x.r.day===number(ch.SKXQ) && x.r.first===number(ch.KSJC) && x.r.last===number(ch.JSJC)) &&
          validBits(x.r.bits) && [...mask].some((b,i)=>b==='1' && x.r.bits[i]==='1'));
        if(candidates.length!==1) fail('incomplete');
        const original=candidates[0].r;
        original.bits=[...original.bits].map((v,i)=>mask[i]==='1'?'0':v).join('');
        const next=field(ch.XSKZC);
        const hasMove=heu ? ['01','03'].includes(String(ch.TKLXDM)) :
          /1/.test(next) || !!(ch.XSKXQ || ch.XKSJC || ch.XJSJC);
        if(!hasMove) continue; // Full/partial cancellation.
        const day=number(ch.XSKXQ), first=number(ch.XKSJC), last=number(ch.XJSJC);
        if(!validBits(next)||!day||day>7||!first||!last||last<first||last>30) fail('incomplete');
        schedules.push({id,r:{...original,day,first,last,bits:next,weekText:'',
          room:field(ch.XJASMC)||field(ch.JASMC)||original.room,teacher:field(ch.XSKJS)||field(ch.YSKJS)||original.teacher}});
      }
      if(jlu) pending=(await read('xskcb','xswpkc')).length;
    }
    const rows=schedules.map(x=>x.r).filter(r=>!/^0+$/.test(r.bits));
    if(rows.length>500) fail('large');
    return {rows,pending};
  } catch(e){return {error:['origin','login','large','shape','term','incomplete'].includes(e.message)?e.message:'endpoint'};}
})
