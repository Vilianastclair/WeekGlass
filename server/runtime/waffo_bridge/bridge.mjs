import { createPrivateKey } from 'node:crypto';
import { realpathSync } from 'node:fs';
import { open } from 'node:fs/promises';
import { isAbsolute } from 'node:path';
import { fileURLToPath } from 'node:url';

const API_ORIGIN = 'https://api.waffo.ai';
const API_PATHS = new Set(['/v1/graphql', '/v1/actions/checkout/create-session']);
const CHECKOUT_ORIGINS = new Set(['https://checkout.waffo.ai', 'https://pancake.waffo.ai']);
const RETURN_BASE = 'https://cloud.viliana.cn/v1/billing/checkout';
const SESSION_TTL_SECONDS = 900;
const MAX_WEBHOOK_BYTES = 256 * 1024;
const MAX_INPUT_BYTES = 4 * Math.ceil(MAX_WEBHOOK_BYTES / 3) + 4096;
const MAX_KEY_BYTES = 16 * 1024;

const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const EXTERNAL_ID = new RegExp(`^${UUID}$`);
const SESSION_ID = new RegExp(`^cs_${UUID}$`);
const MERCHANT_ID = /^MER_[A-Za-z0-9]{22}$/;
const STORE_ID = /^STO_[A-Za-z0-9]{22}$/;
const PRODUCT_ID = /^PROD_[A-Za-z0-9]{22}$/;
const ORDER_ID = /^ORD_[A-Za-z0-9]{22}$/;
const PAYMENT_ID = /^PAY_[A-Za-z0-9]{22}$/;
const REFUND_ID = /^(?:REF|RFD)_[A-Za-z0-9]{22}$/;
const MERCHANT_REFUND_ID = /^[A-Za-z0-9._:-]{1,128}$/;
const PROVIDER_CURRENCY = /^[A-Z]{3}$/;
const CHECKOUT_CURRENCY = /^(?:CNY|USD)$/;
const CHECKOUT_AMOUNT = /^(?:0|[1-9][0-9]{0,7})(?:\.[0-9]{1,2})?$/;
const DISPLAY_AMOUNT = /^[0-9]{1,12}(?:\.[0-9]{1,8})?$/;
const STATUS = /^[a-z][a-z0-9_]{0,39}$/;
const UTC_TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|\+00:00)$/;
const TEXT_DECODER = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true });

const catalogQuery = (extra = '') => `query WeekGlassCatalog($storeId: String!, $productId: String!) {
  store(id: $storeId) { id status slug${extra} }
  onetimeProducts(storeId: $storeId, filter: { id: { eq: $productId } }, limit: 2) {
    id status hasProdVersion prices { currency priceInfo { amount taxCategory } }
  }
}`;
const CATALOG = catalogQuery();
const LIVE_CATALOG = catalogQuery(' prodEnabled');

const orderQuery = (extra = '') => `query WeekGlassOrder($storeId: String!, $reference: String!) {
  onetimeOrders(storeId: $storeId, limit: 2, filter: {
    orderMerchantExternalId: { eq: $reference }
  }) {
    id orderMerchantExternalId status testMode currency${extra}
    store { id }
    onetimeProduct { id }
    priceSnapshot { currency total }
    payments {
      id status refundStatus testMode createdAt
      pspAmountDetails { amount currency }
      refunds { id status refundTicketMerchantExternalId createdAt pspAmountDetails { amount currency } }
    }
  }
}`;
const ORDER = orderQuery();
const LIVE_ORDER = orderQuery(' createdAt');

class BridgeError extends Error {}

function requireThat(condition, code = 'provider_response_invalid') {
  if (!condition) throw new BridgeError(code);
}

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function matches(value, pattern) {
  return typeof value === 'string' && pattern.test(value);
}

function timestamp(value) {
  requireThat(matches(value, UTC_TIMESTAMP) && Number.isFinite(Date.parse(value)));
  return value.replace(/\+00:00$/, 'Z');
}

