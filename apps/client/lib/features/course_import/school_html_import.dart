// Dart ports of WakeUp's historical CourseAdapter HTML parsers.
// Copyright (c) 2020 YZune. HUST adapter by Xeu (ThankRain); SYSU adapter by Qjbtiger.
// Source: https://github.com/sasaju/CourseAdapter/tree/02144ad1d393bfc39a8cf87368cffa50084eb17b
// MIT license: assets/licenses/CourseAdapter.txt

import 'dart:convert';
import 'dart:typed_data';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import 'school_html_format.dart';
import 'westlake_sis_timetable.dart';
import 'whu_timetable.dart';

/// The file is parsed as data. Scripts, frames and linked resources are never
/// loaded, and no account information is read from the page.
class SchoolHtmlImport {
  static const maxBytes = 4 * 1024 * 1024;
  static const fileAccountKey = 'local-html';

  static WhuTimetable read(({SchoolHtmlFormat format, Uint8List bytes}) input) {
    if (input.bytes.length > maxBytes) {
      throw const FormatException('课表文件超过 4 MB，请另存为仅包含课表的 HTML 文件。');
    }
    final String source;
    try {
      source = utf8.decode(input.bytes);
    } on FormatException {
      throw const FormatException('无法读取网页编码，请将课表 HTML 另存为 UTF-8 后再试。');
    }
    final document = html.parse(source);
    for (final element in document.querySelectorAll(
      'script, style, template',
    )) {
      element.remove();
    }
    final result = _ImportedRows();
    switch (input.format) {
      case SchoolHtmlFormat.westlake:
        return WestlakeSisTimetable.parse(document);
      case SchoolHtmlFormat.peking:
        _readPeking(document, result);
      case SchoolHtmlFormat.hust:
        _readHust(document, result);
      case SchoolHtmlFormat.sysu:
        _readSysu(document, result);
    }
    if (result.meetings.isEmpty && result.warnings.isEmpty) {
      throw const FormatException('没有找到可导入的课程。请确认所选格式，并另存已显示课程的个人课表页面。');
    }
    return WhuTimetable(
      meetings: result.meetings,
      warnings: result.warnings,
      account: '',
    );
  }
}

// The historical PekingParser reads the selection list, not a weekly grid.
void _readPeking(Document document, _ImportedRows result) {
  final table = document.querySelector('table.datagrid');
  if (table == null) {
    throw const FormatException('未找到北京大学选课网的课表列表，请检查所选文件与格式。');
  }
  for (final row in _tableRows(table)) {
    final cells = row.children.where((cell) => cell.localName == 'td').toList();
    if (cells.length < 11 || _text(cells[8]).contains('未')) continue;
    final title = _text(cells[0]), teacher = _text(cells[4]);
    final times = _lines(cells[7]).toList();
    if (times.isEmpty) result.warn(title, '没有给出上课安排');
    for (final time in times) {
      result.tryRow(title, () {
        final weekday = _weekday.firstMatch(time);
        if (weekday == null) throw const FormatException('没有明确的上课星期');
        final afterDay = time.substring(weekday.end);
        final period = _period.firstMatch(afterDay);
        if (period == null) throw const FormatException('没有明确的上课节次');
        final beforePeriod = afterDay.substring(0, period.start).trim();
        var room = afterDay.substring(period.end).trim();
        final prefix = _parityOnly.firstMatch(beforePeriod);
        final suffix = _paritySuffix.firstMatch(room);
        if (beforePeriod.isNotEmpty && prefix == null) {
          throw const FormatException('节次前的单双周标记无法识别');
        }
        final parity = prefix?[1] ?? suffix?[1] ?? suffix?[2];
        if (suffix != null) room = room.substring(suffix.end);
        if (prefix != null &&
            suffix != null &&
            prefix[1] != (suffix[1] ?? suffix[2])) {
          throw const FormatException('单双周标记互相矛盾');
        }
        result.add(
          title: title,
          weekday: _day(weekday[1]!),
          periods: _periods(period[1]!),
          weekText: _weeks(time.substring(0, weekday.start), parity: parity),
          room: _plainRoom(room),
          teacher: teacher,
        );
      });
    }
  }
}

