import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash, generateKeyPairSync, sign, verify } from 'node:crypto';
import { mkdtempSync, rmdirSync, unlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { runBridge } from './bridge.mjs';

const id = (prefix) => `${prefix}_12345678901234567890Ab`;
const store = id('STO');
const merchant = id('MER');
const product = id('PROD');
const annualProduct = 'PROD_ABCDEFGHIJKLMNOPQRSTUV';
const payment = id('PAY');
const refund = id('REF');
const reference = 'a5766fc2-4063-43f6-8d06-ef9982d8ce0c';
const session = 'cs_330f1021-2855-4161-8719-25a9423b9e37';
const expiresAt = () => new Date(Date.now() + 900000).toISOString();
const recorded = '2026-11-13T08:09:10.123456Z';

const directory = mkdtempSync(fileURLToPath(new URL('./.test-fixtures-', import.meta.url)));
const keyFile = join(directory, 'synthetic-test.pem');
const keys = generateKeyPairSync('rsa', { modulusLength: 2048 });
writeFileSync(keyFile, keys.privateKey.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600 });
after(() => { unlinkSync(keyFile); rmdirSync(directory); });

const env = {
  WEEKGLASS_WAFFO_STORE_ID: store,
  WEEKGLASS_WAFFO_MERCHANT_ID: merchant,
  WEEKGLASS_WAFFO_PRIVATE_KEY_FILE: keyFile,
};
const liveEnv = {
  WEEKGLASS_WAFFO_MODE: 'prod',
  WEEKGLASS_WAFFO_LIVE_MERCHANT_ID: merchant,
  WEEKGLASS_WAFFO_LIVE_STORE_ID: store,
  WEEKGLASS_WAFFO_LIVE_PRODUCT_ID: product,
  WEEKGLASS_WAFFO_LIVE_PRIVATE_KEY_FILE: keyFile,
};
const catalog = {
  store: { id: store, status: 'active', slug: 'weekglass-test' },
  onetimeProducts: [{ id: product, status: 'active', hasProdVersion: false, prices: [
    { currency: 'CNY', priceInfo: { amount: '29.00', taxCategory: 'saas' } },
    { currency: 'USD', priceInfo: { amount: '5.00', taxCategory: 'saas' } },
  ] }],
};
const catalogInput = { op: 'catalog', product_id: product, currency: 'CNY' };
const createInput = { ...catalogInput, op: 'create_checkout', amount: '29.00', external_order_id: reference };
const queryInput = { op: 'query_order', external_order_id: reference };
const liveCreate = { ...createInput, amount: '1.00' };
const liveUrl = `https://pancake.waffo.ai/store/weekglass-test/checkout/${session}`;

function response(data) {
  return Response.json({ data });
}

function mockProvider(...responses) {
  const requests = [];
  return {
    requests,
    options: { env, fetch: async (address, init) => {
      requests.push({ address, ...init });
      const next = responses.shift();
      if (next instanceof Error) throw next;
      return next;
    } },
  };
}

function inspectSigned(request, path) {
  assert.equal(request.address, `https://api.waffo.ai${path}`);
  assert.equal(request.method, 'POST');
  assert.equal(request.redirect, 'error');
  assert.equal(request.headers['X-Merchant-Id'], merchant);
  assert.match(request.headers['X-Timestamp'], /^[0-9]+$/);
  const bodyDigest = createHash('sha256').update(request.body).digest('base64');
  const canonical = `POST\n${path}\n${request.headers['X-Timestamp']}\n${bodyDigest}`;
  assert(verify('RSA-SHA256', Buffer.from(canonical), keys.publicKey, Buffer.from(request.headers['X-Signature'], 'base64')));
  return JSON.parse(request.body);
}

