import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter/widgets.dart';
import 'package:weekglass/features/cloud/cloud_auth_service.dart';
import 'package:weekglass/features/cloud/cloud_connection.dart';
import 'package:weekglass/features/cloud/cloud_sync_engine.dart';
import 'package:weekglass_data/weekglass_data.dart';

import 'cloud_sync_engine_test.dart' show event, receipt, record;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late SqliteEventRepository repository;
  late _ScriptedPeer peer;
  late CloudSyncEngine engine;

  setUp(() {
    repository = SqliteEventRepository(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    peer = _ScriptedPeer();
    engine = CloudSyncEngine(
      repository: repository,
      request: peer.request,
      debounceDuration: Duration.zero,
      retryDelay: const Duration(milliseconds: 20),
      maxRetryDelay: const Duration(milliseconds: 80),
    );
  });

  tearDown(() async {
    await engine.disconnect();
    engine.dispose();
    peer.finishWaits();
    await repository.close();
  });

  Future<void> connect() => engine.connect(
    serverId: 'server',
    accountId: 'account',
    datasetId: 'dataset',
    epoch: 'epoch',
    deviceId: 'device',
    uploadLocal: true,
  );

  test(
    'idle long poll waits independently and reuses the received delta',
    () async {
      await connect();
      await _until(() => peer.waits.length == 1);
      final pulls = peer.immediatePulls;
      expect(peer.waits.single.cursor, 'pull-0');
      expect(engine.busy, isFalse);

      final page = _remotePage('pull-1', title: '另一台设备的新日程');
      peer.waits.single.response.complete(page);
      await _until(() => peer.waits.length == 2);
      expect(peer.immediatePulls, pulls);
      expect((await repository.getAllEvents()).single.title, '另一台设备的新日程');
      expect(peer.waits.last.cursor, 'pull-1');
      expect(engine.error, isNull);
    },
  );

  test(
    'local upload proceeds while the change notification is held open',
    () async {
      await connect();
      await _until(() => peer.waits.length == 1);
      await repository.save(event('local'));
      await _until(() => peer.batches.length == 1 && !engine.busy);
      expect(peer.waits.single.response.isCompleted, isFalse);
      expect(engine.pendingCount, 0);
      expect(peer.batches.single['mutations'], hasLength(1));
    },
  );

  test('an empty held wait preserves a concurrent upload retry', () async {
    await connect();
    await _until(() => peer.waits.length == 1);
    peer.uploadErrors = 1;
    await repository.save(event('retry-during-wait'));
    await _until(() => engine.error != null && !engine.busy);
    expect(peer.batchTimes, hasLength(1));
    expect(peer.waits.single.response.isCompleted, isFalse);

    peer.waits.single.response.complete(_emptyPage('pull-0'));
    await _until(() => peer.batches.length == 1 && !engine.busy);
    expect(peer.batchTimes, hasLength(2));
    expect(
      peer.batchTimes[1].difference(peer.batchTimes[0]).inMilliseconds,
      greaterThanOrEqualTo(18),
    );
    expect(engine.pendingCount, 0);
    expect(engine.error, isNull);
  });

  test(
    'an obsolete waiting response never moves the committed cursor backward',
    () async {
      await connect();
      await _until(() => peer.waits.length == 1);
      final staleWait = peer.waits.single;
      peer.pages['pull-0'] = _remotePage('pull-2', title: '最新', revision: '2');
      await engine.sync();

      staleWait.response.complete(_remotePage('pull-1', title: '过时'));
      await _until(() => peer.waits.length == 2);
      expect(peer.waits.last.cursor, 'pull-2');
      expect((await repository.getAllEvents()).single.title, '最新');
      expect(engine.error, isNull);
    },
  );

  test(
    'a local edit at the final acknowledgement runs again before idle',
    () async {
      await connect();
      await _until(() => peer.waits.length == 1);
      peer.pages['pull-0'] = _emptyPage('pull-1');
      final acknowledgement = Completer<void>();
      peer.holdAcknowledgement = acknowledgement;
      final syncing = engine.sync();
      await _until(() => peer.acknowledgementHeld);
      await repository.save(event('late'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      acknowledgement.complete();
      await syncing;
      expect(peer.batches, hasLength(1));
      expect(engine.pendingCount, 0);
    },
  );

  test('background edits coalesce and foreground return starts without manual sync', () async {
    await connect();
    await _until(() => peer.waits.length == 1);
    engine.setForeground(false);
    for (var version = 1; version <= 20; version++) {
      await repository.save(
        event('offline', title: '第$version次修改', version: version),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(peer.batches, isEmpty);
    final pulls = peer.immediatePulls;

    peer.waits.single.response.complete(
      _remotePage('hidden', title: '隐藏时的旧响应'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(peer.waits, hasLength(1));
    expect(peer.immediatePulls, pulls);

    engine.setForeground(true);
    await _until(() => peer.batches.length == 1 && !engine.busy);
    final mutation = (peer.batches.single['mutations'] as List).single as Map;
    expect(mutation['event']['title'], '第20次修改');
    expect((await repository.getAllEvents()).single.id, 'offline');
    expect(engine.pendingCount, 0);
  });

  test(
    'disconnect discards held remote data and schedules no new wait',
    () async {
      await connect();
      await _until(() => peer.waits.length == 1);
      await engine.disconnect().timeout(const Duration(seconds: 1));
      peer.waits.single.response.complete(
        _remotePage('pull-1', title: '退出后的响应'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(peer.waits, hasLength(1));
      expect(await repository.getAllEvents(), isEmpty);
      expect(engine.connected, isFalse);
    },
  );

  test(
    'network watch errors use exponential delays up to the retry cap',
    () async {
      peer.watchErrors = 3;
      await connect();
      await _until(() => peer.watchTimes.length == 4);
      final times = peer.watchTimes;
      expect(
        times[1].difference(times[0]).inMilliseconds,
        greaterThanOrEqualTo(18),
      );
      expect(
        times[2].difference(times[1]).inMilliseconds,
        greaterThanOrEqualTo(38),
      );
      expect(
        times[3].difference(times[2]).inMilliseconds,
        greaterThanOrEqualTo(78),
      );
      expect(peer.snapshots, 1);
      expect(peer.batches, isEmpty);
    },
  );

  test(
    'read-only watch applies remote deltas without retrying uploads',
    () async {
      peer.denyWrites = true;
      await repository.save(event('read-only'));
      await connect();
      await _until(() => peer.waits.length == 1);
      expect(engine.uploadPaused, isTrue);
      expect(engine.error, isNull);
      expect(engine.pendingCount, 1);
      final pulls = peer.immediatePulls;
      await repository.save(event('another-edit'));
      await _until(() => engine.pendingCount == 2);
      expect(peer.immediatePulls, pulls);
      peer.waits.single.response.complete(
        _remotePage('pull-1', title: '另一台设备'),
      );
      await _until(() => peer.waits.length == 2);
      expect(peer.waits.last.cursor, 'pull-1');
      expect(peer.batchTimes, hasLength(1));
      expect(peer.acknowledgements, 2);
      expect(
        (await repository.getAllEvents()).map((e) => e.id),
        unorderedEquals(['read-only', 'another-edit', 'remote']),
      );
      expect(engine.pendingCount, 2);
      expect(engine.error, isNull);
    },
  );

  test('receipt uncertainty retains ID and defers only an own echo', () async {
    peer.uploadErrors = 1;
    await repository.save(event('uncertain'));
    await connect();
    await engine.updateWriteEntitlement(false);
    await repository.save(event('uncertain', title: '后续编辑', version: 2));
    final first = peer.attempts.single;
    final scope = SqliteSyncStore.scopeKey('server', 'account', 'dataset');
    peer.pages['pull-0'] = _remotePage('pull-1', title: '远端日程');
    peer.receiptErrors = 1;
    await engine.sync();
    expect(
      (await repository.syncStore.flight(scope))!['batch_id'],
      first['batch_id'],
    );
    expect((await repository.syncStore.profile(scope))['cursor'], 'pull-1');
    expect(engine.error, isNull);
    expect(engine.conflicts, isEmpty);
    final firstMutation = (first['mutations'] as List).single as Map;
    peer.pages['pull-1'] = {
      'changes': [
        {
          'batch_id': first['batch_id'],
          'records': [
            record(Map<String, dynamic>.from(firstMutation), revision: '2'),
          ],
        },
      ],
      'next_cursor': 'pull-2',
      'has_more': false,
    };
    peer.receiptErrors = 1;
    await engine.sync();
    expect(
      (await repository.syncStore.flight(scope))!['batch_id'],
      first['batch_id'],
    );
    expect((await repository.syncStore.profile(scope))['cursor'], 'pull-1');
    expect(engine.conflicts, isEmpty);
    peer.receipts[first['batch_id'] as String] = receipt(first, revision: '2');
    await engine.sync();
    expect(await repository.syncStore.flight(scope), isNull);
    expect((await repository.syncStore.profile(scope))['cursor'], 'pull-2');
    expect(engine.conflicts, isEmpty);
    expect(engine.pendingCount, 1);
    expect(peer.attempts, hasLength(1));
  });

  test('403 unrelated to subscription is not a paused connection', () async {
    peer.denyWrites = true;
    peer.deniedCode = 'device_mismatch';
    await repository.save(event('pending'));
    await connect();
    expect(engine.uploadPaused, isFalse);
    expect(engine.error, contains('拒绝'));
    expect(engine.pendingCount, 1);
  });

  test('an older self-host keeps replaying identical batches without receipt lookup', () async {
    final auth = _ConnectionAuth(peer)..hosted = false;
    final cloud = CloudConnection(repository: repository, auth: auth);
    try {
      await repository.save(event('self-hosted'));
      peer.uploadErrors = 1;
      await cloud.initialize();
      await cloud.approveAndConnect();
      expect(cloud.engine.error, isNotNull);
      await cloud.engine.sync();
      expect(cloud.engine.error, isNull);
      expect(peer.attempts, hasLength(2));
      expect(peer.attempts[0], peer.attempts[1]);
      expect(
        peer.calls.where((s) => s.startsWith('GET /v1/sync/batches/')),
        isEmpty,
      );
    } finally {
      await cloud.engine.disconnect();
      cloud.dispose();
    }
  });

  test('expiry keeps export available and fresh rights pull before uploading a new batch', () async {
    final auth = _ConnectionAuth(peer);
    final cloud = CloudConnection(repository: repository, auth: auth);
    try {
      await cloud.initialize();
      await cloud.approveAndConnect();
      await _until(() => peer.waits.isNotEmpty);
      final wait = peer.waits.single;
      peer.denyWrites = true;
      await repository.saveBatch([event('remote'), event('same-group')]);
      await cloud.engine.sync();
      await _until(() => cloud.entitlements?['sync_write'] == false);
      final deniedId = peer.attempts.single['batch_id'];
      final scope = SqliteSyncStore.scopeKey('server', 'account', 'dataset');
      expect((await repository.syncStore.flight(scope))!['batch_id'], deniedId);
      expect(cloud.engine.uploadPaused, isTrue);
      expect(cloud.connected, isTrue);

      peer.pages['pull-0'] = _remotePage('pull-1', title: '云端冲突');
      peer.cursor = 'pull-1';
      wait.response.complete(peer.pages['pull-0']!);
      await _until(
        () => cloud.engine.conflicts.isNotEmpty && !cloud.engine.busy,
      );
      expect(cloud.engine.conflicts.single.remoteTitle, '云端冲突');
      expect((await cloud.exportCalendar())['records'], hasLength(1));
      expect(
        (await repository.getAllEvents()).every((e) => e.title == '本地'),
        isTrue,
      );

      peer.failEntitlements = true;
      await expectLater(
        cloud.refreshEntitlements(),
        throwsA(isA<SocketException>()),
      );
      expect(cloud.entitlementsStale, isTrue);
      expect(cloud.entitlements?['sync_write'], isFalse);
      await repository.save(event('independent'));
      await _until(() => cloud.engine.pendingCount == 3);
      await _until(() => !cloud.engine.busy);
      expect(peer.attempts, hasLength(1));

      final offset = peer.calls.length;
      peer.failEntitlements = false;
      peer.denyWrites = false;
      cloud.didChangeAppLifecycleState(AppLifecycleState.paused);
      cloud.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await _until(() => peer.attempts.length == 2 && !cloud.engine.busy);
      final resumed = peer.calls.skip(offset).toList();
      final lookup = resumed.indexOf('GET /v1/sync/batches/$deniedId');
      final upload = resumed.indexOf('POST /v1/sync/batches');
      final pull = resumed.lastIndexWhere(
        (s) =>
            s.contains('changes?cursor=pull-1') && !s.contains('wait_seconds'),
        upload,
      );
      expect(lookup, greaterThanOrEqualTo(0));
      expect(pull, greaterThan(lookup));
      expect(upload, greaterThan(pull));
      expect(peer.attempts.last['batch_id'], isNot(deniedId));
      expect(
        (peer.batches.single['mutations'] as List).single['event_id'],
        'independent',
      );
      expect(cloud.engine.uploadPaused, isFalse);
      expect(cloud.entitlementsStale, isFalse);
      expect(cloud.engine.pendingCount, 2);
      expect(cloud.engine.conflicts, hasLength(1));
    } finally {
      await cloud.engine.disconnect();
      cloud.dispose();
    }
  });

  test(
    'a nonadvancing delta fails once and waits before reading it again',
    () async {
      await connect();
      await _until(() => peer.waits.length == 1);
      peer.waits.single.response.complete(_remotePage('pull-0', title: '无进展'));
      await _until(() => engine.error != null && !engine.busy);
      expect(engine.error, contains('游标未前进'));
      expect(await repository.getAllEvents(), isEmpty);
      expect(peer.waits, hasLength(1));
      expect(peer.immediatePulls, 1);
    },
  );

  test('consent, lifecycle and quiesce control automatic connection', () async {
    final auth = _ConnectionAuth(peer);
    final cloud = CloudConnection(repository: repository, auth: auth);
    try {
      await cloud.initialize();
      cloud.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(peer.snapshots, 0);
      expect(cloud.engine.connected, isFalse);

      await cloud.approveAndConnect();
      await _until(() => peer.waits.length == 1);
      cloud.didChangeAppLifecycleState(AppLifecycleState.paused);
      peer.waits.single.response.complete(_emptyPage('pull-0'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(peer.waits, hasLength(1));
      final pulls = peer.immediatePulls;
      cloud.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await _until(() => peer.immediatePulls > pulls);

      await cloud.quiesce();
      expect(cloud.engine.connected, isFalse);
      final beforeResume = peer.immediatePulls;
      await cloud.resume();
      expect(cloud.engine.connected, isTrue);
      expect(peer.immediatePulls, greaterThan(beforeResume));
      await cloud.disconnect();
      expect(auth.connected, isFalse);
      expect(cloud.engine.connected, isFalse);
    } finally {
      await cloud.engine.disconnect();
      cloud.dispose();
    }
  });

  test('idle traffic contains one small delta reply without another snapshot or ack', () async {
    await connect();
    await _until(() => peer.waits.length == 1);
    final before = peer.responseBytes;
    final reply = _emptyPage('pull-0');
    peer.waits.single.response.complete(reply);
    await _until(() => peer.responseBytes > before);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final idleBytes = peer.responseBytes - before;
    expect(idleBytes, utf8.encode(jsonEncode(reply)).length);
    expect(idleBytes, lessThan(200));
    expect(peer.waits, hasLength(1));
    expect(peer.snapshots, 1);
    expect(peer.acknowledgements, 1);
    debugPrint(
      jsonEncode({
        'fixture': 'idle 25-second change wait',
        'response_json_bytes': idleBytes,
        'requests_per_24_foreground_hours': 86400 ~/ 25,
        'http_request_and_response_header_budget_bytes': [400, 1200],
        'headers':
            'Estimate for both directions including an authorization header.',
        'excluded':
            'TLS records, transport headers, reconnection and token refresh.',
      }),
    );
  });
}

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for synchronization');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

Map<String, dynamic> _emptyPage(String cursor) => {
  'changes': <Map<String, dynamic>>[],
  'next_cursor': cursor,
  'has_more': false,
  'server_time': '2026-11-07T00:00:00Z',
};

Map<String, dynamic> _remotePage(
  String cursor, {
  required String title,
  String revision = '1',
}) => {
  'changes': [
    {
      'batch_id': 'remote-$revision',
      'records': [
        record({
          'event_id': 'remote',
          'event': {
            'id': 'remote',
            'title': title,
            'color_key': 'mist_blue',
            'is_all_day': false,
            'start_utc': '2026-11-07T01:00:00Z',
            'end_utc': '2026-11-07T02:00:00Z',
            'time_zone_id': 'Asia/Shanghai',
            'created_at_utc': '2026-11-07T00:00:00Z',
            'updated_at_utc': '2026-11-07T00:00:00Z',
            'version': int.parse(revision),
          },
        }, revision: revision),
      ],
    },
  ],
  'next_cursor': cursor,
  'has_more': false,
};

class _WaitingPage {
  _WaitingPage(this.cursor);
  final String cursor;
  final response = Completer<Map<String, dynamic>>();
}

class _ScriptedPeer {
  final pages = <String, Map<String, dynamic>>{};
  final waits = <_WaitingPage>[];
  final batches = <Map<String, dynamic>>[];
  final watchTimes = <DateTime>[];
  final batchTimes = <DateTime>[];
  final attempts = <Map<String, dynamic>>[];
  final receipts = <String, Map<String, dynamic>>{};
  final calls = <String>[];
  String cursor = 'pull-0';
  int snapshots = 0;
  int immediatePulls = 0;
  int acknowledgements = 0;
  int responseBytes = 0;
  int watchErrors = 0;
  int uploadErrors = 0;
  int receiptErrors = 0;
  bool denyWrites = false;
  String deniedCode = 'subscription_required';
  bool failEntitlements = false;
  int entitlementReads = 0;
  bool acknowledgementHeld = false;
  Completer<void>? holdAcknowledgement;

  Future<Map<String, dynamic>> request(
    String method,
    String path,
    Map<String, dynamic>? body,
  ) async {
    calls.add('$method $path');
    final result = await _respond(method, Uri.parse(path), body);
    responseBytes += utf8.encode(jsonEncode(result)).length;
    return result;
  }

  Future<Map<String, dynamic>> _respond(
    String method,
    Uri uri,
    Map<String, dynamic>? body,
  ) async {
    switch (uri.path) {
      case '/v1/sync/snapshots':
        snapshots++;
        return {
          'snapshot_id': 'snapshot',
          'dataset_id': 'dataset',
          'sync_epoch': 'epoch',
          'boundary_cursor': cursor,
          'records': <Map<String, dynamic>>[],
          'next_page_token': null,
        };
      case '/v1/sync/changes':
        final from = uri.queryParameters['cursor']!;
        if (uri.queryParameters['wait_seconds'] == '25') {
          watchTimes.add(DateTime.now());
          if (watchErrors > 0) {
            watchErrors--;
            throw const SocketException('offline');
          }
          final wait = _WaitingPage(from);
          waits.add(wait);
          return wait.response.future;
        }
        immediatePulls++;
        return pages[from] ?? _emptyPage(from);
      case '/v1/sync/batches':
        final batch = body!;
        batchTimes.add(DateTime.now());
        attempts.add(batch);
        if (uploadErrors > 0) {
          uploadErrors--;
          throw const SocketException('upload interrupted');
        }
        if (denyWrites) {
          throw SyncRequestException(403, deniedCode, {});
        }
        batches.add(batch);
        final next = 'uploaded-${batches.length}';
        pages[cursor] = {
          'changes': [
            {
              'batch_id': batch['batch_id'],
              'records': [
                for (final mutation in batch['mutations'] as List)
                  record(Map<String, dynamic>.from(mutation as Map)),
              ],
            },
          ],
          'next_cursor': next,
          'has_more': false,
        };
        cursor = next;
        final result = receipt(batch);
        receipts[batch['batch_id'] as String] = result;
        return result;
      case '/v1/sync/ack':
        acknowledgements++;
        final held = holdAcknowledgement;
        holdAcknowledgement = null;
        if (held != null) {
          acknowledgementHeld = true;
          await held.future;
        }
        return {};
      default:
        if (method == 'GET' && uri.path.startsWith('/v1/sync/batches/')) {
          if (receiptErrors > 0) {
            receiptErrors--;
            throw const SocketException('receipt unavailable');
          }
          return receipts[uri.pathSegments.last] ??
              (throw SyncRequestException(404, 'receipt_not_found', {}));
        }
        throw StateError('Unexpected sync request $method $uri');
    }
  }

  void finishWaits() {
    for (final wait in waits) {
      if (!wait.response.isCompleted) {
        wait.response.complete(_emptyPage(wait.cursor));
      }
    }
  }
}

class _ConnectionAuth extends CloudAuthService {
  _ConnectionAuth(this.peer);
  final _ScriptedPeer peer;
  bool approved = false;
  bool loggedIn = true;
  bool hosted = true;

  @override
  bool get connected => loggedIn;
  @override
  bool get mergeApproved => approved;
  @override
  String? get origin => hosted ? officialCloudOrigin : 'https://self-host.test';
  @override
  String get serverId => 'server';
  @override
  String get accountId => 'account';
  @override
  String get datasetId => 'dataset';
  @override
  String get epoch => 'epoch';
  @override
  String get deviceId => 'device';
  @override
  Future<void> restore() async {}
  @override
  Future<void> approveMerge() async {
    approved = true;
  }

  @override
  Future<void> logout() async {
    loggedIn = false;
  }

  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path,
    Map<String, dynamic>? body,
  ) async {
    if (path.startsWith('/v1/sync/')) return peer.request(method, path, body);
    if (path == '/v1/devices') return {'devices': <Map<String, dynamic>>[]};
    if (path == '/v1/me/entitlements') {
      peer.entitlementReads++;
      if (peer.failEntitlements) throw const SocketException('offline');
      return {
        'mode': 'hosted',
        'sync_read': true,
        'sync_write': !peer.denyWrites,
        'export_allowed': true,
      };
    }
    if (path == '/v1/exports/calendar') {
      return {
        'format': 'weekglass-json-v1',
        'records': [
          for (final batch in peer.pages.values.expand(
            (page) => page['changes'] as List,
          ))
            ...batch['records'] as List,
        ],
      };
    }
    return {};
  }
}
