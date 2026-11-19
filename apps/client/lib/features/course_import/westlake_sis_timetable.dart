import 'dart:convert';

import 'package:html/dom.dart';

import 'whu_timetable.dart';

/// PeopleSoft's "按课程" download is an HTML table named ps.xls.
abstract final class WestlakeSisTimetable {
  static const _headers = [
    '班级',
    '课程代码',
    '课程名称',
    '开始/结束日期',
    '星期和时间',
    '教室',
    '任课教师',
    '状态',
  ];
  static final _range = RegExp(
    r'^(\d{4})/(\d{1,2})/(\d{1,2})\s*-\s*(\d{4})/(\d{1,2})/(\d{1,2})$',
  );
  static final _time = RegExp(
    r'^星期([一二三四五六日天])\s+(\d{1,2}):(\d{2})\s*到\s*(\d{1,2}):(\d{2})$',
  );

  static WhuTimetable parse(Document document) {
    final matches = <(Element, Map<String, int>)>[];
    for (final table in document.querySelectorAll('table')) {
      final row = table.querySelector('tr');
      if (row == null) continue;
      final cells = row.children.map((e) => e.text.trim()).toList();
      if (_headers.every((s) => cells.where((x) => x == s).length == 1)) {
        matches.add((table, {for (final s in _headers) s: cells.indexOf(s)}));
      }
    }
    if (matches.length != 1) {
      throw const FormatException(
        '请选择从西湖大学 SIS「查看我的课表」的「按课程」页下载的原始 ps.xls 文件。',
      );
    }
    final (table, index) = matches.single;
    final rows = table
        .querySelectorAll('tr')
        .where((r) => r.parent == table || r.parent?.parent == table)
        .skip(1)
        .toList();
    if (rows.length > 200) throw const FormatException('课程过多，请只下载本人的一个学期。');
    final warnings = <String>{};
    final slots = <_DatedSlot>[];
    for (final row in rows) {
      final cells = row.children;
      if (index.values.any((i) => i >= cells.length)) {
        throw const FormatException('SIS 表格行不完整，请重新下载原始文件。');
      }
      Element cell(String label) => cells[index[label]!];
      final title = cell('课程名称').text.trim();
      final status = cell('状态').text.trim();
      if (status != '已注册') {
        warnings.add(
          '${title.isEmpty ? "一门课程" : title}：状态为「${status.isEmpty ? "未标明" : status}」，未安排。',
        );
        continue;
      }
      final code = cell('课程代码').text.trim(), section = cell('班级').text.trim();
      if (title.isEmpty || code.isEmpty || section.isEmpty) {
        throw const FormatException('已注册课程缺少课名、代码或班级，请核对文件。');
      }
      final dates = _groups(cell('开始/结束日期')), times = _groups(cell('星期和时间'));
      final rooms = _groups(cell('教室')), teachers = _groups(cell('任课教师'));
      if (dates.isEmpty ||
          times.isEmpty ||
          [...dates, ...times].every((s) => s == '待定')) {
        warnings.add('$title：SIS 尚未提供完整的日期和钟点，未安排。');
        continue;
      }
      if (dates.length != times.length ||
          [
            rooms,
            teachers,
          ].any((v) => v.isNotEmpty && v.length != dates.length)) {
        throw FormatException('$title：同一门课的日期、钟点、教室或教师行不能一一对应，请核对原始文件。');
      }
      for (var i = 0; i < dates.length; i++) {
        final date = _range.firstMatch(dates[i]),
            time = _time.firstMatch(times[i]);
        if (date == null || time == null) {
          throw FormatException(
            '$title：无法识别「${dates[i]} / ${times[i]}」，请核对 SIS 的日期和时间。',
          );
        }
        DateTime getDate(int at) {
          final y = int.parse(date[at]!),
              m = int.parse(date[at + 1]!),
              d = int.parse(date[at + 2]!);
          final result = DateTime.utc(y, m, d);
          if (y < 2000 || y > 2100 || result.month != m || result.day != d) {
            throw FormatException('$title：日期无效。');
          }
          return result;
        }

        int minute(int at) {
          final h = int.parse(time[at]!), m = int.parse(time[at + 1]!);
          if (h > 23 || m > 59) throw FormatException('$title：钟点无效。');
          return h * 60 + m;
        }

        final start = getDate(1),
            end = getDate(4),
            from = minute(2),
            to = minute(4);
        final day = '一二三四五六日天'.indexOf(time[1]!) + 1,
            weekday = day == 8 ? 7 : day;
        final first = start.add(
          Duration(days: (weekday - start.weekday + 7) % 7),
        );
        if (first.isAfter(end) ||
            end.difference(start).inDays > 366 ||
            to <= from) {
          throw FormatException('$title：请核对日期范围、星期及结束钟点。');
        }
        slots.add(
          _DatedSlot(
            id: jsonEncode([code, section]),
            title: title,
            first: first,
            end: end,
            start: from,
            stop: to,
            room: rooms.isEmpty ? '' : rooms[i],
            teacher: teachers.isEmpty ? '' : teachers[i],
            range: dates[i],
          ),
        );
      }
    }
    if (slots.isEmpty) {
      throw FormatException(
        '未找到有明确日期与钟点的已注册课程。${warnings.isEmpty ? "" : warnings.first}',
      );
    }
    final earliest = slots
        .map((m) => m.first)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final monday = earliest.subtract(Duration(days: earliest.weekday - 1));
    final groups = <(String, DateTime, DateTime, int, int), List<_DatedSlot>>{};
    for (final s in slots) {
      if (s.end.difference(monday).inDays >= 53 * 7) {
        throw const FormatException('日期跨度超过一个学年，请下载单学期课表。');
      }
      (groups[(s.id, s.first, s.end, s.start, s.stop)] ??= []).add(s);
    }
    return WhuTimetable(
      account: '',
      suggestedFirstMonday: DateTime(monday.year, monday.month, monday.day),
      warnings: warnings.toList(),
      meetings: groups.values.map((g) {
        final s = g.first;
        return WhuCourseMeeting(
          courseKey: whuHash(s.id).substring(0, 24),
          title: s.title,
          weekday: s.first.weekday,
          periods: const [],
          weeks: [
            for (
              var d = s.first;
              !d.isAfter(s.end);
              d = d.add(const Duration(days: 7))
            )
              1 + d.difference(monday).inDays ~/ 7,
          ],
          weekText: s.range,
          room: g
              .map((x) => x.room)
              .where((x) => x.isNotEmpty)
              .toSet()
              .join('、'),
          teacher: g
              .map((x) => x.teacher)
              .where((x) => x.isNotEmpty)
              .toSet()
              .join('、'),
          fixedTime: ClassPeriod(s.start, s.stop),
        );
      }).toList(),
    );
  }

  // SIS separates meeting patterns with two BRs; a single BR can separate
  // two instructors in the SAME pattern. Keep internal blanks aligned.
  static List<String> _groups(Element cell) {
    final buf = StringBuffer();
    void walk(Node node) {
      if (node is Text) {
        buf.write(node.data.replaceAll(RegExp(r'\s+'), ' '));
      } else if (node is Element && node.localName == 'br') {
        buf.write('\n');
      } else {
        for (final child in node.nodes) {
          walk(child);
        }
      }
    }

    walk(cell);
    final groups = buf
        .toString()
        .split(RegExp(r'\n[^\S\n]*\n'))
        .map((s) => s.trim().replaceAll(RegExp(r'[,，]?\s*\n\s*'), '、'))
        .toList();
    while (groups.isNotEmpty && groups.last.isEmpty) {
      groups.removeLast();
    }
    return groups;
  }
}

class _DatedSlot {
  const _DatedSlot({
    required this.id,
    required this.title,
    required this.first,
    required this.end,
    required this.start,
    required this.stop,
    required this.room,
    required this.teacher,
    required this.range,
  });
  final String id, title, room, teacher, range;
  final DateTime first, end;
  final int start, stop;
}
