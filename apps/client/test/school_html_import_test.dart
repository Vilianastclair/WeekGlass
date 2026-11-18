import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:weekglass/features/course_import/school_adapter.dart';
import 'package:weekglass/features/course_import/school_html_format.dart';
import 'package:weekglass/features/course_import/school_html_import.dart';
import 'package:weekglass/features/course_import/whu_timetable.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

String _fixture(SchoolHtmlFormat format) =>
    File('test/fixtures/${format.name}-timetable.html').readAsStringSync();

WhuTimetable _read(SchoolHtmlFormat format, [String? source]) =>
    SchoolHtmlImport.read((
      format: format,
      bytes: Uint8List.fromList(utf8.encode(source ?? _fixture(format))),
    ));

void main() {
  test('Peking reads approved courses, separate slots and odd weeks', () {
    final timetable = _read(SchoolHtmlFormat.peking);
    expect(timetable.account, isEmpty);
    expect(timetable.courseKeys, hasLength(1));
    expect(timetable.warnings, hasLength(1));
    expect(timetable.warnings.single, contains('待定课程'));
    expect(timetable.meetings, hasLength(2));
    final first = timetable.meetings.first;
    expect(first.title, '示例线性代数');
    expect(first.teacher, '甲老师');
    expect(first.room, '理教203');
    expect(first.weekday, DateTime.monday);
    expect(first.periods, [1, 2]);
    expect(first.weeks, [1, 3, 5]);
    final second = timetable.meetings.last;
    expect(second.weekday, DateTime.saturday);
    expect(second.periods, [3]);
    expect(second.weeks, [9]);
    expect(second.room, '实验中心 A 104');
  });

  test('HUST reads micro-campus cards and reports unplaced meetings', () {
    final data = _read(SchoolHtmlFormat.hust);
    expect(data.meetings, hasLength(2));
    expect(data.warnings, ['示例流体力学：上课星期待定或无法识别']);
    final first = data.meetings.first;
    expect(first.weekday, DateTime.tuesday);
    expect(first.periods, [2, 3]);
    expect(first.weeks, [1, 2, 3, 4]);
    expect(first.room, '西十二 201');
    expect(first.teacher, '乙老师');
    expect(first.note, '人数：30\n开课对象：示例班');
    final second = data.meetings.last;
    expect(second.weekday, DateTime.sunday);
    expect(second.periods, [1]);
    expect(second.weeks, [6, 8, 10]);
    expect(second.room, isEmpty);
  });

  test('SYSU reads Sunday-first grid with grouped columns and row spans', () {
    final data = _read(SchoolHtmlFormat.sysu);
    expect(data.warnings, isEmpty);
    expect(data.meetings, hasLength(3));
    expect(data.meetings[0].weekday, DateTime.monday);
    expect(data.meetings[0].periods, [1, 2]);
    expect(data.meetings[0].weeks, [3, 4, 5, 6, 7, 8]);
    expect(data.meetings[1].weekday, DateTime.tuesday);
    expect(data.meetings[1].periods, [1]);
    expect(data.meetings[1].weeks, [2, 4, 6]);
    expect(data.meetings[2].weekday, DateTime.sunday);
    expect(data.meetings[2].periods, [2]);
    expect(data.meetings[2].weeks, [8]);
    expect(data.meetings[2].room, '实验楼 A/102');
    expect(data.meetings[2].teacher, isEmpty);
  });

  test('SYSU checks geometry before assigning weekdays', () {
    final source = _fixture(SchoolHtmlFormat.sysu);
    final explicit = _read(
      SchoolHtmlFormat.sysu,
      source.replaceFirst(
        '<td class="11111" colspan="5"></td>',
        '<td class="11111" colspan="7"></td>',
      ),
    );
    expect(explicit.meetings.last.weekday, DateTime.sunday);
    expect(
      () => _read(
        SchoolHtmlFormat.sysu,
        source.replaceFirst('colspan="5"', 'colspan="6"'),
      ),
      throwsFormatException,
    );
  });

  test(
    'wrong school, login pages and unguided script shells cannot import',
    () {
      expect(
        () => _read(SchoolHtmlFormat.peking, _fixture(SchoolHtmlFormat.hust)),
        throwsFormatException,
      );
      expect(
        () => _read(
          SchoolHtmlFormat.hust,
          '<form><input name="username"><input type="password"></form>',
        ),
        throwsFormatException,
      );
      expect(
        () => _read(
          SchoolHtmlFormat.hust,
          '<ul id="ktlist"></ul><script>loadPersonalTimetable()</script>',
        ),
        throwsFormatException,
      );
      expect(
        () => SchoolHtmlImport.read((
          format: SchoolHtmlFormat.hust,
          bytes: Uint8List(SchoolHtmlImport.maxBytes + 1),
        )),
        throwsFormatException,
      );
      expect(
        () => SchoolHtmlImport.read((
          format: SchoolHtmlFormat.hust,
          bytes: Uint8List.fromList([0xff]),
        )),
        throwsFormatException,
      );
    },
  );

  test('file sources expand with explicit clock and reimport idempotently', () {
    final format = SchoolHtmlFormat.peking;
    final timetable = _read(format);
    final firstMonday = DateTime(2040, 3, 5);
    List<CalendarEvent> expand() => timetable.expand(
      term: const WhuTerm(2039, 12),
      accountKey: SchoolHtmlImport.fileAccountKey,
      firstMonday: firstMonday,
      clock: ClassPeriod.parseClock(
        '1 08:00-08:50\n2 09:00-09:50\n3 10:10-11:00',
      ),
      schoolId: format.sourceId,
    );
    final events = expand();
    expect(events, hasLength(4));
    expect(events.first.startLocal, DateTime(2040, 3, 5, 8));
    expect(events.first.endLocal, DateTime(2040, 3, 5, 9, 50));
    expect(events.last.startLocal, DateTime(2040, 5, 5, 10, 10));
    expect(events.last.notes, '地点：实验中心 A 104\n教师：甲老师');
    expect(
      events.every((e) => SchoolAdapter.acceptsImportSource(e.importSource)),
      isTrue,
    );
    expect(SchoolAdapter.acceptsImportSource('pku:legacy'), isFalse);
    expect(SchoolAdapter.available, [SchoolAdapter.whu]);
    final repeat = CourseImportPlan.compare(
      incoming: expand(),
      previous: events,
      allActive: events,
    );
    expect(repeat.changes, isEmpty);
    expect(repeat.unchanged, 4);
  });
}
