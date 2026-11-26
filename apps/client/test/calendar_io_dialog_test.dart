import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:weekglass/features/calendar_io/calendar_io.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass_data/weekglass_data.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

void main() {
  setUp(
    () => SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty(),
  );
  Future<PlannerController> controller([
    Iterable<CalendarEvent> events = const [],
  ]) async {
    final repository = _MemoryRepository();
    await repository.saveBatch(events.toList());
    final c = PlannerController(
      repository: repository,
      timeZoneId: 'Asia/Shanghai',
    );
    await c.initialize();
    c.setAnchorDate(DateTime(2026, 11, 2));
    return c;
  }

  Widget app(PlannerController c) => MaterialApp(
    theme: WeekGlassTheme.light(),
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: Scaffold(
      body: Builder(
        builder: (context) => Column(
          children: [
            TextButton(
              onPressed: () => openCalendarImport(context, c),
              child: const Text('导入入口'),
            ),
            TextButton(
              onPressed: () => openCalendarExport(context, c),
              child: const Text('导出入口'),
            ),
          ],
        ),
      ),
    ),
  );

  for (final size in [const Size(1000, 740), const Size(390, 700)]) {
    testWidgets(
      'import/export dialogs fit $size and offer color/mono choices',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final c = await controller();
        await tester.pumpWidget(app(c));
        await tester.tap(find.text('导入入口'));
        await tester.pumpAndSettle();
        expect(find.text('选择文件'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('导出入口'));
        await tester.pumpAndSettle();
        expect(find.text('彩色 PDF'), findsOneWidget);
        expect(find.text('黑白 PDF'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        c.dispose();
      },
    );
  }

  testWidgets('color PDF exports a busy week from the calendar dialog', (
    tester,
  ) async {
    final previous = FilePickerPlatform.instance;
    final output = Platform.environment['WG_COLOR_PDF_SAMPLE'];
    final picker = _FixturePicker(
      saveTarget: output == null ? null : File(output),
    );
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = previous);
    final events = [
      for (var day = 0; day < 7; day++)
        for (final (i, entry) in const [
          (8 * 60, 35, '晨间阅读'),
          (8 * 60 + 40, 45, '线性代数'),
          (9 * 60 + 40, 80, '城市观察'),
          (11 * 60 + 15, 20, '整理笔记'),
          (12 * 60, 50, '午餐与休息'),
          (14 * 60, 80, '工作室讨论'),
          (16 * 60, 55, '样品制作'),
          (18 * 60 + 20, 25, '校园散步'),
          (19 * 60 + 10, 65, '个人练习'),
        ].indexed)
          CalendarEvent.timed(
            id: 'pdf-$day-$i',
            title: entry.$3,
            startLocal: DateTime(2026, 11, 2 + day, 0, entry.$1),
            endLocal: DateTime(2026, 11, 2 + day, 0, entry.$1 + entry.$2),
            timeZoneId: 'Asia/Shanghai',
            color: EventColor.values[(i + day) % EventColor.values.length],
            notes: i == 2
                ? '地点：图书馆二楼\n带上观察记录与草图。'
                : day == 6 && i == 8
                ? '整理本周作品，下周带齐纸样。'
                : null,
          ),
      for (var i = 0; i < 2; i++)
        CalendarEvent.timed(
          id: 'pdf-overlap-$i',
          title: i == 0 ? '实验室交流' : '取资料',
          startLocal: DateTime(2026, 11, 3 + i, 14, 25),
          endLocal: DateTime(2026, 11, 3 + i, 14, i == 0 ? 55 : 30),
          timeZoneId: 'Asia/Shanghai',
          color: EventColor.rose,
        ),
    ];
    final c = await controller(events);
    await tester.pumpWidget(app(c));
    await tester.tap(find.text('导出入口'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '导出'));
      final deadline = DateTime.now().add(const Duration(seconds: 12));
      while (picker.savedBytes == null && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
    expect(picker.savedName, 'WeekGlass-20261102-彩色.pdf');
    expect(picker.savedMime, 'application/pdf');
    expect(picker.savedBytes!.take(5), '%PDF-'.codeUnits);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets(
    'fixture import previews, saves atomically, and undo removes the batch',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final oldPicker = FilePickerPlatform.instance;
      FilePickerPlatform.instance = _FixturePicker();
      addTearDown(() => FilePickerPlatform.instance = oldPicker);
      final c = await controller();
      await tester.pumpWidget(app(c));
      await tester.tap(find.text('导入入口'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择文件'));
      for (
        var i = 0;
        i < 100 && find.text('虚构导入日程 1').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('虚构导入日程 1'), findsOneWidget);
      expect(c.events, isEmpty);
      await tester.tap(find.text('导入 2 项'));
      for (var i = 0; i < 100 && c.events.isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      expect(c.events.length, 2);
      expect((await c.repository.getAllEvents()).length, 2);
      expect(find.text('撤销'), findsOneWidget);
      await tester.tap(find.text('撤销'));
      for (var i = 0; i < 100 && c.events.isNotEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(c.events, isEmpty);
      expect(await c.repository.getAllEvents(), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );

  test('save helper sends extension, MIME, bytes and cancellation to native picker', () async {
    final old = FilePickerPlatform.instance;
    final picker = _FixturePicker();
    FilePickerPlatform.instance = picker;
    try {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final result = await saveCalendarFile(
        bytes: bytes,
        suggestedName: '虚构导出',
        extension: 'json',
        mimeType: 'application/json',
      );
      expect(result, isNull);
      expect(picker.savedName, '虚构导出.json');
      expect(picker.savedMime, 'application/json');
      expect(picker.savedBytes, bytes);
    } finally {
      FilePickerPlatform.instance = old;
    }
  });
}

class _FixturePicker extends FilePickerPlatform {
  _FixturePicker({this.saveTarget});

  final File? saveTarget;
  String? savedName, savedMime;
  Uint8List? savedBytes;
  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => _FixtureFile();
  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    String mimeType = 'application/octet-stream',
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    if (saveTarget case final file?) {
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
    }
    savedName = fileName;
    savedMime = mimeType;
    savedBytes = bytes;
    return saveTarget?.uri;
  }
}

final class _FixtureFile extends PlatformFile {
  final bytes = Uint8List.fromList(
    utf8.encode(
      jsonEncode([
        for (var i = 1; i <= 2; i++)
          {
            'id': 'fixture-$i',
            'title': '虚构导入日程 $i',
            'start': '2026-11-0${i + 1}T08:00:00+08:00',
            'end': '2026-11-0${i + 1}T09:00:00+08:00',
            'timeZoneId': 'Asia/Shanghai',
            'notes': '仅用于自动测试',
          },
      ]),
    ),
  );
  @override
  String get name => 'fixture.json';
  @override
  Uri get uri => Uri.parse('file:///fixture.json');
  @override
  Never get xFile => throw UnimplementedError();
  @override
  int? lengthSync() => bytes.length;
  @override
  Future<int?> length() async => bytes.length;
  @override
  Future<Uint8List> readAsBytes() async => bytes;
  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(bytes);
}

class _MemoryRepository implements EventRepository, ImportedEventRepository {
  final values = <String, CalendarEvent>{};
  @override
  Future<List<CalendarEvent>> getAllEvents() async =>
      values.values.where((e) => e.deletedAtUtc == null).toList();
  @override
  Future<List<CalendarEvent>> getImportedEvents(String prefix) async => values
      .values
      .where((e) => e.importSource?.startsWith(prefix) == true)
      .toList();
  @override
  Future<List<CalendarEvent>> getEventsForRange({
    required DateTime startLocal,
    required DateTime endLocal,
  }) async => (await getAllEvents())
      .where(
        (e) =>
            e.startLocal.isBefore(endLocal) && e.endLocal.isAfter(startLocal),
      )
      .toList();
  @override
  Future<void> save(CalendarEvent e) async {
    values[e.id] = e;
  }

  @override
  Future<void> saveBatch(List<CalendarEvent> events) async {
    for (final e in events) {
      values[e.id] = e;
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