// HUSTParser reads the micro-campus course cards and their weekly rows.
void _readHust(Document document, _ImportedRows result) {
  final list = document.getElementById('ktlist');
  if (list == null) {
    throw const FormatException('未找到华中科技大学微校园的课表列表，请检查所选文件与格式。');
  }
  for (final card in list.children) {
    final titleElement = card.querySelector('strong');
    final slots = card.querySelectorAll('.demo-grid');
    if (titleElement == null && slots.isEmpty) continue;
    final title = titleElement == null ? '' : _text(titleElement);
    final details = card.querySelectorAll('p').map(_text).toList();
    final teacher =
        details
            .where((value) => RegExp(r'^(?:教师|老师)\s*[:：]').hasMatch(value))
            .map(
              (value) =>
                  value.replaceFirst(RegExp(r'^(?:教师|老师)\s*[:：]\s*'), ''),
            )
            .firstOrNull ??
        '';
    final note = details
        .where((value) => RegExp(r'^(?:人数|开课对象)\s*[:：]').hasMatch(value))
        .join('\n');
    var hadSlot = false;
    for (final slot in slots) {
      final fields = slot.children.map(_text).toList();
      if (fields.isNotEmpty && fields[0].contains('周次')) continue;
      hadSlot = true;
      result.tryRow(title, () {
        if (fields.length != 4) throw const FormatException('上课安排字段不完整');
        final weekday = _weekday.firstMatch(fields[1]);
        if (weekday == null) throw const FormatException('上课星期待定或无法识别');
        result.add(
          title: title,
          weekday: _day(weekday[1]!),
          periods: _periods(fields[2]),
          weekText: _weeks(fields[0]),
          room: _plainRoom(fields[3]),
          teacher: teacher,
          note: note,
        );
      });
    }
    if (!hadSlot) result.warn(title, '没有给出上课安排');
  }
}

// SYSUParser uses seven weekday header spans and a separate body table. The
// legacy grid starts on Sunday. Explicit empty cells and ordinary row spans
// are both checked before position is turned into a date.
void _readSysu(Document document, _ImportedRows result) {
  final tables = document.querySelectorAll(
    'table.com-table.class-schedule-table2',
  );
  if (tables.length < 2) {
    throw const FormatException('未找到中山大学学生课表的双表格，请检查所选文件与格式。');
  }
  const invalidGrid = FormatException('中山大学课表的行列不匹配，无法可靠确定星期和节次。');
  final header = _tableRows(tables[0]).firstOrNull;
  final headers = header?.children
      .where((cell) => cell.localName == 'th' && !cell.classes.contains('th2'))
      .toList();
  if (headers == null || headers.length != 7) throw invalidGrid;
  final columns = <int>[];
  final days = <int>{};
  for (var i = 0; i < headers.length; i++) {
    final cell = headers[i];
    final match = _weekday.firstMatch(_text(cell));
    final day = match == null ? (i == 0 ? 7 : i) : _day(match[1]!);
    if (!days.add(day)) throw invalidGrid;
    columns.addAll(List.filled(_span(cell, 'colspan', 24, invalidGrid), day));
  }
  final rows = _tableRows(tables[1])
      .where((row) => row.children.any((cell) => cell.localName == 'td'))
      .toList();
  if (rows.length > 24) throw invalidGrid;
  final occupiedUntil = List<int>.filled(columns.length, 0);
  for (var index = 0; index < rows.length; index++) {
    final spans = [
      for (final cell in rows[index].children)
        if (cell.localName == 'td' && !cell.classes.contains('td2-1'))
          (cell, _span(cell, 'colspan', columns.length, invalidGrid)),
    ];
    final explicitWidth = spans.fold<int>(0, (width, span) => width + span.$2);
    final skipSpanned = explicitWidth != columns.length;
    if (skipSpanned &&
        explicitWidth + occupiedUntil.where((until) => until > index).length !=
            columns.length) {
      throw invalidGrid;
    }
    var cursor = 0;
    for (final (cell, width) in spans) {
      if (skipSpanned) {
        while (cursor < columns.length && occupiedUntil[cursor] > index) {
          cursor++;
        }
      }
      final first = cursor;
      cursor += width;
      if (cursor > columns.length ||
          (skipSpanned &&
              occupiedUntil
                  .sublist(first, cursor)
                  .any((until) => until > index))) {
        throw invalidGrid;
      }
      if (cell.classes.contains('11111') || _text(cell).isEmpty) continue;
      if (columns[first] != columns[cursor - 1]) throw invalidGrid;
      final height = _span(cell, 'rowspan', 24 - index, invalidGrid);
      for (var col = first; col < cursor; col++) {
        if (index + height > occupiedUntil[col]) {
          occupiedUntil[col] = index + height;
        }
      }
      final fields = cell.querySelectorAll('span').map(_text).toList();
      final rawTitle = fields.elementAtOrNull(1) ?? '';
      final course = RegExp(r'^\s*\(([^()]+)\)\s*(.+)$').firstMatch(rawTitle);
      final title = course?[2]?.trim() ?? rawTitle;
      result.tryRow(title, () {
        if (fields.length < 4 || course == null) {
          throw const FormatException('课表单元格字段不完整');
        }
        result.add(
          title: title,
          weekday: columns[first],
          periods: List.generate(height, (offset) => index + 1 + offset),
          weekText: _weeks(fields[0].replaceAll('/', '').trim()),
          room: _plainRoom(fields[3]),
          teacher: fields[2],
          courseId: course[1]!,
        );
      });
    }
  }
}

