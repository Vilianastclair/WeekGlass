import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

class SleepScheduleConflict {
  const SleepScheduleConflict(this.local, this.remote, this.remoteRevision);

  final SleepSchedule local;
  final SleepSchedule remote;
  final String remoteRevision;
}

/// Keeps one explicit device preference, plus the active cloud baseline and
/// any ambiguous write. An implicit display default is never stored here.
class SqliteSleepScheduleStore {
  SqliteSleepScheduleStore(this.database);
  final Future<Database> Function() database;
  static const _uuid = Uuid();

  static Future<void> createSchema(DatabaseExecutor db) async {
    await db.execute(
      'CREATE TABLE IF NOT EXISTS planner_sleep_schedule (id INTEGER PRIMARY KEY CHECK(id=1), schedule TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS sync_sleep_schedule (scope TEXT PRIMARY KEY, remote TEXT, flight TEXT, conflict INTEGER NOT NULL)',
    );
  }

  Future<SleepSchedule?> read() async => _read(await database());

  Future<bool> save(SleepSchedule schedule, {bool migrate = false}) async {
    if (!schedule.valid) throw ArgumentError('无效的睡眠时段');
    return (await database()).transaction((tx) async {
      final old = await _read(tx);
      if (migrate && old != null || _same(old, schedule)) return false;
      await _write(tx, schedule);
      // If the user manually matches a conflict's cloud version, it is resolved.
      final rows = await tx.rawQuery(
        'SELECT s.scope,s.remote FROM sync_sleep_schedule s JOIN sync_profiles p USING(scope) WHERE p.active=1 AND s.conflict=1',
      );
      if (rows.isNotEmpty &&
          _same(_head(rows.single['remote'])?.schedule, schedule)) {
        await _update(tx, rows.single['scope']! as String, {'conflict': 0});
      }
      return true;
    });
  }

  static Future<void> reset(DatabaseExecutor tx, String scope) async {
    await tx.delete(
      'sync_sleep_schedule',
      where: 'scope=?',
      whereArgs: [scope],
    );
  }

  Future<String> revision(String scope) async {
    final state = await _state(await database(), scope);
    return state == null
        ? 'unknown'
        : _head(state['remote'])?.revision ?? 'none';
  }

  Future<({SleepScheduleConflict? conflict, bool pending})> status(
    String scope,
  ) async {
    final db = await database();
    final local = await _read(db);
    final state = await _state(db, scope);
    final remote = _head(state?['remote']);
    final different = local != null && !_same(local, remote?.schedule);
    return (
      conflict: different && state?['conflict'] == 1 && remote != null
          ? SleepScheduleConflict(local, remote.schedule, remote.revision)
          : null,
      pending: state != null && (different || state['flight'] != null),
    );
  }

