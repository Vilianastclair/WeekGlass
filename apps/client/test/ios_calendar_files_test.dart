import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
// The app selects this transitive implementation through file_picker at runtime.
// ignore: depend_on_referenced_packages
import 'package:file_picker_darwin/file_picker_darwin.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weekglass/features/calendar_io/calendar_codec.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass_data/weekglass_data.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

import 'mobile_planner_test.dart' show mobileApp;

void main() {
  LiveTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;

  testWidgets(
    'iPhone settings and More import three documents and export the week',
    (tester) async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      await initializeDateFormatting('zh_CN');
      const size = Size(390, 844);
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);

      final folder = Directory.systemTemp.createTempSync(
        'weekglass-file-test-',
      );
      addTearDown(() => folder.deleteSync(recursive: true));
      final sources = Directory(p.join(folder.path, '输入 # 100%'))..createSync();
      final exports = Directory(p.join(folder.path, '输出 # 100%'))..createSync();
      final fixtures = <File, File>{
        for (final name in ['timetable.ics', 'visits.csv', 'review.json'])
          File(p.join('test', 'fixtures', 'ios_calendar_files', name)): File(
            p.join(sources.path, name.toUpperCase()),
          ),
      };
      for (final MapEntry(key: fixture, value: source) in fixtures.entries) {
        fixture.copySync(source.path);
      }
      final badJson = File(p.join(sources.path, '无效.json'))
        ..writeAsStringSync('{"title": "未闭合');

      final picker = FilePickerDarwin();
      final originalPicker = FilePickerPlatform.instance;
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = originalPicker);
      final messenger = tester.binding.defaultBinaryMessenger;
      File? selected;
      var cancelSave = false;
      var pickCount = 0;
      final saves = <(String, String, Uint8List)>[];
      messenger.setMockMethodCallHandler(picker.methodChannel, (call) async {
        final arguments = call.arguments as Map<Object?, Object?>;
        switch (call.method) {
          case 'custom':
            pickCount++;
            expect(arguments['allowedExtensions'], ['ics', 'csv', 'json']);
            expect(arguments['allowMultipleSelection'], isFalse);
            final file = selected;
            if (file == null) return null;
            return [
              {
                'path': file.path,
                'name': p.basename(file.path),
                'size': file.lengthSync(),
              },
            ];
          case 'save':
            final name = arguments['fileName'] as String;
            final type = arguments['fileType'] as String;
            final bytes = arguments['bytes'] as Uint8List;
            saves.add((name, type, bytes));
            if (cancelSave) return null;
            final file = File(p.join(exports.path, name))
              ..writeAsBytesSync(bytes);
            return file.path;
          default:
            fail('Unexpected Darwin picker method: ${call.method}');
        }
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(picker.methodChannel, null),
      );

      sqfliteFfiInit();
      final repository = SqliteEventRepository(
        factory: databaseFactoryFfiNoIsolate,
        databasePath: p.join(folder.path, 'calendar.sqlite3'),
      );
      addTearDown(repository.close);
      final controller = PlannerController(
        repository: repository,
        timeZoneId: 'America/New_York',
      );
      await controller.initialize();
      await controller.setSleepSchedule(
        const SleepSchedule(sleepMinute: 23 * 60 + 45, wakeMinute: 23 * 60),
      );
      controller.setAnchorDate(DateTime(2026, 11, 23));
      addTearDown(controller.dispose);

      const capturePath = String.fromEnvironment('WG_IOS_FILES_CAPTURE_DIR');
      final frame = GlobalKey();
      if (capturePath.isNotEmpty) {
        for (final (family, asset) in [
          ('WeekGlassSans', 'assets/fonts/NotoSansSC-Variable.ttf'),
          ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
        ]) {
          await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
        }
        await LiquidGlass.load();
      }
      Future<void> capture(String name) async {
        if (capturePath.isEmpty) return;
        final boundary =
            frame.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1.5);
        try {
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!;
          File(p.join(capturePath, '$name.png'))
              .writeAsBytesSync(bytes.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      }

      await tester.pumpWidget(
        RepaintBoundary(
          key: frame,
          child: mobileApp(controller, textScale: 1.3),
        ),
      );
      await tester.pumpAndSettle();

      Future<void> tapText(String text) async {
        await tester.tap(find.text(text).hitTestable().last);
        await tester.pumpAndSettle();
      }

      Future<void> openMore(String action) async {
        await tester.tap(find.byKey(const ValueKey('mobile-action-more')));
        await tester.pumpAndSettle();
        await tapText(action);
      }

      final choose = find.widgetWithText(FilledButton, '选择文件并导入');
      final save = find.widgetWithText(FilledButton, '导出');
      await tester.tap(find.byKey(const ValueKey('mobile-action-settings')));
      await tester.pumpAndSettle();
      await tapText('本机日程');
      expect(find.text('导入课表'), findsNothing);
      await tapText('导入日程');
      expect(choose, findsOneWidget);
      expect(find.text('课表图片 / 文字'), findsNothing);
      expect(find.byType(CheckboxListTile), findsNothing);
      await capture('import');

      Future<void> chooseSelected() async {
        await tester.tap(choose);
        await tester.pumpAndSettle();
      }

      await chooseSelected(); // Native cancellation is a null method result.
      expect(choose, findsOneWidget);
      expect(controller.events, isEmpty);

      selected = badJson;
      await chooseSelected();
      expect(find.text('JSON 格式无效。'), findsOneWidget);
      expect(controller.events, isEmpty);

      for (final (index, file) in fixtures.values.indexed) {
        if (index > 0) await tapText('导入日程');
        selected = file;
        await chooseSelected();
        expect(
          choose,
          findsNothing,
        ); // Selecting the file completes the import.
        expect(controller.events, hasLength(index + 1));
      }

      await tapText('导入日程');
      selected = fixtures.values.first;
      await chooseSelected();
      expect(find.textContaining('1 项重复'), findsOneWidget);
      expect(controller.events, hasLength(3));
      expect(pickCount, 6);
      await tapText('取消');
      await tester.tap(find.byTooltip('返回设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭设置'));
      await tester.pumpAndSettle();

      List<Object?> values(CalendarEvent e) => [
        e.title,
        e.startUtc,
        e.endUtc,
        e.timeZoneId,
        e.notes,
        e.color,
      ];
      final expected = [
        [
          '合唱排练, 二部',
          DateTime.utc(2026, 11, 24, 16, 15),
          DateTime.utc(2026, 11, 24, 17),
          'Europe/Paris',
          '提前10分钟\n带谱夹\n地点：小剧场',
          EventColor.lavender,
        ],
        [
          '植物园，线上讲座',
          DateTime.utc(2026, 11, 25, 14, 30),
          DateTime.utc(2026, 11, 25, 15, 10),
          'America/New_York',
          '问答含 "寄生植物"\n回放保留一周',
          EventColor.sageGreen,
        ],
        [
          '翻译稿校对（第二轮）',
          DateTime.utc(2026, 11, 26, 12, 5),
          DateTime.utc(2026, 11, 26, 13, 20),
          'Asia/Shanghai',
          '人名和地名按原文；保留‘长安’。',
          EventColor.rose,
        ],
      ];
      expect((await repository.getAllEvents()).map(values), expected);
      expect(
        controller.events.any((event) => !controller.sleep.allows(event)),
        isTrue,
      );

      await openMore('导出日程');
      await capture('export');
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'PDF'))
            .selected,
        isTrue,
      );
      cancelSave = true;
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      expect(exports.listSync(), isEmpty);

      cancelSave = false;
      final formats = [
        ('PDF', 'pdf', 'application/pdf'),
        ('ICS', 'ics', 'text/calendar'),
        ('CSV', 'csv', 'text/csv'),
        ('JSON', 'json', 'application/json'),
      ];
      for (final (index, (label, extension, mime)) in formats.indexed) {
        if (index > 0) {
          await openMore('导出日程');
          await tester.tap(find.widgetWithText(ChoiceChip, label));
          await tester.pumpAndSettle();
        }
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(save, findsNothing);
        final (filename, contentType, bytes) = saves.last;
        expect(filename, 'WeekGlass-20261123.$extension');
        expect(contentType, mime);
        expect(File(p.join(exports.path, filename)).readAsBytesSync(), bytes);
        if (label == 'PDF') {
          expect(ascii.decode(bytes.take(5).toList()), '%PDF-');
          if (capturePath.isNotEmpty) {
            File(p.join(capturePath, filename)).writeAsBytesSync(bytes);
          }
        } else {
          final exported = CalendarCodec().decode(
            text: CalendarCodec.decodeText(bytes),
            format: CalendarFileFormat.values.byName(extension),
            timeZoneId: 'America/New_York',
            rangeStart: DateTime(2026, 11, 23),
            rangeEnd: DateTime(2026, 11, 30),
          );
          expect(exported.events.map(values), expected);
        }
      }
      expect(saves, hasLength(5));
      for (final MapEntry(key: fixture, value: source) in fixtures.entries) {
        expect(source.readAsBytesSync(), fixture.readAsBytesSync());
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
