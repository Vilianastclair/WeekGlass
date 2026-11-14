import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:weekglass/main.dart';
import 'package:weekglass/features/planner/event_details_dialog.dart';
import 'package:weekglass/features/planner/event_editor_dialog.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

import 'whu_import_test.dart' show MemoryImportRepo;

CalendarEvent source({bool overnight = false}) => CalendarEvent.timed(
  id: 'source',
  title: '洗漱',
  notes: '准备毛巾\n睡前护肤',
  startLocal: DateTime(2026, 11, 3, overnight ? 23 : 9, 15),
  endLocal: overnight
      ? DateTime(2026, 11, 4, 0, 45)
      : DateTime(2026, 11, 3, 9, 45),
  color: EventColor.lavender,
  timeZoneId: 'Asia/Shanghai',
  seriesId: 'original-series',
  recurrenceRule: 'FREQ=WEEKLY;COUNT=3',
  importSource: 'whu:2026:3',
  importFingerprint: 'school-origin',
  createdAtUtc: DateTime.utc(2026, 1, 1),
  version: 7,
);

void main() {
  setUp(() async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await initializeDateFormatting('zh_CN');
  });

  Future<({PlannerController c, MemoryImportRepo repo, CalendarEvent original})>
  mount(
    WidgetTester tester, {
    bool overnight = false,
    Size size = const Size(1000, 760),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = MemoryImportRepo();
    final original = source(overnight: overnight);
    await repo.save(original);
    final c = PlannerController(repository: repo, timeZoneId: 'Asia/Shanghai');
    await c.initialize();
    c.setAnchorDate(DateTime(2026, 11, 3));
    if (overnight) {
      await c.setSleepSchedule(const SleepSchedule(enabled: false));
    }
    await tester.pumpWidget(WeekGlassApp(controller: c));
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    });
    return (c: c, repo: repo, original: original);
  }

  Future<void> openCopy(
    WidgetTester tester,
    PlannerController c,
    CalendarEvent original,
  ) async {
    openEventDetails(
      tester.element(find.byType(Scaffold)),
      controller: c,
      event: original,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'copy preserves content but detaches batch/import identity; repeat copy and cancel are safe',
    (tester) async {
      final env = await mount(tester, size: const Size(390, 844));
      await openCopy(tester, env.c, env.original);
      expect(find.text('复制日程'), findsOneWidget);
      expect(find.text('洗漱'), findsWidgets);
      expect(find.text('准备毛巾\n睡前护肤'), findsOneWidget);
      await tester.tap(find.text('创建副本'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final copy = env.c.events.singleWhere((e) => e.id != 'source');
      expect(copy.title, env.original.title);
      expect(copy.notes, env.original.notes);
      expect(copy.color, env.original.color);
      expect(copy.startLocal, env.original.startLocal);
      expect(copy.endLocal, env.original.endLocal);
      expect(copy.seriesId, isNull);
      expect(copy.recurrenceRule, isNull);
      expect(copy.importSource, isNull);
      expect(copy.importFingerprint, isNull);
      expect(copy.version, 1);
      expect(copy.createdAtUtc.isAfter(env.original.createdAtUtc), isTrue);
      expect(env.repo.records['source'], same(env.original));
      await tester.tap(find.text('再复制'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EventEditorDialog>(find.byType(EventEditorDialog))
            .copyFrom!
            .id,
        copy.id,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(env.c.events, hasLength(2));
      await env.c.undo();
      expect(env.c.events.single.id, env.original.id);
      expect(tester.takeException(), isNull);
    },
  );

  for (final frequency in ['每周', '每月']) {
    testWidgets(
      'copy can create a new $frequency batch without modifying its source',
      (tester) async {
        final env = await mount(tester);
        await openCopy(tester, env.c, env.original);
        await tester.ensureVisible(find.text(frequency));
        await tester.tap(find.text(frequency));
        await tester.pumpAndSettle();
        if (frequency == '每周') {
          await tester.enterText(
            find.byKey(const ValueKey('repeat-week-count')),
            '3',
          );
        }
        await tester.tap(find.text('创建副本'));
        await tester.pumpAndSettle();
        final copies = env.c.events.where((e) => e.id != 'source').toList();
        expect(copies.length, frequency == '每周' ? 3 : 4);
        expect(copies.map((e) => e.seriesId).toSet(), hasLength(1));
        expect(copies.first.seriesId, isNotNull);
        expect(copies.first.seriesId, isNot(env.original.seriesId));
        expect(
          copies.every((e) => e.importSource == null && e.title == '洗漱'),
          isTrue,
        );
        expect(env.repo.records['source'], same(env.original));
        await env.c.undo();
        expect(env.c.events.single.id, 'source');
      },
    );
  }

  for (final overnight in [false, true]) {
    testWidgets(
      'copy shifts its end with the new start, overnight=$overnight',
      (tester) async {
        final env = await mount(tester, overnight: overnight);
        await openCopy(tester, env.c, env.original);
        await tester.tap(find.descendant(of: find.byType(EventEditorDialog),
          matching: find.text(overnight ? '23:15' : '09:15')));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.keyboard_outlined));
        await tester.pumpAndSettle();
        final fields = find.descendant(
          of: find.byType(TimePickerDialog),
          matching: find.byType(TextField),
        );
        await tester.enterText(fields.at(0), overnight ? '22' : '20');
        await tester.enterText(fields.at(1), '45');
        await tester.tap(find.text('确定'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('创建副本'));
        await tester.pumpAndSettle();
        final copy = env.c.events.singleWhere((e) => e.id != 'source');
        expect(copy.startLocal, DateTime(2026, 11, 3, overnight ? 22 : 20, 45));
        expect(
          copy.endLocal.difference(copy.startLocal),
          env.original.endLocal.difference(env.original.startLocal),
        );
        expect(env.repo.records['source'], same(env.original));
      },
    );
  }

  testWidgets(
    'failed copy stays editable and retry creates exactly one event',
    (tester) async {
      final env = await mount(tester);
      await openCopy(tester, env.c, env.original);
      env.repo.fail = true;
      await tester.tap(find.text('创建副本'));
      await tester.pumpAndSettle();
      expect(find.text('保存失败，本次修改未生效。请重试。'), findsOneWidget);
      expect(env.c.events, hasLength(1));
      env.repo.fail = false;
      await tester.tap(find.text('创建副本'));
      await tester.pumpAndSettle();
      expect(env.c.events, hasLength(2));
      expect((await env.repo.getAllEvents()), hasLength(2));
    },
  );
}
