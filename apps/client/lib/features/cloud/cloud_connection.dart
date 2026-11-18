import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:weekglass_data/weekglass_data.dart';

import 'cloud_auth_service.dart';
import 'cloud_sync_engine.dart';

enum CloudSubscriptionState {
  signedOut('未连接'),
  checking('待确认'),
  notSubscribed('未开通'),
  active('已开通'),
  expired('已到期');

  const CloudSubscriptionState(this.label);
  final String label;
}

String cloudErrorMessage(Object error) {
  if (error is CloudLoginException) return error.message;
  if (error is CloudApiException) {
    if (error.code == 'incorrect_password') return '当前密码不正确，请重试。';
    if (error.code == 'confirmation_required') return '请输入当前账号名以确认删除。';
    if (error.code == 'device_limit') return '已达到设备上限，请先撤销一台旧设备。';
    if (error.code == 'subscription_required' ||
        error.code == 'subscription_expired') {
      return '没有有效的云服务，不能合并或同步日程。本机日程已保留。';
    }
    return switch (error.status) {
      401 => '登录已失效，请断开后重新连接。',
      403 => '当前账号没有此操作的权限，本机日程和待同步修改已保留。',
      429 => '请求稍多，请稍后重试。',
      507 => '云端空间已满，本机修改已保留。',
      _ => '服务器暂时无法完成请求，请稍后重试。',
    };
  }
  if (error is SocketException || error is TimeoutException) {
    return '暂时无法连接，请检查网络后重试。';
  }
  if (error is HandshakeException) return '服务器证书无法验证，请检查服务器地址与证书。';
  if (error is ArgumentError) return error.message.toString();
  if (error is FormatException) return '服务器响应或已保存的连接信息无效，请重新连接。';
  return '连接未完成，请重试。本机日程不会丢失。';
}

class CloudConnection extends ChangeNotifier with WidgetsBindingObserver {
  CloudConnection({
    required SqliteEventRepository repository,
    CloudAuthService? auth,
  }) : auth = auth ?? CloudAuthService() {
    this.auth.syncTransportAllowed = _canTransport;
    engine = CloudSyncEngine(
      repository: repository,
      request: this.auth.request,
      canTransport: _canTransport,
      onRemoteChange: () async {
        await refreshPlanner?.call();
      },
      onRemoteSleepChange: () async {
        await refreshSleepSchedule?.call();
      },
      onServiceDenied: _serviceDenied,
    );
    engine.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
  }

  final CloudAuthService auth;
  late final CloudSyncEngine engine;
  Future<void> Function()? refreshPlanner;
  Future<void> Function()? refreshSleepSchedule;
  bool working = false;
  bool ready = false;
  bool _paused = false;
  bool _foreground = true;
  bool _disconnecting = false;
  bool _disposed = false;
  bool _cancelLoginRequested = false;
  int _accountRead = 0;
  int _accountProfileRead = 0;
  int _sessionRead = 0;
  Future<void>? _entitlementRead;
  Future<void>? _engineConnection;
  int _entitlementRevision = 0;
  Timer? _entitlementTimer;
  bool _entitlementsStale = false;
  CloudLoginPhase? loginPhase;
  bool accountLoading = false;
  String? accountProblem;
  String? problem;
  Map<String, dynamic>? entitlements;
  Map<String, dynamic>? account;
  List<Map<String, dynamic>> devices = [];
  bool get busy => working || engine.busy;
  bool get connected => auth.connected;
  bool get entitlementsStale => _entitlementsStale;
  DateTime? get currentPeriodEnd =>
      DateTime.tryParse(entitlements?['current_period_end']?.toString() ?? '');

  CloudSubscriptionState get subscriptionState {
    if (!auth.connected || !auth.official) {
      return CloudSubscriptionState.signedOut;
    }
    final end = currentPeriodEnd;
    return switch (entitlements?['status']) {
      'active' when end != null && !DateTime.now().isBefore(end) =>
        CloudSubscriptionState.expired,
      'active'
          when entitlements?['sync_read'] == true &&
              entitlements?['sync_write'] == true =>
        CloudSubscriptionState.active,
      'expired' => CloudSubscriptionState.expired,
      'not_subscribed' => CloudSubscriptionState.notSubscribed,
      _ => CloudSubscriptionState.checking,
    };
  }

