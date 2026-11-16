// Exercise the production same-origin export script without a browser dependency.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../weekglass_server/console_style.py'), 'utf8');
const script = source.match(/CALENDAR_JS = r'''([\s\S]*?)'''/)[1];
const base = '/account/calendar/';
const claim = '9fd1b61a-70bb-42fd-9223-861c3ed10afa';

function controls({truncated = false, unconfirmed = false} = {}) {
  const events = [], requests = [];
  const start = {hidden: false, addEventListener(_, fn) {this.click = fn;}};
  const confirm = {hidden: true, addEventListener(_, fn) {this.click = fn;}};
  const save = {hidden: true, click() {events.push(this.href);}};
  const intro = {hidden: false};
  const status = {textContent: ''};
  const elements = {'[data-prepare]':start, '[data-confirm]':confirm, '[data-save]':save,
    '[data-export-status]':status, '[data-export-intro]':intro};
  const document = {querySelector: () => ({dataset:{csrf:'test-only'}, querySelector: key => elements[key]})};
  const fetch = async (url, options) => {
    assert.equal(options.method, 'POST');
    assert.equal(options.credentials, 'same-origin');
    assert.equal(options.headers['X-WeekGlass-CSRF'], 'test-only');
    const operation = url.replace(base, '');
    requests.push(operation);
    if (operation === 'prepare') return {ok:true, json:async () => ({export_id:claim})};
    if (operation === claim + '/download') {
      const size = truncated ? (truncated = false, 0) : 13;
      return {ok:true, headers:{get: () => '13'}, blob:async () => ({size})};
    }
    assert.equal(operation, claim + '/complete');
    if (unconfirmed) {
      unconfirmed = false;
      throw Error('synthetic connection loss');
    }
    return {ok:true};
  };
  vm.runInNewContext(script, {document, fetch, URL:{createObjectURL: () => 'blob:the-same-calendar'}});
  return {start, save, confirm, intro, status, events, requests};
}

test('a complete transfer downloads and consumes once; local resave does not request data', async () => {
  const {start, save, confirm, intro, status, events, requests} = controls();
  await start.click();
  assert.deepEqual(requests, ['prepare', claim + '/download', claim + '/complete']);
  assert.equal(start.hidden, true);
  assert.equal(intro.hidden, true);
  assert.equal(confirm.hidden, true);
  assert.equal(save.hidden, false);
  assert.match(status.textContent, /请妥善保存/);
  save.click();
  assert.deepEqual(events, ['blob:the-same-calendar', 'blob:the-same-calendar']);
  assert.equal(requests.length, 3);
});

test('a truncated transfer never consumes and retries the same claim', async () => {
  const {start, save, status, requests} = controls({truncated:true});
  await start.click();
  assert.match(status.textContent, /导出机会仍保留/);
  assert.equal(save.hidden, true);
  assert.deepEqual(requests, ['prepare', claim + '/download']);
  await start.click();
  assert.deepEqual(requests, ['prepare', claim + '/download', 'prepare', claim + '/download', claim + '/complete']);
});

test('a lost completion response can retry without retransferring the calendar', async () => {
  const {start, confirm, status, requests} = controls({unconfirmed:true});
  await start.click();
  assert.equal(confirm.hidden, false);
  assert.match(status.textContent, /无需重新下载/);
  await confirm.click();
  assert.equal(confirm.hidden, true);
  assert.deepEqual(requests, ['prepare', claim + '/download', claim + '/complete', claim + '/complete']);
});
