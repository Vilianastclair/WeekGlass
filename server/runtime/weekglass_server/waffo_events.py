"""Map authenticated Waffo Pancake deliveries to environment-scoped ledger events."""
import re
from datetime import datetime
from uuid import UUID

from .billing import VerifiedEvent, WAFFO_LIVE_PROVIDER, WAFFO_TEST_PROVIDER


PROVIDER = WAFFO_TEST_PROVIDER
PRODUCT_METADATA_KEY = 'weekglass_product_id'
_CNY_DISPLAY = re.compile(r'([0-9]{1,8})(?:\.([0-9]{1,2}))?')
_UTC_TIMESTAMP = re.compile(r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|\+00:00)')


def _text(data: dict, key: str) -> str:
    value = data.get(key)
    if (not isinstance(value, str) or not 1 <= len(value) <= 128
            or not value.isprintable() or value != value.strip()):
        raise ValueError(f'Invalid Waffo {key}')
    return value


def _minor_units(data: dict, key: str) -> int:
    match = _CNY_DISPLAY.fullmatch(_text(data, key))
    if not match:
        raise ValueError(f'Invalid Waffo {key}')
    units, fraction = match.groups()
    amount = int(units) * 100 + int((fraction or '').ljust(2, '0'))
    if not 0 < amount <= 2147483647:
        raise ValueError(f'Invalid Waffo {key}')
    return amount


def normalize_event(payload: dict, merchant_id: str, store_id: str, products: tuple[str, ...], *,
                    mode: str = 'test') -> VerifiedEvent | None:
    """Accept only this store's WeekGlass checkout scope after signature verification."""
    if mode not in ('test', 'prod'):
        raise ValueError('Invalid Waffo scope')
    if not isinstance(payload, dict):
        raise ValueError('Invalid Waffo event')
    delivery_mode = payload.get('mode')
    if delivery_mode not in ('test', 'prod'):
        raise ValueError('Invalid Waffo mode')
    event_type = _text(payload, 'eventType')
    event_store = _text(payload, 'storeId')
    # A failed refund ticket can be resubmitted with the same merchant ID and a different amount.
    if delivery_mode != mode or event_store != store_id or event_type not in ('order.completed', 'refund.succeeded'):
        return None

    data = payload.get('data')
    if not isinstance(data, dict):
        raise ValueError('Invalid Waffo data')
    # Waffo does not expose a product ID in this webhook. Merchant checkout metadata is echoed here.
    metadata = data.get('orderMetadata', {})
    if not isinstance(metadata, dict):
        raise ValueError('Invalid Waffo orderMetadata')
    if PRODUCT_METADATA_KEY not in metadata:
        return None
    product_id = _text(metadata, PRODUCT_METADATA_KEY)
    if product_id not in products:
        return None

    _text(data, 'orderId')
    if data.get('orderStatus') != 'completed' or data.get('paymentStatus') != 'succeeded':
        raise ValueError('Invalid Waffo payment state')
    if data.get('currency') != 'CNY':
        raise ValueError('Invalid Waffo currency')
    checkout_ref = _text(data, 'orderMerchantExternalId')
    try:
        checkout_id = UUID(checkout_ref)
    except ValueError:
        raise ValueError('Invalid Waffo orderMerchantExternalId') from None
    if checkout_ref not in (checkout_id.hex, str(checkout_id)):
        raise ValueError('Invalid Waffo orderMerchantExternalId')
    timestamp = _text(payload, 'timestamp')
    if not _UTC_TIMESTAMP.fullmatch(timestamp):
        raise ValueError('Invalid Waffo timestamp')
    try:
        occurred_at = datetime.fromisoformat(timestamp)
    except ValueError:
        raise ValueError('Invalid Waffo timestamp') from None

    entity_id = _text(payload, 'eventId')
    payment_id = _text(data, 'paymentId')
    provider = WAFFO_TEST_PROVIDER if mode == 'test' else WAFFO_LIVE_PROVIDER
    fields = dict(event_id=f'{event_type}:{entity_id}', provider=provider, merchant_id=merchant_id,
                  app_id=store_id, related_id=checkout_id, occurred_at=occurred_at,
                  external_id=payment_id, currency='CNY')
    if mode == 'prod':
        fields['provider_product_id'] = product_id
    if event_type == 'order.completed':
        if entity_id != payment_id:
            raise ValueError('Waffo eventId does not identify the payment')
        # `amount` can fall back to the listed price when no actual charge was reported.
        return VerifiedEvent(kind='payment_paid', amount_minor=_minor_units(data, 'chargedAmount'), **fields)

    if data.get('refundStatus') != 'succeeded':
        raise ValueError('Invalid Waffo refund state')
    merchant_refund_id = (_text(data, 'refundTicketMerchantExternalId') if 'refundTicketMerchantExternalId' in data
                          else f'dashboard:{entity_id}')
    return VerifiedEvent(kind='refund_succeeded', amount_minor=_minor_units(data, 'refundedAmount'),
                         merchant_refund_id=merchant_refund_id, provider_refund_id=entity_id, **fields)
