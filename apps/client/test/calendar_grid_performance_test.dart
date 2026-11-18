import 'dart:math' as math;
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:weekglass/features/planner/calendar_grid.dart';
import 'package:weekglass/features/planner/glass_event_card.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass/main.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

import 'mobile_planner_test.dart' show mobileApp;
import 'whu_import_test.dart' show MemoryImportRepo;

class _CountingController extends PlannerController {
  _CountingController()
    : super(repository: MemoryImportRepo(), timeZoneId: 'Asia/Shanghai');
  int windowReads = 0;

  @override
  List<CalendarEvent> timedEventsInWindow(DateTime date) {
    windowReads++;
    return super.timedEventsInWindow(date);
  }
}

CalendarEvent _event(String id, int day, int start, int duration) =>
    CalendarEvent.timed(
      id: id,
      title: '虚构课程',
      startLocal: DateTime(2026, 11, day, 0, start),
      endLocal: DateTime(2026, 11, day, 0, start + duration),
      timeZoneId: 'Asia/Shanghai',
    );

double _minute(DateTime value, DateTime day) =>
    DateTime.utc(
      value.year,
      value.month,
      value.day,
      value.hour,
      value.minute,
      value.second,
      value.millisecond,
      value.microsecond,
    ).difference(DateTime.utc(day.year, day.month, day.day)).inMicroseconds /
    Duration.microsecondsPerMinute;

(double, double) _referenceBand(
  CalendarEvent event,
  List<CalendarEvent> events,
  DateTime day,
  int visibleStart,
  int visibleEnd,
  double scale,
  double minimum,
) {
  final eventStart = _minute(event.startLocal, day);
  final eventEnd = _minute(event.endLocal, day);
  final start = eventStart.clamp(visibleStart, visibleEnd).toDouble();
  final end = eventEnd.clamp(visibleStart, visibleEnd).toDouble();
  if (start != eventStart || end != eventEnd) {
    return ((start - visibleStart) * scale, (end - start) * scale);
  }
  var before = visibleStart.toDouble();
  var after = visibleEnd.toDouble();
  for (final other in events) {
    if (other.id == event.id) continue;
    final otherStart = _minute(other.startLocal, day);
    final otherEnd = _minute(other.endLocal, day);
    if (otherEnd <= start) before = math.max(before, otherEnd);
    if (otherStart >= end) after = math.min(after, otherStart);
  }
  final available = math.max(.01, (after - before) * scale);
  final height = math.min(available, math.max(minimum, (end - start) * scale));
  final earliest = (before - visibleStart) * scale;
  final latest = math.max(earliest, (after - visibleStart) * scale - height);
  final top = ((start - visibleStart) * scale).clamp(earliest, latest);
  return (
    top.clamp(0.0, math.max(0.0, (visibleEnd - visibleStart) * scale - height)),
    height,
  );
}

