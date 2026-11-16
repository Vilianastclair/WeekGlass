import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:weekglass/main.dart';
import 'package:weekglass/features/course_import/teaching_term.dart';
import 'package:weekglass/features/course_import/whu_timetable.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass/features/planner/planner_settings_dialog.dart';
import 'package:weekglass/features/planner/event_editor_dialog.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

import 'whu_import_test.dart' show MemoryImportRepo, payload, expand;

const oldFooter = '\n2026–2027 秋季学期 · 第 9 周 · 第 1、2 节\n来源：武汉大学教务系统';

void main() {
  setUp(() async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await initializeDateFormatting('zh_CN');
  });
  test('WHU notes contain only available location and teacher', () {
    final events = expand(payload());
    expect(events.first.notes, '地点：教学楼 A101\n教师：示例教师');
    final empty = payload();
    final row = (empty['kbList'] as List).first as Map;
    row.remove('cdmc');
    row.remove('xm');
    expect(expand(empty).first.notes, anyOf(isNull, isEmpty));
  });
  test(
    'legacy footer cleanup preserves user notes and reimport protection',
    () {
      final current = expand(payload()).first;
      final old = current.withDetails(
        title: current.title,
        notes: '${current.notes}$oldFooter',
        color: current.color,
      );
      final unmodified = copyImported(
        old,
        fingerprint: eventImportFingerprint(old),
      );
      final migrated = compactLegacyWhuNotes(unmodified);
      expect(migrated.notes, current.notes);
      expect(migrated.importFingerprint, eventImportFingerprint(migrated));
      expect(
        CourseImportPlan.compare(
          incoming: [current],
          previous: [migrated],
          allActive: [migrated],
        ).changes,
        isEmpty,
      );
      final manual = unmodified.withDetails(
        title: '自定义名称',
        notes: '${unmodified.notes}\n带上笔记本',
        color: EventColor.rose,
      );
      final cleaned = compactLegacyWhuNotes(manual);
      expect(cleaned.notes, '${current.notes}\n带上笔记本');
      expect(cleaned.title, '自定义名称');
      expect(cleaned.importFingerprint, unmodified.importFingerprint);
      expect(
        CourseImportPlan.compare(
          incoming: [current],
          previous: [cleaned],
          allActive: [cleaned],
        ).keptEdits,
        1,
      );
      expect(identical(compactLegacyWhuNotes(cleaned), cleaned), isTrue);
    },
  );
  test('selective batch notes update keeps unchecked fields and supports clearing and undo', () async {
    final repo = MemoryImportRepo();
    final c = PlannerController(repository: repo, timeZoneId: 'Asia/Shanghai');
    await c.initialize();
    final original = expand(payload());
    await c.saveEvents(original);
    final edited = original.first.withDetails(
      title: '当前改名',
      notes: '地点：新教室',
      color: EventColor.rose,
    );
    expect(await c.saveBatchChanges(edited, fields: {BatchEditField.notes}), 4);
    final other = c.events.singleWhere((e) => e.id == original[1].id);
    expect(other.notes, '地点：新教室');
    expect(other.title, original[1].title);
    expect(other.color, original[1].color);
    expect(other.startUtc, original[1].startUtc);
    expect(other.importSource, original[1].importSource);
    expect(c.events.singleWhere((e) => e.id == edited.id).title, '当前改名');
    await c.undo();
    expect(c.events.map((e) => e.notes).toSet(), {original.first.notes});
    await c.saveBatchChanges(
      original.first.withDetails(
        title: original.first.title,
        notes: null,
        color: original.first.color,
      ),
      fields: {BatchEditField.notes},
    );
    expect(c.events.every((e) => e.notes == null), isTrue);
    await c.undo();
    repo.fail = true;
    await expectLater(
      c.saveBatchChanges(edited, fields: {BatchEditField.notes}),
      throwsStateError,
    );
    expect(c.events.map((e) => e.notes).toSet(), {original.first.notes});
    c.dispose();
  });
  test('teaching weeks use Monday and stop outside the confirmed term', () {
    final term = TeachingTerm(
      year: 2026,
      semester: 3,
      firstMonday: DateTime(2026, 9, 7),
      weeks: 19,
    );
    expect(term.weekAt(DateTime(2026, 9, 6)), isNull);
    expect(term.weekAt(DateTime(2026, 9, 7)), 1);
    expect(term.weekAt(DateTime(2026, 11, 4)), 9);
    expect(term.weekAt(DateTime(2027, 1, 17, 23, 59)), 19);
    expect(term.weekAt(DateTime(2027, 1, 18)), isNull);
    expect(
      TeachingTerm(
        year: 2026,
        semester: 12,
        firstMonday: DateTime(2027, 2, 22),
        weeks: 18,
      ).number,
      2,
    );
  });
  test('0.11 imports recover teaching calendar and migrate notes once; display preference survives restart', () async {
    final prefs = SharedPreferencesAsync();
    await prefs.setString(
      'whu_schedule_2026-3',
      jsonEncode({'firstMonday': '2026-09-07T00:00:00.000', 'periods': []}),
    );
    final repo = MemoryImportRepo();
    final current = expand(payload()).first;
    final old = current.withDetails(
      title: current.title,
      notes: '${current.notes}$oldFooter',
      color: current.color,
    );
    await repo.save(
      copyImported(old, fingerprint: eventImportFingerprint(old)),
    );
    final c = PlannerController(repository: repo, timeZoneId: 'Asia/Shanghai');
    await c.initialize();
    c.setAnchorDate(DateTime(2026, 11, 4));
    expect(c.whuConnected, isTrue);
    expect(c.teachingWeekLabel, '第 1 学期 · 第 9 周');
    expect(c.events.first.notes, current.notes);
    await c.setTeachingWeekVisible(false);
    expect(c.teachingWeekLabel, isNull);
    final next = PlannerController(
      repository: repo,
      timeZoneId: 'Asia/Shanghai',
    );
    await next.initialize();
    next.setAnchorDate(DateTime(2026, 11, 4));
    expect(next.showTeachingWeek, isFalse);
    await next.setTeachingWeekVisible(true);
    expect(next.teachingWeekLabel, '第 1 学期 · 第 9 周');
    await next.setWhuConnected(false);
    expect(next.teachingWeekLabel, isNull);
    c.dispose();
    next.dispose();
  });
  testWidgets(
    'multi-field save offers independent note selection and preserves other events',
    (tester) async {
      tester.view.physicalSize = const Size(800, 560);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = PlannerController(
        repository: MemoryImportRepo(),
        timeZoneId: 'Asia/Shanghai',
      );
      await c.initialize();
      final original = expand(payload());
      await c.saveEvents(original);
      await tester.pumpWidget(WeekGlassApp(controller: c));
      await tester.pumpAndSettle();
      openEventEditor(
        tester.element(find.byType(Scaffold)),
        controller: c,
        event: original.first,
        date: original.first.startLocal,
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '本条新名称');
      await tester.ensureVisible(find.byType(TextField).last);
      await tester.enterText(find.byType(TextField).last, '同批新备注');
      await tester.tap(find.text('保存日程'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sync-title')), findsOneWidget);
      expect(find.byKey(const ValueKey('sync-notes')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sync-title')));
      await tester.tap(find.text('修改同批日程'));
      await tester.pumpAndSettle();
      expect(
        c.events.singleWhere((e) => e.id == original.first.id).title,
        '本条新名称',
      );
      expect(
        c.events
            .where((e) => e.id != original.first.id)
            .every((e) => e.title == original.first.title),
        isTrue,
      );
      expect(c.events.every((e) => e.notes == '同批新备注'), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );
  for (final width in [390.0, 800.0]) {
    testWidgets('teaching display setting is conditional and works at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = PlannerController(
        repository: MemoryImportRepo(),
        timeZoneId: 'Asia/Shanghai',
      );
      await c.initialize();
      c.setAnchorDate(DateTime(2026, 11, 4));
      await tester.pumpWidget(WeekGlassApp(controller: c));
      await tester.pumpAndSettle();
      openPlannerSettings(tester.element(find.byType(Scaffold)), c);
      await tester.pumpAndSettle();
      await tester.tap(find.text('日历与外观'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('show-teaching-week')), findsNothing);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭设置'));
      await tester.pumpAndSettle();
      await c.rememberTeachingTerm(
        TeachingTerm(
          year: 2026,
          semester: 3,
          firstMonday: DateTime(2026, 9, 7),
          weeks: 19,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('teaching-week-label')), findsOneWidget);
      c.navigatePeriod(1);
      await tester.pumpAndSettle();
      expect(c.teachingWeekLabel, '第 1 学期 · 第 10 周');
      openPlannerSettings(tester.element(find.byType(Scaffold)), c);
      await tester.pumpAndSettle();
      await tester.tap(find.text('日历与外观'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('show-teaching-week')));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('teaching-week-label')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    });
  }
}
