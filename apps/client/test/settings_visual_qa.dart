// Capture the actual Flutter windows at desktop and phone sizes.
// flutter test test/settings_visual_qa.dart --concurrency=1
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weekglass/features/cloud/cloud_auth_service.dart';
import 'package:weekglass/features/cloud/cloud_connection.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass/main.dart';
import 'package:weekglass_data/weekglass_data.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

import 'cloud_auth_test.dart' show MemoryVault, tokens;
import 'mobile_planner_test.dart' show mobileApp;
import 'whu_import_test.dart' show MemoryImportRepo;

const _output = String.fromEnvironment(
  'WG_SETTINGS_QA_DIR',
  defaultValue: '../../design-reference/previews/commercial-settings',
);

void main() {
  testWidgets(
    'render the cloud surface in the planner, settings, and cloud dialog',
    (tester) async {
      final shadowsWereDisabled = debugDisableShadows;
      debugDisableShadows = false;
      addTearDown(() => debugDisableShadows = shadowsWereDisabled);
      await initializeDateFormatting('zh_CN');
      await tester.runAsync(() async {
        for (final (family, path) in [
          ('WeekGlassSans', 'assets/fonts/NotoSansSC-Variable.ttf'),
          ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
        ]) {
          await (FontLoader(family)..addFont(rootBundle.load(path))).load();
        }
        await LiquidGlass.load();
      });
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetPadding);

      for (final (name, platform, size, mode, firstStatus, textScale) in [
        (
          'windows',
          TargetPlatform.windows,
          const Size(1280, 760),
          ThemeMode.dark,
          'not_subscribed',
          1.0,
        ),
        (
          'android',
          TargetPlatform.android,
          const Size(390, 844),
          ThemeMode.light,
          'expired',
          1.0,
        ),
        (
          'android-compact',
          TargetPlatform.android,
          const Size(320, 568),
          ThemeMode.dark,
          null,
          1.3,
        ),
      ]) {
        var status = firstStatus;
        debugDefaultTargetPlatformOverride = platform;
        final mobile = platform == TargetPlatform.android;
        tester.view.physicalSize = size;
        tester.view.padding = mobile
            ? const FakeViewPadding(top: 24, bottom: 24)
            : const FakeViewPadding();
        SharedPreferencesAsyncPlatform.instance =
            InMemorySharedPreferencesAsync.empty();
        final repository = SqliteEventRepository(
          factory: databaseFactoryFfi,
          databasePath: inMemoryDatabasePath,
        );
        final auth = CloudAuthService(
          vault: MemoryVault()
            ..value = firstStatus == null
                ? null
                : jsonEncode({
                    ...tokens(),
                    'origin': officialCloudOrigin,
                    'merge_approved': false,
                  }),
          transport: (uri, method, body, headers, form) async =>
              switch (uri.path) {
                '/v1/me/entitlements' => {
                  'status': status,
                  'sync_read': status == 'active',
                  'sync_write': status == 'active',
                  'export_allowed': status != 'not_subscribed',
                },
                '/v1/me/account' => {'verified_email': 'planner@example.test'},
                _ => throw StateError('Unexpected cloud request: ${uri.path}'),
              },
        );
        final cloud = CloudConnection(repository: repository, auth: auth);
        final controller = PlannerController(
          repository: MemoryImportRepo(),
          timeZoneId: 'Asia/Shanghai',
          cloud: cloud,
        );
        await cloud.initialize();
        await controller.initialize();
        await controller.saveAppearance(
          skin: WeekGlassSkin.moonstone,
          themeMode: mode,
        );
        if (mobile) controller.setView(PlannerView.threeDays);
        controller.setAnchorDate(DateTime(2026, 11, 16));
        await controller.saveEvents([
          for (final (index, day, hour, title, color) in [
            (0, 16, 8, '晨间阅读', EventColor.mistBlue),
            (1, 16, 10, '专题研讨', EventColor.sageGreen),
            (2, 17, 9, '整理研究笔记', EventColor.rose),
            (3, 17, 14, '机器人实验', EventColor.lavender),
            (4, 18, 9, '工作坊', EventColor.softPeach),
            (5, 18, 13, '设计讨论', EventColor.warmSand),
            (6, 19, 8, '小组报告', EventColor.mistBlue),
            (7, 20, 9, '整理本周课表', EventColor.sageGreen),
          ])
            CalendarEvent.timed(
              id: 'settings-fixture-$index',
              title: title,
              color: color,
              startLocal: DateTime(2026, 11, day, hour),
              endLocal: DateTime(2026, 11, day, hour + 1, 45),
              timeZoneId: 'Asia/Shanghai',
            ),
        ]);
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: mobile
                ? mobileApp(
                    controller,
                    mode: mode,
                    motion: true,
                    textScale: textScale,
                  )
                : WeekGlassApp(controller: controller),
          ),
        );
        await tester.runAsync(
          () => precacheImage(
            const AssetImage('assets/brand/atmosphere.png'),
            tester.element(find.byType(Scaffold).first),
          ),
        );
        Future<void> capture(String screen) async {
          expect(tester.takeException(), isNull);
          await tester.runAsync(() async {
            final boundary =
                key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final bitmap = await boundary.toImage();
            final bytes = await bitmap.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File('$_output/$name-$screen.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            bitmap.dispose();
          });
        }

        Future<void> advance([int frames = 16]) async {
          await tester.pump();
          for (var i = 0; i < frames; i++) {
            await tester.pump(const Duration(milliseconds: 20));
          }
        }

        await advance();
        await capture('planner');
        await tester.tap(
          mobile
              ? find.byKey(const ValueKey('mobile-action-settings'))
              : find.byTooltip('打开设置'),
        );
        await advance();
        await capture('settings-home');
        await tester.tap(find.byKey(const ValueKey('cloud-service-entry')));
        await advance();
        expect(
          find.byKey(const ValueKey('subscribe-cloud-service')).hitTestable(),
          findsOneWidget,
        );
        await capture(
          'cloud-${(firstStatus ?? 'signed-out').replaceAll('_', '-')}',
        );
        if (!mobile) {
          await tester.tap(find.text('完成'));
          await advance();
          await tester.tap(find.text('日历与外观'));
          await advance();
          await capture('calendar-settings');
          await tester.tap(find.byTooltip('返回设置'));
          status = 'active';
          await cloud.refreshEntitlements();
          await advance();
          expect(find.text('已开通'), findsOneWidget);
          await capture('settings-active');
        }

        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        await repository.close();
        debugDefaultTargetPlatformOverride = null;
      }
      debugDisableShadows = shadowsWereDisabled;
    },
  );
}
