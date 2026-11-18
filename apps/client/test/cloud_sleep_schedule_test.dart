import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weekglass/features/cloud/cloud_sync_engine.dart';
import 'package:weekglass_data/weekglass_data.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

import 'cloud_sync_engine_test.dart' show event, receipt, record;

const _first = SleepSchedule(sleepMinute: 1395, wakeMinute: 435);
const _second = SleepSchedule(enabled: false, sleepMinute: 60, wakeMinute: 525);
const _third = SleepSchedule(sleepMinute: 75, wakeMinute: 555);

void main() {
  setUpAll(sqfliteFfiInit);

  test('implicit default is not sent; one PUT shares explicit times in the existing long poll', () async {
    final peer = _Peer();
    final writer = _Client(peer);
    final reader = _Client(
      peer,
      automatic: true,
      path: await _temporaryCalendar(),
    );
    addTearDown(writer.close);
    addTearDown(reader.close);
    await writer.connect();
    await reader.connect(device: 'reader');
    await _until(() => peer.waits.length == 1);
    expect(peer.writes, isEmpty);
    expect(await reader.local, isNull);
    expect(peer.waits.single.revision, 'none');

    final pulls = peer.pulls;
    final acks = peer.acks;
    await writer.repo.saveSleepSchedule(_second);
    await writer.engine.sync();
    peer.completeWait();
    await _until(() => reader.sleepReloads == 1 && peer.waits.length == 2);

    expect(peer.writes.single['schedule'], _payload(_second));
    expect(_payload((await reader.local)!), _payload(_second));
    expect(writer.engine.pendingCount, 0);
    expect(reader.calendarReloads, 0);
    expect(
      peer.pulls,
      pulls + 1,
      reason: 'only the sender needed an immediate pull',
    );
    expect(peer.acks, acks, reason: 'no calendar cursor changed');
    expect(peer.waits.last.revision, peer.head!['revision']);
  });

  test(
    'first different explicit schedules wait for a choice through reconnect',
    () async {
      final peer = _Peer()..advance(_first);
      final client = _Client(peer);
      addTearDown(client.close);
      await client.repo.migrateSleepSchedule(_second);
      await client.connect();
      var conflict = client.engine.sleepScheduleConflict!;
      expect(_payload(conflict.local), _payload(_second));
      expect(_payload(conflict.remote), _payload(_first));
      expect(_payload((await client.local)!), _payload(_second));
      expect(peer.writes, isEmpty);
      expect(client.engine.pendingCount, 1);

      await client.connect();
      conflict = client.engine.sleepScheduleConflict!;
      await client.engine.resolveSleepScheduleConflict(
        conflict,
        useLocal: false,
      );
      expect(client.engine.sleepScheduleConflict, isNull);
      expect(_payload((await client.local)!), _payload(_first));
      expect(peer.writes, isEmpty);
      expect(client.sleepReloads, 1);
    },
  );

  test('cas conflict does not overwrite newer remote and explicit local choice retries on latest revision', () async {
    final peer = _Peer()..advance(_first);
    final client = _Client(peer);
    addTearDown(client.close);
    await client.connect();
    await client.repo.saveSleepSchedule(_second);
    peer.beforeWrite = () async {
      peer.advance(_third);
    };
    await client.engine.sync();

    final conflict = client.engine.sleepScheduleConflict!;
    expect(_payload(conflict.local), _payload(_second));
    expect(_payload(conflict.remote), _payload(_third));
    expect(peer.head!['schedule'], _payload(_third));
    await client.engine.resolveSleepScheduleConflict(conflict, useLocal: true);

    expect(peer.writes, hasLength(2));
    expect(peer.writes.last['base_revision'], conflict.remoteRevision);
    expect(peer.head!['schedule'], _payload(_second));
    expect(client.engine.sleepScheduleConflict, isNull);
  });

  test('lost committed response survives reopen and does not turn a later offline edit into a conflict', () async {
    final path = await _temporaryCalendar();
    final peer = _Peer()..advance(_first);
    final original = _Client(peer, path: path);
    await original.connect();
    await original.repo.saveSleepSchedule(_second);
    peer.afterWrite = () async {
      await original.repo.saveSleepSchedule(_third);
      throw const SocketException('response lost after commit');
    };
    await original.engine.sync();
    expect(original.engine.error, isNotNull);
    expect(peer.head!['schedule'], _payload(_second));
    await original.close();

    final reopened = _Client(peer, path: path);
    addTearDown(reopened.close);
    await reopened.connect();
    expect(reopened.engine.sleepScheduleConflict, isNull);
    expect(reopened.engine.error, isNull);
    expect(peer.writes, hasLength(2));
    expect(peer.head!['schedule'], _payload(_third));
    expect(_payload((await reopened.local)!), _payload(_third));
  });

  test('a legacy server ignores the extension and still synchronizes calendar edits', () async {
    final peer = _Peer()..supportsSchedule = false;
    final client = _Client(peer);
    addTearDown(client.close);
    await client.repo.saveSleepSchedule(_second);
    await client.repo.save(event('legacy-calendar'));
    await client.connect();
    expect(client.engine.sleepScheduleSupported, isFalse);
    expect(client.engine.pendingCount, 0);
    expect(peer.eventWrites, 1);
    expect(peer.writes, isEmpty);
    expect(_payload((await client.local)!), _payload(_second));

    peer.supportsSchedule = true;
    await client.engine.sync();
    expect(client.engine.sleepScheduleSupported, isTrue);
    expect(peer.writes.single['schedule'], _payload(_second));
    expect(peer.eventWrites, 1);
  });

  test('a different cloud account cannot silently overwrite the current device schedule', () async {
    final peer = _Peer()..advance(_first);
    final client = _Client(peer);
    addTearDown(client.close);
    await client.connect(account: 'account-a');
    expect(_payload((await client.local)!), _payload(_first));
    peer.advance(_second);
    await client.connect(account: 'account-b');
    expect(client.engine.sleepScheduleConflict, isNotNull);
    expect(peer.writes, isEmpty);
    await client.engine.resolveSleepScheduleConflict(
      client.engine.sleepScheduleConflict!,
      useLocal: false,
    );
    expect(_payload((await client.local)!), _payload(_second));

    peer.advance(_first);
    await client.connect(account: 'account-a');
    expect(client.engine.sleepScheduleConflict, isNotNull);
    expect(_payload((await client.local)!), _payload(_second));
    expect(peer.writes, isEmpty);
  });
}

