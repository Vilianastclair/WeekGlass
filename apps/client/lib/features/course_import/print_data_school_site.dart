import 'dart:convert';

import 'print_data_course_timetable.dart';
import 'whu_timetable.dart';

enum PrintDataTableShape { studentTableVms, studentTableVm, activities }

/// A known school route for one semester's personal print-data request.
class PrintDataSchoolSite {
  const PrintDataSchoolSite({
    required this.name,
    required this.origin,
    this.path = '/student/for-std/course-table',
    this.semesterSelector = 'select#allSemesters',
    this.numericTermLabel = false,
    this.tableShapes = const [PrintDataTableShape.studentTableVms],
    this.query = const {},
    this.readStartDate = false,
    this.readCourseClock = false,
    this.weeksStartSunday = false,
    this.firstMonday,
    this.clock,
  });

  static const asset = 'assets/school_portal/read_print_data.js';
  final String name;
  final String origin;
  final String path;
  final String semesterSelector;
  final bool numericTermLabel;
  final List<PrintDataTableShape> tableShapes;

  /// School-provided alternatives may add fixed parameters. Only the literal
  /// {semesterId} is substituted, using the current timetable selector.
  final Map<String, String> query;
  final bool readStartDate;
  final bool readCourseClock;
  final bool weeksStartSunday;
  final DateTime? Function(Object?, WhuTerm)? firstMonday;
  final List<ClassPeriod>? Function(WhuTerm)? clock;

  String get entry => '$origin$path';

  bool matchesSystem(Uri? uri) =>
      uri != null &&
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      !uri.authority.contains('@') &&
      uri.origin == origin;

  bool matchesPersonalPage(Uri? uri) =>
      matchesSystem(uri) && (uri!.path == path || uri.path == '$path/');

  String script(String assetText, WhuTerm term) {
    final settings = {
      'semesterSelector': semesterSelector,
      'numericTermLabel': numericTermLabel,
      'tableShapes': tableShapes.map((s) => s.name).toList(),
      'query': query,
      'readStartDate': readStartDate,
      'readCourseClock': readCourseClock,
    };
    return '(${assetText.trim()})(${jsonEncode(origin)},${jsonEncode(path)},'
        '${jsonEncode({'year': term.year, 'semester': term.semester})},'
        '${jsonEncode(settings)})';
  }

  WhuTimetable parse(Map data, WhuTerm term) => PrintDataCourseTimetable.parse(
    data['rows'],
    weeksStartSunday: weeksStartSunday,
    suggestedFirstMonday: firstMonday?.call(data['startDate'], term),
    suggestedClock: readCourseClock
        ? _readClock(data['courseUnits'], data['rows'])
        : clock?.call(term),
  );

  // Index and validate the whole schedule, rather than compacting missing
  // periods and accidentally shifting subsequent class times.
  static List<ClassPeriod>? _readClock(Object? units, Object? rows) {
    if (units is! List || units.isEmpty || units.length > 24) return null;
    final numbered = List<ClassPeriod?>.filled(units.length, null);
    for (final unit in units) {
      if (unit is! Map) return null;
      final index = _int(unit['indexNo']);
      if (index == null ||
          index < 1 ||
          index > numbered.length ||
          numbered[index - 1] != null) {
        return null;
      }
      final start = _minutes(unit['startTime']),
          end = _minutes(unit['endTime']);
      if (start == null || end == null || start >= end) return null;
      numbered[index - 1] = ClassPeriod(start, end);
    }
    final clock = <ClassPeriod>[];
    for (final period in numbered) {
      if (period == null ||
          (clock.isNotEmpty && period.start <= clock.last.end)) {
        return null;
      }
      clock.add(period);
    }
    if (rows is List) {
      for (final row in rows.whereType<Map>()) {
        final last = _int(row['endUnit']);
        if (last != null && last <= 24 && last > clock.length) return null;
      }
    }
    return List.unmodifiable(clock);
  }

  static int? _int(Object? value) => switch (value) {
    int n => n,
    String s when RegExp(r'^\d{1,4}$').hasMatch(s) => int.parse(s),
    _ => null,
  };

  static int? _minutes(Object? value) {
    final n = _int(value);
    if (n == null || n < 0 || n > 2359 || n % 100 > 59) return null;
    return (n ~/ 100) * 60 + n % 100;
  }
}
