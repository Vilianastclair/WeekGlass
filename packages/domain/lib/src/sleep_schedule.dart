import 'calendar_event.dart';

class SleepSchedule {
  const SleepSchedule({
    this.enabled = true,
    this.sleepMinute = 23 * 60,
    this.wakeMinute = 7 * 60,
  });
  final bool enabled;
  final int sleepMinute;
  final int wakeMinute;
  bool get valid =>
      sleepMinute >= 0 &&
      sleepMinute < 1440 &&
      wakeMinute >= 0 &&
      wakeMinute < 1440 &&
      sleepMinute != wakeMinute &&
      (!enabled || visibleEnd - visibleStart >= 15);
  int get visibleStart => enabled ? wakeMinute : 0;
  int get visibleEnd => enabled
      ? (sleepMinute > wakeMinute ? sleepMinute : sleepMinute + 1440)
      : 1440;
  bool allows(CalendarEvent event) {
    if (!enabled || event.isAllDay) return true;
    final start = event.startLocal;
    final end = event.endLocal;
    for (
      var day = DateTime(start.year, start.month, start.day - 1);
      !day.isAfter(end);
      day = DateTime(day.year, day.month, day.day + 1)
    ) {
      final sleep = DateTime(
        day.year,
        day.month,
        day.day,
        sleepMinute ~/ 60,
        sleepMinute % 60,
      );
      final wake = DateTime(
        day.year,
        day.month,
        day.day + (wakeMinute <= sleepMinute ? 1 : 0),
        wakeMinute ~/ 60,
        wakeMinute % 60,
      );
      if (start.isBefore(wake) && end.isAfter(sleep)) return false;
    }
    return true;
  }
}
