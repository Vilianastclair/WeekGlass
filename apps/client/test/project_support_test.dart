import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass/features/planner/planner_settings_dialog.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

import 'whu_import_test.dart' show MemoryImportRepo;

const _repo = 'https://github.com/Irthing/WeekGlass';
const _links = {'捐赠说明': '$_repo#support', 'GitHub Star': _repo};
const _urlLauncher = MethodChannel('plugins.flutter.io/url_launcher');

void main() {
  for (final size in [const Size(1000, 880), const Size(320, 568)]) {
    testWidgets('support actions open the correct external URLs at $size', (
      tester,
    ) async {
      final launches = <MethodCall>[];
      _mockLauncher(tester, (call) async {
        launches.add(call);
        return true;
      });
      final controller = await _openSettings(tester, size);
      await _tap(tester, find.text('睡眠时段'));

      for (final action in _links.entries) {
        final button = find.widgetWithText(OutlinedButton, action.key);
        await _tap(tester, button);
        expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
        expect(launches.last.method, 'launch');
        expect(launches.last.arguments['url'], action.value);
        expect(launches.last.arguments['useWebView'], isFalse);
        expect(launches.last.arguments['useSafariVC'], isFalse);
        expect(find.text('设置'), findsOneWidget);
      }

      expect(launches, hasLength(2));
      expect(tester.takeException(), isNull);
      expect(controller.sleep.enabled, isTrue);
      await _tap(tester, find.text('保存'));
      expect(controller.sleep.enabled, isFalse);
    });
  }

  testWidgets('a browser launch failure leaves a usable copy of the link', (
    tester,
  ) async {
    _mockLauncher(tester, (_) async => false);
    await _openSettings(tester, const Size(320, 568));
    await _tap(tester, find.text('捐赠说明'));
    expect(find.text('无法打开链接'), findsOneWidget);
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      _links['捐赠说明'],
    );
    await _tap(tester, find.text('返回设置'));
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('无法打开链接'), findsNothing);
  });
}

void _mockLauncher(
  WidgetTester tester,
  Future<bool> Function(MethodCall) launch,
) {
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_urlLauncher, launch);
  addTearDown(() => messenger.setMockMethodCallHandler(_urlLauncher, null));
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<PlannerController> _openSettings(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();
  final controller = PlannerController(
    repository: MemoryImportRepo(),
    timeZoneId: 'Asia/Shanghai',
  );
  await controller.initialize();
  addTearDown(controller.dispose);

  await tester.pumpWidget(
    MaterialApp(
      theme: WeekGlassTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(1.3)),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => openPlannerSettings(context, controller),
            child: const Text('打开设置'),
          ),
        ),
      ),
    ),
  );
  await _tap(tester, find.text('打开设置'));
  return controller;
}
