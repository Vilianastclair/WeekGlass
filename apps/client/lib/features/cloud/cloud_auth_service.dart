import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import 'package:weekglass_data/weekglass_data.dart';

import '../updates/update_service.dart';
import 'cloud_auth_callback_page.dart';

const officialCloudOrigin = 'https://cloud.viliana.cn';
const legacyOfficialCloudOrigin = 'https://cloud.viliana.cn:8443';

enum CloudPortalPage {
  account(''),
  plans('plans'),
  calendar('calendar');

  const CloudPortalPage(this.fragment);
  final String fragment;
  Uri get uri => Uri.parse(
    '$officialCloudOrigin/account${fragment.isEmpty ? '' : '#$fragment'}',
  );
}

// Account requests and self-hosted sync can reuse this connection pool.
final _cloudHttpClient = _createCloudHttpClient();

HttpClient _createCloudHttpClient() => HttpClient()
  ..connectionTimeout = const Duration(seconds: 12)
  ..idleTimeout = const Duration(seconds: 30)
  ..maxConnectionsPerHost = 4;

class CloudApiException extends SyncRequestException {
  CloudApiException(super.status, super.code, super.payload);
  @override
  String toString() => 'CloudApiException($status, $code)';
}

enum CloudLoginPhase { checkingServer, waitingForBrowser, exchanging, saving }

enum CloudDevicePlatform {
  windows('windows', 'WeekGlass Windows'),
  android('android', 'WeekGlass Android'),
  macOS('macos', 'WeekGlass macOS');

  const CloudDevicePlatform(this.id, this.label);
  final String id;
  final String label;

  static CloudDevicePlatform? forOperatingSystem(String operatingSystem) {
    return switch (operatingSystem) {
      'windows' => windows,
      'android' => android,
      'macos' => macOS,
      _ => null,
    };
  }
}

class CloudLoginException extends StateError {
  CloudLoginException(super.message);
}

class _CloudLogin {
  final cancelled = Completer<void>();
  final finished = Completer<void>();
  bool committed = false;

  void cancel() {
    if (!committed && !cancelled.isCompleted) cancelled.complete();
  }

  void checkCancellation() {
    if (cancelled.isCompleted) throw CloudLoginException('已取消登录。');
  }

  Future<T> wait<T>(
    Future<T> operation, {
    Duration? timeout,
    String? timeoutMessage,
  }) {
    final result = Future.any([
      operation,
      cancelled.future.then<T>((_) => throw CloudLoginException('已取消登录。')),
    ]);
    return timeout == null
        ? result
        : result.timeout(
            timeout,
            onTimeout: () => throw CloudLoginException(timeoutMessage!),
          );
  }
}

abstract interface class CloudTokenVault {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> clear();
}

class SecureCloudTokenVault implements CloudTokenVault {
  static const _storage = FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );
  static const _key = 'weekglass.cloud.session.v1';
  @override
  Future<String?> read() => _storage.read(key: _key);
  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);
  @override
  Future<void> clear() => _storage.delete(key: _key);
}

/// The native broker owns the refresh credential. Dart keeps the current
/// short-lived access grant in memory and uses an opaque ID to request renewal.
class MacCloudSessionVault implements CloudTokenVault {
  static const _channel = MethodChannel('weekglass/macos_account');

  Future<Map<String, dynamic>> _call(Map<String, dynamic> input) async {
    final reply = await _channel.invokeMethod<String>(
      'account',
      jsonEncode(input),
    );
    final result = jsonDecode(reply!) as Map<String, dynamic>;
    if (result['error'] != null) {
      if (result['error'] == 'keychain') {
        throw CloudLoginException('macOS 钥匙串暂时不可用，请解锁后重试。');
      }
      throw CloudApiException(
        result['status'] as int,
        result['error'] as String,
        {},
      );
    }
    return (result['value'] as Map<String, dynamic>?) ?? {};
  }

  @override
  Future<String?> read() async {
    final result = await _call({'op': 'restore'});
    return result.isEmpty ? null : jsonEncode(result);
  }

  @override
  Future<void> write(String value) async {
    final current = jsonDecode(value) as Map<String, dynamic>;
    await _call({
      'op': 'commit',
      'handle': current['refresh_token'],
      'merge': current['merge_approved'],
      'sleep': current['sleep_schedule_approved'],
    });
  }