void main() {
  setUp(() async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await initializeDateFormatting('zh_CN');
  });

  test('indexed bands match neighbor scan for dense overlap, clipping and previews', () {
    final day = DateTime(2026, 11, 3);
    final random = math.Random(29);
    final events = [
      _event('before-midnight', 2, 23 * 60, 9 * 60),
      _event('after-midnight', 3, 22 * 60, 3 * 60),
      _event('adjacent-a', 3, 540, 1),
      _event('adjacent-b', 3, 541, 1),
      for (var i = 0; i < 180; i++)
        _event(
          'dense-$i',
          3,
          420 + random.nextInt(930),
          1 + random.nextInt(120),
        ),
    ];
    for (final (start, end, scale, minimum) in [
      (420, 1380, .65, 18.0),
      (0, 1440, 1.25, 25.0),
    ]) {
      final layout = CalendarDayLayout(
        day: day,
        events: events,
        startMinute: start,
        endMinute: end,
        scale: scale,
        minimumHeight: minimum,
      );
      final probes = [
        ...events,
        for (final event in events.take(20))
          event.withTimedRange(
            event.startLocal.add(const Duration(minutes: 150)),
            event.endLocal.add(const Duration(minutes: 150)),
          ),
      ];
      for (final event in probes) {
        final expected = _referenceBand(
          event,
          events,
          day,
          start,
          end,
          scale,
          minimum,
        );
        final actual = layout.band(event);
        expect(actual.$1, closeTo(expected.$1, 1e-8), reason: event.id);
        expect(actual.$2, closeTo(expected.$2, 1e-8), reason: event.id);
      }
      final referenceLanes = layoutTimedEvents(events);
      for (final event in events) {
        expect(
          layout.lanes[event.id]!.laneCount,
          referenceLanes[event.id]!.laneCount,
        );
        expect(
          layout.lanes[event.id]!.laneIndex,
          referenceLanes[event.id]!.laneIndex,
        );
      }
    }
  });

  testWidgets(
    'dense week retains stationary cards and day layouts during drag frames',
    (tester) async {
      tester.view.physicalSize = const Size(1266, 753);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _CountingController();
      await controller.initialize();
      controller.setAnchorDate(DateTime(2026, 11, 2));
      await controller.saveEvents([
        for (var day = 2; day < 9; day++)
          for (var i = 0; i < 18; i++)
            _event('dense-$day-$i', day, 480 + i * 45, 25),
      ]);
      await tester.pumpWidget(WeekGlassApp(controller: controller));
      await tester.pumpAndSettle();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      });
      controller.windowReads = 0;
      controller.setAnchorDate(DateTime(2026, 11, 2));
      await tester.pumpAndSettle();
      expect(controller.windowReads, 7);

      final card = find.byKey(const ValueKey('event-dense-2-0'));
      final drag = await tester.startGesture(
        tester.getCenter(card),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(0, 25));
      await tester.pump();
      final stationary = find.descendant(
        of: find.byKey(const ValueKey('event-dense-2-1')),
        matching: find.byType(GlassEventCard),
      );
      final stationaryCard = tester.widget<GlassEventCard>(stationary);
      for (var i = 0; i < 4; i++) {
        controller.windowReads = 0;
        await drag.moveBy(const Offset(.4, .4));
        await tester.pump();
        expect(controller.windowReads, 0);
        expect(tester.widget<GlassEventCard>(stationary), same(stationaryCard));
      }
      await drag.cancel();
      await tester.pumpAndSettle();
      await drag.removePointer();

      controller.windowReads = 0;
      await controller.saveEvent(_event('fresh', 4, 600, 75));
      await tester.pumpAndSettle();
      expect(controller.windowReads, 7);
      expect(find.byKey(const ValueKey('event-fresh')), findsOneWidget);
    },
  );

  testWidgets(
    'touch drag retains cards between snap targets and refreshes on sync',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _CountingController();
      await controller.initialize();
      controller.setView(PlannerView.threeDays);
      controller.setAnchorDate(DateTime(2026, 11, 2));
      await controller.saveEvents([
        _event('touch-source', 2, 480, 60),
        for (var day = 2; day < 5; day++)
          for (var i = 0; i < 6; i++)
            _event('touch-$day-$i', day, 630 + i * 70, 45),
      ]);
      await tester.pumpWidget(mobileApp(controller));
      await tester.pumpAndSettle();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      });

      final source = find.byKey(const ValueKey('event-touch-source'));
      final preview = find.byKey(const ValueKey('preview-touch-source'));
      final landing = find.byKey(const ValueKey('drop-target-touch-source'));
      final stationary = find.descendant(
        of: find.byKey(const ValueKey('event-touch-2-0')),
        matching: find.byType(GlassEventCard),
      );
      Finder previewCard() =>
          find.descendant(of: preview, matching: find.byType(GlassEventCard));

      final drag = await tester.startGesture(tester.getCenter(source));
      await tester.pump(const Duration(milliseconds: 600));
      await drag.moveBy(const Offset(0, 18));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 16));
      final stationaryCard = tester.widget<GlassEventCard>(stationary);
      final snappedCard = tester.widget<GlassEventCard>(previewCard());
      expect(snappedCard.event.startLocal, DateTime(2026, 11, 2, 8, 15));
      final snappedBounds = tester.getRect(landing);
      var followerTop = tester.getTopLeft(preview).dy;
      for (var i = 0; i < 4; i++) {
        controller.windowReads = 0;
        await drag.moveBy(const Offset(0, .4));
        await tester.pump();
        final nextTop = tester.getTopLeft(preview).dy;
        expect(nextTop - followerTop, closeTo(.4, .03));
        followerTop = nextTop;
        expect(tester.getRect(landing), snappedBounds);
        expect(tester.widget<GlassEventCard>(stationary), same(stationaryCard));
        expect(tester.widget<GlassEventCard>(previewCard()), same(snappedCard));
        expect(controller.windowReads, 0);
      }

      await drag.moveBy(const Offset(0, 12));
      await tester.pump();
      expect(
        tester.widget<GlassEventCard>(previewCard()).event.startLocal,
        DateTime(2026, 11, 2, 8, 30),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 16));
      final unsharedWidth = tester.getSize(landing).width;

      // A sync may change overlapping events while the pointer is still down.
      // The next parent build must replace the retained day snapshot.
      await controller.repository.saveBatch([_event('remote', 2, 510, 60)]);
      await controller.reloadAfterSync();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byKey(const ValueKey('event-remote')), findsOneWidget);
      expect(tester.getSize(landing).width, lessThan(unsharedWidth));
      controller.windowReads = 0;
      await drag.moveBy(const Offset(0, .4));
      await tester.pump();
      expect(controller.windowReads, 0);
      await drag.up();
      await tester.pumpAndSettle();
      expect(
        controller.events
            .singleWhere((event) => event.id == 'touch-source')
            .startLocal,
        DateTime(2026, 11, 2, 8, 30),
      );
      expect(tester.takeException(), isNull);
      await drag.removePointer();
    },
  );

  testWidgets('touch selection updates only its live and snapped overlays', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = _CountingController();
    await controller.initialize();
    controller.setView(PlannerView.day);
    controller.setAnchorDate(DateTime(2026, 11, 2));
    await controller.saveEvent(_event('selection-neighbor', 2, 480, 60));
    await tester.pumpWidget(mobileApp(controller));
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });

    final lane = tester.getRect(
      find.byKey(
        ValueKey('day-lane-${DateTime(2026, 11, 2).toIso8601String()}'),
      ),
    );
    final stationary = find.descendant(
      of: find.byKey(const ValueKey('event-selection-neighbor')),
      matching: find.byType(GlassEventCard),
    );
    final select = await tester.startGesture(
      Offset(lane.center.dx, lane.top + 15),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await select.moveBy(const Offset(0, 24));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 16));
    final stationaryCard = tester.widget<GlassEventCard>(stationary);
    final landing = find.byKey(const ValueKey('creation-landing'));
    final live = find.byKey(const ValueKey('creation-live'));
    final snappedBounds = tester.getRect(landing);
    var liveBottom = tester.getBottomLeft(live).dy;
    for (var i = 0; i < 4; i++) {
      controller.windowReads = 0;
      await select.moveBy(const Offset(0, .4));
      await tester.pump();
      final nextBottom = tester.getBottomLeft(live).dy;
      expect(nextBottom - liveBottom, closeTo(.4, .03));
      liveBottom = nextBottom;
      expect(tester.getRect(landing), snappedBounds);
      expect(tester.widget<GlassEventCard>(stationary), same(stationaryCard));
      expect(controller.windowReads, 0);
    }
    await select.cancel();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('creation-live')), findsNothing);
    expect(tester.takeException(), isNull);
    await select.removePointer();
  });

  testWidgets(
    'scroll changes only material visibility while keeping cards mounted',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _CountingController();
      await controller.initialize();
      controller.setView(PlannerView.day);
      controller.setAnchorDate(DateTime(2026, 11, 2));
      await controller.saveEvents([
        _event('early', 2, 480, 60),
        _event('late', 2, 1200, 60),
        _event('sunday', 8, 1200, 60),
      ]);
      await tester.pumpWidget(mobileApp(controller));
      await tester.pumpAndSettle();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      });
      GlassEventCard card(String id) => tester.widget<GlassEventCard>(
        find.byWidgetPredicate(
          (widget) => widget is GlassEventCard && widget.event.id == id,
        ),
      );
      expect(card('early').materialActive, isTrue);
      expect(card('late').materialActive, isFalse);
      controller.windowReads = 0;
      final grid = tester.getRect(find.byType(CalendarGrid));
      await tester.dragFrom(
        Offset(grid.right - 20, grid.center.dy),
        const Offset(0, -450),
      );
      await tester.pumpAndSettle();
      expect(controller.windowReads, 0);
      expect(card('early').materialActive, isFalse);
      expect(card('late').materialActive, isTrue);

      controller.setView(PlannerView.week);
      await tester.pumpAndSettle();
      expect(card('sunday').materialActive, isFalse);
      controller.windowReads = 0;
      final horizontal = tester
          .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .firstWhere(
            (scroll) =>
                scroll.scrollDirection == Axis.horizontal &&
                scroll.controller!.position.maxScrollExtent > 0,
          );
      horizontal.controller!.jumpTo(
        horizontal.controller!.position.maxScrollExtent,
      );
      await tester.pumpAndSettle();
      expect(controller.windowReads, 0);
      expect(card('sunday').materialActive, isTrue);
    },
  );
}
