// Behavior tests for the exact CSP-hashed scripts, without browser dependencies.
// Real Chromium navigation/CSP enforcement is separately exercised by browser QA.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../weekglass_server/auth_pages.py'), 'utf8');
const password = source.match(/PASSWORD_SCRIPT = """([\s\S]*?)"""/)[1];
const formScript = password + source.match(/FORM_SCRIPT = PASSWORD_SCRIPT \+ r"""([\s\S]*?)"""/)[1];
const handoffScript = source.match(/HANDOFF_SCRIPT = r"""([\s\S]*?)"""/)[1];

function clock() {
  const pending = new Map(), listeners = new Map();
  let sequence = 0;
  return {
    pending, listeners,
    setTimeout(callback, delay) { const id = ++sequence; pending.set(id, { callback, delay }); return id; },
    clearTimeout(id) { pending.delete(id); },
    addEventListener(name, callback) { listeners.set(name, callback); },
  };
}

function form(action) {
  const attributes = {}, listeners = new Map();
  const button = { textContent: `${action} ready`, disabled: false, dataset: {} };
  const status = { hidden: true, textContent: '' };
  const input = { value: 'synthetic-secret', disabled: false };
  return {
    action, attributes, button, status, input,
    setAttribute(name, value) { attributes[name] = value; },
    removeAttribute(name) { delete attributes[name]; },
    querySelectorAll(selector) { assert.equal(selector, 'button[type="submit"]'); return [button]; },
    querySelector(selector) {
      if (selector === 'button[type="submit"]') return button;
      if (selector === '[data-submit-status]') return status;
      if (selector === 'input[name="action"]') return { value: action };
      throw new Error('unexpected selector');
    },
    addEventListener(name, callback) { listeners.set(name, callback); },
    submit() {
      const event = { defaultPrevented: false, preventDefault() { this.defaultPrevented = true; } };
      listeners.get('submit')(event);
      return event;
    },
  };
}

function formsFixture() {
  const forms = ['login', 'register', 'recover', 'continue'].map(form);
  const window = clock();
  const document = { querySelectorAll(selector) {
    if (selector === '[data-password-toggle]') return [];
    assert.equal(selector, 'form[data-auth-form]'); return forms;
  } };
  vm.runInNewContext(formScript, { document, window });
  return { forms, window };
}

test('submit shows progress, preserves input controls and prevents duplicate submits', () => {
  const { forms, window } = formsFixture();
  assert.equal(forms[0].submit().defaultPrevented, false);
  assert.equal(forms[0].attributes['aria-busy'], 'true');
  assert.equal(forms[0].button.textContent, '正在验证…');
  assert.equal(forms[0].status.hidden, false);
  for (const item of forms) {
    assert.equal(item.button.disabled, true);
    assert.equal(item.input.disabled, false);
    assert.equal(item.input.value, 'synthetic-secret');
    assert.equal(item.submit().defaultPrevented, true);
  }
  assert.equal(window.pending.size, 1);
  const timer = [...window.pending.values()][0];
  assert.equal(timer.delay, 15000);
  timer.callback();
  assert.match(forms[0].status.textContent, /服务器仍未返回结果.*请勿重复提交/);
  assert.equal(forms[0].button.disabled, true);
  assert.equal(window.pending.size, 1, 'timeout never retries credentials');
});

test('history restore resets busy state and permits a deliberate new submission', () => {
  const { forms, window } = formsFixture();
  forms[2].submit();
  assert.equal(forms[2].button.textContent, '正在重设密码…');
  window.listeners.get('pageshow')({ persisted: true });
  assert.equal(window.pending.size, 0);
  for (const item of forms) {
    assert.equal(item.button.disabled, false);
    assert.equal(item.button.textContent, `${item.action} ready`);
    assert.equal(item.attributes['aria-busy'], undefined);
    assert.equal(item.status.hidden, true);
  }
  assert.equal(forms[3].submit().defaultPrevented, false);
  assert.equal(forms[3].button.textContent, '正在连接…');
});

function handoffFixture(href, blocked = false) {
  const attributes = {};
  const listeners = new Map();
  const link = { href,
    removeAttribute(name) { if (name === 'href') this.href = undefined; },
    setAttribute(name, value) { attributes[name] = value; },
    addEventListener(name, callback) { listeners.set(name, callback); },
    click() { listeners.get('click')(); },
  };
  const status = { textContent: '正在返回 WeekGlass 完成设备连接…' };
  const navigations = [];
  const window = clock();
  window.location = { replace(target) {
    if (blocked) throw new Error('synthetic blocked navigation');
    navigations.push(target);
  } };
  const document = { getElementById(id) { return id === 'handoff-link' ? link : status; } };
  vm.runInNewContext(handoffScript, { document, window, URL });
  return { link, attributes, status, window, navigations };
}

const target = `http://127.0.0.1:54321/oauth/callback?code=${'C'.repeat(43)}&state=synthetic-state%26safe`;
test('handoff reads the DOM URL and performs exactly one navigation after feedback can paint', () => {
  const fixture = handoffFixture(target);
  assert.equal(fixture.navigations.length, 0);
  assert.equal(fixture.window.pending.size, 1);
  const timer = [...fixture.window.pending.values()][0];
  assert.equal(timer.delay, 350);
  timer.callback();
  assert.deepEqual(fixture.navigations, [target]);
  assert.equal(fixture.link.href, target, 'manual fallback remains available');
});

test('blocked automatic navigation leaves explicit manual fallback', () => {
  const fixture = handoffFixture(target, true);
  [...fixture.window.pending.values()][0].callback();
  assert.equal(fixture.navigations.length, 0);
  assert.equal(fixture.link.href, target);
  assert.match(fixture.status.textContent, /浏览器未能自动返回.*点击下方按钮/);
});

test('manual return cancels the pending automatic navigation without removing fallback', () => {
  const fixture = handoffFixture(target);
  fixture.link.click();
  assert.equal(fixture.window.pending.size, 0);
  assert.equal(fixture.navigations.length, 0);
  assert.equal(fixture.link.href, target, 'the browser can follow the ordinary anchor');
});

for (const invalid of [
  target.replace('127.0.0.1', 'attacker.example'),
  target.replace('http:', 'https:'),
  target.replace(':54321', ':80'),
  target.replace('/oauth/callback', '/other'),
  target + '&access_token=not-a-token',
  target + '&code=duplicate',
  target + '#fragment',
  'javascript:alert(1)',
]) {
  test(`invalid handoff is disabled without navigation: ${invalid.slice(0, 40)}`, () => {
    const fixture = handoffFixture(invalid);
    assert.equal(fixture.window.pending.size, 0);
    assert.equal(fixture.link.href, undefined);
    assert.equal(fixture.attributes['aria-disabled'], 'true');
    assert.match(fixture.status.textContent, /连接地址无效/);
  });
}
