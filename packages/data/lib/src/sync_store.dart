import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

import 'sleep_schedule_store.dart';
import 'teaching_calendar_store.dart';

class SyncRequestException implements Exception {
  SyncRequestException(this.status, this.code, this.payload);
  final int status;
  final String code;
  final Map<String, dynamic> payload;
  @override
  String toString() => '同步请求失败（$status / $code）';
}

class SyncConflict {
  SyncConflict(this.id, this.local, this.remote);
  final String id;
  final Map<String, dynamic>? local;
  final Map<String, dynamic>? remote;
  String get localTitle => local?['title'] as String? ?? '已删除';
  String get remoteTitle => remote?['event']?['title'] as String? ?? '已删除';
  bool get remoteDeleted => remote?['event'] == null;
}

/// Persistent sync metadata shares the calendar's SQLite transactions.
class SqliteSyncStore {
  SqliteSyncStore(this.database);
  final Future<Database> Function() database;
  static const _uuid = Uuid();

  static Future<void> createSchema(DatabaseExecutor db) async {
    for (final sql in [
      'CREATE TABLE IF NOT EXISTS sync_profiles (scope TEXT PRIMARY KEY, server_id TEXT NOT NULL, account_id TEXT NOT NULL, dataset_id TEXT NOT NULL, epoch TEXT NOT NULL, device_id TEXT NOT NULL, cursor TEXT, active INTEGER NOT NULL DEFAULT 0, reset_heads INTEGER NOT NULL DEFAULT 0)',
      'CREATE TABLE IF NOT EXISTS sync_heads (scope TEXT NOT NULL, id TEXT NOT NULL, revision TEXT NOT NULL, record TEXT NOT NULL, PRIMARY KEY(scope,id))',
      'CREATE TABLE IF NOT EXISTS sync_dirty (scope TEXT NOT NULL, id TEXT NOT NULL, serial INTEGER NOT NULL, group_id TEXT NOT NULL, payload TEXT, PRIMARY KEY(scope,id))',
      'CREATE TABLE IF NOT EXISTS sync_flight (scope TEXT PRIMARY KEY, request TEXT NOT NULL, serials TEXT NOT NULL)',
      'CREATE TABLE IF NOT EXISTS sync_own_batches (scope TEXT NOT NULL, batch_id TEXT NOT NULL, PRIMARY KEY(scope,batch_id))',
      'CREATE TABLE IF NOT EXISTS sync_conflicts (scope TEXT NOT NULL, id TEXT NOT NULL, remote TEXT, PRIMARY KEY(scope,id))',
      'CREATE TABLE IF NOT EXISTS sync_clock (id INTEGER PRIMARY KEY CHECK(id=1), value INTEGER NOT NULL)',
      'INSERT OR IGNORE INTO sync_clock(id,value) VALUES(1,0)',
    ]) {
      await db.execute(sql);
    }
    await createRejectedFlightSchema(db);
  }

  static Future<void> createRejectedFlightSchema(DatabaseExecutor db) =>
      db.execute(
        'CREATE TABLE IF NOT EXISTS sync_rejected_flights (scope TEXT PRIMARY KEY, batch_id TEXT NOT NULL)',
      );

  static Map<String, dynamic> wireRow(Map<String, Object?> row) {
    final result = Map<String, dynamic>.from(row);
    result['is_all_day'] = row['is_all_day'] == 1;
    return result;
  }

  static Future<void> track(DatabaseExecutor tx, List<String> ids) async {
    final profiles = await tx.query('sync_profiles', where: 'active=1');
    if (profiles.isEmpty) return;
    final scope = profiles.single['scope']! as String;
    final group = _uuid.v4();
    for (final id in ids.toSet()) {
      final rows = await tx.query('events', where: 'id=?', whereArgs: [id]);
      if (rows.isEmpty) continue;
      final row = rows.single;
      await _dirty(
        tx,
        scope,
        id,
        row['deleted_at_utc'] == null ? wireRow(row) : null,
        group,
      );
    }
  }

