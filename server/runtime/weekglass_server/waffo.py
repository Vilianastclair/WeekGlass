"""Environment-scoped connectors to the pinned Waffo server SDK."""
import base64
from dataclasses import dataclass
from datetime import datetime, timedelta
from decimal import Decimal
import json
import logging
import os
from pathlib import Path
import re
import shutil
import subprocess
from urllib.parse import urlsplit
from uuid import UUID

from .billing import WAFFO_LIVE_PROVIDER, WAFFO_TEST_PROVIDER, VerifiedEvent, live_order_product_id
from .protocol import now
from .waffo_events import normalize_event

_BRIDGE = Path(__file__).resolve().parents[1] / 'waffo_bridge/bridge.mjs'
_MONEY = re.compile(r'[0-9]{1,8}(?:\.[0-9]{1,2})?')
_SHORT_ID = re.compile(r'(MER|STO|PROD|ORD|PAY|REF|RFD)_[A-Za-z0-9]{22}')
_LIVE_SESSION_ID = re.compile(r'cs_[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}')
LOGGER = logging.getLogger(__name__)


class BridgeError(RuntimeError):
    pass


def minor(amount):
    if not isinstance(amount, str) or not _MONEY.fullmatch(amount):
        raise ValueError('Expected decimal yuan from Waffo')
    return int(Decimal(amount) * 100)


def instant(value):
    if not isinstance(value, str):
        raise ValueError('Missing Waffo timestamp')
    result = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if result.utcoffset() != timedelta(0):
        raise ValueError('Expected UTC Waffo timestamp')
    return result


def _identifier(value, prefix):
    return isinstance(value, str) and re.fullmatch(prefix + r'_[A-Za-z0-9]{1,100}', value)


def _live_identifier(value, prefix):
    return isinstance(value, str) and value.startswith(prefix + '_') and _SHORT_ID.fullmatch(value) is not None


def _checkout_url(value, session_id, test_mode):
    if not isinstance(value, str) or len(value) > 2048 or any(ord(c) <= 32 or ord(c) == 127 for c in value):
        return False
    url = urlsplit(value)
    if url.scheme != 'https' or url.netloc not in ('checkout.waffo.ai', 'pancake.waffo.ai'):
        return False
    if test_mode:
        return url.path.endswith('/checkout/' + session_id)
    return bool(_LIVE_SESSION_ID.fullmatch(session_id)
                and re.fullmatch(r'(?:/store)?/[a-z0-9][a-z0-9-]{0,127}/checkout/' + session_id, url.path)
                and value == f'https://{url.netloc}{url.path}')


