import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weekglass/features/cloud/cloud_auth_service.dart';
import 'package:weekglass/features/cloud/cloud_connection.dart';
import 'package:weekglass/features/cloud/cloud_settings_dialog.dart';
import 'package:weekglass_data/weekglass_data.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

const _waiting = '等待浏览器授权。请在浏览器中完成登录。';
const _exchanging = '已收到浏览器回传，正在验证授权…';
const _saving = '授权已验证，正在安全保存连接…';
const _approved = '合并并同步日程';

void main() {
  for (final size in [const Size(800, 600), const Size(390, 760)]) {
    testWidgets(
      'shows login stages and merge confirmation before account details at $size',
      (tester) async {
        final auth = _FakeCloudAuthService();
        final cloud = await _openSettings(tester, auth, size);
        await _startLogin(tester);

        auth.showPhase(CloudLoginPhase.exchanging);
        await tester.pump();
        expect(find.text(_waiting), findsNothing);
        expect(find.text(_exchanging), findsOneWidget);
        expect(tester.takeException(), isNull);

        auth.showPhase(CloudLoginPhase.saving);
        await tester.pump();
        expect(find.text(_exchanging), findsNothing);
        expect(find.text(_saving), findsOneWidget);
        expect(find.text(_approved), findsNothing);
        expect(tester.takeException(), isNull);

        auth.finishLogin();
        await tester.pumpAndSettle();
        expect(auth.accountDetails.isCompleted, isFalse);
        expect(auth.requests, [
          'GET /v1/me/entitlements',
          'GET /v1/me/account',
        ]);
        expect(cloud.accountLoading, isTrue);
        expect(find.text(_approved), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(find.text('暂不合并'));
        await tester.pumpAndSettle();
        expect(find.text(_approved), findsNothing);
        expect(find.text('确认合并后才会开始同步本机日程。'), findsOneWidget);
        expect(cloud.connected, isTrue);
        expect(cloud.engine.connected, isFalse);
        expect(auth.mergeApprovals, 0);
        expect(
          auth.requests.every((request) => request.startsWith('GET ')),
          isTrue,
        );

        auth.accountDetails.complete({'username': 'synthetic-account'});
        await tester.pumpAndSettle();
        expect(find.text('synthetic-account'), findsOneWidget);
        expect(cloud.accountLoading, isFalse);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('完成'));
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets('unpaid registration connects but never prompts for merge', (
    tester,
  ) async {
    final auth = _FakeCloudAuthService()..paid = false;
    final cloud = await _openSettings(tester, auth, const Size(390, 760));
    await _startLogin(tester);
    auth.finishLogin();
    auth.accountDetails.complete({'username': 'synthetic-account'});
    await tester.pumpAndSettle();
    expect(cloud.connected, isTrue);
    expect(cloud.canSync, isFalse);
    expect(find.text(_approved), findsNothing);
    expect(find.text('合并日程'), findsNothing);
    expect(find.text('立即同步'), findsNothing);
    expect(find.text('未开通'), findsOneWidget);
    expect(find.textContaining('不能合并或同步'), findsOneWidget);
    expect(auth.requests, ['GET /v1/me/entitlements', 'GET /v1/me/account']);
    expect(auth.mergeApprovals, 0);
  });

  testWidgets('cancel during saving shows feedback and skips merge', (
    tester,
  ) async {
    final auth = _FakeCloudAuthService();
    final cloud = await _openSettings(tester, auth, const Size(800, 600));
    await _startLogin(tester);
    auth.showPhase(CloudLoginPhase.saving);
    await tester.pump();

    final cancel = find.text('取消登录');
    await tester.ensureVisible(cancel);
    await tester.tap(cancel);
    expect(auth.cancellations, 1);
    auth.finishLogin();
    await tester.pumpAndSettle();

    expect(find.text('已取消登录。'), findsOneWidget);
    expect(find.text(_approved), findsNothing);
    expect(find.text(_saving), findsNothing);
    expect(cloud.connected, isFalse);
    expect(auth.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing cloud settings prevents a late merge dialog', (
    tester,
  ) async {
    final auth = _FakeCloudAuthService();
    await _openSettings(tester, auth, const Size(390, 760));
    await _startLogin(tester);

    await tester.tap(find.text('完成'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(auth.cancellations, 1);

    // Simulate a connection that committed just before it could be cancelled.
    auth.finishLogin(ignoreCancellation: true);
    auth.accountDetails.complete({'username': 'synthetic-account'});
    await tester.pumpAndSettle();

    expect(find.text('打开云同步'), findsOneWidget);
    expect(find.text(_approved), findsNothing);
    expect(find.text('暂不合并'), findsNothing);
    expect(auth.mergeApprovals, 0);
    expect(tester.takeException(), isNull);
  });
}

Future<CloudConnection> _openSettings(
  WidgetTester tester,
  _FakeCloudAuthService auth,
  Size size,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  const channel = MethodChannel('window_manager');
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    channel,
    (call) async => call.method == 'isMinimized' ? false : null,
  );
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

  final repository = SqliteEventRepository(
    factory: databaseFactoryFfi,
    databasePath: inMemoryDatabasePath,
  );
  final cloud = CloudConnection(repository: repository, auth: auth);
  addTearDown(() async {
    cloud.dispose();
    await repository.close();
  });
  await cloud.initialize();

  await tester.pumpWidget(
    MaterialApp(
      theme: WeekGlassTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(1.3)),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => openCloudSettings(context, cloud),
            child: const Text('打开云同步'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开云同步'));
  await tester.pumpAndSettle();
  return cloud;
}

Future<void> _startLogin(WidgetTester tester) async {
  await tester.tap(find.text('在浏览器中登录'));
  // The indeterminate progress indicator keeps scheduling frames.
  await tester.pump();
  expect(find.text(_waiting), findsOneWidget);
  expect(tester.takeException(), isNull);
}

class _FakeCloudAuthService extends CloudAuthService {
  final _loginResult = Completer<void>();
  final accountDetails = Completer<Map<String, dynamic>>();
  final requests = <String>[];
  void Function(CloudLoginPhase)? _onPhaseChanged;
  bool _connected = false;
  bool paid = true;
  int cancellations = 0;
  int mergeApprovals = 0;

  @override
  bool get connected => _connected;

  @override
  bool get mergeApproved => mergeApprovals > 0;

  @override
  String? get origin => connected ? officialCloudOrigin : null;

  @override
  String get accountId => '12345678-0000-4000-8000-000000000001';

  @override
  Future<void> restore() async {}

  @override
  Future<void> login(
    String address, {
    void Function(CloudLoginPhase)? onPhaseChanged,
  }) async {
    _onPhaseChanged = onPhaseChanged;
    showPhase(CloudLoginPhase.waitingForBrowser);
    await _loginResult.future;
    _connected = true;
  }

  void showPhase(CloudLoginPhase phase) => _onPhaseChanged?.call(phase);

  @override
  void cancelLogin() {
    cancellations++;
  }

  void finishLogin({bool ignoreCancellation = false}) {
    if (cancellations > 0 && !ignoreCancellation) {
      _loginResult.completeError(CloudLoginException('已取消登录。'));
    } else {
      _loginResult.complete();
    }
  }

  @override
  Future<void> approveMerge({bool includeSleepSchedule = false}) async {
    mergeApprovals++;
  }

  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path,
    Map<String, dynamic>? body,
  ) async {
    requests.add('$method $path');
    switch (path) {
      case '/v1/me/entitlements':
        return {
          'status': paid ? 'active' : 'not_subscribed',
          'sync_read': paid,
          'sync_write': paid,
        };
      case '/v1/devices':
        return {'devices': <Map<String, dynamic>>[]};
      case '/v1/me/account':
        return accountDetails.future;
      default:
        throw StateError('Unexpected cloud request: $method $path');
    }
  }
}
