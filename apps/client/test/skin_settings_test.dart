import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass/features/planner/planner_settings_dialog.dart';
import 'package:weekglass/features/planner/skin_picker_dialog.dart';
import 'package:weekglass_data/weekglass_data.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test('appearance commits one pair, keeps legacy mode and falls back on unknown skin', () async {
    final preferences = SharedPreferencesAsync();
    await preferences.setString('theme_mode', 'light');
    final controller = await _controller();
    expect(controller.skin, WeekGlassSkin.moonstone);
    expect(controller.themeMode, ThemeMode.light);
    controller.previewAppearance(
      skin: WeekGlassSkin.roseQuartz,
      themeMode: ThemeMode.dark,
    );
    expect(await preferences.getString('appearance_v1'), isNull);
    await controller.saveAppearance(
      skin: WeekGlassSkin.glacier,
      themeMode: ThemeMode.system,
    );
    final restored = await _controller();
    expect(restored.skin, WeekGlassSkin.glacier);
    expect(restored.themeMode, ThemeMode.system);
    await preferences.setString(
      'appearance_v1',
      jsonEncode({'skin': 'future-skin', 'mode': 'dark'}),
    );
    final unknown = await _controller();
    expect(unknown.skin, WeekGlassSkin.moonstone);
    expect(unknown.themeMode, ThemeMode.dark);
    expect(unknown.glassMotion, isTrue);
    expect(unknown.glassStrength, .72);
    controller.dispose();
    restored.dispose();
    unknown.dispose();
  });

  for (final dismissal in ['cancel', 'escape', 'barrier']) {
    testWidgets('preview rolls back on $dismissal without storing it', (
      tester,
    ) async {
      _size(tester, const Size(1000, 820));
      final c = await _controller();
      await tester.pumpWidget(_host(c));
      await tester.tap(find.text('打开皮肤'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('skin-amethyst')));
      await tester.tap(find.byKey(const ValueKey('appearance-mode-light')));
      await tester.pumpAndSettle();
      c.previewAppearance(
        skin: c.skin,
        themeMode: c.themeMode,
        glassStrength: 1.1,
        glassMotion: false,
      );
      expect(c.skin, WeekGlassSkin.amethyst);
      expect(c.themeMode, ThemeMode.light);
      expect(await SharedPreferencesAsync().getString('appearance_v1'), isNull);
      switch (dismissal) {
        case 'cancel':
          await tester.tap(find.text('取消'));
        case 'escape':
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        case 'barrier':
          await tester.tapAt(const Offset(4, 4));
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('skin-gallery')), findsNothing);
      expect(c.skin, WeekGlassSkin.moonstone);
      expect(c.themeMode, ThemeMode.dark);
      expect(c.glassStrength, LiquidGlass.defaultStrength);
      expect(c.glassMotion, isTrue);
      expect(await SharedPreferencesAsync().getString('appearance_v1'), isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    });
  }

  testWidgets('use skin commits the preview and persists across restart', (
    tester,
  ) async {
    _size(tester, const Size(1000, 820));
    final c = await _controller();
    await tester.pumpWidget(_host(c));
    await tester.tap(find.text('打开皮肤'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('skin-rose_quartz')));
    await tester.tap(find.byKey(const ValueKey('appearance-mode-system')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('glass-motion')));
    await tester.tap(find.byKey(const ValueKey('glass-motion')));
    final slider = tester.widget<Slider>(
      find.byKey(const ValueKey('glass-strength')),
    );
    slider.onChanged!(1.05);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存外观'));
    await tester.pumpAndSettle();
    final restored = await _controller();
    expect(restored.glassMotion, isFalse);
    expect(restored.glassStrength, 1.05);
    expect(restored.skin, WeekGlassSkin.roseQuartz);
    expect(restored.themeMode, ThemeMode.system);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
    restored.dispose();
  });

  for (final size in [const Size(800, 560), const Size(390, 760)]) {
    testWidgets(
      'gallery fits $size at 1.3 text and last skin stays reachable',
      (tester) async {
        _size(tester, size);
        final c = await _controller();
        await tester.pumpWidget(_host(c, textScale: 1.3));
        await tester.tap(find.text('打开皮肤'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final last = find.byKey(const ValueKey('skin-graphite'));
        await tester.ensureVisible(last);
        await tester.pumpAndSettle();
        await tester.tap(last);
        await tester.pumpAndSettle();
        expect(c.skin, WeekGlassSkin.graphite);
        expect(tester.getRect(find.text('保存外观')).bottom, lessThan(size.height));
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
        c.dispose();
      },
    );
  }

  testWidgets('skin dialog preserves unsaved parent sleep settings', (
    tester,
  ) async {
    _size(tester, const Size(1000, 900));
    final c = await _controller();
    await tester.pumpWidget(_host(c));
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('睡眠时段'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('appearance-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('skin-amethyst')));
    await tester.tap(find.text('保存外观'));
    await tester.pumpAndSettle();
    expect(find.text('入睡 23:00'), findsNothing);
    expect(c.sleep.enabled, isTrue);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(c.sleep.enabled, isFalse);
    expect(c.skin, WeekGlassSkin.amethyst);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
}

Future<PlannerController> _controller() async {
  final c = PlannerController(
    repository: _EmptyRepository(),
    timeZoneId: 'Asia/Shanghai',
  );
  await c.initialize();
  return c;
}

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _host(PlannerController c, {double textScale = 1}) => AnimatedBuilder(
  animation: c,
  builder: (context, _) => MaterialApp(
    theme: WeekGlassTheme.light(skin: c.skin),
    darkTheme: WeekGlassTheme.dark(skin: c.skin),
    themeMode: c.themeMode,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(
      body: Builder(
        builder: (context) => Column(
          children: [
            TextButton(
              onPressed: () => openSkinPicker(context, c),
              child: const Text('打开皮肤'),
            ),
            TextButton(
              onPressed: () => openPlannerSettings(context, c),
              child: const Text('打开设置'),
            ),
          ],
        ),
      ),
    ),
  ),
);

class _EmptyRepository implements EventRepository {
  @override
  Future<List<CalendarEvent>> getAllEvents() async => [];
  @override
  Future<List<CalendarEvent>> getEventsForRange({
    required DateTime startLocal,
    required DateTime endLocal,
  }) async => [];
  @override
  Future<void> save(CalendarEvent event) async {}
  @override
  Future<void> saveBatch(List<CalendarEvent> events) async {}
  @override
  Future<void> delete(String id) async {}
  @override
  Future<void> deleteBatch(List<String> ids) async {}
  @override
  Future<void> close() async {}
}
