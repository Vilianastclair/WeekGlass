import 'dart:io';
import 'dart:ui' show ImageByteFormat, PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:weekglass/features/planner/glass_event_card.dart';
import 'package:weekglass/main.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

import 'mobile_planner_test.dart' show mobileApp;
import 'whu_import_test.dart' show MemoryImportRepo;

void main() {
  Future<PlannerController> mount(
    WidgetTester tester, {
    double width = 1800,
    bool adjacent = false,
    bool mobile = false,
    bool compareDurations = false,
    GlobalKey? captureKey,
  }) async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await initializeDateFormatting('zh_CN');
    tester.view.physicalSize = Size(width, mobile ? 844 : 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = PlannerController(
      repository: MemoryImportRepo(),
      timeZoneId: 'Asia/Shanghai',
    );
    await c.initialize();
    c.setAnchorDate(DateTime(2026, 11, 3));
    if (mobile) c.setView(PlannerView.threeDays);
    if (captureKey != null) {
      c.previewAppearance(
        skin: c.skin,
        themeMode: ThemeMode.light,
        glassMotion: false,
      );
    }
    final intervals = adjacent ? [(0, 1), (1, 3), (3, 8)] : [(0, 1)];
    await c.saveEvents([
      for (var i = 0; i < intervals.length; i++)
        CalendarEvent.timed(
          id: 'tiny-$i',
          title: width < 1000 || captureKey != null
              ? '一个很长但是必须能查看完整名称的日程'
              : '洗漱',
          notes: '备注在标题和时间下方',
          startLocal: DateTime(2026, 11, 3, 9, intervals[i].$1),
          endLocal: DateTime(2026, 11, 3, 9, intervals[i].$2),
          timeZoneId: 'Asia/Shanghai',
          color: EventColor.values[i],
        ),
      if (compareDurations || captureKey != null)
        for (final day in [4, 5])
          for (final minutes in [30, 50])
            CalendarEvent.timed(
              id: 'density-$minutes-$day',
              title: day == 4 ? '阅读' : '准备课程并整理这个月的全部课堂笔记',
              startLocal: DateTime(2026, 11, day, minutes == 30 ? 10 : 11),
              endLocal: DateTime(
                2026,
                11,
                day,
                minutes == 30 ? 10 : 11,
                minutes,
              ),
              timeZoneId: 'Asia/Shanghai',
              color: EventColor.sageGreen,
            ),
    ]);
    final app = mobile ? mobileApp(c) : WeekGlassApp(controller: c);
    await tester.pumpWidget(
      captureKey == null ? app : RepaintBoundary(key: captureKey, child: app),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    });
    return c;
  }

  testWidgets(
    'one-minute event stays blank even in a wide column without changing duration',
    (tester) async {
      final c = await mount(tester);
      final card = tester.getRect(find.byKey(const ValueKey('event-tiny-0')));
      expect(card.height, inInclusiveRange(17, 20));
      expect(find.byKey(const ValueKey('card-title-tiny-0')), findsNothing);
      expect(find.byKey(const ValueKey('card-time-tiny-0')), findsNothing);
      expect(c.events.single.duration, const Duration(minutes: 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('equal 30- and 50-minute cards follow the same text density', (
    tester,
  ) async {
    await mount(tester, width: 1266, compareDurations: true);
    for (final minutes in [30, 50]) {
      final heights = [
        for (final day in [4, 5])
          tester
              .getSize(find.byKey(ValueKey('event-density-$minutes-$day')))
              .height,
      ];
      expect(heights.first, closeTo(heights.last, .01));
      expect(heights.first, minutes == 30 ? lessThan(24) : greaterThan(24));
      for (final day in [4, 5]) {
        expect(
          find.byKey(ValueKey('card-title-density-$minutes-$day')),
          minutes == 30 ? findsNothing : findsOneWidget,
        );
      }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('card width and text scale control the title and time slots', (
    tester,
  ) async {
    const titles = ['阅读', '准备课程并整理这个月的全部课堂笔记'];
    Future<void> pumpCards({
      required double width,
      double height = 30,
      double scale = 1,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < titles.length; i++)
                  SizedBox(
                    width: width,
                    height: height,
                    child: GlassEventCard(
                      key: ValueKey('sample-$i'),
                      event: CalendarEvent.timed(
                        id: 'sample-$i',
                        title: titles[i],
                        startLocal: DateTime(
                          2026,
                          11,
                          3,
                          i == 0 ? 9 : 16,
                          i == 0 ? 1 : 48,
                        ),
                        endLocal: DateTime(
                          2026,
                          11,
                          3,
                          i == 0 ? 9 : 17,
                          i == 0 ? 51 : 38,
                        ),
                        timeZoneId: 'Asia/Shanghai',
                      ),
                      selected: false,
                      onTap: () {},
                      onMoveStart: (_) {},
                      onMoveUpdate: (_) {},
                      onMoveEnd: () {},
                      onCancel: () {},
                      onResizeStart: (_, _) {},
                      onResizeUpdate: (_) {},
                      onResizeEnd: () {},
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Finder title(int index) => find.byKey(ValueKey('card-title-sample-$index'));
    Finder time(int index) => find.byKey(ValueKey('card-time-sample-$index'));

    await pumpCards(width: 260);
    for (var i = 0; i < titles.length; i++) {
      expect(
        tester.getCenter(title(i)).dy,
        closeTo(tester.getCenter(time(i)).dy, 1),
      );
      expect(
        tester.renderObject<RenderParagraph>(title(i)).didExceedMaxLines,
        i == 1,
      );
      expect(
        tester.renderObject<RenderParagraph>(time(i)).didExceedMaxLines,
        isFalse,
      );
    }

    final timeWidth = tester.getSize(time(0)).width;
    // The time itself fits here, but would leave less than four title glyphs.
    await pumpCards(width: timeWidth + 54);
    for (var i = 0; i < titles.length; i++) {
      expect(title(i), findsOneWidget);
      expect(time(i), findsNothing);
    }
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(790, 20));
    await mouse.moveTo(tester.getCenter(title(0)));
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('hover-title-sample-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('hover-time-sample-0')), findsOneWidget);
    await mouse.removePointer();

    for (final (width, scale) in [(30.0, 1.0), (260.0, 1.8)]) {
      await pumpCards(width: width, scale: scale);
      for (var i = 0; i < titles.length; i++) {
        expect(title(i), findsNothing);
        expect(time(i), findsNothing);
      }
    }
    await pumpCards(width: 260, height: 70);
    for (var i = 0; i < titles.length; i++) {
      expect(
        tester.getRect(title(i)).bottom,
        lessThan(tester.getRect(time(i)).top),
      );
    }
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'adjacent tiny events stay independently selectable and do not overlap visually',
    (tester) async {
      await mount(tester, adjacent: true);
      final cards = [
        for (var i = 0; i < 3; i++)
          tester.getRect(find.byKey(ValueKey('event-tiny-$i'))),
      ];
      for (var i = 0; i < cards.length; i++) {
        for (var j = i + 1; j < cards.length; j++) {
          expect(cards[i].overlaps(cards[j]), isFalse);
        }
      }
      expect(find.byKey(const ValueKey('card-title-tiny-1')), findsNothing);
      expect(find.byKey(const ValueKey('card-time-tiny-1')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('event-tiny-1')));
      await tester.pumpAndSettle();
      expect(find.textContaining('09:01 — 09:03'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'narrow short card is blank and exposes complete hover and semantics',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await mount(tester, width: 800);
      final card = tester.getRect(find.byKey(const ValueKey('event-tiny-0')));
      expect(find.byKey(const ValueKey('card-title-tiny-0')), findsNothing);
      expect(find.byKey(const ValueKey('card-time-tiny-0')), findsNothing);
      expect(
        find.bySemanticsLabel('一个很长但是必须能查看完整名称的日程，09:00 – 09:01'),
        findsOneWidget,
      );
      semantics.dispose();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(790, 20));
      await mouse.moveTo(card.center);
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      final title = tester.getRect(
        find.byKey(const ValueKey('hover-title-tiny-0')),
      );
      final time = tester.getRect(
        find.byKey(const ValueKey('hover-time-tiny-0')),
      );
      final notes = tester.getRect(find.text('备注在标题和时间下方'));
      expect(title.bottom, lessThan(time.top));
      expect(time.bottom, lessThan(notes.top));
      final popover = tester.getRect(
        find.byKey(const ValueKey('notes-popover-tiny-0')),
      );
      expect(popover.overlaps(card), isFalse);
      expect(find.text('09:00 – 09:01'), findsOneWidget);
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('blank short card opens its full details on touch', (
    tester,
  ) async {
    await mount(tester, width: 390, mobile: true);
    expect(find.byKey(const ValueKey('card-title-tiny-0')), findsNothing);
    expect(find.byKey(const ValueKey('card-time-tiny-0')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('event-tiny-0')));
    await tester.pumpAndSettle();
    expect(find.text('一个很长但是必须能查看完整名称的日程'), findsOneWidget);
    expect(find.textContaining('09:00 — 09:01'), findsOneWidget);
    expect(find.text('备注在标题和时间下方'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  final output = Platform.environment['WG_SHORT_EVENT_CAPTURE_DIR'];
  if (output != null) {
    testWidgets('capture short events and hover details', (tester) async {
      debugDisableShadows = false;
      addTearDown(() => debugDisableShadows = true);
      await tester.runAsync(() async {
        for (final entry in {
          'WeekGlassSans': 'assets/fonts/NotoSansSC-Variable.ttf',
          'MaterialIcons':
              '${Platform.environment['FLUTTER_ROOT']!}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          final loader = FontLoader(entry.key);
          loader.addFont(
            File(entry.value).readAsBytes().then(ByteData.sublistView),
          );
          await loader.load();
        }
        await LiquidGlass.load();
        await Directory(output).create(recursive: true);
      });
      final captureKey = GlobalKey();
      await mount(tester, width: 1266, adjacent: true, captureKey: captureKey);
      expect(find.byKey(const ValueKey('card-title-tiny-0')), findsNothing);
      expect(find.byKey(const ValueKey('card-title-tiny-1')), findsNothing);
      expect(
        find.byKey(const ValueKey('card-title-density-30-4')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('card-title-density-30-5')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('card-title-density-50-4')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('card-title-density-50-5')),
        findsOneWidget,
      );
      final card = tester.getRect(find.byKey(const ValueKey('event-tiny-0')));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(960, 20));
      await mouse.moveTo(card.center);
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('hover-title-tiny-0')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary =
            captureKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final png = await image.toByteData(format: ImageByteFormat.png);
        await File('$output/short-event-empty-and-hover.png')
            .writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      });
      await mouse.removePointer();
      debugDisableShadows = true;
    });
  }
}
