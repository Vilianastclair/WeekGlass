import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:weekglass/features/calendar_io/timetable_image_parser.dart';
import 'package:weekglass/features/calendar_io/timetable_ocr_service.dart';
import 'package:weekglass/features/course_import/course_import_dialog.dart';
import 'package:weekglass/features/course_import/school_portal_timetable.dart';
import 'package:weekglass/features/course_import/wakeup_engine.dart';
import 'package:weekglass/features/course_import/whu_timetable.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass/features/planner/planner_screen.dart';

Future<void> verifyMacosBundledCourseEngine() async {
  final contents = p.dirname(p.dirname(Platform.resolvedExecutable));
  final runtime = Directory(p.join(contents, 'Resources', 'course_adapter'));
  if (!await runtime.exists()) {
    expect(
      Platform.environment['WEEKGLASS_MAC_COURSE_RUNTIME_DIR'],
      isNull,
      reason: 'The supplied course runtime must be in the app bundle.',
    );
    stdout.writeln(
      'Bundled course engine was not supplied for this debug run.',
    );
    return;
  }
  final adapters = await WakeUpEngine.list();
  expect(adapters, isNotEmpty);
  final source = jsonEncode([
    {
      'kcmc': '物理学',
      'jsxm': '教师',
      'jxdd': '实验室',
      'xqj': '三',
      'jc': '2-3',
      'qsz': 1,
      'jsz': 6,
    },
  ]);
  final timetable = await WakeUpEngine.parse(adapter: 'ccibe', source: source);
  final course = timetable.meetings.single;
  expect(
    [
      course.title,
      course.teacher,
      course.room,
      course.weekday,
      course.periods,
      course.weeks,
    ],
    [
      '物理学',
      '教师',
      '实验室',
      3,
      [2, 3],
      [1, 3, 5],
    ],
  );
  stdout.writeln(
    'Bundled course engine found ${adapters.length} adapters and parsed the offline fixture.',
  );
}

Future<void> verifyMacosImageFixture() async {
  final bytes = Platform.environment['WEEKGLASS_MAC_IMAGE_FIXTURE'];
  if (bytes == null) throw StateError('Missing local image fixture.');
  final watch = Stopwatch()..start();
  final page = await const TimetableOcrService().recognize(
    base64.decode(bytes),
  );
  final recognition = TimetableImageParser().parseOcr(page);
  expect(page.words, isNotEmpty);
  expect(recognition.usedLayout, isTrue);
  expect(
    recognition.courses.map(
      (course) =>
          (course.title, course.weekday, course.periodText, course.weekText),
    ),
    unorderedEquals([
      ('高等数学', 1, '1、2', '1-16周'),
      ('大学物理', 3, '3、4', '2-16周(双)'),
      ('程序设计', 5, '7、8', '1-15周(单)'),
    ]),
  );
  stdout.writeln(
    'Native timetable image recognized in ${watch.elapsedMilliseconds} ms (3 courses).',
  );
}