test('saved private key accepts the SDK text formats without exposing the contents', async () => {
  const pkcs8 = keys.privateKey.export({ type: 'pkcs8', format: 'pem' });
  const cases = [
    pkcs8.replace(/\n/g, '\\n'),
    keys.privateKey.export({ type: 'pkcs8', format: 'der' }).toString('base64'),
    keys.privateKey.export({ type: 'pkcs1', format: 'der' }).toString('base64'),
    keys.privateKey.export({ type: 'pkcs1', format: 'pem' }).replace(/\n/g, '\r\n'),
    keys.publicKey.export({ type: 'spki', format: 'pem' }),
  ];
  for (const [index, content] of cases.entries()) {
    const alternate = join(directory, 'alternate.pem');
    writeFileSync(alternate, content, { mode: 0o600 });
    try {
      const { options, requests } = mockProvider(response(catalog));
      const result = await runBridge(catalogInput, {
        ...options, env: { ...env, WEEKGLASS_WAFFO_PRIVATE_KEY_FILE: alternate },
      });
      if (index === cases.length - 1) {
        assert.deepEqual(result, { ok: false, error: 'credentials_unavailable' });
        assert.equal(requests.length, 0);
      } else {
        assert.equal(result.ok, true);
        inspectSigned(requests[0], '/v1/graphql');
      }
    } finally {
      unlinkSync(alternate);
    }
  }
});

test('checkout uses the official SDK to sign the test-product preflight and tax-inclusive session', async () => {
  const expires = expiresAt();
  const url = `https://pancake.waffo.ai/store/weekglass-test/checkout/${session}?test=true`;
  const { requests, options } = mockProvider(response(catalog), response({
    sessionId: session, checkoutUrl: url, expiresAt: expires, apiKey: 'must-not-leak',
  }));
  assert.deepEqual(await runBridge(createInput, options), { ok: true, result: {
    session_id: session, checkout_url: url, expires_at: expires,
  } });
  assert.equal(requests.length, 2);
  const preflight = inspectSigned(requests[0], '/v1/graphql');
  assert.deepEqual(preflight.variables, { storeId: store, productId: product });
  assert.match(preflight.query, /onetimeProducts/);
  assert.match(preflight.query, /hasProdVersion/);
  assert.equal(requests[0].headers['X-Idempotency-Key'], undefined);
  const create = inspectSigned(requests[1], '/v1/actions/checkout/create-session');
  assert.equal(requests[1].headers['X-Idempotency-Key'], `weekglass-test-checkout-${reference}`);
  assert.deepEqual(create, {
    productId: product, currency: 'CNY', priceSnapshot: { amount: '29.00', taxIncluded: true, taxCategory: 'saas' },
    orderMerchantExternalId: reference, metadata: { weekglass_product_id: product },
    expiresInSeconds: 900, allowPromotionCodes: false,
  });
});

test('test USD card diagnostic is explicit; catalog keeps product price and checkout accepts the second documented host', async () => {
  let mock = mockProvider(response(catalog));
  assert.deepEqual(await runBridge(catalogInput, mock.options), { ok: true, result: {
    product_id: product, store_id: store, currency: 'CNY', amount: '29.00', test_mode: true,
    tax_included: false, tax_category: 'saas',
  } });
  mock = mockProvider(response(catalog), response({ sessionId: session,
    checkoutUrl: `https://checkout.waffo.ai/weekglass-test/checkout/${session}`, expiresAt: expiresAt() }));
  assert.equal((await runBridge({ ...createInput, currency: 'USD', amount: '5.00' }, mock.options)).ok, true);
  assert.deepEqual(inspectSigned(mock.requests[1], '/v1/actions/checkout/create-session').includePaymentMethods, ['card']);
});

test('published or unconfirmed catalog state, inactive or wrong store, and missing price prevent a write', async () => {
  for (const [mutate, error] of [
    [(v) => { v.onetimeProducts[0].hasProdVersion = true; }, 'catalog_product_not_test_only'],
    [(v) => { delete v.onetimeProducts[0].hasProdVersion; }, 'catalog_product_not_test_only'],
    [(v) => { v.onetimeProducts[0].status = 'inactive'; }, 'catalog_product_unavailable'],
    [(v) => { v.store.id += 'x'; }, 'catalog_store_unavailable'],
    [(v) => { v.onetimeProducts[0].prices.shift(); }, 'catalog_price_unavailable'],
  ]) {
    const data = structuredClone(catalog);
    mutate(data);
    const mock = mockProvider(response(data));
    assert.deepEqual(await runBridge(createInput, mock.options), { ok: false, error });
    assert.equal(mock.requests.length, 1);
  }
});

