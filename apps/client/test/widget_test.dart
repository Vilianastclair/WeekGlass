import 'package:flutter_test/flutter_test.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

void main() {
  test('week starts on Monday', () {
    expect(mondayOf(DateTime(2026, 11, 3)), DateTime(2026, 11, 2));
  });

  test('overlap layout separates simultaneous blocks and reuses lanes', () {
    final day = DateTime(2026, 11, 3);
    final events = [
      CalendarEvent.timed(
        id: 'a',
        title: 'A',
        startLocal: DateTime(day.year, day.month, day.day, 9),
        endLocal: DateTime(day.year, day.month, day.day, 10),
        timeZoneId: 'Asia/Shanghai',
      ),
      CalendarEvent.timed(
        id: 'b',
        title: 'B',
        startLocal: DateTime(day.year, day.month, day.day, 9, 30),
        endLocal: DateTime(day.year, day.month, day.day, 10, 30),
        timeZoneId: 'Asia/Shanghai',
      ),
      CalendarEvent.timed(
        id: 'c',
        title: 'C',
        startLocal: DateTime(day.year, day.month, day.day, 10, 30),
        endLocal: DateTime(day.year, day.month, day.day, 11),
        timeZoneId: 'Asia/Shanghai',
      ),
    ];

    final layout = layoutTimedEvents(events);
    expect(layout['a']!.laneCount, 2);
    expect(layout['b']!.laneCount, 2);
    expect(layout['c']!.laneCount, 1);
  });
}
