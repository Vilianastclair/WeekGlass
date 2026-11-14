import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weekglass_data/weekglass_data.dart';
import 'package:weekglass_domain/weekglass_domain.dart';
import 'package:weekglass/features/cloud/cloud_sync_engine.dart';

CalendarEvent event(String id, {String title = '本地', int version = 1}) =>
    CalendarEvent.timed(
      id: id,
      title: title,
      startLocal: DateTime.utc(2026, 11, 5, 1),
      endLocal: DateTime.utc(2026, 11, 5, 2),
      timeZoneId: 'Asia/Shanghai',
      version: version,
      createdAtUtc: DateTime.utc(2026, 11, 1),
      updatedAtUtc: DateTime.utc(2026, 11, 5),
    );

Map<String, dynamic> receipt(
  Map<String, dynamic> batch, {
  String revision = '1',
}) => {
  'batch_id': batch['batch_id'],
  'committed_at': '2026-11-05T01:00:00Z',
  'commit_cursor': 'push-do-not-use',
  'results': [
    for (final dynamic m in batch['mutations'] as List)
      {
        'event_id': m['event_id'],
        'mutation_id': m['mutation_id'],
        'revision': revision,
      },
  ],
};
Map<String, dynamic> record(
  Map<String, dynamic> mutation, {
  String revision = '1',
}) => {
  'id': mutation['event_id'],
  'revision': revision,
  'deleted_at_utc': mutation['event'] == null ? '2026-11-05T01:00:00Z' : null,
  'event': mutation['event'],
};

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory directory;
  late SqliteEventRepository repo;
  late SqliteSyncStore store;
  late String scope;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('weekglass-sync-test-');
    repo = SqliteEventRepository(
      factory: databaseFactoryFfi,
      databasePath: '${directory.path}/calendar.db',
    );
    store = repo.syncStore;
  });
  tearDown(() async {
    await repo.close();
    await directory.delete(recursive: true);
  });
  Future<void> activate({
    bool upload = true,
    String account = 'account',
  }) async {
    scope = await store.activate(
      serverId: 'server',
      accountId: account,
      datasetId: 'dataset',
      epoch: 'epoch',
      deviceId: 'device',
      uploadLocal: upload,
    );
    await store.applySnapshot(scope, [], 'pull-0', 'epoch');
  }

  test('frozen request survives restart and newer edit is not cleared by its receipt', () async {
    await repo.save(event('one'));
    await activate();
    final batch = (await store.freeze(scope))!;
    await repo.save(event('one', title: '更新的备注', version: 2));
    await repo.close();
    repo = SqliteEventRepository(
      factory: databaseFactoryFfi,
      databasePath: '${directory.path}/calendar.db',
    );
    store = repo.syncStore;
    expect(jsonEncode(await store.flight(scope)), jsonEncode(batch));
    await store.acceptReceipt(scope, receipt(batch));
    expect((await store.profile(scope))['cursor'], 'pull-0');
    expect(await store.pendingCount(scope), 1);
    final next = (await store.freeze(scope))!;
    final mutation = (next['mutations'] as List).single as Map;
    expect(mutation['base_revision'], '1');
    expect(mutation['event']['title'], '更新的备注');
  });

  test(
    'repeated offline edits coalesce to one latest entity before upload',
    () async {
      await activate();
      for (var version = 1; version <= 20; version++) {
        await repo.save(
          event('one', title: 'Offline edit $version', version: version),
        );
      }
      expect(await store.pendingCount(scope), 1);
      final batch = (await store.freeze(scope))!;
      final changes = batch['mutations'] as List;
      expect(changes, hasLength(1));
      expect((changes.single as Map)['event']['title'], 'Offline edit 20');
      expect((changes.single as Map)['event']['version'], 20);
    },
  );

  test(
    'own older echo never overwrites pending newer local edit or clears undo',
    () async {
      await repo.save(event('one'));
      await activate();
      final batch = (await store.freeze(scope))!;
      await store.acceptReceipt(scope, receipt(batch));
      await repo.save(event('one', title: '后一版本', version: 2));
      final changed = await store.applyChanges(scope, {
        'changes': [
          {
            'batch_id': batch['batch_id'],
            'records': [
              record(
                Map<String, dynamic>.from(
                  (batch['mutations'] as List).single as Map,
                ),
              ),
            ],
          },
        ],
        'next_cursor': 'pull-1',
      });
      expect(changed, false);
      expect((await repo.getAllEvents()).single.title, '后一版本');
      expect(await store.pendingCount(scope), 1);
      expect(await store.conflicts(scope), isEmpty);
    },
  );

  test('conflict preserves local note, pauses whole batch, explicit cloud choice applies', () async {
    await activate();
    await repo.saveBatch([event('one'), event('two')]);
    final batch = (await store.freeze(scope))!;
    final remote = record(
      Map<String, dynamic>.from((batch['mutations'] as List).first as Map),
    );
    (remote['event'] as Map)['title'] = '云端版本';
    await store.rejectFlight(scope, [
      {'event_id': 'one', 'current': remote},
    ]);
    expect((await repo.getAllEvents()).first.title, '本地');
    expect(await store.freeze(scope), isNull);
    final conflict = (await store.conflicts(scope)).single;
    expect(conflict.localTitle, '本地');
    expect(conflict.remoteTitle, '云端版本');
    expect(await store.resolve(scope, 'one', useLocal: false), true);
    expect(
      (await repo.getAllEvents()).firstWhere((e) => e.id == 'one').title,
      '云端版本',
    );
    expect((await store.freeze(scope))!['mutations'], hasLength(1));
  });

  test(
    'delete then undo creates an explicit restore against remote tombstone',
    () async {
      await repo.save(event('one'));
      await activate();
      var batch = (await store.freeze(scope))!;
      await store.acceptReceipt(scope, receipt(batch));
      await repo.delete('one');
      batch = (await store.freeze(scope))!;
      expect((batch['mutations'] as List).single['operation'], 'delete');
      await store.acceptReceipt(scope, receipt(batch, revision: '2'));
      await repo.save(event('one'));
      final restore = (await store.freeze(scope))!['mutations'] as List;
      expect(restore.single['operation'], 'put');
      expect(restore.single['base_revision'], '2');
    },
  );

  test(
    'explicit local resolution of missing remote clears stale base revision',
    () async {
      await repo.save(event('one'));
      await activate();
      final initial = (await store.freeze(scope))!;
      await store.acceptReceipt(scope, receipt(initial));
      await repo.save(event('one', title: '修改'));
      await store.freeze(scope);
      await store.rejectFlight(scope, [
        {'event_id': 'one', 'current': null},
      ]);
      await store.resolve(scope, 'one', useLocal: true);
      final createAgain = (await store.freeze(scope))!['mutations'] as List;
      expect(createAgain.single['base_revision'], isNull);
      expect(createAgain.single['event']['title'], '修改');
    },
  );

  test('local create then delete before upload does not manufacture server tombstone', () async {
    await activate();
    await repo.save(event('one'));
    await repo.delete('one');
    expect(await store.freeze(scope), isNull);
    expect(await store.pendingCount(scope), 0);
  });

  test('large series splits into persisted bounded batches without dropping entries', () async {
    await activate();
    await repo.saveBatch(List.generate(103, (i) => event('whu-$i')));
    final first = (await store.freeze(scope))!;
    expect(first['mutations'], hasLength(100));
    await store.acceptReceipt(scope, receipt(first));
    expect(await store.pendingCount(scope), 3);
    expect((await store.freeze(scope))!['mutations'], hasLength(3));
  });

  test(
    'switching account without import consent sends none of previous calendar',
    () async {
      await repo.save(event('one'));
      await activate();
      final oldScope = scope;
      await activate(upload: false, account: 'other');
      expect(await store.pendingCount(scope), 0);
      expect(await store.freeze(scope), isNull);
      expect(await store.pendingCount(oldScope), 1);
      expect(await repo.getAllEvents(), hasLength(1));
    },
  );

  test('lower revisions after server epoch reset preserve local conflict for review', () async {
    await repo.save(event('one'));
    await activate();
    final batch = (await store.freeze(scope))!;
    await store.acceptReceipt(scope, receipt(batch, revision: '99'));
    await store.activate(
      serverId: 'server',
      accountId: 'account',
      datasetId: 'dataset',
      epoch: 'new-epoch',
      deviceId: 'device',
      uploadLocal: false,
    );
    final remote = record(
      Map<String, dynamic>.from((batch['mutations'] as List).single as Map),
    );
    (remote['event'] as Map)['title'] = '备份中的版本';
    await store.applySnapshot(scope, [remote], 'new-pull', 'new-epoch');
    expect((await repo.getAllEvents()).single.title, '本地');
    expect((await store.conflicts(scope)).single.remoteTitle, '备份中的版本');
  });

  test('interrupted snapshot is never partially applied to calendar', () async {
    await repo.save(event('local'));
    final engine = CloudSyncEngine(
      automatic: false,
      repository: repo,
      request: (method, path, body) async {
        if (path == '/v1/sync/snapshots') {
          return {
            'snapshot_id': 'snapshot',
            'boundary_cursor': 'boundary',
            'sync_epoch': 'epoch',
            'next_page_token': 'page2',
            'records': [
              {
                'id': 'remote',
                'revision': '1',
                'deleted_at_utc': null,
                'event': {'id': 'remote'},
              },
            ],
          };
        }
        throw const SocketException('offline');
      },
    );
    await engine.connect(
      serverId: 'server',
      accountId: 'account',
      datasetId: 'dataset',
      epoch: 'epoch',
      deviceId: 'device',
      uploadLocal: true,
    );
    expect(engine.error, isNotNull);
    expect((await repo.getAllEvents()).single.id, 'local');
    expect(engine.pendingCount, 1);
    engine.dispose();
  });

  test('unchanged idle sync only pulls a delta and does not resend snapshot or ack', () async {
    var snapshots = 0;
    var pulls = 0;
    var acknowledgements = 0;
    final engine = CloudSyncEngine(
      automatic: false,
      repository: repo,
      request: (method, path, body) async {
        if (path == '/v1/sync/snapshots') {
          snapshots++;
          return {
            'snapshot_id': 's',
            'dataset_id': 'dataset',
            'sync_epoch': 'epoch',
            'boundary_cursor': 'pull-0',
            'records': [],
            'next_page_token': null,
          };
        }
        if (path.startsWith('/v1/sync/changes?')) {
          pulls++;
          return {'changes': [], 'next_cursor': 'pull-0', 'has_more': false};
        }
        if (path == '/v1/sync/ack') {
          acknowledgements++;
          return {};
        }
        fail('Idle sync must not upload a batch');
      },
    );
    await engine.connect(
      serverId: 'server',
      accountId: 'account',
      datasetId: 'dataset',
      epoch: 'epoch',
      deviceId: 'device',
    );
    await engine.sync();
    await engine.sync();
    expect(snapshots, 1);
    expect(pulls, 3);
    expect(acknowledgements, 1);
    expect(engine.error, isNull);
    engine.dispose();
  });

  test(
    'lost successful upload response reads its receipt before its own echo',
    () async {
      await repo.save(event('one'));
      final posted = <String>[];
      final recovery = <String>[];
      Map<String, dynamic>? accepted;
      var failOnce = true;
      var reloads = 0;
      final engine = CloudSyncEngine(
        automatic: false,
        repository: repo,
        onRemoteChange: () async {
          reloads++;
        },
        request: (method, path, body) async {
          if (!failOnce) recovery.add('$method $path');
          if (path == '/v1/sync/snapshots') {
            return {
              'snapshot_id': 's',
              'dataset_id': 'dataset',
              'sync_epoch': 'epoch',
              'boundary_cursor': 'pull-0',
              'records': [],
              'next_page_token': null,
            };
          }
          if (path == '/v1/sync/batches') {
            posted.add(jsonEncode(body));
            accepted = body!;
            if (failOnce) {
              failOnce = false;
              throw const SocketException('response lost after commit');
            }
            return receipt(body);
          }
          if (path == '/v1/sync/batches/${accepted?['batch_id']}') {
            expect(method, 'GET');
            return receipt(accepted!);
          }
          if (path.startsWith('/v1/sync/changes')) {
            if (accepted != null && !path.contains('pull-1')) {
              return {
                'changes': [
                  {
                    'batch_id': accepted!['batch_id'],
                    'records': [
                      record(
                        Map<String, dynamic>.from(
                          (accepted!['mutations'] as List).single as Map,
                        ),
                      ),
                    ],
                  },
                ],
                'next_cursor': 'pull-1',
                'has_more': false,
              };
            }
            return {
              'changes': [],
              'next_cursor': accepted == null ? 'pull-0' : 'pull-1',
              'has_more': false,
            };
          }
          if (path == '/v1/sync/ack') return {};
          throw StateError('unexpected request');
        },
      );
      await engine.connect(
        serverId: 'server',
        accountId: 'account',
        datasetId: 'dataset',
        epoch: 'epoch',
        deviceId: 'device',
        uploadLocal: true,
      );
      expect(engine.error, isNotNull);
      expect(engine.pendingCount, 1);
      await repo.save(event('one', title: '后续编辑', version: 2));
      await engine.updateWriteEntitlement(false);
      await engine.sync();
      expect(engine.error, isNull);
      expect(recovery.first, 'GET /v1/sync/batches/${accepted!['batch_id']}');
      expect(posted, hasLength(1));
      expect(engine.pendingCount, 1);
      expect(engine.conflicts, isEmpty);
      expect((await repo.getAllEvents()).single.title, '后续编辑');
      expect(reloads, 0);
      engine.dispose();
    },
  );

  test('existing version two calendar migrates without changing any event or tombstone', () async {
    final old = await databaseFactoryFfi.openDatabase(
      '${directory.path}/calendar.db',
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: (db, version) async {
          await db.execute(
            'CREATE TABLE events(id TEXT PRIMARY KEY,title TEXT NOT NULL,notes TEXT,color_key TEXT,is_all_day INTEGER,start_utc TEXT,end_utc TEXT,all_day_start TEXT,all_day_end_exclusive TEXT,time_zone_id TEXT,recurrence_rule TEXT,series_id TEXT,created_at_utc TEXT,updated_at_utc TEXT,version INTEGER,import_source TEXT,import_fingerprint TEXT,deleted_at_utc TEXT)',
          );
          for (var i = 0; i < 408; i++) {
            await db.insert('events', {
              'id': 'whu-$i',
              'title': '课程 $i',
              'notes': '地点：A207',
              'color_key': 'mist_blue',
              'is_all_day': 0,
              'start_utc': '2026-11-05T01:00:00Z',
              'end_utc': '2026-11-05T02:00:00Z',
              'time_zone_id': 'Asia/Shanghai',
              'created_at_utc': '2026-11-01T00:00:00Z',
              'updated_at_utc': '2026-11-01T00:00:00Z',
              'version': 7,
              'import_source': 'whu:2026',
              if (i % 4 == 0) 'deleted_at_utc': '2026-11-02T00:00:00Z',
            });
          }
        },
      ),
    );
    final before = await old.query('events', orderBy: 'id');
    await old.close();
    final imported = await repo.getImportedEvents('whu:');
    expect(imported, hasLength(408));
    expect(await repo.getAllEvents(), hasLength(306));
    final inspect = await databaseFactoryFfi.openDatabase(
      '${directory.path}/calendar.db',
    );
    expect(await inspect.query('events', orderBy: 'id'), before);
    await activate();
    expect(await store.pendingCount(scope), 306);
  });

  test('renewal after restart checks the rejected flight, replaces an expired cursor, then freezes the latest edit', () async {
    await repo.save(event('one'));
    await activate();
    final rejected = (await store.freeze(scope))!;
    await store.markFlightRejected(scope, rejected['batch_id'] as String);
    await repo.save(event('one', title: '暂停期间修改', version: 2));
    await repo.close();
    repo = SqliteEventRepository(
      factory: databaseFactoryFfi,
      databasePath: '${directory.path}/calendar.db',
    );
    store = repo.syncStore;
    final calls = <String>[];
    Map<String, dynamic>? sent;
    final engine = CloudSyncEngine(
      automatic: false,
      repository: repo,
      request: (method, path, body) async {
        final uri = Uri.parse(path);
        final cursor = uri.queryParameters['cursor'];
        calls.add('$method ${uri.path}${cursor == null ? '' : ' $cursor'}');
        if (uri.path == '/v1/sync/batches/${rejected['batch_id']}') {
          throw SyncRequestException(404, 'receipt_not_found', {});
        }
        if (cursor == 'pull-0') {
          throw SyncRequestException(410, 'cursor_expired', {});
        }
        if (uri.path == '/v1/sync/snapshots') {
          return {
            'snapshot_id': 's',
            'dataset_id': 'dataset',
            'sync_epoch': 'epoch',
            'boundary_cursor': 'snapshot-boundary',
            'records': [],
            'next_page_token': null,
          };
        }
        if (cursor == 'snapshot-boundary') {
          return {'changes': [], 'next_cursor': cursor, 'has_more': false};
        }
        if (uri.path == '/v1/sync/batches') {
          sent = body!;
          return receipt(body);
        }
        if (uri.path == '/v1/sync/ack') return {};
        fail('Unexpected request $method $path');
      },
    );
    addTearDown(engine.dispose);
    await engine.connect(
      serverId: 'server',
      accountId: 'account',
      datasetId: 'dataset',
      epoch: 'epoch',
      deviceId: 'device',
    );
    expect(engine.error, isNull);
    expect(calls.take(6), [
      'GET /v1/sync/batches/${rejected['batch_id']}',
      'GET /v1/sync/changes pull-0',
      'POST /v1/sync/snapshots',
      'GET /v1/sync/batches/${rejected['batch_id']}',
      'GET /v1/sync/changes snapshot-boundary',
      'POST /v1/sync/batches',
    ]);
    expect(sent!['batch_id'], isNot(rejected['batch_id']));
    expect((sent!['mutations'] as List).single['event']['title'], '暂停期间修改');
    expect((await store.profile(scope))['cursor'], 'snapshot-boundary');
    expect(await store.flight(scope), isNull);
    expect(engine.pendingCount, 0);
  });

  test('rejecting an uncertain flight does not undo an explicit cloud conflict resolution', () async {
    await repo.save(event('one'));
    await activate();
    final original = (await store.freeze(scope))!;
    await store.acceptReceipt(scope, receipt(original));
    await repo.save(event('one', title: '离线编辑', version: 2));
    final uncertain = (await store.freeze(scope))!;
    final remote = record(
      Map<String, dynamic>.from((uncertain['mutations'] as List).single as Map),
      revision: '2',
    );
    (remote['event'] as Map)['title'] = '云端修改';
    await store.applyChanges(scope, {
      'changes': [
        {
          'batch_id': 'other-device',
          'records': [remote],
        },
      ],
      'next_cursor': 'pull-2',
    });
    expect(await store.conflicts(scope), hasLength(1));
    expect(await store.resolve(scope, 'one', useLocal: false), isTrue);
    expect(await store.flight(scope), isNotNull);

    await store.rejectFlight(scope, [
      {'event_id': 'one', 'current': remote},
    ]);
    expect(await store.conflicts(scope), isEmpty);
    expect(await store.flight(scope), isNull);
    expect(await store.pendingCount(scope), 0);
    expect((await repo.getAllEvents()).single.title, '云端修改');
  });
}