@dataclass(frozen=True)
class _Waffo:
    merchant_id: str
    app_id: str
    product_id: str
    private_key_file: Path

    def _call(self, operation, **params):
        node = shutil.which('node')
        if not node or not _BRIDGE.is_file():
            raise BridgeError('sdk_unavailable')
        env = {k: os.environ[k] for k in ('PATH', 'SystemRoot', 'WINDIR', 'TEMP', 'TMP') if k in os.environ}
        prefix = 'WEEKGLASS_WAFFO_' if self.test_mode else 'WEEKGLASS_WAFFO_LIVE_'
        env.update({prefix + 'MERCHANT_ID': self.merchant_id, prefix + 'STORE_ID': self.app_id,
                    prefix + 'PRIVATE_KEY_FILE': str(self.private_key_file)})
        if not self.test_mode:
            env.update(WEEKGLASS_WAFFO_MODE='prod', WEEKGLASS_WAFFO_LIVE_PRODUCT_ID=self.product_id)
            if self.annual_product_id:
                env['WEEKGLASS_WAFFO_LIVE_ANNUAL_PRODUCT_ID'] = self.annual_product_id
        try:
            result = subprocess.run([node, str(_BRIDGE)], input=json.dumps({'op': operation, **params}).encode(),
                                    env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=25,
                                    creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0), check=False)
            message = json.loads(result.stdout)
        except (OSError, ValueError, subprocess.TimeoutExpired):
            raise BridgeError('sdk_unavailable') from None
        if isinstance(message, dict) and message.get('ok') is True and isinstance(message.get('result'), dict):
            if result.returncode == 0:
                return message['result']
        code = message.get('error') if isinstance(message, dict) else None
        raise BridgeError(code if isinstance(code, str) and re.fullmatch(r'[a-z][a-z0-9_]{1,70}', code)
                          else 'sdk_invalid_response')

    @property
    def _mode_label(self):
        return 'test' if self.test_mode else 'live'

    @property
    def _scope(self):
        return dict(provider=self.provider, merchant_id=self.merchant_id, app_id=self.app_id)

    def catalog_amount(self, product_id=None):
        product_id = product_id or self.product_id
        result = self._call('catalog', product_id=product_id, currency='CNY')
        if ((result.get('store_id'), result.get('product_id'), result.get('currency')) !=
                (self.app_id, product_id, 'CNY') or result.get('test_mode') is not self.test_mode):
            raise BridgeError(f'{self._mode_label}_catalog_mismatch')
        try:
            amount = minor(result.get('amount'))
            if not 0 < amount <= 2147483647:
                raise ValueError()
            return amount
        except ValueError:
            raise BridgeError(f'{self._mode_label}_catalog_amount_invalid') from None

    def create_checkout(self, order):
        amount = order['amount_minor']
        result = self._call('create_checkout', product_id=self._order_product_id(order), currency='CNY',
                            amount=f'{amount // 100}.{amount % 100:02}', external_order_id=str(order['checkout_id']))
        url, session_id = result.get('checkout_url'), result.get('session_id')
        try:
            expires = instant(result.get('expires_at'))
            current = now()
            if (not isinstance(session_id, str) or not re.fullmatch(r'[A-Za-z0-9_-]{3,128}', session_id)
                    or not _checkout_url(url, session_id, self.test_mode) or not current < expires <= current + timedelta(minutes=16)):
                raise ValueError()
        except ValueError:
            raise BridgeError(f'{self._mode_label}_checkout_response_invalid') from None
        return url, expires

    def verify_event(self, headers, raw):
        signature = headers.get('x-waffo-signature')
        if not isinstance(signature, str) or not 0 < len(signature) <= 2048:
            raise ValueError('Missing signature')
        result = self._call('verify_webhook', signature=signature, body_base64=base64.b64encode(raw).decode('ascii'))
        return normalize_event(result.get('payload'), self.merchant_id, self.app_id, self._webhook_products,
                               mode='test' if self.test_mode else 'prod')

    @property
    def _webhook_products(self):
        return (self.product_id,)

    def _order_product_id(self, order):
        return self.product_id

    def _query_order(self, order):
        response = self._call('query_order', external_order_id=str(order['checkout_id']))
        result = response.get('order') if self.test_mode else response['order']
        if result is not None and (result['test_mode'] is not self.test_mode or result['store_id'] != self.app_id
                or result['product_id'] != self._order_product_id(order)
                or UUID(result['external_order_id']) != order['checkout_id']
                or result['currency'] != order['currency'] or minor(result['amount']) != order['amount_minor']):
            raise ValueError()
        return result


class WaffoTest(_Waffo):
    provider = WAFFO_TEST_PROVIDER
    test_mode = True

    @classmethod
    def load(cls):
        merchant = os.environ.get('WEEKGLASS_WAFFO_MERCHANT_ID')
        store = os.environ.get('WEEKGLASS_WAFFO_STORE_ID')
        product = os.environ.get('WEEKGLASS_WAFFO_PRODUCT_ID')
        if not all(_identifier(value, prefix) for value, prefix in
                   ((merchant, 'MER'), (store, 'STO'), (product, 'PROD'))):
            raise BridgeError('configure_test_merchant_store_and_product')
        path = Path(os.environ.get('WEEKGLASS_WAFFO_PRIVATE_KEY_FILE', ''))
        if not path.is_absolute() or not path.is_file():
            raise BridgeError('test_key_file_missing')
        return cls(merchant, store, product, path)

    def query_events(self, order):
        checkout_id = order['checkout_id']
        try:
            result = self._query_order(order)
            if result is None or result['status'] != 'completed':
                return []
            payments = [p for p in result['payments'] if p['status'] == 'succeeded']
            if len(payments) != 1:
                raise ValueError()
            payment, = payments
            payment_id = payment['provider_payment_id']
            amount = minor(payment['amount'])
            if (not _identifier(payment_id, 'PAY') or payment['currency'] != order['currency']
                    or amount != order['amount_minor']):
                raise ValueError()
            # The query reports a completed charge but no settlement timestamp.
            # The immutable payment record creation time is only for test-ledger bookkeeping.
            # Only signed refund events write refunds: Waffo's documented query
            # and webhook ID formats differ, so do not count them as two refunds.
            if not order['paid_at'] and any(r['status'] == 'succeeded' for r in payment['refunds']):
                return []
            return [VerifiedEvent('query:paid:' + payment_id, 'payment_paid',
                                  related_id=checkout_id, external_id=payment_id, currency=order['currency'],
                                  occurred_at=instant(payment['created_at']), amount_minor=amount, **self._scope)]
        except (KeyError, TypeError, ValueError):
            raise BridgeError('test_order_response_invalid') from None


