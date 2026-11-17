// Run explicitly with WG_CAPTURE_DIR; never reads the user's calendar.
import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:weekglass/main.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass/features/planner/planner_screen.dart';
import 'package:weekglass/features/planner/skin_picker_dialog.dart';
import 'package:weekglass/features/planner/event_editor_dialog.dart';
import 'package:weekglass/features/planner/planner_settings_dialog.dart';
import 'package:weekglass/features/planner/sidebar_action.dart';
import 'package:weekglass/features/calendar_io/calendar_io.dart';
import 'package:weekglass/features/planner/event_details_dialog.dart';
import 'package:weekglass/features/planner/glass_event_card.dart';
import 'package:weekglass/features/course_import/teaching_term.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

import '../test/whu_import_test.dart' show MemoryImportRepo;

void main() {
  testWidgets('capture six glass skins and appearance gallery', (tester) async {
    final output = Platform.environment['WG_CAPTURE_DIR'];
    if (output == null) throw StateError('Set WG_CAPTURE_DIR before capture');
    await tester.runAsync(() => Directory(output).create(recursive: true));
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = true);
    await initializeDateFormatting('zh_CN');
    await tester.runAsync(LiquidGlass.load);
    String rgba(Color color) =>
        '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';
    final tokens = {
      'version': '0.20.19+45',
      'colorEncoding': '#AARRGGBB',
      'radius': WeekGlassGeometry.radius,
      'fontFamily': 'WeekGlassSans / Noto Sans SC',
      'glass': {
        'defaultStrength': LiquidGlass.defaultStrength,
        'maxStrength': LiquidGlass.maxStrength,
        'defaultMotion': true,
        'perCardBackdropBlur': 0,
        'outlineWidth': 1,
        'repaintCadence': 'display vsync; no per-frame widget rebuild',
        'desktopNoiseTexturePixels': '129 x 129, shared',
        'mobileReflection': 'two continuous fields, no texture reads',
      },
      'skins': {
        for (final skin in WeekGlassSkin.values)
          skin.id: {
            'label': skin.label,
            for (final brightness in Brightness.values)
              brightness.name: () {
                final p = WeekGlassPalette.forSkin(skin, brightness);
                return {
                  'canvas': rgba(p.canvas),
                  'text': rgba(p.text),
                  'muted': rgba(p.muted),
                  'accent': rgba(p.accent),
                  'accentStrong': rgba(p.accentStrong),
                  'surface': rgba(p.surface),
                  'line': rgba(p.line),
                  'gridLine': rgba(p.gridLine),
                  'currentTime': rgba(p.currentTime),
                  'shadow': rgba(p.shadow),
                  'atmosphereTint': rgba(p.atmosphereTint),
                  'atmosphereOpacity': p.atmosphereOpacity,
                };
              }(),
          },
      },
      'events': {
        for (final color in EventColor.values)
          color.key: {
            'label': color.label,
            'flowTint': rgba(LiquidGlass.tint(color.key)),
            'daylightFlowTint': rgba(LiquidGlass.daylightEventTint(color.key)),
            'flowPhase': LiquidGlass.phase(color.key),
            'lightInk': rgba(
              WeekGlassPalette.light.eventColor(color.key, selected: true),
            ),
            'darkInk': rgba(
              WeekGlassPalette.dark.eventColor(color.key, selected: true),
            ),
          },
      },
    };
    await tester.runAsync(
      () => File('$output/design-tokens.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(tokens)),
    );
    Future<void> settle() async {
      for (var frame = 0; frame < 25; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await tester.runAsync(() async {
      for (final (family, path) in const [
        ('WeekGlassSans', 'assets/fonts/NotoSansSC-Variable.ttf'),
        ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
      ]) {
        await (FontLoader(family)..addFont(rootBundle.load(path))).load();
      }
    });
    tester.view.physicalSize = const Size(1266, 753);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = PlannerController(
      repository: MemoryImportRepo(),
      timeZoneId: 'Asia/Shanghai',
    );
    await c.initialize();
    c.setAnchorDate(DateTime(2026, 11, 3));
    final titles = ['专注工作', '每周阅读', '项目讨论', '创作时间', '一周复盘', '运动时间', '整理与计划'];
    final hours = [9, 8, 10, 14, 16, 10, 15];
    await c.saveEvents([
      for (var i = 0; i < 7; i++)
        CalendarEvent.timed(
          id: 'demo-$i',
          title: titles[i],
          notes: i == 1 ? '阅读《设计心理学》第三章。' : null,
          startLocal: DateTime(2026, 11, 2 + i, hours[i]),
          endLocal: DateTime(
            2026,
            11,
            2 + i,
            hours[i] + (i == 0 || i == 3 ? 2 : 1),
          ),
          timeZoneId: 'Asia/Shanghai',
          color: EventColor.values[i],
        ),
    ]);
    await c.rememberTeachingTerm(
      TeachingTerm(
        year: 2026,
        semester: 3,
        firstMonday: DateTime(2026, 9, 7),
        weeks: 19,
      ),
    );
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: WeekGlassApp(controller: c),
      ),
    );
    await settle();
    await tester.runAsync(() async {
      final context = tester.element(find.byType(PlannerScreen));
      await precacheImage(const AssetImage('assets/brand/mark.png'), context);
      await precacheImage(
        const AssetImage('assets/brand/atmosphere.png'),
        context,
      );
    });
    Future<void> capture(String name) async {
      await settle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final render =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('$output/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    for (final skin in WeekGlassSkin.values) {
      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        c.previewAppearance(skin: skin, themeMode: mode);
        await capture('${skin.id}-${mode.name}');
      }
    }
    c.previewAppearance(
      skin: WeekGlassSkin.amethyst,
      themeMode: ThemeMode.dark,
    );
    await settle();
    openSkinPicker(tester.element(find.byType(PlannerScreen)), c);
    await capture('gallery-desktop-dark');
    await tester.ensureVisible(find.byKey(const ValueKey('glass-motion')));
    await capture('flow-settings-dark');
    await tester.ensureVisible(find.byKey(const ValueKey('skin-amethyst')));
    await settle();
    await tester.tap(
      find.byKey(ValueKey('skin-${WeekGlassSkin.roseQuartz.id}')),
    );
    await capture('gallery-rose-preview');
    await tester.tap(find.text('取消'));
    await settle();
    expect(c.skin, WeekGlassSkin.amethyst);
    c.previewAppearance(
      skin: WeekGlassSkin.champagne,
      themeMode: ThemeMode.light,
    );
    await settle();
    openSkinPicker(tester.element(find.byType(PlannerScreen)), c);
    await capture('gallery-desktop-light');
    await tester.ensureVisible(find.byKey(const ValueKey('glass-motion')));
    await capture('flow-settings-light');
    tester.view.physicalSize = const Size(800, 560);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await capture('gallery-narrow-large-text');
    tester.view.physicalSize = const Size(390, 844);
    await capture('gallery-mobile-large-text');
    await tester.tap(find.text('取消'));
    await settle();
    tester.view.physicalSize = const Size(1266, 753);
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    await c.saveEvents([
      CalendarEvent.timed(
        id: 'glass-short',
        title: '洗漱',
        notes: '短日程保持原来的时间和可点击范围。',
        startLocal: DateTime(2026, 11, 2, 12, 3),
        endLocal: DateTime(2026, 11, 2, 12, 4),
        timeZoneId: 'Asia/Shanghai',
        color: EventColor.lavender,
      ),
    ]);
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      c.previewAppearance(skin: WeekGlassSkin.moonstone, themeMode: mode);
      await settle();
      final card = find.byWidgetPredicate(
        (w) => w is GlassEventCard && w.event.id == 'demo-0',
      );
      final bounds = tester.getRect(card);
      final mouse = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: bounds.topLeft + const Offset(24, 18));
      await capture('hover-${mode.name}-left');
      await mouse.moveTo(bounds.bottomRight - const Offset(24, 18));
      await capture('hover-${mode.name}-right');
      await mouse.removePointer();
      await capture('short-events-${mode.name}');
      final event = c.events.firstWhere((e) => e.id == 'demo-1');
      openEventDetails(
        tester.element(find.byType(PlannerScreen)),
        controller: c,
        event: event,
      );
      await capture('event-details-${mode.name}');
      Navigator.of(tester.element(find.byType(Dialog))).pop();
      await settle();
      openEventEditor(
        tester.element(find.byType(PlannerScreen)),
        controller: c,
        copyFrom: event,
      );
      await capture('copy-editor-${mode.name}');
      await tester.tap(find.text('每周'));
      await capture('weekly-editor-${mode.name}');
      await tester.tap(find.text('每月'));
      await capture('monthly-editor-${mode.name}');
      await tester.tap(find.text('取消'));
      await settle();
      openPlannerSettings(tester.element(find.byType(PlannerScreen)), c);
      await capture('settings-${mode.name}');
      await tester.tap(find.byTooltip('关闭设置'));
      await settle();
    }
    await c.saveSidebarActions(SidebarAction.values.toSet());
    c.previewAppearance(
      skin: WeekGlassSkin.moonstone,
      themeMode: ThemeMode.light,
    );
    await c.saveEvents([
      CalendarEvent.timed(
        id: 'before-short',
        title: '午间整理',
        startLocal: DateTime(2026, 11, 2, 12),
        endLocal: DateTime(2026, 11, 2, 12, 3),
        timeZoneId: 'Asia/Shanghai',
      ),
      CalendarEvent.timed(
        id: 'after-short',
        title: '午休',
        startLocal: DateTime(2026, 11, 2, 12, 4),
        endLocal: DateTime(2026, 11, 2, 13),
        timeZoneId: 'Asia/Shanghai',
      ),
    ]);
    await capture('custom-sidebar-and-tiny-interval');
    await tester.tap(
      find.byKey(
        ValueKey('compact-events-${DateTime(2026, 11, 2).toIso8601String()}'),
      ),
    );
    await capture('short-events-list');
    await tester.tap(find.text('关闭'));
    await settle();
    openCalendarImport(tester.element(find.byType(PlannerScreen)), c);
    await capture('calendar-import');
    Navigator.of(tester.element(find.byType(Dialog))).pop();
    await settle();
    openCalendarExport(tester.element(find.byType(PlannerScreen)), c);
    await capture('calendar-export');
    Navigator.of(tester.element(find.byType(Dialog))).pop();
    await settle();
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
    debugDisableShadows = true;
  });
}
