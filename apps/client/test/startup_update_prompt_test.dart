import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:weekglass/app/event_reminders.dart';
import 'package:weekglass/features/planner/event_editor_dialog.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass/features/planner/planner_settings_dialog.dart';
import 'package:weekglass/features/updates/startup_update_prompt.dart';
import 'package:weekglass/features/updates/update_service.dart';
import 'package:weekglass/features/updates/update_settings_tile.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

import 'support/windows_startup_feed.dart';
import 'whu_import_test.dart' show MemoryImportRepo;

void main() {
  late Directory temp;
  late Directory updateRoot;
  late Directory installation;
  late MemoryImportRepo repository;
  late PlannerController controller;
  late WindowsStartupFeed feed;
  late UpdateService service;
  late List<String> handoff;
  final plannerKey = GlobalKey();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await initializeDateFormatting('zh_CN');
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    repository = MemoryImportRepo();
    controller = PlannerController(
      repository: repository,
      timeZoneId: 'Asia/Shanghai',
    );
    await controller.initialize();
    feed = WindowsStartupFeed();
    handoff = [];
    temp = await Directory.systemTemp.createTemp('weekglass-update-prompt-');
    updateRoot = await Directory(p.join(temp.path, 'updates')).create();
    installation = await Directory(p.join(temp.path, 'install')).create();
    await File(p.join(installation.path, 'weekglass.exe'))
        .writeAsBytes(feed.executable);
    await File(p.join(installation.path, 'weekglass_updater.exe'))
        .writeAsBytes(feed.helper);
  });

  tearDown(() async {
    service.dispose();
    controller.dispose();
    await temp.delete(recursive: true);
  });

  UpdateService client({UpdateMetadata? metadata}) =>
      UpdateService.windowsForTesting(
          updateRoot: updateRoot,
          installation: installation,
          metadata: metadata ?? feed.metadata,
          verifyEnvelope: feed.verify,
          launchInstaller: (_, _) async => handoff.add('launch'),
        )
        ..beforeInstall = () async {
          await controller.waitForPendingWrites();
          final events = await repository.getAllEvents();
          handoff.add('save: ${events.map((event) => event.title).join(', ')}');
        };

  Future<void> pumpApp(
    WidgetTester tester, {
    bool reducedMotion = false,
    TargetPlatform? platform,
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: WeekGlassTheme.light().copyWith(platform: platform),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: reducedMotion),
          child: child!,
        ),
        home: StartupUpdatePrompt(
          service: service,
          child: Scaffold(
            key: plannerKey,
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Builder(
                    builder: (context) => TextButton(
                      onPressed: () => openEventEditor(
                        context,
                        controller: controller,
                        date: DateTime(2026, 11, 17),
                      ),
                      child: const Text('新建日程'),
                    ),
                  ),
                  Builder(
                    builder: (context) => TextButton(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => AlertDialog(
                          content: UpdateSettingsTile(service: service),
                        ),
                      ),
                      child: const Text('设置'),
                    ),
                  ),
                  Builder(
                    builder: (context) => TextButton(
                      onPressed: () => openPlannerSettings(
                        context,
                        controller,
                        updateService: service,
                      ),
                      child: const Text('完整设置'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> waitFor(WidgetTester tester, bool Function() condition) async {
    for (var frame = 0; frame < 150 && !condition(); frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
    expect(condition(), isTrue);
    await tester.pumpAndSettle();
  }

  Future<void> checkOnLaunch(WidgetTester tester) async {
    await tester.runAsync(() => service.checkOnStartup());
    await tester.pumpAndSettle();
  }

  Future<void> typeEvent(WidgetTester tester, String title) async {
    await tester.tap(find.text('新建日程'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, title);
  }

  Future<void> saveEvent(WidgetTester tester) async {
    await tester.tap(find.text('保存日程'));
    await tester.pumpAndSettle();
  }

  final title = find.text('发现新版本');
  final update = find.text('立即更新');
  final skip = find.text('跳过此版本');

  testWidgets('startup and automatic restart wait for the real event editor', (
    tester,
  ) async {
    final manifest = Completer<List<int>>();
    service = client(
      metadata: (path, limit, {cache}) => path == feed.manifestPath
          ? manifest.future
          : feed.metadata(path, limit),
    );
    await pumpApp(tester);
    await typeEvent(tester, '编辑中的第一条日程');
    await checkOnLaunch(tester);
    expect(title, findsNothing);
    expect(find.text('编辑中的第一条日程'), findsOneWidget);
    expect(tester.testTextInput.isVisible, isTrue);
    await saveEvent(tester);
    expect(title, findsOneWidget);

    await tester.tap(update);
    await tester.pumpAndSettle();
    expect(title, findsNothing);
    expect(service.busy, isTrue);
    await typeEvent(tester, '编辑中的第二条日程');
    manifest.complete(feed.manifest);
    await waitFor(tester, () => service.ready && !service.busy);
    expect(handoff, isEmpty);
    expect(find.text('编辑中的第二条日程'), findsOneWidget);
    expect(title, findsNothing);

    await saveEvent(tester);
    await waitFor(tester, () => handoff.contains('launch') && !service.busy);
    expect(handoff.first, contains('编辑中的第一条日程'));
    expect(handoff.first, contains('编辑中的第二条日程'));
    expect(handoff, hasLength(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'the glass dialog has two actions, and manual Settings bypasses skip',
    (tester) async {
      service = client();
      await pumpApp(tester);
      await checkOnLaunch(tester);
      expect(title, findsOneWidget);
      expect(find.text('WeekGlass ${feed.version} 已发布，是否更新？'), findsOneWidget);
      final dialog = find.byType(GlassAlertDialog);
      expect(dialog, findsOneWidget);
      expect(
        find.descendant(of: dialog, matching: find.byType(TextButton)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dialog, matching: find.byType(FilledButton)),
        findsOneWidget,
      );
      expect(update.hitTestable(), findsOneWidget);
      expect(skip.hitTestable(), findsOneWidget);

      await tester.tapAt(const Offset(5, 5));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(title, findsOneWidget);

      await tester.tap(skip);
      await tester.pumpAndSettle();
      expect(title, findsNothing);
      expect(service.available, isNull);
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已跳过版本'), findsOneWidget);
      await tester.tap(find.text('检查更新'));
      await waitFor(tester, () => service.available != null && !service.busy);
      expect(find.text('下载更新'), findsOneWidget);
      expect(dialog, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'inactive startup defers one prompt and reduces both route motions',
    (tester) async {
      service = client();
      await pumpApp(tester, reducedMotion: true);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await checkOnLaunch(tester);
      expect(service.startupOffer, isNotNull);
      expect(title, findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect(title, findsOneWidget);
      final route = ModalRoute.of(
        tester.element(find.byType(GlassAlertDialog)),
      )!;
      expect(route.transitionDuration, Duration.zero);
      expect(route.reverseTransitionDuration, Duration.zero);
      await tester.tap(skip);
      await tester.pumpAndSettle();
      expect(title, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('a pointer gesture is not interrupted by the startup offer', (
    tester,
  ) async {
    service = client();
    await pumpApp(tester);
    final gesture = await tester.startGesture(const Offset(30, 40));
    await checkOnLaunch(tester);
    expect(title, findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(title, findsOneWidget);
    expect(skip.hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'explicit Windows open handles a newer build but focus alone does not',
    (tester) async {
      final newBuild = feed.build;
      feed.build = UpdateService.currentBuild;
      feed.version = UpdateService.currentVersion;
      final reads = <String>[];
      service = client(
        metadata: (path, limit, {cache}) {
          reads.add(path);
          return feed.metadata(path, limit);
        },
      );
      final reminders = WindowsReminders(
        controller,
        onAppOpen: service.checkOnWindowsReopen,
      );
      await reminders.start();
      addTearDown(reminders.dispose);
      await pumpApp(tester);
      await checkOnLaunch(tester);
      expect(service.startupOffer, isNull);

      feed.build = newBuild;
      feed.version = '0.20.21';
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(reads, [WindowsStartupFeed.channelPath]);
      expect(title, findsNothing);

      const channel = MethodChannel('weekglass/desktop');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      Future<void> openFromWindows() async {
        await tester.runAsync(
          () => messenger.handlePlatformMessage(
            channel.name,
            channel.codec.encodeMethodCall(const MethodCall('openApp')),
            (_) {},
          ),
        );
        await tester.pumpAndSettle();
      }

      await openFromWindows();
      final offer = service.startupOffer;
      expect(offer?.build, newBuild);
      expect(title, findsOneWidget);
      await openFromWindows();
      expect(service.startupOffer, same(offer));
      expect(title, findsOneWidget);
      expect(reads, [
        WindowsStartupFeed.channelPath,
        WindowsStartupFeed.channelPath,
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
      reminders.dispose();
    },
  );

  testWidgets(
    'a hidden offer waits for focus and a pointer-free Settings dismissal',
    (tester) async {
      service = client();
      await pumpApp(tester);
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await checkOnLaunch(tester);
      expect(service.startupOffer, isNotNull);
      expect(title, findsNothing);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(title, findsNothing);
      expect(update.hitTestable(), findsOneWidget);
      expect(skip.hitTestable(), findsOneWidget);
      Navigator.of(tester.element(find.byType(UpdateSettingsTile))).pop();
      await tester.pumpAndSettle();
      expect(title, findsOneWidget);
      expect(update.hitTestable(), findsOneWidget);
      expect(skip.hitTestable(), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Settings offers the same startup choice and installs only after it closes',
    (tester) async {
      final reads = <String>[];
      service = client(
        metadata: (path, limit, {cache}) {
          reads.add(path);
          return feed.metadata(path, limit);
        },
      );
      await pumpApp(tester, platform: TargetPlatform.windows);
      await tester.tap(find.text('完整设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('软件与通知'));
      await tester.pumpAndSettle();
      await checkOnLaunch(tester);
      expect(title, findsNothing);
      expect(update.hitTestable(), findsOneWidget);
      expect(skip.hitTestable(), findsOneWidget);
      expect(find.text('下载更新'), findsNothing);
      expect(reads, [WindowsStartupFeed.channelPath]);

      await tester.tap(update);
      await waitFor(tester, () => service.ready && !service.busy);
      expect(service.startupOffer, isNull);
      expect(reads, [WindowsStartupFeed.channelPath, feed.manifestPath]);
      expect(handoff, isEmpty);
      expect(find.text('更新已就绪，当前操作完成后自动重启更新'), findsOneWidget);
      Navigator.of(tester.element(find.byType(UpdateSettingsTile))).pop();
      await waitFor(tester, () => handoff.contains('launch') && !service.busy);
      expect(title, findsNothing);
      expect(handoff, ['save: ', 'launch']);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('Settings resumes the accepted job after a connection failure', (
    tester,
  ) async {
    var offline = false;
    service = client(
      metadata: (path, limit, {cache}) {
        if (offline) throw const SocketException('offline');
        return feed.metadata(path, limit);
      },
    );
    await pumpApp(tester);
    await checkOnLaunch(tester);
    offline = true;
    await tester.tap(update);
    await waitFor(
      tester,
      () => service.canRetryAcceptedUpdate && !service.busy,
    );
    expect(title, findsNothing);
    expect(handoff, isEmpty);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.textContaining('连接中断'), findsOneWidget);
    expect(find.text('重试更新'), findsOneWidget);
    offline = false;
    await tester.tap(find.text('重试更新'));
    await waitFor(tester, () => service.ready && !service.busy);
    expect(handoff, isEmpty);
    await tester.tapAt(const Offset(5, 5));
    await waitFor(tester, () => handoff.contains('launch') && !service.busy);
    expect(title, findsNothing);
    expect(handoff, ['save: ', 'launch']);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
