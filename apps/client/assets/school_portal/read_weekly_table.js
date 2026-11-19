(async function (origin, path, semester) {
  if (location.origin !== origin || location.pathname !== path) return {error:'origin'};
  if (document.querySelector('input[type=password],input[autocomplete=one-time-code]')) return {error:'login'};
  const tables = document.querySelectorAll('table.qz-weeklyTable');
  if (tables.length !== 1) return {error:tables.length ? 'multiple' : 'shape'};
  const query = new URL(location.href).searchParams;
  const allowed=new Set(['viweType','xnxq01id','zc','kbjcmsid','showallprint','showkchprint','showkink','showfzmprint','baseUrl','xsflMapListJsonStr']);
  if ([...query.keys()].some(k=>!allowed.has(k))) return {error:'origin'};
  const selection = document.querySelector('select#xnxq01id');
  if (selection ? selection.value !== semester : query.get('xnxq01id') !== semester) return {error:'term'};
  if ((document.querySelector('select#zc')?.value || query.get('zc') || '').trim() !== '') return {error:'incomplete'};
  const table=tables[0], rows=[];
  const slots=[...(table.tHead?.rows || [])].map(tr=>[...tr.cells].map(c=>{
    const key=c.textContent.match(/(?:星期|周)([一二三四五六日天])/);
    return key ? '一二三四五六日'.indexOf(key[1].replace('天','日'))+1 : 0;
  })).filter(h=>h.filter(Boolean).length===7);
  if (slots.length!==1 || new Set(slots[0].filter(Boolean)).size!==7) return {error:'shape'};
  const weekDays=slots[0], span=Array(weekDays.length).fill(0);
  const ranges=(raw,max)=>{
    if (!/^\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*$/.test(raw)) return null;
    const set=new Set();
    for(const part of raw.split(',')){
      const [l,r=l]=part.split('-').map(Number);
      if(l<1 || l>r || r>max) return null;
      for(let n=l;n<=r;n++)set.add(n);
    }
    return [...set].sort((a,b)=>a-b);
  };
  const field=(str,tag)=>str.match(new RegExp('(?:^|[;；])(?:'+tag+')[:：]([^;；]*)'))?.[1]?.trim() || '';
  let bodyRows=[...table.tBodies].flatMap(body=>[...body.rows]);
  if (bodyRows.length>100 || !bodyRows.length) return {error:'shape'};
  for (let ri=0;ri<bodyRows.length;ri++) {
    let col=0;
    for(const cell of bodyRows[ri].cells) {
      while(col<span.length && span[col]>ri) col++;
      const width=cell.colSpan, height=cell.rowSpan, at=col;
      if (!height || ri+height>bodyRows.length || col+width>span.length) return {error:'shape'};
      for(let k=0;k<width;k++,col++){
        if(span[col]>ri)return {error:'shape'};
        span[col]=ri+height;
      }
      const tips=cell.querySelectorAll('.qz-tooltip li.qz-toolitiplists');
      const visible=cell.querySelectorAll('li.courselists-item');
      // Tooltip and compact markup are two presentations of the same lesson.
      // Never read a hidden duplicate from both.
      for(const card of (tips.length ? tips : visible)) {
        const name=card.querySelector(tips.length?'.qz-tooltipContent-title':'.qz-hasCourse-title')?.textContent.trim();
        const details=tips.length?[...card.querySelectorAll('.qz-tooltipContent-detailitem')].map(n=>n.textContent.trim()).join(';'):
          (card.querySelector('.qz-hasCourse-abbrinfo')?.textContent || card.textContent?.trim().slice(name?.length || 0) || '');
        if(!name || name.length>240 || details.length>1400 || !weekDays[at])return {error:'shape'};
        const time=field(details,'时间').replace(/\s+/g,'').replace(/[，、]/g,',').replace(/[－–—~～]/g,'-')
            .replace(/[（]/g,'(').replace(/[）]/g,')').replace(/[【]/g,'[').replace(/[】]/g,']');
        const match=time.match(/^([\d,-]+)(?:\(([单双])周?\)|([单双]))?周(?:\(([单双])周?\))?\[([\d,-]+)节\]$/);
        if(!match || (match[4] && (match[2] || match[3]) && match[4] !== (match[2] || match[3])))return {error:'incomplete'};
        const parity=match[2]||match[3]||match[4], weeks=ranges(match[1],53), units=ranges(match[5],24);
        if(!weeks || !units)return {error:'incomplete'};
        const weekIndexes=weeks.filter(w=>!parity || w%2===(parity==='单'?1:0));
        if (!weekIndexes.length)return {error:'incomplete'};
        let room=field(details,'地点'), teacher=field(details,'老师|教师');
        if(room==='()'||room==='（）')room='';
        for(let d=at;d<at+width;d++){
          if(!weekDays[d])return {error:'shape'};
          for(let j=0;j<units.length;){
            const startUnit=units[j]; let endUnit=startUnit; j++;
            while(j<units.length && units[j]===endUnit+1)endUnit=units[j++];
            rows.push({courseName:name,weekday:weekDays[d],teachers:teacher?[teacher]:[],room,startUnit,endUnit,weekIndexes});
            if(rows.length>1000)return {error:'large'};
          }
        }
      }
    }
    if(span.some(end=>end<=ri))return {error:'shape'};
  }
  return {rows};
})

