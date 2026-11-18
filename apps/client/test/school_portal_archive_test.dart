import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:weekglass/features/course_import/course_import_dialog.dart';
import 'package:weekglass/features/course_import/school_portal_timetable.dart';
import 'package:weekglass/features/course_import/whu_timetable.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass/main.dart';

import 'whu_import_test.dart' show MemoryImportRepo, FakeWhuPortal;

// Optional offline replay: the public author archive is not redistributed.
// Set WG_SCHOOL_ARCHIVE_DIR to a directory containing the original HTML.
void main() {
  final dir = Platform.environment['WG_SCHOOL_ARCHIVE_DIR'];
  for (final (file, rules, count) in [
    ('厦门理工学院_新正方_0.html', 11, 133),
    ('山东政法学院_新方正_0.html', 6, 56),
    ('海南大学_强智_2.html', 23, 159),
    ('苏州大学_正方_0.html', 13, 169),
  ]) {
    testWidgets('archived school page $file previews, writes and reimports', (
      t,
    ) async {
      final run = Process.runSync(
        'node',
        ['../../tooling/scripts/test-school-portal-dom.mjs', '$dir/$file'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      expect(run.exitCode, 0, reason: run.stderr.toString());
      final data = SchoolPortalTimetable.parse(run.stdout);
      expect(data.meetings.length, rules);
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      await initializeDateFormatting('zh_CN');
      final now = DateTime.now();
      final term = WhuTerm(
        now.month >= 8 ? now.year : now.year - 1,
        now.month >= 8 ? 3 : 12,
      );
      // This local test supplies a teaching calendar; the historic pages do
      // not supply their bell schedules. No school time is implied.
      final first = DateTime(2025, 9, 1);
      final periods = List.generate(
        14,
        (i) => ClassPeriod(480 + i * 60, 525 + i * 60),
      );
      const testOrigin = 'https://jw.demo.edu.cn';
      await SharedPreferencesAsync().setString(
        'school_web_${testOrigin}_schedule_${term.key}',
        jsonEncode({
          'firstMonday': first.toIso8601String(),
          'periods': [
            for (final p in periods) [p.start, p.end],
          ],
        }),
      );
      final c = PlannerController(
        repository: MemoryImportRepo(),
        timeZoneId: 'Asia/Shanghai',
      );
      await c.initialize();
      addTearDown(c.dispose);
      await t.pumpWidget(WeekGlassApp(controller: c));
      await t.pumpAndSettle();
      for (var i = 0; i < 2; i++) {
        showDialog<void>(
          context: t.element(find.byType(Scaffold)),
          builder: (_) => CourseImportDialog(
            controller: c,
            portal: FakeWhuPortal(),
            schoolReader: (_, site, term) async => data,
          ),
        );
        await t.pumpAndSettle();
        await t.tap(find.byKey(const ValueKey('choose-school-portal')));
        await t.pumpAndSettle();
        await t.tap(find.text('填写其他学校教务网址'));
        await t.pumpAndSettle();
        await t.enterText(
          find.byKey(const ValueKey('school-portal-search')),
          testOrigin,
        );
        await t.tap(find.text('使用这个网址'));
        await t.pumpAndSettle();
        await t.tap(find.text('打开学校教务'));
        await t.pumpAndSettle();
        expect(find.text('核对课程，再放进一周'), findsOneWidget);
        final confirm = find.byKey(const ValueKey('confirm-import-calendar'));
        final commit = find.byKey(const ValueKey('commit-course-import'));
        expect(t.widget<FilledButton>(commit).onPressed, isNull);
        expect(c.events.length, i == 0 ? 0 : count);
        await t.ensureVisible(confirm);
        await t.tap(confirm);
        await t.pumpAndSettle();
        expect(t.widget<FilledButton>(commit).onPressed, isNotNull);
        if (i == 1) expect(find.text('保存导入设置'), findsOneWidget);
        await t.tap(commit);
        await t.pumpAndSettle();
        expect(c.events.length, count);
      }
      final expected = data.expand(
        term: term,
        accountKey: jsonEncode([testOrigin, '']),
        firstMonday: first,
        clock: periods,
        schoolId: 'school_web',
      );
      expect(
        {
          for (final e in c.events) e.id: [e.startLocal, e.endLocal, e.notes],
        },
        equals({
          for (final e in expected) e.id: [e.startLocal, e.endLocal, e.notes],
        }),
      );
      await t.pumpWidget(const SizedBox.shrink());
    }, skip: dir == null);
  }
}
