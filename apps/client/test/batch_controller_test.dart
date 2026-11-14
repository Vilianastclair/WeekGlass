import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weekglass_data/weekglass_data.dart';
import 'package:weekglass_domain/weekglass_domain.dart';
import 'package:weekglass/features/planner/planner_controller.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  setUp(
    () => SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty(),
  );
  test(
    'batch persists to SQLite and one undo removes the entire batch',
    () async {
      final repo = SqliteEventRepository(
        factory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );
      final controller = PlannerController(
        repository: repo,
        timeZoneId: 'Asia/Shanghai',
      );
      await controller.initialize();
      var id = 0;
      final events = expandRepeatedEvent(
        CalendarEvent.timed(
          id: 't',
          title: '每月计划',
          startLocal: DateTime(2026, 11, 3, 9),
          endLocal: DateTime(2026, 11, 3, 10),
          timeZoneId: 'Asia/Shanghai',
        ),
        RepeatPlan(
          frequency: RepeatFrequency.monthly,
          until: DateTime(2027, 2, 3),
        ),
        newId: () => '${id++}',
        seriesId: 's',
      );
      await controller.saveEvents(events);
      final saved = await repo.getAllEvents();
      expect(saved, hasLength(4));
      expect(saved.last.seriesId, 's');
      expect(controller.undoLabel, contains('4 条日程'));
      await controller.undo();
      expect(await repo.getAllEvents(), isEmpty);
      expect(controller.events, isEmpty);
      controller.dispose();
    },
  );
  test('failed batch leaves controller and undo history unchanged', () async {
    final repo = _FailedRepository();
    final controller = PlannerController(
      repository: repo,
      timeZoneId: 'Asia/Shanghai',
    );
    await controller.initialize();
    final event = CalendarEvent.timed(
      id: 't',
      title: '任务',
      startLocal: DateTime(2026, 11, 3, 9),
      endLocal: DateTime(2026, 11, 3, 10),
      timeZoneId: 'Asia/Shanghai',
    );
    await expectLater(controller.saveEvents([event]), throwsStateError);
    expect(controller.events, isEmpty);
    expect(controller.canUndo, isFalse);
    controller.dispose();
  });
}

class _FailedRepository implements EventRepository {
  @override
  Future<List<CalendarEvent>> getAllEvents() async => [];
  @override
  Future<List<CalendarEvent>> getEventsForRange({
    required DateTime startLocal,
    required DateTime endLocal,
  }) async => [];
  @override
  Future<void> save(CalendarEvent e) async => throw StateError('disk failure');
  @override
  Future<void> saveBatch(List<CalendarEvent> e) async =>
      throw StateError('disk failure');
  @override
  Future<void> delete(String id) async {}
  @override
  Future<void> deleteBatch(List<String> ids) async {}
  @override
  Future<void> close() async {}
}
