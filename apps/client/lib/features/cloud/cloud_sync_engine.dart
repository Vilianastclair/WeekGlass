import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:weekglass_data/weekglass_data.dart';

typedef CloudConflict = SyncConflict;
typedef CloudRequest = Future<Map<String, dynamic>> Function(
  String method,
  String path,
  Map<String, dynamic>? body,
);

/// Serial coordinator. Authentication and TLS are owned by the transport.
class CloudSyncEngine extends ChangeNotifier {
  CloudSyncEngine({
    required this.repository,
    required this.request,
    this.onRemoteChange,
    this.onRemoteSleepChange,
    this.canTransport,
    this.onServiceDenied,
    this.automatic = true,
    this.debounceDuration = const Duration(milliseconds: 750),
    this.retryDelay = const Duration(seconds: 2),
    this.maxRetryDelay = const Duration(minutes: 1),
  }) {
    _localSubscription = repository.localChanges.listen((_) {
      if (!_connected || !_foreground) return;
      _debounce?.cancel();
      _debounce = Timer(debounceDuration, () {
        if (!_transportEnabled || _uploadPaused) {
          unawaited(_refreshPendingCount(_scope!, _generation));
        } else {
          unawaited(sync());
        }
      });
    });
  }
  final SqliteEventRepository repository;
  final CloudRequest request;
  final bool automatic;
  final Duration debounceDuration;
  final Duration retryDelay;
  final Duration maxRetryDelay;
  final Future<void> Function()? onRemoteChange;
  final Future<void> Function()? onRemoteSleepChange;
  final bool Function()? canTransport;
  final bool Function(SyncRequestException)? onServiceDenied;
  SqliteSyncStore get _store => repository.syncStore;
  StreamSubscription<void>? _localSubscription;
  Timer? _debounce;
  Timer? _watchTimer;
  Future<void>? _watching;
  bool _foreground = true;
  bool _rerun = false;
  bool _syncFailed = false;
  int _watchGeneration = 0;
  int _watchFailures = 0;
  Duration _watchDelay = Duration.zero;
  ({String cursor, String? sleepRevision, Map<String, dynamic> page})?
  _prefetched;
  String? _scope;
  bool _connected = false;
  bool _busy = false;
  bool _uploadPaused = false;
  bool _recoverReceipts = false;
  bool _syncSleepSchedule = false;
  bool? _sleepScheduleSupported;
  SleepScheduleConflict? _sleepScheduleConflict;
  bool _disposed = false;
  int _generation = 0;
  int _writeGeneration = 0;
  Future<void>? _running;
  DateTime? _lastSync;
  String? _acknowledgedCursor;
  String? _error;
  int _pendingCount = 0;
  List<CloudConflict> _conflicts = [];
  bool get connected => _connected;
  bool get busy => _busy;
  bool get uploadPaused => _uploadPaused;
  DateTime? get lastSync => _lastSync;
  String? get error => _error;
  int get pendingCount => _pendingCount;
  List<CloudConflict> get conflicts => List.unmodifiable(_conflicts);
  bool? get sleepScheduleSupported => _sleepScheduleSupported;
  SleepScheduleConflict? get sleepScheduleConflict => _sleepScheduleConflict;

  bool get _transportEnabled => canTransport?.call() ?? true;

  /// Keep the local profile and outbox, but invalidate replies from the old
  /// entitlement. Call after closing the transport gate and before reopening it.
  void suspendTransport() {
    _generation++;
    _watchGeneration++;
    _watchTimer?.cancel();
    _watchTimer = null;
    _prefetched = null;
    _error = null;
    _emit();
  }

  Future<void> resumeTransport() async {
    await _running;
    if (_foreground) await sync();
  }

  Future<void> updateWriteEntitlement(bool allowed) {
    if (_uploadPaused == !allowed) return Future.value();
    _setUploadPaused(!allowed);
    return allowed && _foreground ? sync() : Future.value();
  }

  void _setUploadPaused(bool paused) {
    _uploadPaused = paused;
    _writeGeneration++;
    if (paused) _recoverReceipts = true;
    _emit();
  }

