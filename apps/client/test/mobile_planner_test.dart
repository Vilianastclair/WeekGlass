import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:weekglass/features/mobile/mobile_planner_screen.dart';
import 'package:weekglass/features/course_import/course_import_dialog.dart';
import 'package:weekglass/features/planner/calendar_grid.dart';
import 'package:weekglass/features/planner/glass_event_card.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass/features/planner/sidebar_action.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

import 'whu_import_test.dart' show MemoryImportRepo, FakeWhuPortal;

Future<PlannerController> mobileFixture() async {
  final c = PlannerController(
    repository: MemoryImportRepo(),
    timeZoneId: 'Asia/Shanghai',
  );
  await c.initialize();
  c.setView(PlannerView.threeDays);
  c.setAnchorDate(DateTime(2026, 11, 2));
  await c.saveEvent(
    CalendarEvent.timed(
      id: 'mobile-example',
      title: '示例课程',
      notes: '模拟数据 · 用于触控回归',
      startLocal: DateTime(2026, 11, 2, 8),
      endLocal: DateTime(2026, 11, 2, 9),
      timeZoneId: 'Asia/Shanghai',
    ),
  );
  return c;
}

Widget mobileApp(
  PlannerController controller, {
  double textScale = 1,
  ThemeMode mode = ThemeMode.light,
  bool motion = false,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  locale: const Locale('zh', 'CN'),
  supportedLocales: const [Locale('zh', 'CN')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  theme: WeekGlassTheme.light(),
  darkTheme: WeekGlassTheme.dark(),
  themeMode: mode,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(textScale),
      alwaysUse24HourFormat: true,
    ),
    child: LiquidGlassScope(mobile: true, motion: motion, child: child!),
  ),
  home: MobilePlannerScreen(controller: controller),
);

