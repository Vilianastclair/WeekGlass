import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:weekglass/features/course_import/school_portal.dart';
import 'package:weekglass/features/course_import/school_portal_reader.dart';

import 'school_portal_replay.dart';

import 'package:weekglass/features/course_import/whu_timetable.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final enabled = Platform.environment['WG_SCHOOL_ENGINE_DIR'] != null;
  test(
    'Beihang timetable model uses only course fields and preserves exact times',
    () async {
      final data = await replaySchoolPage(
        'test/fixtures/school_portal/buaa_model.html',
        parsers: ['BUAAParser'],
        checkSource: (id, source) {
          expect(id, 'BUAAParser');
          expect(source, isNot(contains('PRIVATE_')));
        },
      );
      final m = data.meetings.single;
      expect(
        [m.title, m.teacher, m.room, m.weekday],
        ['离散数学', '示例教师', '理学楼', 1],
      );
      expect(m.weeks, [1, 3, 5]);
      expect(m.periods, [1, 2]);
      expect([m.fixedTime!.start, m.fixedTime!.end], [480, 575]);
      expect(data.suggestedClock, hasLength(14));
    },
    skip: !enabled,
  );
  test('a known semester mismatch is rejected before parsing', () async {
    await expectLater(
      replaySchoolPage(
        'test/fixtures/school_portal/buaa_model.html',
        parsers: ['BUAAParser'],
        term: const WhuTerm(2026, 12),
        checkSource: (_, _) =>
            fail('Mismatched semester must not reach the engine'),
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('学期不一致'),
        ),
      ),
    );
  }, skip: !enabled);
  testWidgets('teaching weeks are entered explicitly and can be cancelled', (
    t,
  ) async {
    int? result;
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async {
              result = await confirmSchoolTermWeeks(
                ctx,
                const WhuTerm(2026, 3),
              );
            },
            child: const Text('读取'),
          ),
        ),
      ),
    );
    await t.tap(find.text('读取'));
    await t.pumpAndSettle();
    final input = find.byKey(const ValueKey('school-term-weeks'));
    await t.enterText(input, '0');
    await t.tap(find.text('继续预览'));
    await t.pumpAndSettle();
    expect(find.text('请填写 1 至 53 之间的整数。'), findsOneWidget);
    await t.enterText(input, '18');
    await t.tap(find.text('继续预览'));
    await t.pumpAndSettle();
    expect(result, 18);
    await t.tap(find.text('读取'));
    await t.pumpAndSettle();
    await t.tap(find.text('取消'));
    await t.pumpAndSettle();
    expect(result, isNull);
  });
  test(
    'Jiangxi Normal reuses only the same locally captured timetable on retry',
    () async {
      final sources = <String>[];
      var asks = 0;
      final data = await replaySchoolPage(
        'test/fixtures/school_portal/jxnu_term_weeks.html',
        parsers: ['JXNUParser'],
        requestWeeks: () async {
          asks++;
          return 18;
        },
        checkSource: (id, source) {
          expect(id, 'JXNUParser');
          sources.add(source);
        },
      );
      expect(asks, 1);
      expect(sources, hasLength(2));
      expect(sources.first, sources.last);
      expect(data.meetings.single.weeks.last, 18);
      await expectLater(
        replaySchoolPage(
          'test/fixtures/school_portal/jxnu_term_weeks.html',
          parsers: ['JXNUParser'],
          requestWeeks: () async => null,
        ),
        throwsA(isA<SchoolReadCancelled>()),
      );
    },
    skip: !enabled,
  );
  test('login page refuses model capture before dispatch', () async {
    await expectLater(
      replaySchoolPage(
        'test/fixtures/school_portal/login.html',
        parsers: ['BUAAParser'],
        checkSource: (_, _) =>
            fail('Credentials page must never reach the engine'),
      ),
      throwsFormatException,
    );
  }, skip: !enabled);
}