function validateRequest(input, testMode) {
  requireThat(isObject(input), 'invalid_request');
  const keys = {
    catalog: ['op', 'product_id', 'currency'],
    create_checkout: ['op', 'product_id', 'currency', 'amount', 'external_order_id'],
    query_order: ['op', 'external_order_id'],
    verify_webhook: ['op', 'signature', 'body_base64'],
  };
  requireThat(typeof input.op === 'string' && Object.hasOwn(keys, input.op), 'invalid_request');
  const actualKeys = Object.keys(input);
  requireThat(
    actualKeys.length === keys[input.op].length && keys[input.op].every((key) => Object.hasOwn(input, key)),
    'invalid_request',
  );
  if (input.op === 'catalog' || input.op === 'create_checkout') {
    requireThat(matches(input.product_id, PRODUCT_ID) &&
      (testMode ? matches(input.currency, CHECKOUT_CURRENCY) : input.currency === 'CNY'), 'invalid_request');
  }
  if (input.op === 'create_checkout' || input.op === 'query_order') {
    requireThat(matches(input.external_order_id, EXTERNAL_ID), 'invalid_request');
  }
  if (input.op === 'create_checkout') {
    requireThat(matches(input.amount, CHECKOUT_AMOUNT) && /[1-9]/.test(input.amount), 'invalid_request');
  }
}

async function loadSdk() {
  try {
    return await import('@waffo/pancake-ts');
  } catch {
    throw new BridgeError('sdk_unavailable');
  }
}

async function readPrivateKey(keyFile) {
  requireThat(typeof keyFile === 'string' && isAbsolute(keyFile) && !/^[\\/]{2}/.test(keyFile), 'credentials_unavailable');
  let file;
  try {
    file = await open(keyFile, 'r');
    const stat = await file.stat();
    requireThat(stat.isFile() && stat.size > 0 && stat.size <= MAX_KEY_BYTES, 'credentials_unavailable');
    const raw = (await file.readFile('utf8')).replace(/\\n/g, '\n').trim();
    const pem = /^-----BEGIN (RSA PRIVATE KEY|PRIVATE KEY)-----([A-Za-z0-9+/=\s]+)-----END \1-----$/.exec(raw);
    const base64 = (pem?.[2] ?? raw).replace(/\s+/g, '');
    requireThat(/^[A-Za-z0-9+/]+={0,2}$/.test(base64), 'credentials_unavailable');
    const bytes = Buffer.from(base64, 'base64');
    requireThat(bytes.toString('base64').replace(/=+$/, '') === base64.replace(/=+$/, ''), 'credentials_unavailable');
    // Waffo supports PEM, escaped newlines, and raw base64 key material.
    const types = pem ? [pem[1] === 'RSA PRIVATE KEY' ? 'pkcs1' : 'pkcs8'] : ['pkcs8', 'pkcs1'];
    let key;
    for (const type of types) {
      try {
        key = createPrivateKey({ key: bytes, format: 'der', type });
        break;
      } catch {
        // Raw base64 has no header to distinguish the two RSA formats.
      }
    }
    requireThat(key?.asymmetricKeyType === 'rsa', 'credentials_unavailable');
    return key.export({ type: 'pkcs8', format: 'pem' });
  } catch {
    throw new BridgeError('credentials_unavailable');
  } finally {
    await file?.close();
  }
}

function transport(fetch, deadline) {
  return async (address, init) => {
    const url = new URL(address);
    requireThat(url.origin === API_ORIGIN && API_PATHS.has(url.pathname) && !url.username && !url.password &&
      !url.search && !url.hash && init?.method === 'POST');
    let response;
    try {
      response = await fetch(url.href, { ...init, redirect: 'error', signal: deadline });
    } catch {
      throw new BridgeError('provider_unavailable');
    }
    if (!response.ok) {
      // Never pass HTTP error bodies, signatures, or request parameters to the caller.
      await response.body?.cancel();
      if (response.status === 401) throw new BridgeError('provider_authentication');
      if (response.status === 403) throw new BridgeError('provider_forbidden');
      if (response.status === 429) throw new BridgeError('provider_rate_limited');
      if (response.status >= 500) throw new BridgeError('provider_unavailable');
      throw new BridgeError(url.pathname === '/v1/graphql' ? 'provider_query_failed' : 'provider_rejected');
    }
    return response;
  };
}

