import 'dart:convert';

import 'whu_timetable.dart';

/// Maps the activities from one already selected personal print-data table.
abstract final class PrintDataCourseTimetable {
  static WhuTimetable parse(
    Object? rows, {
    bool weeksStartSunday = false,
    List<ClassPeriod>? suggestedClock,
    DateTime? suggestedFirstMonday,
  }) {
    if (rows is! List || rows.length > 1000) {
      throw const FormatException('学校教务没有返回可识别的本人课表。');
    }
    final warnings = <String>[];
    final meetings = <WhuCourseMeeting>[];
    final seen = <String>{};
    for (final entry in rows) {
      if (entry is! Map) {
        warnings.add('有一条课程格式无法识别。');
        continue;
      }
      final title = _text(entry['courseName']);
      try {
        if (title.isEmpty) throw const FormatException('课程名称缺失');
        final day = _int(entry['weekday']);
        if (day == null || day < 1 || day > 7) {
          throw const FormatException('星期无法识别');
        }
        final start = _int(entry['startUnit']), end = _int(entry['endUnit']);
        if (start == null ||
            end == null ||
            start < 1 ||
            end < start ||
            end > 24) {
          throw const FormatException('没有明确的起止节次');
        }
        final rawWeeks = entry['weekIndexes'];
        if (rawWeeks is! List || rawWeeks.isEmpty || rawWeeks.length > 54) {
          throw const FormatException('没有明确的教学周');
        }
        final weekSet = <int>{};
        for (final raw in rawWeeks) {
          final week = _int(raw);
          if (week == null || week < 1 || week > 53) {
            throw const FormatException('教学周无法识别');
          }
          // When the school starts teaching weeks on Sunday, rebase to Monday.
          // A Sunday in JWGL's week 1 occurs before the first Monday. Week
          // zero represents that actual Sunday in the existing date expander.
          weekSet.add(
            weeksStartSunday && day == DateTime.sunday ? week - 1 : week,
          );
        }
        final weeks = weekSet.toList()..sort();
        final weekText = [
          if (weeks.first == 0) '第一教学周前的周日',
          if (weeks.last > 0) '${weeks.where((w) => w > 0).join('、')}周',
        ].join('，');
        final room = _text(entry['room']);
        final teacher = switch (entry['teachers']) {
          final List values =>
            values.map(_text).where((v) => v.isNotEmpty).toSet().join('、'),
          _ => '',
        };
        final lessonId = entry['lessonId'];
        final code = _text(entry['lessonCode']);
        final key = whuHash(
          jsonEncode(
            _int(lessonId) != null
                ? [lessonId.toString()]
                : code.isNotEmpty
                ? [code]
                : [title, teacher],
          ),
        ).substring(0, 24);
        if (!seen.add(
          jsonEncode([key, day, start, end, weeks, room, teacher]),
        )) {
          continue;
        }
        meetings.add(
          WhuCourseMeeting(
            courseKey: key,
            title: title,
            weekday: day,
            periods: List.generate(end - start + 1, (i) => start + i),
            weeks: weeks,
            weekText: weekText,
            room: room,
            teacher: teacher,
          ),
        );
      } on FormatException catch (e) {
        warnings.add('${title.isEmpty ? '未命名课程' : title}：${e.message}，未安排。');
      }
    }
    if (meetings.isEmpty) {
      throw FormatException(
        warnings.isEmpty ? '学校教务未返回所选学期的课程。' : '没有可安排的课程。${warnings.first}',
      );
    }
    return WhuTimetable(
      meetings: meetings,
      warnings: warnings,
      account: '',
      suggestedFirstMonday: suggestedFirstMonday,
      suggestedClock: suggestedClock,
    );
  }

  static int? _int(Object? value) => switch (value) {
    int n => n,
    String s when RegExp(r'^\d{1,18}$').hasMatch(s) => int.tryParse(s),
    _ => null,
  };
  static String _text(Object? value) =>
      value is String ? schoolText(value) : '';
}
