import 'print_data_school_site.dart';
import 'whu_timetable.dart';

/// Fudan's undergraduate teaching management system (not graduate selection).
abstract final class FudanPortalTimetable {
  static const name = '复旦大学（本科）';
  static const origin = 'https://fdjwgl.fudan.edu.cn';
  static const path = '/student/for-std/course-table';
  static const entry = '$origin$path';
  static const site = PrintDataSchoolSite(
    name: name,
    origin: origin,
    path: path,
    readStartDate: true,
    weeksStartSunday: true,
    firstMonday: _firstMonday,
    clock: _clock,
  );

  static DateTime? _firstMonday(Object? value, WhuTerm term) {
    if (value is! String) return null;
    final match = RegExp(r'^(20\d{2})-(\d{2})-(\d{2})(?:$|[ T])')
        .firstMatch(value);
    if (match == null) return null;
    final y = int.parse(match[1]!),
        m = int.parse(match[2]!),
        d = int.parse(match[3]!);
    final date = DateTime(y, m, d);
    if ((y != term.year && y != term.year + 1) ||
        date.month != m ||
        date.day != d ||
        date.weekday != DateTime.sunday) {
      return null;
    }
    return DateTime(y, m, d + 1);
  }

  static List<ClassPeriod>? _clock(WhuTerm term) => switch (term.key) {
    '2025-12' || '2026-3' => _official2026Clock,
    _ => null,
  };

  // Published by Fudan for spring and autumn 2026. New terms or additional
  // periods require confirmation from the school's current timetable.
  static const _official2026Clock = [
    ClassPeriod(480, 525),
    ClassPeriod(535, 580),
    ClassPeriod(595, 640),
    ClassPeriod(650, 695),
    ClassPeriod(705, 750),
    ClassPeriod(810, 855),
    ClassPeriod(865, 910),
    ClassPeriod(925, 970),
    ClassPeriod(980, 1025),
    ClassPeriod(1035, 1080),
    ClassPeriod(1110, 1155),
    ClassPeriod(1165, 1210),
    ClassPeriod(1220, 1265),
    ClassPeriod(1275, 1320),
  ];
}
