import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:window_manager/window_manager.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

import 'app/app_services.dart';
import 'app/event_reminders.dart';
import 'features/planner/planner_controller.dart';
import 'features/planner/planner_screen.dart';
import 'features/mobile/mobile_planner_screen.dart';
import 'features/updates/startup_update_prompt.dart';
import 'features/updates/update_service.dart';

Future<void> main(List<String> args) async {
  UpdateService.launchArguments = args;
  final updater = UpdateService.instance;
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('zh_CN');
  await LiquidGlass.load();

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1280, 760),
      minimumSize: Size(800, 560),
      center: true,
      title: 'WeekGlass 周计划',
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
      backgroundColor: Color(0xFF0A0F20),
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  final services = await AppServices.create();
  final controller = PlannerController(
    repository: services.eventRepository,
    timeZoneId: services.timeZoneId,
    cloud: services.cloud,
  );
  await controller.initialize();
  services.cloud.refreshPlanner = controller.reloadAfterSync;
  updater.beforeInstall = () async {
    await controller.waitForPendingWrites();
    await services.cloud.quiesce();
    await controller.waitForPendingWrites();
    await services.eventRepository.close();
  };
  updater.afterInstallFailure = services.cloud.resume;
  updater.beforeAndroidInstall = controller.waitForPendingWrites;
  if (Platform.isWindows) {
    await WindowsReminders(
      controller,
      onAppOpen: updater.checkOnWindowsReopen,
    ).start();
  }

  runApp(WeekGlassApp(controller: controller, updater: updater));
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(UpdateService.completePendingUpdateBoot());
    unawaited(services.cloud.initialize());
    // The local services and first planner frame are ready. Update metadata and
    // cloud recovery both run in the background.
    unawaited(updater.checkOnStartup());
  });
}

class WeekGlassApp extends StatelessWidget {
  const WeekGlassApp({super.key, required this.controller, this.updater});

  final PlannerController controller;
  final UpdateService? updater;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final planner = Platform.isAndroid
            ? MobilePlannerScreen(controller: controller)
            : PlannerScreen(controller: controller);
        final service = updater;
        return MaterialApp(
          title: "Viliana's WeekGlass",
          debugShowCheckedModeBanner: false,
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
            child: LiquidGlassScope(
              strength: controller.glassStrength,
              motion: controller.glassMotion,
              mobile: Platform.isAndroid,
              child: child!,
            ),
          ),
          theme: WeekGlassTheme.light(skin: controller.skin),
          darkTheme: WeekGlassTheme.dark(skin: controller.skin),
          themeAnimationDuration:
              WidgetsBinding
                  .instance
                  .platformDispatcher
                  .accessibilityFeatures
                  .disableAnimations
              ? Duration.zero
              : const Duration(milliseconds: 240),
          themeAnimationCurve: Curves.easeOutCubic,
          themeMode: controller.themeMode,
          home: service != null && service.supportsUpdates
              ? StartupUpdatePrompt(service: service, child: planner)
              : planner,
        );
      },
    );
  }
}
