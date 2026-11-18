// Based on the MIT-licensed NewZFParser, ZhengFangParser and QzParser family
// from YZune's CourseAdapter. Copyright (c) 2020 YZune.
// Invoked only by the native "read this page" button. No bridge or listeners.
(expectedOrigin => {
  const result = (error, rows = []) => JSON.stringify({error, rows});
  if (location.origin !== expectedOrigin) return result('origin');
  const visible = el => !!el && el.getClientRects().length > 0 &&
    el.ownerDocument.defaultView.getComputedStyle(el).visibility !== 'hidden';
  const login = doc => /(?:^|\/)(?:login|sso|cas|authserver|captcha|signin)(?:[./_;-]|$)/i.test(doc.location.pathname+'/'+doc.location.hash.slice(1)) ||
    /(?:^|[?&#])(?:ticket|(?:access|id)_token|SAMLResponse|SAMLRequest|code)=/i.test(doc.location.search+doc.location.hash) ||
    [...doc.querySelectorAll('input[type="password"],input[autocomplete="one-time-code"]')].some(visible);
  if (login(document)) return result('login');
  const docs = [document];
  for (let i = 0; i < docs.length && i < 24; i++) {
    for (const f of docs[i].querySelectorAll('iframe,frame')) {
      try {
        const d = f.contentDocument;
        if (docs.length < 24 && visible(f) && d && d.location.origin === expectedOrigin &&
            !docs.includes(d)) {
          if(login(d)) return result('login');
          docs.push(d);
        }
      } catch (_) { /* Only the school's own visible frames can be read. */ }
    }
  }
  const tables = docs.flatMap(d => [...d.querySelectorAll('table[id]')]
    .filter(t => visible(t) && /^(?:table1|kbgrid_table(?:_\d+)?|kbtable)$/i.test(t.id.trim())));
  if (!tables.length) return result('missing');
  if (tables.length !== 1) return result('multiple');
  const table = tables[0];
  const rows = [];
  const clean = s => (s || '').replace(/\s+/g,' ').trim();
  const text = e => clean(e?.textContent);
  const dayRe = /(?:星期|周|礼拜)\s*([一二三四五六日天1-7])/;
  const dayOf = s => { const c = (s.match(dayRe)||[])[1]; return c ? Number(c) || (c === '天' ? 7 : '一二三四五六日'.indexOf(c)+1) : 0; };
  const fail = (title = '') => rows.push({title, invalid: true});
  // For field text with a decorative icon and a caption, drop the caption only.
  const field = (e, label) => text(e).replace(new RegExp('^'+label+'\\s*[:：]\\s*'),'');
  const rowsOf = t => [...t.rows].filter(r => r.closest('table') === t);
  // New Zhengfang: each card describes its own periods and weeks; row spans
  // are presentation and must not turn a single period into a pair.
  if (table.id.trim() === 'table1' || /^kbgrid_table_\d+$/.test(table.id.trim())) {
    for (const titleEl of table.querySelectorAll('td[id] .title')) {
      const td = titleEl.closest('td'), title = text(titleEl);
      let card = titleEl.parentElement;
      while (card && card !== td && !card.querySelector('p [title],p[title]')) card = card.parentElement;
      if (!card || card === td || card.querySelectorAll('.title').length !== 1) {fail(title);continue;}
      const row = {title, day: Number((td.id.match(/^([1-7])(?:[-_]|$)/)||[])[1] || 0)};
      for (const p of card.querySelectorAll('p')) {
        const tag = (p.hasAttribute('title') ? p : p.querySelector('[title]'))?.getAttribute('title');
        if (tag === '教师' || tag === '任课教师') row.teacher = field(p,tag);
        if (tag === '上课地点' || tag === '教学地点') row.room = field(p,tag);
        if (tag === '节/周' || tag === '周/节') row.time = field(p,tag);
      }
      row.kind = 'zf';
      rows.push(row);
    }
  } else if (table.id.trim() === 'kbtable') {
    // Qiangzhi: map actual weekday headings; variants start on Sunday or Monday.
    const grid = rowsOf(table);
    const head = grid.map(r => [...r.cells].map(c => dayOf(text(c))))
      .find(days => new Set(days.filter(Boolean)).size === 7);
    if (!head) return result('shape');
    for (const tr of grid) {
      const slots = [...tr.cells];
      const rowPeriod = slots.filter(c=>c.tagName==='TH').map(c=>text(c))
        .map(s=>s.match(/^第?\s*([\d\s、,，－-]+)\s*节$/)?.[1]).find(Boolean) || '';
      for (let i=0; i<slots.length; i++) {
        const cell = slots[i];
        if (!visible(cell)) continue;
        let blocks = [...cell.querySelectorAll('.kbcontent,.kbcontent1')].filter(visible);
        // In Qiangzhi the visible summary and its expandable details are
        // sister nodes inside one cell. The summary's row can say 5–6 while
        // the actual course continues into period 7. Prefer explicit details
        // only when their course-name sequence matches the displayed summary.
        const names = b => {
          const a=[], lines=[]; let cur='';
          for(const n of b.childNodes) {
            if(n.nodeType===3) cur+=n.data;
            if(n.nodeName==='BR'){lines.push(clean(cur));cur='';}
          }
          lines.push(clean(cur));let start=true;
          for(const l of lines) {if(/^[-－]{4,}$/.test(l))start=true;else if(l && start){a.push(l);start=false;}}
          return a;
        };
        const detail = [...cell.querySelectorAll('.kbcontent')].find(b =>
          [...b.querySelectorAll('[title="周次(节次)"],[title="周次（节次）"],[title="节次"]')]
          .some(e=> /\[.+\]|节/.test(text(e))));
        if(detail && blocks.some(b=>b.classList.contains('kbcontent1') &&
            names(b).length && JSON.stringify(names(b))===JSON.stringify(names(detail)))) blocks=[detail];
        for (const block of blocks) {
          if (!text(block)) continue;
          const weekdays = head.filter(Boolean);
          const day = slots.length === head.length ? head[i] : slots.length === 7 ? weekdays[i] : 0;
          // A combined block uses a row of hyphens between course names.
          // Project only its name and explicitly labelled timetable fields.
          const chunks = [[]]; let line = [];
          const flush = () => {
            if (line.length) {
              if (/^[-－]{4,}$/.test(clean(line.map(x=>x.value).join('')))) chunks.push([]);
              else chunks[chunks.length-1].push(line);
            }
            line=[];
          };
          const walk = node => {
            if (node.nodeType === 3) { if (clean(node.data)) line.push({value:node.data});return; }
            if (node.nodeType !== 1 || /^(SCRIPT|STYLE|FORM|INPUT|TEXTAREA|SELECT|BUTTON|IFRAME)$/.test(node.tagName)) return;
            if (node.tagName === 'BR') {flush();return;}
            const tag = node.getAttribute('title');
            if (['周次(节次)','周次（节次）','周次','节次','老师','教师','教室','分组'].includes(tag)) {
              line.push({tag,value:text(node)});return;
            }
            node.childNodes.forEach(walk);
          };
          block.childNodes.forEach(walk); flush();
          for (const chunk of chunks.filter(c=>c.length)) {
            const parts = chunk.flat(), fi = parts.findIndex(x=>x.tag);
            const title = clean((chunk[0] || []).filter(x=>!x.tag).map(x=>x.value).join(''));
            const value = (...keys) => parts.filter(x=>keys.includes(x.tag)).map(x=>x.value).join(' ');
            if (fi < 0 || !title) {fail(title);continue;}
            rows.push({kind:'qz',day,title,teacher:value('老师','教师'),room:value('教室'),group:value('分组'),
              time:value('周次(节次)','周次（节次）'), weeks:value('周次'), periods:value('节次') || rowPeriod});
          }
        }
      }
    }
  } else {
    // Old Zhengfang: accept only an explicit day, period and week expression.
    // Never infer periods or weeks from layout alone.
    const timeLine = /\{[^{}]*周[^{}]*\}/;
    if (!rowsOf(table).some(row=>new Set([...row.cells].map(c=>dayOf(text(c))).filter(Boolean)).size===7))
      return result('missing');
    for (const tr of rowsOf(table)) for (const cell of tr.cells) {
      if (cell.querySelector('table')) continue;
      if (!timeLine.test(text(cell))) continue;
      const lines = []; let line = '';
      const walk = n => {
        if (n.nodeType === 3) {line += n.data;return;}
        if (n.nodeType !== 1 || /^(SCRIPT|STYLE|FORM|INPUT|TEXTAREA|SELECT|BUTTON)$/.test(n.tagName)) return;
        if (n.tagName === 'BR') {lines.push(clean(line));line='';return;}
        n.childNodes.forEach(walk);
      };
      cell.childNodes.forEach(walk); lines.push(clean(line));
      const groups = [[]]; for (const l of lines) {if(l) groups.at(-1).push(l);else if(groups.at(-1).length) groups.push([]);}
      for (const g of groups.filter(g=>g.length)) {
        const idx=g.findIndex(l=>timeLine.test(l));
        if (idx < 1 || g.filter(l=>timeLine.test(l)).length !== 1) {fail(g[0]);continue;}
        rows.push({kind:'oldzf',title:g[0],day:dayOf(g[idx]),time:g[idx],
          teacher:g.length-idx>=3 ? g[idx+1] : '',room:g.length-idx>=3 ? g[idx+2] : ''});
      }
    }
  }
  if (!rows.length) return result('missing');
  if (rows.length > 1000 || rows.some(r=>Object.values(r).some(v=>typeof v==='string' && v.length>512))) return result('large');
  const doc=table.ownerDocument;
  const supplemental = [
    ['table#sycjlrtabGrid','tr.jqgrow'],
    ['table#Table3','tr'], ['table#DBGrid','tr'],
  ].some(([selector,rowSelector])=>{
    const t=doc.querySelector(selector);
    if(!t || t===table || !visible(t)) return false;
    if(rowSelector==='tr.jqgrow') return t.querySelector(rowSelector)!==null;
    return rowsOf(t).length>2 && /实践课|原上课时间|调课/.test(text(t.rows[0])+' '+text(t.rows[1]));
  });
  return JSON.stringify({error:null,rows,supplemental});
})
