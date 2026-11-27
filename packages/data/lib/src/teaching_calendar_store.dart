import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

/// Confirmed dates belong to the import source, never to a school login or a
/// calendar event. A frozen write survives a restart and keeps its original base.
class TeachingCalendarStore {
  TeachingCalendarStore(this.database);
  final Future<Database> Function() database;
  static const _uuid = Uuid();
  static final _source = RegExp(
    r'^([a-z][a-z0-9_]{0,31}:[a-f0-9]{24}:(?:20\d{2}|2100)-(?:3|12|16)):',
  );
  static String? sourceKey(String? source) =>
      _source.firstMatch(source ?? '')?.group(1);

  static Future<void> createSchema(DatabaseExecutor db) async {
    await db.execute(
      'CREATE TABLE IF NOT EXISTS teaching_calendars (id TEXT PRIMARY KEY, calendar TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS sync_teaching_sets (scope TEXT PRIMARY KEY, revision TEXT NOT NULL, entries TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS sync_teaching_pending (scope TEXT NOT NULL,id TEXT NOT NULL,calendar TEXT NOT NULL,base TEXT,flight TEXT,PRIMARY KEY(scope,id))',
    );
  }

  static Future<void> activate(
    DatabaseExecutor tx,
    String scope, {
    required bool merge,
    required bool reset,
  }) async {
    if (reset) {
      await tx.delete(
        'sync_teaching_sets',
        where: 'scope=?',
        whereArgs: [scope],
      );
      await tx.update(
        'sync_teaching_pending',
        {'base': null, 'flight': null},
        where: 'scope=?',
        whereArgs: [scope],
      );
    }
    if (merge) {
      await tx.rawInsert(
        'INSERT OR IGNORE INTO sync_teaching_pending(scope,id,calendar) SELECT ?,id,calendar FROM teaching_calendars',
        [scope],
      );
    }
  }

  static Future<Map<String, dynamic>> _entries(
    DatabaseExecutor tx,
    String scope,
  ) async {
    final rows = await tx.query(
      'sync_teaching_sets',
      where: 'scope=?',
      whereArgs: [scope],
    );
    return rows.isEmpty
        ? {}
        : jsonDecode(rows.single['entries'] as String) as Map<String, dynamic>;
  }

  Future<String> revision(String scope) async {
    final rows = await (await database()).query(
      'sync_teaching_sets',
      columns: ['revision'],
      where: 'scope=?',
      whereArgs: [scope],
    );
    return rows.isEmpty ? 'unknown' : rows.single['revision']! as String;
  }

  static bool _same(Object? a, Object? b) =>
      a is Map &&
      b is Map &&
      a['first_monday'] == b['first_monday'] &&
      a['weeks'] == b['weeks'];