test('checkout rejects other domains, sessions or lifetimes and never repeats an ambiguous write', async () => {
  for (const change of [
    { checkoutUrl: `https://pancake.waffo.ai.example.test/store/weekglass-test/checkout/${session}` },
    { checkoutUrl: `https://pancake.waffo.ai/store/wrong-store/checkout/${session}` },
    { checkoutUrl: `https://pancake.waffo.ai/store/weekglass-test/checkout/${session}?test=false` },
    { checkoutUrl: `https://pancake.waffo.ai/store/weekglass-test/checkout/${session}#sensitive` },
    { sessionId: 'not-a-session' },
    { expiresAt: '2099-01-01T00:00:00Z' },
  ]) {
    const mock = mockProvider(response(catalog), response({ sessionId: session,
      checkoutUrl: `https://pancake.waffo.ai/store/weekglass-test/checkout/${session}`,
      expiresAt: expiresAt(), ...change }));
    assert.deepEqual(await runBridge(createInput, mock.options), { ok: false, error: 'provider_response_invalid' });
    assert.equal(mock.requests.length, 2);
  }
  const timeout = mockProvider(response(catalog), new Error('includes-provider-details'));
  assert.deepEqual(await runBridge(createInput, timeout.options), { ok: false, error: 'provider_unavailable' });
  assert.equal(timeout.requests.length, 2);
});

function orderFacts() {
  return {
    id: id('ORD'), orderMerchantExternalId: reference, status: 'completed', testMode: true, currency: 'CNY',
    store: { id: store }, onetimeProduct: { id: product }, priceSnapshot: { currency: 'CNY', total: '29.00' },
    buyerEmail: 'private@example.test', payments: [{
      id: payment, status: 'succeeded', refundStatus: 'refunded', testMode: true, createdAt: recorded,
      amount: '29.00', pspAmountDetails: { amount: '27.00', currency: 'CNY', settlementAmount: '30.60', settlementCurrency: 'HKD' },
      refunds: [{ id: refund, status: 'succeeded', refundTicketMerchantExternalId: 'test-ref-42',
        createdAt: recorded, pspAmountDetails: { amount: '9.00', currency: 'CNY' }, requestedAmountDetails: { amount: '10.00' } }],
    }],
  };
}

test('signed query keeps actual CNY charge separate from quote and settlement, and uses executed PSP refund', async () => {
  const { requests, options } = mockProvider(response({ onetimeOrders: [orderFacts()] }));
  assert.deepEqual(await runBridge(queryInput, options), { ok: true, result: { order: {
    provider_order_id: id('ORD'), external_order_id: reference, product_id: product, store_id: store,
    currency: 'CNY', amount: '29.00', status: 'completed', test_mode: true, payments: [{
      provider_payment_id: payment, status: 'succeeded', amount: '27.00', currency: 'CNY',
      created_at: recorded, refund_status: 'refunded', refunds: [{
        provider_refund_id: refund, merchant_refund_id: 'test-ref-42', status: 'succeeded', amount: '9.00',
        currency: 'CNY', created_at: recorded,
      }],
    }],
  } } });
  const query = inspectSigned(requests[0], '/v1/graphql');
  assert.deepEqual(query.variables, { storeId: store, reference });
  assert.match(query.query, /id status refundStatus testMode createdAt/);
  assert.match(query.query, /pspAmountDetails \{ amount currency \}/);
  assert.doesNotMatch(query.query, /buyerEmail|snapshotAmountDetails|requestedAmountDetails/);
});

