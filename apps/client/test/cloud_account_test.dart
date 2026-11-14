import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weekglass/features/cloud/cloud_account_dialog.dart';
import 'package:weekglass/features/cloud/cloud_auth_service.dart';
import 'package:weekglass/features/cloud/cloud_connection.dart';
import 'package:weekglass_data/weekglass_data.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

import 'cloud_auth_test.dart' show MemoryVault, tokens;

void main() {
  setUpAll(sqfliteFfiInit);

  for (final size in [const Size(800, 600), const Size(390, 760)]) {
    testWidgets(
      'account management fits $size and password change keeps local events',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final vault = MemoryVault()
          ..value = jsonEncode({
            ...tokens(),
            'origin': officialCloudOrigin,
            'merge_approved': false,
          });
        var changes = 0;
        final auth = CloudAuthService(
          vault: vault,
          transport: (uri, method, body, headers, form) async {
            if (uri.path == '/v1/me/entitlements') return {'sync_write': false};
            if (uri.path == '/v1/devices') {
              return {'devices': <Map<String, dynamic>>[]};
            }
            if (uri.path == '/v1/me/account') {
              return {
                'username': 'synthetic-account',
                'recovery_configured': true,
                'usage': {'event_count': 0, 'storage_bytes': 0},
              };
            }
            if (uri.path == '/v1/me/password') {
              changes++;
              if (body!['current_password'] != 'current-password-123') {
                throw CloudApiException(403, 'incorrect_password', {});
              }
            }
            return {};
          },
        );
        final repository = SqliteEventRepository(
          factory: databaseFactoryFfi,
          databasePath: inMemoryDatabasePath,
        );
        await tester.runAsync(
          () => repository.save(
            CalendarEvent.timed(
              id: 'local-safe',
              title: 'Local survives password change',
              startLocal: DateTime(2026, 11, 6, 9),
              endLocal: DateTime(2026, 11, 6, 10),
              timeZoneId: 'Asia/Shanghai',
            ),
          ),
        );
        final cloud = CloudConnection(repository: repository, auth: auth);
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
                  onPressed: () => openCloudAccount(context, cloud),
                  child: const Text('打开账号'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开账号'));
        await tester.pumpAndSettle();
        expect(find.text('synthetic-account'), findsOneWidget);
        expect(find.text('导出云端日历'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('修改密码'));
        await tester.tap(find.text('修改密码'));
        await tester.pumpAndSettle();
        final fields = find.byType(TextField);
        await tester.enterText(fields.at(0), 'wrong');
        await tester.enterText(fields.at(1), 'new-password-123456');
        await tester.enterText(fields.at(2), 'new-password-123456');
        await tester.tap(find.text('确认'));
        await tester.pumpAndSettle();
        expect(find.text('当前密码不正确，请重试。'), findsOneWidget);
        expect(cloud.connected, isTrue);
        await tester.enterText(fields.at(0), 'current-password-123');
        await tester.tap(find.text('确认'));
        await tester.pumpAndSettle();
        expect(changes, 2);
        expect(cloud.connected, isFalse);
        expect(vault.value, isNull);
        final local = await tester.runAsync(repository.getAllEvents);
        expect(local!.single.id, 'local-safe');
        expect(find.text('打开账号'), findsOneWidget);
        expect(tester.takeException(), isNull);
        cloud.dispose();
        await tester.runAsync(repository.close);
      },
    );
  }
}
