import 'package:flutter_test/flutter_test.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

void main() {
  test(
    'biweekly multi-day schedule starts at anchor week and includes cutoff',
    () {
      final plan = RepeatPlan(
        frequency: RepeatFrequency.weekly,
        until: DateTime(2026, 11, 19),
        interval: 2,
        weekdays: {2, 4},
      );
      expect(plan.datesFrom(DateTime(2026, 11, 3)), [
        DateTime(2026, 11, 3),
        DateTime(2026, 11, 5),
        DateTime(2026, 11, 17),
        DateTime(2026, 11, 19),
      ]);
    },
  );
  test('month day 31 skips short months without overflowing', () {
    final plan = RepeatPlan(
      frequency: RepeatFrequency.monthly,
      until: DateTime(2027, 5, 31),
    );
    expect(plan.datesFrom(DateTime(2027, 1, 31)), [
      DateTime(2027, 1, 31),
      DateTime(2027, 3, 31),
      DateTime(2027, 5, 31),
    ]);
  });
  test('monthly leap date and interval retain actual calendar day', () {
    final plan = RepeatPlan(
      frequency: RepeatFrequency.monthly,
      until: DateTime(2028, 4, 29),
      interval: 2,
    );
    expect(plan.datesFrom(DateTime(2027, 12, 29)), [
      DateTime(2027, 12, 29),
      DateTime(2028, 2, 29),
      DateTime(2028, 4, 29),
    ]);
  });
  test(
    'repeated timed and all-day events preserve wall-clock time and span',
    () {
      final plan = RepeatPlan(
        frequency: RepeatFrequency.weekly,
        until: DateTime(2026, 11, 10),
        weekdays: {2},
      );
      var id = 0;
      final timed = CalendarEvent.timed(
        id: 'template',
        title: '练习',
        startLocal: DateTime(2026, 11, 3, 23, 30),
        endLocal: DateTime(2026, 11, 4),
        timeZoneId: 'Asia/Shanghai',
      );
      final result = expandRepeatedEvent(
        timed,
        plan,
        newId: () => '${id++}',
        seriesId: 'series',
      );
      expect(result.last.startLocal, DateTime(2026, 11, 10, 23, 30));
      expect(result.last.endLocal, DateTime(2026, 11, 11));
      expect(result.map((e) => e.id).toSet(), hasLength(2));
      expect(result.every((e) => e.seriesId == 'series'), isTrue);
      final allDay = CalendarEvent.allDay(
        id: 'a',
        title: '休息',
        startDate: DateTime(2026, 11, 3),
        endDateExclusive: DateTime(2026, 11, 5),
        timeZoneId: 'Asia/Shanghai',
      );
      final all = expandRepeatedEvent(
        allDay,
        plan,
        newId: () => '${id++}',
        seriesId: 'all',
      );
      expect(all.last.allDayEndDateExclusive, DateTime(2026, 11, 12));
      expect(all.last.recurrenceRule, contains('WEEKLY'));
    },
  );
  test('invalid ranges, no weekdays and excessive expansion are rejected', () {
    expect(
      () => RepeatPlan(
        frequency: RepeatFrequency.weekly,
        until: DateTime(2026, 1, 1),
        weekdays: {2},
      ).datesFrom(DateTime(2026, 11, 3)),
      throwsArgumentError,
    );
    expect(
      () => RepeatPlan(
        frequency: RepeatFrequency.weekly,
        until: DateTime(2026, 12, 1),
      ).datesFrom(DateTime(2026, 11, 3)),
      throwsArgumentError,
    );
    expect(
      () => RepeatPlan(
        frequency: RepeatFrequency.weekly,
        until: DateTime(2040),
        weekdays: {1, 2, 3, 4, 5, 6, 7},
      ).datesFrom(DateTime(2026)),
      throwsArgumentError,
    );
  });
}
