// Run with Node and Playwright installed; set WG_CHROMIUM to use an existing
// Chromium executable, and WG_AUTH_CAPTURES to save representative PNGs.
// Local renderer/transport fixture only; account and SMTP behavior are tested separately.
const assert = require('node:assert/strict');
const {execFileSync} = require('node:child_process');
const http = require('node:http');
const {mkdir} = require('node:fs/promises');
const path = require('node:path');
const {after, before, test} = require('node:test');
const {chromium} = require('playwright');

const csrf = 'synthetic-csrf';
const samplePassword = 'test-only-passphrase-273';
const signupPasswordAtMinimum = 'Abcd1234';
const resetPasswordAtMinimum = '1234567!';
const email = 'reader@example.invalid';
const requests = [];
let server, browser, origin, pages, failures;

const fixture = String.raw`
import json, sys
from weekglass_server.auth_pages import FORM_SCRIPT_SOURCE, HANDOFF_SCRIPT_SOURCE, page

origin, csrf = sys.argv[1:]
enabled = dict(email_enabled=True, email_signup_enabled=True, email_manage_enabled=True)
masked = dict(email_hint='r***@example.invalid')
standalone = dict(management_only=True)
pending = dict(pending_email='reader@example.invalid', email_pending_editable=True,
               backup_username='wg-0123456789abcdef0123456789abcdef')

def step(action, **kwargs):
    return page(csrf, action=action, **enabled, **kwargs)

pages = {
    'default': page(csrf, **enabled),
    'selfhost': page(csrf),
    'mail_off': page(csrf, email_login_enabled=True),
    'signup_without_mail': page(csrf, email_signup_enabled=True, email_manage_enabled=True),
    'registration_closed': page(csrf, registration=False, **enabled),
    'register_weak': step('email_register', message='密码须为 8 至 128 个字符，且至少包含字母、数字、特殊字符中的两类。空白不算特殊字符。'),
    'otp_verify': step('email_otp_verify', resend_after=2, **masked),
    'otp_wrong': step('email_otp_verify', message='验证码不正确，请重试。', **masked),
    'otp_resent': step('email_otp_verify', notice='已重新发送验证码。', **masked),
    'reset_verify': step('email_reset_verify', **masked),
    'reset_finish': step('email_reset_finish'),
    'reset_done': step('login', notice='密码已更新，请重新登录。'),
    'legacy_wrong': step('legacy_login', message='账号或密码不正确。'),
    'email_wrong': step('email_login', message='邮箱或密码不正确。'),
    'pending_wrong': step('email_pending_login', message='邮箱或密码不正确。'),
    'manage': step('email_manage_begin', **standalone),
    'unpaid': step('email_manage_unverified', **pending, **standalone),
    'pending_saved': step('email_manage_unverified', **(pending | dict(pending_email='corrected@example.invalid')),
                          notice='邮箱已保存，未发送邮件。', **standalone),
    'bind_send': step('email_manage_unverified', email_paid=True, **pending, **standalone),
    'bind_verify': step('email_bind_verify', resend_after=60, **masked, **standalone),
    'bind_done': step('login', management_done=True, notice='现在可以用此邮箱登录和找回密码。', **standalone),
    'change_old_send': step('email_change_old_send', **masked, **standalone),
    'change_old_verify': step('email_change_old_verify', **masked, **standalone),
    'change_new_send': step('email_change_new_send', **standalone),
    'change_new_verify': step('email_change_new_verify', **masked, **standalone),
    'change_done': step('login', management_done=True, notice='邮箱已更换，请重新登录。', **standalone),
    'handoff': page('', handoff_url=f'{origin}/oauth/callback?code={"C"*43}&state=synthetic-state'),
}
print(json.dumps(dict(pages=pages, form=FORM_SCRIPT_SOURCE, handoff=HANDOFF_SCRIPT_SOURCE)))
`;

function respond(res, name, status=200) {
  const csp = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src "
    + (name === 'handoff' ? pages.handoff : pages.form) + "; form-action 'self'; frame-ancestors 'none'; base-uri 'none'";
  res.writeHead(status, {'Content-Type':'text/html; charset=utf-8', 'Content-Security-Policy':csp,
    'Referrer-Policy': name === 'handoff' ? 'no-referrer' : 'same-origin', 'Cache-Control':'no-store'});
  res.end(pages.pages[name]);
}

