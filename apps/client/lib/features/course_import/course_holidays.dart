import 'package:weekglass_domain/weekglass_domain.dart';

DateTime _date(DateTime value) => DateTime(value.year, value.month, value.day);

/// Inclusive local dates as announced by the school. This never reschedules
/// make-up classes and never infers a vacation from a national holiday.
class CourseHoliday {
  CourseHoliday({
    required this.name,
    required DateTime start,
    required DateTime end,
  }) : start = _date(start),
       end = _date(end) {
    if (name.trim().isEmpty || this.end.isBefore(this.start)) {
      throw ArgumentError('请填写假期名称，并确保结束日期不早于开始日期。');
    }
  }
  final String name;
  final DateTime start, end;
  bool contains(DateTime value) {
    final day = _date(value);
    return !day.isBefore(start) && !day.isAfter(end);
  }

  String get dateLabel =>
      '${start.year}/${start.month}/${start.day} – ${end.year}/${end.month}/${end.day}';
  Map<String, Object> toJson() => {
    'name': name,
    'start': start.toIso8601String(),
    'end': end.toIso8601String(),
  };
  factory CourseHoliday.fromJson(Map<String, dynamic> json) => CourseHoliday(
    name: json['name'] as String,
    start: DateTime.parse(json['start'] as String),
    end: DateTime.parse(json['end'] as String),
  );
}

class CourseHolidayPreview {
  const CourseHolidayPreview(
    this.incoming,
    this.affected,
    this.excludedSources,
  );
  final List<CalendarEvent> incoming, affected;
  final Set<String> excludedSources;
  factory CourseHolidayPreview.apply({
    required List<CalendarEvent> events,
    required List<CourseHoliday> holidays,
    bool exclude = false,
  }) {
    final affected = events
        .where((e) => holidays.any((h) => h.contains(e.startLocal)))
        .toList();
    final sources = affected
        .map((e) => e.importSource)
        .whereType<String>()
        .toSet();
    return CourseHolidayPreview(
      exclude
          ? events.where((e) => !sources.contains(e.importSource)).toList()
          : events,
      affected,
      exclude ? sources : {},
    );
  }
}
