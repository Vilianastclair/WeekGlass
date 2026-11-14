import 'cloud_auth_service.dart';

const cloudBillingPurchasesAllowed = bool.fromEnvironment(
  'WG_DIRECT_BILLING',
  defaultValue: true,
);
const _daySeconds = 24 * 60 * 60;
const _monthlySeconds = 30 * _daySeconds;
const _annualSeconds = 365 * _daySeconds;

enum CloudPurchaseMode {
  single('single'),
  autoRenew('auto_renew');

  const CloudPurchaseMode(this.wireName);
  final String wireName;

  String label(CloudBillingOffer offer) => switch (this) {
    single => '仅购买 ${offer.periodLabel}',
    autoRenew => '开通自动续费',
  };
}

DateTime? _time(Object? value) {
  if (value == null) return null;
  final time = value is String ? DateTime.tryParse(value) : null;
  if (time == null || !time.isUtc) throw const FormatException('Invalid time');
  return time;
}

String cloudBillingTime(DateTime value) {
  final local = value.toLocal();
  final minutes = local.timeZoneOffset.inMinutes;
  String two(int n) => n.toString().padLeft(2, '0');
  final sign = minutes < 0 ? '−' : '+';
  final offset = minutes.abs();
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)} '
      'UTC$sign${two(offset ~/ 60)}:${two(offset % 60)}';
}

String cloudBillingMoney(int amount, String currency) {
  final decimal = (amount % 100).toString().padLeft(2, '0');
  return '${currency == 'CNY' ? '¥' : '$currency '}${amount ~/ 100}.$decimal';
}

String cloudBillingProvider(String provider) => switch (provider) {
  'wechat' || 'wechat_pay' || 'wechatpay' => '微信支付',
  'alipay' => '支付宝',
  'waffo_pancake' => '微信支付',
  _ => provider,
};

String _periodLabel(int seconds) => '${seconds ~/ _daySeconds} 天';

class CloudBillingOffer {
  CloudBillingOffer.fromJson(Map<String, dynamic> json)
    : id = json['plan_id'] as String,
      amount = json['amount_minor'] as int,
      currency = json['currency'] as String,
      provider = json['provider'] as String,
      terms = json['terms_version'] as String,
      seconds = json['period_seconds'] as int,
      modes = (json['purchase_modes'] as List).whereType<String>().toSet();

  final String id, currency, provider, terms;
  final int amount, seconds;
  final Set<String> modes;
  String get price => cloudBillingMoney(amount, currency);
  String get periodLabel => _periodLabel(seconds);
  bool get isWaffo => provider == 'waffo_pancake';
  bool get valid =>
      id.isNotEmpty &&
      terms.isNotEmpty &&
      provider.isNotEmpty &&
      currency == 'CNY' &&
      amount > 0 &&
      (id == 'cloud-365d'
          ? isWaffo &&
                seconds == _annualSeconds &&
                modes.length == 1 &&
                modes.contains(CloudPurchaseMode.single.wireName)
          : seconds == _monthlySeconds);

  bool sameQuote(CloudBillingOffer other) =>
      id == other.id &&
      terms == other.terms &&
      provider == other.provider &&
      amount == other.amount &&
      currency == other.currency &&
      seconds == other.seconds;
}

class CloudBillingDiscovery {
  CloudBillingDiscovery.fromJson(Map<String, dynamic> json)
    : capabilities = (json['capabilities'] as List).whereType<String>().toSet(),
      serverTime = _time(json['server_time']);

  final Set<String> capabilities;
  final DateTime? serverTime;
  bool get canBuy =>
      cloudBillingPurchasesAllowed && capabilities.contains('billing_checkout');
  bool allows(CloudPurchaseMode mode) =>
      canBuy &&
      (mode == CloudPurchaseMode.single ||
          capabilities.contains('billing_auto_renew'));
}

