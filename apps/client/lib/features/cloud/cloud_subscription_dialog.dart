import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';
import 'package:window_manager/window_manager.dart';

import 'cloud_auth_service.dart';
import 'cloud_billing_client.dart';
import 'cloud_connection.dart';

Future<void> openCloudSubscription(
  BuildContext context,
  CloudConnection cloud, {
  bool orders = false,
}) async {
  if (!cloud.connected || !cloud.auth.official) return;
  final client = CloudBillingClient(cloud.auth);
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => CloudSubscriptionDialog(
      client: client,
      refreshEntitlements: cloud.refreshEntitlements,
      ordersOnly: orders,
    ),
  );
}

class CloudSubscriptionDialog extends StatefulWidget {
  const CloudSubscriptionDialog({
    super.key,
    required this.client,
    required this.refreshEntitlements,
    this.ordersOnly = false,
    this.launchCheckout,
  });

  final CloudBillingClient client;
  final Future<void> Function() refreshEntitlements;
  final bool ordersOnly;
  final Future<bool> Function(Uri)? launchCheckout;

  @override
  State<CloudSubscriptionDialog> createState() =>
      _CloudSubscriptionDialogState();
}

class _CloudSubscriptionDialogState extends State<CloudSubscriptionDialog>
    with WidgetsBindingObserver, WindowListener {
  static const _orderCheckDelays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
  ];

  CloudBillingDiscovery? _discovery;
  CloudBillingSubscription? _subscription;
  List<CloudBillingOffer> _offers = [];
  List<CloudBillingOrder>? _orders;
  ({CloudBillingOffer offer, CloudPurchaseMode mode, String key})? _attempt;
  String? _checkoutId;
  String? _notice;
  String? _error;
  String? _entitlementError;
  Timer? _orderCheckTimer;
  int _orderCheckIndex = 0;
  bool _loading = false;
  bool _confirming = false;
  bool _mutating = false;
  bool _browserOpen = false;
  bool _foreground = true;
  bool _returnPending = false;
  bool _unavailable = false;

  CloudBillingClient get _client => widget.client;
  bool get _windows => Theme.of(context).platform == TargetPlatform.windows;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  bool _watchingWindow = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_windows == _watchingWindow) return;
    _watchingWindow = _windows;
    if (_watchingWindow) {
      windowManager.addListener(this);
    } else {
      windowManager.removeListener(this);
    }
  }

  @override
  void dispose() {
    _orderCheckTimer?.cancel();
    if (_watchingWindow) windowManager.removeListener(this);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_watchingWindow) _setForeground(state == AppLifecycleState.resumed);
  }

  @override
  void onWindowFocus() => _setForeground(true);

  @override
  void onWindowBlur() => _setForeground(false);

  void _setForeground(bool foreground) {
    if (_foreground == foreground) return;
    _foreground = foreground;
    _orderCheckTimer?.cancel();
    _returnPending = foreground && _checkoutId != null;
    _checkReturnedOrder();
  }

  void _checkReturnedOrder() {
    if (!_returnPending || !_foreground || _loading || _mutating) return;
    _returnPending = false;
    if (_checkoutId case final id?) {
      unawaited(_checkOrder(id, refreshAccess: true));
    }
  }

  Future<void> _checkOrder(String id, {required bool refreshAccess}) async {
    setState(() {
      _loading = true;
      _browserOpen = false;
      _notice = '正在核对付款结果…';
      _error = null;
      if (refreshAccess) _entitlementError = null;
    });
    var retry = true;
    try {
      final order = await _client.order(id);
      if (!mounted) return;
      retry = order.awaitingPayment;
      setState(() {
        final orders = _orders ?? const <CloudBillingOrder>[];
        _orders = [
          if (!orders.any((previous) => previous.id == id)) order,
          for (final previous in orders) previous.id == id ? order : previous,
        ];
        _showOrder(order);
      });
      if (!retry && !widget.ordersOnly) {
        final subscription = await _client.subscription();
        if (mounted) setState(() => _subscription = subscription);
      }
    } catch (_) {
      if (mounted) setState(() => _error = '暂时无法核对付款结果。请稍后刷新。');
    } finally {
      // The first check on return and a confirmed result update sync access.
      // Between them, only read the order; its state may lag behind the cashier.
      if (mounted && (!retry || refreshAccess)) {
        await _refreshSyncAccess();
      }
      if (mounted) {
        setState(() => _loading = false);
        if (_returnPending) {
          _checkReturnedOrder();
        } else if (retry &&
            _checkoutId == id &&
            _foreground &&
            _orderCheckIndex < _orderCheckDelays.length) {
          _orderCheckTimer = Timer(_orderCheckDelays[_orderCheckIndex++], () {
            if (_checkoutId == id && _foreground && !_loading && !_mutating) {
              unawaited(_checkOrder(id, refreshAccess: false));
            }
          });
        }
      }
    }
  }

  Future<void> _refreshSyncAccess() async {
    try {
      await widget.refreshEntitlements();
      if (mounted && _entitlementError != null) {
        setState(() => _entitlementError = null);
      }
    } catch (_) {
      if (mounted) setState(() => _entitlementError = '同步权限暂未刷新，请稍后重试。');
    }
  }

  void _showOrder(CloudBillingOrder order) {
    _notice = switch (order.status) {
      'pending' => _browserOpen ? null : '订单尚未确认付款。若已付款，请勿重复支付。',
      'submitting' || 'processing' => null,
      _ => '最近订单：${order.statusLabel}。',
    };
    if (!order.awaitingPayment) {
      _attempt = null;
      _checkoutId = null;
      _browserOpen = false;
      _orderCheckTimer?.cancel();
    }
  }

  Future<void> _refresh({bool entitlements = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      if (entitlements) _entitlementError = null;
    });
    try {
      final info = await _client.discover();
      if (info == null) {
        if (mounted) setState(() => _unavailable = true);
        return;
      }
      final subscription = widget.ordersOnly
          ? null
          : await _client.subscription();
      if (!mounted) return;
      setState(() {
        _unavailable = false;
        _discovery = info;
        _subscription = subscription;
      });
      // The order list also protects against offering another purchase while a
      // previous browser order is still waiting for payment or confirmation.
      final orders = await _client.orders();
      if (!mounted) return;
      setState(() {
        _orders = orders;
        for (final order in orders) {
          final attempt = _attempt;
          if (_checkoutId == null &&
              attempt != null &&
              order.awaitingPayment &&
              order.matches(attempt.offer, attempt.mode)) {
            _checkoutId = order.id;
          }
          if (_checkoutId == null && attempt == null && order.blocksPurchase) {
            _checkoutId = order.id;
          }
          if (_checkoutId != null && order.id == _checkoutId) {
            _showOrder(order);
            break;
          }
        }
      });
      final offers = !widget.ordersOnly && info.canBuy
          ? await _client.offers()
          : <CloudBillingOffer>[];
      if (mounted) setState(() => _offers = offers);
    } on CloudApiException catch (error) {
      if (mounted) {
        setState(() {
          if (error.status == 404 && _orders == null && _subscription == null) {
            _unavailable = true; // Older official servers before billing.
          } else {
            _error = '暂时无法更新订阅记录。请刷新后重试。';
          }
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '暂时无法更新订阅记录。请刷新后重试。');
    } finally {
      if (entitlements && mounted) await _refreshSyncAccess();
      if (mounted) {
        setState(() => _loading = false);
        _checkReturnedOrder();
      }
    }
  }

  CloudBillingOrder? get _pending {
    for (final order in _orders ?? const <CloudBillingOrder>[]) {
      if (order.status == 'pending') return order;
    }
    return null;
  }

  bool get _processing => _processingOrder != null;

  CloudBillingOrder? get _processingOrder {
    for (final order in _orders ?? const <CloudBillingOrder>[]) {
      if (order.blocksPurchase) return order;
    }
    return _subscription?.inFlight;
  }

  ({CloudBillingOrder order, CloudBillingOffer offer})? get _resumableCheckout {
    const mode = CloudPurchaseMode.single;
    for (final order in _orders ?? const <CloudBillingOrder>[]) {
      if (order.status != 'processing' || !order.canResumeCheckout) continue;
      for (final offer in _offers) {
        if (offer.isWaffo &&
            _allowsOffer(offer, mode) &&
            order.matches(offer, mode)) {
          return (order: order, offer: offer);
        }
      }
    }
    return null;
  }

  bool _allowsOffer(CloudBillingOffer offer, CloudPurchaseMode mode) =>
      _discovery?.allows(mode) == true && offer.modes.contains(mode.wireName);

  bool _available(CloudBillingOffer offer, CloudPurchaseMode mode) {
    if (!_allowsOffer(offer, mode)) return false;
    final pending = _pending;
    if (pending != null && !pending.matches(offer, mode)) return false;
    if (_attempt case final attempt?) {
      return attempt.mode == mode && attempt.offer.sameQuote(offer);
    }
    if (pending != null) return true;
    final subscription = _subscription;
    return subscription != null &&
        (mode == CloudPurchaseMode.single
            ? subscription.canStartRenewal || subscription.status == 'active'
            : subscription.canStartRenewal && _discovery?.serverTime != null);
  }

  bool get _checkoutBusy =>
      _loading ||
      _confirming ||
      _mutating ||
      _browserOpen ||
      _error != null ||
      _unavailable;

  bool get _purchaseBlocked => _checkoutBusy || _processing;

  void _manualRefresh() {
    _orderCheckTimer?.cancel();
    _browserOpen = false;
    unawaited(_refresh(entitlements: true));
  }

  Future<void> _buy(CloudBillingOffer offer, CloudPurchaseMode mode) async {
    if (_purchaseBlocked || !_available(offer, mode)) return;
    final expectedOrderId = _checkoutId ?? _pending?.id;
    _confirming = true;
    final bool? confirmed;
    try {
      confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => _PurchaseConfirmation(
          offer: offer,
          mode: mode,
          serverTime: _discovery!.serverTime,
          currentEnd: _subscription?.currentEnd,
          alreadyRenews: _subscription?.autoRenew == true,
          resuming: expectedOrderId != null || _attempt != null,
        ),
      );
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
    if (!mounted ||
        confirmed != true ||
        _purchaseBlocked ||
        !_offers.any(
          (current) => current.sameQuote(offer) && _available(current, mode),
        )) {
      return;
    }
    await _openCheckout(offer, mode, expectedOrderId ?? _pending?.id);
  }

  Future<void> _resumeCheckout() async {
    if (_checkoutBusy) return;
    if (_resumableCheckout case final resume?) {
      await _openCheckout(
        resume.offer,
        CloudPurchaseMode.single,
        resume.order.id,
      );
    }
  }

  Future<void> _openCheckout(
    CloudBillingOffer offer,
    CloudPurchaseMode mode,
    String? expectedOrderId,
  ) async {
    final prior = _attempt;
    final attempt =
        prior != null && prior.mode == mode && prior.offer.sameQuote(offer)
        ? prior
        : (offer: offer, mode: mode, key: const Uuid().v4());
    setState(() {
      _attempt = attempt;
      _mutating = true;
      _notice = '正在准备收银台…';
    });
    String? problem;
    var browserOpened = false;
    try {
      final checkout = await _client.checkout(
        offer,
        mode,
        attempt.key,
        expectedOrderId: expectedOrderId,
      );
      _checkoutId = checkout.id;
      if (!mounted) return;
      final url = checkout.url;
      if (url == null) {
        setState(() => _notice = '正在核对原订单…');
      } else {
        _orderCheckTimer?.cancel();
        _orderCheckIndex = 0;
        setState(() {
          _browserOpen = true;
          _notice = null;
        });
        try {
          browserOpened =
              await (widget.launchCheckout?.call(url) ??
                  launchUrl(url, mode: LaunchMode.externalApplication));
        } catch (_) {
          // A launcher failure doesn't cancel the original order.
        }
        if (!browserOpened) {
          _browserOpen = false;
          problem = '未能打开浏览器。可继续支付原订单。';
        }
      }
    } on CloudApiException catch (error) {
      if (const {
        'billing_not_configured',
        'billing_plan_unavailable',
        'invalid_checkout',
        'invalid_json',
        'invalid_idempotency_key',
        'billing_terms_changed',
        'auto_renew_unavailable',
        'billing_agreement_open',
        'billing_order_unresolved',
        'billing_period_already_reserved',
        'idempotency_key_reused',
      }.contains(error.code)) {
        // The server definitively rejected this offer, before starting payment.
        _attempt = null;
        problem = switch (error.code) {
          'billing_period_already_reserved' => '已有一笔预购权益，暂不能再购买。',
          'billing_order_unresolved' => '请先核对已有订单的状态。',
          _ => '此报价已不可用，请查看刷新后的购买选项。',
        };
      } else {
        problem = '订单结果待确认。可刷新，或按原选项继续。';
      }
    } catch (_) {
      problem = '订单结果待确认。可刷新，或按原选项继续。';
    } finally {
      if (mounted) {
        if (!browserOpened) await _refresh(entitlements: true);
        if (mounted) {
          setState(() {
            _mutating = false;
            if (problem != null) _notice = problem;
          });
          _checkReturnedOrder();
        }
      }
    }
  }

  Future<void> _cancelRenewal() async {
    if (_loading || _mutating || _subscription?.canCancel != true) return;
    setState(() {
      _mutating = true;
      _notice = null;
    });
    String? problem;
    try {
      final updated = await _client.cancelRenewal();
      if (mounted) setState(() => _subscription = updated);
    } catch (_) {
      problem = '关闭结果待确认，请查看刷新后的状态。';
    } finally {
      if (mounted) {
        await _refresh(entitlements: true);
        if (mounted) {
          setState(() {
            _mutating = false;
            if (problem != null && (_subscription?.canCancel ?? true)) {
              _notice = problem;
            }
          });
          _checkReturnedOrder();
        }
      }
    }
  }

  Future<void> _closePendingOrder(CloudBillingOrder order) async {
    if (_purchaseBlocked) return;
    setState(() {
      _mutating = true;
      _notice = null;
      _checkoutId = order.id;
    });
    String? problem;
    try {
      final closed = await _client.closePendingOrder(order);
      if (closed.status == 'closed') {
        _attempt = null;
        _browserOpen = false;
      }
    } on CloudApiException catch (error) {
      problem = error.code == 'billing_order_processing'
          ? '付款结果待确认，请勿重复付款。'
          : '订单关闭结果待确认，请刷新查看。';
    } catch (_) {
      problem = '订单关闭结果待确认，请刷新查看。';
    } finally {
      if (mounted) {
        await _refresh(entitlements: true);
        if (mounted) {
          setState(() {
            _mutating = false;
            if (problem != null && _checkoutId == order.id) _notice = problem;
          });
          _checkReturnedOrder();
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope<void>(
      canPop: !_mutating,
      child: GlassAlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        title: Text(widget.ordersOnly ? '云同步订单' : '管理订阅'),
        content: SizedBox(
          width: 424,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_loading || _mutating)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 14),
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                if (_unavailable)
                  Text(widget.ordersOnly ? '当前服务器不提供订单记录。' : '当前服务器不提供订阅管理。')
                else if (widget.ordersOnly)
                  ..._buildOrders(theme)
                else if (_subscription case final subscription?)
                  ..._buildSubscription(theme, subscription)
                else if (_loading)
                  const Text('正在读取官方云订阅…'),
                if (_notice case final notice?)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Semantics(liveRegion: true, child: Text(notice)),
                  ),
                if (_error case final error?)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        error,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  ),
                if (_entitlementError case final error?)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Semantics(liveRegion: true, child: Text(error)),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _mutating || _loading ? null : _manualRefresh,
            child: const Text('刷新'),
          ),
          TextButton(
            onPressed: _mutating ? null : () => Navigator.pop(context),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildSubscription(ThemeData theme, CloudBillingSubscription s) {
    final pending = _pending;
    final resume = _resumableCheckout;
    final processing = _processingOrder;
    final browserOffer = _browserOpen ? _attempt?.offer : null;
    final continuing = pending != null || _attempt != null;
    final oneTimeWaffo = _offers.any(
      (offer) => offer.isWaffo && _allowsOffer(offer, CloudPurchaseMode.single),
    );
    final choices = [
      for (final offer in _offers)
        for (final mode in CloudPurchaseMode.values)
          if (_available(offer, mode)) (offer: offer, mode: mode),
    ];
    final compare =
        !continuing &&
        choices.length > 1 &&
        choices.every(
          (choice) =>
              choice.offer.isWaffo && choice.mode == CloudPurchaseMode.single,
        );
    final paidEnd = s.paidEnd;
    final serverTime = _discovery?.serverTime;
    final saleOpen = _offers.any(
      (offer) =>
          CloudPurchaseMode.values.any((mode) => _allowsOffer(offer, mode)),
    );
    return [
      if (_error != null)
        Text('下方为上次确认的订阅状态。', style: theme.textTheme.bodySmall),
      Text('WeekGlass 云', style: theme.textTheme.titleMedium),
      const SizedBox(height: 8),
      Text(
        s.currentEnd == null
            ? '当前没有有效的云同步写入权益'
            : '同步权益截止：${cloudBillingTime(s.currentEnd!)}',
      ),
      if (paidEnd != null && paidEnd != s.currentEnd)
        Text('已付权益截止：${cloudBillingTime(paidEnd)}'),
      if (!oneTimeWaffo || s.status != 'none') Text('自动续费：${s.renewalLabel}'),
      if (s.provider case final provider?)
        Text('付款渠道：${cloudBillingProvider(provider)}'),
      if (s.autoRenew && s.nextCharge != null)
        Text(
          '下次扣费：${cloudBillingTime(s.nextCharge!)}'
          '${s.nextAmount != null && s.currency != null ? ' · ${cloudBillingMoney(s.nextAmount!, s.currency!)}' : ''}',
        ),
      if (s.autoRenew && s.nextCharge == null) const Text('下次扣费时间尚未确定'),
      if (s.status == 'canceled' &&
          s.currentEnd != null &&
          serverTime != null &&
          s.currentEnd!.isAfter(serverTime))
        const Text('已关闭自动续费，本期仍可同步至权益截止。'),
      if (s.status == 'canceling') const Text('已申请关闭，正在确认解约结果。'),
      if (!_browserOpen && processing != null) ...[
        const Divider(height: 26),
        Text(
          '原订单：${processing.periodLabel} · ${processing.price}',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        Text(
          resume != null
              ? '付款结果待确认。若尚未付款，可继续原订单；若已付款，请等待确认。'
              : '已有付款在处理，结果待确认。请勿重复付款。',
        ),
      ],
      if (!_browserOpen && resume != null) ...[
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _checkoutBusy ? null : _resumeCheckout,
          child: const Text('返回收银台继续支付'),
        ),
      ],
      if (browserOffer != null) ...[
        const Divider(height: 26),
        Text(
          '订单：${browserOffer.periodLabel} · ${browserOffer.price}',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        Semantics(
          liveRegion: true,
          child: const Text('请在浏览器中完成付款。返回 WeekGlass 后会自动核对。'),
        ),
      ],
      if (s.canCancel)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: OutlinedButton(
            onPressed: _loading || _mutating ? null : _cancelRenewal,
            child: const Text('关闭自动续费'),
          ),
        ),
      if (!_browserOpen && processing == null && choices.isNotEmpty) ...[
        const Divider(height: 26),
        Text(
          continuing
              ? '未完成订单'
              : compare
              ? '选择同步时长'
              : oneTimeWaffo
              ? '一次购买云同步'
              : '购买云同步',
          style: theme.textTheme.titleMedium,
        ),
        if (!continuing && oneTimeWaffo) ...[
          const SizedBox(height: 4),
          Text(
            '微信支付 · 单次购买，不自动续费',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 10),
        for (var i = 0; i < choices.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _purchaseOption(
            choices[i].offer,
            choices[i].mode,
            continuing,
            compare,
          ),
        ],
      ] else if (!_browserOpen && pending != null && processing == null) ...[
        const Divider(height: 26),
        Text(
          '待付款：${pending.periodLabel} · ${pending.price}',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        const Text('原订单报价已不可用。若尚未付款，可关闭订单后重新选择。'),
      ] else if (!_browserOpen &&
          processing == null &&
          !_loading &&
          _error == null)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            _attempt != null
                ? '原订单结果待确认，暂无可继续的报价。'
                : !saleOpen
                ? '当前未开放购买。'
                : switch (s.status) {
                    'active' => '已有自动续费协议。',
                    'pending' => '签约结果确认后可再购买。',
                    'canceling' => '解约结果确认后可再购买。',
                    _ => '暂时没有可用的购买选项。',
                  },
          ),
        ),
      if (!_browserOpen && pending != null && processing == null)
        TextButton(
          onPressed: _purchaseBlocked
              ? null
              : () => _closePendingOrder(pending),
          child: const Text('关闭未支付订单'),
        ),
    ];
  }

  Widget _purchaseOption(
    CloudBillingOffer offer,
    CloudPurchaseMode mode,
    bool continuing,
    bool compare,
  ) {
    final VoidCallback? onPressed = _purchaseBlocked
        ? null
        : () => _buy(offer, mode);
    if (compare) return _PlanButton(offer: offer, onPressed: onPressed);
    if (offer.isWaffo && mode == CloudPurchaseMode.single) {
      final action = continuing ? '继续支付原订单 · ' : '购买 ';
      return FilledButton(
        onPressed: onPressed,
        child: Text('$action${offer.periodLabel} · ${offer.price}'),
      );
    }
    return OutlinedButton(
      onPressed: onPressed,
      child: Text(
        '${continuing ? '继续支付 · ' : ''}${mode.label(offer)} · ${offer.price}',
      ),
    );
  }

  List<Widget> _buildOrders(ThemeData theme) {
    final orders = _orders;
    if (orders == null) return [if (_loading) const Text('正在读取订单…')];
    if (orders.isEmpty) return const [Text('暂无云同步订单。')];
    return [
      if (_error != null)
        Text('下方为上次确认的订单记录。', style: theme.textTheme.bodySmall),
      for (final order in orders) ...[
        Text(
          '${order.statusLabel} · ${order.price}',
          style: theme.textTheme.titleSmall,
        ),
        Text(
          '${order.periodLabel} · '
          '${order.mode == 'auto_renew' ? '自动续费' : '单次购买'} · '
          '${cloudBillingProvider(order.provider)}',
        ),
        Text(
          '下单：${cloudBillingTime(order.created)}',
          style: theme.textTheme.bodySmall,
        ),
        if (order.paid case final time?)
          Text(
            '付款：${cloudBillingTime(time)}',
            style: theme.textTheme.bodySmall,
          ),
        if (order.periodEnd case final time?)
          Text(
            '本单权益截止：${cloudBillingTime(time)}',
            style: theme.textTheme.bodySmall,
          ),
        SelectableText('订单号：${order.id}', style: theme.textTheme.bodySmall),
        if (!identical(orders.last, order)) const Divider(height: 24),
      ],
    ];
  }
}

class _PlanButton extends StatelessWidget {
  const _PlanButton({required this.offer, required this.onPressed});

  final CloudBillingOffer offer;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return OutlinedButton(
      key: ValueKey(offer.id),
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: colors.onSurface,
        backgroundColor: colors.primary.withValues(alpha: .045),
        minimumSize: const Size(0, 52),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      ),
      child: Row(
        children: [
          Expanded(
            child: OverflowBar(
              alignment: MainAxisAlignment.spaceBetween,
              spacing: 12,
              overflowSpacing: 2,
              children: [
                Text(offer.periodLabel, style: theme.textTheme.titleMedium),
                Text(
                  offer.price,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: onPressed == null ? null : colors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            Icons.chevron_right_rounded,
            size: 19,
            color: onPressed == null ? null : colors.primary,
          ),
        ],
      ),
    );
  }
}

class _PurchaseConfirmation extends StatelessWidget {
  const _PurchaseConfirmation({
    required this.offer,
    required this.mode,
    required this.serverTime,
    required this.currentEnd,
    required this.alreadyRenews,
    required this.resuming,
  });

  final CloudBillingOffer offer;
  final CloudPurchaseMode mode;
  final DateTime? serverTime, currentEnd;
  final bool alreadyRenews, resuming;

  @override
  Widget build(BuildContext context) {
    final renew = mode == CloudPurchaseMode.autoRenew;
    final now = serverTime;
    final current = currentEnd;
    final start = now != null && current != null && current.isAfter(now)
        ? current
        : now;
    final expected = start?.add(Duration(seconds: offer.seconds));
    return GlassAlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      title: Text(
        resuming
            ? '继续支付原订单'
            : offer.isWaffo && !renew
            ? '确认一次购买'
            : mode.label(offer),
      ),
      content: SizedBox(
        width: 390,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${renew ? '首期' : '本次付款'}：${offer.price} / ${offer.periodLabel}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 10),
              Text('付款渠道：${cloudBillingProvider(offer.provider)}'),
              if (renew) ...[
                Text('此后每 ${offer.periodLabel}续费 ${offer.price}。'),
                if (expected != null)
                  Text('预计首次续费：${cloudBillingTime(expected)}，以签约和到账确认时间为准。'),
                const SizedBox(height: 8),
                const Text('签约由支付平台确认。可随时在「云同步 → 管理订阅」关闭自动续费。'),
              ] else
                Text(
                  alreadyRenews
                      ? '本次付款接续 ${offer.periodLabel}，现有自动续费协议保持不变。'
                      : '确认到账后增加 ${offer.periodLabel}云同步权益。\n到期不会自动续费。',
                ),
              const SizedBox(height: 10),
              const Text('云端故障可能导致尚未下载到设备的日程丢失。你可在账号设置中导出日程。'),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('前往收银台'),
        ),
      ],
    );
  }
}
