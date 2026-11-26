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

import 'school_portal_replay.dart';

import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass/main.dart';

import 'whu_import_test.dart' show MemoryImportRepo, FakeWhuPortal;

// Optional offline replay: the public author archive is not redistributed.
// Set WG_SCHOOL_ARCHIVE_DIR to a directory containing the original HTML.
void main() {
  final dir = Platform.environment['WG_SCHOOL_ARCHIVE_DIR'];
  for (final (file, rules, count, adapter, schoolName, testOrigin) in [
    ('厦门理工学院_新正方_0.html', 11, 133, null, null, 'https://jw.demo.edu.cn'),
    ('山东政法学院_新方正_0.html', 6, 56, null, null, 'https://jw.demo.edu.cn'),
    ('海南大学_强智_2.html', 23, 159, null, null, 'https://jw.demo.edu.cn'),
    ('苏州大学_正方_0.html', 13, 169, null, null, 'https://jw.demo.edu.cn'),
    (
      '天津工业大学_URP_0.html',
      19,
      242,
      'UrpParser',
      '天津工业大学',
      'https://jwxs.tiangong.edu.cn',
    ),
    (
      '内蒙古民族大学_URP_0.html',
      58,
      185,
      'UrpParser',
      '内蒙古民族大学',
      'https://jw.demo.edu.cn',
    ),
  ]) {
    testWidgets('archived school page $file previews, writes and reimports', (
      t,
    ) async {
      late WhuTimetable data;
      if (adapter == null) {
        final run = Process.runSync(
          'node',
          ['../../tooling/scripts/test-school-portal-dom.mjs', '$dir/$file'],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        expect(run.exitCode, 0, reason: run.stderr.toString());
        data = SchoolPortalTimetable.parse(run.stdout);
      } else {
        data = (await t.runAsync(
          () => replaySchoolPage(
            '$dir/$file',
            parsers: schoolName == '内蒙古民族大学'
                ? ['NewUrpParser']
                : ['NewUrpParser', 'UrpParser'],
            checkSource: (id, source) => expect(id, adapter),
          ),
        ))!;
      }
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
            schoolReader: (_, site, term) async {
              expect(site.entry.origin, testOrigin);
              if (adapter != null)
                expect(
                  site.parsers,
                  contains(schoolName == '内蒙古民族大学' ? 'NewUrpParser' : adapter),
                );
              return data;
            },
          ),
        );
        await t.pumpAndSettle();
        await t.tap(find.byKey(const ValueKey('choose-school-portal')));
        await t.pumpAndSettle();
        if (schoolName != null) {
          await t.enterText(
            find.byKey(const ValueKey('school-portal-search')),
            schoolName,
          );
          await t.pumpAndSettle();
          await t.tap(find.text(schoolName).last);
          if (schoolName == '内蒙古民族大学') {
            await t.pumpAndSettle();
            await t.enterText(
              find.byKey(const ValueKey('school-portal-search')),
              testOrigin,
            );
            await t.tap(find.text('使用这个网址'));
          }
        } else {
          await t.tap(find.text('填写其他学校教务网址'));
          await t.pumpAndSettle();
          await t.enterText(
            find.byKey(const ValueKey('school-portal-search')),
            testOrigin,
          );
          await t.tap(find.text('使用这个网址'));
        }
        await t.pumpAndSettle();
        await t.tap(find.text('打开学校教务'));
        await t.pumpAndSettle();
        expect(find.text('课表预览'), findsOneWidget);
        final commit = find.byKey(const ValueKey('commit-course-import'));
        expect(c.events.length, i == 0 ? 0 : count);
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