test('a missing actual charge stays unknown and order lookup does not accept production, mismatched or ambiguous orders', async () => {
  const data = orderFacts();
  data.payments[0].pspAmountDetails = null;
  let mock = mockProvider(response({ onetimeOrders: [data] }));
  const unknown = (await runBridge(queryInput, mock.options)).result.order.payments[0];
  assert.equal(unknown.amount, null);
  assert.equal(unknown.currency, null);
  mock = mockProvider(response({ onetimeOrders: [] }));
  assert.deepEqual(await runBridge(queryInput, mock.options), { ok: true, result: { order: null } });
  for (const orders of [[{ ...data, testMode: false }], [{ ...data, orderMerchantExternalId: 'other' }], [data, data]]) {
    mock = mockProvider(response({ onetimeOrders: orders }));
    const result = await runBridge(queryInput, mock.options);
    assert.equal(result.ok, false);
    assert.equal(result.error, orders.length === 2 ? 'ambiguous_order' : 'unexpected_order');
  }
  mock = mockProvider(response({ onetimeOrders: [{ ...data, payments: [{ ...data.payments[0], testMode: false }] }] }));
  assert.deepEqual(await runBridge(queryInput, mock.options), { ok: false, error: 'unexpected_order' });
  data.payments[0].refunds = [];
  mock = mockProvider(response({ onetimeOrders: [data] }));
  assert.deepEqual(await runBridge(queryInput, mock.options), { ok: false, error: 'provider_response_invalid' });
});

test('provider error bodies are not reflected in responses', async () => {
  const auth = mockProvider(Response.json({ errors: [{ message: 'sensitive' }] }, { status: 401 }));
  assert.deepEqual(await runBridge(catalogInput, auth.options), { ok: false, error: 'provider_authentication' });
  const partial = mockProvider(Response.json({ data: catalog, errors: [{ message: 'sensitive' }] }));
  assert.deepEqual(await runBridge(catalogInput, partial.options), { ok: false, error: 'provider_query_failed' });
  const rejected = mockProvider(Response.json({ errors: [{ message: 'sensitive' }] }, { status: 400 }));
  assert.deepEqual(await runBridge(catalogInput, rejected.options), { ok: false, error: 'provider_query_failed' });
});

function webhook(payload, signatureTime = Date.now()) {
  const body = ` ${JSON.stringify(payload, null, 2)}\n`;
  const signature = sign('RSA-SHA256', Buffer.from(`${signatureTime}.${body}`), keys.privateKey).toString('base64');
  return { op: 'verify_webhook', signature: `t=${signatureTime},v1=${signature}`, body_base64: Buffer.from(body).toString('base64') };
}

test('SDK verifies exact webhook bytes, rejects a wrong/expired signature or non-test scope, and strips private fields', async () => {
  const payload = { id: payment, eventId: payment, eventType: 'order.completed', timestamp: recorded,
    storeId: store, mode: 'test', data: { orderId: id('ORD'), paymentId: payment, orderStatus: 'completed',
      paymentStatus: 'succeeded', currency: 'CNY', amount: '29.00', chargedAmount: '27.00', buyerEmail: '买家@example.test',
      orderMerchantExternalId: reference, orderMetadata: { weekglass_product_id: product, privateNote: 'remove' } } };
  const input = webhook(payload);
  const verifyTestWebhook = (body, signature, sdk) => sdk.verifyWebhook(body, signature, {
    publicKey: keys.publicKey.export({ type: 'spki', format: 'pem' }),
  });
  const options = { env, verifyTestWebhook };
  assert.deepEqual(await runBridge(input, options), { ok: true, result: { payload: {
    ...payload, data: { orderId: id('ORD'), paymentId: payment, orderStatus: 'completed', paymentStatus: 'succeeded',
      currency: 'CNY', chargedAmount: '27.00', orderMerchantExternalId: reference, orderMetadata: { weekglass_product_id: product } },
  } } });
  const changed = { ...input, body_base64: Buffer.from(JSON.stringify(payload)).toString('base64') };
  for (const wrong of [changed, webhook({ ...payload, mode: 'prod' }), webhook({ ...payload, storeId: `${store}x` }),
    webhook(payload, Date.now() - 46 * 60 * 1000), { ...input, body_base64: 'abcd-invalid!' }]) {
    assert.deepEqual(await runBridge(wrong, options), { ok: false, error: 'invalid_webhook' });
  }
  assert.deepEqual(await runBridge(input, { env }), { ok: false, error: 'invalid_webhook' });
  const bridge = fileURLToPath(new URL('./bridge.mjs', import.meta.url));
  const withOverride = spawnSync(process.execPath, [bridge], { input: JSON.stringify(input), encoding: 'utf8',
    env: { ...env, WAFFO_WEBHOOK_TEST_PUBLIC_KEY: keys.publicKey.export({ type: 'spki', format: 'pem' }) } });
  assert.deepEqual(JSON.parse(withOverride.stdout), { ok: false, error: 'webhook_key_override_forbidden' });
  assert.equal(withOverride.stderr, '');
});