function queryData(response) {
  requireThat(isObject(response?.data) && (response.errors == null ||
    (Array.isArray(response.errors) && response.errors.length === 0)), 'provider_query_failed');
  return response.data;
}

async function query(client, queryText, variables) {
  return queryData(await client.graphql.query({ query: queryText, variables }));
}

function catalogPrice(product, currency) {
  requireThat(Array.isArray(product.prices));
  const prices = product.prices.filter((price) => price?.currency === currency);
  requireThat(prices.length === 1, 'catalog_price_unavailable');
  const price = prices[0].priceInfo;
  requireThat(matches(price?.amount, DISPLAY_AMOUNT) && matches(price.taxCategory, STATUS));
  return price;
}

function cnyMinor(value) {
  requireThat(matches(value, CHECKOUT_AMOUNT), 'catalog_price_invalid');
  const [whole, fraction = ''] = value.split('.');
  const minor = Number(whole) * 100 + Number(fraction.padEnd(2, '0'));
  requireThat(minor > 0 && minor <= 2147483647, 'catalog_price_invalid');
  return minor;
}

async function publicCatalog(request, variables, slug, mode) {
  const response = await request(`${API_ORIGIN}/v1/graphql`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Store-Slug': slug, 'X-Environment': mode },
    body: JSON.stringify({ query: CATALOG, variables }),
  });
  const data = queryData(await response.json());
  requireThat(data.store?.id === variables.storeId && data.store.slug === slug && data.store.status === 'active' &&
    Array.isArray(data.onetimeProducts), 'catalog_environment_unverified');
  return data.onetimeProducts;
}

async function getCatalog(client, request, storeId, input, testMode) {
  const variables = { storeId, productId: input.product_id };
  const data = await query(client, testMode ? CATALOG : LIVE_CATALOG, variables);
  requireThat(data.store?.id === storeId && data.store.status === 'active', 'catalog_store_unavailable');
  const slug = data.store.slug;
  requireThat(matches(slug, /^[a-z0-9][a-z0-9-]{0,127}$/));
  const products = data.onetimeProducts;
  requireThat(Array.isArray(products));
  requireThat(products.length === 1 && products[0]?.id === input.product_id, 'catalog_product_unavailable');
  const product = products[0];
  requireThat(product.status === 'active', 'catalog_product_unavailable');
  if (testMode) {
    // The key determines Waffo's environment; an unpublished SKU cannot be bought in prod.
    requireThat(product.hasProdVersion === false, 'catalog_product_not_test_only');
  } else {
    requireThat(data.store.prodEnabled === true, 'catalog_store_not_live');
    requireThat(product.hasProdVersion === true, 'catalog_product_not_published');
  }
  const price = catalogPrice(product, input.currency);
  if (!testMode) {
    // Waffo documents that signed GraphQL product status is selected by the key's
    // environment. Prove the signed active result is exclusive to prod using the
    // same product filter with explicit public environment headers, not on signed writes.
    const [prod, test] = await Promise.all([
      publicCatalog(request, variables, slug, 'prod'), publicCatalog(request, variables, slug, 'test'),
    ]);
    requireThat(prod.length === 1 && prod[0]?.id === product.id && prod[0].status === 'active' &&
      prod[0].hasProdVersion === true && (test.length === 0 ||
      (test.length === 1 && test[0]?.id === product.id && test[0].status === 'inactive')),
    'catalog_environment_unverified');
    const prodPrice = catalogPrice(prod[0], input.currency);
    requireThat(cnyMinor(prodPrice.amount) === cnyMinor(price.amount) && prodPrice.taxCategory === price.taxCategory,
      'catalog_environment_unverified');
  }
  return {
    slug,
    product: {
      product_id: product.id,
      store_id: storeId,
      currency: input.currency,
      amount: price.amount,
      test_mode: testMode,
      tax_included: false,
      tax_category: price.taxCategory,
    },
  };
}

