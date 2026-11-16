import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weekglass/features/cloud/cloud_auth_service.dart';
import 'package:weekglass/features/cloud/cloud_connection.dart';
import 'package:weekglass/features/cloud/cloud_settings_dialog.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass/features/planner/planner_settings_dialog.dart';
import 'package:weekglass_data/weekglass_data.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

import 'cloud_auth_test.dart' show MemoryVault, tokens;
import 'whu_import_test.dart' show MemoryImportRepo;

void main() {
  for (final size in [const Size(800, 600), const Size(320, 568)]) {
    testWidgets('cloud choices fit ${size.width} with enlarged text', (
      tester,
    ) async {
      _size(tester, size);
      final repository = _repository();
      final connection = CloudConnection(repository: repository);
      addTearDown(repository.close);
      addTearDown(connection.dispose);
      await tester.pumpWidget(
        _host(
          platform: TargetPlatform.android,
          open: (context) => openCloudSettings(context, connection),
        ),
      );
      await _tap(tester, '打开');
      expect(find.text('WeekGlass 云'), findsOneWidget);
      expect(find.text('在浏览器中登录'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _tap(tester, '自己的服务器');
      expect(find.text('服务器地址'), findsOneWidget);
      expect(find.text('自托管同步免费，由你的服务器保存日程。'), findsOneWidget);
      expect(find.text('订阅云服务'), findsNothing);
      expect(tester.takeException(), isNull);
      await _tap(tester, '完成');
    });
  }

  for (final (platform, size, origin) in [
    (TargetPlatform.android, const Size(320, 568), officialCloudOrigin),
    (TargetPlatform.windows, const Size(1120, 760), legacyOfficialCloudOrigin),
  ]) {
    testWidgets(
      'direct subscription and browser account handoff on $platform',
      (tester) async {
        _size(tester, size);
        SharedPreferencesAsyncPlatform.instance =
            InMemorySharedPreferencesAsync.empty();
        var status = 'not_subscribed';
        var exportAllowed = false;
        var browserWorks = true;
        final launches = <Uri>[];
        final requests = <String>[];
        final auth = CloudAuthService(
          vault: MemoryVault()
            ..value = jsonEncode({
              ...tokens(),
              'origin': origin,
              'merge_approved': false,
            }),
          browserLauncher: (uri) async {
            launches.add(uri);
            return browserWorks;
          },
          transport: (uri, method, body, headers, form) async {
            requests.add('$method ${uri.path}');
            return switch (uri.path) {
              '/v1/me/entitlements' => {
                'status': status,
                'sync_read': status == 'active',
                'sync_write': status == 'active',
                'export_allowed': exportAllowed,
              },
              '/v1/me/account' => {
                'username': 'guest-random',
                'pending_email': 'reader@example.test',
              },
              _ => throw StateError('Unexpected request: $method ${uri.path}'),
            };
          },
        );
        final repository = _repository();
        final cloud = CloudConnection(repository: repository, auth: auth);
        final controller = PlannerController(
          repository: MemoryImportRepo(),
          timeZoneId: 'Asia/Shanghai',
          cloud: cloud,
        );
        addTearDown(repository.close);
        addTearDown(controller.dispose);
        await cloud.initialize();
        await controller.initialize();
        await tester.pumpWidget(
          _host(
            platform: platform,
            open: (context) => openPlannerSettings(context, controller),
          ),
        );

        await _tap(tester, '打开');
        final cta = find.byKey(const ValueKey('subscribe-cloud-service'));
        expect(cta.hitTestable(), findsOneWidget);
        expect(
          tester.getSize(cta).width,
          greaterThan(size.width < 600 ? 235 : 400),
        );
        expect(find.text('未开通'), findsOneWidget);
        expect(find.text('开通后才能跨设备同步日程'), findsOneWidget);
        await _tap(tester, '订阅云服务');
        expect(
          launches.single,
          Uri.parse('$officialCloudOrigin/account#plans'),
        );
        expect(find.text('设置'), findsOneWidget);
        expect(requests, ['GET /v1/me/entitlements']);

        await _tap(tester, '云同步');
        expect(find.text('reader@example.test'), findsOneWidget);
        expect(find.textContaining('不能合并或同步'), findsOneWidget);
        expect(find.text('合并日程'), findsNothing);
        expect(find.text('立即同步'), findsNothing);
        expect(find.text('已连接设备'), findsNothing);
        expect(find.text('账号安全与云端导出'), findsNothing);
        browserWorks = false;
        await _tap(tester, '云服务账号');
        expect(find.text('无法打开链接'), findsOneWidget);
        expect(
          tester.widget<SelectableText>(find.byType(SelectableText)).data,
          '$officialCloudOrigin/account',
        );
        await _tap(tester, '返回设置');
        browserWorks = true;
        await _tap(tester, '云服务账号');
        expect(launches.last, Uri.parse('$officialCloudOrigin/account'));

        status = 'expired';
        exportAllowed = true;
        await _tap(tester, '刷新订阅状态');
        await tester.ensureVisible(find.text('已到期').last);
        expect(find.text('已到期').last.hitTestable(), findsOneWidget);
        expect(find.text('合并日程'), findsNothing);
        await _tap(tester, '前往网页导出云端日程');
        expect(
          launches.last,
          Uri.parse('$officialCloudOrigin/account#calendar'),
        );
        expect(requests.any((r) => r.contains('/exports/')), isFalse);
        exportAllowed = false;
        await _tap(tester, '刷新订阅状态');
        expect(find.text('前往网页导出云端日程'), findsNothing);
        await _tap(tester, '查看网页导出状态');
        expect(
          launches.last,
          Uri.parse('$officialCloudOrigin/account#calendar'),
        );

        status = 'active';
        // Browser handoff can return on Windows or Android via this lifecycle.
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('已开通').last);
        expect(find.text('已开通').last.hitTestable(), findsOneWidget);
        expect(find.text('合并日程'), findsOneWidget);
        expect(cloud.auth.mergeApproved, isFalse);
        expect(requests.every((r) => r.startsWith('GET /v1/me/')), isTrue);
        expect(launches.every((u) => !u.hasQuery && !u.hasPort), isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

SqliteEventRepository _repository() => SqliteEventRepository(
  factory: databaseFactoryFfi,
  databasePath: inMemoryDatabasePath,
);

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _host({
  required TargetPlatform platform,
  required void Function(BuildContext) open,
}) => MaterialApp(
  theme: WeekGlassTheme.light().copyWith(platform: platform),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: const TextScaler.linear(1.3)),
    child: child!,
  ),
  home: Scaffold(
    body: Builder(
      builder: (context) =>
          TextButton(onPressed: () => open(context), child: const Text('打开')),
    ),
  ),
);

Future<void> _tap(WidgetTester tester, String label) async {
  // An underneath settings page can have the same label as a cloud route.
  final finder = find.text(label).hitTestable();
  final target = finder.evaluate().isNotEmpty
      ? finder.first
      : find.text(label).last;
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}
