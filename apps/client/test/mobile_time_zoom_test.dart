import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';
import 'package:weekglass/features/planner/calendar_grid.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass/main.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

import 'mobile_planner_test.dart' show mobileApp;
import 'whu_import_test.dart' show MemoryImportRepo;

class VerticalPinch {
  VerticalPinch(this._top, this._bottom, this.center);

  static Future<VerticalPinch> start(
    WidgetTester tester,
    Offset center,
    double span,
  ) async => VerticalPinch(
    await tester.startGesture(center - Offset(0, span / 2)),
    await tester.startGesture(center + Offset(0, span / 2)),
    center,
  );

  final TestGesture _top;
  final TestGesture _bottom;
  final Offset center;

  Future<void> span(double distance) async {
    await _top.moveTo(center - Offset(0, distance / 2));
    await _bottom.moveTo(center + Offset(0, distance / 2));
  }

  Future<void> liftFirst() => _top.up();
  Future<void> liftLast() => _bottom.up();

  Future<void> finish() async {
    await liftFirst();
    await liftLast();
  }

  Future<void> cancel() async {
    await _top.cancel();
    await _bottom.cancel();
  }
}

final class _CountingPreferences extends InMemorySharedPreferencesAsync {
  _CountingPreferences([super.data = const {}]) : super.withData();

  final zoomWrites = <double>[];

  @override
  Future<bool> setDouble(
    String key,
    double value,
    SharedPreferencesOptions options,
  ) {
    if (key == 'mobile_time_zoom') zoomWrites.add(value);
    return super.setDouble(key, value, options);
  }
}

class _CountingRepo extends MemoryImportRepo {
  int writes = 0;

  @override
  Future<void> saveBatch(List<CalendarEvent> values) async {
    writes++;
    await super.saveBatch(values);
  }
}

final _date = DateTime(2026, 11, 2);
const _sleepless = SleepSchedule(enabled: false);
const _awakeWindow = SleepSchedule(
  wakeMinute: 7 * 60 + 15,
  sleepMinute: 22 * 60 + 45,
);

Finder _lane([int daysLater = 0]) => find.byKey(
  ValueKey(
    'day-lane-${_date.add(Duration(days: daysLater)).toIso8601String()}',
  ),
);
Finder _card([String id = 'lecture']) => find.byKey(ValueKey('event-$id'));
Finder _time(int minute) => find.byKey(
  ValueKey(minute % 60 == 0 ? 'time-${minute ~/ 60}' : 'time-minute-$minute'),
);

List<ScrollPosition> _verticalPositions(WidgetTester tester) => tester
    .widgetList<SingleChildScrollView>(
      find.descendant(
        of: find.byType(CalendarGrid),
        matching: find.byType(SingleChildScrollView),
      ),
    )
    .where((view) => view.scrollDirection == Axis.vertical)
    .map((view) => view.controller!.position)
    .toList();

Rect _viewport(WidgetTester tester) {
  final box = tester.getRect(find.byType(CalendarGrid).first);
  final viewHeight = _verticalPositions(tester).first.viewportDimension;
  return Rect.fromLTRB(
    box.left,
    box.bottom - viewHeight,
    box.right,
    box.bottom,
  );
}

double _translation(WidgetTester tester) => tester
    .widget<Transform>(
      find.byKey(const ValueKey('mobile-calendar-translation')),
    )
    .transform
    .storage[12];

Future<({PlannerController controller, _CountingRepo repo})> _mount(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double textScale = 1,
  SleepSchedule sleep = _sleepless,
  PlannerView view = PlannerView.threeDays,
  bool desktop = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);

  final repo = _CountingRepo();
  final controller = PlannerController(
    repository: repo,
    timeZoneId: 'Asia/Shanghai',
  );
  await controller.initialize();
  await controller.setSleepSchedule(sleep);
  controller.setAnchorDate(_date);
  controller.setView(view);
  await controller.saveEvents([
    CalendarEvent.timed(
      id: 'lecture',
      title: '上午课程',
      startLocal: DateTime(2026, 11, 2, 8),
      endLocal: DateTime(2026, 11, 2, 9),
      timeZoneId: 'Asia/Shanghai',
    ),
    CalendarEvent.timed(
      id: 'brief',
      title: '短练习',
      startLocal: DateTime(2026, 11, 3, 16, 20),
      endLocal: DateTime(2026, 11, 3, 16, 25),
      timeZoneId: 'Asia/Shanghai',
    ),
  ]);
  await tester.pumpWidget(
    desktop
        ? WeekGlassApp(controller: controller)
        : mobileApp(controller, textScale: textScale),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  return (controller: controller, repo: repo);
}

