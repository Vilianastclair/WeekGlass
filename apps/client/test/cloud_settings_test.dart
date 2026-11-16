import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weekglass/features/cloud/cloud_auth_service.dart';
import 'package:weekglass/features/cloud/cloud_connection.dart';
import 'package:weekglass/features/cloud/cloud_settings_dialog.dart';
import 'package:weekglass_data/weekglass_data.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

import 'cloud_auth_test.dart' show MemoryVault, tokens;

void main() {
  for (final size in [const Size(800, 600), const Size(390, 760)]) {
    testWidgets('cloud choices fit $size with enlarged text', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = SqliteEventRepository(
        factory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );
      final connection = CloudConnection(repository: repository);
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
                onPressed: () => openCloudSettings(context, connection),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.text('WeekGlass 云'), findsOneWidget);
      expect(find.text('在浏览器中登录'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('自己的服务器'));
      await tester.pumpAndSettle();
      expect(find.text('服务器地址'), findsOneWidget);
      expect(find.text('自托管同步免费，由你的服务器保存日程。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      connection.dispose();
      await repository.close();
    });
  }

  for (final (platform, size) in [
    (TargetPlatform.android, const Size(390, 760)),
    (TargetPlatform.windows, const Size(800, 600)),
  ]) {
    testWidgets(
      'paid email handoff and return in cloud settings on $platform',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var required = false;
        var available = false;
        var verified = false;
        var browserWorks = false;
        final launches = <Uri>[];
        final requests = <String>[];
        final auth = CloudAuthService(
          vault: MemoryVault()
            ..value = jsonEncode({
              ...tokens(),
              'origin': officialCloudOrigin,
              'merge_approved': false,
            }),
          browserLauncher: (uri) async {
            launches.add(uri);
            return browserWorks;
          },
          transport: (uri, method, body, headers, form) async {
            requests.add('$method ${uri.path}');
            return switch (uri.path) {
              '/v1/devices' => {'devices': <Map<String, dynamic>>[]},
              '/v1/me/entitlements' => {'sync_write': true},
              '/v1/me/account' => {
                'username': 'wg-example',
                'email_verification_required': required,
                'email_verification_available': available,
                'email_verified': verified,
              },
              _ => throw StateError('Unexpected request: $method ${uri.path}'),
            };
          },
        );
        final repository = SqliteEventRepository(
          factory: databaseFactoryFfi,
          databasePath: inMemoryDatabasePath,
        );
        final cloud = CloudConnection(repository: repository, auth: auth);
        addTearDown(repository.close);
        addTearDown(cloud.dispose);
        await cloud.initialize();
        await tester.pumpWidget(
          MaterialApp(
            theme: WeekGlassTheme.light().copyWith(platform: platform),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => openCloudSettings(context, cloud),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        );
        Future<void> tap(String caption) async {
          final finder = find.text(caption);
          await tester.ensureVisible(finder);
          await tester.tap(finder);
          await tester.pumpAndSettle();
        }

        await tap('打开');
        expect(find.text('验证邮箱'), findsNothing);
        required = true;
        await tap('完成');
        await tap('打开');
        expect(find.text('订阅邮箱待验证'), findsOneWidget);
        expect(find.text('邮箱验证暂不可用。请稍后刷新状态。'), findsOneWidget);
        expect(launches, isEmpty);
        available = true;
        await tap('刷新状态');
        await tap('验证邮箱');
        expect(find.text('未能打开浏览器。请重试。'), findsOneWidget);
        browserWorks = true;
        await tap('验证邮箱');
        expect(
          launches,
          List.filled(2, Uri.parse('$officialCloudOrigin/v1/auth/email')),
        );
        expect(find.text('请在浏览器中完成验证，再返回 WeekGlass。'), findsOneWidget);
        expect(requests.every((entry) => entry.startsWith('GET ')), isTrue);
        await tap('刷新状态');
        expect(find.text('邮箱尚未验证。'), findsOneWidget);

        required = available = false;
        verified = true;
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(find.text('邮箱已验证'), findsOneWidget);
        expect(find.text('验证邮箱'), findsNothing);
        expect(cloud.connected, isTrue);
        expect(cloud.entitlements?['sync_write'], true);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
