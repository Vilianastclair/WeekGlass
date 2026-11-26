import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weekglass/features/planner/glass_event_card.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass_data/weekglass_data.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

import 'mobile_planner_test.dart' show mobileApp;

void main() {
  LiveTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  testWidgets(
    'iPhone week editor retains a Sunday event after reopening SQLite',
    (tester) async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      await initializeDateFormatting('zh_CN');
      const size = Size(390, 844);
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetPadding);
      final temp = Directory.systemTemp.createTempSync('weekglass-ios-week-');
      addTearDown(() => temp.deleteSync(recursive: true));
      sqfliteFfiInit();
      final day = DateTime(2026, 11, 29);
      Future<PlannerController> open() async {
        final c = PlannerController(
          repository: SqliteEventRepository(
            factory: databaseFactoryFfiNoIsolate,
            databasePath: '${temp.path}/weekglass.sqlite3',
          ),
          timeZoneId: 'Asia/Shanghai',
        );
        addTearDown(c.repository.close);
        await c.initialize();
        c.setAnchorDate(day);
        return c;
      }

      const capture = String.fromEnvironment('WG_IOS_WIDGET_CAPTURE');
      final frame = GlobalKey();
      if (capture.isNotEmpty) {
        await tester.runAsync(() async {
          for (final (family, path) in [
            ('WeekGlassSans', 'assets/fonts/NotoSansSC-Variable.ttf'),
            ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
          ]) {
            await (FontLoader(family)..addFont(rootBundle.load(path))).load();
          }
          await LiquidGlass.load();
        });
      }
      var c = await open();
      Future<void> showWeek() async {
        await tester.pumpWidget(
          RepaintBoundary(key: frame, child: mobileApp(c)),
        );
        await tester.pumpAndSettle();
        expect(tester.getSize(find.byKey(frame)), size);
        expect(c.view, PlannerView.week);
        expect(c.visibleDays, hasLength(7));
        final week = tester
            .getSemantics(find.bySemanticsLabel('整周'))
            .getSemanticsData();
        expect(week.flagsCollection.isSelected, ui.Tristate.isTrue);
        expect(week.flagsCollection.isButton, isTrue);
        expect(find.bySemanticsLabel('新建日程'), findsOneWidget);
        expect(find.text('课表'), findsNothing);
      }

      Future<void> close() async {
        await tester.pumpWidget(const SizedBox.shrink());
        c.dispose();
        await c.repository.close();
      }

      await showWeek();
      await tester.tap(find.bySemanticsLabel('新建日程'));
      await tester.pumpAndSettle();
      const title = '排练前碰面';
      await tester.enterText(find.byType(TextField).first, title);
      {
        final saved = Completer<void>();
        void changed() {
          if (c.events.isNotEmpty && !saved.isCompleted) saved.complete();
        }

        c.addListener(changed);
        try {
          await tester.tap(find.text('保存日程'));
          await saved.future.timeout(const Duration(seconds: 10));
        } finally {
          c.removeListener(changed);
        }
      }
      await tester.pumpAndSettle();
      expect(c.events.single.title, title);
      final id = c.events.single.id;
      expect(c.events.single.startLocal, DateTime(2026, 11, 29, 9));
      expect(c.events.single.endLocal, DateTime(2026, 11, 29, 10));
      await close();
      c = await open();
      await showWeek();
      expect(c.events.single.id, id);
      expect(find.byType(GlassEventCard).hitTestable(), findsOneWidget);
      expect(find.bySemanticsLabel('$title，09:00 – 10:00'), findsOneWidget);
      if (capture.isNotEmpty) {
        await tester.runAsync(() async {
          final boundary =
              frame.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1.5);
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!;
          File(capture).writeAsBytesSync(bytes.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.byType(GlassEventCard));
      await tester.pumpAndSettle();
      expect(find.text(title).hitTestable(), findsOneWidget);
      expect(find.text('11月29日 星期日\n09:00 — 10:00'), findsOneWidget);
      await close();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
