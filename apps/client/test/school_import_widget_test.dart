import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:weekglass/main.dart';
import 'package:weekglass/features/course_import/course_import_dialog.dart';
import 'package:weekglass/features/course_import/course_holidays.dart';
import 'package:weekglass/features/course_import/school_adapter.dart';
import 'package:weekglass/features/course_import/whu_timetable.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

import 'whu_import_test.dart' show MemoryImportRepo, FakeWhuPortal, payload;

WhuTerm get _term {
  final now = DateTime.now();
  return WhuTerm(
    now.month >= 8 ? now.year : now.year - 1,
    now.month >= 8 ? 3 : 12,
  );
}

DateTime get _monday => mondayOf(DateTime(_term.year, 9, 10));

Future<void> _settings(
  String school, {
  bool exclude = false,
  List<CourseHoliday> holidays = const [],
}) => SharedPreferencesAsync().setString(
  '${school}_schedule_${_term.key}',
  jsonEncode({
    'firstMonday': _monday.toIso8601String(),
    'periods': ClassPeriod.standard.map((p) => [p.start, p.end]).toList(),
    'excludeHolidays': exclude,
    'holidays': holidays.map((h) => h.toJson()).toList(),
  }),
);

Future<PlannerController> _open(
  WidgetTester tester, {
  MemoryImportRepo? repository,
}) async {
  final controller = PlannerController(
    repository: repository ?? MemoryImportRepo(),
    timeZoneId: 'Asia/Shanghai',
  );
  await controller.initialize();
  await tester.pumpWidget(WeekGlassApp(controller: controller));
  await tester.pumpAndSettle();
  showDialog<void>(
    context: tester.element(find.byType(Scaffold)),
    builder: (_) => CourseImportDialog(
      controller: controller,
      portalFactory: (_) => FakeWhuPortal(),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  setUp(() async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await initializeDateFormatting('zh_CN');
  });

  testWidgets('only WHU is offered and old course sources survive an import', (
    tester,
  ) async {
    final repository = MemoryImportRepo();
    final sample = WhuTimetable.parse(payload(extra: true));
    final legacyCourses = [
      for (final school in [SchoolAdapter.shu, SchoolAdapter.buct])
        sample
            .expand(
              term: _term,
              accountKey: 'sample-student',
              firstMonday: _monday.add(const Duration(days: 98)),
              clock: ClassPeriod.standard,
              schoolId: school.id,
            )
            .first,
    ];
    await repository.saveBatch(legacyCourses);
    await _settings('whu');
    final c = await _open(tester, repository: repository);
    expect(find.textContaining('武汉大学'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<SchoolAdapter>), findsNothing);
    expect(find.textContaining('上海大学'), findsNothing);
    expect(find.textContaining('北京化工大学'), findsNothing);
    expect(find.textContaining('课程读取待验证'), findsNothing);
    expect(
      c.events.map((e) => e.id),
      unorderedEquals(legacyCourses.map((e) => e.id)),
    );

    await tester.tap(find.text('连接并读取课表'));
    await tester.pumpAndSettle();
    expect(find.text('返回 / 更换学期'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('commit-course-import')));
    await tester.pumpAndSettle();
    expect(
      c.events.where((e) => e.importSource!.startsWith('whu:')),
      hasLength(6),
    );
    for (final event in legacyCourses) {
      expect(repository.records[event.id], same(event));
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets(
    'holiday choices preview the count, require reconfirmation and persist',
    (tester) async {
      final tuesday = _monday.add(const Duration(days: 1));
      await _settings(
        'whu',
        exclude: true,
        holidays: [CourseHoliday(name: '学校假期', start: tuesday, end: tuesday)],
      );
      final c = await _open(tester);
      await tester.tap(find.text('连接并读取课表'));
      await tester.pumpAndSettle();
      final count = find.byKey(const ValueKey('course-holiday-count'));
      await tester.ensureVisible(count);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(count).data, contains('1 节将排除，保留 5 节'));
      await tester.ensureVisible(find.text('照常导入'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('照常导入'));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(count).data, contains('1 节照常导入，共 6 节'));
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('commit-course-import')),
            )
            .onPressed,
        isNull,
      );
      final confirm = find.byKey(const ValueKey('confirm-import-calendar'));
      await tester.ensureVisible(confirm);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('commit-course-import')));
      await tester.pumpAndSettle();
      expect(c.events, hasLength(6));
      final saved = jsonDecode(
        (await SharedPreferencesAsync().getString(
          'whu_schedule_${_term.key}',
        ))!,
      ) as Map;
      expect(saved['excludeHolidays'], isFalse);
      expect(saved['holidays'], hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );

  testWidgets(
    'holiday editor fits a phone and dates can be added then removed',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _settings('whu');
      final c = await _open(tester);
      await tester.tap(find.text('连接并读取课表'));
      await tester.pumpAndSettle();
      final add = find.byKey(const ValueKey('add-course-holiday'));
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.text('添加假期日期'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '学院假期');
      await tester.tap(find.text('保存日期'));
      await tester.pumpAndSettle();
      expect(find.textContaining('学院假期\n'), findsOneWidget);
      final remove = find.byTooltip('移除学院假期');
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect(find.textContaining('尚未设置假期范围'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(c.events, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );

  testWidgets(
    'old holiday courses require a separate explicit cleanup choice and remain undoable',
    (tester) async {
      final tuesday = _monday.add(const Duration(days: 1));
      await _settings(
        'whu',
        exclude: true,
        holidays: [CourseHoliday(name: '学校假期', start: tuesday, end: tuesday)],
      );
      final c = await _open(tester);
      final old = WhuTimetable.parse(payload(extra: true)).expand(
        term: _term,
        accountKey: 'sample-student',
        firstMonday: _monday,
        clock: ClassPeriod.standard,
      );
      await c.applyCourseImport(old);
      await tester.tap(find.text('连接并读取课表'));
      await tester.pumpAndSettle();
      final cleanup = find.byKey(
        const ValueKey('remove-imported-holiday-courses'),
      );
      expect(tester.widget<CheckboxListTile>(cleanup).value, isFalse);
      expect(find.text('同时移除已导入且未调整的 1 条课程'), findsOneWidget);
      expect(find.text('保存导入设置'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('commit-course-import')));
      await tester.pumpAndSettle();
      expect(c.events, hasLength(6));
      showDialog<void>(
        context: tester.element(find.byType(Scaffold)),
        builder: (_) => CourseImportDialog(
          controller: c,
          portalFactory: (_) => FakeWhuPortal(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('连接并读取课表'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(cleanup);
      await tester.tap(cleanup);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('commit-course-import')),
            )
            .onPressed,
        isNull,
      );
      final confirm = find.byKey(const ValueKey('confirm-import-calendar'));
      await tester.ensureVisible(confirm);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('commit-course-import')));
      await tester.pumpAndSettle();
      expect(c.events, hasLength(5));
      await c.undo();
      expect(c.events, hasLength(6));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );
}
