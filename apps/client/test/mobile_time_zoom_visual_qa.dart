// Explicit rendering using synthetic in-memory data and actual pinch events.
// flutter test test/mobile_time_zoom_visual_qa.dart --concurrency=1
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:weekglass/features/planner/calendar_grid.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass/features/planner/sidebar_action.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

import 'mobile_planner_test.dart' show mobileApp;
import 'mobile_time_zoom_test.dart' show VerticalPinch;
import 'whu_import_test.dart' show MemoryImportRepo;

const _output = String.fromEnvironment(
  'WG_MOBILE_TIME_ZOOM_QA_DIR',
  defaultValue: '../../design-reference/previews/mobile-time-zoom',
);

void main() {
  testWidgets('capture phone time axis at default, fitted and enlarged sizes', (
    tester,
  ) async {
    final shadowsWereDisabled = debugDisableShadows;
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = shadowsWereDisabled);
    await initializeDateFormatting('zh_CN');
    await tester.runAsync(() async {
      for (final (family, path) in [
        ('WeekGlassSans', 'assets/fonts/NotoSansSC-Variable.ttf'),
        ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
      ]) {
        await (FontLoader(family)..addFont(rootBundle.load(path))).load();
      }
      await LiquidGlass.load();
    });
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetPadding);

    final captures = <Map<String, Object>>[];
    for (final (device, size, textScale, theme) in [
      ('portrait', const Size(390, 844), 1.0, ThemeMode.dark),
      ('compact', const Size(320, 568), 1.3, ThemeMode.light),
    ]) {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final controller = PlannerController(
        repository: MemoryImportRepo(),
        timeZoneId: 'Asia/Shanghai',
      );
      await controller.initialize();
      await controller.setSleepSchedule(const SleepSchedule(enabled: false));
      controller.setView(PlannerView.threeDays);
      controller.setAnchorDate(DateTime(2026, 11, 2));
      await controller.saveSidebarActions(SidebarAction.values.toSet());
      final rows = [
        (2, 390, 465, '晨间阅读', EventColor.mistBlue),
        (2, 520, 610, '复习线性代数', EventColor.sageGreen),
        (2, 663, 668, '休息一下', EventColor.warmSand),
        (2, 690, 780, '午间阅读', EventColor.lavender),
        (2, 870, 1020, '整理实验记录', EventColor.softPeach),
        (2, 1300, 1430, '光照实验', EventColor.rose),
        (3, 28, 100, '记录观测数据', EventColor.rose),
        (3, 510, 610, '设计工作坊', EventColor.mistBlue),
        (3, 705, 790, '小组讨论', EventColor.sageGreen),
        (3, 830, 945, '项目讨论', EventColor.rose),
        (3, 1120, 1260, '运动和晚餐', EventColor.lavender),
        (4, 480, 620, '机器人实验', EventColor.warmSand),
        (4, 645, 735, '专题阅读', EventColor.softPeach),
        (4, 780, 925, '研讨课', EventColor.mistBlue),
        (4, 1000, 1125, '课程复习', EventColor.sageGreen),
        (4, 1230, 1345, '整理笔记', EventColor.lavender),
      ];
      await controller.saveEvents([
        for (var i = 0; i < rows.length; i++)
          CalendarEvent.timed(
            id: 'time-zoom-$i',
            title: rows[i].$4,
            color: rows[i].$5,
            timeZoneId: 'Asia/Shanghai',
            startLocal: DateTime(2026, 11, rows[i].$1, 0, rows[i].$2),
            endLocal: DateTime(2026, 11, rows[i].$1, 0, rows[i].$3),
          ),
      ]);

      final key = GlobalKey();
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: mobileApp(controller, mode: theme, textScale: textScale),
        ),
      );
      final grid = find.byType(CalendarGrid);
      await tester.runAsync(
        () => precacheImage(
          const AssetImage('assets/brand/atmosphere.png'),
          tester.element(grid),
        ),
      );
      await tester.pumpAndSettle();
      final box = tester.getRect(grid);
      final positions = tester
          .widgetList<SingleChildScrollView>(
            find.descendant(
              of: grid,
              matching: find.byType(SingleChildScrollView),
            ),
          )
          .where((view) => view.scrollDirection == Axis.vertical)
          .map((view) => view.controller!.position)
          .toList();
      final viewport = positions.last.viewportDimension;
      final focus = Offset(box.center.dx, box.bottom - viewport / 2);
      positions.last.jumpTo(6 * 56);
      await tester.pumpAndSettle();

      Future<void> capture(String state) async {
        expect(tester.takeException(), isNull);
        final filename = '$device-$state.png';
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('$_output/$filename');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        captures.add({
          'file': filename,
          'width': size.width,
          'height': size.height,
          'textScale': textScale,
          'theme': theme.name,
          'zoom': controller.mobileTimeZoom,
          'viewportHeight': viewport,
          'timelineHeight': viewport + positions.last.maxScrollExtent,
        });
      }

      await capture('default');
      final pinch = await VerticalPinch.start(tester, focus, viewport * .82);
      await pinch.span(20);
      await pinch.finish();
      await tester.pumpAndSettle();
      expect(controller.mobileTimeZoom, 0);
      expect(positions.last.maxScrollExtent, 0);
      await capture('fitted');
      final expandedHeight = 24 * 56 * 1.45;
      final startSpan = viewport * .7 / (expandedHeight / viewport);
      final spread = await VerticalPinch.start(tester, focus, startSpan);
      await spread.span(viewport * .7);
      await spread.finish();
      await tester.pumpAndSettle();
      expect(controller.mobileTimeZoom, closeTo(1.45, .01));
      await capture('enlarged');
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    }
    await tester.runAsync(
      () => File('$_output/captures.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'renderer':
              'Flutter widget test with bundled fonts and production surfaces',
          'data': 'Synthetic in-memory events only',
          'safeInsets': {'top': 24, 'bottom': 24},
          'captures': captures,
        }),
      ),
    );
    debugDisableShadows = shadowsWereDisabled;
  });
}
