import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weekglass/main.dart';
import 'package:weekglass/features/course_import/whu_timetable.dart';
import 'package:weekglass/features/course_import/whu_portal.dart';
import 'package:weekglass/features/course_import/course_import_dialog.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass_data/weekglass_data.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

Map<String, Object?> payload({
  String room = '教学楼 A101',
  String weeks = '1-4周',
  String sections = '1-2',
  bool extra = false,
}) => {
  'xsxx': {'XH': 'sample-student'},
  'kbList': [
    {
      'kcmc': '高等数学',
      'jxb_id': 'math-001',
      'jcs': sections,
      'xqj': '2',
      'zcd': weeks,
      'cdmc': room,
      'xm': '示例教师',
    },
    if (extra)
      {
        'kcmc': '大学英语',
        'jxb_id': 'en-001',
        'jcs': '3-4',
        'xqj': '4',
        'zcd': '1-4周(双)',
        'cdmc': '教学楼 B202',
        'xm': '示例教师',
      },
  ],
  'sjkList': [],
};
List<CalendarEvent> expand(Map<String, Object?> p) =>
    WhuTimetable.parse(p).expand(
      term: const WhuTerm(2026, 3),
      accountKey: 'sample-student',
      firstMonday: DateTime(2026, 9, 7),
      clock: ClassPeriod.standard,
    );