Iterable<Element> _tableRows(Element table) sync* {
  for (final element in table.children) {
    if (element.localName == 'tr') {
      yield element;
    } else if (const {'thead', 'tbody', 'tfoot'}.contains(element.localName)) {
      yield* element.children.where((row) => row.localName == 'tr');
    }
  }
}

int _span(Element cell, String key, int limit, FormatException error) {
  final value = int.tryParse(cell.attributes[key] ?? '1');
  if (value == null || value < 1 || value > limit) throw error;
  return value;
}

String _clean(String value) => value.replaceAll(RegExp(r'\s+'), ' ').trim();
String _text(Element value) => _clean(value.text);

String _plainRoom(String value) {
  var trimmed = value.replaceAll(RegExp(r'^[\s/、，,]+|[\s/、，,]+$'), '');
  if ((trimmed.startsWith('(') && trimmed.endsWith(')')) ||
      (trimmed.startsWith('（') && trimmed.endsWith('）'))) {
    trimmed = trimmed.substring(1, trimmed.length - 1).trim();
  }
  return trimmed == '-' ? '' : trimmed;
}

Iterable<String> _lines(Element value) {
  final buffer = StringBuffer();
  void visit(Node node) {
    if (node is Text) {
      buffer.write(node.data);
    } else if (node is Element && node.localName == 'br') {
      buffer.writeln();
    } else {
      for (final child in node.nodes) {
        visit(child);
      }
    }
  }

  visit(value);
  return buffer
      .toString()
      .split('\n')
      .map(_clean)
      .where((line) => line.isNotEmpty);
}

final _weekday = RegExp(r'(?:星期|周)\s*([一二三四五六日天1-7])');
final _period = RegExp(r'第?\s*(\d{1,2}(?:\s*[-~～－–—至、,，]\s*\d{1,2})*)\s*节');
final _parityOnly = RegExp(r'^[（(]?([单双])周?[）)]?$');
final _paritySuffix = RegExp(r'^(?:[（(]([单双])周?[）)]|([单双])周)');

int _day(String value) =>
    int.tryParse(value) ?? (value == '天' ? 7 : '一二三四五六日'.indexOf(value) + 1);

List<int> _periods(String raw) =>
    parsePeriods(raw.replaceAll(RegExp(r'[~～–至]'), '-'));

String _weeks(String raw, {String? parity}) {
  final text = raw
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll(RegExp(r'[~～–—－至]'), '-')
      .replaceAll(RegExp(r'[，、；;]'), ',')
      .replaceAll('（', '(')
      .replaceAll('）', ')');
  final parts = <String>[];
  for (final part in text.split(',')) {
    if (part.isEmpty) throw const FormatException('没有明确的上课周次');
    final explicit = RegExp(r'[()]?([单双])周?[()]?$').firstMatch(part);
    if (explicit != null && parity != null && explicit[1] != parity) {
      throw const FormatException('单双周标记互相矛盾');
    }
    final activeParity = explicit?[1] ?? parity;
    var range = part.replaceFirst(RegExp(r'^每周|每周$'), '');
    if (explicit != null) range = part.substring(0, explicit.start);
    if (!range.endsWith('周')) range += '周';
    parts.add(activeParity == null ? range : '$range($activeParity)');
  }
  return parts.join('、');
}

class _ImportedRows {
  final meetings = <WhuCourseMeeting>[];
  final warnings = <String>[];
  final _seen = <String>{};

  void warn(String title, String message) {
    if (warnings.length < 100) {
      warnings.add('${title.isEmpty ? '未命名课程' : title}：$message');
    } else if (warnings.length == 100) {
      warnings.add('另有未识别的课程，请核对网页原件。');
    }
  }

  void tryRow(String title, void Function() parse) {
    if (meetings.length >= 1000) {
      throw const FormatException('课表超过 1000 条课程规则，请核对文件。');
    }
    try {
      parse();
    } on FormatException catch (error) {
      warn(title, error.message);
    }
  }

  void add({
    required String title,
    required int weekday,
    required List<int> periods,
    required String weekText,
    required String room,
    required String teacher,
    String courseId = '',
    String note = '',
  }) {
    if (title.isEmpty) throw const FormatException('课程名称缺失');
    final weeks = parseTeachingWeeks(weekText);
    final key = whuHash(jsonEncode([courseId, title])).substring(0, 24);
    if (!_seen.add(
      jsonEncode([key, weekday, periods, weeks, room, teacher, note]),
    )) {
      return;
    }
    meetings.add(
      WhuCourseMeeting(
        courseKey: key,
        title: title,
        weekday: weekday,
        periods: periods,
        weeks: weeks,
        weekText: weekText,
        room: room,
        teacher: teacher,
        note: note,
      ),
    );
  }
}
