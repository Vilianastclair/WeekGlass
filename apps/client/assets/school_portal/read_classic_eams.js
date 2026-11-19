(async function (origin, campus, term) {
  const personal = '/eams/courseTableForStd.action';
  const grid = '/eams/courseTableForStd!courseTable.action';
  const home = '/eams/home.action';
  const isPersonal = path => path === grid || path === personal;
  if (location.origin !== origin || !(location.pathname === home || isPersonal(location.pathname))) {
    return {error: 'origin'};
  }
  const isLogin = doc => doc.querySelector('input[type=password],input[autocomplete=one-time-code]');
  if (isLogin(document)) return {error: 'login'};
  const frames = [];
  for (const frame of document.querySelectorAll('iframe, frame')) {
    try {
      const child = frame.contentDocument;
      if (frame.getClientRects().length && child?.location.origin === origin && isPersonal(child.location.pathname)) frames.push(child);
    } catch (_) {}
  }
  if (frames.length > 1) return {error: 'multiple'};
  const doc = frames[0] || document;
  if (isLogin(doc)) return {error: 'login'};
  let panel = doc;
  if (doc === document && location.pathname === home) {
    // The timetable can be opened as a same-document EAMS AJAX panel.
    const forms = [...doc.querySelectorAll('form[action]')].filter(form => {
      try {
        const url = new URL(form.getAttribute('action'), doc.baseURI);
        return form.getClientRects().length && url.origin === origin && isPersonal(url.pathname);
      } catch (_) { return false; }
    });
    if (forms.length > 1) return {error: 'multiple'};
    panel = forms[0]?.parentElement;
    if (!panel || panel === doc.body || panel === doc.documentElement) return {error: 'missing'};
  }

  const names = {'1': 1, '一': 1, '秋季': 1, '2': 2, '二': 2, '春季': 2, '3': 3, '三': 3, '夏季': 3, '暑期': 3};
  const labels = new Set();
  const label = value => {
    const s = (value || '').trim().replace(/\s+/g, '').replace(/[–—－]/g, '-');
    const m = s.match(/^(\d{4})-(\d{4})(?:学年)?(?:第)?([123一二三]|秋季|春季|夏季|暑期)学期$/) ||
      s.match(/^(\d{4})-(\d{4})-([123])$/);
    if (m) labels.add(m[1] + '-' + m[2] + '-' + names[m[3]]);
  };
  for (const el of panel.querySelectorAll('select#allSemesters, select#semesterCalendar, select[name="semester.id"], [id^=semesterBar][id$=Semester], #semesterCalendar_target, caption, h1, h2, h3, legend')) {
    const select = el.matches('select') ? el : el.querySelector('select');
    label(select ? select.selectedOptions[0]?.textContent : el.value || el.textContent);
  }
  if (labels.size > 1) return {error: 'multiple'};
  if (!labels.size) return {error: 'classicTerm'};
  if (!labels.has(term.year + '-' + (term.year + 1) + '-' + ({3:1,12:2,16:3})[term.semester])) {
    return {error: 'term'};
  }

  // Inspect the already loaded timetable only. The optional literal reader
  // below never evaluates page scripts, never fetches and never returns HTML.
  const w = doc.defaultView, raw = [];
  const bounded = (s, n = 240) => typeof s === 'string' && s.length <= n ? s.trim() : '';
  const scripts = [...panel.querySelectorAll('script:not([src])')].map(e => e.textContent).filter(s => s.length <= 2 * 1024 * 1024);
  const liveUnits = panel === doc ? Object.getOwnPropertyDescriptor(w, 'unitCount')?.value : null;
  const unitCount = Number.isInteger(liveUnits) ? liveUnits :
    Number(scripts.find(s => /\bunitCount\s*=\s*\d+\s*;/.test(s))?.match(/\bunitCount\s*=\s*(\d+)\s*;/)?.[1]);
  if (!Number.isInteger(unitCount) || unitCount < 1 || unitCount > 24) return {error: 'shape'};
  let unrecognized = 0;
  const add = (courseName, courseId, teacherName, room, bitmap, day, rawPeriod) => {
    const course = bounded(courseName);
    if (!course || !/^0[01]{1,53}$/.test(bitmap || '') || day < 0 || day > 6 ||
        rawPeriod < 0 || rawPeriod >= unitCount) {
      unrecognized++;
      return;
    }
    // NUAA's 13-cell version reserves display cells 5 and 6 for lunch,
    // unlike the official numbering of normal lessons. If it has a real
    // lesson in either extra cell, retain the school's actual grid numbering.
    const weeks = [...bitmap].flatMap((flag, i) => flag === '1' ? [i] : []);
    if (!weeks.length) { unrecognized++; return; }
    raw.push({
      courseName: course,
      lessonCode: bounded(typeof courseId === 'number' ? String(courseId) : courseId, 60),
      teachers: bounded(teacherName).split(/[,，、]/).map(t => t.trim()).filter(Boolean),
      room: bounded(room),
      weekday: day + 1,
      period: rawPeriod + 1,
      weeks
    });
  };
  const table = panel === doc ? Object.getOwnPropertyDescriptor(w, 'table0')?.value?.activities : null;
  if (Array.isArray(table) && table.length === 7 * unitCount &&
      table.every(cell => Array.isArray(cell))) {
    table.forEach((cell, i) => {
      for (const entry of cell) {
        if (raw.length >= 4000) return;
        if (entry) add(entry.courseName, entry.courseId, entry.teacherName, entry.roomName,
          entry.vaildWeeks ?? entry.validWeeks, Math.floor(i / unitCount), i % unitCount);
      }
    });
  }

  if (!raw.length) {
    unrecognized = 0;
    const snippets = scripts.filter(s => /\bactivity\s*=\s*new\s+TaskActivity\s*\(/.test(s));
    if (snippets.length > 1) return {error: 'multiple'};
    const s = snippets[0];
    if (!s) return {error: 'missing'};
    const argsOf = pos => {
      const args = [], nesting = [];
      let start = pos, quote = '';
      for (let i = pos; i < s.length && i - pos < 5000; i++) {
        const c = s[i];
        if (quote) {
          if (c === '\\') i++;
          else if (c === quote) quote = '';
        } else if (c === '"' || c === "'") quote = c;
        else if ('([{'.includes(c)) nesting.push(c);
        else if (c === ')' && nesting.length === 0) return {args: [...args, s.slice(start, i).trim()], end: i + 1};
        else if (')]}'.includes(c)) {
          if (nesting.pop() !== {')':'(',']':'[','}':'{'}[c]) return null;
        } else if (c === ',' && nesting.length === 0) {
          args.push(s.slice(start, i).trim());
          start = i + 1;
        }
      }
      return null;
    };
    const literal = token => {
      const m = token?.match(/^(?:"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)')$/s);
      if (!m) return '';
      return (m[1] ?? m[2]).replace(/\\(?:u([a-f\d]{4})|x([a-f\d]{2})|(["'\\nt]))/gi,
        (_, u, x, c) => u || x ? String.fromCharCode(parseInt(u || x, 16)) :
          (c === 'n' ? '\n' : c === 't' ? '\t' : c));
    };
    const constructors = [...s.matchAll(/\bactivity\s*=\s*new\s+TaskActivity\s*\(/g)];
    if (constructors.length > 1000) return {error: 'large'};
    for (let i = 0; i < constructors.length; i++) {
      const call = constructors[i], parsed = argsOf(call.index + call[0].length);
      const next = constructors[i + 1]?.index ?? s.length;
      if (!parsed) { unrecognized++; continue; }
      const args = parsed.args;
      // UESTC's validWeeks is argument 7 (one-based); NUAA has both
      // historically deployed layouts, where the bitmap disambiguates them.
      let bits = 6;
      if (campus === 'nuaa' && !/^0[01]{1,53}$/.test(literal(args[6]))) bits = 7;
      let names = literal(args[1]);
      if (campus === 'nuaa' && !names && /^actTeacherName\.join\(/.test(args[1] || '')) {
        const before = s.slice(Math.max(0, call.index - 8000), call.index);
        const a = [...before.matchAll(/\bactTeachers\s*=\s*\[([^\]]{0,5000})\]/g)].at(-1)?.[1] || '';
        names = [...a.matchAll(/\bname\s*:\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')/g)]
          .map(m => literal(m[1])).join('、');
      }
      const cells = s.slice(parsed.end, next).matchAll(
        /\bindex\s*=\s*(\d+)\s*\*\s*unitCount\s*\+\s*(\d+)\s*;\s*table0\.activities\[index\]\[table0\.activities\[index\]\.length\]\s*=\s*activity\s*;/g);
      for (const m of cells) {
        add(literal(args[3]), literal(args[2]), names, literal(args[bits - 1]), literal(args[bits]), Number(m[1]), Number(m[2]));
      }
    }
  }
  if (raw.length >= 4000) return {error: 'large'};
  if (!raw.length) return {error: unrecognized ? 'shape' : 'missing'};
  if (unrecognized) return {error: 'incomplete'};

  const skipLunchCells = campus === 'nuaa' && unitCount === 13 && !raw.some(r => r.period === 5 || r.period === 6);
  const sameCourse = r => [r.lessonCode, r.courseName, r.teachers, r.weekday];
  const canceled = new Set();
  for (const r of raw.filter(r => r.room === '停课')) {
    for (const week of r.weeks) canceled.add(JSON.stringify([...sameCourse(r), r.period, week]));
  }
  const groups = new Map();
  for (const r of raw) {
    if (r.room === '停课') continue;
    const key = JSON.stringify([...sameCourse(r), r.room]);
    if (!groups.has(key)) groups.set(key, {course: r, weekPeriods: new Map()});
    const {weekPeriods} = groups.get(key);
    for (const week of r.weeks) {
      if (canceled.has(JSON.stringify([...sameCourse(r), r.period, week]))) continue;
      if (!weekPeriods.has(week)) weekPeriods.set(week, new Set());
      weekPeriods.get(week).add(r.period);
    }
  }
  const rows = [];
  for (const {course, weekPeriods} of groups.values()) {
    const {courseName, lessonCode, teachers, room, weekday} = course;
    const intervals = new Map();
    const number = p => skipLunchCells && p > 6 ? p - 2 : p;
    for (const [week, periods] of weekPeriods) {
      const nodes = [...periods].sort((a, b) => a - b);
      for (let i = 0; i < nodes.length; i++) {
        const startUnit = number(nodes[i]);
        while (nodes[i + 1] === nodes[i] + 1) i++;
        const endUnit = number(nodes[i]);
        const key = startUnit + ':' + endUnit;
        if (!intervals.has(key)) intervals.set(key, {courseName, lessonCode, teachers, room, weekday, startUnit, endUnit, weekIndexes: []});
        intervals.get(key).weekIndexes.push(week);
      }
    }
    for (const row of intervals.values()) rows.push(row);
  }
  return rows.length > 1000 ? {error: 'large'} : {rows};
})
