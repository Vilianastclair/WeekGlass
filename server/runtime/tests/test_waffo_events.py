"""Exercise the documented Waffo webhook shape after signature verification."""
from datetime import datetime, timezone
from uuid import UUID

import pytest

from weekglass_server.billing import VerifiedEvent
from weekglass_server.waffo_events import normalize_event


MERCHANT = 'merchant-weekglass'
STORE = 'STO_3bVzrkD0FJjFdZNLk8Ualx'
PRODUCT = 'PROD_8d01GmZ0AoyIbgQOnaXdoA'
CHECKOUT = UUID('6061b32c-ac37-4157-b7a0-16deea07a318')
PAYMENT = 'PAY_6eYCunG3IMmIgcQOnaXdoA'
REFUND = 'REF_4cWAtlE1GKkGebONl9Xbnx'
OCCURRED = datetime(2026, 11, 13, 11, 13, 30, 123000, tzinfo=timezone.utc)


def normalize(body):
    return normalize_event(body, MERCHANT, STORE, (PRODUCT,))


@pytest.fixture
def payment():
    return {
        'id': PAYMENT,
        'timestamp': '2026-11-13T11:13:30.123Z',
        'eventType': 'order.completed',
        'eventId': PAYMENT,
        'mode': 'test',
        'storeId': STORE,
        'storeName': 'WeekGlass',
        'data': {
            'orderId': 'ORD_5dXBtmF2HLlHfbPNm0Wcnz',
            'orderStatus': 'completed',
            'orderMerchantExternalId': CHECKOUT.hex,
            'orderMetadata': {'weekglass_product_id': PRODUCT},
            'productName': 'WeekGlass · 30 days',
            'productMetadata': {},
            'paymentId': PAYMENT,
            'paymentStatus': 'succeeded',
            'currency': 'CNY',
            'chargedAmount': '19.90',
            'amount': '19.90',
            'listPrice': {'total': '20.50', 'subtotal': '17.50', 'taxAmount': '3.00'},
        },
    }


@pytest.fixture
def refund(payment):
    payment.update(id=REFUND, eventId=REFUND, eventType='refund.succeeded')
    data = payment['data']
    data.pop('chargedAmount')
    data.pop('listPrice')
    data.update(amount='5.00', refundedAmount='5.00', originalChargedAmount='19.90',
                originalPayment={'total': '20.50', 'subtotal': '17.50', 'taxAmount': '3.00'},
                refundStatus='succeeded', refundCreatedAt='2026-11-13T11:12:00.000Z')
    return payment


def test_confirmed_payment_uses_actual_tax_inclusive_amount_and_configured_scope(payment):
    assert normalize(payment) == VerifiedEvent(
        f'order.completed:{PAYMENT}', 'payment_paid', 'waffo_pancake_test', MERCHANT, STORE,
        CHECKOUT, OCCURRED, external_id=PAYMENT, amount_minor=1990, currency='CNY',
    )


def test_canonical_hyphenated_checkout_and_utc_offset_are_also_supported(payment):
    payment['data']['orderMerchantExternalId'] = str(CHECKOUT)
    payment['timestamp'] = '2026-11-13T11:13:30.123+00:00'
    event = normalize(payment)
    assert (event.related_id, event.occurred_at) == (CHECKOUT, OCCURRED)


def test_deliveries_use_business_key_not_delivery_id(payment):
    expected = normalize(payment)
    payment['id'] = '6b0036c4-a909-4076-a42c-48e0528842d1'
    assert normalize(payment) == expected


@pytest.mark.parametrize(('value', 'minor'), [('19', 1900), ('19.9', 1990), ('0.01', 1), ('21474836.47', 2147483647)])
def test_exact_minor_units(payment, value, minor):
    payment['data']['chargedAmount'] = value
    assert normalize(payment).amount_minor == minor


@pytest.mark.parametrize('value', [19.90, 19, True, None, '0.00', '-0.01', '+1.00', ' 1.00',
                                   '1e1', '1.009', 'NaN', '19,90', '１９.９０', '21474836.48'])
def test_rejects_non_money_and_out_of_range_amounts(payment, value):
    payment['data']['chargedAmount'] = value
    with pytest.raises(ValueError, match='chargedAmount'):
        normalize(payment)


def test_list_price_does_not_substitute_for_actual_charge(payment):
    del payment['data']['chargedAmount']
    with pytest.raises(ValueError, match='chargedAmount'):
        normalize(payment)


@pytest.mark.parametrize(('key', 'value', 'message'), [
    ('mode', 'production', 'mode'), ('mode', None, 'mode'), ('eventType', [], 'eventType'),
    ('storeId', None, 'storeId'), ('data', [], 'data'), ('timestamp', '2026-11-13', 'timestamp'),
    ('timestamp', '2026-11-13T19:13:30+08:00', 'timestamp'),
    ('timestamp', '2026-02-30T19:13:30Z', 'timestamp'), ('eventId', 'PAY_other', 'eventId'),
])
def test_rejects_invalid_envelope(payment, key, value, message):
    payment[key] = value
    with pytest.raises(ValueError, match=message):
        normalize(payment)


