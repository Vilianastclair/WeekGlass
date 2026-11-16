import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:weekglass_data/weekglass_data.dart';

import 'cloud_auth_service.dart';
import 'cloud_sync_engine.dart';

String cloudErrorMessage(Object error) {
  if (error is CloudLoginException) return error.message;
  if (error is CloudApiException) {
    if (error.code == 'incorrect_password') return '当前密码不正确，请重试。';
    if (error.code == 'confirmation_required') return '请输入当前账号名以确认删除。';
    if (error.code == 'device_limit') return '已达到设备上限，请先在已连接的设备上撤销旧设备。';
    return switch (error.status) {
      401 => '登录已失效，请断开后重新连接。',
      403 => '当前账号暂无云端写入权限，本机日程和待同步修改已保留。',
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
    engine = CloudSyncEngine(
      repository: repository,
      request: this.auth.request,
      onRemoteChange: () async {
        await refreshPlanner?.call();
      },
      onUploadDenied: _uploadDenied,
    );
    engine.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
  }

  final CloudAuthService auth;
  late final CloudSyncEngine engine;
  Future<void> Function()? refreshPlanner;
  bool working = false;
  bool ready = false;
  bool _paused = false;
  bool _foreground = true;
  bool _disposed = false;
  bool _cancelLoginRequested = false;
  int _accountRead = 0;
  int _accountProfileRead = 0;
  int _sessionRead = 0;
  Future<void>? _entitlementRead;
  int _writeDenials = 0;
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
  bool get emailVerificationRequired =>
      auth.official && account?['email_verification_required'] == true;
  bool get emailVerificationAvailable =>
      emailVerificationRequired &&
      account?['email_verification_available'] == true;
  bool get emailVerified => auth.official && account?['email_verified'] == true;
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
        if (auth.official) await _refreshEntitlementsQuietly();
        if (auth.mergeApproved) await _connectEngine();
        await _refreshAccount(readEntitlements: !auth.official);
      }
    } catch (error) {
      problem = cloudErrorMessage(error);
    } finally {
      ready = true;
      working = false;
      notifyListeners();
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
      devices = [];
      unawaited(refreshAccount(afterLogin: true));
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
    working = true;
    notifyListeners();
    try {
      await auth.approveMerge();
      await _connectEngine();
    } finally {
      working = false;
      notifyListeners();
    }
  }

  Future<void> _connectEngine() async {
    final official = auth.official;
    final wasPaused = engine.uploadPaused;
    final denials = _writeDenials;
    await engine.connect(
      serverId: auth.serverId,
      accountId: auth.accountId,
      datasetId: auth.datasetId,
      epoch: auth.epoch,
      deviceId: auth.deviceId,
      uploadLocal: true,
      uploadPaused:
          official &&
          (entitlements?['sync_write'] == false ||
              (wasPaused && _entitlementsStale)),
      recoverReceipts: official,
    );
    final allowed = entitlements?['sync_write'];
    if (official &&
        denials == _writeDenials &&
        !_entitlementsStale &&
        allowed is bool) {
      await engine.updateWriteEntitlement(allowed);
    }
  }

  Future<void> refreshEntitlements() {
    if (_disposed || !auth.connected) return Future.value();
    final session = _sessionRead;
    return _entitlementRead ??= _readEntitlements(session).whenComplete(() {
      if (session == _sessionRead) _entitlementRead = null;
    });
  }

  bool _currentSession(int session) =>
      !_disposed && session == _sessionRead && auth.connected;

  Future<void> _readEntitlements(int session) async {
    final denials = _writeDenials;
    try {
      final rights = await auth.request('GET', '/v1/me/entitlements', null);
      if (!_currentSession(session) || denials != _writeDenials) return;
      entitlements = rights;
      _entitlementsStale = false;
      final allowed = rights['sync_write'];
      if (auth.official && allowed is bool) {
        unawaited(engine.updateWriteEntitlement(allowed));
      }
      _scheduleEntitlementExpiry();
    } catch (_) {
      if (!_currentSession(session) || denials != _writeDenials) return;
      _entitlementsStale = entitlements != null;
      rethrow;
    } finally {
      if (_currentSession(session)) _changed();
    }
  }

  Future<void> _refreshEntitlementsQuietly() async {
    try {
      await refreshEntitlements();
    } catch (_) {
      // The last known entitlement and sync state remain visible.
    }
  }

  void _uploadDenied() {
    if (!auth.official) return;
    _writeDenials++;
    _entitlementsStale = entitlements != null;
    _entitlementTimer?.cancel();
    _changed();
    if (_paused || !_foreground) return;
    final session = _sessionRead;
    unawaited(() async {
      // A rights read that started before the denied write may still be stale.
      await _entitlementRead?.then<void>((_) {}, onError: (Object _) {});
      if (_currentSession(session) && !_paused && _foreground) {
        await _refreshEntitlementsQuietly();
      }
    }());
  }

  void _scheduleEntitlementExpiry() {
    _entitlementTimer?.cancel();
    _entitlementTimer = null;
    if (!_foreground ||
        _paused ||
        !auth.official ||
        entitlements?['sync_write'] != true) {
      return;
    }
    final end = entitlements?['current_period_end'];
    final expiry = end is String ? DateTime.tryParse(end) : null;
    if (expiry == null) return;
    final remaining = expiry.difference(DateTime.now());
    // A skewed clock must not create a tight loop or revoke rights locally.
    if (remaining <= Duration.zero) return;
    _entitlementTimer = Timer(
      remaining + const Duration(seconds: 1),
      () => unawaited(_refreshEntitlementsQuietly()),
    );
  }

  void _invalidateEntitlements() {
    _sessionRead++;
    _entitlementRead = null;
    _entitlementsStale = false;
    _entitlementTimer?.cancel();
    _entitlementTimer = null;
  }

  Future<void> refreshAccount({bool afterLogin = false}) =>
      _refreshAccount(afterLogin: afterLogin, readEntitlements: true);

  /// Verification can be refreshed without waiting for sync or device reads.
  Future<void> refreshAccountProfile() => _refreshAccountProfile();

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

  Future<bool> openEmailVerification() => emailVerificationAvailable
      ? auth.openEmailVerification()
      : Future.value(false);

  Future<void> refreshEmailStatusQuietly() async {
    if (!auth.official || emailVerified) return;
    try {
      await refreshAccountProfile();
    } catch (_) {
      // Keep the last confirmed status on automatic refresh.
    }
  }

  Future<void> _refreshAccount({
    bool afterLogin = false,
    required bool readEntitlements,
  }) async {
    final read = ++_accountRead;
    bool current() => !_disposed && _accountRead == read && auth.connected;
    accountProblem = null;
    if (afterLogin) accountLoading = true;
    try {
      if (readEntitlements) await refreshEntitlements();
      if (!current()) return;
      final result = await auth.request('GET', '/v1/devices', null);
      if (!current()) return;
      devices = (result['devices'] as List).cast<Map<String, dynamic>>();
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

  Future<Map<String, dynamic>> exportCalendar() =>
      _accountAction(() => auth.request('GET', '/v1/exports/calendar', null));

  Future<void> sync() async {
    if (working) return;
    working = true;
    _paused = false;
    problem = null;
    notifyListeners();
    try {
      try {
        await refreshAccount();
      } catch (error) {
        problem = cloudErrorMessage(error);
      }
      if (!engine.connected && auth.mergeApproved) {
        await _connectEngine();
      } else {
        await engine.sync();
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
    cancelLogin();
    _accountRead++;
    _invalidateEntitlements();
    accountLoading = false;
    accountProblem = null;
    await engine.disconnect();
    await auth.logout();
    entitlements = null;
    account = null;
    devices = [];
    problem = null;
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
    engine.setForeground(false);
    cancelLogin();
    while (working) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    await engine.disconnect();
  }

  Future<void> resume() async {
    _paused = false;
    engine.setForeground(_foreground);
    if (auth.connected && auth.mergeApproved) await sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground =
        state != AppLifecycleState.hidden &&
        state != AppLifecycleState.paused &&
        state != AppLifecycleState.detached;
    engine.setForeground(_foreground && !_paused);
    if (!_foreground) {
      _entitlementTimer?.cancel();
      return;
    }
    if (state != AppLifecycleState.resumed || !auth.connected || _paused) {
      return;
    }
    if (auth.mergeApproved && !engine.connected && !working) {
      unawaited(sync());
    } else if (auth.official) {
      unawaited(_refreshEntitlementsQuietly());
      unawaited(refreshEmailStatusQuietly());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _invalidateEntitlements();
    WidgetsBinding.instance.removeObserver(this);
    cancelLogin();
    engine.removeListener(_changed);
    engine.dispose();
    super.dispose();
  }
}
