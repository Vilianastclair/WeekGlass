import 'dart:async';

import 'package:sqflite_common/sqlite_api.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

import 'event_repository.dart';
import 'sleep_schedule_store.dart';
import 'sync_store.dart';
import 'teaching_calendar_store.dart';

class SqliteEventRepository
    implements EventRepository, ImportedEventRepository {
  SqliteEventRepository({
    required DatabaseFactory factory,
    required String databasePath,
  }) : _factory = factory,
       _databasePath = databasePath;

  final DatabaseFactory _factory;
  final String _databasePath;
  Future<Database>? _databaseFuture;
  final StreamController<void> _localChanges =
      StreamController<void>.broadcast();
  Stream<void> get localChanges => _localChanges.stream;
  late final SqliteSyncStore syncStore = SqliteSyncStore(() => _database);
  late final sleepScheduleStore = SqliteSleepScheduleStore(() => _database);

  late final teachingCalendars = TeachingCalendarStore(() => _database);

  Future<Database> get _database => _databaseFuture ??= _openDatabase();

  Future<Database> _openDatabase() {
    return _factory.openDatabase(
      _databasePath,
      options: OpenDatabaseOptions(
        version: 4,
        // Additive tables: an older app can still open the calendar at v4.
        onOpen: (db) async {
          await SqliteSleepScheduleStore.createSchema(db);
          await TeachingCalendarStore.createSchema(db);
        },
        onUpgrade: (database, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await database.execute(
              'ALTER TABLE events ADD COLUMN import_source TEXT',
            );
            await database.execute(
              'ALTER TABLE events ADD COLUMN import_fingerprint TEXT',
            );
          }
          if (oldVersion < 3) {
            await SqliteSyncStore.createSchema(database);
          } else if (oldVersion < 4) {
            await SqliteSyncStore.createRejectedFlightSchema(database);
          }
        },
        onCreate: (database, version) async {
          await database.execute('''
            CREATE TABLE events (
              id TEXT PRIMARY KEY,
              title TEXT NOT NULL DEFAULT '',
              notes TEXT,
              color_key TEXT NOT NULL,
              is_all_day INTEGER NOT NULL DEFAULT 0,
              start_utc TEXT,
              end_utc TEXT,
              all_day_start TEXT,
              all_day_end_exclusive TEXT,
              time_zone_id TEXT NOT NULL,
              recurrence_rule TEXT,
              series_id TEXT,
              created_at_utc TEXT NOT NULL,
              updated_at_utc TEXT NOT NULL,
              version INTEGER NOT NULL DEFAULT 1,
              import_source TEXT,
              import_fingerprint TEXT,
              deleted_at_utc TEXT
            )
          ''');
          await database.execute(
            'CREATE INDEX idx_events_start_utc ON events(start_utc)',
          );
          await database.execute(
            'CREATE INDEX idx_events_all_day ON events(all_day_start, all_day_end_exclusive)',
          );
          await database.execute(
            'CREATE INDEX idx_events_series ON events(series_id)',
          );
          await SqliteSyncStore.createSchema(database);
        },
      ),
    );
  }

  Future<SleepSchedule?> readSleepSchedule() => sleepScheduleStore.read();

  Future<void> migrateSleepSchedule(SleepSchedule value) async {
    if (await sleepScheduleStore.save(value, migrate: true)) {
      _localChanges.add(null);
    }
  }

  Future<void> saveSleepSchedule(SleepSchedule value) async {
    if (await sleepScheduleStore.save(value)) _localChanges.add(null);
  }

  @override
  Future<List<CalendarEvent>> getAllEvents() async {
    final database = await _database;
    final rows = await database.query(
      'events',
      where: 'deleted_at_utc IS NULL',
      orderBy: 'is_all_day DESC, start_utc ASC, all_day_start ASC',
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  @override
  Future<List<CalendarEvent>> getImportedEvents(String sourcePrefix) async {
    final database = await _database;
    final rows = await database.query(
      'events',
      where: 'substr(import_source, 1, ?) = ?',
      whereArgs: [sourcePrefix.length, sourcePrefix],
    );
    return rows.map(_fromRow).toList();
  }

  @override
  Future<List<CalendarEvent>> getEventsForRange({
    required DateTime startLocal,
    required DateTime endLocal,
  }) async {
    final all = await getAllEvents();
    return all
        .where((event) {
          if (event.isAllDay) {
            return event.allDayStartDate!.isBefore(endLocal) &&
                event.allDayEndDateExclusive!.isAfter(startLocal);
          }
          return event.endUtc!.isAfter(startLocal.toUtc()) &&
              event.startUtc!.isBefore(endLocal.toUtc());
        })
        .toList(growable: false);
  }

  @override
  Future<void> save(CalendarEvent event) => saveBatch([event]);

  @override
  Future<void> delete(String id) => deleteBatch([id]);

  @override
  Future<void> saveBatch(List<CalendarEvent> events) => saveCourseBatch(events);

  Future<void> saveCourseBatch(
    List<CalendarEvent> events, {
    String? source,
    Map<String, dynamic>? calendar,
    bool migrate = false,
  }) async {
    final database = await _database;
    await database.transaction((transaction) async {
      if (source != null && calendar != null) {
        await TeachingCalendarStore.save(
          transaction,
          source,
          calendar,
          migrate: migrate,
        );
      }
      final batch = transaction.batch();
      for (final event in events) {
        batch.insert(
          'events',
          _toRow(event),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
      await SqliteSyncStore.track(
        transaction,
        events.map((event) => event.id).toList(),
      );
    });
    _localChanges.add(null);
  }

  @override
  Future<void> deleteBatch(List<String> ids) async {
    final database = await _database;
    final now = DateTime.now().toUtc().toIso8601String();
    await database.transaction((transaction) async {
      final batch = transaction.batch();
      for (final id in ids) {
        batch.rawUpdate(
          'UPDATE events SET deleted_at_utc = ?, updated_at_utc = ?, version = version + 1 WHERE id = ? AND deleted_at_utc IS NULL',
          [now, now, id],
        );
      }
      await batch.commit(noResult: true);
      await SqliteSyncStore.track(transaction, ids);
    });
    _localChanges.add(null);
  }

  Map<String, Object?> _toRow(CalendarEvent event) {
    return {
      'id': event.id,
      'title': event.title,
      'notes': event.notes,
      'color_key': event.color.key,
      'is_all_day': event.isAllDay ? 1 : 0,
      'start_utc': event.startUtc?.toUtc().toIso8601String(),
      'end_utc': event.endUtc?.toUtc().toIso8601String(),
      'all_day_start': event.allDayStartDate == null
          ? null
          : _dateKey(event.allDayStartDate!),
      'all_day_end_exclusive': event.allDayEndDateExclusive == null
          ? null
          : _dateKey(event.allDayEndDateExclusive!),
      'time_zone_id': event.timeZoneId,
      'recurrence_rule': event.recurrenceRule,
      'series_id': event.seriesId,
      'import_source': event.importSource,
      'import_fingerprint': event.importFingerprint,
      'created_at_utc': event.createdAtUtc.toUtc().toIso8601String(),
      'updated_at_utc': event.updatedAtUtc.toUtc().toIso8601String(),
      'version': event.version,
      'deleted_at_utc': event.deletedAtUtc?.toUtc().toIso8601String(),
    };
  }

  CalendarEvent _fromRow(Map<String, Object?> row) {
    return CalendarEvent.fromStorage(
      id: row['id']! as String,
      title: row['title'] as String? ?? '',
      notes: row['notes'] as String?,
      colorKey: row['color_key']! as String,
      timeZoneId: row['time_zone_id']! as String,
      startUtc: _parseDate(row['start_utc']),
      endUtc: _parseDate(row['end_utc']),
      allDayStartDate: _parseDate(row['all_day_start']),
      allDayEndDateExclusive: _parseDate(row['all_day_end_exclusive']),
      recurrenceRule: row['recurrence_rule'] as String?,
      seriesId: row['series_id'] as String?,
      importSource: row['import_source'] as String?,
      importFingerprint: row['import_fingerprint'] as String?,
      createdAtUtc: DateTime.parse(row['created_at_utc']! as String),
      updatedAtUtc: DateTime.parse(row['updated_at_utc']! as String),
      version: row['version'] as int? ?? 1,
      deletedAtUtc: _parseDate(row['deleted_at_utc']),
    );
  }

  DateTime? _parseDate(Object? value) {
    if (value == null) return null;
    return DateTime.parse(value as String);
  }

  String _dateKey(DateTime value) {
    final year = value.year.toString().padLeft(4, '0');
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  @override
  Future<void> close() async {
    final future = _databaseFuture;
    if (future == null) return;
    await (await future).close();
    _databaseFuture = null;
  }
}