  Future<void> connect({
    required String serverId,
    required String accountId,
    required String datasetId,
    required String epoch,
    required String deviceId,
    bool uploadLocal = false,
    bool uploadPaused = false,
    bool recoverReceipts = true,
    bool synchronizeSleepSchedule = false,
  }) async {
    await disconnect();
    if (_disposed || !_transportEnabled) return;
    _scope = await _store.activate(
      serverId: serverId,
      accountId: accountId,
      datasetId: datasetId,
      epoch: epoch,
      deviceId: deviceId,
      uploadLocal: uploadLocal,
    );
    _connected = true;
    _syncSleepSchedule = synchronizeSleepSchedule;
    _sleepScheduleSupported = null;
    _sleepScheduleConflict = null;
    _uploadPaused = uploadPaused;
    _recoverReceipts = uploadPaused || recoverReceipts;
    _syncFailed = false;
    _lastSync = null;
    _watchFailures = 0;
    _watchDelay = Duration.zero;
    _acknowledgedCursor = null;
    _error = null;
    _emit();
    await sync();
  }

  Future<void> enableSleepSchedule() {
    if (!_connected || _syncSleepSchedule) return Future.value();
    _syncSleepSchedule = true;
    return sync();
  }

  /// Logging out stops transport; durable pending edits remain bound to profile.
  Future<void> disconnect() async {
    _connected = false;
    _uploadPaused = false;
    _sleepScheduleConflict = null;
    _generation++;
    _watchGeneration++;
    _watchTimer?.cancel();
    _watchTimer = null;
    _prefetched = null;
    _debounce?.cancel();
    await _running;
    _emit();
  }

  void setForeground(bool foreground) {
    if (_foreground == foreground) return;
    _foreground = foreground;
    _watchGeneration++;
    _watchTimer?.cancel();
    _watchTimer = null;
    _debounce?.cancel();
    _prefetched = null;
    if (foreground && _connected) {
      _watchFailures = 0;
      _watchDelay = Duration.zero;
      unawaited(sync());
    }
  }

  Future<void> sync() {
    if (!_connected || _disposed || !_transportEnabled) return Future.value();
    if (_running != null) {
      _rerun = true;
      return _running!;
    }
    _watchTimer?.cancel();
    _watchTimer = null;
    final generation = _generation;
    final scope = _scope!;
    _running = _drain(scope, generation).whenComplete(() {
      _running = null;
      if (_watching == null) {
        if (_error == null) {
          _watchFailures = 0;
          _watchDelay = Duration.zero;
        } else {
          _backoff();
        }
        _scheduleWatch();
      }
    });
    return _running!;
  }

  Future<void> _drain(String scope, int generation) async {
    do {
      _rerun = false;
      await _run(scope, generation);
    } while (_rerun && _current(generation) && _foreground);
  }

  bool get _observe =>
      automatic && _foreground && _connected && !_disposed && _transportEnabled;

  void _backoff() {
    final multiplier = 1 << _watchFailures.clamp(0, 10).toInt();
    final milliseconds = retryDelay.inMilliseconds * multiplier;
    _watchDelay = Duration(
      milliseconds: milliseconds.clamp(1, maxRetryDelay.inMilliseconds).toInt(),
    );
    _watchFailures++;
  }

  void _scheduleWatch() {
    if (!_observe || _watching != null || _watchTimer != null) return;
    _watchTimer = Timer(_watchDelay, () {
      _watchTimer = null;
      if (!_observe) return;
      final generation = _generation;
      final watchGeneration = _watchGeneration;
      _watching =
          _watch(
            scope: _scope!,
            generation: generation,
            watchGeneration: watchGeneration,
          ).whenComplete(() {
            _watching = null;
            _scheduleWatch();
          });
    });
  }

