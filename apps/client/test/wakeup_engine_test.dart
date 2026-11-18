import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weekglass/features/course_import/wakeup_engine.dart';
import 'package:weekglass/features/course_import/whu_timetable.dart';

void main() {
  const course = {
    'name': '合成课程',
    'teacher': '教师',
    'room': '实验室',
    'day': 3,
    'startNode': 0,
    'endNode': 0,
    'startWeek': 2,
    'endWeek': 6,
    'type': 2,
    'startTime': '09:12',
    'endTime': '10:37',
    'credit': 2.0,
  };
  test('explicit school times survive preview and expansion without invented nodes', () {
    final timetable = WakeUpEngine.toTimetable({
      'courses': [
        course,
        course,
        {...course, 'startTime': '25:11'},
      ],
      'timeTable': {
        'timeList': [
          {'node': 2, 'startTime': '09:00', 'endTime': '09:45'},
          {'node': 1, 'startTime': '08:00', 'endTime': '08:45'},
        ],
      },
      'startDate': '2026-9-7',
    });
    final meeting = timetable.meetings.single;
    expect(meeting.periods, isEmpty);
    expect(meeting.scheduleLabel, contains('09:12'));
    expect(meeting.weeks, [2, 4, 6]);
    expect(timetable.suggestedClock!.first.start, 480);
    expect(timetable.suggestedFirstMonday, DateTime(2026, 9, 7));
    expect(timetable.warnings, hasLength(1));
    final events = timetable.expand(
      term: const WhuTerm(2026, 3),
      accountKey: 'fixture',
      firstMonday: timetable.suggestedFirstMonday!,
      clock: const [],
      schoolId: 'school_web',
    );
    expect(events, hasLength(3));
    expect(events.first.startUtc!.toLocal(), DateTime(2026, 9, 16, 9, 12));
    expect(events.first.endUtc!.toLocal(), DateTime(2026, 9, 16, 10, 37));
  });
  test(
    'invalid clocks and non-Monday dates do not become calendar defaults',
    () {
      final result = WakeUpEngine.toTimetable({
        'courses': [course],
        'startDate': '2026-9-8',
        'timeTable': {
          'timeList': [
            {'node': 2, 'startTime': '08:00', 'endTime': '08:45'},
          ],
        },
      });
      expect(result.suggestedClock, isNull);
      expect(result.suggestedFirstMonday, isNull);
      expect(result.warnings, isNotEmpty);
    },
  );
  test(
    'source-size bound is measured in UTF-8 bytes before invoking native code',
    () async {
      await expectLater(
        WakeUpEngine.parse(adapter: 'csv', source: '课' * 1500000),
        throwsA(
          isA<WakeUpEngineException>().having(
            (e) => e.code,
            'code',
            'TOO_LARGE',
          ),
        ),
      );
    },
  );

  final home = Platform.environment['WEEKGLASS_TEST_COURSE_RUNTIME'];
  test('missing term length reaches the caller; retry sends an integer without changing the source', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const channel = MethodChannel('com.viliana.weekglass/courseadapter');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });
    final requests = <Map<String, dynamic>>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'handle');
      final request =
          jsonDecode(call.arguments as String) as Map<String, dynamic>;
      requests.add(request);
      if (!request.containsKey('termWeeks')) {
        return '{"ok":false,"code":"NEED_TERM_WEEKS"}';
      }
      return jsonEncode({
        'ok': true,
        'courses': [
          {
            ...course,
            'startWeek': 1,
            'endWeek': request['termWeeks'],
            'type': 0,
          },
        ],
      });
    });
    const source = '<table>合成课表</table>';
    await expectLater(
      WakeUpEngine.parse(adapter: 'jxnu', source: source),
      throwsA(
        isA<WakeUpEngineException>()
            .having((e) => e.code, 'code', 'NEED_TERM_WEEKS')
            .having((e) => e.message, 'message', contains('教学周数')),
      ),
    );
    final retried = await WakeUpEngine.parse(
      adapter: 'jxnu',
      source: source,
      termWeeks: 17,
    );
    expect(requests, [
      {'op': 'parse', 'adapter': 'jxnu', 'source': source},
      {'op': 'parse', 'adapter': 'jxnu', 'source': source, 'termWeeks': 17},
    ]);
    expect(retried.meetings.single.weeks.last, 17);
  });
  test(
    'shipped Windows JRE and pinned parser run using the client transport',
    () async {
      final runner = WindowsWakeUpRunner(Directory(home!));
      final list = jsonDecode(await runner.handle('{"op":"list"}'));
      expect(list['adapters'], isNotEmpty);
      final result = jsonDecode(
        await runner.handle(
          jsonEncode({
            'op': 'parse',
            'adapter': 'ccibe',
            'source': jsonEncode([
              {
                'kcmc': '物理学',
                'jsxm': '教师',
                'jxdd': '实验室',
                'xqj': '三',
                'jc': '2-3',
                'qsz': 1,
                'jsz': 6,
              },
            ]),
          }),
        ),
      );
      expect(result['ok'], isTrue);
      final m = WakeUpEngine.toTimetable(result).meetings.single;
      expect(
        [m.title, m.room, m.teacher, m.weekday, m.periods, m.weeks],
        [
          '物理学',
          '实验室',
          '教师',
          3,
          [2, 3],
          [1, 3, 5],
        ],
      );
    },
    skip: !Platform.isWindows || home == null
        ? 'Set WEEKGLASS_TEST_COURSE_RUNTIME to the built Windows data/course_adapter.'
        : false,
  );
}
