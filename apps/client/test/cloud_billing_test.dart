import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weekglass/features/cloud/cloud_auth_service.dart';
import 'package:weekglass/features/cloud/cloud_billing_client.dart';
import 'package:weekglass/features/cloud/cloud_subscription_dialog.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';
import 'package:window_manager/window_manager.dart';

import 'cloud_auth_test.dart' show MemoryVault, tokens;

const _id = '66666666-6666-4666-8666-666666666666';
const _url = '$officialCloudOrigin/v1/billing/checkout/$_id#ticket=opaque';
const _captureDir = String.fromEnvironment('WG_BILLING_QA_DIR');
const _waffoTerms = 'waffo-cny-30d-v1';
const _annualTerms = 'waffo-cny-365d-v1';
const _waffoPurchase = '购买 30 天 · ¥1.00';
const _waffoContinue = '继续支付原订单 · 30 天 · ¥1.00';
const _annualContinue = '继续支付原订单 · 365 天 · ¥9.99';
const _monthlyChoice = ValueKey('cloud-30d');
const _annualChoice = ValueKey('cloud-365d');
const _monthlySeconds = 2592000;
const _annualSeconds = 31536000;

class _BillingServer {
  String origin = officialCloudOrigin;
  String mode = 'hosted';
  String agreement = 'none';
  String? orderStatus;
  String? orderMode;
  String? orderPlanId;
  int? orderSeconds;
  String provider = 'wechat';
  String planId = 'cloud-30';
  int amount = 599;
  String orderTerms = 'v1';
  bool replacePendingOnCheckout = false;
  String checkoutUrl = _url;
  bool acceptsPurchases = true;
  bool acceptsRenewal = true;
  bool canResumeCheckout = false;
  String offerTerms = 'v1';
  bool showPlan = true;
  bool showAnnual = false;
  int annualOfferSeconds = _annualSeconds;
  String annualOfferTerms = _annualTerms;
  List<String> annualOfferModes = ['single'];
  bool renewalOnly = false;
  bool loseCheckoutResponse = false;
  bool cancelTimesOut = false;
  bool closeRacesPayment = false;
  bool offline = false;
  int cancelRequests = 0;
  int entitlementReads = 0;
  final keys = <String>[];
  final checkouts = <Map<String, dynamic>>[];
  final requests = <String>[];

  factory _BillingServer.waffo() => _BillingServer()
    ..provider = 'waffo_pancake'
    ..planId = 'cloud-30d'
    ..amount = 100
    ..orderTerms = _waffoTerms
    ..offerTerms = _waffoTerms
    ..acceptsRenewal = false;

  _BillingServer();

  bool get _annualOrder => orderPlanId == 'cloud-365d';
  String get periodEnd =>
      _annualOrder ? '2027-11-13T08:00:02Z' : '2026-12-13T08:00:02Z';

  Map<String, dynamic> get order => {
    'checkout_id': _id,
    'plan_id': orderPlanId ?? planId,
    'purchase_mode': orderMode ?? 'single',
    'amount_minor': _annualOrder ? 999 : amount,
    'currency': 'CNY',
    'period_seconds':
        orderSeconds ?? (_annualOrder ? _annualSeconds : _monthlySeconds),
    'terms_version': _annualOrder ? _annualTerms : orderTerms,
    'provider': provider,
    'status': orderStatus,
    if (canResumeCheckout) 'can_resume_checkout': true,
    'created_at': '2026-11-13T08:00:00Z',
    'paid_at': orderStatus == 'paid' ? '2026-11-13T08:00:02Z' : null,
    'period_end': orderStatus == 'paid' ? periodEnd : null,
  };

  Map<String, dynamic> get subscription => {
    'agreement_status': agreement,
    'auto_renew': agreement == 'active',
    'current_period_end': agreement != 'none' || orderStatus == 'paid'
        ? periodEnd
        : null,
    'paid_period_end': agreement != 'none' || orderStatus == 'paid'
        ? periodEnd
        : null,
    'provider': agreement != 'none' ? provider : null,
    'next_charge_at': agreement == 'active' ? '2026-12-13T08:00:00Z' : null,
    'next_charge_amount_minor': agreement == 'active' ? 599 : null,
    'currency': agreement == 'active' ? 'CNY' : null,
    'in_flight_order':
        orderStatus == 'processing' || orderStatus == 'submitting'
        ? order
        : null,
  };