@dataclass(frozen=True)
class WaffoLive(_Waffo):
    """Live-only WeekGlass CNY WeChat checkout; it never loads sandbox credentials."""

    provider = WAFFO_LIVE_PROVIDER
    test_mode = False
    annual_product_id: str | None = None

    @classmethod
    def load(cls):
        merchant = os.environ.get('WEEKGLASS_WAFFO_LIVE_MERCHANT_ID')
        store = os.environ.get('WEEKGLASS_WAFFO_LIVE_STORE_ID')
        product = os.environ.get('WEEKGLASS_WAFFO_LIVE_PRODUCT_ID')
        if not all(_live_identifier(value, prefix) for value, prefix in
                   ((merchant, 'MER'), (store, 'STO'), (product, 'PROD'))):
            raise BridgeError('configure_live_merchant_store_and_product')
        annual_product = os.environ.get('WEEKGLASS_WAFFO_LIVE_ANNUAL_PRODUCT_ID') or None
        if annual_product and (not _live_identifier(annual_product, 'PROD') or annual_product == product):
            LOGGER.error('Invalid Waffo annual product ID; annual offer unavailable')
            annual_product = None
        path = Path(os.environ.get('WEEKGLASS_WAFFO_LIVE_PRIVATE_KEY_FILE', ''))
        try:
            if path.is_absolute() and path.is_file():
                return cls(merchant, store, product, path, annual_product)
        except OSError:
            pass
        raise BridgeError('live_key_file_missing')

    @property
    def _webhook_products(self):
        return (self.product_id, self.annual_product_id) if self.annual_product_id else (self.product_id,)

    def _order_product_id(self, order):
        return live_order_product_id(self, order)

    def _check_order(self, order):
        if (any(order.get(key) != value for key, value in self._scope.items())
                or order.get('purchase_mode') != 'single' or order.get('source') != 'checkout'
                or order.get('currency') != 'CNY' or not isinstance(order.get('checkout_id'), UUID)
                or type(order.get('amount_minor')) is not int or not 0 < order['amount_minor'] <= 2147483647
                or not _live_identifier(self._order_product_id(order), 'PROD')):
            raise BridgeError('live_order_scope_mismatch')

    def create_checkout(self, order):
        self._check_order(order)
        return super().create_checkout(order)

    def query_events(self, order):
        self._check_order(order)
        try:
            result = self._query_order(order)
            if result is None:
                return []
            expected = order['amount_minor']
            order_id = result['provider_order_id']
            if not _live_identifier(order_id, 'ORD'):
                raise ValueError()
            scope = dict(related_id=order['checkout_id'], amount_minor=expected, currency='CNY',
                         provider_product_id=self._order_product_id(order), **self._scope)
            payments = result['payments']
            if result['status'] == 'pending':
                return []
            if result['status'] == 'canceled':
                if any(payment['status'] not in ('failed', 'canceled') for payment in payments):
                    raise ValueError()
                # The cashier can offer a replacement session with the same order
                # reference until the original expiry. A canceled attempt alone is insufficient.
                expires = order.get('provider_checkout_expires_at')
                if not expires or expires > now() or order['paid_at']:
                    return []
                return [VerifiedEvent('query:closed:' + order_id, 'payment_closed', external_id=order_id,
                                      occurred_at=instant(result['created_at']), **scope)]
            if result['status'] != 'completed':
                raise ValueError()
            succeeded = [p for p in payments if p['status'] == 'succeeded']
            if len(succeeded) != 1 or any(p['status'] not in ('succeeded', 'failed', 'canceled') for p in payments):
                raise ValueError()
            payment, = succeeded
            payment_id = payment['provider_payment_id']
            if (not _live_identifier(payment_id, 'PAY') or payment['currency'] != 'CNY'
                    or minor(payment['amount']) != expected):
                raise ValueError()
            if not order['paid_at'] and not _refunds_reconciled(payment, order, payment_id, expected):
                return []
            # This is when the payment record was created; the signed webhook
            # supplies the event time. Neither date controls the entitlement start.
            return [VerifiedEvent('query:paid:' + payment_id, 'payment_paid', external_id=payment_id,
                                  occurred_at=instant(payment['created_at']), **scope)]
        except (KeyError, TypeError, ValueError):
            raise BridgeError('live_order_response_invalid') from None


def _refunds_reconciled(payment, order, payment_id, expected):
    # Query refund IDs and webhook event IDs are not documented as the same ID.
    # Only signed webhook events enter the refund ledger. A query may complete a
    # payment with existing refunds only when the ledger can apply them atomically.
    successful = [r for r in payment['refunds'] if r['status'] == 'succeeded']
    if not successful:
        return payment['refund_status'] not in ('pending', 'refunded')
    if any(r['currency'] != 'CNY' for r in successful):
        raise ValueError()
    amounts = {r['provider_refund_id']: minor(r['amount']) for r in successful}
    if len(amounts) != len(successful) or any(amount <= 0 for amount in amounts.values()):
        raise ValueError()
    total = sum(amounts.values())
    if total > expected:
        raise ValueError()
    return payment['refund_status'] != 'pending' and order.get('verified_refund_amounts', {}).get(payment_id) == total