class CloudBillingOrder {
  CloudBillingOrder.fromJson(Map<String, dynamic> json)
    : id = json['checkout_id'] as String,
      planId = json['plan_id'] as String,
      mode = json['purchase_mode'] as String,
      amount = json['amount_minor'] as int,
      seconds = json['period_seconds'] as int,
      currency = json['currency'] as String,
      terms = json['terms_version'] as String,
      provider = json['provider'] as String,
      status = json['status'] as String,
      canResumeCheckout = json['can_resume_checkout'] == true,
      created = _time(json['created_at'])!,
      paid = _time(json['paid_at']),
      periodEnd = _time(json['period_end']);

  final String id, planId, mode, currency, terms, provider, status;
  final int amount, seconds;
  final bool canResumeCheckout;
  final DateTime created;
  final DateTime? paid, periodEnd;

  String get price => cloudBillingMoney(amount, currency);
  String get periodLabel => _periodLabel(seconds);

  String get statusLabel => switch (status) {
    'pending' => '待付款',
    'submitting' || 'processing' => '付款结果待确认',
    'paid' => '已付款',
    'closed' => '已关闭',
    'failed' => '付款未成功',
    'refund_pending' => '退款处理中',
    'refunded' => '已退款',
    _ => '订单状态待确认',
  };

  bool get blocksPurchase => status == 'submitting' || status == 'processing';
  bool get awaitingPayment => status == 'pending' || blocksPurchase;
  bool matches(CloudBillingOffer offer, CloudPurchaseMode purchaseMode) =>
      planId == offer.id &&
      mode == purchaseMode.wireName &&
      terms == offer.terms &&
      amount == offer.amount &&
      currency == offer.currency &&
      provider == offer.provider &&
      seconds == offer.seconds;
}

class CloudBillingSubscription {
  CloudBillingSubscription.fromJson(Map<String, dynamic> json)
    : status = json['agreement_status'] as String,
      autoRenew = json['auto_renew'] == true,
      currentEnd = _time(json['current_period_end']),
      paidEnd = _time(json['paid_period_end']),
      nextCharge = _time(json['next_charge_at']),
      nextAmount = json['next_charge_amount_minor'] as int?,
      currency = json['currency'] as String?,
      provider = json['provider'] as String?,
      inFlight = switch (json['in_flight_order']) {
        final Map<String, dynamic> order => CloudBillingOrder.fromJson(order),
        _ => null,
      };

  final String status;
  final bool autoRenew;
  final DateTime? currentEnd, paidEnd, nextCharge;
  final int? nextAmount;
  final String? currency, provider;
  final CloudBillingOrder? inFlight;

  bool get canCancel => status == 'pending' || status == 'active';
  bool get canStartRenewal =>
      const {'none', 'canceled', 'expired'}.contains(status);
  String get renewalLabel => switch (status) {
    'none' => '未开通',
    'pending' => '签约待确认',
    'active' => autoRenew ? '已开启' : '状态待确认',
    'canceling' => '关闭处理中',
    'canceled' => '已关闭',
    'expired' => '已到期',
    _ => '状态待确认',
  };
}

class CloudBillingCheckout {
  CloudBillingCheckout.fromJson(Map<String, dynamic> json)
    : id = json['checkout_id'] as String,
      expiresAt = _time(json['expires_at']),
      url = _checkoutUri(json['url'], json['checkout_id'] as String) {
    if ((url == null) != (expiresAt == null)) {
      throw const FormatException('Invalid checkout response');
    }
  }

  final String id;
  final DateTime? expiresAt;
  final Uri? url;

  static Uri? _checkoutUri(Object? raw, String id) {
    if (raw == null) return null;
    final url = raw is String ? Uri.tryParse(raw) : null;
    if (url == null ||
        url.scheme != 'https' ||
        url.authority != Uri.parse(officialCloudOrigin).authority ||
        url.hasQuery ||
        !RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        ).hasMatch(id) ||
        url.path != '/v1/billing/checkout/$id' ||
        !RegExp(r'^ticket=[A-Za-z0-9_-]+$').hasMatch(url.fragment)) {
      throw const FormatException('Unsafe checkout URL');
    }
    return url;
  }
}

