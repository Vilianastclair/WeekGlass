(async function (termTitle) {
  const gridUrl = 'https://xkgo.ucas.ac.cn:3000/course/personSchedule';
  if (location.href !== gridUrl) return {error: 'origin'};
  if (document.querySelector('input[type=password], input[autocomplete="one-time-code"]')) return {error:'login'};
  const text = el => (el?.textContent || '').trim();
  const visible = el => el.getClientRects().length && getComputedStyle(el).visibility !== 'hidden';
  const heading = document.querySelector('#page-title');
  if (!heading || !visible(heading) || text(heading) !== termTitle) return {error:'term'};
  const tables = [...document.querySelectorAll('table')].filter(t => visible(t) && t.rows[0] &&
    [...t.rows[0].cells].map(text).join('|') === '节次/星期|星期一|星期二|星期三|星期四|星期五|星期六|星期日');
  if (tables.length !== 1) return {error: tables.length ? 'multiple' : 'shape'};
  const courses = new Map(), periods = new Set();
  for (const row of [...tables[0].rows].slice(1)) {
    const cells = [...row.cells], p = Number(text(cells[0]));
    if (cells.length !== 8 || !Number.isInteger(p) || p < 1 || p > 13 || periods.has(p)) return {error:'shape'};
    periods.add(p);
    for (let day = 1; day <= 7; day++) {
      const cell=cells[day], anchors=[...cell.querySelectorAll('a')];
      // Discard no anonymous courses: their weeks cannot be reconstructed.
      if (text(cell).replace(/\s/g,'') !== anchors.map(text).join('').replace(/\s/g,'')) return {error:'incomplete'};
      for (const a of anchors) {
        const m = /^https:\/\/xkcts\.ucas\.ac\.cn:8443\/course\/coursetime\/([1-9]\d{0,8})$/.exec(a.href);
        const title = text(a);
        if (!m || !title || title.length > 250 || !visible(a)) return {error:'incomplete'};
        const id = m[1], course = courses.get(id) || {id, title, slots:[]};
        if (course.title !== title) return {error:'shape'};
        course.slots.push([day,p]);
        courses.set(id, course);
        if (courses.size > 48) return {error:'large'};
      }
    }
  }
  return courses.size ? {termTitle, courses:[...courses.values()]} : {error:'missing'};
})
