import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:weekglass_data/weekglass_data.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

import 'package:weekglass/features/planner/calendar_grid.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass/features/planner/planner_screen.dart';
import 'package:weekglass/features/planner/event_details_dialog.dart';
import 'package:weekglass/main.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets(
    'macOS desktop uses Command and desktop settings captions',
    (tester) async {
      await initializeDateFormatting('zh_CN');
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = PlannerController(
        repository: _EmptyEventRepository(),
        timeZoneId: 'Asia/Shanghai',
      );
      await controller.initialize();
      await tester.pumpWidget(WeekGlassApp(controller: controller));
      await tester.pumpAndSettle();

      expect(find.byTooltip('下一时段 ⌘→'), findsOneWidget);
      final before = controller.weekStart;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(controller.weekStart.difference(before).inDays, 7);

      await tester.tap(find.byTooltip('打开设置'));
      await tester.pumpAndSettle();
      expect(find.text('自定义侧边栏'), findsOneWidget);
      await tester.tap(find.text('软件与通知'));
      await tester.pumpAndSettle();
      expect(find.text('关闭窗口后继续提醒，退出应用后停止'), findsOneWidget);
      expect(find.text('发送测试通知'), findsOneWidget);
      expect(find.text('检查或安装新版本'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
    variant: const TargetPlatformVariant({TargetPlatform.macOS}),
  );

  testWidgets(
    'sleep settings hide nighttime and Windows exposes only essential controls',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = PlannerController(
        repository: _EmptyEventRepository(),
        timeZoneId: 'Asia/Shanghai',
      );
      await c.initialize();
      await tester.pumpWidget(WeekGlassApp(controller: c));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('time-7')), findsOneWidget);
      expect(find.byKey(const ValueKey('time-23')), findsOneWidget);
      expect(find.byKey(const ValueKey('time-0')), findsNothing);
      expect(find.bySemanticsLabel('批量添加'), findsNothing);
      expect(find.bySemanticsLabel('回到今天'), findsNothing);
      expect(find.textContaining('全天概览'), findsNothing);
      expect(find.text('全天'), findsNothing);
      expect(find.byTooltip('添加全天日程'), findsNothing);
      await tester.tap(find.bySemanticsLabel('设置'));
      await tester.pumpAndSettle();
      expect(find.text('入睡 23:00'), findsNothing);
      await tester.tap(find.text('日历与外观'));
      await tester.pumpAndSettle();
      expect(find.text('入睡 23:00'), findsOneWidget);
      expect(find.text('起床 07:00'), findsOneWidget);
      await tester.tap(find.text('睡眠时段'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('time-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('time-24')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );

  testWidgets(
    'repeated event delete offers single and future scope and restores on undo',
    (tester) async {
      await initializeDateFormatting('zh_CN');
      tester.view.physicalSize = const Size(1000, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = PlannerController(
        repository: _EmptyEventRepository(),
        timeZoneId: 'Asia/Shanghai',
      );
      await c.initialize();
      final events = [
        for (final day in [3, 10, 17])
          CalendarEvent.timed(
            id: 'group-$day',
            title: '课程',
            startLocal: DateTime(2026, 11, day, 9),
            endLocal: DateTime(2026, 11, day, 10),
            timeZoneId: 'Asia/Shanghai',
            seriesId: 'group',
          ),
      ];
      await c.saveEvents(events);
      await tester.pumpWidget(WeekGlassApp(controller: c));
      await tester.pumpAndSettle();
      openEventDetails(
        tester.element(find.byType(PlannerScreen)),
        controller: c,
        event: events[1],
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('仅删除本日程'), findsOneWidget);
      expect(find.text('删除此后所有同批日程'), findsOneWidget);
      await tester.tap(find.text('删除此后所有同批日程'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(c.events.map((e) => e.id), ['group-3']);
      expect(find.text('已删除 2 条日程'), findsOneWidget);
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(c.events, hasLength(3));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );

  testWidgets(
    'fit-to-window scale preserves cross-day dragging and edge resizing',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = PlannerController(
        repository: _EmptyEventRepository(),
        timeZoneId: 'Asia/Shanghai',
      );
      await controller.initialize();
      controller.setAnchorDate(DateTime(2026, 11, 3));
      await controller.saveEvent(
        CalendarEvent.timed(
          id: 'drag',
          title: '可拖动任务',
          startLocal: DateTime(2026, 11, 3, 9),
          endLocal: DateTime(2026, 11, 3, 11),
          timeZoneId: 'Asia/Shanghai',
        ),
      );
      await tester.pumpWidget(WeekGlassApp(controller: controller));
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('event-drag'));
      var bounds = tester.getRect(card);
      final move = await tester.startGesture(bounds.center);
      await move.moveBy(const Offset(20, 0));
      await tester.pump();
      await move.moveBy(Offset(bounds.width + 4, 0));
      await tester.pump();
      await move.up();
      await tester.pumpAndSettle();
      expect(controller.events.single.startLocal, DateTime(2026, 11, 4, 9));
      final previousEnd = controller.events.single.endLocal;
      bounds = tester.getRect(card);
      final gesture = await tester.startGesture(
        Offset(bounds.center.dx, bounds.bottom - 2),
      );
      await gesture.moveBy(Offset(0, bounds.height * 2));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 10));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(controller.events.single.startLocal, DateTime(2026, 11, 4, 9));
      expect(controller.events.single.endLocal.isAfter(previousEnd), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'full day fits without vertical scrolling including midnight short events',
    (tester) async {
      tester.view.physicalSize = const Size(800, 560);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = PlannerController(
        repository: _EmptyEventRepository(),
        timeZoneId: 'Asia/Shanghai',
      );
      await controller.initialize();
      await controller.setSleepSchedule(const SleepSchedule(enabled: false));
      controller.setAnchorDate(DateTime(2026, 11, 3));
      await controller.saveEvents([
        CalendarEvent.timed(
          id: 'early',
          title: '午夜任务',
          startLocal: DateTime(2026, 11, 3, 0, 15),
          endLocal: DateTime(2026, 11, 3, 0, 30),
          timeZoneId: 'Asia/Shanghai',
        ),
        CalendarEvent.timed(
          id: 'late',
          title: '深夜任务',
          startLocal: DateTime(2026, 11, 3, 23, 45),
          endLocal: DateTime(2026, 11, 4),
          timeZoneId: 'Asia/Shanghai',
        ),
        for (var i = 0; i < 6; i++)
          CalendarEvent.allDay(
            id: 'all-$i',
            title: '全天任务$i',
            startDate: DateTime(2026, 11, 3),
            endDateExclusive: DateTime(2026, 11, 4),
            timeZoneId: 'Asia/Shanghai',
          ),
      ]);
      await tester.pumpWidget(WeekGlassApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('time-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('time-24')), findsOneWidget);
      expect(
        tester.getBottomRight(find.byKey(const ValueKey('time-24'))).dy,
        lessThanOrEqualTo(560),
      );
      for (final state in tester.stateList<ScrollableState>(
        find.byType(Scrollable),
      )) {
        if (state.position.axis == Axis.vertical) {
          expect(state.position.maxScrollExtent, 0);
        }
      }
      for (final id in ['early', 'late']) {
        final finder = find.byKey(ValueKey('event-$id'));
        expect(finder, findsOneWidget);
        final rect = tester.getRect(finder);
        expect(rect.top, greaterThan(0));
        expect(rect.bottom, lessThanOrEqualTo(553));
      }
      expect(find.byTooltip('6 条全天日程'), findsNothing);
      expect(find.textContaining('全天任务'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets('bulk editor previews and saves a weekly batch with one undo', (
    tester,
  ) async {
    await initializeDateFormatting('zh_CN');
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = PlannerController(
      repository: _EmptyEventRepository(),
      timeZoneId: 'Asia/Shanghai',
    );
    await controller.initialize();
    await tester.pumpWidget(WeekGlassApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('新建日程'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('每周'));
    await tester.pumpAndSettle();
    expect(find.textContaining('共 16 条日程'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('repeat-week-count')),
      '3',
    );
    await tester.enterText(find.byType(TextField).first, '每周练习');
    await tester.ensureVisible(find.text('保存日程'));
    await tester.tap(find.text('保存日程'));
    await tester.pumpAndSettle();
    expect(controller.events.length, 3);
    expect(controller.events.every((e) => e.title == '每周练习'), isTrue);
    expect(controller.events.map((e) => e.seriesId).toSet(), hasLength(1));
    await controller.undo();
    await tester.pumpAndSettle();
    expect(controller.events, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets(
    'Chinese editor saves a local event at minimum desktop size in both themes',
    (tester) async {
      await initializeDateFormatting('zh_CN');
      tester.view.physicalSize = const Size(1000, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = PlannerController(
        repository: _EmptyEventRepository(),
        timeZoneId: 'Asia/Shanghai',
      );
      await controller.initialize();
      await tester.pumpWidget(WeekGlassApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('新建日程'));
      await tester.pumpAndSettle();
      expect(find.text('开始时间'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '玻璃界面验收');
      await tester.tap(find.text('保存日程'));
      await tester.pumpAndSettle();
      final saved = controller.events.single;
      expect(saved.title, '玻璃界面验收');
      expect(find.text('保存日程'), findsNothing);
      final card = find.byKey(ValueKey('event-${saved.id}'));
      for (final mode in [ThemeMode.dark, ThemeMode.light]) {
        controller.setThemeMode(mode);
        await tester.pumpAndSettle();
        await tester.tap(card);
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(Dialog),
            matching: find.text('玻璃界面验收'),
          ),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('关闭'));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'mobile planner keeps the seven-day view reachable without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = PlannerController(
        repository: _EmptyEventRepository(),
        timeZoneId: 'Asia/Shanghai',
      );

      await tester.pumpWidget(
        MaterialApp(home: PlannerScreen(controller: controller)),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CalendarGrid), findsOneWidget);
      expect(find.byType(CalendarGrid), findsOneWidget);
      expect(find.byTooltip('切换视图 · 当前周视图'), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets('desktop planner renders the full navigation shell', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = PlannerController(
      repository: _EmptyEventRepository(),
      timeZoneId: 'Asia/Shanghai',
    );

    await tester.pumpWidget(
      MaterialApp(home: PlannerScreen(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CalendarGrid), findsOneWidget);
    expect(find.bySemanticsLabel('设置'), findsOneWidget);
    expect(find.byType(CalendarGrid), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}

class _EmptyEventRepository implements EventRepository {
  @override
  Future<List<CalendarEvent>> getAllEvents() async => const [];

  @override
  Future<List<CalendarEvent>> getEventsForRange({
    required DateTime startLocal,
    required DateTime endLocal,
  }) async => const [];

  @override
  Future<void> save(CalendarEvent event) async {}

  @override
  Future<void> delete(String id) async {}

  @override
  Future<void> close() async {}
  @override
  Future<void> saveBatch(List<CalendarEvent> events) async {}
  @override
  Future<void> deleteBatch(List<String> ids) async {}
}
