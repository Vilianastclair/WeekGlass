import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weekglass_data/weekglass_data.dart';
import 'package:weekglass_domain/weekglass_domain.dart';
import 'package:weekglass/features/planner/planner_controller.dart';

CalendarEvent task(String id, DateTime start, DateTime end, {String? series}) =>
    CalendarEvent.timed(
      id: id,
      title: id,
      startLocal: start,
      endLocal: end,
      timeZoneId: 'Asia/Shanghai',
      seriesId: series,
    );

void main() {
  setUpAll(sqfliteFfiInit);
  setUp(
    () => SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty(),
  );
  test('sleep boundaries and overnight awake window are exact', () {
    const sleep = SleepSchedule();
    expect(sleep.visibleStart, 420);
    expect(sleep.visibleEnd, 1380);
    expect(
      sleep.allows(
        task('a', DateTime(2026, 11, 3, 7), DateTime(2026, 11, 3, 23)),
      ),
      isTrue,
    );
    expect(
      sleep.allows(
        task('b', DateTime(2026, 11, 3, 6, 45), DateTime(2026, 11, 3, 7)),
      ),
      isFalse,
    );
    expect(
      sleep.allows(task('c', DateTime(2026, 11, 3, 23), DateTime(2026, 11, 4))),
      isFalse,
    );
    const late = SleepSchedule(sleepMinute: 120, wakeMinute: 600);
    expect(late.visibleEnd, 1560);
    expect(
      late.allows(
        task('d', DateTime(2026, 11, 4, 1), DateTime(2026, 11, 4, 2)),
      ),
      isTrue,
    );
    expect(
      late.allows(
        task('e', DateTime(2026, 11, 4, 2), DateTime(2026, 11, 4, 3)),
      ),
      isFalse,
    );
    expect(
      const SleepSchedule(sleepMinute: 420, wakeMinute: 420).valid,
      isFalse,
    );
  });
  test(
    'sleep setting persists and conflicting writes cannot mutate calendar',
    () async {
      final repo = SqliteEventRepository(
        factory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );
      final c = PlannerController(
        repository: repo,
        timeZoneId: 'Asia/Shanghai',
      );
      await c.initialize();
      await c.setSleepSchedule(
        const SleepSchedule(sleepMinute: 1410, wakeMinute: 435),
      );
      final reload = PlannerController(
        repository: repo,
        timeZoneId: 'Asia/Shanghai',
      );
      await reload.initialize();
      expect(reload.sleep.sleepMinute, 1410);
      expect(reload.sleep.wakeMinute, 435);
      final bad = task(
        'night',
        DateTime(2026, 11, 3, 23, 30),
        DateTime(2026, 11, 4),
      );
      await expectLater(c.saveEvents([bad]), throwsArgumentError);
      expect(await repo.getAllEvents(), isEmpty);
      expect(c.canUndo, isFalse);
      await c.saveEvent(
        task('evening', DateTime(2026, 11, 3, 20), DateTime(2026, 11, 3, 21)),
      );
      await expectLater(
        c.setSleepSchedule(
          const SleepSchedule(sleepMinute: 1200, wakeMinute: 420),
        ),
        throwsArgumentError,
      );
      expect(c.sleep.sleepMinute, 1410);
      expect(c.events, hasLength(1));
      c.dispose();
    },
  );
  test(
    'existing night events prevent automatic sleep hiding at upgrade',
    () async {
      final repo = SqliteEventRepository(
        factory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );
      await repo.save(
        task('night', DateTime(2026, 11, 3, 1), DateTime(2026, 11, 3, 2)),
      );
      final c = PlannerController(
        repository: repo,
        timeZoneId: 'Asia/Shanghai',
      );
      await c.initialize();
      expect(c.sleep.enabled, isFalse);
      expect(c.timedEventsInWindow(DateTime(2026, 11, 3)), hasLength(1));
      c.dispose();
    },
  );
  test('window after midnight includes the next calendar date', () async {
    final repo = SqliteEventRepository(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    final c = PlannerController(repository: repo, timeZoneId: 'Asia/Shanghai');
    await c.initialize();
    await c.setSleepSchedule(
      const SleepSchedule(sleepMinute: 120, wakeMinute: 600),
    );
    await c.saveEvent(
      task('late', DateTime(2026, 11, 4, 1), DateTime(2026, 11, 4, 2)),
    );
    expect(c.timedEventsInWindow(DateTime(2026, 11, 3)).single.id, 'late');
    expect(c.timedEventsInWindow(DateTime(2026, 11, 4)), isEmpty);
    c.dispose();
  });
  test('future deletion includes anchor, preserves earlier and unrelated batches, undo restores all', () async {
    final repo = SqliteEventRepository(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    final c = PlannerController(repository: repo, timeZoneId: 'Asia/Shanghai');
    await c.initialize();
    final batch = [
      for (var day in [3, 5, 10, 12])
        task(
          's-$day',
          DateTime(2026, 11, day, 9),
          DateTime(2026, 11, day, 10),
          series: 's',
        ),
    ];
    final other = task(
      'other',
      DateTime(2026, 11, 10, 9),
      DateTime(2026, 11, 10, 10),
      series: 'other',
    );
    await c.saveEvents([...batch, other]);
    await c.deleteEvent('s-5', futureInBatch: true);
    expect((await repo.getAllEvents()).map((e) => e.id).toSet(), {
      's-3',
      'other',
    });
    expect(c.undoLabel, contains('3 条日程'));
    await c.undo();
    expect(await repo.getAllEvents(), hasLength(5));
    await c.deleteEvent('s-5');
    expect(
      (await repo.getAllEvents()).map((e) => e.id),
      containsAll(['s-3', 's-10', 's-12', 'other']),
    );
    expect(await repo.getAllEvents(), hasLength(4));
    c.dispose();
  });
}
