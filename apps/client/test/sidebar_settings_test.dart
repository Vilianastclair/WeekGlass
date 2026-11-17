import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weekglass/features/cloud/cloud_auth_service.dart';
import 'package:weekglass/features/cloud/cloud_connection.dart';
import 'package:weekglass/features/cloud/cloud_service_button.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass/features/planner/sidebar_action.dart';
import 'package:weekglass/main.dart';
import 'package:weekglass_data/weekglass_data.dart';

import 'cloud_auth_test.dart' show MemoryVault;
import 'mobile_planner_test.dart' show mobileApp;
import 'whu_import_test.dart' show MemoryImportRepo;

void main() {
  testWidgets(
    'all shortcuts can be hidden but settings stays reachable after restart',
    (tester) async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      await initializeDateFormatting('zh_CN');
      final first = PlannerController(
        repository: MemoryImportRepo(),
        timeZoneId: 'Asia/Shanghai',
      );
      await first.initialize();
      await first.saveSidebarActions({
        SidebarAction.appearance,
        SidebarAction.exportEvents,
      });
      final restored = PlannerController(
        repository: MemoryImportRepo(),
        timeZoneId: 'Asia/Shanghai',
      );
      await restored.initialize();
      expect(restored.sidebarActions, {
        SidebarAction.appearance,
        SidebarAction.exportEvents,
      });
      await tester.pumpWidget(WeekGlassApp(controller: restored));
      await tester.pumpAndSettle();
      expect(find.byTooltip('皮肤与外观'), findsOneWidget);
      expect(find.byTooltip('导出日程'), findsOneWidget);
      await restored.saveSidebarActions({});
      await tester.pumpAndSettle();
      expect(find.byTooltip('皮肤与外观'), findsNothing);
      expect(find.byTooltip('打开设置'), findsOneWidget);
      await tester.tap(find.byTooltip('打开设置'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('快捷操作'));
      await tester.tap(find.text('快捷操作'));
      await tester.pumpAndSettle();
      final appearance = find.byKey(const ValueKey('sidebar-appearance'));
      await tester.ensureVisible(appearance);
      await tester.tap(appearance);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(restored.sidebarActions, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      first.dispose();
      restored.dispose();
    },
  );

  for (final mobile in [false, true]) {
    testWidgets('cloud is docked beside settings by default and respects hidden preference '
        'on ${mobile ? 'Android' : 'Windows'}', (tester) async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      await initializeDateFormatting('zh_CN');
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = mobile
          ? const Size(320, 568)
          : const Size(800, 560);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final controller = await _createCloudController();
      Widget app(PlannerController controller) => mobile
          ? mobileApp(controller, textScale: 1.3)
          : WeekGlassApp(controller: controller);
      final shortcut = find.byKey(
        ValueKey(mobile ? 'mobile-action-cloud' : 'rail-cloud-service'),
      );
      final settings = mobile
          ? find.byKey(const ValueKey('mobile-action-settings'))
          : find.byTooltip('打开设置');
      final entry = find.byKey(const ValueKey('cloud-service-entry'));
      final cta = find.byKey(const ValueKey('subscribe-cloud-service'));

      await tester.pumpWidget(app(controller));
      await tester.pumpAndSettle();
      expect(controller.sidebarActions, contains(SidebarAction.cloud));
      expect(tester.widget(shortcut), isA<CloudServiceButton>());
      final cloudBounds = tester.getRect(shortcut);
      final settingsBounds = tester.getRect(settings);
      if (mobile) {
        expect(cloudBounds.right, closeTo(settingsBounds.left, .01));
        expect(cloudBounds.center.dy, closeTo(settingsBounds.center.dy, .01));
        expect(cloudBounds.width - 4, greaterThanOrEqualTo(48));
        expect(
          find.byKey(const ValueKey('mobile-action-courses')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('mobile-action-more')), findsNothing);
      } else {
        expect(cloudBounds.bottom, lessThanOrEqualTo(settingsBounds.top));
        expect(settingsBounds.top - cloudBounds.bottom, lessThan(6));
        expect(cloudBounds.center.dx, closeTo(settingsBounds.center.dx, .01));
        expect(
          find.ancestor(of: shortcut, matching: find.byType(Scrollable)),
          findsNothing,
        );
      }
      await _tap(tester, shortcut);
      expect(cta.hitTestable(), findsOneWidget);
      expect(find.text('在浏览器中登录'), findsOneWidget);
      await _tap(tester, find.text('完成'));
      if (mobile) {
        await controller.saveSidebarActions({
          ...SidebarAction.defaults,
          SidebarAction.importEvents,
          SidebarAction.exportEvents,
        });
        await tester.pumpAndSettle();
        await _tap(tester, find.byKey(const ValueKey('mobile-action-more')));
        expect(
          find.byKey(const ValueKey('mobile-more-courses')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('mobile-more-cloud')), findsNothing);
        await _tap(tester, find.byTooltip('关闭更多操作'));
        await controller.saveSidebarActions(SidebarAction.defaults);
        await tester.pumpAndSettle();
      }

      await _tap(tester, settings);
      expect(entry.hitTestable(), findsOneWidget);
      expect(cta, findsNothing);
      expect(find.text('未连接'), findsOneWidget);
      await _tap(tester, find.text('快捷操作'));
      final cloudToggle = find.byKey(const ValueKey('sidebar-cloud'));
      expect(tester.widget<CheckboxListTile>(cloudToggle).value, isTrue);
      await _tap(tester, cloudToggle);
      await _tap(tester, find.text('保存'));
      await _tap(tester, find.byTooltip('关闭设置'));
      expect(shortcut, findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      final restored = await _createCloudController();
      await tester.pumpWidget(app(restored));
      await tester.pumpAndSettle();
      expect(
        restored.sidebarActions,
        unorderedEquals(
          SidebarAction.defaults.difference({SidebarAction.cloud}),
        ),
      );
      expect(shortcut, findsNothing);
      await _tap(tester, settings);
      await _tap(tester, entry);
      expect(cta.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

Future<PlannerController> _createCloudController() async {
  final repository = SqliteEventRepository(
    factory: databaseFactoryFfi,
    databasePath: inMemoryDatabasePath,
  );
  final cloud = CloudConnection(
    repository: repository,
    auth: CloudAuthService(vault: MemoryVault()),
  );
  final controller = PlannerController(
    repository: MemoryImportRepo(),
    timeZoneId: 'Asia/Shanghai',
    cloud: cloud,
  );
  addTearDown(repository.close);
  addTearDown(controller.dispose);
  await controller.initialize();
  await cloud.initialize();
  return controller;
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}