  Future<CloudAuthService> auth() async {
    final vault = MemoryVault()
      ..value = jsonEncode({
        ...tokens(),
        'origin': origin,
        'merge_approved': true,
      });
    final auth = CloudAuthService(
      vault: vault,
      transport: (uri, method, body, headers, form) async {
        expectSync(uri.origin, origin);
        requests.add('$method ${uri.path}');
        if (offline) throw TimeoutException('offline');
        switch (uri.path) {
          case '/v1/server-info':
            expectSync(headers, isEmpty);
            return {
              'protocol_version': '1',
              'server_id': tokens()['server_id'],
              'api_base_url': '$origin/v1',
              'mode': mode,
              'server_time': '2026-11-13T08:00:00Z',
              'capabilities': [
                'subscription',
                if (acceptsPurchases) 'billing_checkout',
                if (acceptsRenewal) 'billing_auto_renew',
              ],
            };
          case '/v1/billing/subscription':
            return subscription;
          case '/v1/billing/plans':
            return {
              'plans': [
                if (showPlan)
                  {
                    'plan_id': planId,
                    'amount_minor': amount,
                    'currency': 'CNY',
                    'period_seconds': _monthlySeconds,
                    'terms_version': offerTerms,
                    'provider': provider,
                    'purchase_modes': [
                      if (!renewalOnly) 'single',
                      if (provider != 'waffo_pancake') 'auto_renew',
                    ],
                  },
                if (showAnnual)
                  {
                    'plan_id': 'cloud-365d',
                    'amount_minor': 999,
                    'currency': 'CNY',
                    'period_seconds': annualOfferSeconds,
                    'terms_version': annualOfferTerms,
                    'provider': provider,
                    'purchase_modes': annualOfferModes,
                  },
              ],
            };
          case '/v1/billing/checkout-sessions':
            checkouts.add(body!);
            orderMode = body['purchase_mode'] as String;
            keys.add(headers['Idempotency-Key']!);
            expectSync(
              headers['Authorization'],
              'Bearer ${tokens()['access_token']}',
            );
            if (replacePendingOnCheckout) {
              orderStatus = 'paid';
              final id = body['expected_checkout_id'];
              if (id == _id) {
                return {'checkout_id': _id, 'url': null, 'expires_at': null};
              }
            }
            if (orderStatus == 'processing' &&
                body['expected_checkout_id'] == _id) {
              return {
                'checkout_id': _id,
                'url': canResumeCheckout ? checkoutUrl : null,
                'expires_at': canResumeCheckout ? '2026-11-13T08:10:00Z' : null,
              };
            }
            orderStatus = 'pending';
            orderPlanId = body['plan_id'] as String;
            if (loseCheckoutResponse) throw TimeoutException('unknown');
            return {
              'checkout_id': _id,
              'url': checkoutUrl,
              'expires_at': '2026-11-13T08:10:00Z',
            };
          case '/v1/billing/subscription/cancel':
            cancelRequests++;
            if (cancelTimesOut) throw TimeoutException('unknown');
            agreement = 'canceling';
            return subscription;
          case '/v1/billing/orders/$_id/close':
            if (closeRacesPayment) {
              orderStatus = 'processing';
              throw CloudApiException(409, 'billing_order_processing', {});
            }
            orderStatus = 'closed';
            return order;
          case '/v1/billing/orders/$_id':
            return order;
          case '/v1/billing/orders':
            return {
              'orders': [if (orderStatus != null) order],
            };
          default:
            throw StateError(uri.path);
        }
      },
    );
    await auth.restore();
    return auth;
  }
}

