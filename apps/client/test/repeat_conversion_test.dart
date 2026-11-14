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

CalendarEvent originalTask({DateTime? date}) => CalendarEvent.timed(
  id: 'original',
  title: '阅读计划',
  notes: '保留这条备注',
  color: EventColor.rose,
  startLocal: date ?? DateTime(2026, 11, 3, 9),
  endLocal: (date ?? DateTime(2026, 11, 3, 9)).add(const Duration(hours: 1)),
  timeZoneId: 'Asia/Shanghai',
  createdAtUtc: DateTime.utc(2026, 1, 1),
  version: 4,
);

void main() {
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await initializeDateFormatting('zh_CN');
  });

  Future<({PlannerController controller, EventRepository repo})> setup({
    bool memory = false,
  }) async {
    final EventRepository repo = memory
        ? _FailingRepository()
        : SqliteEventRepository(
            factory: databaseFactoryFfi,
            databasePath: inMemoryDatabasePath,
          );
    final c = PlannerController(repository: repo, timeZoneId: 'Asia/Shanghai');
    await c.initialize();
    c.setAnchorDate(DateTime(2026, 11, 3));
    addTearDown(() async {
      await repo.close();
      c.dispose();
    });
    return (controller: c, repo: repo);
  }

  test('weekly conversion updates the anchor once, groups future events, and undoes in SQLite', () async {
    final env = await setup();
    final c = env.controller;
    final original = originalTask();
    await c.saveEvent(original);
    final count = await c.convertToRepeat(
      original.withDetails(
        title: '周阅读',
        notes: '新的备注',
        color: EventColor.lavender,
      ),
      RepeatPlan(
        frequency: RepeatFrequency.weekly,
        until: DateTime(2026, 11, 22),
        weekdays: {2, 4},
      ),
    );
    expect(count, 6);
    expect((await env.repo.getAllEvents()), hasLength(6));
    final anchor = c.events.singleWhere((e) => e.id == original.id);
    expect(anchor.createdAtUtc, original.createdAtUtc);
    expect(anchor.version, 5);
    expect(
      c.events.where((e) => e.startLocal == original.startLocal),
      hasLength(1),
    );
    expect(c.events.map((e) => e.seriesId).toSet(), hasLength(1));
    expect(
      c.events.every(
        (e) => e.seriesId != null && e.title == '周阅读' && e.notes == '新的备注',
      ),
      isTrue,
    );
    expect(c.events.every((e) => e.color == EventColor.lavender), isTrue);
    final second = c.events.where((e) => e.id != original.id).first;
    await c.deleteEvent(second.id, futureInBatch: true);
    expect(c.events.single.id, original.id);
    await c.undo();
    expect(c.events, hasLength(6));
    await c.undo();
    final restored = (await env.repo.getAllEvents()).single;
    expect(restored.id, original.id);
    expect(restored.seriesId, isNull);
    expect(restored.recurrenceRule, isNull);
    expect(restored.notes, original.notes);
    expect(restored.title, original.title);
    expect(restored.color, original.color);
    expect(restored.version, original.version);
    expect(restored.createdAtUtc, original.createdAtUtc);
  });

  test('monthly conversion reuses day-31 rules and preserves the original identity', () async {
    final env = await setup();
    final c = env.controller;
    final original = originalTask(date: DateTime(2027, 1, 31, 9));
    await c.saveEvent(original);
    expect(
      await c.convertToRepeat(
        original,
        RepeatPlan(
          frequency: RepeatFrequency.monthly,
          until: DateTime(2027, 5, 31),
        ),
      ),
      3,
    );
    expect(c.events.map((e) => e.startLocal), [
      DateTime(2027, 1, 31, 9),
      DateTime(2027, 3, 31, 9),
      DateTime(2027, 5, 31, 9),
    ]);
    expect(c.events.first.id, original.id);
    expect(
      c.events.every((e) => e.recurrenceRule!.contains('MONTHLY')),
      isTrue,
    );
    await c.undo();
    expect((await env.repo.getAllEvents()).single.id, original.id);
  });

  test(
    'conversion cannot repeat an existing batch or bypass sleep validation',
    () async {
      final env = await setup();
      final c = env.controller;
      final original = originalTask();
      await c.saveEvent(original);
      final plan = RepeatPlan(
        frequency: RepeatFrequency.weekly,
        until: DateTime(2026, 11, 17),
        weekdays: {2},
      );
      await expectLater(
        c.convertToRepeat(
          original.withTimedRange(
            DateTime(2026, 11, 3, 23),
            DateTime(2026, 11, 4),
          ),
          plan,
        ),
        throwsArgumentError,
      );
      expect(c.events.single.seriesId, isNull);
      await c.convertToRepeat(original, plan);
      final before = c.events.length;
      final undo = c.undoLabel;
      await expectLater(
        c.convertToRepeat(c.events.first, plan),
        throwsArgumentError,
      );
      expect(c.events, hasLength(before));
      expect(c.undoLabel, undo);
    },
  );

  test('conversion and its mixed undo leave memory, storage and history unchanged on failure', () async {
    final repo = _FailingRepository();
    final c = PlannerController(repository: repo, timeZoneId: 'Asia/Shanghai');
    await c.initialize();
    addTearDown(c.dispose);
    final original = originalTask();
    await c.saveEvent(original);
    final plan = RepeatPlan(
      frequency: RepeatFrequency.weekly,
      until: DateTime(2026, 11, 17),
      weekdays: {2},
    );
    final before = c.undoLabel;
    repo.fail = true;
    await expectLater(c.convertToRepeat(original, plan), throwsStateError);
    expect(c.events.single.seriesId, isNull);
    expect(repo.active.single.id, original.id);
    expect(c.undoLabel, before);
    repo.fail = false;
    await c.convertToRepeat(original, plan);
    final converted = c.undoLabel;
    repo.fail = true;
    await expectLater(c.undo(), throwsStateError);
    expect(c.events, hasLength(3));
    expect(repo.active, hasLength(3));
    expect(c.undoLabel, converted);
    expect(repo.deleteCalls, 0);
    repo.fail = false;
    await c.undo();
    expect(repo.active.single.seriesId, isNull);
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

  Future<void> openAdjust(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('event-original')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('调整'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'adjust can convert to weekly using the shared weekday and week-count form',
    (tester) async {
      final env = await setup(memory: true);
      final c = env.controller;
      await c.saveEvent(originalTask());
      await mount(tester, c);
      await openAdjust(tester);
      await tester.ensureVisible(find.text('改为周日程'));
      await tester.tap(find.text('改为周日程'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('repeat-week-count')),
        '3',
      );
      await tester.ensureVisible(find.text('二'));
      await tester.tap(find.text('二'));
      await tester.tap(find.text('四'));
      await tester.pumpAndSettle();
      expect(find.text('保留本条，新增 3 条日程'), findsOneWidget);
      await tester.tap(find.text('保存日程'));
      await tester.pumpAndSettle();
      expect(c.events.map((e) => e.startLocal.day).toList()..sort(), [
        3,
        5,
        12,
        19,
      ]);
      expect((await env.repo.getAllEvents()), hasLength(4));
      expect(c.events.where((e) => e.id == 'original'), hasLength(1));
      await c.undo();
      await tester.pumpAndSettle();
      expect(c.events.single.seriesId, isNull);
      expect(c.events.single.notes, '保留这条备注');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'adjust converts to monthly and retains edited title and notes on all occurrences',
    (tester) async {
      final env = await setup(memory: true);
      final c = env.controller;
      await c.saveEvent(originalTask());
      await mount(tester, c);
      await openAdjust(tester);
      await tester.ensureVisible(find.text('改为月日程'));
      await tester.tap(find.text('改为月日程'));
      await tester.pumpAndSettle();
      expect(find.textContaining('每月 3 日'), findsOneWidget);
      expect(find.text('保留本条，新增 3 条日程'), findsOneWidget);
      await tester.ensureVisible(find.byType(TextField).first);
      await tester.enterText(find.byType(TextField).first, '每月阅读');
      await tester.tap(find.text('保存日程'));
      await tester.pumpAndSettle();
      expect(c.events, hasLength(4));
      expect(
        c.events.every((e) => e.title == '每月阅读' && e.notes == '保留这条备注'),
        isTrue,
      );
      expect(c.events.map((e) => e.startLocal.month), [11, 12, 1, 2]);
      await openAdjust(tester);
      expect(find.text('改为月日程'), findsNothing);
      expect(find.text('改为周日程'), findsNothing);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(c.events, hasLength(4));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'conversion selection can be canceled at minimum desktop size in both themes',
    (tester) async {
      final env = await setup(memory: true);
      final c = env.controller;
      await c.saveEvent(originalTask());
      await mount(tester, c, size: const Size(800, 560));
      for (final mode in [ThemeMode.dark, ThemeMode.light]) {
        c.setThemeMode(mode);
        await tester.pumpAndSettle();
        await openAdjust(tester);
        await tester.ensureVisible(find.text('改为周日程'));
        await tester.tap(find.text('改为周日程'));
        await tester.pumpAndSettle();
        expect(tester.getRect(find.text('保存日程')).bottom, lessThan(560));
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(c.events.single.seriesId, isNull);
        expect((await env.repo.getAllEvents()), hasLength(1));
        expect(tester.takeException(), isNull);
      }
    },
  );
}

class _FailingRepository implements EventRepository {
  bool fail = false;
  int deleteCalls = 0;
  final records = <String, CalendarEvent>{};
  List<CalendarEvent> get active =>
      records.values.where((e) => e.deletedAtUtc == null).toList();
  @override
  Future<List<CalendarEvent>> getAllEvents() async => active;
  @override
  Future<List<CalendarEvent>> getEventsForRange({
    required DateTime startLocal,
    required DateTime endLocal,
  }) async => active;
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
    deleteCalls++;
    for (final id in ids) {
      records.remove(id);
    }
  }

  @override
  Future<void> close() async {}
}