  /// Applies the singleton head in the same transaction as a calendar change
  /// page. A known first cloud value and a different explicit local value
  /// need a choice, not a tie-breaker based on time or device.
  static Future<bool> apply(
    DatabaseExecutor tx,
    String scope,
    Object? record,
  ) async {
    final incoming = record == null ? null : _Head.fromWire(record as Map);
    final state = await _state(tx, scope);
    final previous = _head(state?['remote']);
    if (state != null && previous?.revision == incoming?.revision) return false;

    final local = await _read(tx);
    final flight = _map(state?['flight']);
    final ownWrite =
        incoming != null && flight?['write_id'] == incoming.writeId;
    final adopt =
        incoming != null &&
        !ownWrite &&
        (local == null ||
            (state != null &&
                flight == null &&
                _same(local, previous?.schedule)));
    final different =
        local != null && incoming != null && !_same(local, incoming.schedule);
    final conflict = different && !adopt && !ownWrite;

    if (adopt && !_same(local, incoming.schedule)) {
      await _write(tx, incoming.schedule);
    }
    // A changed base makes any other frozen CAS attempt inapplicable. If
    // this is our own echo, keep a newer local edit and send it on this base.
    await tx.insert('sync_sleep_schedule', {
      'scope': scope,
      'remote': record == null ? null : jsonEncode(record),
      'conflict': conflict ? 1 : 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return adopt && !_same(local, incoming.schedule);
  }

  /// Freeze before sending so a dropped response or restart can reconcile
  /// the same write ID on the next pull, without losing a later local edit.
  Future<Map<String, dynamic>?> prepare(String scope) async {
    return (await database()).transaction((tx) async {
      final state = await _state(tx, scope);
      if (state == null || state['conflict'] == 1) return null;
      final flight = _map(state['flight']);
      if (flight != null) return flight;
      final local = await _read(tx);
      final remote = _head(state['remote']);
      if (local == null || _same(local, remote?.schedule)) return null;
      final profile = (await tx.query(
        'sync_profiles',
        where: 'scope=?',
        whereArgs: [scope],
      )).single;
      final request = <String, dynamic>{
        'dataset_id': profile['dataset_id'],
        'sync_epoch': profile['epoch'],
        'base_revision': remote?.revision,
        'write_id': _uuid.v4(),
        'schedule': _toWire(local),
      };
      await _update(tx, scope, {'flight': jsonEncode(request)});
      return request;
    });
  }

  Future<bool> accept(String scope, Map<String, dynamic>? record) async {
    return (await database()).transaction((tx) => apply(tx, scope, record));
  }

  Future<bool> resolve(
    String scope,
    String revision, {
    required bool useLocal,
  }) async {
    return (await database()).transaction((tx) async {
      final state = await _state(tx, scope);
      if (state?['conflict'] != 1) return false;
      final remote = _head(state?['remote']);
      if (remote == null || remote.revision != revision) return false;
      if (!useLocal) await _write(tx, remote.schedule);
      await _update(tx, scope, {'conflict': 0});
      return !useLocal;
    });
  }

  static Future<SleepSchedule?> _read(DatabaseExecutor db) async {
    final rows = await db.query('planner_sleep_schedule');
    return rows.isEmpty ? null : _fromWire(_map(rows.single['schedule'])!);
  }

  static Future<void> _write(
    DatabaseExecutor db,
    SleepSchedule schedule,
  ) async {
    await db.insert('planner_sleep_schedule', {
      'id': 1,
      'schedule': jsonEncode(_toWire(schedule)),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<Map<String, Object?>?> _state(
    DatabaseExecutor db,
    String scope,
  ) async {
    final rows = await db.query(
      'sync_sleep_schedule',
      where: 'scope=?',
      whereArgs: [scope],
    );
    return rows.isEmpty ? null : rows.single;
  }

  static Future<void> _update(
    DatabaseExecutor db,
    String scope,
    Map<String, Object?> values,
  ) async {
    await db.update(
      'sync_sleep_schedule',
      values,
      where: 'scope=?',
      whereArgs: [scope],
    );
  }

  static Map<String, dynamic>? _map(Object? json) =>
      json == null ? null : jsonDecode(json as String) as Map<String, dynamic>;
  static _Head? _head(Object? json) =>
      json == null ? null : _Head.fromWire(_map(json)!);

  static bool _same(SleepSchedule? a, SleepSchedule? b) =>
      a?.enabled == b?.enabled &&
      a?.sleepMinute == b?.sleepMinute &&
      a?.wakeMinute == b?.wakeMinute;

  static Map<String, dynamic> _toWire(SleepSchedule value) => {
    'enabled': value.enabled,
    'sleep_minute': value.sleepMinute,
    'wake_minute': value.wakeMinute,
  };

  static SleepSchedule _fromWire(Map value) {
    final schedule = SleepSchedule(
      enabled: value['enabled'] as bool,
      sleepMinute: value['sleep_minute'] as int,
      wakeMinute: value['wake_minute'] as int,
    );
    if (!schedule.valid) throw const FormatException('无效的云端睡眠时段');
    return schedule;
  }
}

class _Head {
  const _Head(this.revision, this.writeId, this.schedule);
  factory _Head.fromWire(Map record) => _Head(
    record['revision'] as String,
    record['write_id'] as String,
    SqliteSleepScheduleStore._fromWire(record['schedule'] as Map),
  );
  final String revision;
  final String writeId;
  final SleepSchedule schedule;
}