test('CLI rejects raw secrets or unavailable credentials with one safe JSON line and no stderr', () => {
  const bridge = fileURLToPath(new URL('./bridge.mjs', import.meta.url));
  for (const [input, config, error] of [
    [{ ...catalogInput, private_key: 'sensitive' }, env, 'invalid_request'],
    [catalogInput, { ...env, WEEKGLASS_WAFFO_PRIVATE_KEY_FILE: 'secret-location.pem' }, 'credentials_unavailable'],
  ]) {
    const result = spawnSync(process.execPath, [bridge], { input: JSON.stringify(input), encoding: 'utf8', env: config });
    assert.equal(result.status, 1);
    assert.equal(result.stdout, `${JSON.stringify({ ok: false, error })}\n`);
    assert.equal(result.stderr, '');
  }
});

test('CLI hands a signed catalog response back over stdin/stdout without stderr', () => {
  const bridge = fileURLToPath(new URL('./bridge.mjs', import.meta.url));
  const preload = join(directory, 'offline-fetch.cjs');
  writeFileSync(preload, `globalThis.fetch = async (address, init) => {
    if (address !== 'https://api.waffo.ai/v1/graphql' || !init.headers['X-Signature']) throw new Error('Unexpected call');
    return Response.json({ data: ${JSON.stringify(catalog)} });
  };\n`);
  try {
    const result = spawnSync(process.execPath, ['--require', preload, bridge], {
      input: JSON.stringify(catalogInput), encoding: 'utf8', env,
    });
    assert.equal(result.status, 0);
    assert.equal(result.stderr, '');
    assert.equal(result.stdout.trim().split('\n').length, 1);
    assert.deepEqual(JSON.parse(result.stdout), { ok: true, result: {
      product_id: product, store_id: store, currency: 'CNY', amount: '29.00', test_mode: true,
      tax_included: false, tax_category: 'saas',
    } });
  } finally {
    unlinkSync(preload);
  }
});

function liveCatalogs(sku = product, price = '1.00') {
  const signed = structuredClone(catalog);
  signed.store.prodEnabled = true;
  signed.onetimeProducts[0].hasProdVersion = true;
  signed.onetimeProducts[0].id = sku;
  signed.onetimeProducts[0].prices[0].priceInfo.amount = price;
  const prod = structuredClone(signed);
  const test = { store: { ...signed.store }, onetimeProducts: [] };
  return { signed, prod, test };
}

function liveMock(data, ...rest) {
  const mock = mockProvider(response(data.signed), response(data.prod), response(data.test), ...rest);
  mock.options.env = liveEnv;
  return mock;
}

test('live checkout signs the approved CNY price and stable reference only after a read-only environment proof', async () => {
  const expires = expiresAt();
  const data = liveCatalogs();
  data.test.onetimeProducts.push({ id: product, status: 'inactive' });
  const mock = liveMock(data, response({ sessionId: session, checkoutUrl: liveUrl, expiresAt: expires }));
  assert.deepEqual(await runBridge(liveCreate, mock.options), { ok: true, result: {
    session_id: session, checkout_url: liveUrl, expires_at: expires,
  } });
  const [preflight, publicProd, publicTest, create] = mock.requests;
  const signed = inspectSigned(preflight, '/v1/graphql');
  assert.match(signed.query, /prodEnabled/);
  assert.equal(preflight.headers['X-Environment'], undefined);
  for (const [req, mode] of [[publicProd, 'prod'], [publicTest, 'test']]) {
    assert.equal(req.address, 'https://api.waffo.ai/v1/graphql');
    assert.equal(req.redirect, 'error');
    assert.deepEqual(req.headers, { 'Content-Type': 'application/json', 'X-Store-Slug': 'weekglass-test', 'X-Environment': mode });
    assert.deepEqual(JSON.parse(req.body).variables, { storeId: store, productId: product });
  }
  assert.deepEqual(inspectSigned(create, '/v1/actions/checkout/create-session'), {
    productId: product, currency: 'CNY', priceSnapshot: { amount: '1.00', taxIncluded: true, taxCategory: 'saas' },
    orderMerchantExternalId: reference, metadata: { weekglass_product_id: product },
    expiresInSeconds: 900, allowPromotionCodes: false, includePaymentMethods: ['wechat'],
    successUrl: `https://cloud.viliana.cn/v1/billing/checkout/${reference}?returned=1`, language: 'zh-Hans',
  });
  assert.equal(create.headers['X-Idempotency-Key'], `weekglass-live-checkout-${reference}`);
  assert.equal(create.headers['X-Environment'], undefined);
  assert.equal(mock.requests.length, 4);
});