  Future<void> _watch({
    required String scope,
    required int generation,
    required int watchGeneration,
  }) async {
    bool current() =>
        _observe && _current(generation) && watchGeneration == _watchGeneration;
    try {
      if (!current()) return;
      final profile = await _store.profile(scope);
      if (!current()) return;
      final cursor = profile['cursor'] as String?;
      if (cursor == null || _syncFailed) {
        await sync();
        if (!current()) return;
        if (_syncFailed) {
          _backoff();
        } else {
          _watchDelay = Duration.zero;
        }
        return;
      }
      final timer = Stopwatch()..start();
      final sleepRevision = await _sleepRevision(scope);
      if (!current()) return;
      final page = await _requestChanges(cursor, sleepRevision, wait: true);
      if (!current()) return;
      if (!_syncFailed && _error != null) {
        _error = null;
        _emit();
      }
      final changes = page['changes'] as List;
      final sleepChanged =
          sleepRevision != null && page.containsKey('sleep_schedule');
      final currentSleepPage =
          sleepChanged && sleepRevision == await _sleepRevision(scope);
      if (!current()) return;
      if (changes.isNotEmpty ||
          page['next_cursor'] != cursor ||
          currentSleepPage) {
        _prefetched = (
          cursor: cursor,
          sleepRevision: sleepRevision,
          page: page,
        );
        await sync();
        if (!current()) return;
        final latest = await _store.profile(scope);
        final appliedSleepRevision = sleepChanged
            ? await _sleepRevision(scope)
            : sleepRevision;
        if (!current()) return;
        if (_syncFailed ||
            latest['cursor'] == cursor &&
                appliedSleepRevision == sleepRevision) {
          // A blocked upload or unchanged cursor must not download the same
          // immediately available batch in an unbounded hot loop.
          _backoff();
        } else {
          _watchFailures = 0;
          _watchDelay = Duration.zero;
        }
      } else if (_syncFailed) {
        // Upload may have failed while this independent request was waiting.
        // Its empty reply must not add an idle interval to upload retry.
        _backoff();
      } else if (sleepChanged) {
        // Our own PUT advanced this baseline while the poll was in flight.
        _watchFailures = 0;
        _watchDelay = Duration.zero;
      } else {
        _watchFailures = 0;
        // Older self-hosted servers may return immediately despite wait_seconds.
        // Keep their empty responses at most once per 25 seconds.
        final remaining = const Duration(seconds: 25) - timer.elapsed;
        _watchDelay = remaining.isNegative ? Duration.zero : remaining;
      }
    } on SyncRequestException catch (error) {
      if (!current()) return;
      if (_serviceDenied(error)) return;
      if (error.status == 410) {
        await sync();
        if (!current()) return;
        if (_error == null) {
          _watchFailures = 0;
          _watchDelay = Duration.zero;
          return;
        }
      } else {
        _error = _errorMessage(error);
        _emit();
      }
      _backoff();
    } catch (_) {
      if (!current()) return;
      _error = '暂时无法连接云端，本地日程正常保存';
      _backoff();
      _emit();
    }
  }

  String _errorMessage(SyncRequestException error) => switch (error.status) {
    401 => '登录已失效，请重新连接；待同步内容已保留',
    403 => '云端拒绝此请求，本地日程与待同步内容已保留',
    410 => '云端数据版本已变化，请重试同步；本地内容已保留',
    429 => '请求稍多，稍后会自动重试',
    507 => '云端空间不足，待同步内容已保留',
    _ => '暂时无法同步，恢复连接后会重试',
  };

  bool _serviceDenied(SyncRequestException error) =>
      error.status == 403 &&
      (error.code == 'subscription_required' ||
          error.code == 'subscription_expired') &&
      onServiceDenied?.call(error) == true;

  bool _current(int generation) =>
      !_disposed &&
      _connected &&
      generation == _generation &&
      _transportEnabled;

  Future<void> _refreshPendingCount(String scope, int generation) async {
    final count = await _pendingFor(scope);
    if (_disposed ||
        !_connected ||
        generation != _generation ||
        count == _pendingCount) {
      return;
    }
    _pendingCount = count;
    _emit();
  }

  Future<int> _pendingFor(String scope) async {
    final count = await _store.pendingCount(scope);
    if (_sleepScheduleSupported != true) return count;
    final sleep = await repository.sleepScheduleStore.status(scope);
    return count + (sleep.pending ? 1 : 0);
  }

  Future<String?> _sleepRevision(String scope) async {
    if (!_syncSleepSchedule) return null;
    // On each connection, probe through the existing pull; old servers ignore
    // the extra query parameter and continue calendar synchronization.
    if (_sleepScheduleSupported != true) return 'unknown';
    return repository.sleepScheduleStore.revision(scope);
  }

