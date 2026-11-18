// Copyright (c) 2026 WeekGlass. Selector shapes follow YZune's MIT CourseAdapter.
// Project only the selected timetable; no full document, forms, external scripts
// or traffic history are returned to the application.
(async (origin, keys, term, readModel) => {
  if (location.origin!==origin) return {error:'origin'};
  const visible=e=>!!e && e.getClientRects().length>0 && e.ownerDocument.defaultView.getComputedStyle(e).visibility!=='hidden';
  const login=d=>/(?:^|\/)(?:login|sso|cas|authserver|captcha|signin)(?:[./_;-]|$)/i.test(d.location.pathname+'/' + d.location.hash.slice(1)) ||
    [...d.querySelectorAll('input[type=password],input[autocomplete=one-time-code]')].some(visible) ||
    /(?:^|[?&#])(ticket|(?:access|id)_token|SAMLResponse|SAMLRequest|code)=/i.test(d.location.search+d.location.hash);
  if(login(document)) return {error:'login'};
  const docs=[document];
  for (const d of docs) for(const f of d.querySelectorAll('iframe,frame')) {
    try {
      const inner=f.contentDocument;
      if (visible(f) && inner && (inner.location.origin===origin ||
          (f.hasAttribute('srcdoc') && inner.location.href==='about:srcdoc' && inner.defaultView.origin===origin)) &&
          docs.length<24 && !docs.includes(inner)) {
        if(login(inner)) return {error:'login'};
        docs.push(inner);
      }
    } catch (_) {}
  }
  const selectors={
    AHNUParser:'#kcb',NewAHNUParser:'table#lessons:has(.showSchedules)',
    BJTUParser:'table.table-bordered',BNUZParser:'#table1',BFAforYJSParser:'#table:has(td[_nk])',
    CSXYParser:'table:has([id="1-1-2"])',CQUPTParser:'#stuPanel',CNUParser:'table:has(.curriculum-item)',
    CTGUParser:'table:has(td[field=kcmc]):has(td[field=sjms])',ECJTUParser:'table.table_border',ECNUParser:'table.table:has(thead:nth-of-type(2))',
    FSPTParser:'#kbtable',GDBYXYParser:'#pageRpt',GDEIParser:'table:has(td div div)',
    GXICParser:'table[width="98%"]:has(a[title])',GZHUYJSParser:'table.tab_0',HHUParser:'#timetable:has(.kbcontent)',
    HLJUParser:'table:has(.ivu-table-tbody)',HNIUParser:'[bordercolordark="#FFFFFF" i]',HNJMParser:'.Sub-kcbt,.Sub-kcbt + br,.Sub-kcbt + table',
    HNZJParser:'table#reportArea',HNUSTParser:'#kbtable',HrbeuGraduateParser:'#StuCul_TimetableQry_TimeTable',
    HUATParser:'#ctl00_ContentPlaceHolder1_CourseTable',HUSTParser:'.main-page-block:has(.search-details-body)',
    JAVTCParser:'table[border="1"][width="98%"]:has(a[title])',JinZhiParser:'.wut_table:has(.mtt_arrange_item)',
    JNUParser:'#oReportCell',JXAUParser:'#KebiaoTable1',JXNUParser:'#_ctl1_NewKcb',
    KingosoftZXParser:'#pageRpt',LNGDParser:'#wdkb-kb, #root .kbappTimetableDayColumnRoot___1DlDV',
    NewZFParser:'#table1,#sycjlrtabGrid',NFUParser:'table:has(tr.ui-widget-content)',NJUParser:'#kcb_container:has(.wut_table)',
    NWPUGraduateParser:'#sample-table-1',NYISTParser:'.course-content',OldQzParser:'#kbtable',PekingParser:'table.datagrid',
    Qz2017Parser:'.el-table__header,.el-table__body', QzParser:'#kbtable',QzBrParser:'#kbtable',QzCrazyParser:'#kbtable',QzWithNodeParser:'#kbtable',
    SDPEIParser:'#tableMain',SHUParser2024:'.arranged-content',SHTechParser:'#div-table',SHTechParser2024:'#jsTbl_01',SIMCParser:'.grid:has(>table)',
    SITParser:'table:has([name=d1])',SUESParser:'.listTable',SWJTUGraduateParser:'.mtt_table1',SYSUParser:'.com-table.class-schedule-table2',
    SYSUParser2024:'#table-bot',UrpParser:'table.displayTag,table.table-striped.table-bordered',USTCGraduateParser:'table',
    WISTParser:'.wut_table:has(td[data-role=item])',XAUATParser:'table:has(tr#swsjbzlb1)',XJTUGraduateParser:'.GridViewStyle',
    YZZYParser:'#timetable:has(.kbcontent)',ZhengFangParser:'#Table1,#kbgrid_table',ZjvtitParser:'table.scheduleTable:has(.courseInfo)',ZPTCParser:'#kb:has(.pbtd)',
    ECUPLParser:'.listTable',
  };
  const models=new Set(['BUAAParser','CCIBEParser','ChengFangParser','FSTVCParser','GDBHParser','HFUTParser','JLUParser','JXAUJkParser','NewUrpParser','NWPUParser','RUCParser','SUESParser2','SUSTechParser','YGUParser']);
  const scripts=new Set(['ECUPLParser','HUNNUParser','AHSTUParser','SupwisdomParser','SUESParser','THUParser']);
  function timetable(e) {
    const text=e.innerText||'';
    return /(?:星期|周)[一1]/.test(text) && /(?:星期|周)[五5]/.test(text) ||
      /(?:周次|教学周|上课周|\d+\s*[-~至]\s*\d+\s*周)/.test(text) && /(?:课程|课名|教师|教室|节次|\d+\s*节)/.test(text);
  }
  const tags=new Set('div span p a b font br table tbody thead tfoot tr th td h1 h2 h3 h4 ol ul li section em strong small i label pre center dl dt dd'.split(' '));
  const attrs=new Set('id class title colspan rowspan field week lesson data-role data-unit _nk border bordercolordark width valign align color'.split(' '));
  const esc=s=>s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
  // String serialization: unlike deep-cloning live nodes, this never creates
  // active elements or sends requests to asset URLs.
  const adapterAttrs={
    WISTParser:new Set(['data-week','data-begin-unit','data-end-unit']), JXNUParser:new Set(['bgcolor']),
    SWJTUGraduateParser:new Set(['jc','xq']), NewZFParser:new Set(['aria-describedby']),
  };
  function serialize(el,key) {
    let budget=0;
    function walk(n) {
      if(++budget>150000) throw Error('large');
      if(n.nodeType===3) return esc(n.data);
      if(n.nodeType!==1) return '';
      const tag=n.localName;
      if(['script','style','template','caption','iframe','frame','svg','input','select','option','textarea','button','object','embed','img','link'].includes(tag)) return '';
      if(n.classList?.contains('student-info') || n.classList?.contains('student-profile')) return '';
      const body=[...n.childNodes].map(walk).join('');
      if(!tags.has(tag)) return body;
      let attr='';
      for(const {name,value} of n.attributes) {
        if(attrs.has(name) || adapterAttrs[key]?.has(name) || name==='name' && value==='d1' || name==='onmouseover' && value==='kbtc(this)') attr+=' '+name+'="'+esc(value)+'"';
        else if(name==='style'){
          const safe=value.split(';').map(v=>v.trim()).filter(v=>/^(?:text-align|vertical-align|display|height|width|top|left)\s*:\s*[\w. %+-]+$/i.test(v));
          if(safe.length) attr+=' style="'+esc(safe.join('; ')+(value.trim().endsWith(';')?';':''))+'"';
        }
      }
      return '<'+tag+attr+'>'+body+(tag==='br'?'':'</'+tag+'>');
    }
    return walk(el);
  }
  function courseScript(doc,key) {
    // The parser reads these literal timetable statements as text. Never
    // evaluate them or include an entire page's scripts.
    const chunks=[];
    for (const el of doc.querySelectorAll('script:not([src])')) {
      const s=el.textContent;
      if(s.length>4*1024*1024) continue;
      if(key==='THUParser' && /setInitValue\(/.test(s) && /strHTML/.test(s)){
        const lines=s.split(/\r?\n/).filter(l=>/strHTML1?\s*\+=|blue_red_none|(?:getElementById\([^)]*a\d_\d)/.test(l));
        if(lines.length) chunks.push('setInitValue()\n'+lines.join('\n')+'\nsetInitValue');
      } else if(key==='ECUPLParser' && /new CourseTable\(/.test(s) && /newActivity\(/.test(s)) {
        const lines=s.match(/new CourseTable\('[\d-]+',\[[\d,[\]]+\]\)|newActivity\([^;]{1,2000}\);|addActivityByTime\(activity,\d,\d+,\d+\);/g)||[];
        if(lines.length) chunks.push('<script language="JavaScript">'+lines.join('\n')+'</script>');
      } else if(/new TaskActivity\(/.test(s)) {
        const statements=s.match(/(?:var (?:actTeachers|teachers)\s*=\s*\[[^;]{0,3000}\]|(?:activity\s*=\s*)?new TaskActivity\([^;]{1,4000}\)|courseName\s*\+=\s*"[^"\n]*"|index\s*=\s*\d+\*unitCount\+\d+)\s*;/g)||[];
        const term=s.match(/table0\.marshalTable\(\s*[-\d]+\s*,\s*[-\d]+\s*,\s*[-\d]+\s*\);/);
        if(statements.length) chunks.push('var activity=null;\n'+statements.join('\n')+'\n'+(term?.[0]||'table0.marshalTable'));
      }
    }
    return chunks.join('\n');
  }
  const checked=new Set(), rejected={};
  for(const key of keys) {
    if(checked.has(key)) continue; checked.add(key);
    const matches=[];
    for(const d of docs) {
      let roots=[...d.querySelectorAll(selectors[key]||'table,.course-table,.courseTable,.timetable,.schedule-table,[id*=timetable i],#wdkb-kb,#kcb_container,.arranged-content,.schedule-list,.datagrid-view,[role=grid]')].filter(visible);
      // Common CSS classes are not enough on their own. Require course-table
      // columns or weekday headings before reading generic grids or a JSON model.
      if(models.has(key) || !selectors[key] || ['GDEIParser','BJTUParser','NFUParser','PekingParser','UrpParser','SUESParser','USTCGraduateParser','HNIUParser','ECNUParser'].includes(key)) roots=roots.filter(timetable);
      if(key==='SUESParser' || key==='ECUPLParser') {
        const tables=[...d.querySelectorAll('table.listTable')];
        // These adapters pair a grid and a detail list. The list can sit
        // in a collapsed tab belonging to the visible schedule.
        roots=tables.length===2 && tables.some(t=>visible(t) && timetable(t)) ? tables : [];
      }
      if(key==='UrpParser') {
        const detail=t=>{
          const cols=[...t.querySelectorAll('thead th')].map(c=>c.textContent.trim());
          return ['课程名','教师','周次','星期','节次'].every(n=>cols.includes(n));
        };
        roots=roots.filter(detail);
        // New URP splits this semester's courses into program-plan tabs. Include
        // inactive tabs only from that same, explicitly identified plan group.
        const group=roots[0]?.closest('.tab-content');
        if(group?.querySelector('.nav-tabs')?.textContent.includes('总学分') &&
           roots.every(t=>t.closest('.tab-content')===group)) {
          roots=[...group.querySelectorAll(selectors[key])].filter(detail);
        }
      }
      if(key==='USTCGraduateParser' && d.defaultView.frameElement?.id!=='iframeContent_kbcxappustcxskbcx') roots=[];
      // One copy of each root; nested elements remain in their parent's structure.
      roots=roots.filter(e=>!roots.some(outer=>outer!==e && outer.contains(e)));
      if(!roots.length) continue;
      if(!models.has(key) && roots.length>1) {
        // Some vendors split ONE schedule into complementary tables/lists.
        // Independently complete grids must never be concatenated.
        const paired=['ECUPLParser','SUESParser','SYSUParser'].includes(key) && roots.length===2;
        const complementary=key==='Qz2017Parser' && roots.length===2 &&
          roots.filter(e=>e.classList.contains('el-table__header')).length===1 &&
          roots.filter(e=>e.classList.contains('el-table__body')).length===1 ||
          key==='NewZFParser' && roots.length===2 && new Set(roots.map(t=>t.id)).size===2;
        const grouped=key==='UrpParser' && roots.every(e=>e.closest('.tab-content')?.querySelector('.nav-tabs')?.textContent.includes('总学分') && e.closest('.tab-content')===roots[0].closest('.tab-content')) ||
          key==='HNJMParser' || key==='NYISTParser' && roots.every(e=>e.parentElement===roots[0].parentElement) ||
          key==='LNGDParser' && roots.length<=7 && roots.every(e=>e.closest('#root')===roots[0].closest('#root'));
        if(!(paired || complementary || grouped)) return {error:'multiple'};
      }
      let text='';
      if(models.has(key)) {
        try {text=await readModel(d,key,term,roots);} catch(e) {if(e.message==='large') throw e; if(e.message==='term') return {error:'term'}; rejected[key]='endpoint';}
      } else {
        if(!selectors[key] && !scripts.has(key)) continue;
        const script=scripts.has(key) ? courseScript(d,key) : '';
        if(scripts.has(key) && !script) continue;
        text=key==='WISTParser' ?
          '<table class="wut_table"><tbody><tr>'+[...roots[0].querySelectorAll('td[data-role=item]:has(.mtt_arrange_item)')].map(e=>serialize(e,key)).join('')+'</tr></tbody></table>' :
          roots.map(e=>serialize(e,key)).join('\n');
        if(key==='NWPUGraduateParser') {
          const selected=d.querySelector('#xq option:checked');
          if(selected) text+='<select id="xq"><option selected>'+esc(selected.textContent)+'</option></select>';
        }
        if(key==='SITParser') text='<form>'+text+'</form>';
        if(key==='LNGDParser' && !text.includes('id="wdkb-kb"')) text='<div id="root">'+text+'</div>';
        if(key==='USTCGraduateParser') text='<iframe id="iframeContent_kbcxappustcxskbcx" srcdoc="'+esc(text)+'"></iframe>';
        if(script) text+='\n'+script;
      }
      if(text) matches.push(text);
    }
    if(matches.length>1) return {error:'multiple'};
    if(matches.length===1) {
      if(new TextEncoder().encode(matches[0]).length>4*1024*1024) return {error:'large'};
      return {adapter:key,source:matches[0]};
    }
  }
  return {error:Object.keys(rejected).length?'endpoint':'missing'};
})