before(async () => {
  failures = [];
  server = http.createServer(async (req, res) => {
    const url = new URL(req.url, origin);
    if (url.pathname === '/oauth/callback') {
      requests.push(Object.fromEntries(url.searchParams));
      res.end('connected');
      return;
    }
    if (req.method === 'GET') {
      if (url.pathname === '/favicon.ico') { res.writeHead(204); res.end(); return; }
      respond(res, url.searchParams.get('view') ?? (url.pathname === '/v1/auth/email' ? 'manage' : 'default'));
      return;
    }
    try {
      assert.equal(req.url, '/v1/auth/authorize');
      assert.equal(req.headers.origin, origin);
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      const fields = Object.fromEntries(new URLSearchParams(Buffer.concat(chunks).toString()));
      const {action} = fields;
      assert.equal(fields.csrf, csrf);
      requests.push(fields);
      const destination = {
        email_login:'email_wrong', email_register:fields.password === '12345678' ? 'register_weak' : 'handoff',
        email_pending_login:fields.password === samplePassword ? 'handoff' : 'pending_wrong',
        email_otp_send:'otp_verify', email_otp_verify:fields.code === '123456' ? 'handoff' : 'otp_wrong',
        email_resend:'otp_resent', email_reset_send:'reset_verify',
        email_reset_verify:'reset_finish', email_reset_finish:'reset_done', login:'legacy_wrong',
        email_manage_begin:fields.identifier?.startsWith('verified-') ? 'change_old_send'
                           : fields.identifier?.startsWith('unpaid-') ? 'unpaid' : 'bind_send',
        email_pending_save:'pending_saved',
        email_bind_send:'bind_verify', email_bind_verify:'bind_done',
        email_change_old_send:'change_old_verify', email_change_old_verify:'change_new_send',
        email_change_new_send:'change_new_verify', email_change_new_verify:'change_done',
        email_cancel:'default',
      }[action];
      assert.ok(destination, `unmapped fixture step ${action}`);
      respond(res, destination, destination.endsWith('wrong') ? 401 : destination === 'register_weak' ? 400 : 200);
    } catch (error) {
      failures.push(error);
      res.writeHead(500).end();
    }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  origin = `http://127.0.0.1:${server.address().port}`;
  pages = JSON.parse(execFileSync(process.env.PYTHON || 'python', ['-c', fixture, origin, csrf],
    {cwd:path.resolve(__dirname, '..'), encoding:'utf8'}));
  browser = await chromium.launch({executablePath:process.env.WG_CHROMIUM, headless:true});
});

after(async () => {
  await browser?.close();
  if (server?.listening) await new Promise(resolve => server.close(resolve));
  assert.deepEqual(failures, []);
});

async function pageFor(t, {width=1280, height=800, colorScheme='light', javaScriptEnabled=true, view, management=false}={}) {
  const context = await browser.newContext({viewport:{width, height}, colorScheme,
    javaScriptEnabled, reducedMotion:'reduce'});
  t.after(() => context.close());
  const page = await context.newPage();
  page.setDefaultTimeout(8000);
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  page.on('console', m => {
    if (m.type() === 'error' && !m.text().match(/status of 40[01]/)) errors.push(m.text());
  });
  t.after(() => assert.deepEqual(errors, []));
  await page.goto(origin + '/v1/auth/' + (management ? 'email' : 'authorize') + (view ? '?view=' + view : ''));
  return page;
}

async function capture(page, name) {
  const output = process.env.WG_AUTH_CAPTURES;
  if (output) {
    await mkdir(output, {recursive:true});
    await page.screenshot({path:path.join(output, name + '.png'), fullPage:true});
  }
}

async function click(page, role, name) {
  await page.getByRole(role, {name, exact:true}).click();
}

async function onlyPane(page, id) {
  const visible = page.locator('.auth-views > section:visible');
  assert.equal(await visible.count(), 1);
  assert.equal(await visible.getAttribute('id'), id);
}

async function fit(page) {
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth === innerWidth));
  assert.ok(await page.locator('main .segment:visible a, main button:visible').evaluateAll(elements =>
    elements.every(el => el.getBoundingClientRect().left >= 0 && el.getBoundingClientRect().right <= innerWidth)));
}