  Future<Map<String, dynamic>> _requestChanges(
    String cursor,
    String? sleepRevision, {
    bool wait = false,
  }) => request(
    'GET',
    '/v1/sync/changes?cursor=${Uri.encodeQueryComponent(cursor)}&limit_batches=1'
        '${wait ? '&wait_seconds=25' : ''}'
        '${sleepRevision == null ? '' : '&sleep_revision=${Uri.encodeQueryComponent(sleepRevision)}'}',
    null,
  );

  Future<void> _run(String scope, int generation) async {
    final writeGeneration = _writeGeneration;
    bool canUpload() =>
        _current(generation) &&
        !_uploadPaused &&
        writeGeneration == _writeGeneration;
    _busy = true;
    _error = null;
    _emit();
    var calendarChanged = false;
    var sleepChanged = false;
    try {
      // A fresh 403 conclusively rejects this POST. A 404 for a previously
      // timed-out POST only says no receipt has been committed yet.
      var flight = await _store.flight(scope);
      if (!_current(generation)) return;
      if (flight != null) {
        if (canUpload() && !_recoverReceipts) {
          if (!await _send(
            scope,
            flight,
            fresh: false,
            generation: generation,
          )) {
            flight = null;
          }
        }
        if (flight != null &&
            await _readReceipt(
              scope,
              flight,
              generation: generation,
              allowUnavailable: _uploadPaused,
            )) {
          flight = null;
        }
      }
      if (!_current(generation)) return;
      var profile = await _store.profile(scope);
      if (!_current(generation)) return;
      if (profile['cursor'] == null) {
        calendarChanged = await _snapshot(scope, generation, flight);
        flight = await _store.flight(scope);
      }
      for (var round = 0; round < 500 && _current(generation); round++) {
        profile = await _store.profile(scope);
        if (!_current(generation)) return;
        Map<String, dynamic> page;
        String? sleepRevision;
        try {
          final prefetched = _prefetched;
          _prefetched = null;
          sleepRevision = await _sleepRevision(scope);
          if (!_current(generation)) return;
          page =
              prefetched != null &&
                  prefetched.cursor == profile['cursor'] &&
                  prefetched.sleepRevision == sleepRevision
              ? prefetched.page
              : await _requestChanges(
                  profile['cursor'] as String,
                  sleepRevision,
                );
        } on SyncRequestException catch (e) {
          if (e.status != 410) rethrow;
          if (!_current(generation)) return;
          await _store.resetCursor(scope);
          calendarChanged =
              await _snapshot(scope, generation, flight) || calendarChanged;
          flight = await _store.flight(scope);
          continue;
        }
        if (!_current(generation)) return;
        if ((page['changes'] as List).isNotEmpty &&
            page['next_cursor'] == profile['cursor']) {
          throw StateError('云端同步游标未前进，请稍后重试');
        }
        if (flight != null &&
            (page['changes'] as List).any(
              (batch) => batch['batch_id'] == flight!['batch_id'],
            )) {
          // A delayed request may have committed since the first lookup.
          // Never apply its echo as another device's conflicting edit.
          if (!await _readReceipt(scope, flight, generation: generation)) {
            if (!_current(generation)) return;
            throw StateError('正在确认上一批上传，确认后将继续同步');
          }
          flight = null;
        }
        if (!_current(generation)) return;
        final applied = await _store.applyChangePage(
          scope,
          page,
          includeSleepSchedule: sleepRevision != null,
        );
        calendarChanged = applied.calendarChanged || calendarChanged;
        sleepChanged = applied.sleepChanged || sleepChanged;
        if (sleepRevision != null) {
          if (page.containsKey('sleep_schedule')) {
            _sleepScheduleSupported = true;
          } else {
            _sleepScheduleSupported ??= false;
          }
        }
        if (page['has_more'] == true) continue;
        if (!canUpload()) break;
        if (flight != null &&
            await _store.releaseRejectedFlight(
              scope,
              flight['batch_id'] as String,
            )) {
          flight = null;
        }
        final fresh = flight == null;
        final batch = flight ?? await _store.freeze(scope);
        if (batch == null) {
          if (canUpload() && _sleepScheduleSupported == true) {
            final sleepWrite = await repository.sleepScheduleStore.prepare(
              scope,
            );
            if (sleepWrite != null && canUpload()) {
              final result = await _sendSleepSchedule(
                scope,
                sleepWrite,
                generation,
              );
              sleepChanged = result.changed || sleepChanged;
              if (result.accepted &&
                  canUpload() &&
                  (await repository.sleepScheduleStore.status(scope)).pending) {
                continue;
              }
            }
          }
          break;
        }
        if (!canUpload()) break;
        if (await _send(scope, batch, fresh: fresh, generation: generation)) {
          if (!_current(generation)) return;
          flight = batch;
          if (await _readReceipt(
            scope,
            flight,
            generation: generation,
            allowUnavailable: true,
          )) {
            flight = null;
          }
        } else {
          flight = null;
        }
      }
      if (_current(generation)) {
        _lastSync = DateTime.now();
        profile = await _store.profile(scope);
        if (!_current(generation)) return;
        final cursor = profile['cursor'] as String;
        if (_acknowledgedCursor != cursor) {
          await request('POST', '/v1/sync/ack', {
            'device_id': profile['device_id'],
            'cursor': cursor,
          });
          if (_current(generation)) _acknowledgedCursor = cursor;
        }
      }
    } on SyncRequestException catch (e) {
      if (!_current(generation) || _serviceDenied(e)) return;
      _error = _errorMessage(e);
      if (e.status == 410) await _store.resetCursor(scope);
    } catch (e) {
      if (!_current(generation)) return;
      _error = e is StateError ? e.message.toString() : '暂时无法连接云端，本地日程正常保存';
    } finally {
      _syncFailed = _error != null;
      _pendingCount = await _pendingFor(scope);
      _conflicts = await _store.conflicts(scope);
      _sleepScheduleConflict = _sleepScheduleSupported == true
          ? (await repository.sleepScheduleStore.status(scope)).conflict
          : null;
      if (calendarChanged) await onRemoteChange?.call();
      if (sleepChanged) await onRemoteSleepChange?.call();
      _busy = false;
      _emit();
    }
  }