  static Future<void> _dirty(
    DatabaseExecutor tx,
    String scope,
    String id,
    Map<String, dynamic>? payload,
    String group,
  ) async {
    await tx.rawUpdate('UPDATE sync_clock SET value=value+1 WHERE id=1');
    final serial = (await tx.query('sync_clock')).single['value'];
    await tx.insert('sync_dirty', {
      'scope': scope,
      'id': id,
      'serial': serial,
      'group_id': group,
      'payload': payload == null ? null : jsonEncode(payload),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static String scopeKey(String server, String account, String dataset) =>
      jsonEncode([server, account, dataset]);

  Future<String> activate({
    required String serverId,
    required String accountId,
    required String datasetId,
    required String epoch,
    required String deviceId,
    required bool uploadLocal,
  }) async {
    final scope = scopeKey(serverId, accountId, datasetId);
    final db = await database();
    await db.transaction((tx) async {
      final old = await tx.query(
        'sync_profiles',
        where: 'scope=?',
        whereArgs: [scope],
      );
      if (old.isNotEmpty &&
          (old.single['active'] != 1 || old.single['epoch'] != epoch)) {
        await SqliteSleepScheduleStore.reset(tx, scope);
      }
      await TeachingCalendarStore.activate(
        tx,
        scope,
        merge: old.isEmpty && uploadLocal,
        reset: old.isNotEmpty && old.single['epoch'] != epoch,
      );
      await tx.update('sync_profiles', {'active': 0});
      if (old.isEmpty) {
        await tx.insert('sync_profiles', {
          'scope': scope,
          'server_id': serverId,
          'account_id': accountId,
          'dataset_id': datasetId,
          'epoch': epoch,
          'device_id': deviceId,
          'active': 1,
        });
        if (uploadLocal) {
          final rows = await tx.query(
            'events',
            where: 'deleted_at_utc IS NULL',
          );
          final group = _uuid.v4();
          for (final row in rows) {
            await _dirty(tx, scope, row['id']! as String, wireRow(row), group);
          }
        }
      } else {
        // A replaced server epoch requires a fresh snapshot, preserving dirty data.
        final changedEpoch = old.single['epoch'] != epoch;
        await tx.update(
          'sync_profiles',
          {
            'active': 1,
            'epoch': epoch,
            'device_id': deviceId,
            if (changedEpoch) 'cursor': null,
            if (changedEpoch) 'reset_heads': 1,
          },
          where: 'scope=?',
          whereArgs: [scope],
        );
        if (changedEpoch) await _clearFlight(tx, scope);
      }
    });
    return scope;
  }

  Future<Map<String, dynamic>> profile(String scope) async =>
      Map<String, dynamic>.from(
        (await (await database()).query(
          'sync_profiles',
          where: 'scope=?',
          whereArgs: [scope],
        )).single,
      );

  Future<int> pendingCount(String scope) async {
    final rows = await (await database()).rawQuery(
      'SELECT count(*) AS n FROM sync_dirty WHERE scope=?',
      [scope],
    );
    return rows.single['n']! as int;
  }

  Future<List<SyncConflict>> conflicts(String scope) async {
    final db = await database();
    final rows = await db.rawQuery(
      'SELECT c.id,c.remote,d.payload FROM sync_conflicts c LEFT JOIN sync_dirty d ON c.scope=d.scope AND c.id=d.id WHERE c.scope=?',
      [scope],
    );
    return rows
        .map(
          (r) => SyncConflict(
            r['id']! as String,
            _decode(r['payload']),
            _decode(r['remote']),
          ),
        )
        .toList();
  }

  Future<Map<String, dynamic>?> flight(String scope) async {
    final rows = await (await database()).query(
      'sync_flight',
      where: 'scope=?',
      whereArgs: [scope],
    );
    return rows.isEmpty ? null : _decode(rows.single['request']);
  }

  /// Only a first POST definitively denied by the server can mark a flight.
  /// A timed-out earlier attempt may still commit, even if its receipt is absent.
  Future<void> markFlightRejected(String scope, String batchId) async {
    final db = await database();
    await db.insert('sync_rejected_flights', {
      'scope': scope,
      'batch_id': batchId,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// After receipt lookup and pull, release only the frozen request. Dirty
  /// serials and operation groups remain intact for re-freezing.
  Future<bool> releaseRejectedFlight(String scope, String batchId) async {
    final db = await database();
    return db.transaction((tx) async {
      final rejected = await tx.query(
        'sync_rejected_flights',
        where: 'scope=? AND batch_id=?',
        whereArgs: [scope, batchId],
      );
      if (rejected.isEmpty) return false;
      final rows = await tx.query(
        'sync_flight',
        where: 'scope=?',
        whereArgs: [scope],
      );
      if (rows.isEmpty ||
          _decode(rows.single['request'])!['batch_id'] != batchId)
        return false;
      await _clearFlight(tx, scope);
      return true;
    });
  }

  static Future<void> _clearFlight(DatabaseExecutor tx, String scope) async {
    await tx.delete('sync_flight', where: 'scope=?', whereArgs: [scope]);
    await tx.delete(
      'sync_rejected_flights',
      where: 'scope=?',
      whereArgs: [scope],
    );
  }

  Future<Map<String, dynamic>?> freeze(String scope) async {
    final db = await database();
    return db.transaction((tx) async {
      final previous = await tx.query(
        'sync_flight',
        where: 'scope=?',
        whereArgs: [scope],
      );
      if (previous.isNotEmpty) return _decode(previous.single['request']);
      final p = (await tx.query(
        'sync_profiles',
        where: 'scope=?',
        whereArgs: [scope],
      )).single;
      if (p['cursor'] == null) throw StateError('首次快照尚未完成');
      final dirty = await tx.rawQuery(
        'SELECT d.*,h.revision FROM sync_dirty d LEFT JOIN sync_heads h ON h.scope=d.scope AND h.id=d.id WHERE d.scope=? AND NOT EXISTS (SELECT 1 FROM sync_conflicts c JOIN sync_dirty cd ON c.scope=cd.scope AND c.id=cd.id WHERE c.scope=d.scope AND cd.group_id=d.group_id) ORDER BY d.serial LIMIT 100',
        [scope],
      );
      final mutations = <Map<String, dynamic>>[];
      final serials = <String, dynamic>{};
      final request = <String, dynamic>{
        'batch_id': _uuid.v4(),
        'device_id': p['device_id'],
        'dataset_id': p['dataset_id'],
        'sync_epoch': p['epoch'],
        'mutations': mutations,
      };
      for (final row in dirty) {
        final id = row['id']! as String;
        if (row['payload'] == null && row['revision'] == null) {
          // Created and deleted without ever reaching this server.
          await tx.delete(
            'sync_dirty',
            where: 'scope=? AND id=?',
            whereArgs: [scope, id],
          );
          continue;
        }
        final payload = _decode(row['payload']);
        if (payload != null &&
            utf8.encode(jsonEncode(payload)).length > 131072) {
          throw StateError('日程内容过长，暂时无法同步；本地内容已保留');
        }
        mutations.add({
          'mutation_id': _uuid.v4(),
          'event_id': id,
          'base_revision': row['revision'],
          'operation': payload == null ? 'delete' : 'put',
          'event': payload,
        });
        if (utf8.encode(jsonEncode(request)).length > 2097152) {
          mutations.removeLast();
          break;
        }
        serials[id] = row['serial'];
      }
      if (mutations.isEmpty) return null;
      await tx.insert('sync_flight', {
        'scope': scope,
        'request': jsonEncode(request),
        'serials': jsonEncode(serials),
      });
      return request;
    });
  }

  Future<void> acceptReceipt(String scope, Map<String, dynamic> receipt) async {
    final db = await database();
    await db.transaction((tx) async {
      final rows = await tx.query(
        'sync_flight',
        where: 'scope=?',
        whereArgs: [scope],
      );
      if (rows.isEmpty) return;
      final request = _decode(rows.single['request'])!;
      if (request['batch_id'] != receipt['batch_id'])
        throw StateError('同步回执与批次不符');
      final serials = _decode(rows.single['serials'])!;
      final results = {
        for (final dynamic r in receipt['results'] as List)
          r['event_id'] as String: r,
      };
      for (final dynamic m in request['mutations'] as List) {
        final id = m['event_id'] as String;
        final result = results[id];
        if (result == null || result['mutation_id'] != m['mutation_id'])
          throw StateError('同步回执不完整');
        final record = <String, dynamic>{
          'id': id,
          'revision': result['revision'],
          'event': m['event'],
          'deleted_at_utc': m['operation'] == 'delete'
              ? receipt['committed_at']
              : null,
        };
        await _head(tx, scope, record);
        await tx.delete(
          'sync_dirty',
          where: 'scope=? AND id=? AND serial=?',
          whereArgs: [scope, id, serials[id]],
        );
      }
      await tx.insert('sync_own_batches', {
        'scope': scope,
        'batch_id': request['batch_id'],
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      await _clearFlight(tx, scope);
      // Do not advance pull cursor: other devices may have committed before us.
    });
  }

  Future<void> rejectFlight(String scope, List<dynamic> conflicts) async {
    final db = await database();
    await db.transaction((tx) async {
      for (final dynamic c in conflicts) {
        // A user may have chosen the cloud version while a read-only session
        // still held this immutable flight. Only pending edits can conflict.
        final dirty = await tx.query(
          'sync_dirty',
          columns: ['id'],
          where: 'scope=? AND id=?',
          whereArgs: [scope, c['event_id']],
        );
        if (dirty.isEmpty) continue;
        await tx.insert('sync_conflicts', {
          'scope': scope,
          'id': c['event_id'],
          'remote': c['current'] == null ? null : jsonEncode(c['current']),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await _clearFlight(tx, scope);
    });
  }

  Future<void> resetCursor(String scope, {bool abandonFlight = false}) async {
    final db = await database();
    await db.transaction((tx) async {
      await tx.update(
        'sync_profiles',
        {'cursor': null},
        where: 'scope=?',
        whereArgs: [scope],
      );
      if (abandonFlight) await _clearFlight(tx, scope);
    });
  }

  Future<bool> applySnapshot(
    String scope,
    List<Map<String, dynamic>> records,
    String boundary,
    String epoch,
  ) async {
    final db = await database();
    return db.transaction((tx) async {
      final oldHeads = await tx.query(
        'sync_heads',
        where: 'scope=?',
        whereArgs: [scope],
      );
      final profile = (await tx.query(
        'sync_profiles',
        where: 'scope=?',
        whereArgs: [scope],
      )).single;
      final resetHeads =
          profile['reset_heads'] == 1 || profile['epoch'] != epoch;
      if (profile['epoch'] != epoch) {
        await _clearFlight(tx, scope);
        await SqliteSleepScheduleStore.reset(tx, scope);
        await TeachingCalendarStore.activate(
          tx,
          scope,
          merge: false,
          reset: true,
        );
      }
      final ids = records.map((r) => r['id']).toSet();
      // After server restore, do not silently discard data absent from its snapshot.
      for (final old in oldHeads.where(
        (h) => resetHeads && !ids.contains(h['id']),
      )) {
        final local = await tx.query(
          'events',
          where: 'id=? AND deleted_at_utc IS NULL',
          whereArgs: [old['id']],
        );
        if (local.isNotEmpty) {
          await _dirty(
            tx,
            scope,
            old['id']! as String,
            wireRow(local.single),
            _uuid.v4(),
          );
          await tx.insert('sync_conflicts', {
            'scope': scope,
            'id': old['id'],
            'remote': null,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      if (resetHeads)
        await tx.delete('sync_heads', where: 'scope=?', whereArgs: [scope]);
      var changed = false;
      for (final record in records) {
        changed = await _apply(tx, scope, record, false) || changed;
      }
      // Clear only stale baselines absent from this complete snapshot.
      for (final old in oldHeads.where(
        (h) => resetHeads && !ids.contains(h['id']),
      )) {
        await tx.delete(
          'sync_heads',
          where: 'scope=? AND id=?',
          whereArgs: [scope, old['id']],
        );
      }
      await tx.update(
        'sync_profiles',
        {'cursor': boundary, 'epoch': epoch, 'reset_heads': 0},
        where: 'scope=?',
        whereArgs: [scope],
      );
      return changed;
    });
  }

  Future<bool> applyChanges(String scope, Map<String, dynamic> page) async =>
      (await applyChangePage(scope, page)).calendarChanged;

  Future<({bool calendarChanged, bool sleepChanged})> applyChangePage(
    String scope,
    Map<String, dynamic> page, {
    bool includeSleepSchedule = false,
  }) async {
    final db = await database();
    return db.transaction((tx) async {
      var changed = false;
      for (final dynamic batch in page['changes'] as List) {
        final own = (await tx.query(
          'sync_own_batches',
          where: 'scope=? AND batch_id=?',
          whereArgs: [scope, batch['batch_id']],
        )).isNotEmpty;
        for (final dynamic r in batch['records'] as List) {
          changed =
              await _apply(
                tx,
                scope,
                Map<String, dynamic>.from(r as Map),
                own,
              ) ||
              changed;
        }
      }
      await tx.update(
        'sync_profiles',
        {'cursor': page['next_cursor']},
        where: 'scope=?',
        whereArgs: [scope],
      );
      final sleepChanged =
          includeSleepSchedule && page.containsKey('sleep_schedule')
          ? await SqliteSleepScheduleStore.apply(
              tx,
              scope,
              page['sleep_schedule'],
            )
          : false;
      return (calendarChanged: changed, sleepChanged: sleepChanged);
    });
  }

  static Future<bool> _apply(
    DatabaseExecutor tx,
    String scope,
    Map<String, dynamic> record,
    bool own,
  ) async {
    final id = record['id'] as String;
    final prior = await tx.query(
      'sync_heads',
      where: 'scope=? AND id=?',
      whereArgs: [scope, id],
    );
    if (prior.isNotEmpty &&
        BigInt.parse(prior.single['revision']! as String) >=
            BigInt.parse(record['revision'] as String))
      return false;
    final dirty = await tx.query(
      'sync_dirty',
      where: 'scope=? AND id=?',
      whereArgs: [scope, id],
    );
    final local = await tx.query('events', where: 'id=?', whereArgs: [id]);
    final payload = record['event'] == null
        ? null
        : Map<String, dynamic>.from(record['event'] as Map);
    final localPayload = local.isEmpty || local.single['deleted_at_utc'] != null
        ? null
        : wireRow(local.single);
    if (dirty.isNotEmpty) {
      final pending = _decode(dirty.single['payload']);
      if (_same(pending, payload)) {
        await tx.delete(
          'sync_dirty',
          where: 'scope=? AND id=?',
          whereArgs: [scope, id],
        );
        await tx.delete(
          'sync_conflicts',
          where: 'scope=? AND id=?',
          whereArgs: [scope, id],
        );
      } else if (!own) {
        await tx.insert('sync_conflicts', {
          'scope': scope,
          'id': id,
          'remote': jsonEncode(record),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await _head(tx, scope, record);
      return false;
    }
    if (prior.isEmpty && local.isNotEmpty && !_same(localPayload, payload)) {
      await _dirty(tx, scope, id, localPayload, _uuid.v4());
      await tx.insert('sync_conflicts', {
        'scope': scope,
        'id': id,
        'remote': jsonEncode(record),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await _head(tx, scope, record);
      return false;
    }
    await _head(tx, scope, record);
    if (_same(localPayload, payload)) return false;
    await _writeRecord(tx, record);
    return true;
  }

  static Future<void> _head(
    DatabaseExecutor tx,
    String scope,
    Map<String, dynamic> record,
  ) async {
    final previous = await tx.query(
      'sync_heads',
      where: 'scope=? AND id=?',
      whereArgs: [scope, record['id']],
    );
    if (previous.isNotEmpty &&
        BigInt.parse(previous.single['revision']! as String) >
            BigInt.parse(record['revision'] as String))
      return;
    await tx.insert('sync_heads', {
      'scope': scope,
      'id': record['id'],
      'revision': record['revision'],
      'record': jsonEncode(record),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> _writeRecord(
    DatabaseExecutor tx,
    Map<String, dynamic> record,
  ) async {
    if (record['event'] == null) {
      await tx.update(
        'events',
        {
          'deleted_at_utc':
              record['deleted_at_utc'] ??
              DateTime.now().toUtc().toIso8601String(),
        },
        where: 'id=?',
        whereArgs: [record['id']],
      );
    } else {
      final row = Map<String, Object?>.from(record['event'] as Map);
      row['is_all_day'] = row['is_all_day'] == true ? 1 : 0;
      row['deleted_at_utc'] = null;
      await tx.insert(
        'events',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  Future<bool> resolve(
    String scope,
    String id, {
    required bool useLocal,
  }) async {
    final db = await database();
    return db.transaction((tx) async {
      final conflicts = await tx.query(
        'sync_conflicts',
        where: 'scope=? AND id=?',
        whereArgs: [scope, id],
      );
      if (conflicts.isEmpty) return false;
      final remote = _decode(conflicts.single['remote']);
      if (remote != null) {
        await _head(tx, scope, remote);
      } else {
        await tx.delete(
          'sync_heads',
          where: 'scope=? AND id=?',
          whereArgs: [scope, id],
        );
      }
      if (!useLocal) {
        await _writeRecord(
          tx,
          remote ??
              {
                'id': id,
                'event': null,
                'deleted_at_utc': DateTime.now().toUtc().toIso8601String(),
              },
        );
        await tx.delete(
          'sync_dirty',
          where: 'scope=? AND id=?',
          whereArgs: [scope, id],
        );
      }
      await tx.delete(
        'sync_conflicts',
        where: 'scope=? AND id=?',
        whereArgs: [scope, id],
      );
      return !useLocal;
    });
  }

  static Map<String, dynamic>? _decode(Object? value) => value == null
      ? null
      : Map<String, dynamic>.from(jsonDecode(value as String) as Map);
  static Object? _sort(Object? value) {
    if (value is Map)
      return {
        for (final key in value.keys.map((e) => e as String).toList()..sort())
          key: _sort(value[key]),
      };
    if (value is List) return value.map(_sort).toList();
    return value;
  }

  static bool _same(Object? a, Object? b) =>
      jsonEncode(_sort(a)) == jsonEncode(_sort(b));
}