function validateCheckoutUrl(raw, slug, sessionId, testMode) {
  requireThat(typeof raw === 'string' && raw.length <= 512);
  let url;
  try {
    url = new URL(raw);
  } catch {
    throw new BridgeError('provider_response_invalid');
  }
  const path = `/${slug}/checkout/${sessionId}`;
  requireThat(
    !url.username && !url.password && !url.hash && (!url.search || (testMode && url.search === '?test=true')) &&
    CHECKOUT_ORIGINS.has(url.origin) && (url.pathname === path || url.pathname === `/store${path}`),
  );
  if (!testMode) requireThat(raw === `${url.origin}${url.pathname}`);
  return url.href;
}

async function createCheckout(client, catalog, input, testMode) {
  const session = await client.checkout.anonymous.create({
    productId: input.product_id,
    currency: input.currency,
    // This REST field is supported and forwarded unchanged by SDK 0.28.
    priceSnapshot: { amount: input.amount, taxIncluded: true, taxCategory: testMode ? 'saas' : catalog.product.tax_category },
    orderMerchantExternalId: input.external_order_id,
    metadata: { weekglass_product_id: input.product_id },
    expiresInSeconds: SESSION_TTL_SECONDS,
    allowPromotionCodes: false,
    ...(!testMode ? { includePaymentMethods: ['wechat'],
      successUrl: `${RETURN_BASE}/${input.external_order_id}?returned=1`, language: 'zh-Hans' }
      : input.currency === 'USD' ? { includePaymentMethods: ['card'] } : {}),
  }, { idempotencyKey: `weekglass-${testMode ? 'test' : 'live'}-checkout-${input.external_order_id}` });
  requireThat(matches(session?.sessionId, SESSION_ID));
  const expiry = timestamp(session.expiresAt);
  const now = Date.now();
  requireThat(Date.parse(expiry) > now && Date.parse(expiry) <= now + (SESSION_TTL_SECONDS + 60) * 1000);
  return {
    session_id: session.sessionId,
    checkout_url: validateCheckoutUrl(session.checkoutUrl, catalog.slug, session.sessionId, testMode),
    expires_at: expiry,
  };
}

function refundFacts(refund) {
  requireThat(matches(refund?.id, REFUND_ID) && matches(refund.status, STATUS));
  const psp = refund.pspAmountDetails;
  requireThat(psp == null || (matches(psp.amount, DISPLAY_AMOUNT) && matches(psp.currency, PROVIDER_CURRENCY)));
  const merchantRefund = refund.refundTicketMerchantExternalId;
  requireThat(merchantRefund == null || matches(merchantRefund, MERCHANT_REFUND_ID));
  return {
    provider_refund_id: refund.id,
    merchant_refund_id: merchantRefund ?? null,
    status: refund.status,
    amount: psp?.amount ?? null,
    currency: psp?.currency ?? null,
    created_at: timestamp(refund.createdAt),
  };
}

function paymentFacts(payment, testMode) {
  requireThat(matches(payment?.id, PAYMENT_ID) && matches(payment.status, STATUS));
  requireThat(payment.testMode === testMode, 'unexpected_order');
  requireThat(payment.refundStatus == null || matches(payment.refundStatus, STATUS));
  requireThat(Array.isArray(payment.refunds));
  // Do not substitute Payment.amount (which can be the quote) or the PSP's settlement currency.
  const details = payment.pspAmountDetails;
  requireThat(details == null || (matches(details.amount, DISPLAY_AMOUNT) && matches(details.currency, PROVIDER_CURRENCY)));
  const refunds = payment.refunds.map(refundFacts);
  requireThat(payment.refundStatus !== 'refunded' || refunds.some((refund) => refund.status === 'succeeded'));
  return {
    provider_payment_id: payment.id,
    status: payment.status,
    amount: details?.amount ?? null,
    currency: details?.currency ?? null,
    created_at: timestamp(payment.createdAt),
    refund_status: payment.refundStatus ?? null,
    refunds,
  };
}