  static Future<bool> save(
    DatabaseExecutor tx,
    String id,
    Map<String, dynamic> calendar, {
    bool migrate = false,
  }) async {
    if (sourceKey('$id:') != id) throw ArgumentError('课程来源无效');
    final old = await tx.query(
      'teaching_calendars',
      where: 'id=?',
      whereArgs: [id],
    );
    if (migrate && old.isNotEmpty) return false;
    final profiles = await tx.query('sync_profiles', where: 'active=1');
    final encoded = jsonEncode(calendar);
    await tx.insert('teaching_calendars', {
      'id': id,
      'calendar': encoded,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    if (profiles.isEmpty) return true;
    final scope = profiles.single['scope'] as String;
    final head = (await _entries(tx, scope))[id] as Map?;
    if (migrate && head != null) return true;
    final pending = await tx.query(
      'sync_teaching_pending',
      where: 'scope=? AND id=?',
      whereArgs: [scope, id],
    );
    if (pending.isEmpty && _same(head?['calendar'], calendar)) return true;
    if (pending.isEmpty) {
      await tx.insert('sync_teaching_pending', {
        'scope': scope,
        'id': id,
        'base': head?['revision'],
        'calendar': encoded,
      });
    } else {
      await tx.update(
        'sync_teaching_pending',
        {'calendar': encoded},
        where: 'scope=? AND id=?',
        whereArgs: [scope, id],
      );
    }
    return true;
  }

  Future<Map<String, Map<String, dynamic>>> read() async {
    final db = await database();
    return db.transaction((tx) async {
      final result = <String, Map<String, dynamic>>{
        for (final r in await tx.query('teaching_calendars'))
          r['id'] as String: jsonDecode(r['calendar'] as String),
      };
      final p = await tx.query('sync_profiles', where: 'active=1');
      if (p.isEmpty) return result;
      final scope = p.single['scope']! as String;
      for (final entry in (await _entries(tx, scope)).entries) {
        result[entry.key] = Map<String, dynamic>.from(
          entry.value['calendar'] as Map,
        );
      }
      for (final r in await tx.query(
        'sync_teaching_pending',
        where: 'scope=?',
        whereArgs: [scope],
      )) {
        result[r['id'] as String] = jsonDecode(r['calendar'] as String);
      }
      return result;
    });
  }

  Future<bool> apply(String scope, Map<String, dynamic> set) async {
    final db = await database();
    return db.transaction((tx) async {
      final revision = set['revision'] as String;
      final prior = await tx.query(
        'sync_teaching_sets',
        where: 'scope=?',
        whereArgs: [scope],
      );
      final heads = set['entries'] as Map;
      for (final row in await tx.query(
        'sync_teaching_pending',
        where: 'scope=?',
        whereArgs: [scope],
      )) {
        final id = row['id'] as String;
        final head = heads[id] as Map?;
        final desired = jsonDecode(row['calendar'] as String);
        final flight = row['flight'] == null
            ? null
            : jsonDecode(row['flight'] as String) as Map;
        final accepted =
            head != null &&
            flight != null &&
            (head['revision'] == flight['write_id'] ||
                _same(head['calendar'], flight['calendar']));
        if (accepted && !_same(desired, head['calendar'])) {
          await tx.update(
            'sync_teaching_pending',
            {'base': head['revision'], 'flight': null},
            where: 'scope=? AND id=?',
            whereArgs: [scope, id],
          );
        } else if (_same(desired, head?['calendar']) ||
            row['base'] != head?['revision']) {
          // A simultaneous different import keeps the committed calendar. No
          // speculative rebasing of old offline preferences over a newer head.
          await tx.delete(
            'sync_teaching_pending',
            where: 'scope=? AND id=?',
            whereArgs: [scope, id],
          );
        }
      }
      await tx.insert('sync_teaching_sets', {
        'scope': scope,
        'revision': revision,
        'entries': jsonEncode(heads),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return (prior.firstOrNull?['revision'] ?? 'none') != revision;
    });
  }

  // A live local record with a confirmed, nonconflicting head belongs to this
  // destination; pending calendar changes for unrelated offline courses do not.
  static const _sharedPending =
      ' FROM sync_teaching_pending p JOIN sync_profiles s USING(scope) '
      'WHERE p.scope=? AND EXISTS(SELECT 1 FROM events e JOIN sync_heads h ON h.id=e.id AND h.scope=p.scope '
      "WHERE substr(e.import_source,1,length(p.id)+1)=p.id||':' AND e.deleted_at_utc IS NULL "
      'AND NOT EXISTS(SELECT 1 FROM sync_conflicts c WHERE c.id=e.id AND c.scope=p.scope))';

  Future<int> pendingCount(String scope) async =>
      (await (await database()).rawQuery(
            'SELECT count(*) AS n$_sharedPending',
            [scope],
          )).single['n']!
          as int;

  Future<Map<String, dynamic>?> prepare(String scope) async {
    final db = await database();
    return db.transaction((tx) async {
      // Only the destination that actually has a shared course receives its
      // term. A cloud-only first connection leaves unrelated local terms here.
      final rows = await tx.rawQuery(
        'SELECT p.*,s.dataset_id,s.epoch$_sharedPending ORDER BY p.id LIMIT 1',
        [scope],
      );
      if (rows.isEmpty) return null;
      final r = rows.single;
      if (r['flight'] != null)
        return jsonDecode(r['flight'] as String) as Map<String, dynamic>;
      final write = <String, dynamic>{
        'key': r['id'],
        'dataset_id': r['dataset_id'],
        'sync_epoch': r['epoch'],
        'base_revision': r['base'],
        'write_id': _uuid.v4(),
        'calendar': jsonDecode(r['calendar'] as String),
      };
      await tx.update(
        'sync_teaching_pending',
        {'flight': jsonEncode(write)},
        where: 'scope=? AND id=?',
        whereArgs: [scope, r['id']],
      );
      return write;
    });
  }
}
