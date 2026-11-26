import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:weekglass/features/calendar_io/calendar_codec.dart';
import 'package:weekglass/features/calendar_io/timetable_image_import_dialog.dart';
import 'package:weekglass/features/calendar_io/timetable_image_parser.dart';
import 'package:weekglass/features/calendar_io/timetable_ocr_service.dart';
import 'package:weekglass/features/course_import/whu_timetable.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass_data/weekglass_data.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

const _fixtureDirectory = 'test/fixtures/timetable_image';

TimetableOcrPage fixturePage([String format = 'zh']) =>
    TimetableOcrPage.fromMap(
      jsonDecode(
        File('$_fixtureDirectory/ocr-windows-$format.json')
            .readAsStringSync()
            .replaceFirst('\uFEFF', ''),
      ) as Map,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  setUp(
    () => SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty(),
  );
  final parser = TimetableImageParser();
  test('optional OCR room changes do not duplicate an existing occurrence', () {
    const before = TimetableCourseDraft(
      title: '测试课程',
      weekday: 1,
      periodText: '1-2',
      weekText: '1周',
      room: '教一101',
    );
    const after = TimetableCourseDraft(
      title: '测试课程',
      weekday: 1,
      periodText: '1-2',
      weekText: '1周',
      room: '教一1O1',
    );
    TimetableImportPlan make(TimetableCourseDraft course) =>
        TimetableImportPlan(
          courses: [course],
          firstMonday: DateTime(2026, 9, 7),
          totalWeeks: 16,
          clock: ClassPeriod.standard,
          timeZoneId: 'Asia/Shanghai',
        );
    final existing = make(before).preview().events;
    final repeated = make(after).preview(existing: existing);
    expect(repeated.events, isEmpty);
    expect(repeated.duplicateCount, 1);
    expect(existing.single.notes, contains('101'));
  });
  test('calendar interchange retains system-local wall clock after timezone decoding', () {
    final result = CalendarCodec().decode(
      text: '[{"title":"虚构时区测试","start":"2026-09-07 08:00","end":"2026-09-07 09:00"}]',
      format: CalendarFileFormat.json,
      timeZoneId: 'Asia/Shanghai',
      rangeStart: DateTime(2026, 9, 7),
      rangeEnd: DateTime(2026, 9, 8),
    );
    final event = result.events.single;
    expect(event.startUtc, isNot(isA<tz.TZDateTime>()));
    expect(event.startLocal, DateTime.utc(2026, 9, 7).toLocal());
  });
  TimetableImportPlan plan(
    List<TimetableCourseDraft> courses, {
    DateTime? monday,
    int weeks = 16,
  }) => TimetableImportPlan(
    courses: courses,
    firstMonday: monday ?? DateTime(2026, 9, 7),
    totalWeeks: weeks,
    clock: ClassPeriod.standard,
    timeZoneId: 'Asia/Shanghai',
  );

  for (final format in ['zh', 'jpg', 'bmp', 'gif', 'tiff', 'webp']) {
    test(
      'recorded $format OCR preserves 3 columns, periods and odd/even weeks',
      () {
        final parsed = parser.parseOcr(fixturePage(format));
        expect(parsed.usedLayout, isTrue);
        expect(parsed.courses.map((course) => course.title), [
          '高等数学',
          '大学物理',
          '程序设计',
        ]);
        expect(parsed.courses.map((course) => course.weekday), [1, 3, 5]);
        expect(parsed.courses.map((course) => course.periodText), [
          '1、2',
          '3、4',
          '7、8',
        ]);
        expect(parsed.courses.map((course) => course.weekText), [
          '1-16周',
          '2-16周(双)',
          '1-15周(单)',
        ]);
        expect(
          parsed.messages.any((message) => message.contains('补齐缺失的表头')),
          isTrue,
        );
        final preview = plan(parsed.courses).preview();
        expect(preview.events.length, 32);
        expect(preview.events.map((event) => event.seriesId).toSet().length, 3);
        expect(preview.events.every((event) => event.seriesId != null), isTrue);
        expect(preview.events.first.startUtc, DateTime.utc(2026, 9, 7));
        expect(preview.events.first.startUtc, isNot(isA<tz.TZDateTime>()));
        expect(
          preview.events.where((event) => event.title == '大学物理').length,
          8,
        );
        expect(
          plan(parsed.courses).preview(existing: preview.events).duplicateCount,
          32,
        );
        expect(
          plan(parsed.courses)
              .preview(
                existing: preview.events.map(
                  (event) => event.markedDeleted(DateTime.now()),
                ),
              )
              .events,
          isEmpty,
        );
      },
    );
  }
  test('consecutive period numbers do not create an event across lunch', () {
    const course = TimetableCourseDraft(
      title: '跨午休测试',
      weekday: 1,
      periodText: '5-6',
      weekText: '1周',
    );
    final result = plan([course]).preview();
    expect(result.events.length, 2);
    expect(
      result.events.every((event) => event.duration.inMinutes == 45),
      isTrue,
    );
  });

  test(
    'text fallback needs no JSON and leaves missing schedule fields empty',
    () {
      final parsed = parser.parseText(
        '高等数学 | 周一 | 1-2节 | 1-16周 | 教一101 | 张老师\n大学物理 | 周三 | 3-4节 | 2-16周(双) | 实验楼201',
      );
      expect(parsed.courses.length, 2);
      expect(plan(parsed.courses).preview().events.length, 24);
      final incomplete = parser.parseText('程序设计\n教室：计算机楼305').courses.single;
      expect(incomplete.weekday, isNull);
      expect(incomplete.periodText, isEmpty);
      expect(incomplete.weekText, isEmpty);
      expect(() => plan([incomplete]).preview(), throwsFormatException);
    },
  );

  test(
    'first Monday, total weeks and every missing repeat schedule are validated',
    () {
      const course = TimetableCourseDraft(
        title: '测试课程',
        weekday: 1,
        periodText: '1-2',
        weekText: '1-16周',
      );
      expect(
        () => plan([course], monday: DateTime(2026, 9, 8)).preview(),
        throwsFormatException,
      );
      expect(() => plan([course], weeks: 15).preview(), throwsFormatException);
      expect(() => plan([course], weeks: 0).preview(), throwsFormatException);
      expect(
        () => plan([
          const TimetableCourseDraft(
            title: '缺周次',
            weekday: 1,
            periodText: '1-2',
            weekText: '',
          ),
        ]).preview(),
        throwsFormatException,
      );
      expect(() => TimetableImportPlan.parseClock(''), throwsFormatException);
      expect(
        () => TimetableImportPlan.parseClock('1 08:00-08:45\n2 08:30-09:15'),
        throwsFormatException,
      );
      expect(
        () => TimetableImportPlan.parseClock('1 08:00-08:45\n3 09:00-09:45'),
        throwsFormatException,
      );
    },
  );

  test('noncontiguous periods stay separate and duplicates within input are removed', () {
    const course = TimetableCourseDraft(
      title: '分段课程',
      weekday: 1,
      periodText: '1、3',
      weekText: '1周',
    );
    final result = plan([course, course]).preview();
    expect(result.events.length, 2);
    expect(result.duplicateCount, 2);
    expect(
      result.events.every((event) => event.duration.inMinutes == 45),
      isTrue,
    );
  });

  test('native OCR fixture persists to isolated SQLite and one undo survives reopen', () async {
    final directory = Directory('.dart_tool/timetable-ocr-qa')
      ..createSync(recursive: true);
    final databasePath =
        '${directory.absolute.path}/fictional-${DateTime.now().microsecondsSinceEpoch}.sqlite';
    final repository = SqliteEventRepository(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
    );
    final controller = PlannerController(
      repository: repository,
      timeZoneId: 'Asia/Shanghai',
    );
    await controller.initialize();
    final preview = plan(parser.parseOcr(fixturePage()).courses).preview();
    expect(await repository.getAllEvents(), isEmpty);
    await controller.saveEvents(preview.events);
    expect((await repository.getAllEvents()).length, 32);
    expect(
      plan(parser.parseOcr(fixturePage()).courses)
          .preview(existing: await repository.getAllEvents())
          .events,
      isEmpty,
    );
    await controller.undo();
    expect(await repository.getAllEvents(), isEmpty);
    expect(controller.events, isEmpty);
    controller.dispose();
    await repository.close();
    final reopened = SqliteEventRepository(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
    );
    expect(await reopened.getAllEvents(), isEmpty);
    final deleted = await reopened.getImportedEvents(
      CalendarCodec.sourcePrefix,
    );
    expect(deleted.length, 32);
    expect(deleted.every((event) => event.deletedAtUtc != null), isTrue);
    await reopened.close();
  });

  testWidgets('WebP is normalized locally before the Windows OCR method', (
    tester,
  ) async {
    Uint8List? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('weekglass/timetable_ocr'),
          (call) async {
            expect(call.method, 'recognize');
            received = call.arguments as Uint8List;
            return {
              'language': 'zh-Hans-CN',
              'width': 1,
              'height': 1,
              'lines': [],
            };
          },
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('weekglass/timetable_ocr'),
            null,
          ),
    );
    await tester.runAsync(
      () async => const _WindowsOcrService().recognize(
        File('$_fixtureDirectory/fictional-timetable.webp').readAsBytesSync(),
      ),
    );
    expect(received!.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
  });

  for (final size in [const Size(1080, 840), const Size(390, 760)]) {
    testWidgets(
      'editable review fits $size and never reads clipboard on entry',
      (tester) async {
        await initializeDateFormatting('zh_CN');
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = PlannerController(
          repository: TimetableMemoryRepository(),
          timeZoneId: 'Asia/Shanghai',
        );
        await controller.initialize();
        final ocr = FixtureOcrService();
        await tester.pumpWidget(timetableTestApp(controller, ocr));
        await tester.tap(find.text('图片导入'));
        await tester.pumpAndSettle();
        expect(ocr.clipboardReads, 0);
        expect(ocr.recognitions, 0);
        expect(controller.events, isEmpty);
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '生成日程预览'))
              .onPressed,
          isNull,
        );
        await tester.tap(find.text('粘贴图片'));
        await tester.pumpAndSettle();
        expect(ocr.clipboardReads, 1);
        expect(ocr.recognitions, 1);
        expect(find.text('高等数学'), findsOneWidget);
        expect(controller.events, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      },
    );
  }

  testWidgets(
    'text-only mobile review validates dates, previews, saves and undoes',
    (tester) async {
      await initializeDateFormatting('zh_CN');
      tester.view.physicalSize = const Size(390, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = TimetableMemoryRepository();
      final controller = PlannerController(
        repository: repository,
        timeZoneId: 'Asia/Shanghai',
      );
      await controller.initialize();
      await tester.pumpWidget(
        timetableTestApp(
          controller,
          const _TextOnlyOcrService(),
          initialText: '测试课程 | 周一 | 1-2节 | 1-2周 | 教一101',
        ),
      );
      await tester.tap(find.text('图片导入'));
      await tester.pumpAndSettle();
      expect(find.text('选择课表图片'), findsNothing);
      expect(find.text('粘贴图片'), findsNothing);
      await tester.tap(find.text('生成日程预览'));
      await tester.pumpAndSettle();
      expect(find.textContaining('请明确填写第一教学周'), findsOneWidget);
      expect(repository.saveBatchCalls, 0);
      await tester.enterText(
        find.byKey(const Key('timetable-first-monday')),
        '2026-09-07',
      );
      await tester.enterText(
        find.byKey(const Key('timetable-total-weeks')),
        '2',
      );
      await tester.enterText(
        find.byKey(const Key('timetable-clock')),
        '1 08:00-08:45\n2 08:50-09:35',
      );
      await tester.tap(find.text('生成日程预览'));
      await tester.pumpAndSettle();
      expect(find.text('可导入 2 项，重复 0 项'), findsOneWidget);
      expect(repository.saveBatchCalls, 0);
      await tester.tap(find.text('导入 2 项'));
      await tester.pumpAndSettle();
      expect(repository.saveBatchCalls, 1);
      expect((await repository.getAllEvents()).length, 2);
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(await repository.getAllEvents(), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
}

Widget timetableTestApp(
  PlannerController controller,
  TimetableOcrService ocr, {
  String initialText = '',
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: WeekGlassTheme.light(),
  locale: const Locale('zh', 'CN'),
  supportedLocales: const [Locale('zh', 'CN')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        onPressed: () => showDialog<bool>(
          context: context,
          builder: (_) => TimetableImageImportDialog(
            controller: controller,
            ocr: ocr,
            initialText: initialText,
          ),
        ),
        child: const Text('图片导入'),
      ),
    ),
  ),
);

class _WindowsOcrService extends TimetableOcrService {
  const _WindowsOcrService();
  @override
  bool get supportsImages => true;
}

class _TextOnlyOcrService extends TimetableOcrService {
  const _TextOnlyOcrService();
  @override
  bool get supportsImages => false;
}

class FixtureOcrService extends TimetableOcrService {
  int clipboardReads = 0, recognitions = 0;
  @override
  bool get supportsImages => true;
  @override
  Future<Uint8List?> clipboardImage() async {
    clipboardReads++;
    return File('$_fixtureDirectory/fictional-timetable.png').readAsBytesSync();
  }

  @override
  Future<TimetableOcrPage> recognize(Uint8List bytes) async {
    recognitions++;
    return fixturePage();
  }
}

class TimetableMemoryRepository
    implements EventRepository, ImportedEventRepository {
  final values = <String, CalendarEvent>{};
  int saveBatchCalls = 0;
  @override
  Future<List<CalendarEvent>> getAllEvents() async =>
      values.values.where((event) => event.deletedAtUtc == null).toList();
  @override
  Future<List<CalendarEvent>> getImportedEvents(String prefix) async => values
      .values
      .where((event) => event.importSource?.startsWith(prefix) == true)
      .toList();
  @override
  Future<List<CalendarEvent>> getEventsForRange({
    required DateTime startLocal,
    required DateTime endLocal,
  }) async => (await getAllEvents())
      .where(
        (event) =>
            event.startLocal.isBefore(endLocal) &&
            event.endLocal.isAfter(startLocal),
      )
      .toList();
  @override
  Future<void> save(CalendarEvent event) async {
    values[event.id] = event;
  }

  @override
  Future<void> saveBatch(List<CalendarEvent> events) async {
    saveBatchCalls++;
    for (final event in events) {
      values[event.id] = event;
    }
  }

  @override
  Future<void> delete(String id) async {
    if (values[id] != null) {
      values[id] = values[id]!.markedDeleted(DateTime.now());
    }
  }

  @override
  Future<void> deleteBatch(List<String> ids) async {
    for (final id in ids) {
      await delete(id);
    }
  }

  @override
  Future<void> close() async {}
}