void main() {
  late _CountingPreferences preferences;
  setUp(() async {
    preferences = _CountingPreferences();
    SharedPreferencesAsyncPlatform.instance = preferences;
    await initializeDateFormatting('zh_CN');
  });

  testWidgets(
    'spread stretches only time and holds the focal minute in its first frame',
    (tester) async {
      final f = await _mount(tester);
      final before = tester.getRect(_lane());
      final writes = f.repo.writes;
      final center = _viewport(tester).center;
      final pinch = await VerticalPinch.start(tester, center, 72);
      await pinch.span(120);
      await tester.pump();
      final after = tester.getRect(_lane());
      expect(after.height, closeTo(before.height * 120 / 72, .001));
      expect(after.left, before.left);
      expect(after.width, before.width);
      expect(
        (center.dy - after.top) / after.height,
        closeTo((center.dy - before.top) / before.height, .00001),
      );
      final vertical = _verticalPositions(tester);
      expect(vertical.first.pixels, greaterThan(0));
      expect(vertical.first.pixels, closeTo(vertical.last.pixels, .001));
      expect(f.controller.anchorDate, _date);
      expect(f.repo.writes, writes);
      expect(preferences.zoomWrites, isEmpty);
      await pinch.liftFirst();
      await tester.pump();
      expect(preferences.zoomWrites, isEmpty);
      await pinch.liftLast();
      await tester.pumpAndSettle();
      expect(preferences.zoomWrites, hasLength(1));

      final alignedTime = tester.getTopLeft(_time(12 * 60)).dy;
      await tester.dragFrom(center, const Offset(-170, 0));
      await tester.pumpAndSettle();
      expect(f.controller.anchorDate, _date.add(const Duration(days: 3)));
      expect(tester.getTopLeft(_time(12 * 60)).dy, closeTo(alignedTime, .001));
      expect(tester.getSize(_lane(3)).height, closeTo(after.height, .001));

      final reopened = PlannerController(
        repository: f.repo,
        timeZoneId: 'Asia/Shanghai',
      );
      await reopened.initialize();
      expect(reopened.mobileTimeZoom, closeTo(120 / 72, .001));
      reopened.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  for (final (size, scale, sleep) in [
    (const Size(390, 844), 1.0, _sleepless),
    (const Size(320, 568), 1.3, _awakeWindow),
    (const Size(844, 390), 1.3, _sleepless),
  ]) {
    testWidgets('pinch fits the complete configured time window at $size', (
      tester,
    ) async {
      final f = await _mount(
        tester,
        size: size,
        textScale: scale,
        sleep: sleep,
      );
      final viewport = _viewport(tester);
      final center = viewport.center;
      final span = viewport.height * .86;
      // Landscape leaves less room for each squeeze. A completed gesture must
      // retain its scale so the next can continue all the way to fit.
      var pinch = await VerticalPinch.start(tester, center, span);
      for (var i = 0; ; i++) {
        await pinch.span(20);
        await tester.pump();
        if (_verticalPositions(tester).last.maxScrollExtent == 0 || i == 2) {
          break;
        }
        await pinch.finish();
        await tester.pumpAndSettle();
        pinch = await VerticalPinch.start(tester, center, span);
      }
      for (final scroll in _verticalPositions(tester)) {
        expect(scroll.maxScrollExtent, 0);
        expect(scroll.pixels, 0);
      }
      expect(tester.getRect(_lane()).height, closeTo(viewport.height, .001));
      final startLabel = tester.getRect(_time(sleep.visibleStart));
      final endLabel = tester.getRect(_time(sleep.visibleEnd));
      expect(startLabel.top, greaterThanOrEqualTo(viewport.top));
      expect(endLabel.bottom, lessThanOrEqualTo(viewport.bottom));
      final labels = tester
          .widgetList<Text>(
            find.byWidgetPredicate(
              (w) =>
                  w is Text &&
                  w.key is ValueKey<String> &&
                  (w.key! as ValueKey<String>).value.startsWith('time-'),
            ),
          )
          .map((w) => tester.getRect(find.byKey(w.key!)))
          .toList();
      for (var i = 1; i < labels.length; i++) {
        expect(labels[i].top, greaterThan(labels[i - 1].bottom));
      }
      expect(tester.getSize(_card('brief')).height, lessThan(4));
      expect(find.byKey(const ValueKey('card-title-brief')), findsNothing);
      expect(find.byKey(const ValueKey('card-time-brief')), findsNothing);

      await pinch.finish();
      await tester.pumpAndSettle();
      expect(f.controller.mobileTimeZoom, 0);
      expect(preferences.zoomWrites.last, 0.0);
      if (size.height > size.width) {
        expect(preferences.zoomWrites, hasLength(1));
      }
      final writes = f.repo.writes;
      await tester.tap(_card('brief'));
      await tester.pumpAndSettle();
      expect(find.text('短练习'), findsOneWidget);
      expect(find.textContaining('16:20 — 16:25'), findsOneWidget);
      expect(f.repo.writes, writes);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          ValueKey(
            'compact-events-${_date.add(const Duration(days: 1)).toIso8601String()}',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('短练习'));
      await tester.pumpAndSettle();
      expect(find.textContaining('16:20 — 16:25'), findsOneWidget);
    });
  }

  testWidgets(
    'the upper zoom limit reverses immediately and cancel restores height and offset',
    (tester) async {
      final f = await _mount(tester);
      final viewport = _viewport(tester);
      await tester.dragFrom(viewport.center, const Offset(0, -170));
      await tester.pumpAndSettle();
      final before = tester.getRect(_lane());
      final offset = _verticalPositions(tester).last.pixels;
      expect(offset, greaterThan(100));

      final pinch = await VerticalPinch.start(tester, viewport.center, 42);
      await pinch.span(200);
      await tester.pump();
      expect(tester.getSize(_lane()).height, closeTo(before.height * 3, .01));
      await pinch.span(182);
      await tester.pump();
      expect(tester.getSize(_lane()).height, lessThan(before.height * 2.98));

      await pinch.cancel();
      await tester.pumpAndSettle();
      expect(tester.getRect(_lane()).height, closeTo(before.height, .001));
      expect(tester.getRect(_lane()).top, closeTo(before.top, .001));
      for (final scroll in _verticalPositions(tester)) {
        expect(scroll.pixels, closeTo(offset, .001));
      }
      expect(f.controller.mobileTimeZoom, 1);
      expect(preferences.zoomWrites, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('adding a second finger cancels a held card without writing', (
    tester,
  ) async {
    final f = await _mount(tester);
    final before = f.controller.events.first;
    final writes = f.repo.writes;
    final origin = tester.getCenter(_card());
    final edit = await tester.startGesture(origin);
    await tester.pump(const Duration(milliseconds: 600));
    await edit.moveBy(const Offset(0, -56));
    await tester.pump();
    expect(find.byKey(const ValueKey('preview-lecture')), findsOneWidget);
    final second = await tester.startGesture(origin + const Offset(0, 10));
    await second.moveBy(const Offset(0, -35));
    await tester.pump();
    expect(find.byKey(const ValueKey('preview-lecture')), findsNothing);
    expect(tester.getSize(_lane()).height, lessThan(24 * 56));
    await second.up();
    await edit.moveBy(const Offset(0, -74));
    await edit.up();
    await tester.pumpAndSettle();
    expect(f.repo.writes, writes);
    expect(f.controller.events.first.startUtc, before.startUtc);
    expect(f.controller.events.first.endUtc, before.endUtc);
    expect(find.text('新建日程'), findsNothing);
    expect(find.text('调整'), findsNothing);
    expect(preferences.zoomWrites, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the second finger over an adjacent preview takes over a date swipe',
    (tester) async {
      final f = await _mount(tester);
      final viewport = _viewport(tester);
      final first = await tester.startGesture(viewport.center);
      await first.moveBy(const Offset(-165, 0));
      await tester.pump();
      expect(_translation(tester), closeTo(-165, 1));
      expect(find.byType(CalendarGrid), findsNWidgets(2));
      final second = await tester.startGesture(
        Offset(viewport.right - 24, viewport.center.dy + 70),
      );
      await tester.pump();
      expect(_translation(tester), 0);
      expect(find.byType(CalendarGrid), findsOneWidget);
      final before = tester.getSize(_lane()).height;
      await second.moveBy(const Offset(0, -26));
      await tester.pump();
      expect(tester.getSize(_lane()).height, lessThan(before));
      await second.up();
      await first.moveBy(const Offset(-45, 0));
      await first.up();
      await tester.pumpAndSettle();
      expect(f.controller.anchorDate, _date);
      expect(_translation(tester), 0);
      expect(preferences.zoomWrites, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'horizontal two-finger motion is neither zoom nor date navigation',
    (tester) async {
      final f = await _mount(tester);
      final viewport = _viewport(tester);
      final before = tester.getRect(_lane());
      final first = await tester.startGesture(
        viewport.center - const Offset(28, 0),
      );
      final second = await tester.startGesture(
        viewport.center + const Offset(28, 0),
      );
      await first.moveBy(const Offset(-120, 0));
      await second.moveBy(const Offset(120, 0));
      await tester.pump(const Duration(milliseconds: 600));
      await first.up();
      await second.up();
      await tester.pumpAndSettle();
      expect(tester.getRect(_lane()), before);
      expect(f.controller.anchorDate, _date);
      expect(_translation(tester), 0);
      expect(preferences.zoomWrites, isEmpty);
      expect(find.text('新建日程'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a stored phone zoom and two touches leave desktop sizing unchanged',
    (tester) async {
      preferences = _CountingPreferences({'mobile_time_zoom': 3.0});
      SharedPreferencesAsyncPlatform.instance = preferences;
      final f = await _mount(
        tester,
        size: const Size(1266, 753),
        desktop: true,
      );
      final box = _viewport(tester);
      final before = tester.getRect(_lane());
      final pinch = await VerticalPinch.start(
        tester,
        Offset(box.left + 20, box.center.dy),
        80,
      );
      await pinch.span(180);
      await pinch.finish();
      await tester.pumpAndSettle();
      expect(f.controller.mobileTimeZoom, 3);
      expect(tester.getRect(_lane()), before);
      expect(before.height, closeTo(box.height, .001));
      expect(preferences.zoomWrites, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