  Future<({bool accepted, bool changed})> _sendSleepSchedule(
    String scope,
    Map<String, dynamic> write,
    int generation,
  ) async {
    try {
      final record = await request('PUT', '/v1/sync/sleep-schedule', write);
      if (!_current(generation)) return (accepted: false, changed: false);
      if (record['write_id'] != write['write_id'] ||
          !mapEquals(record['schedule'] as Map, write['schedule'] as Map)) {
        throw StateError('云端睡眠时段回执不符，请稍后重试');
      }
      final changed = await repository.sleepScheduleStore.accept(scope, record);
      return (accepted: true, changed: changed);
    } on SyncRequestException catch (error) {
      if (!_current(generation)) return (accepted: false, changed: false);
      if (error.status == 404) {
        // A server may have rolled back after this connection discovered support.
        _sleepScheduleSupported = false;
        return (accepted: false, changed: false);
      }
      if (error.status == 409 &&
          error.code == 'sleep_schedule_conflict' &&
          error.payload.containsKey('sleep_schedule')) {
        final changed = await repository.sleepScheduleStore.accept(
          scope,
          error.payload['sleep_schedule'] as Map<String, dynamic>?,
        );
        return (accepted: false, changed: changed);
      }
      rethrow;
    }
  }

  Future<bool> _send(
    String scope,
    Map<String, dynamic> batch, {
    required bool fresh,
    required int generation,
  }) async {
    try {
      final receipt = await request('POST', '/v1/sync/batches', batch);
      if (!_current(generation)) return false;
      await _store.acceptReceipt(scope, receipt);
    } on SyncRequestException catch (e) {
      if (!_current(generation)) return false;
      if (e.status == 403 &&
          (e.code == 'subscription_required' ||
              e.code == 'subscription_expired')) {
        final serviceDenied = _serviceDenied(e);
        if (fresh) {
          await _store.markFlightRejected(scope, batch['batch_id'] as String);
        }
        if (serviceDenied || !_current(generation)) return false;
        _setUploadPaused(true);
        return true;
      } else if (e.status == 409 &&
          e.code == 'revision_conflict' &&
          e.payload['conflicts'] is List) {
        await _store.rejectFlight(scope, e.payload['conflicts'] as List);
      } else {
        rethrow;
      }
    }
    return false;
  }

