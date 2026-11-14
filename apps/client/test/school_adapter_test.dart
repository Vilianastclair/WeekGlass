import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:weekglass/features/course_import/course_holidays.dart';
import 'package:weekglass/features/course_import/school_adapter.dart';
import 'package:weekglass/features/course_import/whu_portal.dart';
import 'package:weekglass/features/course_import/whu_timetable.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

List<CalendarEvent> _courses({String schoolId = 'whu'}) {
  final timetable = WhuTimetable.parse(
    jsonDecode(
      File('test/fixtures/whu-timetable-synthetic.json').readAsStringSync(),
    ),
  );
  return timetable.expand(
    term: const WhuTerm(2040, 12),
    accountKey: timetable.account,
    firstMonday: DateTime(2040, 3, 5),
    clock: ClassPeriod.standard,
    schoolId: schoolId,
  );
}

void main() {
  test(
    'school catalogue offers verified import and recognizes paused sources',
    () {
      expect(SchoolAdapter.all.map((s) => s.name), ['武汉大学', '上海大学', '北京化工大学']);
      expect(SchoolAdapter.available, [SchoolAdapter.whu]);
      expect(SchoolAdapter.whu.verifiedImport, isTrue);
      for (final school in [SchoolAdapter.shu, SchoolAdapter.buct]) {
        expect(school.verifiedImport, isFalse);
        expect(school.status, contains('待验证'));
        expect(school.firstMonday(const WhuTerm(2026, 3)), isNull);
        expect(school.calendarWeeks(const WhuTerm(2026, 3)), isNull);
        expect(school.allowed(school.entry), isTrue);
        expect(school.isTeachingPage(school.timetableUrl), isTrue);
      }
    },
  );

  test('login origins are exact HTTPS hosts with no arbitrary login proxy', () {
    for (final school in SchoolAdapter.all) {
      for (final url in [
        'http://${school.host}',
        'https://${school.host}.untrusted.example/',
        'https://user:password@${school.host}/',
        'https://${school.host}:8443/',
        'https://untrusted.example/',
        'file:///tmp/login',
      ]) {
        expect(school.allowed(url), isFalse, reason: '${school.name}: $url');
      }
    }
    expect(
      SchoolAdapter.shu.allowed(
        'https://newsso.shu.edu.cn/oauth2/login/example',
      ),
      isTrue,
    );
    expect(
      SchoolAdapter.shu.isTeachingPage('https://newsso.shu.edu.cn/'),
      isFalse,
    );
    expect(SchoolAdapter.buct.allowed(SchoolAdapter.shu.entry), isFalse);
  });

  test('each school bridge targets its own exact personal timetable path', () {
    for (final school in SchoolAdapter.all) {
      final observe = whuObserveScript('example-observer', school: school);
      final fetch = whuFetchScript(
        'example-request',
        const WhuTerm(2026, 3),
        school: school,
      );
      expect(
        observe,
        contains('location.origin!==${jsonEncode(school.origin)}'),
      );
      expect(
        observe,
        contains('url.pathname===${jsonEncode(school.responsePath)}'),
      );
      expect(fetch, contains('${school.responsePath}?gnmkdm=N2151'));
      expect(fetch, contains("credentials:'same-origin'"));
      expect(fetch, contains("send({error:'schoolQuery'"));
      expect(fetch, isNot(contains('input[type="password"]')));
    }
  });

  test('school namespaces preserve the old WHU IDs and separate identical accounts', () {
    final whu = _courses();
    final shu = _courses(schoolId: 'shu');
    final buct = _courses(schoolId: 'buct');
    expect(whu, isNotEmpty);
    expect(shu, hasLength(whu.length));
    expect(buct, hasLength(whu.length));
    expect(
      whu.every(
        (e) => e.id.startsWith('whu-') && e.importSource!.startsWith('whu:'),
      ),
      isTrue,
    );
    expect(
      shu.every(
        (e) => e.id.startsWith('shu-') && e.importSource!.startsWith('shu:'),
      ),
      isTrue,
    );
    expect({
      ...whu.map((e) => e.id),
      ...shu.map((e) => e.id),
      ...buct.map((e) => e.id),
    }, hasLength(whu.length * 3));
    expect(
      CourseImportPlan.compare(
        incoming: shu,
        previous: shu,
        allActive: shu,
      ).changes,
      isEmpty,
    );
  });

  test('holidays are inclusive and overlapping ranges never double-count', () {
    final events = _courses();
    final holiday = CourseHoliday(
      name: '虚构星港假期',
      start: DateTime(2040, 3, 27, 12),
      end: DateTime(2040, 3, 29, 12),
    );
    final holidays = [
      holiday,
      CourseHoliday(
        name: '重叠日期',
        start: DateTime(2040, 3, 28),
        end: DateTime(2040, 3, 29),
      ),
    ];
    final keep = CourseHolidayPreview.apply(events: events, holidays: holidays);
    expect(keep.incoming, events);
    expect(keep.excludedSources, isEmpty);
    final exclude = CourseHolidayPreview.apply(
      events: events,
      holidays: holidays,
      exclude: true,
    );
    expect(exclude.affected, hasLength(4));
    expect(exclude.incoming.length + exclude.affected.length, events.length);
    expect(
      exclude.affected.every((e) => holiday.contains(e.startLocal)),
      isTrue,
    );
    expect(
      exclude.incoming.where(
        (e) => e.startLocal == DateTime(2040, 4, 8, 14, 55),
      ),
      hasLength(1),
    );
    expect(
      exclude.incoming.where(
        (e) => e.startLocal == DateTime(2040, 4, 8, 18, 30),
      ),
      hasLength(1),
    );
    expect(holiday.contains(DateTime(2040, 3, 29, 23, 59)), isTrue);
    expect(holiday.contains(DateTime(2040, 3, 30)), isFalse);
    expect(
      CourseHoliday.fromJson(holiday.toJson()).dateLabel,
      holiday.dateLabel,
    );
  });

  test('excluding a previously imported holiday removes only untouched matching sources', () {
    final events = _courses();
    final first = events.first;
    final holiday = CourseHoliday(
      name: '停课一天',
      start: first.startLocal,
      end: first.startLocal,
    );
    final preview = CourseHolidayPreview.apply(
      events: events,
      holidays: [holiday],
      exclude: true,
    );
    final edited = first.withDetails(
      title: '手动调整',
      color: first.color,
      notes: first.notes,
    );
    final previous = [edited, ...events.skip(1)];
    final plan = CourseImportPlan.compare(
      incoming: preview.incoming,
      previous: previous,
      allActive: previous,
      excludedSources: preview.excludedSources,
    );
    expect(plan.keptEdits, 1);
    expect(plan.removed, preview.affected.length - 1);
    expect(plan.changes.any((e) => e.id == edited.id), isFalse);
    expect(
      plan.changes.every(
        (e) => e.deletedAtUtc != null && holiday.contains(e.startLocal),
      ),
      isTrue,
    );
  });

  test('an explicit holiday exclusion can remove all selected occurrences', () {
    final events = _courses().take(1).toList();
    final preview = CourseHolidayPreview.apply(
      events: events,
      holidays: [
        CourseHoliday(
          name: '指定假期',
          start: events.first.startLocal,
          end: events.first.startLocal,
        ),
      ],
      exclude: true,
    );
    final plan = CourseImportPlan.compare(
      incoming: preview.incoming,
      previous: events,
      allActive: events,
      excludedSources: preview.excludedSources,
    );
    expect(plan.removed, 1);
    // An ordinary empty school response still cannot erase the calendar.
    expect(
      CourseImportPlan.compare(
        incoming: [],
        previous: events,
        allActive: events,
        removeMissing: true,
      ).changes,
      isEmpty,
    );
  });

  test('missing holiday ranges do not silently omit any class', () {
    final events = _courses();
    final preview = CourseHolidayPreview.apply(
      events: events,
      holidays: [],
      exclude: true,
    );
    expect(preview.incoming, events);
    expect(preview.affected, isEmpty);
    expect(
      () => CourseHoliday(
        name: '',
        start: DateTime(2026, 1, 1),
        end: DateTime(2026, 1, 1),
      ),
      throwsArgumentError,
    );
    expect(
      () => CourseHoliday(
        name: '错误范围',
        start: DateTime(2026, 1, 2),
        end: DateTime(2026, 1, 1),
      ),
      throwsArgumentError,
    );
  });

  test('skip-only holiday policy preserves old courses even when canceled-course cleanup is enabled', () {
    final events = _courses();
    final preview = CourseHolidayPreview.apply(
      events: events,
      holidays: [
        CourseHoliday(
          name: '停课一天',
          start: events.first.startLocal,
          end: events.first.startLocal,
        ),
      ],
      exclude: true,
    );
    final plan = CourseImportPlan.compare(
      incoming: preview.incoming,
      previous: events,
      allActive: events,
      removeMissing: true,
      preservedSources: preview.excludedSources,
    );
    expect(plan.changes, isEmpty);
  });
}