void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });
  setUp(() async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await initializeDateFormatting('zh_CN');
  });
  test('fictional timetable imports split weeks and week-five makeups but skips untimed courses', () {
    final response = jsonDecode(
      File('test/fixtures/whu-timetable-synthetic.json').readAsStringSync(),
    );
    final timetable = WhuTimetable.parse(response);
    expect(timetable.account, 'fictional-student-orbit');
    expect(timetable.courseKeys, hasLength(3));
    expect(timetable.meetings, hasLength(6));
    expect(timetable.warnings, hasLength(2));
    expect(timetable.warnings.every((w) => w.contains('未提供可安排的星期与节次')), isTrue);
    final events = timetable.expand(
      term: const WhuTerm(2040, 12),
      accountKey: timetable.account,
      firstMonday: DateTime(2040, 3, 5),
      clock: ClassPeriod.standard,
    );
    expect(events, hasLength(18));
    final navigation = events.where((e) => e.title == '虚构课程：彗星导航');
    expect(navigation.map((e) => e.seriesId).toSet(), hasLength(1));
    final tuesdayStarts = navigation
        .where((e) => e.startLocal.weekday == DateTime.tuesday)
        .map((e) => e.startLocal)
        .toList()..sort();
    expect(
      tuesdayStarts,
      [
        DateTime(2040, 3, 13, 8, 50),
        DateTime(2040, 3, 20, 8, 50),
        DateTime(2040, 3, 27, 8, 50),
        DateTime(2040, 4, 17, 8, 50),
        DateTime(2040, 5, 1, 8, 50),
        DateTime(2040, 5, 8, 8, 50),
        DateTime(2040, 5, 15, 8, 50),
      ],
    );
    expect(
      events.where((e) => e.startLocal.weekday == DateTime.wednesday).length,
      6,
    );
    final makeups = events
        .where((e) => e.startLocal.weekday == DateTime.sunday)
        .toList();
    expect(makeups, hasLength(2));
    expect(
      makeups.map((e) => e.startLocal).toList()..sort(),
      [DateTime(2040, 4, 8, 14, 55), DateTime(2040, 4, 8, 18, 30)],
    );
    expect(events.map((e) => e.id).toSet(), hasLength(18));
    expect(
      events.any(
        (e) => e.title.startsWith('虚构实践：') || e.title.startsWith('虚构网课：'),
      ),
      isFalse,
    );
    final repeated = CourseImportPlan.compare(
      incoming: events,
      previous: events,
      allActive: events,
    );
    expect(repeated.changes, isEmpty);
  });
  test('2026–2027 school calendar uses the published afternoon periods and teaching Mondays', () {
    expect(ClassPeriod.standard.map((p) => p.label).toList(), [
      '08:00 – 08:45',
      '08:50 – 09:35',
      '09:50 – 10:35',
      '10:40 – 11:25',
      '11:30 – 12:15',
      '14:05 – 14:50',
      '14:55 – 15:40',
      '15:45 – 16:30',
      '16:40 – 17:25',
      '17:30 – 18:15',
      '18:30 – 19:15',
      '19:20 – 20:05',
      '20:10 – 20:55',
    ]);
    expect(const WhuTerm(2026, 3).calendarFirstMonday, DateTime(2026, 9, 7));
    expect(const WhuTerm(2026, 12).calendarFirstMonday, DateTime(2027, 2, 22));
    expect(const WhuTerm(2027, 3).calendarFirstMonday, isNull);
  });
  test(
    'teaching weeks handle odd/even, separate ranges and Chinese punctuation',
    () {
      expect(parseTeachingWeeks('1-8周(单),10-12周(双),15周'), [
        1,
        3,
        5,
        7,
        10,
        12,
        15,
      ]);
      expect(parseTeachingWeeks('2至6周（双）、9周'), [2, 4, 6, 9]);
      expect(parseTeachingWeeks('1-2周,&nbsp;<span>8-10周</span>'), [
        1,
        2,
        8,
        9,
        10,
      ]);
      expect(parseTeachingWeeks('第3-4(周)；6-8(双)周'), [3, 4, 6, 8]);
      expect(parsePeriods('第1-2节、4节'), [1, 2, 4]);
      for (final bad in ['', '1-18周，待定', '0-5周', '52-56周', '8-2周']) {
        expect(() => parseTeachingWeeks(bad), throwsFormatException);
      }
      expect(() => parsePeriods('1-28节'), throwsFormatException);
    },
  );
  test('login/error payload cannot be mistaken for an empty timetable; invalid courses are explicit', () {
    for (final bad in [
      {'message': 'not logged in'},
      [],
      null,
    ]) {
      expect(() => WhuTimetable.parse(bad), throwsFormatException);
    }
    final p = payload();
    (p['kbList'] as List).add({
      'kcmc': '待排实践',
      'jcs': '待定',
      'xqj': '2',
      'zcd': '1-2周',
    });
    final data = WhuTimetable.parse(p);
    expect(data.meetings, hasLength(1));
    expect(data.warnings.single, contains('待排实践'));
    final dup = payload();
    (dup['kbList'] as List).add((dup['kbList'] as List).first);
    expect(WhuTimetable.parse(dup).meetings, hasLength(1));
  });
  test('weekly expansion keeps dates, rooms, teachers, stable identities and splits period gaps', () {
    final result = expand(payload(weeks: '1-4周(双)', sections: '1-2,4'));
    expect(result, hasLength(4));
    expect(result.first.startLocal, DateTime(2026, 9, 15, 8));
    expect(result.first.endLocal, DateTime(2026, 9, 15, 9, 35));
    expect(result[1].startLocal, DateTime(2026, 9, 15, 10, 40));
    expect(result.first.notes, contains('教学楼 A101'));
    expect(result.first.notes, contains('示例教师'));
    expect(result.map((e) => e.id).toSet(), hasLength(4));
    expect(result.map((e) => e.seriesId).toSet(), hasLength(1));
    final updated = expand(
      payload(room: '新教室', weeks: '1-4周(双)', sections: '1-2,4'),
    );
    expect(updated.first.id, result.first.id);
    expect(
      updated.first.importFingerprint,
      isNot(result.first.importFingerprint),
    );
    expect(
      () => WhuTimetable.parse(payload()).expand(
        term: const WhuTerm(2026, 3),
        accountKey: 'sample',
        firstMonday: DateTime(2026, 9, 8),
        clock: ClassPeriod.standard,
      ),
      throwsArgumentError,
    );
  });
  test('repeat import is idempotent, updates unchanged courses, preserves local edits/colors/deletions', () {
    final original = expand(payload());
    final colored = original[0].withDetails(
      title: original[0].title,
      notes: original[0].notes,
      color: EventColor.slate,
    );
    final edited = original[1].withDetails(
      title: '自己改的名字',
      notes: '自己的备注',
      color: original[1].color,
    );
    final deleted = original[2].markedDeleted(DateTime.now());
    final previous = [colored, edited, deleted, original[3]];
    final fresh = expand(payload(room: '新教室'));
    final plan = CourseImportPlan.compare(
      incoming: fresh,
      previous: previous,
      allActive: [colored, edited, original[3]],
    );
    expect(plan.updated, 2);
    expect(plan.keptEdits, 1);
    expect(plan.keptDeleted, 1);
    expect(plan.added, 0);
    expect(plan.changes.first.color, EventColor.slate);
    final equal = CourseImportPlan.compare(
      incoming: original,
      previous: original,
      allActive: original,
    );
    expect(equal.changes, isEmpty);
    expect(equal.unchanged, 4);
    final restored = CourseImportPlan.compare(
      incoming: fresh,
      previous: previous,
      allActive: [],
      restoreDeleted: true,
    );
    expect(restored.added, 1);
    final removed = CourseImportPlan.compare(
      incoming: [fresh.last],
      previous: previous,
      allActive: [],
      removeMissing: true,
    );
    expect(removed.removed, 1);
    expect(removed.keptEdits, 1);
    expect(
      CourseImportPlan.compare(
        incoming: [],
        previous: previous,
        allActive: [],
        removeMissing: true,
      ).removed,
      0,
    );
  });
  test(
    'existing manual events with the same title and time are not duplicated',
    () {
      final fresh = expand(payload());
      final manual = CalendarEvent.timed(
        id: 'manual',
        title: fresh.first.title,
        startLocal: fresh.first.startLocal,
        endLocal: fresh.first.endLocal,
        timeZoneId: 'Asia/Shanghai',
      );
      final plan = CourseImportPlan.compare(
        incoming: fresh,
        previous: [],
        allActive: [manual],
      );
      expect(plan.added, 3);
      expect(plan.duplicates, 1);
      expect(
        WhuTimetable.scopeFor(const WhuTerm(2026, 3), 'one'),
        isNot(WhuTimetable.scopeFor(const WhuTerm(2026, 3), 'two')),
      );
    },
  );
  test('SQLite import, mixed refresh and one undo preserve full metadata across restart', () async {
    final dir = Directory.systemTemp.createTempSync('weekglass-import-test-');
    final db = '${dir.path}/calendar.db';
    var repo = SqliteEventRepository(
      factory: databaseFactoryFfi,
      databasePath: db,
    );
    final c = PlannerController(repository: repo, timeZoneId: 'Asia/Shanghai');
    await c.initialize();
    final original = expand(payload());
    await c.applyCourseImport(original);
    final incoming = expand(payload(room: '新教室', weeks: '2-5周'));
    final prefix = WhuTimetable.scopeFor(
      const WhuTerm(2026, 3),
      'sample-student',
    );
    final plan = CourseImportPlan.compare(
      incoming: incoming,
      previous: await repo.getImportedEvents(prefix),
      allActive: c.events,
      removeMissing: true,
    );
    expect(plan.added, 1);
    expect(plan.updated, 3);
    expect(plan.removed, 1);
    await c.applyCourseImport(plan.changes);
    expect(c.events, hasLength(4));
    expect(c.events.every((e) => e.notes!.contains('新教室')), isTrue);
    await c.undo();
    expect(c.events, hasLength(4));
    expect(c.events.every((e) => e.notes!.contains('A101')), isTrue);
    c.dispose();
    await repo.close();
    repo = SqliteEventRepository(factory: databaseFactoryFfi, databasePath: db);
    final stored = await repo.getImportedEvents(prefix);
    expect(stored, hasLength(5));
    expect(stored.where((e) => e.deletedAtUtc != null), hasLength(1));
    expect(stored.every((e) => e.importFingerprint != null), isTrue);
    await repo.close();
    dir.deleteSync(recursive: true);
  });
  test('v1 calendar migrates without losing existing records', () async {
    final dir = Directory.systemTemp.createTempSync(
      'weekglass-migration-test-',
    );
    final path = '${dir.path}/calendar.db';
    final old = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, v) async {
          await db.execute(
            'CREATE TABLE events (id TEXT PRIMARY KEY,title TEXT,notes TEXT,color_key TEXT,is_all_day INTEGER,start_utc TEXT,end_utc TEXT,all_day_start TEXT,all_day_end_exclusive TEXT,time_zone_id TEXT,recurrence_rule TEXT,series_id TEXT,created_at_utc TEXT,updated_at_utc TEXT,version INTEGER,deleted_at_utc TEXT)',
          );
          await db.insert('events', {
            'id': 'old',
            'title': '原有安排',
            'color_key': 'mist_blue',
            'is_all_day': 0,
            'start_utc': '2026-11-03T01:00:00.000Z',
            'end_utc': '2026-11-03T02:00:00.000Z',
            'time_zone_id': 'Asia/Shanghai',
            'created_at_utc': '2026-01-01T00:00:00.000Z',
            'updated_at_utc': '2026-01-01T00:00:00.000Z',
            'version': 1,
          });
        },
      ),
    );
    await old.close();
    final repo = SqliteEventRepository(
      factory: databaseFactoryFfi,
      databasePath: path,
    );
    expect((await repo.getAllEvents()).single.title, '原有安排');
    await repo.saveBatch(expand(payload()));
    expect(await repo.getAllEvents(), hasLength(5));
    await repo.close();
    dir.deleteSync(recursive: true);
  });
  test('failed import leaves memory and undo intact; time changes keep source metadata', () async {
    final repo = MemoryImportRepo();
    final c = PlannerController(repository: repo, timeZoneId: 'Asia/Shanghai');
    await c.initialize();
    final events = expand(payload());
    repo.fail = true;
    await expectLater(c.applyCourseImport(events), throwsStateError);
    expect(c.events, isEmpty);
    expect(c.canUndo, isFalse);
    repo.fail = false;
    await c.applyCourseImport(events);
    final moved = events.first.withTimedRange(
      events.first.startLocal.add(const Duration(hours: 1)),
      events.first.endLocal.add(const Duration(hours: 1)),
    );
    expect(moved.importSource, events.first.importSource);
    expect(moved.importFingerprint, events.first.importFingerprint);
    await c.saveBatchChanges(moved);
    expect(c.events.every((e) => e.importSource != null), isTrue);
    c.dispose();
  });
  test(
    'web bridge only reads the school timetable and restricts trusted origins',
    () {
      expect(NativeWhuPortal.allowed('https://jwgl.whu.edu.cn/path'), isTrue);
      for (final url in [
        'http://jwgl.whu.edu.cn',
        'https://jwgl.whu.edu.cn.evil.example',
        'file:///tmp/login',
        'https://example.com',
      ]) {
        expect(NativeWhuPortal.allowed(url), isFalse);
      }
      final script = whuFetchScript('sample-request', const WhuTerm(2026, 3));
      expect(script, contains('xskbcx_cxXsgrkb'));
      expect(script, contains("credentials:'same-origin'"));
      expect(script, contains('requestId'));
    },
  );
  for (final size in [
    const Size(1000, 760),
    const Size(800, 560),
    const Size(390, 844),
  ]) {
    testWidgets(
      'import preview and commit fit $size; previous import is skipped',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final now = DateTime.now();
        final year = now.month >= 8 ? now.year : now.year - 1;
        final sem = now.month >= 8 ? 3 : 12;
        final monday = mondayOf(DateTime(year, 9, 10));
        await SharedPreferencesAsync().setString(
          'whu_schedule_$year-$sem',
          jsonEncode({
            'firstMonday': monday.toIso8601String(),
            'periods': ClassPeriod.standard
                .map((p) => [p.start, p.end])
                .toList(),
          }),
        );
        final repo = MemoryImportRepo();
        final c = PlannerController(
          repository: repo,
          timeZoneId: 'Asia/Shanghai',
        );
        await c.initialize();
        await tester.pumpWidget(WeekGlassApp(controller: c));
        await tester.pumpAndSettle();
        final context = tester.element(find.byType(Scaffold));
        showDialog<void>(
          context: context,
          builder: (_) =>
              CourseImportDialog(controller: c, portal: FakeWhuPortal()),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('连接并读取课表'));
        await tester.pumpAndSettle();
        expect(find.text('核对课程，再放进一周'), findsOneWidget);
        expect(find.text('高等数学'), findsOneWidget);
        expect(
          tester
              .getRect(find.byKey(const ValueKey('commit-course-import')))
              .bottom,
          lessThan(size.height),
        );
        await tester.tap(find.byKey(const ValueKey('commit-course-import')));
        await tester.pumpAndSettle();
        expect(c.events, hasLength(6));
        expect(tester.takeException(), isNull);
        final incoming = WhuTimetable.parse(payload(extra: true)).expand(
          term: WhuTerm(year, sem),
          accountKey: 'sample-student',
          firstMonday: monday,
          clock: ClassPeriod.standard,
        );
        expect(
          CourseImportPlan.compare(
            incoming: incoming,
            previous: c.events,
            allActive: c.events,
          ).changes,
          isEmpty,
        );
        await c.undo();
        expect(c.events, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        c.dispose();
      },
    );
  }
  testWidgets(
    'connection failure can be retried and canceled without changing events',
    (tester) async {
      final c = PlannerController(
        repository: MemoryImportRepo(),
        timeZoneId: 'Asia/Shanghai',
      );
      await c.initialize();
      await tester.pumpWidget(WeekGlassApp(controller: c));
      await tester.pumpAndSettle();
      showDialog<void>(
        context: tester.element(find.byType(Scaffold)),
        builder: (_) => CourseImportDialog(
          controller: c,
          portal: FakeWhuPortal(fail: true),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('连接并读取课表'));
      await tester.pumpAndSettle();
      expect(find.textContaining('学校暂时不可用'), findsOneWidget);
      expect(find.text('重新连接'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭导入'));
      await tester.pumpAndSettle();
      expect(c.events, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );
  testWidgets(
    'empty school response keeps the official page available for verification',
    (tester) async {
      final c = PlannerController(
        repository: MemoryImportRepo(),
        timeZoneId: 'Asia/Shanghai',
      );
      await c.initialize();
      await tester.pumpWidget(WeekGlassApp(controller: c));
      await tester.pumpAndSettle();
      showDialog<void>(
        context: tester.element(find.byType(Scaffold)),
        builder: (_) => CourseImportDialog(
          controller: c,
          portal: FakeWhuPortal(empty: true),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('连接并读取课表'));
      await tester.pumpAndSettle();
      expect(find.textContaining('学校未返回所选学期'), findsOneWidget);
      expect(find.text('打开学校课表'), findsOneWidget);
      expect(find.text('核对课程，再放进一周'), findsNothing);
      expect(c.events, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );
}

class MemoryImportRepo implements EventRepository, ImportedEventRepository {
  bool fail = false;
  final records = <String, CalendarEvent>{};
  @override
  Future<List<CalendarEvent>> getAllEvents() async =>
      records.values.where((e) => e.deletedAtUtc == null).toList();
  @override
  Future<List<CalendarEvent>> getImportedEvents(String prefix) async => records
      .values
      .where((e) => e.importSource?.startsWith(prefix) ?? false)
      .toList();
  @override
  Future<List<CalendarEvent>> getEventsForRange({
    required DateTime startLocal,
    required DateTime endLocal,
  }) async => getAllEvents();
  @override
  Future<void> save(CalendarEvent e) => saveBatch([e]);
  @override
  Future<void> saveBatch(List<CalendarEvent> events) async {
    if (fail) throw StateError('test failure');
    for (final e in events) {
      records[e.id] = e;
    }
  }

  @override
  Future<void> delete(String id) => deleteBatch([id]);
  @override
  Future<void> deleteBatch(List<String> ids) async {
    for (final id in ids) {
      final e = records[id];
      if (e != null) records[id] = e.markedDeleted(DateTime.now());
    }
  }

  @override
  Future<void> close() async {}
}

class FakeWhuPortal extends WhuPortal {
  FakeWhuPortal({this.fail = false, this.empty = false});
  final bool fail, empty;
  bool connected = false;
  @override
  bool get initialized => connected;
  @override
  bool get loading => false;
  @override
  bool get canRead => connected && !fail;
  @override
  String get host => connected ? 'jwgl.whu.edu.cn' : '';
  @override
  String? get error => fail && connected ? '学校暂时不可用，请重试。' : null;
  @override
  Widget buildView() => const Center(child: Text('学校官方登录页面'));
  @override
  Future<void> initialize() async {
    connected = true;
    notifyListeners();
  }

  @override
  Future<void> reconnect() => initialize();
  @override
  Future<void> openTimetable() => initialize();
  @override
  Future<void> signOut() async {
    connected = false;
    notifyListeners();
  }

  @override
  Future<WhuTimetable> read(WhuTerm term) async =>
      WhuTimetable.parse(empty ? {'kbList': <Object>[]} : payload(extra: true));
  @override
  Future<void> close() async {
    dispose();
  }
}
