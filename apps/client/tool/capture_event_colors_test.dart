// Run explicitly with WG_CAPTURE_DIR. These planner views use only made-up events.
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
import 'package:weekglass/features/course_import/teaching_term.dart';
import 'package:weekglass/features/planner/glass_event_card.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass/main.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

import '../test/mobile_planner_test.dart' show mobileApp;
import '../test/whu_import_test.dart' show MemoryImportRepo;

const _frame = Duration(microseconds: 16667);

final _events = [
  for (var day = 2; day <= 8; day++) ...[
    _event('morning-$day', '晨间准备', day, 450, 462, EventColor.mistBlue),
    _event('rest-$day', '午休', day, 765, 810, EventColor.rose),
    _event('evening-$day', '收拾书桌', day, 1408, 1425, EventColor.lavender),
  ],
  _event('reading', '专题阅读', 2, 510, 610, EventColor.rose),
  _event('design', '设计工作坊', 2, 610, 725, EventColor.sageGreen),
  _event('tiny', '记下实验数据', 2, 810, 816, EventColor.mistBlue),
  _event('library', '图书馆自习', 2, 825, 990, EventColor.mistBlue),
  _event('revisions', '整理项目资料', 2, 1045, 1190, EventColor.slate),
  _event('walk', '散步', 2, 1110, 1190, EventColor.lavender),
  _event('discussion', '项目讨论', 3, 495, 595, EventColor.lavender),
  _event('lecture', '材料实验与报告', 3, 625, 755, EventColor.softPeach),
  _event('review', '每周回顾', 3, 849, 941, EventColor.warmSand),
  _event('writing', '写作练习', 4, 540, 685, EventColor.slate),
  _event('studio', '作品集修改', 4, 845, 990, EventColor.softPeach),
  _event('planning', '读书小组', 5, 685, 765, EventColor.warmSand),
  _event('exercise', '户外活动', 6, 830, 980, EventColor.sageGreen),
  _event('notes', '整理课程笔记', 6, 995, 1090, EventColor.mistBlue),
];

CalendarEvent _event(
  String id,
  String title,
  int day,
  int start,
  int end,
  EventColor color,
) => CalendarEvent.timed(
  id: id,
  title: title,
  startLocal: DateTime(2026, 11, day, 0, start),
  endLocal: DateTime(2026, 11, day, 0, end),
  notes: '合成日程用来核对玻璃卡片和排版。',
  timeZoneId: 'Asia/Shanghai',
  color: color,
);

List<double> _rect(Rect value) => [
  value.left,
  value.top,
  value.right,
  value.bottom,
];

void main() {
  testWidgets('capture calendar cards in the actual planner layouts', (
    tester,
  ) async {
    final output = Platform.environment['WG_CAPTURE_DIR'];
    if (output == null) throw StateError('Set WG_CAPTURE_DIR for capture');
    await initializeDateFormatting('zh_CN');
    await tester.runAsync(() async {
      await Directory(output).create(recursive: true);
      await LiquidGlass.load();
      for (final (family, path) in const [
        ('WeekGlassSans', 'assets/fonts/NotoSansSC-Variable.ttf'),
        ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
      ]) {
        await (FontLoader(family)..addFont(rootBundle.load(path))).load();
      }
    });
    tester.view.devicePixelRatio = 1;
    debugDisableShadows = false;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(() => debugDisableShadows = true);

    final captures = <String, Object>{};
    for (final (name, size, mobile, mode) in const [
      ('windows-light', Size(1280, 760), false, ThemeMode.light),
      ('android-light', Size(390, 844), true, ThemeMode.light),
      ('windows-dark', Size(1280, 760), false, ThemeMode.dark),
    ]) {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final controller = PlannerController(
        repository: MemoryImportRepo(),
        timeZoneId: 'Asia/Shanghai',
      );
      await controller.initialize();
      controller.setView(mobile ? PlannerView.threeDays : PlannerView.week);
      controller.setAnchorDate(DateTime(2026, 11, 2));
      controller.previewAppearance(
        skin: WeekGlassSkin.moonstone,
        themeMode: mode,
      );
      await controller.setSleepSchedule(
        const SleepSchedule(wakeMinute: 450, sleepMinute: 1425),
      );
      await controller.rememberTeachingTerm(
        TeachingTerm(
          year: 2026,
          semester: 3,
          firstMonday: DateTime(2026, 9, 7),
          weeks: 19,
        ),
      );
      await controller.saveEvents(_events);

      tester.view.physicalSize = size;
      tester.view.padding = mobile
          ? const FakeViewPadding(top: 24, bottom: 24)
          : const FakeViewPadding();
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: mobile
              ? mobileApp(controller, mode: mode, motion: true)
              : WeekGlassApp(controller: controller),
        ),
      );
      // Decode assets without advancing the clock, then capture the same
      // moving reflection phase across runs and both theme variants.
      await tester.runAsync(() async {
        final context = tester.element(find.byType(GlassEventCard).first);
        await precacheImage(const AssetImage('assets/brand/mark.png'), context);
        await precacheImage(
          const AssetImage('assets/brand/atmosphere.png'),
          context,
        );
      });
      for (var i = 0; i < 96; i++) {
        await tester.pump(_frame);
      }
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('event-tiny')), findsOneWidget);
      expect(find.byKey(const ValueKey('card-title-tiny')), findsNothing);

      final viewport = Offset.zero & size;
      final cards = <String, Object>{};
      for (final card in tester.widgetList<GlassEventCard>(
        find.byType(GlassEventCard),
      )) {
        final event = card.event;
        final finder = find.byKey(ValueKey('event-${event.id}'));
        final bounds = tester.getRect(finder);
        if (!viewport.overlaps(bounds)) continue;
        cards[event.id] = {
          'color': event.color.key,
          'rect': _rect(bounds),
          for (final slot in ['title', 'time'])
            if (find
                .byKey(ValueKey('card-$slot-${event.id}'))
                .evaluate()
                .isNotEmpty)
              slot: _rect(
                tester.getRect(find.byKey(ValueKey('card-$slot-${event.id}'))),
              ),
        };
      }
      captures[name] = {
        'size': [size.width, size.height],
        'cards': cards,
      };
      await tester.runAsync(() async {
        final render =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await File('$output/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
      });
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    }
    await tester.runAsync(
      () => File('$output/geometry.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(captures)),
    );
    debugDisableShadows = true;
  });
}
