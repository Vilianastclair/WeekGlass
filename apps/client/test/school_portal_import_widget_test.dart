import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:weekglass/features/course_import/school_portal_timetable.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:weekglass/features/course_import/course_import_dialog.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass/main.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

import 'whu_import_test.dart' show FakeWhuPortal, MemoryImportRepo;

void main() {
  testWidgets(
    'school timetable read in a real browser previews, saves, deduplicates and undoes',
    (tester) async {
      final browser = Process.runSync(
        'node',
        [
          '../../tooling/scripts/test-school-portal-dom.mjs',
          'test/fixtures/school_portal/zhengfang.html',
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      expect(browser.exitCode, 0, reason: browser.stderr.toString());
      final actualDom = SchoolPortalTimetable.parse(browser.stdout);
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      await initializeDateFormatting('zh_CN');
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final captureDir = Platform.environment['WG_SCHOOL_CAPTURE_DIR'];
      if (captureDir != null) {
        await tester.runAsync(() async {
          for (final (name, path) in [
            ('WeekGlassSans', 'assets/fonts/NotoSansSC-Variable.ttf'),
            ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
          ]) {
            final font = FontLoader(name)..addFont(rootBundle.load(path));
            await font.load();
          }
          await LiquidGlass.load();
        });
      }

      final repository = MemoryImportRepo();
      final controller = PlannerController(
        repository: repository,
        timeZoneId: 'Asia/Shanghai',
      );
      await controller.initialize();
      controller.previewAppearance(
        skin: controller.skin,
        themeMode: ThemeMode.light,
        glassMotion: false,
      );
      final renderKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: renderKey,
          child: WeekGlassApp(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      addTearDown(controller.dispose);

      Future<void> capture(String name) async {
        if (captureDir == null) return;
        await tester.runAsync(() async {
          final boundary =
              renderKey.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('$captureDir/$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }

      final commit = find.byKey(const ValueKey('commit-course-import'));
      final confirm = find.byKey(const ValueKey('confirm-import-calendar'));
      var capturedSource = false;
      Future<void> openFixture() async {
        final portal = FakeWhuPortal();
        showDialog<void>(
          context: tester.element(find.byType(Scaffold)),
          builder: (_) => CourseImportDialog(
            controller: controller,
            portal: portal,
            schoolReader: (_, site, term) async {
              expect(site.entry.host, 'jwxt.shu.edu.cn');
              return actualDom;
            },
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('choose-school-portal')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('school-portal-search')),
          '上海',
        );
        await tester.pumpAndSettle();
        if (!capturedSource) await capture('school-picker-phone');
        await tester.tap(find.text('上海大学').last);
        await tester.pumpAndSettle();
        if (!capturedSource) await capture('school-entry-phone');
        capturedSource = true;
        await tester.tap(find.text('打开学校教务'));
        await tester.pumpAndSettle();
        expect(portal.connected, isFalse);
        expect(find.text('示例线性代数'), findsOneWidget);
        expect(find.byKey(const ValueKey('import-profile')), findsOneWidget);
        expect(controller.events.length, anyOf(0, 4));
        expect(tester.widget<FilledButton>(commit).onPressed, isNull);
        expect(tester.widget<CheckboxListTile>(confirm).value, isFalse);
      }

      await openFixture();
      final dayPicker = find.byKey(const ValueKey('first-teaching-monday'));
      await tester.ensureVisible(dayPicker);
      await tester.tap(dayPicker);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '确定'));
      await tester.pumpAndSettle();
      final editClock = find.byKey(const ValueKey('edit-course-school-clock'));
      await tester.ensureVisible(editClock);
      await tester.tap(editClock);
      await tester.pumpAndSettle();
      final clockInput = find.byKey(const ValueKey('course-school-clock-text'));
      expect(tester.widget<TextField>(clockInput).controller!.text, isEmpty);
      await tester.enterText(clockInput, '1 08:00-08:50');
      await tester.tap(find.text('应用时刻'));
      await tester.pumpAndSettle();
      expect(find.text('所选课程用到第 3 节，请补齐时刻。'), findsOneWidget);
      await tester.enterText(
        clockInput,
        '1 08:00-08:50\n2 09:00-09:50\n3 10:10-11:00',
      );
      await tester.tap(find.text('应用时刻'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(confirm);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(commit).onPressed, isNotNull);
      await capture('school-preview-phone');
      await tester.tap(commit);
      await tester.pumpAndSettle();
      expect(controller.events, hasLength(4));
      expect(
        controller.events.every(
          (event) => event.importSource!.startsWith('school_web:'),
        ),
        isTrue,
      );
      expect(controller.whuConnected, isFalse);
      final originalIds = controller.events.map((e) => e.id).toSet();

      await openFixture();
      await tester.ensureVisible(confirm);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(find.text('保存导入设置'), findsOneWidget);
      await tester.tap(commit);
      await tester.pumpAndSettle();
      expect(controller.events.map((e) => e.id).toSet(), originalIds);
      await controller.undo();
      expect(controller.events, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip:
        !Platform.isWindows && Platform.environment['WG_TEST_BROWSER'] == null,
  );
}
