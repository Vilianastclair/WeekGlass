import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weekglass_data/weekglass_data.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late SqliteEventRepository repository;

  setUp(() {
    repository = SqliteEventRepository(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
  });

  tearDown(() async {
    await repository.close();
  });

  test('timed events round-trip through SQLite', () async {
    final start = DateTime(2026, 11, 3, 9, 30);
    final event = CalendarEvent.timed(
      id: 'timed-1',
      title: 'A quiet morning',
      notes: 'Bring a notebook',
      color: EventColor.lavender,
      startLocal: start,
      endLocal: start.add(const Duration(minutes: 90)),
      timeZoneId: 'Asia/Shanghai',
    );

    await repository.save(event);
    final loaded = await repository.getAllEvents();

    expect(loaded, hasLength(1));
    expect(loaded.single.id, event.id);
    expect(loaded.single.title, event.title);
    expect(loaded.single.notes, event.notes);
    expect(loaded.single.color, EventColor.lavender);
    expect(loaded.single.startUtc, event.startUtc);
    expect(loaded.single.endUtc, event.endUtc);
    expect(loaded.single.timeZoneId, 'Asia/Shanghai');
  });

  test('all-day events are found by a range within their date', () async {
    final event = CalendarEvent.allDay(
      id: 'all-day-1',
      title: 'A full day away',
      startDate: DateTime(2026, 11, 3),
      endDateExclusive: DateTime(2026, 11, 4),
      timeZoneId: 'Asia/Shanghai',
    );

    await repository.save(event);
    final result = await repository.getEventsForRange(
      startLocal: DateTime(2026, 11, 3, 9),
      endLocal: DateTime(2026, 11, 3, 18),
    );

    expect(result, hasLength(1));
    expect(result.single.isAllDay, isTrue);
    expect(result.single.allDayStartDate, DateTime(2026, 11, 3));
  });

  test(
    'deletion is a tombstone and a restored event becomes visible',
    () async {
      final start = DateTime(2026, 11, 3, 14);
      final event = CalendarEvent.timed(
        id: 'undo-1',
        title: 'Review',
        startLocal: start,
        endLocal: start.add(const Duration(hours: 1)),
        timeZoneId: 'Asia/Shanghai',
      );

      await repository.save(event);
      await repository.delete(event.id);
      expect(await repository.getAllEvents(), isEmpty);

      await repository.save(event);
      final restored = await repository.getAllEvents();

      expect(restored, hasLength(1));
      expect(restored.single.id, event.id);
      expect(restored.single.deletedAtUtc, isNull);
    },
  );
}
