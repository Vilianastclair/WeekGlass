// Explicit Flutter capture of the startup prompt with synthetic calendar data.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:weekglass/features/mobile/mobile_planner_screen.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass/features/planner/planner_screen.dart';
import 'package:weekglass/features/planner/planner_settings_dialog.dart';
import 'package:weekglass/features/updates/android_update_bridge.dart';
import 'package:weekglass/features/updates/startup_update_prompt.dart';
import 'package:weekglass/features/updates/update_service.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

import 'support/windows_startup_feed.dart';
import 'whu_import_test.dart' show MemoryImportRepo;

const _captureSettings = bool.fromEnvironment('WG_REOPEN_UPDATE_SETTINGS_QA');
const _output = String.fromEnvironment(
  'WG_STARTUP_UPDATE_QA_DIR',
  defaultValue: _captureSettings
      ? '../../docs/qa/reopen-update-20261117'
      : '../../docs/qa/startup-update-20261117',
);

void main() {
  testWidgets('render the production startup prompt over both planners', (
    tester,
  ) async {
    final shadowsDisabled = debugDisableShadows;
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = shadowsDisabled);
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
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetPadding);

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(AndroidUpdateBridge.channel, (
      call,
    ) async {
      if (call.method != 'deviceInfo') {
        throw StateError('Unexpected native action: ${call.method}');
      }
      return {
        'sourceApk': 'synthetic.apk',
        'arm64': true,
        'version': UpdateService.currentVersion,
        'build': UpdateService.currentBuild,
      };
    });
    addTearDown(
      () =>
          messenger.setMockMethodCallHandler(AndroidUpdateBridge.channel, null),
    );

    for (final (name, platform, size, theme, scale, reduce) in [
      (
        'windows',
        TargetPlatform.windows,
        const Size(1280, 760),
        ThemeMode.dark,
        1.0,
        false,
      ),
      if (!_captureSettings)
        (
          'android',
          TargetPlatform.android,
          const Size(390, 844),
          ThemeMode.light,
          1.0,
          false,
        ),
      (
        'android-compact',
        TargetPlatform.android,
        const Size(320, 568),
        ThemeMode.dark,
        1.3,
        true,
      ),
    ]) {
      final mobile = platform == TargetPlatform.android;
      debugDefaultTargetPlatformOverride = platform;
      tester.view.physicalSize = size;
      tester.view.padding = mobile
          ? const FakeViewPadding(top: 24, bottom: 24)
          : const FakeViewPadding();
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();

      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('weekglass-startup-render-'),
      ))!;
      final feed = WindowsStartupFeed()..version = '0.20.21';
      final service = mobile
          ? UpdateService.androidForTesting(
              updateRoot: root,
              metadata: (path, limit, {cache}) async {
                expect(path, 'channels/android-arm64/stable.json');
                final payload = jsonDecode(
                  utf8.decode(feed.channel),
                ) as Map<String, dynamic>;
                payload['platform'] = 'android-arm64';
                final descriptor = payload['manifest'] as Map<String, dynamic>;
                descriptor['path'] = (descriptor['path'] as String)
                    .replaceFirst('windows-x64', 'android-arm64');
                return utf8.encode(jsonEncode(payload));
              },
              verifyEnvelope: feed.verify,
            )
          : UpdateService.windowsForTesting(
              updateRoot: root,
              installation: root,
              metadata: feed.metadata,
              verifyEnvelope: feed.verify,
              launchInstaller: (_, _) async =>
                  fail('Do not launch an installer'),
            );
      final controller = PlannerController(
        repository: MemoryImportRepo(),
        timeZoneId: 'Asia/Shanghai',
      );
      await controller.initialize();
      if (mobile) controller.setView(PlannerView.threeDays);
      controller.setAnchorDate(DateTime(2026, 11, 16));
      await controller.saveEvents([
        for (final (date, hour, title, color) in [
          (16, 8, '晨间阅读', EventColor.mistBlue),
          (16, 11, '专题研讨', EventColor.sageGreen),
          (17, 9, '整理研究笔记', EventColor.rose),
          (17, 13, '机器人实验', EventColor.lavender),
          (18, 9, '设计讨论', EventColor.softPeach),
          (19, 10, '小组报告', EventColor.warmSand),
          (20, 8, '复习本周课表', EventColor.mistBlue),
        ])
          CalendarEvent.timed(
            id: 'startup-fixture-$date-$hour',
            title: title,
            color: color,
            startLocal: DateTime(2026, 11, date, hour),
            endLocal: DateTime(2026, 11, date, hour + 1, 30),
            timeZoneId: 'Asia/Shanghai',
          ),
      ]);
      final key = GlobalKey();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            navigatorKey: navigator,
            debugShowCheckedModeBanner: false,
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: WeekGlassTheme.light(),
            darkTheme: WeekGlassTheme.dark(),
            themeMode: theme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: reduce,
                alwaysUse24HourFormat: true,
              ),
              child: LiquidGlassScope(
                mobile: mobile,
                motion: true,
                child: child!,
              ),
            ),
            home: StartupUpdatePrompt(
              service: service,
              child: mobile
                  ? MobilePlannerScreen(controller: controller)
                  : PlannerScreen(controller: controller),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => precacheImage(
          const AssetImage('assets/brand/atmosphere.png'),
          tester.element(find.byType(Scaffold).first),
        ),
      );
      Future<void> advance() async {
        await tester.pump();
        await tester.pump();
        for (var i = 0; i < 16; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
      }

      if (_captureSettings) {
        unawaited(
          openPlannerSettings(
            navigator.currentContext!,
            controller,
            updateService: service,
          ),
        );
        await advance();
        await tester.tap(find.text(mobile ? '软件更新' : '软件与通知'));
        await advance();
      }
      await tester.runAsync(() => service.checkOnStartup());
      await advance();
      for (final label in [
        _captureSettings ? '发现新版本 ${feed.version}' : '发现新版本',
        '跳过此版本',
        '立即更新',
      ]) {
        final finder = find.text(label);
        expect(finder.hitTestable(), findsOneWidget);
        final rect = tester.getRect(finder);
        expect(rect.left, greaterThan(0));
        expect(rect.right, lessThan(size.width));
        expect(rect.bottom, lessThan(size.height));
      }
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final render =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await render.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final suffix = _captureSettings ? '-settings' : '';
        final file = File('$_output/$name$suffix.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });

      await tester.pumpWidget(const SizedBox.shrink());
      service.dispose();
      controller.dispose();
      await tester.runAsync(() => root.delete(recursive: true));
    }
    debugDefaultTargetPlatformOverride = null;
    debugDisableShadows = shadowsDisabled;
  });
}
