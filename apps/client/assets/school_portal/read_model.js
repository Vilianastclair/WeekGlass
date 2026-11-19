// Read only the data model feeding an already displayed timetable, at the user's request.
// This function runs inside the current same-origin document; it never installs hooks.
(async (doc, key, term, anchors) => {
  const w = doc.defaultView, loc = doc.location;
  const path = loc.pathname, here = loc.href;
  const fields = s => Object.fromEntries(s.split(' ').filter(Boolean).map(n => [n, true]));
  const activity = {...fields('courseName weekday room teachers startUnit endUnit credits lessonCode campus lessonRemark startTime endTime'), weekIndexes: [true]};
  activity.teachers = [true];
  const schema = {
    NewUrpParser: {dateList: [{selectCourseList: [{...fields('courseName attendClassTeacher'), timeAndPlaceList: [fields('campusName teachingBuildingName classroomName classDay classSessions classWeek continuingSession')]}]}]},
    BUAAParser: {datas: {arrangedList: [{...fields('courseName dayOfWeek placeName beginSection endSection credit beginTime endTime'), cellDetail: [{text:true}], titleDetail: [true]}]}},
    JLUParser: {datas: {xsjxrwcx: {rows: [fields('KCMC RKJS PKSJDD')]}}},
    CCIBEParser: [fields('kcmc xqj jxdd jsxm jc qsz jsz')],
    HFUTParser: {result: {lessonList: [fields('id courseName courseTypeName')], scheduleGroupList: [fields('lessonId stdCount')], scheduleList: [{...fields('lessonId weekday personName weekIndex startTime periods endTime lessonType'),room:{nameZh:true}}]}},
    SUSTechParser: [fields('KEY SKSJ')],
    GDBHParser: {data:[fields('cname week croomno name seq startweek endweek xf')]},
    YGUParser: {code:true,data:[{weekList:[{kcbVoList:[fields('xq zcs jcs dsz rkls kcmc jsmc')]}]}]},
    JXAUJkParser: {Data:[fields('SkZhou KcMc XingQi Skdd Rkls Jieci')]},
    FSTVCParser: {rows:[fields('skbjmc kcmc skjsxm zc skrq jcshow skcdmc xq xqs xn')],total:true},
    SUESParser2: {studentTableVms:[{activities:[activity],timeTableLayout:{name:true,courseUnitList:[fields('indexNo startTime endTime')]},arrangedLessonSearchVms:[{semester:{startDate:true}}]}]},
    NWPUParser: {semesterName:true,getData:{weekIndices:[true],lessons:[{semester:{startDate:true}}]},printData:{studentTableVm:{activities:[activity]}}},
    ChengFangParser: [fields('zcs xq jcdm2 kcmc jxcdmcs teaxms')],
    RUCParser: {course:[fields('title week start quittingTime teacher place weekly')], schoolHours:[true]},
  };
  if (!Object.hasOwn(schema,key)) return null;
  let nodes = 0;
  function pick(value, spec) {
    if (++nodes > 200000) throw Error('large');
    if (value == null) return null;
    if (spec === true) return ['number','string','boolean'].includes(typeof value) ? value : null;
    if (Array.isArray(spec)) return Array.isArray(value) ? value.map(e=>pick(e,spec[0])) : null;
    const out = {};
    for (const [k,v] of Object.entries(spec)) {
      if (typeof value === 'object' && Object.hasOwn(value,k)) out[k] = pick(value[k],v);
    }
    return out;
  }
  const shapes = {
    NewUrpParser:x=>x?.dateList?.[0]?.selectCourseList, BUAAParser:x=>x?.datas?.arrangedList,
    JLUParser:x=>x?.datas?.xsjxrwcx?.rows, HFUTParser:x=>x?.result?.scheduleList,
    CCIBEParser:x=>Array.isArray(x) && x.some(r=>r?.kcmc && r?.xqj && r?.qsz != null),
    SUSTechParser:x=>Array.isArray(x) && x.some(r=>r?.KEY && r?.SKSJ),
    GDBHParser:x=>x?.data?.some?.(r=>r?.cname && r?.startweek != null),
    YGUParser:x=>x?.data?.some?.(r=>Array.isArray(r?.weekList)),
    JXAUJkParser:x=>x?.Data?.some?.(r=>r?.KcMc && r?.SkZhou),
    FSTVCParser:x=>x?.rows?.length && x.rows[0]?.kcmc && Number(x.total)===x.rows.length,
    SUESParser2:x=>x?.studentTableVms?.[0]?.activities,
    NWPUParser:x=>x?.getData?.weekIndices && x?.printData?.studentTableVm?.activities,
    ChengFangParser:x=>Array.isArray(x) && x.some(r=>r?.jcdm2 && r?.kcmc),
    RUCParser:x=>x?.course?.some?.(r=>r?.weekly && r?.title) && Array.isArray(x?.schoolHours),
  };
  function model(x) {
    if (!shapes[key](x)) return null;
    nodes=0;
    const safe=pick(x,schema[key]);
    if(key==='NewUrpParser' && safe.dateList.length>1) {
      // The source page labels these tabs by program plan, not term. Only
      // collapse groups that identify themselves as plans in the source.
      if (!x.dateList.every(g=>Object.hasOwn(g,'programPlanCode') || Object.hasOwn(g,'programPlanName'))) return null;
      safe.dateList=[{selectCourseList:safe.dateList.flatMap(g=>g?.selectCourseList||[])}];
    }
    if(key==='BUAAParser') for(const row of safe.datas.arrangedList) {
      if(Array.isArray(row.cellDetail)) row.cellDetail=[{text:''},row.cellDetail[1]];
      if(Array.isArray(row.titleDetail)) row.titleDetail=[...Array(8).fill(''),row.titleDetail[8]];
    }
    const result = JSON.stringify(safe, null, key === 'RUCParser' ? 2 : undefined);
    if (key==='ChengFangParser') return '<!-- timetable model -->\nvar kbxx = '+result+';';
    return key==='RUCParser' ? '<!-- timetable model -->\n'+result : result;
  }
  // A documented semester code on the displayed personal timetable takes
  // precedence over guesses. Reject a known mismatch instead of putting
  // last year's rows in the app's newly selected semester.
  if (anchors.length && ['BUAAParser','NWPUParser','SUESParser2','SUSTechParser','NewUrpParser'].includes(key)) {
    const controls=doc.querySelectorAll('select[name=termCode],select[name=XNXQDM],select[name=semesterAssoc],select[name=semesterId],select#semester,select:has(option[name=semesterAssoc])');
    for(const control of controls) {
      const label=control.selectedOptions[0]?.textContent.trim() || '';
      const encoded=/^(\d{4})[-_](?:\d{4}[-_])?([123])$/.exec(control.value);
      const year=encoded ? Number(encoded[1]) : Number(/(\d{4})\s*[-～~至—–]\s*\d{4}/.exec(label)?.[1]);
      const order=encoded ? Number(encoded[2]) : /秋/.test(label) ? 1 : /春/.test(label) ? 2 : /夏/.test(label) ? 3 :
        Number(/第?\s*([123])\s*学期/.exec(label)?.[1]);
      if(year && (year!==term.year || order && order!==({3:1,12:2,16:3})[term.semester])) throw Error('term');
    }
  }
  const data = [];
  const roots = anchors.filter(e=>e?.getClientRects().length);
  // Only timetable components and specifically named schedule properties, never
  // application stores, user profiles, storage, authentication or session objects.
  for (const root of roots) {
    let el = root;
    for (let i=0; el && i<5 && !el.matches('body,html'); i++,el=el.parentElement) {
      const vm = el.__vue__?.$data ?? el.__vueParentComponent?.data;
      if (!vm) continue;
      for (const prop of ['timetable','schedule','scheduleData','courseTable','tableData','kbxx','wdkb','courseList','arrangedList','studentTableVms','dateList','wdkbData','course','schoolHours','xsjxrwcx','scheduleList','weekList']) {
        if (!Object.hasOwn(vm,prop)) continue;
        const x=vm[prop]; data.push(x);
        if (prop==='arrangedList') data.push({datas:{arrangedList:x}});
        if (prop==='xsjxrwcx') data.push({datas:{xsjxrwcx:x}});
        if (prop==='dateList' || prop==='studentTableVms') data.push({[prop]:x});
        if (prop==='scheduleList') data.push({result:{scheduleList:x,lessonList:vm.lessonList,scheduleGroupList:vm.scheduleGroupList}});
        if (prop==='course') data.push({course:x,schoolHours:vm.schoolHours});
      }
    }
  }
  if (!roots.length) return null;
  if (key === 'ChengFangParser') data.push(w.kbxx);
  for (const script of doc.querySelectorAll('script[type="application/json"][id]')) {
    if (!/^(?:(?:my|student)?(?:timetable|schedule|coursetable)(?:[-_]?(?:model|data))?|kbxx|wdkb)$/i.test(script.id) || script.textContent.length>4*1024*1024) continue;
    try {data.push(JSON.parse(script.textContent));} catch (_) {}
  }
  if (key==='FSTVCParser' && loc.host==='jw.fzrjxy.com' && path==='/studentportal.php/Jxxx/xxjdxx' && doc.querySelector('#mainlist') && typeof w.jQuery?.fn?.datagrid === 'function') {
    const grid=w.jQuery('#mainlist'); data.push(grid.datagrid('getData'));
  }
  // Extract only literal JSON arrays in the two legacy models, even when the
  // school puts the variable inside a closure. Brackets in quoted course names
  // are data; no school script is ever executed by this reader.
  function arrayAfter(s, key) {
    const hit=key.exec(s);
    if(!hit) return null;
    const start=hit.index+hit[0].length-1;
    let level=0,quoted=false;
    for(let i=start; i<s.length && i-start<4*1024*1024; i++) {
      const c=s[i];
      if(quoted) { if(c==='\\') i++; else if(c==='"') quoted=false; continue; }
      if(c==='"') quoted=true;
      else if(c==='[') level++;
      else if(c===']' && --level===0) {try{return JSON.parse(s.slice(start,i+1));} catch(_){return null;}}
    }
    return null;
  }
  if (key==='RUCParser' || key==='ChengFangParser') {
    for (const script of doc.querySelectorAll('script:not([src])')) {
      const s=script.textContent;
      if(s.length>4*1024*1024) continue;
      if(key==='ChengFangParser') data.push(arrayAfter(s,/\bvar\s+kbxx\s*=\s*\[/));
      else {
        const course=arrayAfter(s, /"course"\s*:\s*\[/), schoolHours=arrayAfter(s, /"schoolHours"\s*:\s*\[/);
        if(course && schoolHours) data.push({course,schoolHours});
      }
    }
  }
  for (const x of data) { const source=model(x); if(source) return source; }
  // Requests below are same-origin read-only school APIs. The displayed
  // schedule is a prerequisite; login, redirection and generic URLs are never replayed.
  async function request(url, form) {
    const method = form ? 'POST' : 'GET';
    const response = await w.fetch(url, {method,mode:'same-origin',credentials:'same-origin',redirect:'error',
      signal:AbortSignal.timeout(8000), headers:{Accept:'application/json','X-Requested-With':'XMLHttpRequest'},
      ...(form ? {body: new URLSearchParams(form)} : {})});
    if (!response.ok || loc.href !== here || !/\bjson\b/i.test(response.headers.get('Content-Type')||'')) throw Error('endpoint');
    const reader=response.body.getReader(), decoder=new TextDecoder();
    let size=0, text='';
    while (true) {
      const part=await reader.read(); if(part.done) break;
      if ((size+=part.value.byteLength)>4*1024*1024) {await reader.cancel(); throw Error('large');}
      text+=decoder.decode(part.value,{stream:true});
    }
    return JSON.parse(text+decoder.decode());
  }
  if(key==='NewUrpParser' && doc.querySelector('#mycoursetable')) {
    // The author's Inner Mongolia Minzu historical page uses this exact
    // personal-timetable GET. Match only this URL that the current page
    // already queried; do not examine or monitor any other requests.
    const route='/student/courseSelect/thisSemesterCurriculum/ajaxStudentSchedule/callback';
    if(w.performance.getEntriesByName(loc.origin+route,'resource').length) return model(await request(route));
  }
  if (key==='BUAAParser' && loc.origin==='https://byxt.buaa.edu.cn') {
    // Only reuse term/campus controls actually published by the personal
    // schedule. Do not read or send arbitrary form fields.
    const termSelect=doc.querySelector('select[name=termCode],select[name=XNXQDM]');
    const campus=doc.querySelector('select[name=campusCode],select[name=XQDM]');
    if (termSelect && /^\d{4}[-\d]{1,10}$/.test(termSelect.value) &&
        (!campus || /^\d{1,8}$/.test(campus.value))) {
      const args={[termSelect.name]:termSelect.value};
      if(campus) args[campus.name]=campus.value;
      return model(await request('/jwapp/sys/homeapp/api/home/student/getMyScheduleDetail.do',args));
    }
  }
  if ((key==='SUESParser2' && loc.origin==='https://jxfw.sues.edu.cn' || key==='NWPUParser' && loc.origin==='https://jwxt.nwpu.edu.cn') &&
      /^\/student\/for-std\/course-table(?:\/|$)/.test(path)) {
    const sel=doc.querySelector('select[name="semesterAssoc"],select#semester,select[name="semesterId"],select:has(option[name="semesterAssoc"])');
    const id=sel?.value;
    if(!/^\d{1,12}$/.test(id||'')) return null;
    const base='/student/for-std/course-table';
    if (key==='SUESParser2') return model(await request(base+'/semester/'+id+'/print-data?semesterId='+id+'&hasExperiment=true'));
    // The school assigns these values to *this* schedule. Do not accept an ID
    // from the app, URL inputs or users, and never look up a student profile.
    const number=n=> typeof n==='string' || typeof n==='number' ? /^\d{1,18}$/.test(String(n)) : false;
    if (!number(w.personId) || !number(w.dataId)) return null;
    const getData=await request(base+'/get-data?semesterId='+id+'&dataId='+w.personId+'&bizTypeId=2');
    const printData=await request(base+'/semester/'+id+'/print-data/'+w.dataId+'?hasExperiment=true');
    return model({getData,printData,semesterName:sel.selectedOptions[0]?.textContent||''});
  }
  return null;
})
