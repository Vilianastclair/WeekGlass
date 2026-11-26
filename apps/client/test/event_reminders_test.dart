import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:weekglass/app/event_reminders.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

import 'whu_import_test.dart' show MemoryImportRepo;

CalendarEvent event(String id, DateTime start, DateTime end) =>
    CalendarEvent.timed(
      id: id,
      title: id,
      startLocal: start,
      endLocal: end,
      timeZoneId: 'Asia/Shanghai',
    );

void main() {
  final at = DateTime.utc(2026, 11, 4, 12);
  testWidgets('native notification click opens the correct stored event date', (tester) async {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    final repo = MemoryImportRepo();
    final meeting = event('class', at, at.add(const Duration(hours: 1)));
    await repo.save(meeting);
    final planner = PlannerController(repository: repo, timeZoneId: 'Asia/Shanghai');
    await planner.initialize();
    planner.setAnchorDate(DateTime(2026, 1, 1));
    const channel = MethodChannel('weekglass/desktop');
    final messenger = tester.binding.defaultBinaryMessenger;
    final requests = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      requests.add(call.method);
      return null;
    });
    final reminders = DesktopReminders(planner);
    try {
      await reminders.start(signalReady: true);
      expect(requests, ['remindersReady']);
      await tester.runAsync(() => messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(const MethodCall('openEvent', 'class')),
        (_) {},
      ));
      final local = meeting.startLocal;
      expect(planner.anchorDate, DateTime(local.year, local.month, local.day));
    } finally {
      reminders.dispose();
      planner.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
  test('start/end triggers once, adjacent boundaries form one notice', () {
    final engine = ReminderEngine(
      startedAt: at.subtract(const Duration(minutes: 2)),
    );
    final events = [
      event('洗漱', at, at.add(const Duration(minutes: 5))),
      event('阅读', at.subtract(const Duration(hours: 1)), at),
    ];
    final due = engine.due(events, at);
    expect(due.length, 2);
    expect(due.first.start, false);
    final notice = ReminderEngine.notice(due);
    expect(notice.title, '日程交接');
    expect(notice.body, contains('洗漱'));
    expect(notice.body, contains('阅读'));
    expect(notice.eventId, '洗漱');
    engine.delivered.addAll(due.map((b) => b.key));
    expect(engine.due(events, at.add(const Duration(seconds: 2))), isEmpty);
    final ending = engine.due(events, at.add(const Duration(minutes: 5)));
    expect(ending.single.start, false);
    expect(ReminderEngine.notice(ending).title, '日程结束');
  });

  test('uses latest data after moves/deletion and only catches recent wake-up boundaries', () {
    final engine = ReminderEngine(
      startedAt: at.subtract(const Duration(days: 1)),
    );
    final moved = event(
      'moved',
      at.add(const Duration(minutes: 5)),
      at.add(const Duration(minutes: 10)),
    );
    final deleted = event(
      'deleted',
      at,
      at.add(const Duration(minutes: 1)),
    ).markedDeleted(at);
    expect(engine.due([moved, deleted], at), isEmpty);
    final recent = event(
      'recent',
      at.subtract(const Duration(seconds: 80)),
      at.add(const Duration(hours: 1)),
    );
    final stale = event(
      'stale',
      at.subtract(const Duration(hours: 1)),
      at.subtract(const Duration(minutes: 10)),
    );
    expect(engine.due([recent, stale], at).single.event.id, 'recent');
  });

  test('startup has no historical burst and history survives restart/clock reversal', () {
    final scheduled = event('same', at, at.add(const Duration(hours: 1)));
    final engine = ReminderEngine(
      startedAt: at.subtract(const Duration(seconds: 10)),
    );
    final first = engine.due([scheduled], at);
    final reloaded = ReminderEngine(
      startedAt: at.subtract(const Duration(seconds: 10)),
      delivered: first.map((b) => b.key),
    );
    expect(reloaded.due([scheduled], at), isEmpty);
    final startup = ReminderEngine(
      startedAt: at.add(const Duration(seconds: 1)),
    );
    expect(
      startup.due([scheduled], at.add(const Duration(seconds: 2))),
      isEmpty,
    );
    reloaded.eligibleAfter = at.add(const Duration(minutes: 2));
    expect(
      reloaded.due([scheduled], at.add(const Duration(minutes: 1))),
      isEmpty,
    );
  });

  test('changed boundary can remind again; changing a name does not duplicate an alert', () {
    final engine = ReminderEngine(
      startedAt: at.subtract(const Duration(minutes: 1)),
    );
    final original = event('schedule', at, at.add(const Duration(hours: 1)));
    engine.delivered.addAll(engine.due([original], at).map((b) => b.key));
    expect(
      engine.due([
        original.withDetails(
          title: 'new',
          color: original.color,
          notes: original.notes,
        ),
      ], at),
      isEmpty,
    );
    final moved = original.withTimedRange(
      at.add(const Duration(minutes: 10)),
      at.add(const Duration(minutes: 20)),
    );
    expect(
      engine.due([moved], at.add(const Duration(minutes: 10))).single.start,
      true,
    );
  });
}