class _Client {
  _Client(
    _Peer peer, {
    bool automatic = false,
    String path = inMemoryDatabasePath,
  }) : repo = SqliteEventRepository(
         factory: databaseFactoryFfi,
         databasePath: path,
       ) {
    engine = CloudSyncEngine(
      repository: repo,
      request: peer.request,
      automatic: automatic,
      debounceDuration: const Duration(days: 1),
      onRemoteSleepChange: () async {
        sleepReloads++;
      },
      onRemoteChange: () async {
        calendarReloads++;
      },
    );
  }

  final SqliteEventRepository repo;
  late final CloudSyncEngine engine;
  int sleepReloads = 0;
  int calendarReloads = 0;

  Future<SleepSchedule?> get local => repo.readSleepSchedule();

  Future<void> connect({
    String account = 'account',
    String device = 'writer',
  }) => engine.connect(
    serverId: 'server',
    accountId: account,
    datasetId: 'dataset',
    epoch: 'epoch',
    deviceId: device,
    uploadLocal: true,
    synchronizeSleepSchedule: true,
  );

  Future<void> close() async {
    await engine.disconnect();
    engine.dispose();
    await repo.close();
  }
}

class _Peer {
  bool supportsSchedule = true;
  int pulls = 0;
  int acks = 0;
  int eventWrites = 0;
  int version = 0;
  Map<String, dynamic>? head;
  Future<void> Function()? beforeWrite;
  Future<void> Function()? afterWrite;
  final writes = <Map<String, dynamic>>[];
  final waits =
      <({String? revision, Completer<Map<String, dynamic>> response})>[];
  final calendarPages = <String, Map<String, dynamic>>{};

