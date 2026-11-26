import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weekglass/features/cloud/cloud_auth_service.dart';

const _origin = 'https://weekglass-smoke.invalid';

/// Run native loopback and Keychain operations without any external account.
Future<void> createMacosCloudFixture(String runId) async {
  const code = 'local-test-code';
  const serverId = '11111111-1111-4111-8111-111111111111';
  final browser = Completer<Uri>();
  final metadata = Completer<Map<String, dynamic>>();
  final vault = _FixtureVault(runId);
  final auth = CloudAuthService(
    vault: vault,
    callbackTimeout: const Duration(seconds: 15),
    browserLauncher: (uri) async {
      browser.complete(uri);
      return true;
    },
    transport: (uri, method, body, _, _) async {
      expect(uri.origin, _origin);
      if (method == 'GET' && uri.path == '/v1/server-info') {
        return {
          'protocol_version': '1',
          'server_id': serverId,
          'authorization_endpoint': '$_origin/v1/auth/authorize',
          'token_endpoint': '$_origin/v1/auth/token',
        };
      }
      if (method == 'POST' && uri.path == '/v1/auth/token') {
        expect(body!['code'], code);
        return {
          'token_type': 'Bearer',
          'access_token': '${'a' * 40}-fixture',
          'refresh_token': '${'r' * 40}-fixture',
          'expires_in': 900,
          'refresh_expires_in': 2592000,
          'server_id': serverId,
          'account_id': '22222222-2222-4222-8222-222222222222',
          'device_id': body['device_id'],
          'dataset_id': '44444444-4444-4444-8444-444444444444',
          'sync_epoch': '55555555-5555-4555-8555-555555555555',
        };
      }
      if (method == 'PATCH' && uri.path.startsWith('/v1/devices/')) {
        metadata.complete(body!);
        return {};
      }
      throw StateError('Unexpected fixture request: $method ${uri.path}');
    },
  );

  final http = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  http.findProxy = (_) => 'DIRECT';
  Future<void>? login;
  var readyForRelaunch = false;
  try {
    expect(await vault.read(), isNull);
    // Link the two futures so an early app failure surfaces before the browser
    // receipt deadline, and the pending login is always handled on cleanup.
    login = auth.login(_origin);
    final authorization = await Future.any<Uri>([
      browser.future,
      login.then((_) => browser.future),
    ]).timeout(const Duration(seconds: 8));
    final callback = Uri.parse(authorization.queryParameters['redirect_uri']!);
    expect(callback.host, '127.0.0.1');
    expect(callback.scheme, 'http');
    final request = await http.getUrl(
      callback.replace(
        queryParameters: {
          'state': authorization.queryParameters['state']!,
          'code': code,
        },
      ),
    );
    request.followRedirects = false;
    final receipt = await request.close().timeout(const Duration(seconds: 18));
    expect(receipt.statusCode, HttpStatus.ok);
    expect(receipt.headers.value('Cache-Control'), 'no-store');
    final html = await utf8.decoder.bind(receipt).join();
    expect(html, isNot(contains(code)));
    await login;
    expect(auth.connected, isTrue);
    expect(auth.mergeApproved, isFalse);
    final device = await metadata.future.timeout(const Duration(seconds: 8));
    expect(device['display_name'], 'WeekGlass macOS');
    expect(device['platform'], 'macos');
    expect(device['device_id'], authorization.queryParameters['device_id']);
    expect(device['app_version'], matches(r'^\d+\.\d+\.\d+\+\d+$'));
    expect(await vault.read(), isNotNull);
    readyForRelaunch = true;
    stdout.writeln(
      'Local Cloud OAuth receipt and isolated macOS Keychain write verified.',
    );
  } finally {
    auth.cancelLogin();
    await login?.then<void>((_) {}, onError: (Object _) {});
    http.close(force: true);
    if (!readyForRelaunch) await vault.clear();
  }
}

Future<void> restoreMacosCloudFixture(String runId) async {
  final stored = CloudAuthService(vault: _FixtureVault(runId));
  await stored.restore();
  expect(stored.origin, _origin);
  expect(stored.connected, isTrue);
  expect(stored.mergeApproved, isFalse);
  stdout.writeln(
    'Isolated macOS Keychain session restored in the new process.',
  );
}

Future<void> clearMacosCloudFixture(String runId) async {
  final vault = _FixtureVault(runId);
  await vault.clear();
  expect(await vault.read(), isNull);
}

class _FixtureVault implements CloudTokenVault {
  _FixtureVault(String runId)
    : _storage = FlutterSecureStorage(
        mOptions: MacOsOptions(
          accountName: 'weekglass.macos.smoke.$runId',
          usesDataProtectionKeychain: false,
        ),
      );

  final FlutterSecureStorage _storage;
  static const _key = 'fixture';

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);

  @override
  Future<void> clear() => _storage.delete(key: _key);
}
