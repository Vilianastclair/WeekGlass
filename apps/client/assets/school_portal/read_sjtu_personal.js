// Read an authenticated student's whole-term course table on their request.
// Endpoint and form fields: yingyx's published SJTU calendar reader,
// https://greasyfork.org/en/scripts/597465-sjtu-ics-calendar-sync/code
(async (origin, path, year, semester) => {
  if (location.origin !== origin || location.pathname !== path) return {error:'origin'};
  const visible = el => !!el && el.getClientRects().length > 0 &&
    getComputedStyle(el).visibility === 'visible';
  if ([...document.querySelectorAll('input[type="password"],input[autocomplete="one-time-code"]')].some(visible)) {
    return {error:'login'};
  }
  if (/(?:^|[?&#])(?:ticket|(?:access|id)_token|SAMLResponse|SAMLRequest|code)=/i.test(location.search + location.hash)) {
    return {error:'login'};
  }
  const yearInput = document.querySelector('#xnm');
  const semesterInput = document.querySelector('#xqm');
  // The standard Chosen widget can replace the underlying native select.
  const displayed = input => input instanceof HTMLSelectElement &&
    (visible(input) || visible(document.getElementById(input.id + '_chosen')));
  if (!displayed(yearInput) || !displayed(semesterInput)) return {error:'missing'};
  const matchesTerm = () => yearInput.value === year && semesterInput.value === semester;
  if (!matchesTerm()) return {error:'term'};

  let response;
  try {
    response = await fetch('/kbcx/xskbcx_cxXsgrkb.html?gnmkdm=N2151', {
      method: 'POST',
      mode: 'same-origin',
      credentials: 'same-origin',
      redirect: 'error',
      headers: {
        'Accept': 'application/json',
        'X-Requested-With': 'XMLHttpRequest',
      },
      // Blank filters request the signed-in student's unfiltered timetable.
      body: new URLSearchParams({
        xnm: year, xqm: semester, kzlx: 'ck', xsdm: '', kclbdm: '', kclxdm: '',
      }),
    });
  } catch (_) {
    return {error:'endpoint'};
  }
  if (response.status === 401 || response.status === 403) return {error:'login'};
  if (!response.ok) return {error:'endpoint'};
  if (!/\bjson\b/i.test(response.headers.get('Content-Type') || '')) return {error:'login'};

  let data;
  try { data = await response.json(); }
  catch (_) { return {error:'shape'}; }
  if (!matchesTerm()) return {error:'term'};
  if (!Array.isArray(data?.kbList)) return {error:'shape'};
  if (data.kbList.length > 1000) return {error:'large'};
  const fields = ['kcmc','xqj','jcs','jc','zcd','xm','xqmc','cdmc','jxb_id','kch_id','kch'];
  const kbList = [];
  for (const row of data.kbList) {
    if (!row || typeof row !== 'object' || Array.isArray(row)) return {error:'shape'};
    const projected = {};
    for (const key of fields) {
      const field = row[key];
      if (typeof field === 'string' && field.length > 512) return {error:'large'};
      if (typeof field === 'string' || typeof field === 'number') projected[key] = field;
    }
    kbList.push(projected);
  }
  return {kbList};
})