function last(expected) {
  assert.deepEqual(requests.at(-1), {csrf, ...expected});
}

test('email registration needs one post and hands directly to PKCE even with email delivery off', async t => {
  const page = await pageFor(t, {view:'signup_without_mail'});
  await onlyPane(page, 'login');
  assert.equal(await page.getByRole('link', {name:'邮箱验证码'}).count(), 0);
  await page.keyboard.press('Tab');
  await page.keyboard.press('Tab');
  assert.equal(await page.locator(':focus').innerText(), '注册');
  await page.keyboard.press('Enter');
  await onlyPane(page, 'register');
  assert.equal(await page.getByRole('link', {name:'注册', exact:true}).getAttribute('aria-current'), 'page');
  assert.equal(await page.getByRole('button', {name:'发送验证码'}).count(), 0);
  await page.locator('#register-email').fill(email);
  await page.locator('#register-password').fill(signupPasswordAtMinimum);
  await page.locator('#register-confirm').fill(signupPasswordAtMinimum);
  await click(page, 'button', '显示');
  assert.equal(await page.locator('#register-password').getAttribute('type'), 'text');
  await click(page, 'button', '隐藏');
  let readPending;
  const pending = new Promise(resolve => { readPending = resolve; });
  await page.exposeFunction('readPending', readPending);
  await page.evaluate(() => document.addEventListener('submit', ({target}) => {
    const button = target.querySelector('button[type="submit"]');
    const status = target.querySelector('[data-submit-status]');
    window.readPending([button.textContent, button.disabled, status.textContent, status.hidden]);
  }, {once:true}));
  const seen = requests.length;
  await click(page, 'button', '注册并连接');
  assert.deepEqual(await pending, ['正在创建账号…', true, '正在安全提交，请稍候。', false]);
  await page.waitForURL('**/oauth/callback?**');
  assert.equal(requests.length, seen + 2);
  assert.ok(!(await page.content()).includes(signupPasswordAtMinimum));
  assert.ok(!(await page.content()).includes(email));
  assert.deepEqual(requests.at(-2), {action:'email_register', csrf, email,
    password:signupPasswordAtMinimum, confirm_password:signupPasswordAtMinimum});
  assert.deepEqual(requests.at(-1), {code:'C'.repeat(43), state:'synthetic-state'});
});

test('signup guidance explains the password classes and keeps the error in the signup pane', async t => {
  const page = await pageFor(t, {view:'signup_without_mail'});
  await click(page, 'link', '注册');
  await page.locator('#register-email').fill(email);
  assert.match(await page.locator('#register-password-help').innerText(), /8 至 128.*字母、数字、特殊字符中的两类/);
  await page.locator('#register-password').fill('12345678');
  await page.locator('#register-confirm').fill('12345678');
  await click(page, 'button', '注册并连接');
  await onlyPane(page, 'register');
  assert.match(await page.getByRole('alert').innerText(), /空白不算特殊字符/);
});

test('email OTP shows cooldown, sends resend alone, and keeps errors on the verify page', async t => {
  const page = await pageFor(t, {width:320, height:700, colorScheme:'dark'});
  await click(page, 'link', '邮箱验证码');
  await onlyPane(page, 'otp');
  await page.locator('#otp-email').fill(email);
  await click(page, 'button', '发送验证码');
  await page.getByRole('heading', {name:'输入验证码'}).waitFor();
  last({action:'email_otp_send', email});
  const resend = page.getByRole('button', {name:/重新发送/});
  assert.ok(await resend.isDisabled());
  await fit(page);
  await resend.click(); // Playwright waits for cooldown; no fixed sleep.
  await page.getByText('已重新发送验证码。', {exact:true}).waitFor();
  last({action:'email_resend'});
  await page.locator('#verify-code').fill('111111');
  await click(page, 'button', '验证并连接');
  await page.getByRole('alert').waitFor();
  assert.equal(await page.getByRole('alert').innerText(), '验证码不正确，请重试。');
  last({action:'email_otp_verify', code:'111111'});
  await capture(page, 'otp-error-mobile-dark');
});

