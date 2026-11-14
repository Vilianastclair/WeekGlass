import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weekglass/main.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass_data/weekglass_data.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

List<CalendarEvent> batch(RepeatFrequency frequency) => [
  for (var i = 0; i < 4; i++)
    CalendarEvent.timed(
      id: 'member-$i',
      title: '同名课程',
      notes: '备注-$i',
      startLocal: frequency == RepeatFrequency.weekly
          ? DateTime(2026, 11, 3 + i * 7, 9 + i)
          : DateTime(2026, 11 + i, 3, 9 + i),
      endLocal: frequency == RepeatFrequency.weekly
          ? DateTime(2026, 11, 3 + i * 7, 10 + i, i * 5)
          : DateTime(2026, 11 + i, 3, 10 + i, i * 5),
      seriesId: 'main-batch',
      recurrenceRule: frequency == RepeatFrequency.weekly
          ? 'FREQ=WEEKLY'
          : 'FREQ=MONTHLY',
      color: EventColor.rose,
      timeZoneId: 'Asia/Shanghai',
      createdAtUtc: DateTime.utc(2026, 1, i + 1),
      version: 2 + i,
    ),
];

void main() {
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await initializeDateFormatting('zh_CN');
  });

  Future<PlannerController> controller(EventRepository repo) async {
    final c = PlannerController(repository: repo, timeZoneId: 'Asia/Shanghai');
    await c.initialize();
    c.setAnchorDate(DateTime(2026, 11, 3));
    addTearDown(() async {
      await repo.close();
      c.dispose();
    });
    return c;
  }

  for (final frequency in [RepeatFrequency.weekly, RepeatFrequency.monthly]) {
    test(
      '${frequency.name} appearance sync covers earlier and later records without touching other batches or deleted records',
      () async {
        final repo = SqliteEventRepository(
          factory: databaseFactoryFfi,
          databasePath: inMemoryDatabasePath,
        );
        final c = await controller(repo);
        final group = batch(frequency);
        final unrelated = [
          CalendarEvent.timed(
            id: 'other-batch',
            title: '同名课程',
            seriesId: 'other-batch',
            startLocal: DateTime(2026, 11, 4, 9),
            endLocal: DateTime(2026, 11, 4, 10),
            timeZoneId: 'Asia/Shanghai',
          ),
          CalendarEvent.timed(
            id: 'single',
            title: '同名课程',
            startLocal: DateTime(2026, 11, 5, 9),
            endLocal: DateTime(2026, 11, 5, 10),
            timeZoneId: 'Asia/Shanghai',
          ),
        ];
        await c.saveEvents([...group, ...unrelated]);
        await c.deleteEvent(group.last.id);
        final selected = group[1].withDetails(
          title: '统一新名称',
          notes: '只修改当前备注',
          color: EventColor.lavender,
        );
        expect(
          await c.saveBatchChanges(
            selected,
            fields: {BatchEditField.title, BatchEditField.color},
          ),
          3,
        );
        final active = await repo.getAllEvents();
        expect(active, hasLength(5));
        for (final before in group.take(3)) {
          final after = active.singleWhere((e) => e.id == before.id);
          expect(after.title, '统一新名称');
          expect(after.color, EventColor.lavender);
          expect(after.startUtc, before.startUtc);
          expect(after.endUtc, before.endUtc);
          expect(
            after.notes,
            before.id == selected.id ? '只修改当前备注' : before.notes,
          );
          expect(after.createdAtUtc, before.createdAtUtc);
          expect(after.seriesId, before.seriesId);
          expect(after.recurrenceRule, before.recurrenceRule);
        }
        expect(active.any((e) => e.id == group.last.id), isFalse);
        for (final item in unrelated) {
          final after = active.singleWhere((e) => e.id == item.id);
          expect(after.title, item.title);
          expect(after.color, item.color);
        }
        await c.undo();
        final restored = await repo.getAllEvents();
        for (final before in group.take(3)) {
          final after = restored.singleWhere((e) => e.id == before.id);
          expect(after.title, before.title);
          expect(after.color, before.color);
          expect(after.notes, before.notes);
          expect(after.startUtc, before.startUtc);
          expect(after.endUtc, before.endUtc);
          expect(after.version, before.version);
        }
        expect(restored.any((e) => e.id == group.last.id), isFalse);
      },
    );
  }

  test('only changed appearance fields propagate; failures preserve storage, memory and undo', () async {
    final repo = _Repo();
    final c = await controller(repo);
    final group = batch(RepeatFrequency.weekly).take(2).toList();
    final second = group[1].withDetails(
      title: '单独改过的名称',
      notes: group[1].notes,
      color: EventColor.slate,
    );
    await c.saveEvents([group[0], second]);
    await c.saveBatchChanges(
      group[0].withDetails(
        title: '新名称',
        notes: group[0].notes,
        color: group[0].color,
      ),
    );
    expect(
      c.events.singleWhere((e) => e.id == second.id).color,
      EventColor.slate,
    );
    await c.undo();
    await c.saveBatchChanges(
      group[0].withDetails(
        title: group[0].title,
        notes: group[0].notes,
        color: EventColor.lavender,
      ),
    );
    expect(c.events.singleWhere((e) => e.id == second.id).title, '单独改过的名称');
    final undo = c.undoLabel;
    final before = {for (final e in c.events) e.id: e};
    repo.fail = true;
    await expectLater(
      c.saveBatchChanges(
        c.events.first.withDetails(
          title: '失败的改名',
          notes: '不保存',
          color: EventColor.softPeach,
        ),
      ),
      throwsStateError,
    );
    expect(c.undoLabel, undo);
    for (final e in c.events) {
      expect(e.title, before[e.id]!.title);
      expect(e.color, before[e.id]!.color);
    }
    expect(repo.records[second.id]!.title, '单独改过的名称');
    await expectLater(c.undo(), throwsStateError);
    expect(c.undoLabel, undo);
    repo.fail = false;
    await c.undo();
    expect(c.events.first.color, group[0].color);
    expect(
      c.events.singleWhere((e) => e.id == second.id).color,
      EventColor.slate,
    );
  });

  for (final frequency in [RepeatFrequency.weekly, RepeatFrequency.monthly]) {
    test(
      '${frequency.name} batch time changes retain calendar dates, metadata and one atomic undo',
      () async {
        final repo = SqliteEventRepository(
          factory: databaseFactoryFfi,
          databasePath: inMemoryDatabasePath,
        );
        final c = await controller(repo);
        final group = batch(frequency);
        await c.saveEvents(group);
        final selected = group[1];
        final date = selected.startLocal;
        final edited = selected.withTimedRange(
          DateTime(date.year, date.month, date.day, 8, 30),
          DateTime(date.year, date.month, date.day, 9, 45),
        );
        expect(c.batchChangeLabels(edited), ['开始时间', '结束时间']);
        expect(await c.saveBatchChanges(edited), 4);
        for (final item in await repo.getAllEvents()) {
          final before = group.singleWhere((e) => e.id == item.id);
          expect(dateOnly(item.startLocal), dateOnly(before.startLocal));
          expect(item.startLocal.hour, 8);
          expect(item.startLocal.minute, 30);
          expect(item.endLocal.hour, 9);
          expect(item.endLocal.minute, 45);
          expect(item.notes, before.notes);
          expect(item.seriesId, before.seriesId);
          expect(item.createdAtUtc, before.createdAtUtc);
        }
        await c.undo();
        for (final item in await repo.getAllEvents()) {
          final before = group.singleWhere((e) => e.id == item.id);
          expect(item.startUtc, before.startUtc);
          expect(item.endUtc, before.endUtc);
        }
      },
    );
  }

  test('only changed time endpoints propagate; invalid or sleeping members reject the entire save', () async {
    final repo = _Repo();
    final c = await controller(repo);
    final group = batch(RepeatFrequency.weekly).take(2).toList();
    await c.saveEvents(group);
    final first = group.first;
    final start = DateTime(2026, 11, 3, 8, 15);
    await c.saveBatchChanges(first.withTimedRange(start, first.endLocal));
    expect(
      c.events.every(
        (e) => e.startLocal.hour == 8 && e.startLocal.minute == 15,
      ),
      isTrue,
    );
    expect(
      c.events.singleWhere((e) => e.id == group[1].id).endUtc,
      group[1].endUtc,
    );
    await c.undo();
    final beforeUndo = c.undoLabel;
    // This is valid for the selected 10:00–11:05 occurrence, but invalid for
    // its earlier 09:00–10:00 member, so no occurrence may be saved.
    final second = group[1];
    await expectLater(
      c.saveBatchChanges(
        second.withTimedRange(DateTime(2026, 11, 10, 10, 30), second.endLocal),
      ),
      throwsArgumentError,
    );
    expect(c.undoLabel, beforeUndo);
    expect(c.events.first.startUtc, first.startUtc);
    expect(repo.records[first.id]!.startUtc, first.startUtc);
    await expectLater(
      c.saveBatchChanges(
        first.withTimedRange(DateTime(2026, 11, 3, 6), first.endLocal),
      ),
      throwsArgumentError,
    );
    expect(c.undoLabel, beforeUndo);
    expect(c.events.first.startUtc, first.startUtc);
  });

  test('overnight batch changes preserve next-day end and independent seconds; date-only changes do not propagate', () async {
    final c = await controller(_Repo());
    await c.setSleepSchedule(const SleepSchedule(enabled: false));
    final group = [
      for (var i = 0; i < 2; i++)
        CalendarEvent.timed(
          id: 'overnight-$i',
          title: '夜间',
          notes: '备注-$i',
          seriesId: 'overnight',
          startLocal: DateTime(2026, 11, 3 + i * 7, 23, 10, 17),
          endLocal: DateTime(2026, 11, 4 + i * 7, 1, 25, 19),
          timeZoneId: 'Asia/Shanghai',
        ),
    ];
    await c.saveEvents(group);
    final shifted = group.first.withTimedRange(
      DateTime(2026, 11, 5, 23, 10, 17),
      DateTime(2026, 11, 6, 1, 25, 19),
    );
    expect(c.batchChangeLabels(shifted), isEmpty);
    final edited = group.first.withTimedRange(
      group.first.startLocal,
      DateTime(2026, 11, 4, 2, 30),
    );
    await c.saveBatchChanges(edited);
    for (final item in c.events) {
      final before = group.singleWhere((e) => e.id == item.id);
      expect(item.startUtc, before.startUtc);
      expect(dateOnly(item.endLocal), dateOnly(before.endLocal));
      expect(item.endLocal.hour, 2);
      expect(item.endLocal.minute, 30);
      expect(item.notes, before.notes);
    }
  });

  Future<void> mount(
    WidgetTester tester,
    PlannerController c, {
    Size size = const Size(1000, 760),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(WeekGlassApp(controller: c));
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  Future<void> adjust(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(ValueKey('event-$id')).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('调整'));
    await tester.pumpAndSettle();
  }

  testWidgets('save asks scope; current and batch edits share one undo', (
    tester,
  ) async {
    final c = await controller(_Repo());
    final group = batch(RepeatFrequency.weekly).take(3).toList();
    await c.saveEvents(group);
    await mount(tester, c);
    await adjust(tester, group.first.id);
    expect(find.byType(CheckboxListTile), findsNothing);
    await tester.enterText(find.byType(TextField).first, '仅改当前');
    await tester.ensureVisible(find.byTooltip(EventColor.lavender.label));
    await tester.tap(find.byTooltip(EventColor.lavender.label));
    await tester.tap(find.text('保存日程'));
    await tester.pumpAndSettle();
    expect(find.text('将修改应用到？'), findsOneWidget);
    expect(c.events.first.title, '同名课程');
    await tester.tap(find.text('仅修改本日程'));
    await tester.pumpAndSettle();
    expect(c.events.first.title, '仅改当前');
    expect(c.events[1].title, '同名课程');
    expect(c.events[1].color, EventColor.rose);
    await c.undo();
    await tester.pumpAndSettle();
    await adjust(tester, group.first.id);
    await tester.enterText(find.byType(TextField).first, '整批新名称');
    await tester.ensureVisible(find.byTooltip(EventColor.lavender.label));
    await tester.tap(find.byTooltip(EventColor.lavender.label));
    await tester.tap(find.text('保存日程'));
    await tester.pumpAndSettle();
    expect(find.text('已调整名称、颜色'), findsOneWidget);
    await tester.tap(find.text('修改同批日程'));
    await tester.pumpAndSettle();
    expect(
      c.events.every(
        (e) => e.title == '整批新名称' && e.color == EventColor.lavender,
      ),
      isTrue,
    );
    for (final before in group) {
      final after = c.events.singleWhere((e) => e.id == before.id);
      expect(after.startUtc, before.startUtc);
      expect(after.endUtc, before.endUtc);
      expect(after.notes, before.notes);
    }
    await c.undo();
    expect(
      c.events.every((e) => e.title == '同名课程' && e.color == EventColor.rose),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'monthly sync can be canceled and fits minimum desktop size in both themes',
    (tester) async {
      final c = await controller(_Repo());
      await c.saveEvents(batch(RepeatFrequency.monthly));
      await mount(tester, c, size: const Size(800, 560));
      for (final mode in [ThemeMode.dark, ThemeMode.light]) {
        c.setThemeMode(mode);
        await tester.pumpAndSettle();
        await adjust(tester, 'member-0');
        await tester.enterText(find.byType(TextField).first, '未保存的名称');
        await tester.tap(find.text('保存日程'));
        await tester.pumpAndSettle();
        expect(find.textContaining('共 4 条'), findsOneWidget);
        expect(tester.getRect(find.text('修改同批日程')).bottom, lessThan(560));
        await tester.tap(find.text('返回调整'));
        await tester.pumpAndSettle();
        expect(find.text('未保存的名称'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(
          c.events.every(
            (e) => e.title == '同名课程' && e.color == EventColor.rose,
          ),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'time and notes edits ask scope; current-only notes remain local',
    (tester) async {
      final c = await controller(_Repo());
      final group = batch(RepeatFrequency.monthly).take(2).toList();
      await c.saveEvents(group);
      await mount(tester, c);
      await adjust(tester, 'member-0');
      await tester.tap(find.text('结束时间'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.keyboard_outlined));
      await tester.pumpAndSettle();
      final inputs = find.descendant(
        of: find.byType(TimePickerDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(inputs.first, '11');
      await tester.enterText(inputs.last, '30');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存日程'));
      await tester.pumpAndSettle();
      expect(find.text('已调整结束时间'), findsOneWidget);
      await tester.tap(find.text('修改同批日程'));
      await tester.pumpAndSettle();
      for (final item in c.events) {
        final before = group.singleWhere((e) => e.id == item.id);
        expect(item.startUtc, before.startUtc);
        expect(item.endLocal.hour, 11);
        expect(item.endLocal.minute, 30);
        expect(dateOnly(item.endLocal), dateOnly(before.endLocal));
      }
      await adjust(tester, 'member-0');
      await tester.ensureVisible(find.byType(TextField).last);
      await tester.enterText(find.byType(TextField).last, '仅更新备注');
      await tester.tap(find.text('保存日程'));
      await tester.pumpAndSettle();
      expect(find.text('已调整备注'), findsOneWidget);
      await tester.tap(find.text('仅修改本日程'));
      await tester.pumpAndSettle();
      expect(c.events.first.notes, '仅更新备注');
      expect(c.events.last.notes, group.last.notes);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'moving a batch event asks scope, can cancel and can update all dates with one undo',
    (tester) async {
      final c = await controller(_Repo());
      final group = batch(RepeatFrequency.weekly).take(2).toList();
      await c.saveEvents(group);
      await mount(tester, c);
      final lane = find.byKey(
        ValueKey('day-lane-${DateTime(2026, 11, 3).toIso8601String()}'),
      );
      final hourHeight = tester.getRect(lane).height / 16;
      Future<void> move() async {
        final card = find.byKey(const ValueKey('event-member-0'));
        final drag = await tester.startGesture(
          tester.getCenter(card),
          kind: PointerDeviceKind.mouse,
        );
        await drag.moveBy(Offset(0, hourHeight));
        await tester.pump();
        await drag.up();
        await tester.pumpAndSettle();
      }

      await move();
      expect(find.text('将修改应用到？'), findsOneWidget);
      await tester.tap(find.text('返回调整'));
      await tester.pumpAndSettle();
      expect(c.events.first.startUtc, group.first.startUtc);
      await move();
      await tester.tap(find.text('修改同批日程'));
      await tester.pumpAndSettle();
      expect(
        c.events.every((e) => e.startLocal.hour == 10 && e.endLocal.hour == 11),
        isTrue,
      );
      for (final item in c.events) {
        expect(
          dateOnly(item.startLocal),
          dateOnly(group.singleWhere((e) => e.id == item.id).startLocal),
        );
      }
      await c.undo();
      await tester.pumpAndSettle();
      for (final item in c.events) {
        expect(
          item.startUtc,
          group.singleWhere((e) => e.id == item.id).startUtc,
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('appearance-only editing preserves overnight times and seconds', (
    tester,
  ) async {
    final c = await controller(_Repo());
    await c.setSleepSchedule(const SleepSchedule(enabled: false));
    final events = [
      for (var i = 0; i < 2; i++)
        CalendarEvent.timed(
          id: 'night-$i',
          title: '夜间安排',
          startLocal: DateTime(2026, 11, 3 + i * 7, 23, 10, 17),
          endLocal: DateTime(2026, 11, 4 + i * 7, 1, 25, 19),
          seriesId: 'night',
          recurrenceRule: 'FREQ=WEEKLY',
          timeZoneId: 'Asia/Shanghai',
        ),
    ];
    await c.saveEvents(events);
    await mount(tester, c);
    await adjust(tester, 'night-0');
    await tester.enterText(find.byType(TextField).first, '整批夜间安排');
    await tester.tap(find.text('保存日程'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('修改同批日程'));
    await tester.pumpAndSettle();
    expect(c.events.every((e) => e.title == '整批夜间安排'), isTrue);
    for (final before in events) {
      final after = c.events.singleWhere((e) => e.id == before.id);
      expect(after.startUtc, before.startUtc);
      expect(after.endUtc, before.endUtc);
    }
    expect(tester.takeException(), isNull);
  });
}

class _Repo implements EventRepository {
  bool fail = false;
  final records = <String, CalendarEvent>{};
  @override
  Future<List<CalendarEvent>> getAllEvents() async =>
      records.values.where((e) => e.deletedAtUtc == null).toList();
  @override
  Future<List<CalendarEvent>> getEventsForRange({
    required DateTime startLocal,
    required DateTime endLocal,
  }) async => getAllEvents();
  @override
  Future<void> save(CalendarEvent event) async => saveBatch([event]);
  @override
  Future<void> saveBatch(List<CalendarEvent> events) async {
    if (fail) throw StateError('simulated transaction failure');
    for (final event in events) {
      records[event.id] = event;
    }
  }

  @override
  Future<void> delete(String id) async => deleteBatch([id]);
  @override
  Future<void> deleteBatch(List<String> ids) async {
    for (final id in ids) {
      records.remove(id);
    }
  }

  @override
  Future<void> close() async {}
}
