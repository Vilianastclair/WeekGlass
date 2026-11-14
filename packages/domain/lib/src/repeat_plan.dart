import 'calendar_event.dart';

enum RepeatFrequency { none, weekly, monthly }

/// Finite expansion in local calendar dates; monthly dates that do not exist
/// are skipped rather than silently moving into the following month.
class RepeatPlan {
  const RepeatPlan({
    required this.frequency,
    required this.until,
    this.interval = 1,
    this.weekdays = const {},
  });
  final RepeatFrequency frequency;
  final DateTime until;
  final int interval;
  final Set<int> weekdays;

  List<DateTime> datesFrom(DateTime start) {
    final first = DateTime(start.year, start.month, start.day);
    final last = DateTime(until.year, until.month, until.day);
    if (interval < 1 || interval > 52) throw ArgumentError('重复间隔须为 1–52。');
    if (last.isBefore(first)) throw ArgumentError('截止日期不能早于开始日期。');
    if (frequency == RepeatFrequency.none) return [first];
    if (frequency == RepeatFrequency.weekly &&
        (weekdays.isEmpty || weekdays.any((d) => d < 1 || d > 7))) {
      throw ArgumentError('请至少选择一个星期。');
    }
    final dates = <DateTime>[];
    void add(DateTime date) {
      dates.add(date);
      if (dates.length > 2000) throw ArgumentError('单次最多生成 2000 条日程，请缩短日期范围。');
    }

    if (frequency == RepeatFrequency.weekly) {
      // UTC date ordinals avoid DST changing the count of calendar days.
      final week = DateTime.utc(
        first.year,
        first.month,
        first.day - first.weekday + 1,
      );
      for (
        var date = first;
        !date.isAfter(last);
        date = DateTime(date.year, date.month, date.day + 1)
      ) {
        final days = DateTime.utc(
          date.year,
          date.month,
          date.day,
        ).difference(week).inDays;
        if (days ~/ 7 % interval == 0 && weekdays.contains(date.weekday))
          add(date);
      }
    } else {
      for (var month = 0; ; month += interval) {
        final monthStart = DateTime(first.year, first.month + month, 1);
        if (monthStart.isAfter(last)) break;
        final candidate = DateTime(
          monthStart.year,
          monthStart.month,
          first.day,
        );
        if (candidate.month == monthStart.month && !candidate.isAfter(last))
          add(candidate);
      }
    }
    return dates;
  }

  String get rule =>
      'FREQ=${frequency == RepeatFrequency.weekly ? 'WEEKLY' : 'MONTHLY'};INTERVAL=$interval;UNTIL=${until.toIso8601String()};BYDAY=${(weekdays.toList()..sort()).join(',')}';
}

List<CalendarEvent> expandRepeatedEvent(
  CalendarEvent event,
  RepeatPlan plan, {
  required String Function() newId,
  required String seriesId,
}) {
  final dates = plan.datesFrom(event.startLocal);
  return dates.map((date) {
    final start = event.startLocal;
    final end = event.endLocal;
    final id = newId();
    if (event.isAllDay) {
      final span = DateTime.utc(
        end.year,
        end.month,
        end.day,
      ).difference(DateTime.utc(start.year, start.month, start.day)).inDays;
      return CalendarEvent.allDay(
        id: id,
        title: event.title,
        notes: event.notes,
        color: event.color,
        startDate: date,
        endDateExclusive: DateTime(date.year, date.month, date.day + span),
        timeZoneId: event.timeZoneId,
        recurrenceRule: plan.rule,
        seriesId: seriesId,
      );
    }
    final dayOffset = DateTime.utc(
      end.year,
      end.month,
      end.day,
    ).difference(DateTime.utc(start.year, start.month, start.day)).inDays;
    return CalendarEvent.timed(
      id: id,
      title: event.title,
      notes: event.notes,
      color: event.color,
      startLocal: DateTime(
        date.year,
        date.month,
        date.day,
        start.hour,
        start.minute,
      ),
      endLocal: DateTime(
        date.year,
        date.month,
        date.day + dayOffset,
        end.hour,
        end.minute,
      ),
      timeZoneId: event.timeZoneId,
      recurrenceRule: plan.rule,
      seriesId: seriesId,
    );
  }).toList();
}