test('email recovery for eligible accounts posts only the inputs for each step', async t => {
  const page = await pageFor(t, {width:320, height:700});
  const fill = (selector, value) => page.locator(selector).fill(value);
  const next = async (label, heading, expected) => {
    await click(page, 'button', label);
    await page.getByRole('heading', {name:heading, exact:true}).waitFor();
    last(expected);
    await fit(page);
  };
  await click(page, 'link', '忘记密码');
  await fill('#reset-email', email);
  await next('发送验证码', '验证邮箱', {action:'email_reset_send', email});
  await fill('#verify-code', '123456');
  await next('验证验证码', '设置新密码', {action:'email_reset_verify', code:'123456'});
  await capture(page, 'email-reset-mobile-light');
  await fill('#reset-finish-password', resetPasswordAtMinimum);
  await fill('#reset-finish-confirm', resetPasswordAtMinimum);
  await next('保存新密码', '连接 WeekGlass', {
    action:'email_reset_finish', password:resetPasswordAtMinimum, confirm_password:resetPasswordAtMinimum});
});

async function manage(page, identity_kind, identifier, heading) {
  await page.getByLabel('账号类型', {exact:true}).selectOption(identity_kind);
  await page.locator('#manage-identifier').fill(identifier);
  await page.locator('#manage-password').fill(samplePassword);
  await click(page, 'button', '确认身份');
  await page.getByRole('heading', {name:heading, exact:true}).waitFor();
  last({action:'email_manage_begin', identity_kind, identifier, password:samplePassword});
}

test('standalone verification accepts the current or replacement address for paid accounts without PKCE', async t => {
  const page = await pageFor(t, {width:320, height:700, colorScheme:'dark', management:true});
  assert.equal(await page.getByRole('link', {name:'注册', exact:true}).count(), 0);
  await manage(page, 'pending_email', email, '验证邮箱');
  assert.equal(await page.locator('#bind-email').inputValue(), email);
  assert.equal(await page.getByRole('button', {name:'跳过并连接'}).count(), 0);
  await fit(page);
  await capture(page, 'paid-verification-mobile-dark');
  const replacement = 'next@example.invalid';
  await page.locator('#bind-email').fill(replacement);
  await click(page, 'button', '发送验证码');
  await page.getByRole('textbox', {name:'验证码', exact:true}).waitFor();
  last({action:'email_bind_send', email:replacement});
  assert.equal(await page.getByRole('button', {name:/重新发送/}).isDisabled(), true);
  await page.locator('#verify-code').fill('123456');
  await click(page, 'button', '确认验证');
  await page.getByRole('heading', {name:'邮箱已验证', exact:true}).waitFor();
  last({action:'email_bind_verify', code:'123456'});
  assert.equal(await page.locator('form').count(), 0);
  assert.equal(await page.locator('#handoff-link').count(), 0);
});

test('a verified account proves its old and new addresses to replace a verified address', async t => {
  const page = await pageFor(t, {width:320, height:700, management:true});
  const fill = (selector, value) => page.locator(selector).fill(value);
  const next = async (label, heading, expected) => {
    await click(page, 'button', label);
    await page.getByRole('heading', {name:heading, exact:true}).waitFor();
    last(expected);
    await fit(page);
  };
  await manage(page, 'email', 'verified-reader@example.invalid', '验证原邮箱');
  await next('发送验证码', '验证原邮箱', {action:'email_change_old_send'});
  await fill('#verify-code', '123456');
  await next('验证原邮箱', '输入新邮箱', {action:'email_change_old_verify', code:'123456'});
  await capture(page, 'change-email-mobile-light');
  const newEmail = 'next@example.invalid';
  await fill('#change-email', newEmail);
  await next('发送验证码', '验证新邮箱', {action:'email_change_new_send', email:newEmail});
  await fill('#verify-code', '123456');
  await next('确认更换', '邮箱已验证', {action:'email_change_new_verify', code:'123456'});
});

test('an unpaid account can correct a pending address, with no verification controls or mail', async t => {
  const page = await pageFor(t, {width:320, height:700, management:true});
  await manage(page, 'username', 'unpaid-legacy-fallback', '邮箱尚未验证');
  assert.equal(await page.getByRole('button', {name:'发送验证码'}).count(), 0);
  assert.equal(await page.locator('[aria-label="备用账号标识"]').innerText(), 'wg-0123456789abcdef0123456789abcdef');
  await fit(page);
  const corrected = 'corrected@example.invalid';
  await page.locator('#pending-email').fill(corrected);
  await page.locator('#pending-password').fill(samplePassword);
  await click(page, 'button', '保存邮箱');
  await page.getByText('邮箱已保存，未发送邮件。', {exact:true}).waitFor();
  last({action:'email_pending_save', email:corrected, password:samplePassword});
  assert.equal(await page.locator('#pending-email').inputValue(), corrected);
});

