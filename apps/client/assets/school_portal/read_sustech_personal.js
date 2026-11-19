(async function (origin, path, term) {
  if (location.origin !== origin || location.pathname !== path) return {error: 'origin'};
  const endpoint = '/xszykb/queryxszykbzong';
  const visible = e => e.getClientRects().length &&
    e.ownerDocument.defaultView.getComputedStyle(e).visibility !== 'hidden';
  const login = d => [...d.querySelectorAll('input[type=password],input[autocomplete="one-time-code"]')].some(visible) ||
    /(?:^|[?&#])(?:ticket|(?:access|id)_token|SAMLResponse|SAMLRequest|code)=/i.test(d.location.search + d.location.hash);
  if (login(document)) return {error: 'login'};

  // The school's home page hosts many other apps. Only use the personal
  // semester query after the open panel itself has already used that URL.
  const docs = [document];
  for (const doc of docs) {
    for (const frame of doc.querySelectorAll('iframe,frame')) {
      try {
        const child = frame.contentDocument;
        if (docs.length < 24 && visible(frame) && child?.location.origin === origin && !docs.includes(child)) docs.push(child);
      } catch (_) { /* cross-origin school app */ }
    }
  }
  const url = origin + endpoint;
  const panels = docs.filter(doc => !login(doc) &&
    doc.defaultView.performance.getEntriesByName(url, 'resource').length &&
    [...doc.querySelectorAll('table,[role=grid]')].some(el => {
      if (!visible(el)) return false;
      const text = el.innerText;
      return /(?:星期|周)[一1]|\bMon(?:day)?\b/i.test(text) &&
        /(?:星期|周)[五5]|\bFri(?:day)?\b/i.test(text);
    }));
  if (panels.length !== 1) return {error: panels.length ? 'multiple' : 'missing'};
  const doc = panels[0], window = doc.defaultView;
  const here = location.href, panel = doc.location.href;
  let responseData;
  try {
    const response = await window.fetch(endpoint, {
      method: 'POST', mode: 'same-origin', credentials: 'same-origin', redirect: 'error',
      signal: AbortSignal.timeout(8000),
      headers: {Accept: 'application/json', 'X-Requested-With': 'XMLHttpRequest'},
      body: new URLSearchParams(term)
    });
    if (!response.ok || response.url !== url || !response.body) return {error: 'endpoint'};
    const reader = response.body.getReader(), decoder = new TextDecoder();
    let size = 0, text = '';
    for (;;) {
      const {done, value} = await reader.read();
      if (done) break;
      if ((size += value.byteLength) > 2 * 1024 * 1024) {
        await reader.cancel();
        return {error: 'large'};
      }
      text += decoder.decode(value, {stream: true});
    }
    // Some TIS deployments deliver JSON as text. Reject login HTML or
    // unexpected envelopes in the same code path without returning the body.
    responseData = JSON.parse(text + decoder.decode());
    if (location.href !== here || doc.location.href !== panel ||
        (doc !== document && (window.frameElement?.contentDocument !== doc || !visible(window.frameElement)))) return {error: 'origin'};
  } catch (_) { return {error: 'endpoint'}; }
  const rows = Array.isArray(responseData) ? responseData :
    responseData?.content ?? responseData?.data;
  if (!Array.isArray(rows)) return {error: 'shape'};
  if (rows.length > 1200) return {error: 'large'};
  if (!rows.some(row => /^(?:bz|xq[1-7]_jc\d+)$/i.test(row?.KEY || ''))) return {error: rows.length ? 'shape' : 'empty'};
  const text = (value, limit) => typeof value === 'string' && value.length <= limit ? value : null;
  const period = value => Number.isInteger(value) || /^\d{1,2}$/.test(String(value)) ? Number(value) : null;
  return {
    term: term.xn + '-' + term.xq,
    rows: rows.map(row => ({
      KEY: text(row?.KEY, 24),
      SKSJ: text(row?.SKSJ, 6000),
      KSJC: period(row?.KSJC),
      JSJC: period(row?.JSJC),
      ZC: text(row?.ZC, 100),
    }))
  };
})