/// A billing dialog belongs to the official account that was active when
/// opened. The legacy :8443 API is trusted; browser handoff is canonical only.
class CloudBillingClient {
  CloudBillingClient(this._auth)
    : _account = _auth.accountId,
      _server = _auth.serverId,
      _origin = _auth.origin {
    _checkAccount();
  }

  final CloudAuthService _auth;
  final String _account, _server;
  final String? _origin;

  void _checkAccount() {
    if (!_auth.connected ||
        !_auth.official ||
        _auth.origin != _origin ||
        _auth.serverId != _server ||
        _auth.accountId != _account) {
      throw CloudApiException(401, 'not_connected', {});
    }
  }

  Future<T> _read<T>(
    Future<Map<String, dynamic>> Function() request,
    T Function(Map<String, dynamic>) decode,
  ) async {
    _checkAccount();
    final result = await request();
    _checkAccount();
    return decode(result);
  }

  Future<CloudBillingDiscovery?> discover() =>
      _read(_auth.billingServerInfo, (json) {
        if (json['server_id'] != _server ||
            json['protocol_version'] != '1' ||
            json['api_base_url'] != '$_origin/v1') {
          throw const FormatException('Billing server identity mismatch');
        }
        if (json['mode'] != 'hosted') return null;
        final info = CloudBillingDiscovery.fromJson(json);
        return info.capabilities.contains('subscription') ? info : null;
      });

  Future<CloudBillingSubscription> subscription() => _read(
    () => _auth.request('GET', '/v1/billing/subscription', null),
    CloudBillingSubscription.fromJson,
  );

  Future<List<CloudBillingOffer>> offers() => _read(
    () => _auth.request('GET', '/v1/billing/plans', null),
    (json) => (json['plans'] as List)
        .cast<Map<String, dynamic>>()
        .map(CloudBillingOffer.fromJson)
        .where((offer) => offer.valid)
        .toList(),
  );

  Future<List<CloudBillingOrder>> orders() => _read(
    () => _auth.request('GET', '/v1/billing/orders', null),
    (json) => (json['orders'] as List)
        .cast<Map<String, dynamic>>()
        .map(CloudBillingOrder.fromJson)
        .toList(),
  );

  Future<CloudBillingOrder> order(String id) => _read(
    () => _auth.request(
      'GET',
      '/v1/billing/orders/${Uri.encodeComponent(id)}',
      null,
    ),
    (json) {
      final order = CloudBillingOrder.fromJson(json);
      if (order.id != id) {
        throw const FormatException('Order identity mismatch');
      }
      return order;
    },
  );

  Future<CloudBillingSubscription> cancelRenewal() => _read(
    () => _auth.request('POST', '/v1/billing/subscription/cancel', null),
    CloudBillingSubscription.fromJson,
  );

  Future<CloudBillingOrder> closePendingOrder(CloudBillingOrder order) => _read(
    () => _auth.request(
      'POST',
      '/v1/billing/orders/${Uri.encodeComponent(order.id)}/close',
      null,
    ),
    CloudBillingOrder.fromJson,
  );

  Future<CloudBillingCheckout> checkout(
    CloudBillingOffer offer,
    CloudPurchaseMode mode,
    String key, {
    String? expectedOrderId,
  }) => _read(
    () => _auth.createBillingCheckout({
      'plan_id': offer.id,
      'purchase_mode': mode.wireName,
      'terms_version': offer.terms,
      if (expectedOrderId != null && offer.isWaffo)
        'expected_checkout_id': expectedOrderId,
    }, key),
    (json) {
      final checkout = CloudBillingCheckout.fromJson(json);
      if (expectedOrderId != null && checkout.id != expectedOrderId) {
        throw const FormatException('Checkout identity mismatch');
      }
      return checkout;
    },
  );
}
