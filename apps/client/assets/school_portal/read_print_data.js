(async function (origin, path, term, settings) {
  if (location.origin !== origin || ![path, path + '/'].includes(location.pathname)) {
    return {error: 'origin'};
  }
  if (document.querySelector('input[type="password"],input[autocomplete="one-time-code"]')) {
    return {error: 'login'};
  }
  const controls = document.querySelectorAll(settings.semesterSelector);
  if (controls.length > 1 || controls[0]?.selectedOptions.length > 1) return {error: 'multiple'};
  const select = controls[0];
  const option = select?.selectedOptions[0];
  const id = option?.value ?? '';
  if (!/^\d{1,12}$/.test(id)) return {error: 'shape'};
  const label = option.textContent.replace(/\s+/g, '').replace(/[–—－]/g, '-');
  const names = {3: ['1', '一', '秋季'], 12: ['2', '二', '春季'], 16: ['3', '三', '夏季', '暑期']};
  const yearLabel = term.year + '-' + (term.year + 1);
  const termNames = names[term.semester];
  if (!termNames?.some(n => ['','第'].some(prefix => label === yearLabel + '学年' + prefix + n + '学期')) &&
      !(settings.numericTermLabel && termNames && label === yearLabel + '-' + termNames[0])) {
    return {error: 'term'};
  }

  // The school sets this opaque semester ID in the personal timetable's
  // selector. The documented print-data route does not take a student ID.
  const start = !settings.readStartDate || typeof semesters === 'undefined' || !Array.isArray(semesters)
    ? null
    : semesters.find(row => row && String(row.id) === id)?.startDate;
  const here = location.href;
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(settings.query)) {
    params.set(key, value === '{semesterId}' ? id : value);
  }
  const query = params.toString();
  const endpoint = path + '/semester/' + id + '/print-data' + (query ? '?' + query : '');
  let data;
  try {
    const response = await fetch(endpoint, {
      method: 'GET',
      mode: 'same-origin',
      credentials: 'same-origin',
      redirect: 'error',
      signal: AbortSignal.timeout(8000),
      headers: {Accept: 'application/json', 'X-Requested-With': 'XMLHttpRequest'}
    });
    if (!response.ok || response.url !== origin + endpoint ||
        !/\bjson\b/i.test(response.headers.get('Content-Type') || '') || !response.body) {
      return {error: 'endpoint'};
    }
    const body = response.body.getReader();
    const decoder = new TextDecoder();
    let size = 0, json = '';
    for (;;) {
      const {done, value} = await body.read();
      if (done) break;
      if ((size += value.byteLength) > 4 * 1024 * 1024) {
        await body.cancel();
        return {error: 'large'};
      }
      json += decoder.decode(value, {stream: true});
    }
    data = JSON.parse(json + decoder.decode());
  } catch (_) {
    return {error: 'endpoint'};
  }
  if (location.href !== here || !select.isConnected || select.selectedOptions.length !== 1 ||
      select.selectedOptions[0] !== option || option.value !== id) {
    return {error: 'term'};
  }
  let activities, table;
  for (const shape of settings.tableShapes) {
    if (shape === 'studentTableVms' && Array.isArray(data?.studentTableVms)) {
      if (data.studentTableVms.length > 1) return {error: 'multiple'};
      table = data.studentTableVms[0];
      activities = data.studentTableVms.length ? table?.activities : [];
    } else if (shape === 'studentTableVm') {
      table = data?.studentTableVm;
      activities = table?.activities;
    } else if (shape === 'activities') {
      table = null;
      activities = data?.activities;
    }
    if (Array.isArray(activities)) break;
  }
  if (!Array.isArray(activities)) return {error: 'shape'};
  if (activities.length > 1000) return {error: 'large'};

  // Only course fields cross the WebView boundary: no student info, raw page,
  // login data or ancillary teaching-office records.
  const text = (value, max = 240) => typeof value === 'string' && value.length <= max ? value : null;
  const scalar = value => Number.isSafeInteger(value) || (typeof value === 'string' && /^\d{1,18}$/.test(value))
    ? value
    : null;
  const units = settings.readCourseClock ? table?.timeTableLayout?.courseUnitList : null;
  return {
    startDate: text(start, 50),
    ...(Array.isArray(units) && units.length <= 24 ? {
      courseUnits: units.map(unit => ({
        indexNo: scalar(unit?.indexNo),
        startTime: scalar(unit?.startTime),
        endTime: scalar(unit?.endTime)
      }))
    } : {}),
    rows: activities.map(row => ({
      courseName: text(row?.courseName),
      lessonId: scalar(row?.lessonId),
      lessonCode: text(row?.lessonCode, 60),
      weekday: scalar(row?.weekday),
      startUnit: scalar(row?.startUnit),
      endUnit: scalar(row?.endUnit),
      weekIndexes: Array.isArray(row?.weekIndexes) && row.weekIndexes.length <= 54 ? row.weekIndexes.map(scalar) : null,
      room: text(row?.room),
      teachers: Array.isArray(row?.teachers) && row.teachers.length <= 20
        ? row.teachers.map(t => text(t, 80)).filter(Boolean)
        : []
    }))
  };
})
