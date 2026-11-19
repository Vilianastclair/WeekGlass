(async function (origin, pagePath, term) {
  if (location.origin !== origin || location.pathname !== pagePath) return {error: 'origin'};
  if (/(?:^|[?&#])(?:ticket|(?:access|id)_token|SAMLResponse|SAMLRequest|code)=/i.test(location.search + location.hash) ||
      document.querySelector('input[type=password],input[autocomplete="one-time-code"]')) {
    return {error: 'login'};
  }
  const here = location.href;
  const endpoint = '/jwapp/sys/wdkb/modules/xskcb/xskcb.do';
  const pageSize = 500;
  let data;
  try {
    const response = await fetch(endpoint, {
      method: 'POST',
      mode: 'same-origin',
      credentials: 'same-origin',
      redirect: 'error',
      signal: AbortSignal.timeout(8000),
      headers: {Accept: 'application/json', 'X-Requested-With': 'XMLHttpRequest'},
      body: new URLSearchParams({XNXQDM: term, querySetting: '[]', pageNumber: '1', pageSize: String(pageSize)})
    });
    if (!response.ok || response.url !== origin + endpoint ||
        !/\bjson\b/i.test(response.headers.get('Content-Type') || '') || !response.body) {
      return {error: 'endpoint'};
    }
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
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
    data = JSON.parse(text + decoder.decode());
  } catch (_) {
    return {error: 'endpoint'};
  }
  if (location.href !== here) return {error: 'origin'};
  if (data?.code != null && String(data.code) !== '0') return {error: 'endpoint'};
  const page = data?.datas?.xskcb;
  if (!Array.isArray(page?.rows)) return {error: 'shape'};
  const total = page.totalSize;
  if (page.rows.length > pageSize || (total == null && page.rows.length === pageSize) ||
      (total != null && (!/^\d+$/.test(String(total)) || Number(total) !== page.rows.length))) {
    return {error: 'incomplete'};
  }
  const text = (value, max) => typeof value === 'string' && value.length <= max ? value : '';
  return {
    rows: page.rows.map(row => ({
      title: text(row?.KCM, 240),
      code: text(row?.KCH, 80),
      section: text(row?.KXH, 40),
      teacher: text(row?.SKJS, 240),
      arrangement: text(row?.YPSJDD, 6000)
    }))
  };
})
