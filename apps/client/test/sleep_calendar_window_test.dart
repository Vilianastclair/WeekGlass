import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:weekglass/features/planner/glass_event_card.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass/main.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

import 'mobile_planner_test.dart' show mobileApp;
import 'whu_import_test.dart' show MemoryImportRepo;

final _day = DateTime(2026, 11, 2);

CalendarEvent _event(String title, int start, int end) => CalendarEvent.timed(
  id: title,
  title: title,
  startLocal: DateTime(_day.year, _day.month, _day.day, start),
  endLocal: DateTime(_day.year, _day.month, _day.day, end),
  timeZoneId: 'Asia/Shanghai',
);

Finder _card(String id) => find.byKey(ValueKey('event-$id'));

Future<void> _setHour(WidgetTester tester, String label, String hour) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(Icons.keyboard_outlined));
  await tester.pumpAndSettle();
  final fields = find.descendant(
    of: find.byType(TimePickerDialog),
    matching: find.byType(TextField),
  );
  await tester.enterText(fields.first, hour);
  await tester.enterText(fields.last, '00');
  await tester.tap(find.text('确定'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await initializeDateFormatting('zh_CN');
  });

  for (final touch in [false, true]) {
    testWidgets(
      '${touch ? 'mobile' : 'desktop'} calendar clips and restores the view, not the events',
      (tester) async {
        tester.view.physicalSize = touch
            ? const Size(390, 844)
            : const Size(1000, 760);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final repo = MemoryImportRepo();
        final original = [
          _event('before', 7, 9),
          _event('morning', 8, 10),
          _event('evening', 16, 18),
          _event('after', 17, 19),
        ];
        await repo.saveBatch(original);
        final c = PlannerController(
          repository: repo,
          timeZoneId: 'Asia/Shanghai',
        );
        await c.initialize();
        c.setAnchorDate(_day);
        if (touch) c.setView(PlannerView.day);
        await tester.pumpWidget(
          touch ? mobileApp(c) : WeekGlassApp(controller: c),
        );
        await tester.pumpAndSettle();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          c.dispose();
        });
        expect(_card('before'), findsOneWidget);
        expect(_card('after'), findsOneWidget);

        await tester.tap(
          touch
              ? find.byKey(const ValueKey('mobile-action-settings'))
              : find.bySemanticsLabel('设置'),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('日历与外观'));
        await tester.pumpAndSettle();
        await _setHour(tester, '起床 07:00', '9');
        await _setHour(tester, '入睡 23:00', '17');
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('关闭设置'));
        await tester.pumpAndSettle();
        expect(_card('before'), findsNothing);
        expect(_card('after'), findsNothing);
        final lane = tester.getRect(
          find.byKey(ValueKey('day-lane-${_day.toIso8601String()}')),
        );
        final morning = tester.getRect(_card('morning'));
        final evening = tester.getRect(_card('evening'));
        expect(morning.top, closeTo(lane.top, .01));
        expect(morning.height, closeTo(lane.height / 8, .01));
        expect(evening.bottom, closeTo(lane.bottom, .01));
        expect(evening.height, closeTo(lane.height / 8, .01));
        GlassEventCard card(String id) => tester.widget<GlassEventCard>(
          find.descendant(of: _card(id), matching: find.byType(GlassEventCard)),
        );
        expect(card('morning').canResizeStart, isFalse);
        expect(card('evening').canResizeEnd, isFalse);
        await tester.tap(_card('morning'));
        await tester.pumpAndSettle();
        expect(find.textContaining('08:00 — 10:00'), findsOneWidget);
        await tester.tap(find.text('调整'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, '仅更新标题');
        await tester.tap(find.text('保存日程'));
        await tester.pumpAndSettle();
        final edited = repo.records['morning']!;
        expect(edited.title, '仅更新标题');
        expect(edited.startUtc, original[1].startUtc);
        expect(edited.endUtc, original[1].endUtc);
        await c.undo();

        await c.setSleepSchedule(const SleepSchedule(enabled: false));
        await tester.pumpAndSettle();
        expect(_card('before'), findsOneWidget);
        expect(_card('after'), findsOneWidget);
        expect(await repo.getAllEvents(), orderedEquals(original));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