test('legacy account and recovery remain reachable without mail or JavaScript', async t => {
  const page = await pageFor(t, {javaScriptEnabled:false, width:320, height:700, view:'selfhost'});
  await onlyPane(page, 'login');
  assert.equal(await page.getByRole('link', {name:'邮箱验证码'}).count(), 0);
  await click(page, 'link', '注册');
  await onlyPane(page, 'register');
  assert.equal(await page.locator('#register input[name="action"]').inputValue(), 'register');
  assert.equal(await page.locator('#register-password').getAttribute('minlength'), '16');
  await click(page, 'link', '登录');
  await click(page, 'link', '忘记密码');
  await onlyPane(page, 'recover');
  assert.equal(await page.getByLabel('恢复码', {exact:true}).getAttribute('name'), 'recovery_key');
  assert.equal(await page.locator('#recover-password').getAttribute('minlength'), '16');
  await fit(page);

  await page.goto(origin + '/v1/auth/authorize?view=registration_closed');
  assert.equal(await page.getByRole('link', {name:'注册', exact:true}).count(), 0);
  await click(page, 'link', '使用原账号');
  await onlyPane(page, 'legacy');
  await page.locator('#legacy-username').fill('email-shaped@example.invalid');
  await page.locator('#legacy-password').fill(samplePassword);
  await click(page, 'button', '登录并连接');
  last({action:'login', username:'email-shaped@example.invalid', password:samplePassword});
  await onlyPane(page, 'legacy');
  await page.getByRole('alert').waitFor();

  await page.goto(origin + '/v1/auth/authorize?view=mail_off');
  assert.equal(await page.getByRole('link', {name:'邮箱验证码'}).count(), 0);
  assert.equal(await page.getByRole('link', {name:'验证或更换邮箱'}).count(), 0);
  assert.equal(await page.locator('#login-password').getAttribute('minlength'), null);
  await page.locator('#login-email').fill(email);
  await page.locator('#login-password').fill(samplePassword);
  await click(page, 'button', '登录并连接');
  last({action:'email_login', email, password:samplePassword});
  await onlyPane(page, 'login');
  await page.getByRole('alert').waitFor();
  await page.goto(origin + '/v1/auth/authorize?view=mail_off');
  await click(page, 'link', '忘记密码');
  assert.equal(await page.getByLabel('WeekGlass 账号或邮箱').getAttribute('maxlength'), '254');
  assert.equal(await page.locator('#recover-password').getAttribute('minlength'), '8');
  assert.equal(await page.locator('#recover-password').getAttribute('maxlength'), '1024');
  assert.match(await page.locator('#recover-password-help').innerText(), /原账号：至少 16 个字符/);
});

test('pending email password login is explicit and never uses the ordinary email action', async t => {
  const page = await pageFor(t, {width:320, height:700, view:'mail_off'});
  await click(page, 'link', '使用未验证邮箱');
  await onlyPane(page, 'pending-login');
  await fit(page);
  await capture(page, 'pending-email-mobile-light');
  async function signIn(password) {
    await page.getByLabel('未验证邮箱', {exact:true}).fill(email);
    await page.locator('#pending-login-password').fill(password);
    await click(page, 'button', '登录并连接');
  }
  const wrong = 'a-different-test-password';
  await signIn(wrong);
  await page.getByRole('alert').waitFor();
  await onlyPane(page, 'pending-login');
  last({action:'email_pending_login', email, password:wrong});
  await signIn(samplePassword);
  await page.waitForURL('**/oauth/callback?**');
  assert.deepEqual(requests.at(-2), {action:'email_pending_login', csrf, email, password:samplePassword});
});

test('registration data entry remains legible on a 320px screen', async t => {
  const page = await pageFor(t, {width:320, height:700, colorScheme:'dark'});
  await click(page, 'link', '注册');
  await fit(page);
  await capture(page, 'registration-mobile-dark');
  const desktop = await pageFor(t);
  await capture(desktop, 'login-light');
});