  bool get canSync =>
      auth.connected &&
      (!auth.official || subscriptionState == CloudSubscriptionState.active);

  bool _canTransport() =>
      !_disposed &&
      !_paused &&
      !_disconnecting &&
      auth.mergeApproved &&
      canSync;

  String? get accountLabel =>
      (account?['verified_email'] ??
              account?['pending_email'] ??
              account?['username'])
          as String?;
  String get displayName => auth.official ? 'WeekGlass 云' : '自己的服务器';
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    working = true;
    notifyListeners();
    try {
      await auth.restore();
      if (auth.connected) {
        if (auth.official) {
          await _refreshEntitlementsQuietly();
        } else {
          await _ensureEngine();
          await refreshAccount();
        }
      }
    } catch (error) {
      problem = cloudErrorMessage(error);
    } finally {
      ready = true;
      working = false;
      _changed();
    }
  }

  Future<void> login(String origin) async {
    if (working) return;
    working = true;
    problem = null;
    loginPhase = CloudLoginPhase.checkingServer;
    _cancelLoginRequested = false;
    _changed();
    try {
      auth.closeOfficialSyncTransport();
      await engine.disconnect();
      if (_cancelLoginRequested) throw CloudLoginException('已取消登录。');
      await auth.login(
        origin,
        onPhaseChanged: (phase) {
          loginPhase = phase;
          _changed();
        },
      );
      if (_disposed) return;
      _invalidateEntitlements();
      entitlements = null;
      account = null;
      accountLoading = false;
      devices = [];
      if (auth.official) {
        unawaited(_refreshEntitlementsQuietly());
      } else {
        unawaited(refreshAccount(afterLogin: true));
      }
    } catch (error) {
      problem = cloudErrorMessage(error);
      rethrow;
    } finally {
      loginPhase = null;
      working = false;
      _changed();
    }
  }

  void cancelLogin() {
    _cancelLoginRequested = true;
    auth.cancelLogin();
  }

  Future<void> approveAndConnect() async {
    if (working) return;
    if (!canSync) {
      throw CloudLoginException('开通云服务后才能合并与同步日程。');
    }
    working = true;
    notifyListeners();
    try {
      await auth.approveMerge(includeSleepSchedule: true);
      await _ensureEngine();
    } finally {
      working = false;
      notifyListeners();
    }
  }

  Future<void> approveSleepSchedule() => _accountAction(() async {
    if (!_canTransport()) return;
    await auth.approveSleepSchedule();
    if (engine.connected) {
      await engine.enableSleepSchedule();
    } else {
      await _ensureEngine();
    }
  });

  Future<void> _ensureEngine() {
    if (_engineConnection case final pending?) return pending;
    if (!_foreground || !_canTransport() || engine.connected) {
      return Future.value();
    }
    return _engineConnection = engine
        .connect(
          serverId: auth.serverId,
          accountId: auth.accountId,
          datasetId: auth.datasetId,
          epoch: auth.epoch,
          deviceId: auth.deviceId,
          uploadLocal: true,
          recoverReceipts: auth.official,
          synchronizeSleepSchedule: auth.sleepScheduleApproved,
        )
        .whenComplete(() => _engineConnection = null);
  }

  Future<void> refreshEntitlements() {
    if (_disposed || !auth.connected) return Future.value();
    final session = _sessionRead;
    return _entitlementRead ??= _readEntitlements(session).whenComplete(() {
      if (session == _sessionRead) _entitlementRead = null;
    });
  }

  /// Wait for a check already started by login, without making another request.
  Future<void> waitForEntitlements() async {
    try {
      await _entitlementRead;
    } catch (_) {
      // A successful login does not require a successful metadata read.
    }
  }

  bool _currentSession(int session) =>
      !_disposed && session == _sessionRead && auth.connected;

  Future<void> _readEntitlements(int session) async {
    final revision = _entitlementRevision;
    bool current() =>
        _currentSession(session) && revision == _entitlementRevision;
    final Map<String, dynamic> rights;
    try {
      rights = await auth.request('GET', '/v1/me/entitlements', null);
    } catch (_) {
      if (!current()) return;
      _entitlementsStale = entitlements != null;
      _scheduleEntitlementExpiry();
      _changed();
      rethrow;
    }
    if (!current()) return;
    final wasAllowed = canSync;
    entitlements = rights;
    _entitlementsStale = false;
    if (auth.official && !canSync) _suspendOfficialTransport();
    _scheduleEntitlementExpiry();
    _changed();
    if (auth.official && !wasAllowed && _canTransport() && _foreground) {
      try {
        if (engine.connected) {
          await engine.resumeTransport();
        } else {
          await _ensureEngine();
        }
      } catch (error) {
        if (current()) {
          problem = cloudErrorMessage(error);
          _changed();
        }
      }
    }
  }

  Future<void> _refreshEntitlementsQuietly() async {
    try {
      await refreshEntitlements();
    } catch (_) {
      // The last known entitlement and sync state remain visible.
    }
  }

  bool _serviceDenied(SyncRequestException _) {
    if (!auth.official) return false;
    _entitlementRevision++;
    entitlements = {
      ...?entitlements,
      'status': 'expired',
      'sync_read': false,
      'sync_write': false,
      'current_period_end': null,
    };
    _entitlementsStale = false;
    _entitlementTimer?.cancel();
    _suspendOfficialTransport();
    return true;
  }

  void _suspendOfficialTransport() {
    auth.closeOfficialSyncTransport();
    if (engine.connected) engine.suspendTransport();
  }

  void _scheduleEntitlementExpiry() {
    _entitlementTimer?.cancel();
    _entitlementTimer = null;
    if (_paused || subscriptionState != CloudSubscriptionState.active) {
      return;
    }
    final expiry = currentPeriodEnd;
    if (expiry == null) return;
    final remaining = expiry.difference(DateTime.now());
    if (remaining <= Duration.zero) return;
    _entitlementTimer = Timer(remaining, () {
      if (canSync) {
        _scheduleEntitlementExpiry();
        return;
      }
      _suspendOfficialTransport();
      _changed();
      if (_foreground) unawaited(_refreshEntitlementsQuietly());
    });
  }

  void _invalidateEntitlements() {
    _sessionRead++;
    _entitlementRead = null;
    _entitlementsStale = false;
    _entitlementTimer?.cancel();
    _entitlementTimer = null;
  }

  /// Official account identity is read only when the sync page is opened.
  Future<void> loadOfficialIdentity() async {
    if (!auth.official || accountLoading || account != null) return;
    final session = _sessionRead;
    accountLoading = true;
    try {
      await _refreshAccountProfile();
    } catch (_) {
      // Subscription and sync do not depend on account profile metadata.
    } finally {
      if (_currentSession(session)) {
        accountLoading = false;
        _changed();
      }
    }
  }

  Future<void> _refreshAccountProfile({bool notify = true}) async {
    if (_disposed || !auth.connected) return;
    final session = _sessionRead;
    final read = ++_accountProfileRead;
    bool current() => _currentSession(session) && _accountProfileRead == read;
    try {
      final details = await auth.request('GET', '/v1/me/account', null);
      if (current()) account = details;
    } on CloudApiException catch (error) {
      if (error.status != 404) rethrow;
      if (current()) account = null; // Older self-hosted servers.
    } finally {
      if (notify && current()) _changed();
    }
  }

  Future<void> refreshAccount({bool afterLogin = false}) async {
    final read = ++_accountRead;
    bool current() => !_disposed && _accountRead == read && auth.connected;
    accountProblem = null;
    if (afterLogin) accountLoading = true;
    try {
      await refreshEntitlements();
      if (!current()) return;
      if (!auth.official) {
        final result = await auth.request('GET', '/v1/devices', null);
        if (!current()) return;
        devices = (result['devices'] as List).cast<Map<String, dynamic>>();
      }
      await _refreshAccountProfile(notify: false);
    } catch (_) {
      if (!afterLogin) rethrow;
      if (current()) accountProblem = '连接已完成，暂时无法读取账号或设备资料。';
    } finally {
      if (current()) {
        accountLoading = false;
        _changed();
      }
    }
  }

  Future<T> _accountAction<T>(Future<T> Function() action) async {
    if (working) throw StateError('请等待当前操作完成。');
    working = true;
    problem = null;
    notifyListeners();
    try {
      return await action();
    } catch (error) {
      problem = cloudErrorMessage(error);
      rethrow;
    } finally {
      working = false;
      notifyListeners();
    }
  }

  Future<void> renameDevice(Map<String, dynamic> device, String name) =>
      _accountAction(() async {
        await auth.request('PATCH', '/v1/devices/${device['device_id']}', {
          'device_id': device['device_id'],
          'display_name': name.trim(),
          'platform': device['platform'],
          'app_version': device['app_version'],
        });
        await refreshAccount();
      });

  Future<String> rotateRecoveryKey(String password) => _accountAction(() async {
    final result = await auth.request('POST', '/v1/me/recovery-key', {
      'current_password': password,
    });
    await refreshAccount();
    return result['recovery_key'] as String;
  });

  Future<void> revokeOtherDevices(String password) => _accountAction(() async {
    await auth.request('POST', '/v1/me/sessions/revoke-others', {
      'current_password': password,
    });
    await refreshAccount();
  });

  Future<void> changePassword(String current, String next) =>
      _accountAction(() async {
        await auth.request('POST', '/v1/me/password', {
          'current_password': current,
          'new_password': next,
        });
        await _clearConnection();
      });

  Future<void> deleteAccount(String password, String confirmation) =>
      _accountAction(() async {
        await auth.request('DELETE', '/v1/me/account', {
          'current_password': password,
          'confirmation': confirmation,
        });
        await _clearConnection();
      });

  Future<Map<String, dynamic>> exportCalendar() => _accountAction(() {
    if (auth.official) {
      throw CloudLoginException('请在浏览器中的云服务账号页面导出。');
    }
    return auth.request('GET', '/v1/exports/calendar', null);
  });

  Future<void> sync() async {
    if (working || !_canTransport()) return;
    working = true;
    problem = null;
    notifyListeners();
    try {
      if (auth.official) await _refreshEntitlementsQuietly();
      if (engine.connected) {
        await engine.sync();
      } else {
        await _ensureEngine();
      }
    } catch (error) {
      problem = cloudErrorMessage(error);
    } finally {
      working = false;
      notifyListeners();
    }
  }

  Future<void> revokeDevice(String id) async {
    await _accountAction(() async {
      await auth.request('DELETE', '/v1/devices/$id', null);
      await refreshAccount();
    });
  }

  Future<void> _clearConnection() async {
    _disconnecting = true;
    auth.closeOfficialSyncTransport();
    cancelLogin();
    _accountRead++;
    _invalidateEntitlements();
    accountLoading = false;
    accountProblem = null;
    try {
      await _engineConnection;
      await engine.disconnect();
      await auth.logout();
      entitlements = null;
      account = null;
      devices = [];
      problem = null;
    } finally {
      _disconnecting = false;
    }
  }

  Future<void> disconnect() async {
    working = true;
    notifyListeners();
    try {
      await _clearConnection();
    } finally {
      working = false;
      notifyListeners();
    }
  }

  Future<void> quiesce() async {
    _paused = true;
    _entitlementTimer?.cancel();
    auth.closeOfficialSyncTransport();
    engine.setForeground(false);
    cancelLogin();
    while (working) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    await _engineConnection;
    await engine.disconnect();
  }

  Future<void> resume() async {
    _paused = false;
    await _resumeForeground();
  }

  Future<void> _resumeForeground() async {
    if (auth.official) await _refreshEntitlementsQuietly();
    if (_disposed || _paused || !_foreground) return;
    engine.setForeground(true);
    try {
      await _ensureEngine();
    } catch (error) {
      problem = cloudErrorMessage(error);
      _changed();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground =
        state != AppLifecycleState.hidden &&
        state != AppLifecycleState.paused &&
        state != AppLifecycleState.detached;
    if (!_foreground || _paused) {
      engine.setForeground(false);
      return;
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(_resumeForeground());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _invalidateEntitlements();
    auth.closeOfficialSyncTransport();
    WidgetsBinding.instance.removeObserver(this);
    cancelLogin();
    engine.removeListener(_changed);
    engine.dispose();
    super.dispose();
  }
}
