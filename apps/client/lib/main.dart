import 'dart:io';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:window_manager/window_manager.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

import 'app/app_services.dart';
import 'app/event_reminders.dart';
import 'app/windows_vortex.dart';
import 'app/windows_window_motion.dart';
import 'features/planner/planner_controller.dart';
import 'features/planner/planner_screen.dart';
import 'features/mobile/mobile_planner_screen.dart';
import 'features/updates/startup_update_prompt.dart';
import 'features/updates/update_service.dart';

Future<void> main(List<String> args) => runWeekGlass(args);

Future<void> runWeekGlass(
  List<String> args, {
  Future<AppServices> Function()? createServices,
  Widget Function(Widget)? wrapApp,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  UpdateService.launchArguments = args;
  final updater = UpdateService.instance;
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'WakeUp CourseAdapter',
    ], await rootBundle.loadString('assets/licenses/CourseAdapter.txt'));
    yield LicenseEntryWithLineBreaks([
      'School directory (baoozak/timetable)',
    ], await rootBundle.loadString('assets/licenses/SchoolDirectory.txt'));
    yield LicenseEntryWithLineBreaks(
      ['WakeUp CourseAdapter 2025 archive'],
      await rootBundle.loadString(
        'assets/licenses/WakeUpCourseAdapter2024.txt',
      ),
    );
    yield LicenseEntryWithLineBreaks([
      'WakeUpSchedule school routing',
    ], await rootBundle.loadString('assets/licenses/WakeUpSchedule.txt'));
  });
  await initializeDateFormatting('zh_CN');
  await LiquidGlass.load();

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    WindowsVortex.instance.attach();
    await WindowsWindowMotion.instance.initialize();
    const options = WindowOptions(
      size: Size(1280, 760),
      minimumSize: Size(800, 560),
      center: true,
      title: 'WeekGlass 周计划',
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
      backgroundColor: Color(0xFF0A0F20),
    );
    await windowManager.waitUntilReadyToShow(options);
  }

  final services = await (createServices?.call() ?? AppServices.create());
  final controller = PlannerController(
    repository: services.eventRepository,
    timeZoneId: services.timeZoneId,
    cloud: services.cloud,
  );
  await controller.initialize();
  services.cloud.refreshPlanner = controller.reloadAfterSync;
  services.cloud.refreshSleepSchedule = controller.reloadSleepSchedule;
  updater.beforeInstall = () async {
    await controller.waitForPendingWrites();
    await services.cloud.quiesce();
    await controller.waitForPendingWrites();
    await services.eventRepository.close();
  };
  updater.afterInstallFailure = services.cloud.resume;
  updater.beforeAndroidInstall = controller.waitForPendingWrites;
  if (Platform.isWindows || Platform.isMacOS) {
    await DesktopReminders(
      controller,
      onAppOpen: Platform.isWindows ? updater.checkOnWindowsReopen : null,
    ).start(signalReady: Platform.isMacOS);
  }

  final app = WeekGlassApp(controller: controller, updater: updater);
  runApp(wrapApp?.call(app) ?? app);
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
        Widget planner = Platform.isAndroid
            ? MobilePlannerScreen(controller: controller)
            : PlannerScreen(controller: controller);
        if (Platform.isWindows) {
          planner = RepaintBoundary(
            key: WindowsVortex.instance.frameKey,
            child: planner,
          );
        }
        final service = updater;
        return MaterialApp(
          title: "Viliana's WeekGlass",
          debugShowCheckedModeBanner: false,
          navigatorObservers: [if (Platform.isWindows) WindowsVortex.instance],
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
