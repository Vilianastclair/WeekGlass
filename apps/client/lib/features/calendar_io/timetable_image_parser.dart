import 'dart:convert';
import 'dart:math' as math;

import 'package:weekglass_domain/weekglass_domain.dart';

import '../course_import/whu_timetable.dart';
import 'calendar_codec.dart';

class TimetableOcrWord {
  const TimetableOcrWord(this.text, this.x, this.y, this.width, this.height);
  final String text;
  final double x, y, width, height;
  double get centerX => x + width / 2;
  double get centerY => y + height / 2;
  factory TimetableOcrWord.fromMap(Map value) => TimetableOcrWord(
    value['text'] as String,
    (value['x'] as num).toDouble(),
    (value['y'] as num).toDouble(),
    (value['width'] as num).toDouble(),
    (value['height'] as num).toDouble(),
  );
}

class TimetableOcrPage {
  const TimetableOcrPage({
    required this.text,
    required this.words,
    required this.language,
    this.width = 0,
    this.height = 0,
  });
  final String text, language;
  final List<TimetableOcrWord> words;
  final int width, height;
  factory TimetableOcrPage.fromMap(Map value) {
    final lines = value['lines'] as List? ?? [];
    return TimetableOcrPage(
      text: lines.map((line) => (line as Map)['text']).join('\n'),
      words: [
        for (final line in lines)
          for (final word in (line as Map)['words'] as List)
            TimetableOcrWord.fromMap(word as Map),
      ],
      language: value['language'] as String? ?? '',
      width: (value['width'] as num?)?.toInt() ?? 0,
      height: (value['height'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Fields recognized from a single timetable course.
/// Missing week/day/period information stays empty; dates never come from OCR.
class TimetableCourseDraft {
  const TimetableCourseDraft({
    required this.title,
    required this.weekday,
    required this.periodText,
    required this.weekText,
    this.room = '',
    this.teacher = '',
    this.sourceText = '',
    this.layoutSuggestion = false,
  });
  final String title, periodText, weekText, room, teacher, sourceText;
  final int? weekday;
  final bool layoutSuggestion;
}

class TimetableRecognition {
  const TimetableRecognition(
    this.courses,
    this.messages, {
    this.usedLayout = false,
  });
  final List<TimetableCourseDraft> courses;
  final List<String> messages;
  final bool usedLayout;
}

class TimetableImageParser {
  static const maxTextLength = 100000;
  static final _day = RegExp(r'(?:星期|周|礼拜)([一二三四五六日天1-7])');
  static final _period = RegExp(r'第?\d{1,2}(?:\s*[-—–－~～至、,，]\s*\d{1,2})*\s*节');
  static final _week = RegExp(
    r'第?\d{1,2}(?:\s*[-—–－~～至、,，]\s*\d{1,2})*\s*周(?:\s*[（(]?[单双]周?[）)]?)?',
  );
  static String _compact(String value) => value
      .replaceAll(RegExp(r'\s'), '')
      .replaceAllMapped(RegExp(r'(\d)一(?=\d)'), (match) => '${match[1]}-')
      .replaceAll(RegExp('[—–－~～至]'), '-')
      .replaceAll('（', '(')
      .replaceAll('）', ')');
  static int _weekday(String value) => switch (value) {
    '一' || '1' => 1,
    '二' || '2' => 2,
    '三' || '3' => 3,
    '四' || '4' => 4,
    '五' || '5' => 5,
    '六' || '6' => 6,
    _ => 7,
  };

  TimetableRecognition parseText(String text) {
    if (text.length > maxTextLength) {
      throw const FormatException('课表文字过长，请分批识别。');
    }
    text = text.replaceAll('\r', '').trim();
    if (text.isEmpty) {
      return const TimetableRecognition([], ['请先选择图片，或粘贴课表文字。']);
    }
    final paragraphs = text.split(RegExp(r'\n\s*\n'));
    final blocks = <String>[];
    for (final paragraph in paragraphs) {
      final lines = paragraph
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .toList();
      // One complete course per line is common in copied timetable lists.
      if (lines.length > 1 &&
          lines.every((line) => _day.hasMatch(_compact(line)))) {
        blocks.addAll(lines);
      } else {
        blocks.add(paragraph);
      }
    }
    if (blocks.length > 200) throw const FormatException('课程条目超过 200 条，请分批识别。');
    final courses = blocks
        .map((block) => _course(block))
        .where((c) => c.title.isNotEmpty || c.periodText.isNotEmpty)
        .toList();
    return TimetableRecognition(courses, [
      '文字按空行分隔课程；也支持每行一门：课程 | 周一 | 1-2节 | 1-16周 | 地点 | 教师。',
      if (courses.any(
        (c) => c.weekday == null || c.periodText.isEmpty || c.weekText.isEmpty,
      ))
        '有课程缺少星期、节次或周次，请在下方补齐后预览。',
    ]);
  }

  TimetableRecognition parseOcr(TimetableOcrPage page) {
    if (page.words.length > 20000) throw const FormatException('图片文字过多，请分开导入。');
    final rows = _rows(page.words);
    List<_DayAnchor> days = [];
    _WordRow? header;
    for (final row in rows) {
      final found = <_DayAnchor>[];
      final characters = <TimetableOcrWord>[];
      final text = StringBuffer();
      for (final word in row.words) {
        final compact = _compact(word.text);
        text.write(compact);
        characters.addAll(List.filled(compact.length, word));
      }
      for (final match in _day.allMatches(text.toString())) {
        final first = characters[match.start], last = characters[match.end - 1];
        found.add(
          _DayAnchor(_weekday(match[1]!), (first.x + last.x + last.width) / 2),
        );
      }
      if (found.map((e) => e.day).toSet().length >= 3 &&
          found.length > days.length) {
        days = found;
        header = row;
      }
    }
    if (days.length < 3 || header == null) {
      final parsed = parseText(page.text);
      return TimetableRecognition(parsed.courses, [
        '未找到完整的星期表头，已按文字整理。',
        ...parsed.messages,
      ]);
    }
    days.sort((a, b) => a.x.compareTo(b.x));
    // OCR often misses 一/二/三 next to table borders. Only interpolate a
    // regular, increasing weekday header and keep the suggestion conspicuous.
    var interpolated = false;
    if (page.width > 0 && days.length < 7) {
      final spacings = <double>[];
      for (var i = 1; i < days.length; i++) {
        if (days[i].day <= days[i - 1].day) {
          spacings.clear();
          break;
        }
        spacings.add(
          (days[i].x - days[i - 1].x) / (days[i].day - days[i - 1].day),
        );
      }
      if (spacings.isNotEmpty) {
        final spacing = spacings.reduce((a, b) => a + b) / spacings.length;
        if (spacing > 30 &&
            spacings.every(
              (value) => (value - spacing).abs() < spacing * .18,
            )) {
          final origin = days.first.x - (days.first.day - 1) * spacing;
          final inferred = [
            for (var day = 1; day <= 7; day++)
              if (origin + (day - 1) * spacing > spacing * .5 &&
                  origin + (day - 1) * spacing < page.width - spacing * .3)
                _DayAnchor(day, origin + (day - 1) * spacing),
          ];
          if (inferred.length > days.length) {
            days = inferred;
            interpolated = true;
          }
        }
      }
    }
    final firstGap = days[1].x - days[0].x;
    final leftEdge = days.first.x - firstGap / 2;
    final anchors = <_PeriodAnchor>[];
    for (final row in rows.where(
      (row) => row.y > header!.y + header.height * .6,
    )) {
      final label = _compact(
        _join(row.words.where((word) => word.centerX < leftEdge).toList()),
      );
      if (RegExp(r'^(?:第)?\d{1,2}(?:[-、,]\d{1,2})*(?:节)?$').hasMatch(label)) {
        try {
          anchors.add(_PeriodAnchor(row.y, parsePeriods(label)));
        } on FormatException {
          /* Not a period label. */
        }
      }
    }
    anchors.sort((a, b) => a.y.compareTo(b.y));
    final courses = <TimetableCourseDraft>[];
    for (var column = 0; column < days.length; column++) {
      final left = column == 0
          ? leftEdge
          : (days[column - 1].x + days[column].x) / 2;
      final right = column == days.length - 1
          ? days[column].x + (days[column].x - days[column - 1].x) / 2
          : (days[column].x + days[column + 1].x) / 2;
      final body = page.words
          .where(
            (word) =>
                word.centerX >= left &&
                word.centerX < right &&
                word.centerY > header!.y + header.height * .8,
          )
          .toList();
      if (anchors.isNotEmpty) {
        for (var row = 0; row < anchors.length; row++) {
          final top = row == 0
              ? header.y + header.height
              : (anchors[row - 1].y + anchors[row].y) / 2;
          final bottom = row == anchors.length - 1
              ? double.infinity
              : (anchors[row].y + anchors[row + 1].y) / 2;
          final content = _rows(
            body
                .where((word) => word.centerY >= top && word.centerY < bottom)
                .toList(),
          );
          if (content.isEmpty) continue;
          courses.add(
            _course(
              content.map((row) => _join(row.words)).join('\n'),
              day: days[column].day,
              periods: anchors[row].periods,
              layout: true,
            ),
          );
        }
      } else {
        final content = _rows(body);
        var group = <_WordRow>[];
        void flush() {
          if (group.isEmpty) return;
          courses.add(
            _course(
              group.map((row) => _join(row.words)).join('\n'),
              day: days[column].day,
              layout: true,
            ),
          );
          group = [];
        }

        for (final row in content) {
          if (group.isNotEmpty &&
              row.y - group.last.y >
                  math.max(row.height, group.last.height) * 2.3) {
            flush();
          }
          group.add(row);
        }
        flush();
      }
    }
    courses.removeWhere(
      (course) => course.title.isEmpty && course.periodText.isEmpty,
    );
    if (courses.length > 200) {
      throw const FormatException('课程条目超过 200 条，请分开导入。');
    }
    return TimetableRecognition(courses, [
      '已按星期列${anchors.isEmpty ? '' : '和节次行'}整理 ${courses.length} 门课程。',
      if (interpolated) '已按相邻星期列的间距补齐缺失的表头。',
      if (anchors.isEmpty) '未识别到节次行标，请补齐每门课程的节次。',
      '请设置学期起始日期、总周数和每节课的时刻。',
    ], usedLayout: true);
  }

  TimetableCourseDraft _course(
    String source, {
    int? day,
    List<int>? periods,
    bool layout = false,
  }) {
    final lines = source
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    final compact = _compact(source);
    final dayMatch = _day.firstMatch(compact);
    final periodMatch = _period.firstMatch(compact);
    final weekMatch = _week.firstMatch(compact);
    var periodText = periodMatch?.group(0) ?? periods?.join('、') ?? '';
    var weekday = dayMatch == null ? day : _weekday(dayMatch[1]!);
    var week = weekMatch?.group(0) ?? '';
    if (week.endsWith('单') || week.endsWith('双')) {
      week =
          '${week.substring(0, week.length - 1)}(${week.substring(week.length - 1)})';
    }
    String field(String pattern) =>
        RegExp(pattern).firstMatch(source)?.group(1)?.trim() ?? '';
    var room = field(r'(?:地点|教室|上课地点)\s*[:：]\s*([^\n|｜]+)');
    var teacher = field(r'(?:教师|老师|任课教师)\s*[:：]\s*([^\n|｜]+)');
    if (teacher.isEmpty) {
      for (final line in lines.skip(1)) {
        if (RegExp(r'^.{1,6}老师$').hasMatch(_compact(line))) {
          teacher = _compact(line);
          break;
        }
      }
    }
    final columns = source
        .split(RegExp('[|｜\t]'))
        .map((part) => part.trim())
        .toList();
    String title;
    if (columns.length >= 4) {
      title = columns.first;
      if (weekday == null) {
        final number = int.tryParse(columns[1]);
        if (number != null && number >= 1 && number <= 7) weekday = number;
      }
      if (periodText.isEmpty) {
        try {
          parsePeriods(columns[2]);
          periodText = columns[2];
        } on FormatException {
          /* Leave missing for review. */
        }
      }
      if (week.isEmpty) {
        try {
          parseTeachingWeeks(columns[3]);
          week = columns[3];
        } on FormatException {
          /* Leave missing for review. */
        }
      }
      if (columns.length > 4 && room.isEmpty) room = columns[4];
      if (columns.length > 5 && teacher.isEmpty) teacher = columns[5];
    } else {
      title = '';
      for (final line in lines) {
        if (RegExp(r'^(?:地点|教室|教师|老师|任课教师)\s*[:：]').hasMatch(line)) continue;
        final normalized = _compact(line);
        var candidate = normalized
            .replaceAll(_day, '')
            .replaceAll(_period, '')
            .replaceAll(_week, '')
            .replaceAll(RegExp(r'^[\s:：、,，/|｜]+|[\s:：、,，/|｜]+$'), '');
        if (candidate.isNotEmpty) {
          // Keep natural spaces in titles when the line itself has no schedule.
          title = normalized == candidate ? line : candidate;
          break;
        }
      }
      if (room.isEmpty && lines.length > 1) {
        for (final line in lines.skip(1)) {
          if (RegExp(r'(?:楼|教室|教学|教[一二三四五六七八九十]|[A-Za-z]\d{2,})')
                  .hasMatch(line) &&
              !_week.hasMatch(_compact(line)) &&
              !_period.hasMatch(_compact(line))) {
            room = line.replaceAllMapped(
              RegExp(r'(\d)\s+(?=\d)'),
              (match) => match[1]!,
            );
            break;
          }
        }
      }
    }
    return TimetableCourseDraft(
      title: title,
      weekday: weekday,
      periodText: periodText,
      weekText: week,
      room: room,
      teacher: teacher,
      sourceText: source,
      layoutSuggestion: layout,
    );
  }

  static String _join(List<TimetableOcrWord> words) {
    final sorted = [...words]..sort((a, b) => a.x.compareTo(b.x));
    final out = StringBuffer();
    String previous = '';
    for (final word in sorted) {
      if (RegExp(r'[A-Za-z0-9]$').hasMatch(previous) &&
          RegExp(r'^[A-Za-z0-9]').hasMatch(word.text)) {
        out.write(' ');
      }
      out.write(word.text);
      previous = word.text;
    }
    return out.toString();
  }

  static List<_WordRow> _rows(List<TimetableOcrWord> words) {
    final sorted = [...words]..sort((a, b) => a.centerY.compareTo(b.centerY));
    final rows = <_WordRow>[];
    for (final word in sorted) {
      if (word.text.trim().isEmpty) continue;
      if (rows.isEmpty ||
          (word.centerY - rows.last.y).abs() >
              math.max(word.height, rows.last.height) * .55) {
        rows.add(_WordRow([word]));
      } else {
        rows.last.words.add(word);
      }
    }
    for (final row in rows) {
      row.words.sort((a, b) => a.x.compareTo(b.x));
    }
    return rows;
  }
}

class _DayAnchor {
  const _DayAnchor(this.day, this.x);
  final int day;
  final double x;
}

class _PeriodAnchor {
  const _PeriodAnchor(this.y, this.periods);
  final double y;
  final List<int> periods;
}

class _WordRow {
  _WordRow(this.words);
  final List<TimetableOcrWord> words;
  double get y =>
      words.map((e) => e.centerY).reduce((a, b) => a + b) / words.length;
  double get height => words.map((e) => e.height).reduce(math.max);
}

/// Shared by the review UI and regression tests. No persistence occurs here.
class TimetableImportPlan {
  TimetableImportPlan({
    required this.courses,
    required this.firstMonday,
    required this.totalWeeks,
    required this.clock,
    required this.timeZoneId,
  });
  final List<TimetableCourseDraft> courses;
  final DateTime firstMonday;
  final int totalWeeks;
  final List<ClassPeriod> clock;
  final String timeZoneId;

  static List<ClassPeriod> parseClock(String text) =>
      ClassPeriod.parseClock(text);

  CalendarImportResult preview({Iterable<CalendarEvent> existing = const []}) {
    if (firstMonday.weekday != DateTime.monday) {
      throw const FormatException('第一教学周日期必须为周一。');
    }
    if (totalWeeks < 1 || totalWeeks > 53) {
      throw const FormatException('学期周数须为 1–53 周。');
    }
    if (courses.isEmpty) throw const FormatException('请至少保留一门课程。');
    if (courses.length > 200) throw const FormatException('一次最多导入 200 个课程块。');
    if (clock.isEmpty || clock.length > 24) {
      throw const FormatException('请设置每节课的时刻。');
    }
    for (var i = 0; i < clock.length; i++) {
      if (clock[i].start < 0 ||
          clock[i].end > 1440 ||
          clock[i].end <= clock[i].start ||
          (i > 0 && clock[i].start < clock[i - 1].end)) {
        throw const FormatException('节次时刻必须连续编号、顺序排列且互不重叠。');
      }
    }
    final rows = <Map<String, dynamic>>[];
    for (var index = 0; index < courses.length; index++) {
      final course = courses[index];
      final label = course.title.trim().isEmpty
          ? '第 ${index + 1} 门课程'
          : course.title;
      if (course.title.trim().isEmpty) throw FormatException('$label：请填写课程名称。');
      if (course.weekday == null ||
          course.weekday! < 1 ||
          course.weekday! > 7) {
        throw FormatException('$label：请选择星期。');
      }
      if (course.periodText.trim().isEmpty) {
        throw FormatException('$label：请填写节次。');
      }
      if (course.weekText.trim().isEmpty) {
        throw FormatException('$label：请填写重复周次，例如 1-16周；不会自动补满整个学期。');
      }
      List<int> periods, weeks;
      try {
        periods = parsePeriods(course.periodText);
        weeks = parseTeachingWeeks(course.weekText);
      } on FormatException catch (error) {
        throw FormatException('$label：${error.message}');
      }
      if (weeks.last > totalWeeks) {
        throw FormatException('$label：课程周次超出设置的 $totalWeeks 周学期。');
      }
      if (periods.last > clock.length) {
        throw FormatException('$label：请补充第 ${periods.last} 节的时刻。');
      }
      final runs = <List<int>>[];
      for (final period in periods) {
        if (runs.isEmpty ||
            period != runs.last.last + 1 ||
            clock[period - 1].start - clock[runs.last.last - 1].end > 30) {
          runs.add([period]);
        } else {
          runs.last.add(period);
        }
      }
      for (final week in weeks) {
        final day = DateTime(
          firstMonday.year,
          firstMonday.month,
          firstMonday.day + (week - 1) * 7 + course.weekday! - 1,
        );
        for (final run in runs) {
          final start = clock[run.first - 1].start,
              end = clock[run.last - 1].end;
          String localTime(int minutes) => DateTime(
            day.year,
            day.month,
            day.day,
            minutes ~/ 60,
            minutes % 60,
          ).toIso8601String();
          rows.add({
            'title': course.title.trim(),
            'seriesId': jsonEncode([
              'timetable-image-v1',
              firstMonday.toIso8601String(),
              course.title.trim(),
              course.weekday,
              run,
              timeZoneId,
            ]),
            'start': localTime(start),
            'end': localTime(end),
            'timeZoneId': timeZoneId,
            'notes': [
              if (course.room.trim().isNotEmpty) '地点：${course.room.trim()}',
              if (course.teacher.trim().isNotEmpty)
                '教师：${course.teacher.trim()}',
            ].join('\n'),
          });
          if (rows.length > CalendarCodec.maxEvents) {
            throw const FormatException('展开后超过 5000 项日程，请分批导入。');
          }
        }
      }
    }
    final result = CalendarCodec().decode(
      text: jsonEncode(rows),
      format: CalendarFileFormat.json,
      timeZoneId: timeZoneId,
      rangeStart: firstMonday,
      rangeEnd: DateTime(
        firstMonday.year,
        firstMonday.month,
        firstMonday.day + totalWeeks * 7,
      ),
      existing: existing,
    );
    if (result.skippedCount > 0) {
      throw FormatException(
        '有 ${result.skippedCount} 项日程无法排入，请核对时间：${result.messages.join('；')}',
      );
    }
    // Re-reading a screenshot may change optional room/teacher OCR text. Keep
    // the same named class at the same time as one calendar occurrence.
    String scheduleKey(CalendarEvent event) => jsonEncode([
      event.title.trim(),
      event.startUtc?.toIso8601String(),
      event.endUtc?.toIso8601String(),
    ]);
    final known = existing.map(scheduleKey).toSet();
    final unique = <CalendarEvent>[];
    var duplicates = result.duplicateCount;
    for (final event in result.events) {
      if (known.add(scheduleKey(event))) {
        unique.add(event);
      } else {
        duplicates++;
      }
    }
    return CalendarImportResult(
      events: unique,
      duplicateCount: duplicates,
      skippedCount: 0,
      messages: result.messages,
    );
  }
}