async function getOrder(client, storeId, reference, testMode) {
  const data = await query(client, testMode ? ORDER : LIVE_ORDER, { storeId, reference });
  const orders = data.onetimeOrders;
  requireThat(Array.isArray(orders));
  if (orders.length === 0) return { order: null };
  requireThat(orders.length === 1, 'ambiguous_order');
  const order = orders[0];
  requireThat(order?.testMode === testMode && order.orderMerchantExternalId === reference && order.store?.id === storeId, 'unexpected_order');
  requireThat(matches(order.id, ORDER_ID) && matches(order.onetimeProduct?.id, PRODUCT_ID) &&
    matches(order.status, STATUS) && matches(order.currency, PROVIDER_CURRENCY));
  requireThat(order.priceSnapshot?.currency === order.currency && matches(order.priceSnapshot.total, DISPLAY_AMOUNT));
  requireThat(Array.isArray(order.payments));
  return { order: {
    provider_order_id: order.id,
    external_order_id: reference,
    product_id: order.onetimeProduct.id,
    store_id: storeId,
    currency: order.currency,
    amount: order.priceSnapshot.total,
    status: order.status,
    test_mode: testMode,
    ...(!testMode ? { created_at: timestamp(order.createdAt) } : {}),
    payments: order.payments.map((payment) => paymentFacts(payment, testMode)),
  } };
}

const WEBHOOK_FIELDS = {
  orderId: ORDER_ID,
  orderMerchantExternalId: EXTERNAL_ID,
  orderStatus: STATUS,
  paymentId: PAYMENT_ID,
  paymentStatus: STATUS,
  refundStatus: STATUS,
  refundTicketMerchantExternalId: MERCHANT_REFUND_ID,
  currency: PROVIDER_CURRENCY,
  chargedAmount: DISPLAY_AMOUNT,
  refundedAmount: DISPLAY_AMOUNT,
  originalChargedAmount: DISPLAY_AMOUNT,
  paymentDate: /^\d{4}-\d{2}-\d{2}$/,
  refundCreatedAt: UTC_TIMESTAMP,
};

function verifyEvent(sdk, input, storeId, mode, verifier) {
  // The SDK prefers env overrides to its built-in key; this bridge never accepts those overrides.
  requireThat(!process.env.WAFFO_WEBHOOK_TEST_PUBLIC_KEY && !process.env.WAFFO_WEBHOOK_PROD_PUBLIC_KEY &&
    !process.env.WAFFO_WEBHOOK_PUBLIC_KEY, 'webhook_key_override_forbidden');
  requireThat(typeof input.signature === 'string' && input.signature.length > 0 && input.signature.length <= 2048, 'invalid_webhook');
  requireThat(typeof input.body_base64 === 'string' && input.body_base64.length <= 4 * Math.ceil(MAX_WEBHOOK_BYTES / 3), 'invalid_webhook');
  const bytes = Buffer.from(input.body_base64, 'base64');
  requireThat(bytes.length > 0 && bytes.length <= MAX_WEBHOOK_BYTES && bytes.toString('base64') === input.body_base64, 'invalid_webhook');
  let event;
  try {
    const body = TEXT_DECODER.decode(bytes);
    event = verifier(body, input.signature, sdk);
  } catch {
    throw new BridgeError('invalid_webhook');
  }
  requireThat(event?.mode === mode && event.storeId === storeId && isObject(event.data), 'invalid_webhook');
  const eventId = /^[A-Za-z0-9:._-]{1,128}$/;
  requireThat(matches(event.id, eventId) && matches(event.eventId, eventId) &&
    matches(event.eventType, /^[a-z][a-z0-9_]{0,39}\.[a-z][a-z0-9_]{0,39}$/) &&
    matches(event.timestamp, UTC_TIMESTAMP) && Number.isFinite(Date.parse(event.timestamp)), 'invalid_webhook');
  if (event.eventType === 'order.completed') requireThat(matches(event.eventId, PAYMENT_ID), 'invalid_webhook');
  if (event.eventType === 'refund.succeeded') requireThat(matches(event.eventId, REFUND_ID), 'invalid_webhook');
  const data = Object.fromEntries(Object.entries(WEBHOOK_FIELDS)
    .filter(([field, pattern]) => matches(event.data[field], pattern))
    .map(([field]) => [field, event.data[field]]));
  const productId = event.data.orderMetadata?.weekglass_product_id;
  if (matches(productId, PRODUCT_ID)) data.orderMetadata = { weekglass_product_id: productId };
  return { payload: {
    id: event.id, eventId: event.eventId, eventType: event.eventType,
    timestamp: event.timestamp, storeId, mode, data,
  } };
}