Future<void> importMacosCourseFixture(
  WidgetTester tester,
  PlannerController planner,
  Future<void> Function() capturePreview,
) async {
  final context = tester.element(find.byType(PlannerScreen));
  final importer = find.byType(CourseImportDialog);
  final course = find.text('示例线性代数');
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CourseImportDialog(
        controller: planner,
        schoolReader: (context, site, _) async {
          expect(site.entry.host, 'jwxt.shu.edu.cn');
          return _readFixtureInWebKit(context);
        },
      ),
    ),
  );
  await _tap(tester, find.byKey(const ValueKey('choose-school-portal')));
  final schoolSearch = find.byKey(const ValueKey('school-portal-search'));
  await _waitFor(tester, schoolSearch);
  await tester.enterText(schoolSearch, '上海大学');
  await _tap(tester, find.widgetWithText(ListTile, '上海大学'));
  await _tap(tester, find.text('打开学校教务'));
  await _waitFor(tester, course);

  await _tap(tester, find.byKey(const ValueKey('first-teaching-monday')));
  await _tap(tester, find.widgetWithText(TextButton, '确定'));
  await _tap(tester, find.byKey(const ValueKey('edit-course-school-clock')));
  final clock = find.byKey(const ValueKey('course-school-clock-text'));
  await _waitFor(tester, clock);
  await tester.enterText(clock, '1 08:00-08:50\n2 09:00-09:50\n3 10:10-11:00');
  await _tap(tester, find.text('应用时刻'));
  // Supply the fixture's term inputs through the existing import dialog.
  await _tap(tester, find.byKey(const ValueKey('confirm-import-calendar')));
  final commit = find.byKey(const ValueKey('commit-course-import'));
  final watch = Stopwatch()..start();
  while (tester.widget<FilledButton>(commit).onPressed == null &&
      watch.elapsed < const Duration(seconds: 12)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(tester.widget<FilledButton>(commit).onPressed, isNotNull);
  await tester.ensureVisible(course);
  await capturePreview();
  await _tap(tester, commit);
  while (importer.evaluate().isNotEmpty &&
      watch.elapsed < const Duration(seconds: 20)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(importer, findsNothing);

  final records = planner.events.where(
    (event) => event.importSource?.startsWith('school_web:') ?? false,
  );
  expect(records, hasLength(4));
  final maths = records.where((event) => event.title == '示例线性代数');
  expect(maths, hasLength(2));
  for (final event in maths) {
    expect(event.startLocal.weekday, DateTime.tuesday);
    expect((event.startLocal.hour, event.startLocal.minute), (8, 0));
    expect((event.endLocal.hour, event.endLocal.minute), (9, 50));
    expect(event.notes, allOf(contains('示例老师'), contains('示例楼201')));
  }
  final lab = records.where((event) => event.title == '示例实验');
  expect(lab, hasLength(2));
  for (final event in lab) {
    expect(event.startLocal.weekday, DateTime.thursday);
    expect((event.startLocal.hour, event.startLocal.minute), (10, 10));
    expect((event.endLocal.hour, event.endLocal.minute), (11, 0));
  }
  stdout.writeln(
    'WKWebView fixture imported 2 courses into 4 calendar entries.',
  );
}

Future<WhuTimetable> _readFixtureInWebKit(BuildContext context) async {
  const encoded = String.fromEnvironment('WEEKGLASS_MAC_COURSE_FIXTURE');
  if (encoded.isEmpty) throw StateError('Missing local course fixture.');
  final fixture = utf8.decode(base64.decode(encoded));
  final extractor = await rootBundle.loadString(SchoolPortalTimetable.asset);
  final loaded = Completer<void>();
  final controller = WebViewController();
  await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
  await controller.setNavigationDelegate(
    NavigationDelegate(
      onPageFinished: (_) {
        if (!loaded.isCompleted) loaded.complete();
      },
      onNavigationRequest: (request) => request.url == 'about:blank'
          ? NavigationDecision.navigate
          : NavigationDecision.prevent,
    ),
  );
  if (!context.mounted) throw StateError('The import dialog closed.');
  final navigator = Navigator.of(context);
  final route = MaterialPageRoute<void>(
    builder: (_) => Scaffold(body: WebViewWidget(controller: controller)),
  );
  unawaited(navigator.push(route));
  try {
    // This archived source is loaded directly from the test build. It uses no
    // campus address, credentials or external resources.
    await controller.loadHtmlString(fixture);
    await loaded.future.timeout(const Duration(seconds: 12));
    expect(
      await controller.runJavaScriptReturningResult('location.origin'),
      'null',
    );
    final result = await controller.runJavaScriptReturningResult(
      '(${extractor.trim()})("null")',
    );
    final timetable = SchoolPortalTimetable.parse(result);
    expect(timetable.warnings, isEmpty);
    expect(
      timetable.meetings.map(
        (meeting) => (
          meeting.title,
          meeting.weekday,
          meeting.periods.join(','),
          meeting.weeks.join(','),
        ),
      ),
      unorderedEquals([('示例线性代数', 2, '1,2', '1,3'), ('示例实验', 4, '3', '2,4')]),
    );
    return timetable;
  } finally {
    if (route.isCurrent) navigator.pop();
  }
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _waitFor(tester, finder);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder.hitTestable());
}

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  final watch = Stopwatch()..start();
  do {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  } while (watch.elapsed < const Duration(seconds: 18));
  fail('Timed out waiting for $finder.');
}
