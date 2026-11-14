import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:weekglass/features/mobile/mobile_press_feedback.dart';
import 'package:weekglass/features/planner/calendar_grid.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

import 'mobile_planner_test.dart' show mobileApp;
import 'whu_import_test.dart' show MemoryImportRepo;

class _CountingRepo extends MemoryImportRepo {
  int writes = 0;
  @override
  Future<void> saveBatch(List<CalendarEvent> values) async {
    writes++;
    await super.saveBatch(values);
  }
}

void main() {
  Future<({PlannerController controller, _CountingRepo repo})> mount(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    bool reduced = false,
    double textScale = 1,
  }) async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await initializeDateFormatting('zh_CN');
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures(disableAnimations: reduced);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final repo = _CountingRepo();
    final c = PlannerController(repository: repo, timeZoneId: 'Asia/Shanghai');
    await c.initialize();
    c.setView(PlannerView.threeDays);
    c.setAnchorDate(DateTime(2026, 11, 2));
    await c.saveEvent(
      CalendarEvent.timed(
        id: 'touch',
        title: '示例课程',
        notes: '只供触控测试的模拟数据',
        startLocal: DateTime(2026, 11, 2, 8, 7),
        endLocal: DateTime(2026, 11, 2, 9, 2),
        timeZoneId: 'Asia/Shanghai',
      ),
    );
    await tester.pumpWidget(mobileApp(c, textScale: textScale));
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    });
    return (controller: c, repo: repo);
  }

  Finder card() => find.byKey(const ValueKey('event-touch'));
  Finder preview() => find.byKey(const ValueKey('preview-touch'));
  double pageOffset(WidgetTester tester) => tester
      .widget<Transform>(
        find.byKey(const ValueKey('mobile-calendar-translation')),
      )
      .transform
      .storage[12];

  testWidgets(
    'touch scrolling and blank taps never create; only held selection opens the editor',
    (tester) async {
      final f = await mount(tester);
      final grid = tester.getRect(find.byType(CalendarGrid));
      final blank = Offset(grid.right - 50, grid.top + 270);
      final writes = f.repo.writes;
      await tester.tapAt(blank);
      await tester.pumpAndSettle();
      expect(find.text('新建日程'), findsNothing);
      final clockY = tester.getTopLeft(find.byKey(const ValueKey('time-8'))).dy;
      final scroll = await tester.startGesture(blank);
      await tester.pump(const Duration(milliseconds: 80));
      await scroll.moveBy(const Offset(9, -30));
      await tester.pump(const Duration(milliseconds: 20));
      await scroll.moveBy(const Offset(0, -110));
      await tester.pump(const Duration(milliseconds: 650));
      await scroll.up();
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('time-8'))).dy,
        lessThan(clockY - 80),
      );
      expect(find.byKey(const ValueKey('creation-live')), findsNothing);
      expect(find.text('新建日程'), findsNothing);
      expect(f.repo.writes, writes);
      expect(f.controller.anchorDate, DateTime(2026, 11, 2));
      final hold = await tester.startGesture(blank);
      await tester.pump(const Duration(milliseconds: 600));
      await hold.moveBy(const Offset(0, 40));
      await tester.pump();
      expect(find.byKey(const ValueKey('creation-live')), findsOneWidget);
      await hold.up();
      await tester.pumpAndSettle();
      expect(find.text('新建日程'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(f.repo.writes, writes);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'paging follows the finger, shows actual adjacent dates and cancels without navigation',
    (tester) async {
      final f = await mount(tester);
      final grid = tester.getRect(find.byType(CalendarGrid));
      final origin = Offset(grid.center.dx, grid.top + 250);
      final swipe = await tester.startGesture(origin);
      await swipe.moveBy(const Offset(-150, 0));
      await tester.pump();
      expect(pageOffset(tester), closeTo(-150, 1));
      expect(find.byType(CalendarGrid), findsNWidgets(2));
      final adjacent = tester.widget<CalendarGrid>(
        find.byKey(const ValueKey('mobile-adjacent-1')),
      );
      expect(adjacent.visibleDays!.first, DateTime(2026, 11, 5));
      expect(f.controller.anchorDate, DateTime(2026, 11, 2));
      await swipe.cancel();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(pageOffset(tester), inExclusiveRange(-150, 0));
      await tester.pumpAndSettle();
      expect(pageOffset(tester), 0);
      expect(find.byType(CalendarGrid), findsOneWidget);
      expect(f.controller.anchorDate, DateTime(2026, 11, 2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'committed swipe and header arrows preserve vertical browsing position',
    (tester) async {
      final f = await mount(tester);
      final grid = tester.getRect(find.byType(CalendarGrid));
      await tester.dragFrom(
        Offset(grid.right - 50, grid.top + 270),
        const Offset(0, -180),
      );
      await tester.pumpAndSettle();
      final clockY = tester
          .getTopLeft(find.byKey(const ValueKey('time-12')))
          .dy;
      await tester.dragFrom(
        Offset(grid.right - 50, grid.top + 270),
        const Offset(-170, 0),
      );
      await tester.pumpAndSettle();
      expect(f.controller.anchorDate, DateTime(2026, 11, 5));
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('time-12'))).dy,
        closeTo(clockY, .01),
      );
      await tester.tap(find.byKey(const ValueKey('mobile-previous-period')));
      await tester.pumpAndSettle();
      expect(f.controller.anchorDate, DateTime(2026, 11, 2));
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('time-12'))).dy,
        closeTo(clockY, .01),
      );
      expect(find.byType(CalendarGrid), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'held event owns horizontal movement and cancellation restores its exact original without writes',
    (tester) async {
      final f = await mount(tester);
      final original = f.controller.events.single;
      final bounds = tester.getRect(card());
      final writes = f.repo.writes;
      final drag = await tester.startGesture(bounds.center);
      await tester.pump(const Duration(milliseconds: 600));
      await drag.moveBy(const Offset(110, 56));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(preview()).dx, greaterThan(bounds.left + 70));
      expect(f.controller.anchorDate, DateTime(2026, 11, 2));
      expect(pageOffset(tester), 0);
      await drag.cancel();
      await tester.pump();
      expect(preview(), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 70));
      expect(
        tester.getTopLeft(preview()).dx,
        inExclusiveRange(bounds.left, bounds.left + 110),
      );
      await tester.pumpAndSettle();
      expect(preview(), findsNothing);
      expect(tester.getRect(card()), bounds);
      expect(f.controller.events.single.startLocal, original.startLocal);
      expect(f.controller.events.single.endLocal, original.endLocal);
      expect(f.repo.writes, writes);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'moving away and back preserves a non-quarter-hour original on release',
    (tester) async {
      final f = await mount(tester);
      final original = f.controller.events.single;
      final origin = tester.getCenter(card());
      final writes = f.repo.writes;
      final drag = await tester.startGesture(origin);
      await tester.pump(const Duration(milliseconds: 600));
      await drag.moveBy(const Offset(100, 56));
      await tester.pump();
      await drag.moveTo(origin + const Offset(1, 1));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      expect(f.controller.events.single.startLocal, original.startLocal);
      expect(f.controller.events.single.endLocal, original.endLocal);
      expect(f.repo.writes, writes);
      expect(preview(), findsNothing);
    },
  );

  testWidgets(
    'reduced motion keeps paging and dragging usable without translation, press scale or return animation',
    (tester) async {
      final f = await mount(tester, reduced: true);
      final pressed = await tester.startGesture(tester.getCenter(card()));
      await tester.pump(const Duration(milliseconds: 100));
      final scale = tester.widget<AnimatedScale>(
        find.descendant(
          of: find.byKey(const ValueKey('mobile-card-press-touch')),
          matching: find.byType(AnimatedScale),
        ),
      );
      expect(scale.scale, 1);
      expect(scale.duration, Duration.zero);
      await tester.pump(const Duration(milliseconds: 500));
      await pressed.moveBy(const Offset(80, 56));
      await tester.pump();
      await pressed.cancel();
      await tester.pump();
      expect(preview(), findsNothing);
      final grid = tester.getRect(find.byType(CalendarGrid));
      final swipe = await tester.startGesture(
        Offset(grid.center.dx, grid.top + 260),
      );
      await swipe.moveBy(const Offset(-150, 0));
      await tester.pump();
      expect(pageOffset(tester), 0);
      expect(find.byType(CalendarGrid), findsOneWidget);
      await swipe.up();
      await tester.pump();
      expect(f.controller.anchorDate, DateTime(2026, 11, 5));
      expect(pageOffset(tester), 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'touch feedback confirms hold and snap changes, never each pointer update',
    (tester) async {
      final f = await mount(tester);
      final feedback = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            feedback.add(call.arguments);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final drag = await tester.startGesture(tester.getCenter(card()));
      await tester.pump(const Duration(milliseconds: 600));
      expect(feedback, ['HapticFeedbackType.lightImpact']);
      await tester.pump(const Duration(milliseconds: 80));
      await drag.moveBy(const Offset(0, 60));
      await tester.pump();
      expect(
        feedback
            .where((value) => value == 'HapticFeedbackType.selectionClick')
            .length,
        1,
      );
      for (var i = 0; i < 5; i++) {
        await drag.moveBy(const Offset(0, .2));
        await tester.pump(const Duration(milliseconds: 8));
      }
      expect(feedback.length, 2);
      await drag.up();
      await tester.pumpAndSettle();
      expect(feedback.last, 'HapticFeedbackType.lightImpact');
      expect(feedback.length, 3);
      expect(
        f.controller.events.single.startLocal,
        DateTime(2026, 11, 2, 9, 15),
      );
    },
  );

  testWidgets('reduced-motion details and editor use immediate routes', (
    tester,
  ) async {
    await mount(tester, reduced: true);
    await tester.tap(card());
    await tester.pump();
    final detailsRoute = ModalRoute.of(tester.element(find.text('调整')))!;
    expect(detailsRoute.transitionDuration, Duration.zero);
    expect(detailsRoute.reverseTransitionDuration, Duration.zero);
    await tester.tap(find.text('调整'));
    await tester.pumpAndSettle();
    final editorRoute = ModalRoute.of(tester.element(find.text('取消')))!;
    expect(editorRoute.transitionDuration, Duration.zero);
    expect(editorRoute.reverseTransitionDuration, Duration.zero);
    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(find.byType(CalendarGrid), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(320, 568), const Size(390, 844)]) {
    testWidgets('large-text phone touch targets and semantics fit $size', (
      tester,
    ) async {
      await mount(tester, size: size, textScale: 1.3);
      final semantics = tester.ensureSemantics();
      try {
        await tester.pump();
        expect(find.bySemanticsLabel(RegExp('示例课程')), findsOneWidget);
        expect(find.byType(MobilePressFeedback), findsWidgets);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }
}