export async function runBridge(input, {
  env = process.env,
  fetch = globalThis.fetch,
  verifyTestWebhook = (body, signature, sdk) => sdk.verifyWebhook(body, signature, { environment: 'test' }),
  verifyLiveWebhook = (body, signature, sdk) => sdk.verifyWebhook(body, signature, { environment: 'prod' }),
} = {}) {
  const mode = env.WEEKGLASS_WAFFO_MODE ?? 'test';
  const testMode = mode === 'test';
  let mayHaveSubmitted = false;
  try {
    requireThat(testMode || mode === 'prod', 'invalid_request');
    validateRequest(input, testMode);
    const prefix = testMode ? 'WEEKGLASS_WAFFO_' : 'WEEKGLASS_WAFFO_LIVE_';
    const storeId = env[`${prefix}STORE_ID`];
    requireThat(matches(storeId, STORE_ID), 'credentials_unavailable');
    const sdk = await loadSdk();
    if (input.op === 'verify_webhook') {
      return { ok: true, result: verifyEvent(sdk, input, storeId, mode, testMode ? verifyTestWebhook : verifyLiveWebhook) };
    }
    const merchantId = env[`${prefix}MERCHANT_ID`];
    requireThat(matches(merchantId, MERCHANT_ID), 'credentials_unavailable');
    if (!testMode && (input.op === 'catalog' || input.op === 'create_checkout')) {
      const products = [env[`${prefix}PRODUCT_ID`], env[`${prefix}ANNUAL_PRODUCT_ID`]];
      requireThat(products.includes(input.product_id), 'catalog_product_unavailable');
    }
    const privateKey = await readPrivateKey(env[`${prefix}PRIVATE_KEY_FILE`]);
    const request = transport(fetch, AbortSignal.timeout(8000));
    const client = new sdk.WaffoPancake({
      merchantId, privateKey, baseUrl: API_ORIGIN, fetch: request,
    });
    let result;
    if (input.op === 'query_order') {
      result = await getOrder(client, storeId, input.external_order_id, testMode);
    } else {
      const catalog = await getCatalog(client, request, storeId, input, testMode);
      if (input.op === 'catalog') result = catalog.product;
      else {
        if (!testMode) {
          requireThat(cnyMinor(catalog.product.amount) === cnyMinor(input.amount), 'catalog_quote_changed');
        }
        mayHaveSubmitted = true;
        result = await createCheckout(client, catalog, input, testMode);
      }
    }
    return { ok: true, result };
  } catch (error) {
    const code = error instanceof BridgeError ? error.message : 'provider_response_invalid';
    const preflight = mode === 'prod' && input?.op === 'create_checkout' && !mayHaveSubmitted;
    return { ok: false, error: preflight ? `checkout_preflight_${code}` : code };
  }
}

async function runCli() {
  let response;
  try {
    const chunks = [];
    let total = 0;
    for await (const chunk of process.stdin) {
      total += chunk.length;
      requireThat(total <= MAX_INPUT_BYTES, 'invalid_request');
      chunks.push(chunk);
    }
    response = await runBridge(JSON.parse(TEXT_DECODER.decode(Buffer.concat(chunks))));
  } catch {
    response = { ok: false, error: 'invalid_request' };
  }
  process.stdout.write(`${JSON.stringify(response)}\n`);
  if (!response.ok) process.exitCode = 1;
}

if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
  await runCli();
}