test('annual checkout requires the separately configured SKU and forwards its exact WeChat quote', async () => {
  const input = { ...liveCreate, product_id: annualProduct, amount: '9.99' };
  const data = liveCatalogs(annualProduct, '9.99');
  const mock = liveMock(data, response({ sessionId: session, checkoutUrl: liveUrl, expiresAt: expiresAt() }));
  assert.deepEqual(await runBridge(input, mock.options), {
    ok: false, error: 'checkout_preflight_catalog_product_unavailable',
  });
  assert.equal(mock.requests.length, 0);
  mock.options.env = { ...liveEnv, WEEKGLASS_WAFFO_LIVE_ANNUAL_PRODUCT_ID: annualProduct };
  assert.equal((await runBridge(input, mock.options)).ok, true);
  const create = inspectSigned(mock.requests[3], '/v1/actions/checkout/create-session');
  assert.deepEqual(create.priceSnapshot, { amount: '9.99', taxIncluded: true, taxCategory: 'saas' });
  assert.equal(create.productId, annualProduct);
  assert.deepEqual(create.metadata, { weekglass_product_id: annualProduct });
  assert.deepEqual(create.includePaymentMethods, ['wechat']);
});

test('live preflight fails before any write on unpublished, unapproved, mixed-mode or changed quote', async () => {
  for (const [mutate, code, n] of [
    [(d) => { d.signed.store.prodEnabled = false; }, 'catalog_store_not_live', 1],
    [(d) => { d.signed.onetimeProducts[0].hasProdVersion = false; }, 'catalog_product_not_published', 1],
    [(d) => { d.signed.onetimeProducts[0].status = 'inactive'; }, 'catalog_product_unavailable', 1],
    [(d) => { d.prod.onetimeProducts = []; }, 'catalog_environment_unverified', 3],
    [(d) => { d.test.onetimeProducts = d.prod.onetimeProducts; }, 'catalog_environment_unverified', 3],
    [(d) => { d.test.store.slug = 'another-store'; }, 'catalog_environment_unverified', 3],
    [(d) => { d.prod.onetimeProducts[0].prices[0].priceInfo.amount = '1.01'; }, 'catalog_environment_unverified', 3],
    [(d) => { d.prod.onetimeProducts[0].prices[0].priceInfo.amount = '2.00';
      d.signed.onetimeProducts[0].prices[0].priceInfo.amount = '2.00'; }, 'catalog_quote_changed', 3],
  ]) {
    const data = liveCatalogs();
    mutate(data);
    const mock = liveMock(data);
    assert.deepEqual(await runBridge(liveCreate, mock.options), { ok: false, error: `checkout_preflight_${code}` });
    assert.equal(mock.requests.length, n);
    assert(mock.requests.every((req) => req.address === 'https://api.waffo.ai/v1/graphql'));
  }
  const mock = liveMock(liveCatalogs());
  assert.deepEqual(await runBridge({ ...liveCreate, currency: 'USD' }, mock.options), {
    ok: false, error: 'checkout_preflight_invalid_request',
  });
  assert.deepEqual(await runBridge(liveCreate, { ...mock.options, env: { ...env, WEEKGLASS_WAFFO_MODE: 'prod' } }), {
    ok: false, error: 'checkout_preflight_credentials_unavailable',
  });
  assert.equal(mock.requests.length, 0);
});

