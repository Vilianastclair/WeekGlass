import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:weekglass/main.dart';
import 'package:weekglass/features/planner/calendar_grid.dart';
import 'package:weekglass/features/planner/glass_event_card.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

import 'whu_import_test.dart' show MemoryImportRepo;

class _CountingRepo extends MemoryImportRepo {
  int writes = 0;
  @override
  Future<void> saveBatch(List<CalendarEvent> events) async {
    writes++;
    await super.saveBatch(events);
  }
}

void main() {
  Future<
    ({PlannerController controller, _CountingRepo repo, CalendarEvent event})
  >
  mount(
    WidgetTester tester, {
    bool series = false,
    bool tiny = false,
    double textScale = 1,
  }) async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await initializeDateFormatting('zh_CN');
    tester.view.physicalSize = const Size(1266, 753);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final repo = _CountingRepo();
    final c = PlannerController(repository: repo, timeZoneId: 'Asia/Shanghai');
    await c.initialize();
    c.setAnchorDate(DateTime(2026, 11, 3));
    final event = CalendarEvent.timed(
      id: 'return',
      title: '轻松阅读',
      startLocal: DateTime(2026, 11, 3, 9, 50),
      endLocal: DateTime(2026, 11, 3, tiny ? 9 : 11, tiny ? 51 : 25),
      timeZoneId: 'Asia/Shanghai',
      seriesId: series ? 'reading' : null,
    );
    await c.saveEvents([
      event,
      if (series)
        CalendarEvent.timed(
          id: 'next',
          title: '轻松阅读',
          startLocal: DateTime(2026, 11, 10, 9, 50),
          endLocal: DateTime(2026, 11, 10, 11, 25),
          timeZoneId: 'Asia/Shanghai',
          seriesId: 'reading',
        ),
    ]);
    await tester.pumpWidget(WeekGlassApp(controller: c));
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    });
    return (controller: c, repo: repo, event: event);
  }

  Finder event() => find.byKey(const ValueKey('event-return'));
  Finder preview() => find.byKey(const ValueKey('preview-return'));
  Finder lane(int day) => find.byKey(
    ValueKey('day-lane-${DateTime(2026, 11, day).toIso8601String()}'),
  );

  testWidgets(
    'magnetic return eases to the exact non-quarter origin without writes or batch prompt',
    (tester) async {
      final fixture = await mount(tester, series: true);
      final original = tester.getRect(event());
      final origin = original.center;
      final writes = fixture.repo.writes;
      final drag = await tester.startGesture(
        origin,
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(Offset(tester.getSize(lane(3)).width, 28));
      await tester.pumpAndSettle();
      final away = tester.getRect(preview());
      expect(away.left, greaterThan(original.left));
      await drag.moveTo(origin + const Offset(3, 2));
      await tester.pump();
      final first = tester.getRect(preview());
      expect(first.left, closeTo(away.left, .01));
      await tester.pump(const Duration(milliseconds: 60));
      final middle = tester.getRect(preview());
      expect(middle.left, inExclusiveRange(original.left, away.left));
      await tester.pump(const Duration(milliseconds: 500));
      final restored = tester.getRect(preview());
      expect(restored.left, closeTo(original.left, .01));
      expect(restored.top, closeTo(original.top, .01));
      final card = tester.widget<GlassEventCard>(
        find.descendant(of: preview(), matching: find.byType(GlassEventCard)),
      );
      expect(card.event.startLocal, fixture.event.startLocal);
      expect(card.event.endLocal, fixture.event.endLocal);
      await drag.up();
      await tester.pumpAndSettle();
      await drag.removePointer();
      expect(find.byKey(const ValueKey('batch-edit-scope')), findsNothing);
      expect(fixture.repo.writes, writes);
      expect(
        fixture.controller.events
            .firstWhere((e) => e.id == 'return')
            .startLocal,
        DateTime(2026, 11, 3, 9, 50),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'fast release inside return magnet commits the origin before the animation finishes',
    (tester) async {
      final fixture = await mount(tester);
      final origin = tester.getCenter(event());
      final writes = fixture.repo.writes;
      final drag = await tester.startGesture(
        origin,
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(26, 30));
      await tester.pump();
      await drag.moveTo(origin + const Offset(1, 1));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      await drag.removePointer();
      expect(fixture.repo.writes, writes);
      expect(
        fixture.controller.events.single.startLocal,
        fixture.event.startLocal,
      );
    },
  );

  testWidgets(
    'continuous card reaches all canvas edges while landing remains on valid quarter hours',
    (tester) async {
      final fixture = await mount(tester);
      final origin = tester.getCenter(event());
      final first = tester.getRect(lane(2));
      final last = tester.getRect(lane(8));
      final calendar = tester.getRect(find.byType(CalendarGrid));
      expect(last.bottom, closeTo(calendar.bottom, .01));
      expect(last.right, closeTo(calendar.right, .01));
      final drag = await tester.startGesture(
        origin,
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveTo(first.topLeft - const Offset(100, 100));
      await tester.pumpAndSettle();
      var live = tester.getRect(preview());
      expect(live.top, closeTo(first.top, .01));
      expect(live.left, closeTo(first.left, .01));
      await drag.moveTo(last.bottomRight + const Offset(100, 100));
      await tester.pumpAndSettle();
      live = tester.getRect(preview());
      expect(live.bottom, closeTo(last.bottom, .01));
      expect(live.right, closeTo(last.right, .01));
      final landing = tester.getRect(
        find.byKey(const ValueKey('drop-target-return')),
      );
      expect(
        landing.bottom,
        lessThan(live.bottom),
      ); // 95-minute event cannot end at 23:00 on a quarter start.
      await drag.up();
      await tester.pumpAndSettle();
      await drag.removePointer();
      expect(
        fixture.controller.events.single.startLocal,
        DateTime(2026, 11, 8, 21, 15),
      );
      expect(
        fixture.controller.events.single.endLocal,
        DateTime(2026, 11, 8, 22, 50),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'resize preview meets both time edges exactly without changing minute precision',
    (tester) async {
      final fixture = await mount(tester);
      final bounds = tester.getRect(lane(3));
      var rect = tester.getRect(event());
      var drag = await tester.startGesture(
        Offset(rect.center.dx, rect.top + 1),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveTo(Offset(rect.center.dx, bounds.top - 40));
      await tester.pumpAndSettle();
      expect(tester.getRect(preview()).top, closeTo(bounds.top, .01));
      await drag.up();
      await tester.pumpAndSettle();
      await drag.removePointer();
      expect(
        fixture.controller.events.single.startLocal,
        DateTime(2026, 11, 3, 7),
      );
      rect = tester.getRect(event());
      drag = await tester.startGesture(
        Offset(rect.center.dx, rect.bottom - 1),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveTo(Offset(rect.center.dx, bounds.bottom + 40));
      await tester.pumpAndSettle();
      expect(tester.getRect(preview()).bottom, closeTo(bounds.bottom, .01));
      await drag.up();
      await tester.pumpAndSettle();
      await drag.removePointer();
      expect(
        fixture.controller.events.single.endLocal,
        DateTime(2026, 11, 3, 23),
      );
    },
  );

  testWidgets(
    'minimal cards retain their scaled height and resize edges when blank',
    (tester) async {
      final fixture = await mount(tester, tiny: true, textScale: 1.3);
      final rect = tester.getRect(event());
      expect(rect.height, inExclusiveRange(18, 24));
      expect(find.byKey(const ValueKey('card-title-return')), findsNothing);
      expect(find.byKey(const ValueKey('card-time-return')), findsNothing);
      expect(
        fixture.controller.events.single.duration,
        const Duration(minutes: 1),
      );
      final drag = await tester.startGesture(
        Offset(rect.center.dx, rect.bottom - 1),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(0, 30));
      await tester.pumpAndSettle();
      expect(tester.getRect(preview()).height, greaterThan(rect.height));
      await drag.cancel();
      await tester.pumpAndSettle();
      await drag.removePointer();
      expect(
        fixture.controller.events.single.duration,
        const Duration(minutes: 1),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
