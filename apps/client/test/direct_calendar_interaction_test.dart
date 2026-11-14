import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:weekglass/main.dart';
import 'package:weekglass/features/planner/event_editor_dialog.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass_data/weekglass_data.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

CalendarEvent task(String id, {String? notes}) => CalendarEvent.timed(
  id: id,
  title: '阅读笔记',
  notes: notes,
  startLocal: DateTime(2026, 11, 3, 9),
  endLocal: DateTime(2026, 11, 3, 11),
  timeZoneId: 'Asia/Shanghai',
);

void main() {
  setUp(() async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await initializeDateFormatting('zh_CN');
  });

  Future<PlannerController> mount(
    WidgetTester tester, {
    CalendarEvent? event,
    Size size = const Size(1000, 760),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = PlannerController(
      repository: _Repository(),
      timeZoneId: 'Asia/Shanghai',
    );
    await c.initialize();
    c.setAnchorDate(DateTime(2026, 11, 3));
    if (event != null) await c.saveEvent(event);
    await tester.pumpWidget(WeekGlassApp(controller: c));
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    });
    return c;
  }

  Finder card() => find.bySemanticsLabel('阅读笔记，09:00 – 11:00');
  Finder lane() => find.byKey(
    ValueKey('day-lane-${DateTime(2026, 11, 3).toIso8601String()}'),
  );

  testWidgets('tiny event between appointments never creates false columns', (
    tester,
  ) async {
    final c = await mount(tester, size: const Size(800, 560));
    CalendarEvent make(String id, DateTime start, DateTime end) =>
        CalendarEvent.timed(
          id: id,
          title: id,
          startLocal: start,
          endLocal: end,
          timeZoneId: 'Asia/Shanghai',
        );
    await c.saveEvents([
      make('before', DateTime(2026, 11, 3, 9), DateTime(2026, 11, 3, 10)),
      make('tiny', DateTime(2026, 11, 3, 10), DateTime(2026, 11, 3, 10, 1)),
      make('after', DateTime(2026, 11, 3, 10, 1), DateTime(2026, 11, 3, 11)),
    ]);
    await tester.pumpAndSettle();
    final before = tester.getRect(find.byKey(const ValueKey('event-before')));
    final tiny = tester.getRect(find.byKey(const ValueKey('event-tiny')));
    final after = tester.getRect(find.byKey(const ValueKey('event-after')));
    expect(after.width, before.width);
    expect(after.left, before.left);
    expect(tiny.width, after.width);
    expect(tiny.top, greaterThanOrEqualTo(before.bottom - .01));
    expect(tiny.bottom, lessThanOrEqualTo(after.top + .01));
    expect(tester.takeException(), isNull);
    await tester.tap(
      find.byKey(
        ValueKey('compact-events-${DateTime(2026, 11, 3).toIso8601String()}'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('11月3日 · 短日程'), findsOneWidget);
    await tester.tap(find.text('tiny'));
    await tester.pumpAndSettle();
    expect(find.text('调整'), findsOneWidget);
  });

  testWidgets(
    'blank click creates at the clicked time; direct drag selects both directions and end boundary',
    (tester) async {
      await mount(tester);
      final rect = tester.getRect(lane());
      Offset at(int minute) =>
          Offset(rect.center.dx, rect.top + (minute - 420) / 960 * rect.height);
      expect(find.byTooltip('添加全天日程'), findsNothing);
      await tester.tapAt(at(600));
      await tester.pumpAndSettle();
      var editor = tester.widget<EventEditorDialog>(
        find.byType(EventEditorDialog),
      );
      expect(editor.start, DateTime(2026, 11, 3, 10));
      expect(editor.end, DateTime(2026, 11, 3, 11));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      for (final range in [(720, 840), (840, 720), (1260, 1380)]) {
        final gesture = await tester.startGesture(at(range.$1));
        await gesture.moveTo(at((range.$1 + range.$2) ~/ 2));
        await tester.pump();
        await gesture.moveTo(
          at(range.$2).translate(0, range.$2 == 1380 ? -.1 : 0),
        );
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();
        editor = tester.widget<EventEditorDialog>(
          find.byType(EventEditorDialog),
        );
        final start = range.$1 < range.$2 ? range.$1 : range.$2;
        final end = range.$1 > range.$2 ? range.$1 : range.$2;
        expect(editor.start, DateTime(2026, 11, 3, 0, start));
        expect(editor.end, DateTime(2026, 11, 3, 0, end));
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'one click opens selectable notes; adjust opens editor with the same notes',
    (tester) async {
      final c = await mount(
        tester,
        event: task('notes', notes: '先读第三章。\n记下三个问题，讨论时带上笔记。'),
      );
      await tester.tap(card());
      await tester.pumpAndSettle();
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        contains('记下三个问题'),
      );
      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('编辑日程'), findsNothing);
      await tester.tap(find.text('调整'));
      await tester.pumpAndSettle();
      expect(find.byType(EventEditorDialog), findsOneWidget);
      expect(find.text('编辑日程'), findsOneWidget);
      expect(
        tester
            .widget<EventEditorDialog>(find.byType(EventEditorDialog))
            .event!
            .notes,
        contains('第三章'),
      );
      expect(find.text('删除'), findsNothing);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(c.events.single.notes, contains('三个问题'));
    },
  );

  testWidgets(
    'single deletion requires confirmation and its toast counts down and restores',
    (tester) async {
      final c = await mount(tester, event: task('delete', notes: '不可丢失的备注'));
      await tester.tap(card());
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('确认删除日程？'), findsOneWidget);
      expect(c.events, hasLength(1));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(c.events, hasLength(1));
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认删除'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(c.events, isEmpty);
      expect(find.text('撤销'), findsOneWidget);
      final bar = find.byKey(const ValueKey('notice-progress'));
      final full = tester.getSize(bar).width;
      await tester.pump(const Duration(seconds: 1));
      expect(tester.getSize(bar).width, lessThan(full));
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(c.events.single.notes, '不可丢失的备注');
      expect(find.byKey(const ValueKey('notice-progress')), findsNothing);
    },
  );

  testWidgets(
    'undo toast expires after five seconds without restoring anything',
    (tester) async {
      final c = await mount(tester, event: task('expire'));
      await tester.tap(card());
      await tester.pumpAndSettle();
      expect(find.text('暂无备注'), findsOneWidget);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认删除'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('撤销'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      expect(c.events, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('long notes fit a small viewport in both appearances', (
    tester,
  ) async {
    final c = await mount(
      tester,
      event: task('long', notes: List.filled(60, '阅读后记录思考，明天继续。').join('\n')),
      size: const Size(800, 560),
    );
    for (final theme in [ThemeMode.dark, ThemeMode.light]) {
      c.setThemeMode(theme);
      await tester.pumpAndSettle();
      await tester.tap(card());
      await tester.pumpAndSettle();
      expect(find.text('调整'), findsOneWidget);
      expect(tester.getBottomRight(find.text('调整')).dy, lessThan(560));
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
    }
  });

  testWidgets(
    'tall-card notes stay outside and allow move and both resize edges',
    (tester) async {
      final c = await mount(tester);
      final original = CalendarEvent.timed(
        id: 'tall-notes',
        title: '长时段',
        notes: '这条备注不遮挡时间块，也不接收鼠标。',
        startLocal: DateTime(2026, 11, 3, 14, 30),
        endLocal: DateTime(2026, 11, 3, 19, 22),
        timeZoneId: 'Asia/Shanghai',
      );
      for (final mode in ['move', 'top', 'bottom']) {
        await c.saveEvent(original);
        await tester.pumpAndSettle();
        final card = find.byKey(const ValueKey('event-tall-notes'));
        final rect = tester.getRect(card);
        final pointer = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await pointer.addPointer(location: Offset.zero);
        await pointer.moveTo(rect.center);
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        final notes = find.byKey(const ValueKey('notes-popover-tall-notes'));
        expect(notes, findsOneWidget);
        expect(tester.getRect(notes).overlaps(rect.inflate(12)), isFalse);
        expect(tester.getRect(notes).right, lessThanOrEqualTo(988));
        final grab = mode == 'top'
            ? Offset(rect.center.dx, rect.top + 2)
            : mode == 'bottom'
            ? Offset(rect.center.dx, rect.bottom - 2)
            : rect.center;
        await pointer.down(grab);
        await tester.pump();
        expect(notes, findsNothing);
        await pointer.moveBy(const Offset(0, 18));
        await tester.pump();
        expect(
          find.byKey(const ValueKey('preview-tall-notes')),
          findsOneWidget,
        );
        await pointer.up();
        await tester.pumpAndSettle();
        await pointer.removePointer();
        if (mode == 'move') {
          expect(
            c.events.single.startLocal.isAfter(original.startLocal),
            isTrue,
          );
          expect(c.events.single.duration, original.duration);
        } else if (mode == 'top') {
          expect(
            c.events.single.startLocal.isAfter(original.startLocal),
            isTrue,
          );
          expect(c.events.single.endLocal, original.endLocal);
        } else {
          expect(c.events.single.startLocal, original.startLocal);
          expect(c.events.single.endLocal.isAfter(original.endLocal), isTrue);
        }
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'right-edge notes use the left side and reposition after resize',
    (tester) async {
      final c = await mount(tester);
      await c.saveEvent(
        CalendarEvent.timed(
          id: 'edge-notes',
          title: '周日安排',
          notes: List.filled(30, '边缘备注').join('\n'),
          startLocal: DateTime(2026, 11, 8, 14),
          endLocal: DateTime(2026, 11, 8, 19),
          timeZoneId: 'Asia/Shanghai',
        ),
      );
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      final card = find.byKey(const ValueKey('event-edge-notes'));
      final notes = find.byKey(const ValueKey('notes-popover-edge-notes'));
      for (final viewport in [const Size(1000, 760), const Size(800, 560)]) {
        tester.view.physicalSize = viewport;
        await tester.pumpAndSettle();
        await mouse.moveTo(tester.getCenter(card));
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        expect(notes, findsOneWidget);
        final bounds = tester.getRect(notes);
        expect(bounds.right, lessThanOrEqualTo(tester.getRect(card).left - 15));
        expect(bounds.overlaps(tester.getRect(card)), isFalse);
        expect(bounds.left, greaterThanOrEqualTo(12));
        expect(bounds.bottom, lessThanOrEqualTo(viewport.height - 12));
      }
      await mouse.removePointer();
      await tester.pumpAndSettle();
      expect(notes, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'calendar and sidebar float within the canvas with a shared baseline',
    (tester) async {
      await mount(tester);
      final rail = tester.getRect(
        find.byKey(const ValueKey('sidebar-surface')),
      );
      final calendar = tester.getRect(
        find.byKey(const ValueKey('calendar-surface')),
      );
      expect(rail.left, greaterThanOrEqualTo(12));
      expect(rail.top, greaterThanOrEqualTo(12));
      expect(calendar.left - rail.right, greaterThanOrEqualTo(12));
      expect(1000 - calendar.right, greaterThanOrEqualTo(12));
      expect(760 - calendar.bottom, greaterThanOrEqualTo(12));
      expect(calendar.bottom, closeTo(rail.bottom, .1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('hover shows only notes and bounds long notes', (tester) async {
    final notes = List.filled(40, '只显示这条日程的备注。').join('\n');
    await mount(tester, event: task('hover', notes: notes));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('event-hover'))),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 180));
    final preview = find.text(notes).last;
    expect(preview, findsOneWidget);
    expect(tester.widget<Text>(preview).maxLines, 8);
    expect(tester.getRect(preview).bottom, lessThanOrEqualTo(760));
    expect(find.textContaining('单击查看备注'), findsNothing);
    expect(find.textContaining('拖动移动'), findsNothing);
    expect(tester.takeException(), isNull);
    await mouse.removePointer();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'drag keeps the source, springs between snap targets and commits the latest target',
    (tester) async {
      final c = await mount(tester, event: task('fluid'));
      final event = find.byKey(const ValueKey('event-fluid'));
      final drag = await tester.startGesture(
        tester.getCenter(event),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(4, 3));
      await tester.pump();
      final preview = find.byKey(const ValueKey('preview-fluid'));
      expect(preview, findsOneWidget);
      var bounds = tester.getRect(preview);
      final sourceBounds = tester.getRect(event);
      final landing = find.byKey(const ValueKey('drop-target-fluid'));
      final landingBounds = tester.getRect(landing);
      for (var i = 0; i < 3; i++) {
        await drag.moveBy(const Offset(.4, .4));
        await tester.pump();
        final next = tester.getRect(preview);
        expect(next.left - bounds.left, closeTo(.4, .03));
        expect(next.top - bounds.top, closeTo(.4, .03));
        bounds = next;
        expect(tester.getRect(event), sourceBounds);
        expect(
          tester.getRect(landing),
          rectMoreOrLessEquals(landingBounds, epsilon: .001),
        );
      }
      final dayWidth = tester.getSize(lane()).width;
      await drag.moveBy(Offset(dayWidth, 8));
      await tester.pump();
      expect(
        tester.getRect(landing),
        rectMoreOrLessEquals(landingBounds, epsilon: .001),
      );
      await tester.pump(const Duration(milliseconds: 60));
      final inFlight = tester.getRect(landing);
      expect(inFlight.left - landingBounds.left, inExclusiveRange(0, dayWidth));
      final badge = tester.getRect(
        find.byKey(const ValueKey('drop-target-fluid-label')),
      );
      expect(badge.left - inFlight.left, closeTo(2, .05));
      // Retarget before settling: no position jump or reset to the old cell.
      await drag.moveBy(Offset(dayWidth, 0));
      await tester.pump();
      expect(tester.getRect(landing).left, closeTo(inFlight.left, .001));
      expect(tester.getRect(landing).top, closeTo(inFlight.top, .001));
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.getRect(landing).left, greaterThan(inFlight.left));
      expect(tester.getRect(event), sourceBounds);
      expect(c.events.single.startLocal, DateTime(2026, 11, 3, 9));
      await drag.up();
      await tester.pumpAndSettle();
      final saved = c.events.single;
      expect(saved.startLocal.minute, 15);
      expect(saved.startLocal.day, 5);
      expect(saved.startLocal.second, 0);
      expect(saved.duration, const Duration(hours: 2));
      await drag.removePointer();
      final cancel = await tester.startGesture(
        tester.getCenter(event),
        kind: PointerDeviceKind.mouse,
      );
      await cancel.moveBy(const Offset(8, 4));
      await tester.pump();
      await cancel.cancel();
      await tester.pumpAndSettle();
      expect(c.events.single.startLocal, saved.startLocal);
      await cancel.removePointer();
      expect(find.byKey(const ValueKey('preview-fluid')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an exact drop finishes feedback and cancellation of creation does not open the editor',
    (tester) async {
      final c = await mount(tester, event: task('exact'));
      final original = find.byKey(const ValueKey('event-exact'));
      final drag = await tester.startGesture(
        tester.getCenter(original),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(Offset(tester.getSize(lane()).width, 0));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      expect(c.events.single.startLocal, DateTime(2026, 11, 4, 9));
      expect(find.byKey(const ValueKey('drop-target-exact')), findsNothing);
      expect(find.byKey(const ValueKey('preview-exact')), findsNothing);
      await drag.removePointer();
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpAndSettle();
      final blank = tester.getRect(lane());
      final create = await tester.startGesture(
        Offset(blank.center.dx, blank.center.dy),
        kind: PointerDeviceKind.mouse,
      );
      await create.moveBy(const Offset(0, 25));
      await tester.pump();
      expect(find.byKey(const ValueKey('creation-landing')), findsOneWidget);
      final firstHeight = tester
          .getSize(find.byKey(const ValueKey('creation-landing')))
          .height;
      await create.moveBy(const Offset(0, 35));
      await tester.pump();
      // Reduced-motion users get the exact new target on the next frame.
      expect(
        tester.getSize(find.byKey(const ValueKey('creation-landing'))).height,
        greaterThan(firstHeight + 20),
      );
      await create.cancel();
      await create.removePointer();
      await tester.pumpAndSettle();
      expect(find.byType(EventEditorDialog), findsNothing);
      expect(find.byKey(const ValueKey('creation-landing')), findsNothing);
    },
  );

  testWidgets('resize follows subpixels without fifteen-minute snapping', (
    tester,
  ) async {
    final c = await mount(tester, event: task('resize'));
    final bounds = tester.getRect(find.byKey(const ValueKey('event-resize')));
    final drag = await tester.startGesture(
      Offset(bounds.center.dx, bounds.bottom - 2),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(0, 3));
    await tester.pump();
    final preview = find.byKey(const ValueKey('preview-resize'));
    final first = tester.getRect(preview);
    await drag.moveBy(const Offset(0, .4));
    await tester.pump();
    expect(tester.getRect(preview).height - first.height, closeTo(.4, .03));
    await drag.up();
    await tester.pumpAndSettle();
    expect(c.events.single.startLocal, DateTime(2026, 11, 3, 9));
    expect(c.events.single.endLocal.minute, inInclusiveRange(1, 14));
    expect(c.events.single.endLocal.second, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'creation uses quarter hours with separate smooth outline and snapped shadow',
    (tester) async {
      await mount(tester);
      final rect = tester.getRect(lane());
      Offset at(double minute) =>
          Offset(rect.center.dx, rect.top + (minute - 420) / 960 * rect.height);
      await tester.tapAt(at(611));
      await tester.pumpAndSettle();
      var editor = tester.widget<EventEditorDialog>(
        find.byType(EventEditorDialog),
      );
      expect(editor.start, DateTime(2026, 11, 3, 10, 15));
      expect(editor.end, DateTime(2026, 11, 3, 11, 15));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      final drag = await tester.startGesture(
        at(601),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveTo(at(620));
      await tester.pump();
      final ghost = find.byKey(const ValueKey('creation-landing'));
      final live = find.byKey(const ValueKey('creation-live'));
      final beforeGhost = tester.getRect(ghost);
      var beforeLive = tester.getRect(live);
      expect(find.text('10:00 – 10:15'), findsOneWidget);
      for (var i = 0; i < 3; i++) {
        await drag.moveBy(const Offset(0, .4));
        await tester.pump();
        final next = tester.getRect(live);
        expect(next.bottom - beforeLive.bottom, closeTo(.4, .03));
        expect(tester.getRect(ghost), beforeGhost);
        beforeLive = next;
      }
      await drag.moveTo(at(641));
      await tester.pump();
      expect(tester.getRect(ghost), beforeGhost);
      expect(find.text('10:00 – 10:45'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        tester.getRect(ghost).height,
        inExclusiveRange(beforeGhost.height, rect.height * 45 / 960 - 1),
      );
      await drag.up();
      await tester.pumpAndSettle();
      editor = tester.widget<EventEditorDialog>(find.byType(EventEditorDialog));
      expect(editor.start, DateTime(2026, 11, 3, 10));
      expect(editor.end, DateTime(2026, 11, 3, 10, 45));
      await drag.removePointer();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'short event title is centered vertically with readable type and a consistent inset',
    (tester) async {
      final c = await mount(tester, size: const Size(1800, 760));
      await c.saveEvent(
        CalendarEvent.timed(
          id: 'short',
          title: '预留时间',
          startLocal: DateTime(2026, 11, 3, 9),
          endLocal: DateTime(2026, 11, 3, 9, 50),
          timeZoneId: 'Asia/Shanghai',
        ),
      );
      await tester.pumpAndSettle();
      final card = tester.getRect(find.byKey(const ValueKey('event-short')));
      final title = find.byKey(const ValueKey('card-title-short'));
      final titleBounds = tester.getRect(title);
      expect(titleBounds.center.dy, closeTo(card.center.dy, 1));
      expect(titleBounds.left - card.left, inInclusiveRange(12, 14));
      final style = tester.widget<Text>(title).style!;
      expect(style.fontFamily, 'WeekGlassSans');
      expect(style.fontSize, greaterThanOrEqualTo(12.5));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('editor has no all-day mode and saves one-minute tasks', (
    tester,
  ) async {
    final c = await mount(tester);
    openEventEditor(
      tester.element(find.byType(Scaffold).first),
      controller: c,
      start: DateTime(2026, 11, 3, 9),
      end: DateTime(2026, 11, 3, 9, 1),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('全天'), findsNothing);
    await tester.tap(find.text('保存日程'));
    await tester.pumpAndSettle();
    expect(c.events.single.isAllDay, isFalse);
    expect(c.events.single.duration, const Duration(minutes: 1));
    await tester.tap(find.bySemanticsLabel('设置'));
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('拖动吸附'), findsNothing);
    expect(find.textContaining('全天'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test(
    'deletion-specific undo preserves later changes and cannot replay twice',
    () async {
      final repo = _Repository();
      final c = PlannerController(
        repository: repo,
        timeZoneId: 'Asia/Shanghai',
      );
      await c.initialize();
      await c.saveEvent(task('removed', notes: '保留备注'));
      final receipt = (await c.deleteEvent('removed'))!;
      await c.saveEvent(task('later', notes: '稍后新建'));
      expect(await c.undoDeletion(receipt), isTrue);
      expect(c.events.map((e) => e.id).toSet(), {'removed', 'later'});
      expect(repo.events.keys.toSet(), {'removed', 'later'});
      expect(await c.undoDeletion(receipt), isFalse);
      await c.undo();
      expect(c.events.single.id, 'removed');
      expect(c.events.single.notes, '保留备注');
      c.dispose();
    },
  );
}

class _Repository implements EventRepository {
  final events = <String, CalendarEvent>{};
  @override
  Future<List<CalendarEvent>> getAllEvents() async => events.values.toList();
  @override
  Future<List<CalendarEvent>> getEventsForRange({
    required DateTime startLocal,
    required DateTime endLocal,
  }) async => events.values.toList();
  @override
  Future<void> save(CalendarEvent event) async => events[event.id] = event;
  @override
  Future<void> saveBatch(List<CalendarEvent> values) async {
    for (final e in values) {
      events[e.id] = e;
    }
  }

  @override
  Future<void> delete(String id) async => events.remove(id);
  @override
  Future<void> deleteBatch(List<String> ids) async {
    for (final id in ids) {
      events.remove(id);
    }
  }

  @override
  Future<void> close() async {}
}