  // An unavailable lookup may defer resolution during a read-only pass.
  // Before an echo, snapshot, or upload it must be checked successfully.
  Future<bool> _readReceipt(
    String scope,
    Map<String, dynamic> batch, {
    required int generation,
    bool allowUnavailable = false,
  }) async {
    if (!_current(generation)) return false;
    final id = batch['batch_id'] as String;
    late final Map<String, dynamic> receipt;
    try {
      receipt = await request('GET', '/v1/sync/batches/$id', null);
    } on SyncRequestException catch (e) {
      if (e.status == 404 && e.code == 'receipt_not_found') return false;
      if (allowUnavailable && (e.status == 429 || e.status >= 500)) {
        return false;
      }
      rethrow;
    } on SocketException {
      if (allowUnavailable) return false;
      rethrow;
    } on TimeoutException {
      if (allowUnavailable) return false;
      rethrow;
    }
    if (!_current(generation)) return false;
    await _store.acceptReceipt(scope, receipt);
    return true;
  }

  Future<bool> _snapshot(
    String scope,
    int generation,
    Map<String, dynamic>? flight,
  ) async {
    if (!_current(generation)) return false;
    // Pages are staged in memory and applied in a single SQLite transaction.
    // Bounded by server's 64 MiB account quota; never clear live rows first.
    final first = await request('POST', '/v1/sync/snapshots', null);
    if (!_current(generation)) return false;
    final records = <Map<String, dynamic>>[];
    var page = first;
    var bytes = 0;
    final profile = await _store.profile(scope);
    if (first['dataset_id'] != null &&
        first['dataset_id'] != profile['dataset_id']) {
      throw StateError('云端数据空间与登录不符');
    }
    for (var pages = 0; pages < 10000; pages++) {
      bytes += utf8.encode(jsonEncode(page)).length;
      if (bytes > 80 * 1024 * 1024 ||
          records.length + (page['records'] as List).length > 50000) {
        throw StateError('云端快照超出安全大小限制');
      }
      records.addAll(
        (page['records'] as List).map(
          (r) => Map<String, dynamic>.from(r as Map),
        ),
      );
      if (!_current(generation)) return false;
      final next = page['next_page_token'];
      if (next == null) {
        if (flight != null && flight['sync_epoch'] == first['sync_epoch']) {
          // The snapshot has no batch IDs, so check again at its boundary.
          await _readReceipt(scope, flight, generation: generation);
          if (!_current(generation)) return false;
        }
        return _store.applySnapshot(
          scope,
          records,
          first['boundary_cursor'] as String,
          first['sync_epoch'] as String,
        );
      }
      page = await request(
        'GET',
        '/v1/sync/snapshots/${first['snapshot_id']}?page_token=${Uri.encodeQueryComponent(next as String)}',
        null,
      );
      if (page['boundary_cursor'] != first['boundary_cursor'] ||
          page['snapshot_id'] != first['snapshot_id']) {
        throw StateError('云端快照边界不一致，请重新连接');
      }
    }
    throw StateError('云端快照超出限制');
  }

  Future<void> resolveConflict(String id, {required bool useLocal}) async {
    final generation = _generation;
    await _running;
    if (!_current(generation) || _scope == null) return;
    final changed = await _store.resolve(_scope!, id, useLocal: useLocal);
    if (changed) await onRemoteChange?.call();
    await sync();
  }

  Future<void> resolveSleepScheduleConflict(
    SleepScheduleConflict conflict, {
    required bool useLocal,
  }) async {
    final generation = _generation;
    await _running;
    if (!_current(generation) || _scope == null) return;
    final changed = await repository.sleepScheduleStore.resolve(
      _scope!,
      conflict.remoteRevision,
      useLocal: useLocal,
    );
    if (changed) await onRemoteSleepChange?.call();
    await sync();
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _connected = false;
    _generation++;
    _localSubscription?.cancel();
    _debounce?.cancel();
    _watchGeneration++;
    _watchTimer?.cancel();
    _watchTimer = null;
    _prefetched = null;
    super.dispose();
  }
}