  @override
  Future<void> clear() async {
    await _call({'op': 'clear'});
  }

  Future<Map<String, dynamic>> authorize(
    String origin,
    String server,
    Map<String, dynamic> grant,
  ) => _call({
    'op': 'authorize',
    'origin': origin,
    'server_id': server,
    ...grant,
  });

  Future<Map<String, dynamic>> renew(String handle) =>
      _call({'op': 'renew', 'handle': handle});
  Future<void> revoke(String handle) async {
    await _call({'op': 'revoke', 'handle': handle});
  }
}

typedef CloudHttpTransport = Future<Map<String, dynamic>> Function(
  Uri uri,
  String method,
  Map<String, dynamic>? body,
  Map<String, String> headers,
  bool form,
);

/// Only origins are accepted; redirects never inherit credentials.
Uri validateCloudOrigin(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw ArgumentError('请输入完整的 HTTPS 服务器地址，不包含路径。');
  }
  return Uri.parse(uri.origin);
}

Future<Map<String, dynamic>> cloudHttpRequest(
  Uri uri,
  String method,
  Map<String, dynamic>? body,
  Map<String, String> headers,
  bool form, {
  HttpClient? client,
}) async {
  final request = await (client ?? _cloudHttpClient)
      .openUrl(method, uri)
      .timeout(const Duration(seconds: 15));
  request.followRedirects = false;
  headers.forEach(request.headers.set);
  request.headers.set(HttpHeaders.acceptHeader, 'application/json');
  if (body != null) {
    request.headers.contentType = form
        ? ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8')
        : ContentType.json;
    request.write(
      form
          ? Uri(queryParameters: body.map((k, v) => MapEntry(k, '$v'))).query
          : jsonEncode(body),
    );
  }
  final response = await request.close().timeout(const Duration(seconds: 35));
  final bytes = <int>[];
  await for (final chunk in response.timeout(const Duration(seconds: 35))) {
    bytes.addAll(chunk);
    final limit = uri.path == '/v1/exports/calendar' ? 80 : 24;
    if (bytes.length > limit * 1024 * 1024) {
      throw const FormatException('服务器响应过大');
    }
  }
  Map<String, dynamic> value = {};
  if (bytes.isNotEmpty) {
    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw CloudApiException(response.statusCode, 'http_error', {});
      }
      rethrow;
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('服务器响应无效');
    }
    value = decoded;
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw CloudApiException(
      response.statusCode,
      value['code'] is String ? value['code'] as String : 'http_error',
      value,
    );
  }
  return value;
}

class CloudAuthService {
  CloudAuthService({
    CloudTokenVault? vault,
    CloudHttpTransport? transport,
    Future<bool> Function(Uri)? browserLauncher,
    CloudDevicePlatform? devicePlatform,
    this.callbackTimeout = const Duration(minutes: 5),
  }) : _vault =
           vault ??
           (Platform.isMacOS
               ? MacCloudSessionVault()
               : SecureCloudTokenVault()),
       _transportOverride = transport,
       _devicePlatform =
           devicePlatform ??
           CloudDevicePlatform.forOperatingSystem(Platform.operatingSystem),
       _launch =
           browserLauncher ??
           ((uri) => launchUrl(uri, mode: LaunchMode.externalApplication));

  final CloudTokenVault _vault;
  final CloudHttpTransport? _transportOverride;
  final CloudDevicePlatform? _devicePlatform;
  final Duration callbackTimeout;
  final Future<bool> Function(Uri) _launch;
  bool Function()? syncTransportAllowed;
  Map<String, dynamic>? _session;
  Future<String>? _refreshing;
  Future<void>? _loggingOut;
  Future<void> _vaultWrites = Future.value();
  int _sessionGeneration = 0;
  int _officialSyncGeneration = 0;
  HttpClient? _officialSyncClient;
  _CloudLogin? _login;
  bool get connected => _session != null;
  bool get mergeApproved => _session?['merge_approved'] == true;
  bool get sleepScheduleApproved =>
      mergeApproved && _session?['sleep_schedule_approved'] == true;
  String? get origin => _session?['origin'] as String?;
  String get serverId => _session!['server_id'] as String;
  String get accountId => _session!['account_id'] as String;
  String get deviceId => _session!['device_id'] as String;
  String get datasetId => _session!['dataset_id'] as String;
  String get epoch => _session!['sync_epoch'] as String;
  bool get official =>
      origin == officialCloudOrigin || origin == legacyOfficialCloudOrigin;