@pytest.mark.parametrize(('key', 'value', 'message'), [
    ('orderMetadata', [], 'orderMetadata'), ('orderMetadata', {'weekglass_product_id': None}, 'weekglass_product_id'),
    ('orderId', None, 'orderId'), ('orderStatus', 'active', 'payment state'),
    ('paymentStatus', 'failed', 'payment state'), ('paymentId', 'a\x00b', 'paymentId'),
    ('currency', 'USD', 'currency'), ('orderMerchantExternalId', 'not-a-uuid', 'orderMerchantExternalId'),
    ('orderMerchantExternalId', f'urn:uuid:{CHECKOUT}', 'orderMerchantExternalId'),
    ('orderMerchantExternalId', CHECKOUT.hex.upper(), 'orderMerchantExternalId'),
])
def test_rejects_invalid_weekglass_payment_fields(payment, key, value, message):
    payment['data'][key] = value
    with pytest.raises(ValueError, match=message):
        normalize(payment)


@pytest.mark.parametrize(('key', 'value'), [
    ('mode', 'prod'), ('storeId', 'STO_other'), ('eventType', 'subscription.payment_succeeded'),
    ('eventType', 'refund.failed'),
])
def test_ignores_events_outside_test_order_and_successful_refund_scope(payment, key, value):
    payment[key] = value
    assert normalize(payment) is None


@pytest.mark.parametrize('metadata', [{}, {'weekglass_product_id': 'PROD_other'}])
def test_direct_product_id_cannot_replace_checkout_metadata(payment, metadata):
    payment['data'].update(orderMetadata=metadata, productId=PRODUCT)
    assert normalize(payment) is None


def test_unrelated_same_store_checkout_may_have_no_external_reference_or_metadata(payment):
    del payment['data']['orderMerchantExternalId']
    del payment['data']['orderMetadata']
    assert normalize(payment) is None


def test_refund_uses_settled_amount_and_original_payment_not_price_snapshot(refund):
    refund['data']['refundTicketMerchantExternalId'] = 'weekglass-refund-1'
    assert normalize(refund) == VerifiedEvent(
        f'refund.succeeded:{REFUND}', 'refund_succeeded', 'waffo_pancake_test', MERCHANT, STORE,
        CHECKOUT, OCCURRED, external_id=PAYMENT, amount_minor=500, currency='CNY',
        merchant_refund_id='weekglass-refund-1', provider_refund_id=REFUND,
    )


def test_dashboard_refund_uses_stable_provider_reference_when_merchant_did_not_supply_one(refund):
    event = normalize(refund)
    assert event.merchant_refund_id == f'dashboard:{REFUND}'
    refund['id'] = '17b80945-96cd-4fe7-9e1e-af094aa9e7a6'
    assert normalize(refund) == event


def test_refund_with_missing_settled_amount_cannot_change_entitlement(refund):
    del refund['data']['refundedAmount']
    with pytest.raises(ValueError, match='refundedAmount'):
        normalize(refund)


def test_refund_cannot_report_success_and_failure_at_once(refund):
    refund['data']['refundStatus'] = 'failed'
    with pytest.raises(ValueError, match='refund state'):
        normalize(refund)


def test_failed_refund_does_not_reserve_merchant_reference_needed_for_resubmission(refund):
    refund['data']['refundTicketMerchantExternalId'] = 'weekglass-refund-1'
    refund.update(eventType='refund.failed')
    refund['data'].update(refundStatus='failed', refundedAmount='9.99')
    assert normalize(refund) is None
    refund.update(eventType='refund.succeeded')
    refund['data'].update(refundStatus='succeeded', refundedAmount='5.00')
    assert normalize(refund).amount_minor == 500


@pytest.mark.parametrize(('fixture', 'kind', 'amount'), [
    ('payment', 'payment_paid', 1990), ('refund', 'refund_succeeded', 500),
])
def test_production_event_is_opt_in_and_keeps_a_distinct_ledger_scope(request, fixture, kind, amount):
    payload = request.getfixturevalue(fixture)
    assert normalize_event(payload, MERCHANT, STORE, (PRODUCT,), mode='prod') is None
    payload['mode'] = 'prod'
    event = normalize_event(payload, MERCHANT, STORE, ('PROD_annual', PRODUCT), mode='prod')
    assert (event.provider, event.related_id, event.kind, event.amount_minor, event.provider_product_id) == (
        'waffo_pancake', CHECKOUT, kind, amount, PRODUCT)
    assert normalize(payload) is None
