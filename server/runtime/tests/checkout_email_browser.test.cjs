// Run alongside auth_email_browser.test.cjs using Playwright and the local Python runtime.
const assert = require('node:assert/strict');
const {execFileSync} = require('node:child_process');
const {mkdir} = require('node:fs/promises');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const {mkdtempSync, writeFileSync, unlinkSync, rmdirSync} = require('node:fs');
const {test} = require('node:test');
const {chromium} = require('playwright');

const fixture = String.raw`
import json
from types import SimpleNamespace
from weekglass_server.billing import WAFFO_LIVE_PROVIDER
from weekglass_server.waffo_routes import order_page
config = SimpleNamespace(sandbox_origin=None)
order = dict(account_id=None, period_seconds=30 * 86400, amount_minor=100,
             provider=WAFFO_LIVE_PROVIDER, provider_checkout_url=None)
pages = {}
for view, status, verify in [('pending', 'processing', False), ('paid', 'paid', True)]:
    reply = order_page(dict(order, status=status), config, verify_email=verify)
    pages[view] = [reply.body.decode(), dict(reply.headers)]
print(json.dumps(pages))
`;

test('an in-place payment refresh offers the same verified next step as a paid reload', async () => {
  const temp = mkdtempSync(path.join(os.tmpdir(), 'wg-checkout-browser-'));
  const signingKey = path.join(temp, 'synthetic-key');
  writeFileSync(signingKey, 'unusable-synthetic-checkout-fixture-key-not-for-production');
  let server, browser;
  try {
    const pages = JSON.parse(execFileSync(process.env.WG_PYTHON || 'python', ['-c', fixture], {
      cwd: path.resolve(__dirname, '..'), encoding: 'utf8',
      env: {...process.env, WEEKGLASS_SERVER_ID: '81659991-4094-4cca-afb2-9a04d3fd41ec',
        AUTH_SIGNING_KEY_FILE: signingKey},
    }));
    let paid = false;
    server = http.createServer((req, res) => {
      if (req.url === '/v1/billing/checkout/test/refresh' && req.method === 'POST') {
        res.writeHead(200, {'Content-Type': 'application/json'});
        return res.end(JSON.stringify({status: 'paid', verify_email: true}));
      }
      if (req.url === '/v1/auth/email') return res.end('Separate account verification');
      if (req.url !== '/v1/billing/checkout/test') {
        res.writeHead(404);
        return res.end();
      }
      const [body, headers] = pages[paid ? 'paid' : 'pending'];
      res.writeHead(200, headers);
      res.end(body);
    });
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const origin = `http://127.0.0.1:${server.address().port}`;
    browser = await chromium.launch({executablePath: process.env.WG_CHROMIUM, headless: true});
    const page = await browser.newPage({viewport: {width: 360, height: 740}, colorScheme: 'light'});
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    const action = page.getByRole('link', {name: '验证或更换邮箱'});
    await page.goto(origin + '/v1/billing/checkout/test');
    assert.equal(await action.count(), 0);
    await page.getByRole('button', {name: '查看付款结果'}).click();
    await action.waitFor({state: 'visible'});
    assert.match(await page.getByRole('status').innerText(), /30 天云同步已到账。请验证邮箱/);
    assert.equal(await action.getAttribute('href'), '/v1/auth/email');
    assert.equal(await page.getByRole('button', {name: '查看付款结果'}).count(), 0);
    if (process.env.WG_AUTH_CAPTURES) {
      await mkdir(process.env.WG_AUTH_CAPTURES, {recursive: true});
      await page.screenshot({path: path.join(process.env.WG_AUTH_CAPTURES, 'paid-checkout-mobile.png')});
    }
    paid = true;
    await page.reload();
    await action.waitFor({state: 'visible'});
    await action.click();
    await page.waitForURL(origin + '/v1/auth/email');
    assert.deepEqual(errors, []);
  } finally {
    await browser?.close();
    if (server) await new Promise(resolve => server.close(resolve));
    unlinkSync(signingKey);
    rmdirSync(temp);
  }
});
