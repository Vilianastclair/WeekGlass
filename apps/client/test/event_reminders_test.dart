import 'package:flutter_test/flutter_test.dart';
import 'package:weekglass/app/event_reminders.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

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