test('after the live submission boundary a malformed result or lost response remains ambiguous', async () => {
  for (const url of [`${liveUrl}?test=true`, `${liveUrl}?`, `${liveUrl}#`, liveUrl.replace('.ai/', '.ai:443/'),
    liveUrl.replace('/store/', '/./store/'), liveUrl.replace('weekglass-test', 'another-store'),
    liveUrl.replace('.ai/', '.ai.example.test/')]) {
    const mock = liveMock(liveCatalogs(), response({ sessionId: session, checkoutUrl: url, expiresAt: expiresAt() }));
    assert.deepEqual(await runBridge(liveCreate, mock.options), { ok: false, error: 'provider_response_invalid' });
    assert.equal(mock.requests.length, 4);
  }
  const timeout = liveMock(liveCatalogs(), new Error('sensitive request detail'));
  assert.deepEqual(await runBridge(liveCreate, timeout.options), { ok: false, error: 'provider_unavailable' });
  assert.equal(timeout.requests.length, 4);
});

test('live reconciliation requires prod mode on the order and every payment, and rejects an ambiguous reference', async () => {
  const order = orderFacts();
  order.testMode = order.payments[0].testMode = false;
  order.createdAt = recorded;
  let mock = mockProvider(response({ onetimeOrders: [order] }));
  mock.options.env = liveEnv;
  const result = await runBridge(queryInput, mock.options);
  assert.equal(result.result.order.test_mode, false);
  assert.equal(result.result.order.created_at, recorded);
  assert.equal(result.result.order.payments[0].amount, '27.00');
  assert.match(inspectSigned(mock.requests[0], '/v1/graphql').query, /testMode currency createdAt/);
  for (const [orders, error] of [
    [[{ ...order, testMode: true }], 'unexpected_order'],
    [[{ ...order, payments: [{ ...order.payments[0], testMode: true }] }], 'unexpected_order'],
    [[order, order], 'ambiguous_order'],
  ]) {
    mock = mockProvider(response({ onetimeOrders: orders }));
    mock.options.env = liveEnv;
    assert.deepEqual(await runBridge(queryInput, mock.options), { ok: false, error });
  }
});

test('live verification pins production verification mode and rejects a key override', async () => {
  const payload = { id: refund, eventId: refund, eventType: 'refund.succeeded', timestamp: recorded,
    storeId: store, mode: 'prod', data: { orderId: id('ORD'), paymentId: payment, orderStatus: 'completed',
      paymentStatus: 'succeeded', refundStatus: 'succeeded', currency: 'CNY', refundedAmount: '1.00',
      originalChargedAmount: '1.00', orderMerchantExternalId: reference,
      orderMetadata: { weekglass_product_id: product } } };
  const input = webhook(payload);
  const verificationEnv = { WEEKGLASS_WAFFO_MODE: 'prod', WEEKGLASS_WAFFO_LIVE_STORE_ID: store };
  const verifyLiveWebhook = (body, signature, sdk) => sdk.verifyWebhook(body, signature, {
    environment: 'prod', publicKey: keys.publicKey.export({ type: 'spki', format: 'pem' }),
  });
  const verifyTestWebhook = () => assert.fail('Live verification cannot use the test verifier');
  const options = { env: verificationEnv, verifyLiveWebhook, verifyTestWebhook };
  assert.deepEqual(await runBridge(input, options), { ok: true, result: { payload } });
  assert.deepEqual(await runBridge(webhook({ ...payload, mode: 'test' }), options), { ok: false, error: 'invalid_webhook' });
  assert.deepEqual(await runBridge(input, { env: verificationEnv }), { ok: false, error: 'invalid_webhook' });
  const bridge = fileURLToPath(new URL('./bridge.mjs', import.meta.url));
  const withOverride = spawnSync(process.execPath, [bridge], { input: JSON.stringify(input), encoding: 'utf8',
    env: { ...verificationEnv, WAFFO_WEBHOOK_PROD_PUBLIC_KEY: keys.publicKey.export({ type: 'spki', format: 'pem' }) } });
  assert.deepEqual(JSON.parse(withOverride.stdout), { ok: false, error: 'webhook_key_override_forbidden' });
  assert.equal(withOverride.stderr, '');
});