Future<GlobalKey> _open(
  WidgetTester tester,
  _BillingServer server, {
  bool orders = false,
  bool dark = false,
  TargetPlatform? platform,
  double scale = 1.0,
  Size size = const Size(390, 740),
  Future<bool> Function(Uri)? launch,
}) async {
  final client = CloudBillingClient(await server.auth());
  final frame = GlobalKey();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    RepaintBoundary(
      key: frame,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: (dark ? WeekGlassTheme.dark() : WeekGlassTheme.light()).copyWith(
          platform: platform,
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => CloudSubscriptionDialog(
                  client: client,
                  refreshEntitlements: () async {
                    server.entitlementReads++;
                  },
                  launchCheckout: launch,
                  ordersOnly: orders,
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
  return frame;
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

int _orderReads(_BillingServer server) => server.requests
    .where((request) => request == 'GET /v1/billing/orders/$_id')
    .length;

void main() {
  test('checkout handoff accepts only canonical origin and scoped ticket', () {
    CloudBillingCheckout parse(String url) => CloudBillingCheckout.fromJson({
      'checkout_id': _id,
      'expires_at': '2026-11-13T08:10:00Z',
      'url': url,
    });
    expect(parse(_url).url, Uri.parse(_url));
    for (final bad in [
      _url.replaceFirst('https', 'http'),
      _url.replaceFirst('cloud.viliana.cn', 'evil.example'),
      _url.replaceFirst('cloud.viliana.cn', 'cloud.viliana.cn:8443'),
      _url.replaceFirst('cloud.viliana.cn', 'user@cloud.viliana.cn'),
      _url.replaceFirst('checkout/', 'other/'),
      _url.replaceFirst('#', '?access_token=secret#'),
      _url.replaceFirst('opaque', 'opaque&password=secret'),
      _url.replaceFirst(_id, 'another-order'),
    ]) {
      expect(() => parse(bad), throwsFormatException);
    }
  });

  test('self-hosted origin cannot even request billing discovery', () async {
    final server = _BillingServer()..origin = 'https://sync.example.org';
    final auth = await server.auth();
    expect(() => CloudBillingClient(auth), throwsA(isA<CloudApiException>()));
    expect(server.requests, isEmpty);
  });

  testWidgets(
    'fixed official origin is insufficient without hosted discovery',
    (tester) async {
      final server = _BillingServer()..mode = 'self_hosted';
      await _open(tester, server);
      expect(find.text('当前服务器不提供订阅管理。'), findsOneWidget);
      expect(server.requests, ['GET /v1/server-info']);
    },
  );

  testWidgets('purchase gates leave management available without merchant', (
    tester,
  ) async {
    final server = _BillingServer()..acceptsPurchases = false;
    await _open(tester, server);
    expect(find.text('自动续费：未开通'), findsOneWidget);
    expect(find.text('当前未开放购买。'), findsOneWidget);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(server.requests, isNot(contains('GET /v1/billing/plans')));
  });

  testWidgets('non-pilot account sees no Waffo purchase without an offer', (
    tester,
  ) async {
    final server = _BillingServer.waffo()..showPlan = false;
    await _open(tester, server);
    expect(server.requests, contains('GET /v1/billing/plans'));
    expect(find.text('当前未开放购买。'), findsOneWidget);
    expect(find.text(_waffoPurchase), findsNothing);
    expect(server.checkouts, isEmpty);
  });

  testWidgets(
    'legacy hosted API offers only single purchase without renewal capability',
    (tester) async {
      final server = _BillingServer()
        ..origin = legacyOfficialCloudOrigin
        ..acceptsRenewal = false;
      await _open(tester, server);
      expect(find.text('仅购买 30 天 · ¥5.99'), findsOneWidget);
      expect(find.textContaining('开通自动续费'), findsNothing);
    },
  );

  testWidgets('Waffo checkout is a single payment with immediate feedback', (
    tester,
  ) async {
    final server = _BillingServer.waffo();
    final launcher = Completer<bool>();
    final launches = <Uri>[];
    await _open(
      tester,
      server,
      launch: (url) {
        launches.add(url);
        return launcher.future;
      },
    );
    final purchase = find.text(_waffoPurchase);
    expect(find.text('一次购买云同步'), findsOneWidget);
    expect(find.text('微信支付 · 单次购买，不自动续费'), findsOneWidget);
    expect(find.textContaining('开通自动续费'), findsNothing);
    await _tap(tester, purchase);
    expect(find.text('本次付款：¥1.00 / 30 天'), findsOneWidget);
    expect(find.text('付款渠道：微信支付'), findsOneWidget);
    expect(find.textContaining('不会自动续费'), findsWidgets);
    await tester.tap(find.text('前往收银台'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(launches, [Uri.parse(_url)]);
    expect(find.textContaining('返回 WeekGlass 后会自动核对'), findsOneWidget);
    expect(find.text(_waffoContinue), findsNothing);
    server.orderStatus = 'processing';
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(_orderReads(server), 0);
    launcher.complete(true);
    await tester.pumpAndSettle();
    expect(find.text(_waffoContinue), findsNothing);
    expect(server.checkouts.single, {
      'plan_id': 'cloud-30d',
      'purchase_mode': 'single',
      'terms_version': _waffoTerms,
    });
    expect(_orderReads(server), 1);
    await _tap(tester, find.text('完成'));
    await tester.pump(const Duration(seconds: 20));
    expect(_orderReads(server), 1);
  });

  testWidgets('two one-time quotes show the selected duration and price', (
    tester,
  ) async {
    final server = _BillingServer.waffo()..showAnnual = true;
    final launched = <Uri>[];
    await _open(
      tester,
      server,
      size: const Size(320, 570),
      scale: 1.8,
      launch: (url) async {
        launched.add(url);
        return true;
      },
    );
    final monthly = find.byKey(_monthlyChoice);
    final annual = find.byKey(_annualChoice);
    expect(
      find.descendant(of: monthly, matching: find.text('¥1.00')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: annual, matching: find.text('¥9.99')),
      findsOneWidget,
    );
    expect(find.text('微信支付 · 单次购买，不自动续费'), findsOneWidget);
    expect(find.textContaining('开通自动续费'), findsNothing);
    await _tap(tester, monthly);
    expect(find.text('本次付款：¥1.00 / 30 天'), findsOneWidget);
    await _tap(tester, find.text('取消'));
    expect(server.checkouts, isEmpty);
    await _tap(tester, annual);
    expect(find.text('本次付款：¥9.99 / 365 天'), findsOneWidget);
    expect(find.text('付款渠道：微信支付'), findsOneWidget);
    expect(find.textContaining('到期不会自动续费'), findsOneWidget);
    expect(server.checkouts, isEmpty);
    await _tap(tester, find.text('前往收银台'));
    expect(server.checkouts.single, {
      'plan_id': 'cloud-365d',
      'purchase_mode': 'single',
      'terms_version': _annualTerms,
    });
    expect(launched, [Uri.parse(_url)]);
    expect(find.text('订单：365 天 · ¥9.99'), findsOneWidget);
    expect(monthly, findsNothing);
    expect(annual, findsNothing);

    server.orderStatus = 'paid';
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(server.entitlementReads, 1);
    expect(find.text('最近订单：已付款。'), findsOneWidget);
    expect(
      find.text('同步权益截止：${cloudBillingTime(DateTime.parse(server.periodEnd))}'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'monthly checkout still sends monthly terms when both are listed',
    (tester) async {
      final server = _BillingServer.waffo()..showAnnual = true;
      await _open(tester, server, launch: (_) async => true);
      await _tap(tester, find.byKey(_monthlyChoice));
      await _tap(tester, find.text('前往收银台'));
      expect(server.checkouts.single, {
        'plan_id': 'cloud-30d',
        'purchase_mode': 'single',
        'terms_version': _waffoTerms,
      });
    },
  );

  testWidgets('the annual ID only offers 365-day single checkout', (
    tester,
  ) async {
    final server = _BillingServer.waffo()
      ..showAnnual = true
      ..annualOfferSeconds = _monthlySeconds;
    await _open(tester, server);
    expect(find.text(_waffoPurchase), findsOneWidget);
    expect(find.textContaining('¥9.99'), findsNothing);
    server.annualOfferSeconds = _annualSeconds;
    server.annualOfferModes = ['single', 'auto_renew'];
    await _tap(tester, find.text('刷新'));
    expect(find.textContaining('¥9.99'), findsNothing);
    server.annualOfferModes = ['single'];
    await _tap(tester, find.text('刷新'));
    expect(find.byKey(_annualChoice), findsOneWidget);
  });

  testWidgets('reopened dialog resumes only the original annual checkout', (
    tester,
  ) async {
    final server = _BillingServer.waffo()
      ..showAnnual = true
      ..orderStatus = 'pending'
      ..orderPlanId = 'cloud-365d';
    final launches = <Uri>[];
    await _open(
      tester,
      server,
      launch: (url) async {
        launches.add(url);
        return true;
      },
    );
    expect(find.byKey(_monthlyChoice), findsNothing);
    expect(find.text(_waffoContinue), findsNothing);
    await _tap(tester, find.text(_annualContinue));
    expect(find.text('继续支付原订单'), findsOneWidget);
    expect(find.text('本次付款：¥9.99 / 365 天'), findsOneWidget);
    await _tap(tester, find.text('前往收银台'));
    expect(server.checkouts.single, {
      'plan_id': 'cloud-365d',
      'purchase_mode': 'single',
      'terms_version': _annualTerms,
      'expected_checkout_id': _id,
    });
    expect(launches, [Uri.parse(_url)]);

    await _tap(tester, find.text('完成'));
    server.orderStatus = 'processing';
    server.canResumeCheckout = true;
    await _tap(tester, find.text('打开'));
    final resume = find.text('返回收银台继续支付');
    expect(resume, findsOneWidget);
    expect(find.text('原订单：365 天 · ¥9.99'), findsOneWidget);
    expect(find.byKey(_monthlyChoice), findsNothing);

    server.annualOfferTerms = 'changed';
    await _tap(tester, find.text('刷新'));
    expect(resume, findsNothing);
    expect(find.byKey(_monthlyChoice), findsNothing);
    server.annualOfferTerms = _annualTerms;
    server.orderSeconds = _monthlySeconds;
    await _tap(tester, find.text('刷新'));
    expect(resume, findsNothing);
    server.orderSeconds = null;
    await _tap(tester, find.text('刷新'));
    await _tap(tester, resume);
    expect(server.checkouts.last, server.checkouts.first);
    expect(launches, [Uri.parse(_url), Uri.parse(_url)]);
  });

  testWidgets('unavailable pending annual quote can be closed, not replaced', (
    tester,
  ) async {
    final server = _BillingServer.waffo()
      ..showAnnual = true
      ..orderStatus = 'pending'
      ..orderPlanId = 'cloud-365d'
      ..annualOfferTerms = 'changed';
    await _open(tester, server);
    expect(find.text('待付款：365 天 · ¥9.99'), findsOneWidget);
    expect(find.text(_annualContinue), findsNothing);
    expect(find.text(_waffoPurchase), findsNothing);
    expect(find.byKey(_monthlyChoice), findsNothing);
    await _tap(tester, find.text('关闭未支付订单'));
    expect(server.orderStatus, 'closed');
    expect(server.checkouts, isEmpty);
    expect(find.byKey(_monthlyChoice), findsOneWidget);
    expect(find.byKey(_annualChoice), findsOneWidget);
  });

  testWidgets('annual order history identifies duration and paid end', (
    tester,
  ) async {
    final server = _BillingServer.waffo()
      ..orderStatus = 'paid'
      ..orderPlanId = 'cloud-365d';
    await _open(tester, server, orders: true);
    expect(find.text('已付款 · ¥9.99'), findsOneWidget);
    expect(find.text('365 天 · 单次购买 · 微信支付'), findsOneWidget);
    expect(
      find.text('本单权益截止：${cloudBillingTime(DateTime.parse(server.periodEnd))}'),
      findsOneWidget,
    );
  });

  testWidgets('Waffo return checks the order until payment settles', (
    tester,
  ) async {
    final server = _BillingServer.waffo();
    await _open(tester, server, launch: (_) async => true);
    await _tap(tester, find.text(_waffoPurchase));
    await _tap(tester, find.text('前往收银台'));
    server.orderStatus = 'processing';
    final planReads = server.requests
        .where((request) => request == 'GET /v1/billing/plans')
        .length;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(_orderReads(server), 1);
    expect(server.entitlementReads, 1);
    expect(find.text('已有付款在处理，结果待确认。请勿重复付款。'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(_orderReads(server), 2);
    expect(server.entitlementReads, 1);
    server.orderStatus = 'paid';
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(_orderReads(server), 3);
    expect(server.entitlementReads, 2);
    expect(find.text('最近订单：已付款。'), findsOneWidget);
    expect(find.textContaining('同步权益截止：'), findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
    expect(_orderReads(server), 3);
    expect(
      server.requests
          .where((request) => request == 'GET /v1/billing/plans')
          .length,
      planReads,
    );
  });

  testWidgets('processing Waffo payment reopens only the existing checkout', (
    tester,
  ) async {
    final server = _BillingServer.waffo();
    final launches = <Uri>[];
    await _open(
      tester,
      server,
      launch: (url) async {
        launches.add(url);
        return true;
      },
    );
    await _tap(tester, find.text(_waffoPurchase));
    await _tap(tester, find.text('前往收银台'));
    server.orderStatus = 'processing';
    server.canResumeCheckout = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.textContaining('付款结果待确认'), findsOneWidget);
    expect(find.textContaining('若已付款，请等待确认'), findsOneWidget);
    expect(find.text(_waffoPurchase), findsNothing);
    expect(find.text('关闭未支付订单'), findsNothing);
    final resume = find.text('返回收银台继续支付');
    await _tap(tester, resume);
    expect(find.text('前往收银台'), findsNothing);
    expect(resume, findsNothing);
    expect(launches, [Uri.parse(_url), Uri.parse(_url)]);
    expect(server.checkouts, hasLength(2));
    expect(server.checkouts.last['expected_checkout_id'], _id);
    expect(server.keys.last, server.keys.first);
    expect(server.orderStatus, 'processing');
  });

  testWidgets('processing Waffo checkout requires a valid matching offer', (
    tester,
  ) async {
    final server = _BillingServer.waffo()
      ..orderStatus = 'processing'
      ..canResumeCheckout = true;
    await _open(tester, server, launch: (_) async => true);
    final resume = find.text('返回收银台继续支付');
    expect(resume, findsOneWidget);
    final refresh = find.text('刷新');

    server.canResumeCheckout = false;
    await _tap(tester, refresh);
    expect(resume, findsNothing);

    server.orderStatus = 'submitting';
    server.canResumeCheckout = true;
    await _tap(tester, refresh);
    expect(resume, findsNothing);

    server.orderStatus = 'processing';
    server.offerTerms = 'v2';
    await _tap(tester, refresh);
    expect(resume, findsNothing);

    server.offerTerms = _waffoTerms;
    server.acceptsPurchases = false;
    await _tap(tester, refresh);
    expect(resume, findsNothing);
    expect(find.text(_waffoPurchase), findsNothing);
    expect(server.checkouts, isEmpty);
  });

  testWidgets('Windows return cancels background checks and stops at a limit', (
    tester,
  ) async {
    final server = _BillingServer.waffo();
    await _open(
      tester,
      server,
      platform: TargetPlatform.windows,
      launch: (_) async => true,
    );
    await _tap(tester, find.text(_waffoPurchase));
    await _tap(tester, find.text('前往收银台'));
    server.orderStatus = 'processing';
    final listener =
        windowManager.listeners
                .whereType<State<CloudSubscriptionDialog>>()
                .single
            as WindowListener;
    listener.onWindowBlur();
    listener.onWindowFocus();
    await tester.pumpAndSettle();
    expect(_orderReads(server), 1);
    listener.onWindowBlur();
    await tester.pump(const Duration(seconds: 20));
    expect(_orderReads(server), 1);
    listener.onWindowFocus();
    await tester.pumpAndSettle();
    for (final seconds in [5, 10, 30]) {
      await tester.pump(Duration(seconds: seconds));
      await tester.pumpAndSettle();
    }
    expect(_orderReads(server), 4);
    server.orderStatus = 'paid';
    await _tap(tester, find.text('刷新'));
    expect(_orderReads(server), 4);
    expect(server.requests.last, 'GET /v1/billing/plans');
    expect(find.text('最近订单：已付款。'), findsOneWidget);
  });

  testWidgets('continuing a Waffo order pins it even if paid during checkout', (
    tester,
  ) async {
    final server = _BillingServer.waffo()
      ..orderStatus = 'pending'
      ..replacePendingOnCheckout = true;
    final launches = <Uri>[];
    await _open(
      tester,
      server,
      launch: (url) async {
        launches.add(url);
        return true;
      },
    );
    await _tap(tester, find.text(_waffoContinue));
    await _tap(tester, find.text('前往收银台'));
    expect(server.checkouts.single['expected_checkout_id'], _id);
    expect(launches, isEmpty);
    expect(find.text('最近订单：已付款。'), findsOneWidget);
  });

  testWidgets('a failed Waffo browser launch can resume only the same order', (
    tester,
  ) async {
    final server = _BillingServer.waffo();
    var launches = 0;
    await _open(tester, server, launch: (_) async => ++launches == 2);
    await _tap(tester, find.text(_waffoPurchase));
    await _tap(tester, find.text('前往收银台'));
    expect(find.textContaining('未能打开浏览器'), findsOneWidget);
    await _tap(tester, find.text(_waffoContinue));
    await _tap(tester, find.text('前往收银台'));
    expect(server.checkouts.last['expected_checkout_id'], _id);
    expect(server.keys, [server.keys.first, server.keys.first]);
    expect(launches, 2);
    expect(find.textContaining('返回 WeekGlass 后会自动核对'), findsOneWidget);
  });

  testWidgets('unsafe Waffo checkout response never launches a browser', (
    tester,
  ) async {
    final server = _BillingServer.waffo()
      ..checkoutUrl = _url.replaceFirst(
        'cloud.viliana.cn',
        'checkout.waffo.ai',
      );
    final launches = <Uri>[];
    await _open(
      tester,
      server,
      launch: (url) async {
        launches.add(url);
        return true;
      },
    );
    await _tap(tester, find.text(_waffoPurchase));
    await _tap(tester, find.text('前往收银台'));
    expect(launches, isEmpty);
    expect(find.textContaining('订单结果待确认'), findsOneWidget);
  });

  testWidgets(
    'opt-in, same-key recovery and browser return refresh confirmed order',
    (tester) async {
      final server = _BillingServer();
      final launches = <Uri>[];
      await _open(
        tester,
        server,
        scale: 1.3,
        launch: (url) async {
          launches.add(url);
          return true;
        },
      );
      final single = find.text('仅购买 30 天 · ¥5.99');
      final renewal = find.text('开通自动续费 · ¥5.99');
      expect(single, findsOneWidget);
      expect(renewal, findsOneWidget);
      expect(server.checkouts, isEmpty);
      await _tap(tester, renewal);
      expect(find.text('首期：¥5.99 / 30 天'), findsOneWidget);
      expect(find.textContaining('预计首次续费'), findsOneWidget);
      await _tap(tester, find.text('取消'));
      expect(server.checkouts, isEmpty);
      server.loseCheckoutResponse = true;
      await _tap(tester, single);
      await _tap(tester, find.text('前往收银台'));
      expect(launches, isEmpty);
      expect(server.keys, hasLength(1));
      expect(find.textContaining('订单结果待确认'), findsOneWidget);
      expect(renewal, findsNothing);
      server.loseCheckoutResponse = false;
      await _tap(tester, find.text('继续支付 · 仅购买 30 天 · ¥5.99'));
      await _tap(tester, find.text('前往收银台'));
      expect(launches, [Uri.parse(_url)]);
      expect(server.keys, [server.keys.first, server.keys.first]);
      expect(server.keys.first, matches(RegExp(r'^[a-f0-9-]{36}$')));
      expect(server.checkouts.last, {
        'plan_id': 'cloud-30',
        'purchase_mode': 'single',
        'terms_version': 'v1',
      });
      final priorReads = server.entitlementReads;
      server.orderStatus = 'paid';
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(server.entitlementReads, greaterThan(priorReads));
      expect(find.text('最近订单：已付款。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'renewal cancellation separates in-flight payment and waits for confirmation',
    (tester) async {
      final server = _BillingServer()
        ..agreement = 'active'
        ..orderStatus = 'processing';
      await _open(tester, server, size: const Size(800, 600));
      final close = find.text('关闭自动续费');
      expect(find.textContaining('下次扣费：'), findsOneWidget);
      expect(find.textContaining('已有付款在处理，结果待确认'), findsOneWidget);
      server.cancelTimesOut = true;
      await _tap(tester, close);
      expect(server.cancelRequests, 1);
      expect(find.text('自动续费：已开启'), findsOneWidget);
      expect(find.textContaining('关闭结果待确认'), findsOneWidget);
      server.cancelTimesOut = false;
      await _tap(tester, close);
      expect(server.cancelRequests, 2);
      expect(find.text('自动续费：关闭处理中'), findsOneWidget);
      expect(find.textContaining('已有付款在处理，结果待确认'), findsOneWidget);
      expect(find.textContaining('已关闭自动续费'), findsNothing);
      server.agreement = 'canceled';
      await _tap(tester, find.text('刷新'));
      expect(find.textContaining('已关闭自动续费，本期仍可同步'), findsOneWidget);
    },
  );

  testWidgets('orders remain readable offline with clearly stale state', (
    tester,
  ) async {
    final server = _BillingServer()..orderStatus = 'paid';
    await _open(tester, server, orders: true);
    expect(find.text('已付款 · ¥5.99'), findsOneWidget);
    expect(find.textContaining('本单权益截止'), findsOneWidget);
    server.offline = true;
    await _tap(tester, find.text('刷新'));
    expect(find.text('下方为上次确认的订单记录。'), findsOneWidget);
    expect(find.text('已付款 · ¥5.99'), findsOneWidget);
  });

  testWidgets('switch purchase mode only after closing a pending order', (
    tester,
  ) async {
    final server = _BillingServer()..orderStatus = 'pending';
    await _open(tester, server);
    expect(find.text('开通自动续费 · ¥5.99'), findsNothing);
    await _tap(tester, find.text('关闭未支付订单'));
    expect(server.orderStatus, 'closed');
    expect(find.text('开通自动续费 · ¥5.99'), findsOneWidget);
    expect(find.text('最近订单：已关闭。'), findsOneWidget);
  });

  testWidgets('a raced close leaves the in-flight payment unresolved', (
    tester,
  ) async {
    final server = _BillingServer()
      ..orderStatus = 'pending'
      ..closeRacesPayment = true;
    await _open(tester, server);
    await _tap(tester, find.text('关闭未支付订单'));
    expect(find.text('开通自动续费 · ¥5.99'), findsNothing);
    expect(find.textContaining('已有付款在处理'), findsOneWidget);
    expect(find.text('最近订单：已关闭。'), findsNothing);
  });

  testWidgets('a pending agreement is not reported as a closed sale', (
    tester,
  ) async {
    final server = _BillingServer()
      ..agreement = 'pending'
      ..renewalOnly = true;
    await _open(tester, server);
    expect(find.text('签约结果确认后可再购买。'), findsOneWidget);
    expect(find.text('当前未开放购买。'), findsNothing);
  });

  if (_captureDir.isNotEmpty) {
    testWidgets('capture rendered purchase layouts', (tester) async {
      await tester.runAsync(() async {
        for (final (family, asset) in [
          ('WeekGlassSans', 'assets/fonts/NotoSansSC-Variable.ttf'),
          ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
        ]) {
          await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
        }
      });
      Future<void> capture(GlobalKey key, String name) async {
        await tester.runAsync(() async {
          final frame =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await frame.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final output = File('$_captureDir/$name.png');
          await output.parent.create(recursive: true);
          await output.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      for (final (label, size, scale, dark) in [
        ('android', const Size(390, 844), 1.3, false),
        ('android-dark', const Size(390, 844), 1.3, true),
        ('windows', const Size(800, 600), 1.0, false),
      ]) {
        await tester.pumpWidget(const SizedBox());
        final key = await _open(
          tester,
          _BillingServer.waffo()..showAnnual = true,
          size: size,
          scale: scale,
          dark: dark,
          launch: (_) async => true,
        );
        await capture(key, '$label-subscription');
        await _tap(tester, find.byKey(_monthlyChoice));
        await capture(key, '$label-confirm-monthly');
        await _tap(tester, find.text('取消'));
        await _tap(tester, find.byKey(_annualChoice));
        await capture(key, '$label-confirm-annual');
        await _tap(tester, find.text('前往收银台'));
        await capture(key, '$label-browser');
      }
    });
  }
}