  void advance(SleepSchedule next) {
    head = {
      'revision': 'remote-${++version}',
      'write_id': 'write-$version',
      'schedule': _payload(next),
    };
  }

  Map<String, dynamic> page(String cursor, String? revision) => {
    ...calendarPages[cursor] ??
        {'changes': [], 'has_more': false, 'next_cursor': cursor},
    if (supportsSchedule &&
        revision != null &&
        revision != (head?['revision'] ?? 'none'))
      'sleep_schedule': head,
  };

  void completeWait() {
    final wait = waits.last;
    wait.response.complete(page('calendar-0', wait.revision));
  }

  Future<Map<String, dynamic>> request(
    String method,
    String path,
    Map<String, dynamic>? body,
  ) async {
    final uri = Uri.parse(path);
    switch (uri.path) {
      case '/v1/sync/snapshots':
        return {
          'snapshot_id': 'snapshot',
          'sync_epoch': 'epoch',
          'boundary_cursor': 'calendar-0',
          'records': [],
          'next_page_token': null,
        };
      case '/v1/sync/changes':
        final revision = uri.queryParameters['sleep_revision'];
        if (uri.queryParameters['wait_seconds'] == '25') {
          final response = Completer<Map<String, dynamic>>();
          waits.add((revision: revision, response: response));
          return response.future;
        }
        pulls++;
        return page(uri.queryParameters['cursor']!, revision);
      case '/v1/sync/ack':
        acks++;
        return {};
      case '/v1/sync/sleep-schedule':
        expect(method, 'PUT');
        if (!supportsSchedule) {
          throw SyncRequestException(404, 'request_rejected', {});
        }
        final write = body!;
        writes.add(write);
        final before = beforeWrite;
        beforeWrite = null;
        await before?.call();
        if (write['write_id'] == head?['write_id']) return head!;
        if (write['base_revision'] != head?['revision']) {
          throw SyncRequestException(409, 'sleep_schedule_conflict', {
            'sleep_schedule': head,
          });
        }
        final accepted = {
          'revision': 'remote-${++version}',
          'write_id': write['write_id'],
          'schedule': write['schedule'],
        };
        head = accepted;
        final after = afterWrite;
        afterWrite = null;
        await after?.call();
        return accepted;
      case '/v1/sync/batches':
        eventWrites++;
        calendarPages['calendar-0'] = {
          'changes': [
            {
              'batch_id': body!['batch_id'],
              'records': [
                for (final Map<String, dynamic> m in body['mutations'] as List)
                  record(m),
              ],
            },
          ],
          'has_more': false,
          'next_cursor': 'calendar-1',
        };
        return receipt(body);
      default:
        throw StateError('Unexpected request $method $path');
    }
  }
}

Map<String, dynamic> _payload(SleepSchedule schedule) => {
  'enabled': schedule.enabled,
  'sleep_minute': schedule.sleepMinute,
  'wake_minute': schedule.wakeMinute,
};

Future<String> _temporaryCalendar() async {
  final folder = await Directory.systemTemp.createTemp('wg-sleep-test-');
  final path = '${folder.path}/calendar.db';
  addTearDown(() async {
    await databaseFactoryFfi.deleteDatabase(path);
    await folder.delete();
  });
  return path;
}

Future<void> _until(bool Function() predicate) async {
  final clock = Stopwatch()..start();
  while (!predicate() && clock.elapsed < const Duration(seconds: 3)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(predicate(), isTrue);
}