void main() {
  setUp(() async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await initializeDateFormatting('zh_CN');
  });
  void size(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  for (final viewport in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(844, 390),
  ]) {
    testWidgets(
      'mobile dock, navigation and views fit $viewport at 1.3 text size',
      (tester) async {
        size(tester, viewport);
        final c = await mobileFixture();
        await c.saveSidebarActions(SidebarAction.values.toSet());
        await tester.pumpWidget(mobileApp(c, textScale: 1.3));
        await tester.pumpAndSettle();
        final dock = tester.getRect(
          find.byKey(const ValueKey('mobile-action-dock')),
        );
        expect(dock.bottom, lessThanOrEqualTo(viewport.height));
        expect(
          tester.widget<CalendarGrid>(find.byType(CalendarGrid)).touchMode,
          isTrue,
        );
        for (final view in [
          ('单日', PlannerView.day),
          ('整周', PlannerView.week),
          ('三日', PlannerView.threeDays),
        ]) {
          await tester.tap(find.text(view.$1));
          await tester.pumpAndSettle();
          expect(c.view, view.$2);
          expect(tester.takeException(), isNull);
        }
        await tester.tap(find.byKey(const ValueKey('mobile-next-period')));
        await tester.pumpAndSettle();
        expect(c.anchorDate, DateTime(2026, 11, 5));
        await tester.tap(find.byKey(const ValueKey('mobile-previous-period')));
        await tester.pumpAndSettle();
        expect(c.anchorDate, DateTime(2026, 11, 2));
        await tester.tap(find.byKey(const ValueKey('mobile-action-more')));
        await tester.pumpAndSettle();
        expect(find.text('导入日程'), findsOneWidget);
        expect(find.text('导出日程'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('关闭更多操作'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
        c.dispose();
      },
    );
  }

  testWidgets(
    'settings remains reachable after every optional shortcut is hidden',
    (tester) async {
      size(tester, const Size(320, 568));
      final c = await mobileFixture();
      await c.saveSidebarActions({});
      await tester.pumpWidget(mobileApp(c, textScale: 1.3));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mobile-action-create')), findsNothing);
      expect(find.byKey(const ValueKey('mobile-view-switch')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('mobile-action-settings')));
      await tester.pumpAndSettle();
      expect(find.text('保存'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );

  testWidgets(
    'ordinary vertical swipes scroll both lanes and time rail without editing',
    (tester) async {
      size(tester, const Size(390, 844));
      final c = await mobileFixture();
      await tester.pumpWidget(mobileApp(c));
      await tester.pumpAndSettle();
      final clock = find.byKey(const ValueKey('time-8'));
      final startY = tester.getTopLeft(clock).dy;
      final grid = tester.getRect(find.byType(CalendarGrid));
      await tester.dragFrom(
        Offset(grid.left + 170, grid.top + 300),
        const Offset(0, -160),
      );
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(clock).dy, lessThan(startY - 80));
      expect(c.events.single.startLocal, DateTime(2026, 11, 2, 8));
      expect(find.text('新建日程'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );

  testWidgets('a card swipe scrolls but a held card can move by one hour', (
    tester,
  ) async {
    size(tester, const Size(390, 844));
    final c = await mobileFixture();
    await tester.pumpWidget(mobileApp(c));
    await tester.pumpAndSettle();
    final card = find.byType(GlassEventCard).first;
    final gesture = await tester.startGesture(tester.getCenter(card));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(0, 56));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(c.events.single.startLocal, DateTime(2026, 11, 2, 9));
    final current = c.events.single.startLocal;
    await tester.drag(card, const Offset(0, -80));
    await tester.pumpAndSettle();
    expect(c.events.single.startLocal, current);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets(
    'mobile new event and school import use the shared dialogs at larger text size',
    (tester) async {
      size(tester, const Size(320, 568));
      final c = await mobileFixture();
      await tester.pumpWidget(mobileApp(c, textScale: 1.3));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mobile-action-create')));
      await tester.pumpAndSettle();
      expect(find.text('新建日程'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mobile-action-courses')));
      await tester.pumpAndSettle();
      expect(find.text('导入学校课表'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // Opening this sheet does not initialize the native school WebView.
      await tester.tap(find.byTooltip('关闭导入'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );

  testWidgets('phone settings, details and file workflows fit larger text', (
    tester,
  ) async {
    size(tester, const Size(320, 568));
    final c = await mobileFixture();
    await c.saveSidebarActions(SidebarAction.values.toSet());
    await tester.pumpWidget(mobileApp(c, textScale: 1.3));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(GlassEventCard).first);
    await tester.pumpAndSettle();
    expect(find.text('调整'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mobile-action-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sidebar-customization')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    for (final (key, title) in [
      ('importEvents', '导入日程'),
      ('exportEvents', '导出日历'),
      ('appearance', '皮肤与外观'),
    ]) {
      await tester.tap(find.byKey(const ValueKey('mobile-action-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('mobile-more-$key')));
      await tester.pumpAndSettle();
      expect(find.text(title), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    }
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets('small phone editor remains usable above the keyboard', (
    tester,
  ) async {
    size(tester, const Size(320, 568));
    addTearDown(tester.view.resetViewInsets);
    final c = await mobileFixture();
    await tester.pumpWidget(mobileApp(c, textScale: 1.3));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mobile-action-create')));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 270);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getBottomLeft(find.text('取消')).dy, lessThan(298));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    tester.view.resetViewInsets();
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets(
    'school preview and holiday controls fit a narrow phone with larger text',
    (tester) async {
      size(tester, const Size(320, 568));
      final c = await mobileFixture();
      await tester.pumpWidget(mobileApp(c, textScale: 1.3));
      await tester.pumpAndSettle();
      showDialog<void>(
        context: tester.element(find.byType(Scaffold)),
        builder: (_) => CourseImportDialog(
          controller: c,
          portalFactory: (_) => FakeWhuPortal(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('连接并读取课表'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(
        find.byKey(const ValueKey('course-holiday-settings')),
      );
      await tester.pumpAndSettle();
      expect(find.text('排除假期'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭导入'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );
}