  /// Abort only the official data stream, without interrupting account or
  /// entitlement requests. The next service period opens a fresh connection.
  void closeOfficialSyncTransport() {
    _officialSyncGeneration++;
    _officialSyncClient?.close(force: true);
    _officialSyncClient = null;
  }

  Future<Map<String, dynamic>> _transport(
    Uri uri,
    String method,
    Map<String, dynamic>? body,
    Map<String, String> headers,
    bool form, {
    bool officialSync = false,
  }) =>
      _transportOverride?.call(uri, method, body, headers, form) ??
      cloudHttpRequest(
        uri,
        method,
        body,
        headers,
        form,
        client: officialSync
            ? _officialSyncClient ??= _createCloudHttpClient()
            : null,
      );

  Future<void> restore() async {
    final generation = _sessionGeneration;
    final stored = await _vault.read();
    if (stored == null ||
        generation != _sessionGeneration ||
        _loggingOut != null) {
      return;
    }
    final value = jsonDecode(stored) as Map<String, dynamic>;
    validateCloudOrigin(value['origin'] as String);
    _validateTokens(value, offlineState: _vault is MacCloudSessionVault);
    _session = value;
    _sessionGeneration++;
    _refreshing = null;
  }

  void _validateTokens(
    Map<String, dynamic> tokens, {
    bool offlineState = false,
  }) {
    for (final key in [
      if (!offlineState) 'access_token',
      'refresh_token',
      'server_id',
      'account_id',
      'device_id',
      'dataset_id',
      'sync_epoch',
    ]) {
      if (tokens[key] is! String || (tokens[key] as String).isEmpty) {
        throw const FormatException('登录响应不完整');
      }
    }
    if (tokens['token_type'] != 'Bearer') {
      throw const FormatException('不支持的登录类型');
    }
    final uuid = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    );
    for (final key in [
      'server_id',
      'account_id',
      'device_id',
      'dataset_id',
      'sync_epoch',
    ]) {
      if (!uuid.hasMatch(tokens[key] as String)) {
        throw const FormatException('登录身份无效');
      }
    }
    if ((!offlineState && (tokens['access_token'] as String).length < 32) ||
        (tokens['refresh_token'] as String).length < 32) {
      throw const FormatException('登录凭据无效');
    }
  }

  static String randomSecret() {
    final random = Random.secure();
    return base64UrlEncode(List<int>.generate(48, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  Future<void> login(
    String address, {
    void Function(CloudLoginPhase)? onPhaseChanged,
  }) async {
    if (_login != null) throw CloudLoginException('已有登录正在进行。');
    if (_loggingOut != null) throw CloudLoginException('正在断开连接，请稍后重试。');
    final login = _CloudLogin();
    _login = login;
    HttpServer? listener;
    final callbackResponses = <Future<void>>[];
    final receipt = Completer<bool>();
    try {
      onPhaseChanged?.call(CloudLoginPhase.checkingServer);
      final base = validateCloudOrigin(address);
      final info = await login.wait(
        _transport(base.resolve('/v1/server-info'), 'GET', null, {}, false),
      );
      login.checkCancellation();
      if (info['protocol_version'] != '1' ||
          info['server_id'] is! String ||
          info['authorization_endpoint'] !=
              '${base.origin}/v1/auth/authorize' ||
          info['token_endpoint'] != '${base.origin}/v1/auth/token') {
        throw const FormatException('服务器协议或登录地址不匹配');
      }
      final prefs = SharedPreferencesAsync();
      var device = await login.wait(
        prefs.getString('cloud_installation_device_id'),
      );
      device ??= const Uuid().v4();
      await login.wait(prefs.setString('cloud_installation_device_id', device));
      login.checkCancellation();
      final verifier = randomSecret();
      final state = randomSecret();
      final challenge = base64UrlEncode(
        sha256.convert(ascii.encode(verifier)).bytes,
      ).replaceAll('=', '');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      listener = server;
      login.checkCancellation();
      final redirect = 'http://127.0.0.1:${server.port}/oauth/callback';
      final result = Completer<String>();
      String? claimedCode;
      final callbackPages = loadCloudAuthCallbackPages();
      server.listen((request) {
        final Map<String, List<String>> q;
        try {
          q = request.uri.queryParametersAll;
        } on FormatException {
          unawaited(_writeCallback(request, callbackPages, status: 400));
          return;
        }
        final valid =
            request.method == 'GET' &&
            request.uri.path == '/oauth/callback' &&
            q['state']?.length == 1 &&
            q['state']!.single == state &&
            q['code']?.length == 1 &&
            q['code']!.single.isNotEmpty &&
            !q.containsKey('error');
        final code = valid ? q['code']!.single : null;
        if (code == null ||
            (claimedCode == null &&
                (receipt.isCompleted || login.cancelled.isCompleted)) ||
            (claimedCode != null && claimedCode != code)) {
          unawaited(_writeCallback(request, callbackPages, status: 400));
          return;
        }
        // Claim the code before awaiting any I/O. Losing the browser response
        // cannot prevent a valid callback from reaching the application.
        callbackResponses.add(
          _writeCallback(
            request,
            callbackPages,
            status: 502,
            receipt: receipt.future,
            signup:
                (base.origin == officialCloudOrigin ||
                    base.origin == legacyOfficialCloudOrigin) &&
                q['signup']?.length == 1 &&
                q['signup']!.single == '1',
          ),
        );
        if (claimedCode == null) {
          claimedCode = code;
          result.complete(code);
        }
      });
      final authorization = base
          .resolve('/v1/auth/authorize')
          .replace(
            queryParameters: {
              'response_type': 'code',
              'client_id': 'weekglass-native',
              'redirect_uri': redirect,
              'code_challenge': challenge,
              'code_challenge_method': 'S256',
              'state': state,
              'device_id': device,
            },
          );
      onPhaseChanged?.call(CloudLoginPhase.waitingForBrowser);
      login.checkCancellation();
      final launch = Future.sync(() => _launch(authorization)).then(
        (opened) {
          if (!opened) throw CloudLoginException('无法打开浏览器，请检查默认浏览器设置。');
          return result.future;
        },
        onError: (Object _) {
          throw CloudLoginException('无法打开浏览器，请检查默认浏览器设置。');
        },
      );
      final code = await login.wait(
        Future.any<String>([result.future, launch]),
        timeout: callbackTimeout,
        timeoutMessage: '等待浏览器授权超时，请重新连接。',
      );
      login.checkCancellation();
      onPhaseChanged?.call(CloudLoginPhase.exchanging);
      login.checkCancellation();
      final grant = <String, dynamic>{
        'grant_type': 'authorization_code',
        'client_id': 'weekglass-native',
        'code': code,
        'redirect_uri': redirect,
        'code_verifier': verifier,
        'device_id': device,
      };
      final vault = _vault;
      final tokens = await login.wait(
        vault is MacCloudSessionVault
            ? vault.authorize(base.origin, info['server_id'] as String, grant)
            : _transport(
                base.resolve('/v1/auth/token'),
                'POST',
                grant,
                {},
                true,
              ),
        timeout: const Duration(seconds: 35),
        timeoutMessage: '接收授权超时，请重新连接。',
      );
      _validateTokens(tokens);
      if (tokens['server_id'] != info['server_id'] ||
          tokens['device_id'] != device) {
        throw const FormatException('登录服务器身份不匹配');
      }
      final next = {
        ...tokens,
        'origin': base.origin,
        'merge_approved': false,
        'sleep_schedule_approved': false,
      };
      onPhaseChanged?.call(CloudLoginPhase.saving);
      await _saveLogin(login, next);
      unawaited(
        _updateDeviceMetadata(base, device, next['access_token'] as String),
      );
    } finally {
      receipt.complete(login.committed);
      // Allow the claimed request to deliver its receipt without holding the
      // UI hostage if the browser closes or never reads its response.
      unawaited(_closeCallback(listener, callbackResponses));
      _login = null;
      login.finished.complete();
    }
  }

  void cancelLogin() => _login?.cancel();

  Future<void> _queueVaultWrite(Future<void> Function() write) {
    final pending = _vaultWrites.then((_) => write());
    _vaultWrites = pending.then<void>((_) {}, onError: (Object _) {});
    return pending;
  }

  Future<void> _saveLogin(
    _CloudLogin login,
    Map<String, dynamic> next,
  ) => _queueVaultWrite(() async {
    login.checkCancellation();
    final previous = _session;
    try {
      await _vault.write(jsonEncode(next));
      login.checkCancellation();
    } catch (error) {
      // The write may have completed as the user cancelled. Roll it back
      // before releasing this attempt or allowing logout to clear the vault.
      try {
        if (previous == null) {
          await _vault.clear();
        } else {
          await _vault.write(jsonEncode(previous));
        }
      } catch (_) {
        throw CloudLoginException('无法恢复本机安全存储，请检查系统凭据存储后重试。');
      }
      if (error is CloudLoginException) rethrow;
      throw CloudLoginException('无法安全保存登录，请检查系统凭据存储后重试。');
    }
    _session = next;
    _sessionGeneration++;
    _refreshing = null;
    login.committed = true;
  });

  Future<void> _writeCallback(
    HttpRequest request,
    Future<CloudAuthCallbackPages> pages, {
    required int status,
    Future<bool>? receipt,
    bool signup = false,
  }) async {
    try {
      final success = receipt != null && await receipt;
      final response = request.response;
      response.headers.set('Cache-Control', 'no-store');
      response.headers.set('Referrer-Policy', 'no-referrer');
      response.headers.set('X-Content-Type-Options', 'nosniff');
      response.headers.set('Content-Security-Policy', cloudAuthCallbackCsp);
      if (success && signup) {
        response.statusCode = HttpStatus.seeOther;
        response.headers.set(
          HttpHeaders.locationHeader,
          CloudPortalPage.plans.uri,
        );
        await response.close();
        return;
      }
      final content = await pages;
      response.headers.contentType = ContentType.html;
      response.statusCode = success ? 200 : status;
      response.write(
        success
            ? content.success
            : receipt == null
            ? content.invalid
            : content.failed,
      );
      await response.close();
    } catch (_) {
      // A disconnected browser cannot undo the application outcome.
    }
  }

  Future<void> _closeCallback(
    HttpServer? server,
    List<Future<void>> responses,
  ) async {
    try {
      if (responses.isNotEmpty) {
        await Future.wait(responses).timeout(const Duration(seconds: 2));
      }
    } catch (_) {}
    try {
      await server?.close(force: true);
    } catch (_) {}
  }

  Future<void> _updateDeviceMetadata(
    Uri base,
    String device,
    String access,
  ) async {
    final platform = _devicePlatform;
    if (platform == null) return;
    try {
      await _transport(
        base.resolve('/v1/devices/$device'),
        'PATCH',
        {
          'device_id': device,
          'display_name': platform.label,
          'platform': platform.id,
          'app_version':
              '${UpdateService.currentVersion}+${UpdateService.currentBuild}',
        },
        {'Authorization': 'Bearer $access'},
        false,
      );
    } catch (_) {
      // Optional metadata cannot delay or change login.
    }
  }

  bool _currentSession(int generation) =>
      _session != null &&
      generation == _sessionGeneration &&
      _loggingOut == null;

  void _ensureSession(int generation) {
    if (!_currentSession(generation)) {
      throw CloudApiException(401, 'not_connected', {});
    }
  }

  Future<void> approveMerge({bool includeSleepSchedule = false}) {
    final generation = _sessionGeneration;
    return _queueVaultWrite(() async {
      _ensureSession(generation);
      final next = {
        ..._session!,
        'merge_approved': true,
        if (includeSleepSchedule) 'sleep_schedule_approved': true,
      };
      await _vault.write(jsonEncode(next));
      _ensureSession(generation);
      _session = next;
    });
  }

  Future<void> approveSleepSchedule() {
    if (!mergeApproved) throw CloudLoginException('请先确认合并日程。');
    return approveMerge(includeSleepSchedule: true);
  }

  Future<Map<String, dynamic>> request(
    String method,
    String path,
    Map<String, dynamic>? body,
  ) => _request(method, path, body);

  /// The browser signs in independently. Never hand off native credentials.
  Future<bool> openPortal(CloudPortalPage page) => _launch(page.uri);

  Future<Map<String, dynamic>> _request(
    String method,
    String path,
    Map<String, dynamic>? body,
  ) async {
    final generation = _sessionGeneration;
    _ensureSession(generation);
    final session = _session!;
    if (!path.startsWith('/v1/') || path.startsWith('//')) {
      throw ArgumentError('Invalid API path');
    }
    final target = Uri.parse(session['origin'] as String).resolve(path);
    if (target.origin != session['origin']) {
      throw ArgumentError('Cross-origin API request');
    }
    final syncRequest = target.path.startsWith('/v1/sync/');
    final officialSync = syncRequest && official;
    final syncGeneration = _officialSyncGeneration;
    void ensureSyncAllowed() {
      if (syncRequest &&
          (syncTransportAllowed?.call() == false ||
              officialSync && syncGeneration != _officialSyncGeneration)) {
        throw CloudApiException(403, 'sync_inactive', {});
      }
    }

    Future<Map<String, dynamic>> send(String access) {
      ensureSyncAllowed();
      return _transport(
        target,
        method,
        body,
        {'Authorization': 'Bearer $access'},
        false,
        officialSync: officialSync,
      );
    }

    if (session['access_token'] == null && _vault is MacCloudSessionVault) {
      await _renewOnce(generation);
      _ensureSession(generation);
    }
    final access = _session!['access_token'] as String;
    try {
      return await send(access);
    } on CloudApiException catch (error) {
      if (error.status != 401) rethrow;
      _ensureSession(generation);
      ensureSyncAllowed();
      if (_session?['access_token'] == access) {
        await _renewOnce(generation);
      }
      _ensureSession(generation);
      return send(_session!['access_token'] as String);
    }
  }

  Future<String> _renewOnce(int generation) =>
      _refreshing ??= _refresh(generation).whenComplete(() {
        if (_sessionGeneration == generation) _refreshing = null;
      });

  Future<String> _refresh(int generation) async {
    final old = _session!;
    late Map<String, dynamic> tokens;
    try {
      final vault = _vault;
      tokens = vault is MacCloudSessionVault
          ? await vault.renew(old['refresh_token'] as String)
          : await _transport(
              Uri.parse(old['origin'] as String).resolve('/v1/auth/token'),
              'POST',
              {
                'grant_type': 'refresh_token',
                'client_id': 'weekglass-native',
                'refresh_token': old['refresh_token'],
                'device_id': old['device_id'],
              },
              {},
              true,
            );
    } on CloudApiException catch (error) {
      if (error.code == 'invalid_grant' || error.status == 401) {
        throw CloudApiException(401, 'session_expired', {});
      }
      rethrow;
    }
    _validateTokens(tokens);
    for (final key in [
      'server_id',
      'account_id',
      'device_id',
      'dataset_id',
      'sync_epoch',
    ]) {
      if (tokens[key] != old[key]) {
        throw const FormatException('登录身份发生变化，请重新连接');
      }
    }
    await _queueVaultWrite(() async {
      if (!_currentSession(generation)) return;
      final next = {
        ..._session!,
        ...tokens,
        'merge_approved': mergeApproved,
        'sleep_schedule_approved': sleepScheduleApproved,
      };
      await _vault.write(jsonEncode(next));
      if (_currentSession(generation)) _session = next;
    });
    // Logout can revoke the freshly rotated token even when the old session
    // was invalidated before its credentials could be committed locally.
    return tokens['refresh_token'] as String;
  }

  Future<void> logout() =>
      _loggingOut ??= _logout().whenComplete(() => _loggingOut = null);

  Future<void> _logout() async {
    _sessionGeneration++;
    closeOfficialSyncTransport();
    final login = _login;
    login?.cancel();
    await login?.finished.future;
    final session = _session;
    final refreshing = _refreshing;
    _refreshing = null;
    String? rotatedToken;
    if (refreshing != null) {
      try {
        rotatedToken = await refreshing;
      } catch (_) {}
    }
    final latest = _session ?? session;
    if (latest != null) {
      try {
        final handle = rotatedToken ?? latest['refresh_token'] as String;
        final vault = _vault;
        if (vault is MacCloudSessionVault) {
          await vault.revoke(handle);
        } else {
          await _transport(
            Uri.parse(latest['origin'] as String).resolve('/v1/auth/revoke'),
            'POST',
            {'refresh_token': handle, 'device_id': latest['device_id']},
            {},
            false,
          );
        }
      } catch (_) {
        // Offline logout always clears local credentials; server tokens expire.
      }
    }
    await _queueVaultWrite(() async {
      await _vault.clear();
      _session = null;
    });
  }
}
