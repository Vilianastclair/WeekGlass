import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass/features/planner/planner_settings_dialog.dart';
import 'package:weekglass/features/updates/update_settings_tile.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

import 'whu_import_test.dart' show MemoryImportRepo;

const _githubLabel = 'GitHub Star';
const _sponsorLabel = '友情赞助';
const _links = {
  _githubLabel: 'https://github.com/Vilianastclair/WeekGlass',
  _sponsorLabel: 'https://cloud.viliana.cn/support',
};
const _urlLauncher = MethodChannel('plugins.flutter.io/url_launcher');

void main() {
  for (final size in [const Size(1000, 880), const Size(320, 568)]) {
    testWidgets(
      'GitHub opens at the top and sponsorship at the bottom ($size)',
      (tester) async {
        final launches = <MethodCall>[];
        _mockLauncher(tester, (call) async {
          launches.add(call);
          return true;
        });
        final controller = await _openSettings(tester, size);
        final scrollView = find.byType(SingleChildScrollView).first;
        final scrollable = find
            .descendant(of: scrollView, matching: find.byType(Scrollable))
            .first;
        final position = tester.state<ScrollableState>(scrollable).position;
        final github = _projectButton(_githubLabel);
        final sponsor = _projectButton(_sponsorLabel);
        final sleep = find.text('睡眠时段');
        final save = find.text('保存');
        final viewport = tester.getRect(scrollView);
        final githubBounds = tester.getRect(github);

        expect(position.pixels, position.minScrollExtent);
        expect(github.hitTestable(), findsOneWidget);
        expect(githubBounds.top, greaterThanOrEqualTo(viewport.top));
        expect(githubBounds.bottom, lessThanOrEqualTo(viewport.bottom));
        expect(
          githubBounds.top,
          greaterThan(tester.getRect(find.text('设置')).bottom),
        );
        expect(githubBounds.bottom, lessThan(tester.getRect(sleep).top));
        expect(tester.getSize(github).height, greaterThanOrEqualTo(48));
        expect(find.text('微信赞赏'), findsNothing);

        await tester.tap(sleep);
        await tester.pumpAndSettle();
        await tester.tap(github);
        await tester.pumpAndSettle();
        expect(find.text('设置'), findsOneWidget);

        position.jumpTo(position.maxScrollExtent);
        await tester.pumpAndSettle();
        final sponsorBounds = tester.getRect(sponsor);
        expect(sponsor.hitTestable(), findsOneWidget);
        expect(
          sponsorBounds.top,
          greaterThan(tester.getRect(find.byType(UpdateSettingsTile)).bottom),
        );
        expect(
          sponsorBounds.bottom,
          closeTo(tester.getRect(scrollView).bottom, 0.01),
        );
        expect(sponsorBounds.bottom, lessThan(tester.getRect(save).top));
        expect(tester.getSize(sponsor).height, greaterThanOrEqualTo(48));
        await tester.tap(sponsor);
        await tester.pumpAndSettle();
        expect(find.text('设置'), findsOneWidget);

        expect(launches.map((call) => call.arguments['url']), _links.values);
        for (final call in launches) {
          expect(call.method, 'launch');
          expect(call.arguments['useWebView'], isFalse);
          expect(call.arguments['useSafariVC'], isFalse);
        }
        expect(tester.takeException(), isNull);
        expect(controller.sleep.enabled, isTrue);
        await _tap(tester, save);
        expect(controller.sleep.enabled, isFalse);
      },
    );

    testWidgets(
      'both links remain copyable if the browser cannot open ($size)',
      (tester) async {
        _mockLauncher(tester, (_) async => false);
        await _openSettings(tester, size);
        for (final action in _links.entries) {
          await _tap(tester, _projectButton(action.key));
          expect(find.text('无法打开链接'), findsOneWidget);
          expect(
            tester.widget<SelectableText>(find.byType(SelectableText)).data,
            action.value,
          );
          await _tap(tester, find.text('返回设置'));
          expect(find.text('设置'), findsOneWidget);
          expect(find.text('无法打开链接'), findsNothing);
        }
      },
    );
  }
}

Finder _projectButton(String label) =>
    find.widgetWithText(OutlinedButton, label);

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
