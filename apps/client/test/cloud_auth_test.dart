import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weekglass/features/cloud/cloud_auth_callback_page.dart';
import 'package:weekglass/features/cloud/cloud_auth_service.dart';
import 'package:weekglass/features/cloud/cloud_connection.dart';
import 'package:weekglass_data/weekglass_data.dart';

class MemoryVault implements CloudTokenVault {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async {
    this.value = value;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

Map<String, dynamic> tokens({String? device, String suffix = 'old'}) => {
  'token_type': 'Bearer',
  'access_token': '${'a' * 40}-$suffix',
  'refresh_token': '${'r' * 40}-$suffix',
  'expires_in': 900,
  'refresh_expires_in': 2592000,
  'server_id': '11111111-1111-4111-8111-111111111111',
  'account_id': '22222222-2222-4222-8222-222222222222',
  'device_id': device ?? '33333333-3333-4333-8333-333333333333',
  'dataset_id': '44444444-4444-4444-8444-444444444444',
  'sync_epoch': '55555555-5555-4555-8555-555555555555',
};

MemoryVault saved() => MemoryVault()
  ..value = jsonEncode({
    ...tokens(),
    'origin': officialCloudOrigin,
    'merge_approved': true,
  });

Map<String, dynamic> _discovery() => {
  'protocol_version': '1',
  'server_id': tokens()['server_id'],
  'authorization_endpoint': '$officialCloudOrigin/v1/auth/authorize',
  'token_endpoint': '$officialCloudOrigin/v1/auth/token',
};

Map<String, dynamic> _discoveryAt(String origin) => {
  ..._discovery(),
  'authorization_endpoint': '$origin/v1/auth/authorize',
  'token_endpoint': '$origin/v1/auth/token',
};

Uri _callback(Uri authorization) =>
    Uri.parse(authorization.queryParameters['redirect_uri']!).replace(
      queryParameters: {
        'state': authorization.queryParameters['state']!,
        'code': 'test-callback-code',
      },
    );

Future<({int status, String html})> _getReceipt(
  HttpClient http,
  Uri callback,
) async {
  final request = await http.getUrl(callback);
  final response = await request.close();
  return (
    status: response.statusCode,
    html: await utf8.decoder.bind(response).join(),
  );
}

class _HeldVault extends MemoryVault {
  final writing = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> write(String value) async {
    if (!writing.isCompleted) writing.complete();
    await release.future;
    await super.write(value);
  }
}

class _LoopbackCloudHttp extends HttpOverrides {
  _LoopbackCloudHttp(this.port);
  final int port;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _LoopbackCloudClient(super.createHttpClient(context), port);
}

class _LoopbackCloudClient implements HttpClient {
  _LoopbackCloudClient(this.client, this.port);
  final HttpClient client;
  final int port;

  @override
  set connectionTimeout(Duration? value) => client.connectionTimeout = value;
  @override
  set idleTimeout(Duration value) => client.idleTimeout = value;
  @override
  set maxConnectionsPerHost(int? value) => client.maxConnectionsPerHost = value;
  @override
  void close({bool force = false}) => client.close(force: force);
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) => client.openUrl(
    method,
    url.replace(scheme: 'http', host: '127.0.0.1', port: port),
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // This non-widget suite exercises a real loopback callback listener.
  HttpOverrides.global = null;
  setUp(
    () => SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty(),
  );

  test('only HTTPS origins accepted; credentials and path are rejected', () {
    expect(
      validateCloudOrigin('https://cloud.viliana.cn:8443/').origin,
      legacyOfficialCloudOrigin,
    );
    expect(
      validateCloudOrigin('https://cloud.viliana.cn/').origin,
      officialCloudOrigin,
    );
    for (final invalid in [
      'http://cloud.viliana.cn',
      'file:///secret',
      'https://user:password@cloud.viliana.cn',
      'https://cloud.viliana.cn/v1',
      'https://cloud.viliana.cn?token=x',
      'https://cloud.viliana.cn#x',
    ]) {
      expect(() => validateCloudOrigin(invalid), throwsArgumentError);
    }
  });

  test('legacy official session keeps its origin and merge approval', () async {
    final vault = MemoryVault()
      ..value = jsonEncode({
        ...tokens(),
        'origin': legacyOfficialCloudOrigin,
        'merge_approved': true,
      });
    final auth = CloudAuthService(vault: vault);
    await auth.restore();
    expect(auth.official, isTrue);
    expect(auth.origin, legacyOfficialCloudOrigin);
    expect(auth.mergeApproved, isTrue);
  });

  for (final (origin, flag, succeeds, expectedStatus) in [
    (officialCloudOrigin, '1', true, 303),
    (legacyOfficialCloudOrigin, '1', true, 303),
    (officialCloudOrigin, '1', false, 502),
    (officialCloudOrigin, '2', true, 200),
    ('https://self-host.test', '1', true, 200),
  ]) {
    test(
      'signup callback handoff is limited to durable official signup: $origin $flag $succeeds',
      () async {
        final browser = Completer<Uri>();
        final vault = MemoryVault();
        final auth = CloudAuthService(
          vault: vault,
          browserLauncher: (uri) async {
            browser.complete(uri);
            return true;
          },
          transport: (uri, method, body, _, _) async {
            if (uri.path.endsWith('/server-info')) return _discoveryAt(origin);
            if (method == 'PATCH') return {};
            if (!succeeds) throw CloudApiException(401, 'invalid_grant', {});
            return tokens(device: body!['device_id'] as String);
          },
        );
        final http = HttpClient();
        addTearDown(() => http.close(force: true));
        final login = auth.login(origin);
        final completed = succeeds
            ? login
            : expectLater(login, throwsA(isA<CloudApiException>()));
        final callback = _callback(await browser.future);
        final request = await http.getUrl(
          callback.replace(
            queryParameters: {
              ...callback.queryParameters,
              'signup': flag,
              'next': 'https://evil.example',
            },
          ),
        );
        request.followRedirects = false;
        final response = await request.close();
        expect(response.statusCode, expectedStatus);
        expect(
          response.headers.value('Location'),
          expectedStatus == 303 ? '$officialCloudOrigin/account#plans' : isNull,
        );
        expect(response.headers.value('Cache-Control'), 'no-store');
        expect(response.headers.value('Referrer-Policy'), 'no-referrer');
        final html = await utf8.decoder.bind(response).join();
        expect(html, isNot(contains('test-callback-code')));
        if (!succeeds) expect(html, contains('连接未完成'));
        await completed;
        expect(auth.connected, succeeds);
        expect(vault.value, succeeds ? isNotNull : isNull);
        expect(auth.mergeApproved, isFalse);
      },
    );
  }

  test(
    'a token renewal cannot retry a sync request after the service stops',
    () async {
      final rotating = Completer<void>();
      final rotation = Completer<Map<String, dynamic>>();
      var requests = 0;
      final auth = CloudAuthService(
        vault: saved(),
        transport: (uri, _, _, _, _) {
          if (uri.path == '/v1/auth/token') {
            rotating.complete();
            return rotation.future;
          }
          requests++;
          throw CloudApiException(401, 'expired', {});
        },
      )..syncTransportAllowed = () => true;
      await auth.restore();
      final request = expectLater(
        auth.request('GET', '/v1/sync/changes', null),
        throwsA(
          isA<CloudApiException>().having(
            (e) => e.code,
            'code',
            'sync_inactive',
          ),
        ),
      );
      await rotating.future;
      // Even if a new service period is already active, this request must
      // not cross the boundary when the old token renewal finishes.
      auth.closeOfficialSyncTransport();
      rotation.complete(tokens(suffix: 'new'));
      await request;
      expect(requests, 1);
    },
  );

  test('pausing official sync aborts a real stream without closing account requests', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final streaming = Completer<void>();
    final metadataRequested = Completer<void>();
    final releaseMetadata = Completer<void>();
    var holdFirstStream = true;
    server.listen((request) async {
      final response = request.response;
      response.headers.contentType = ContentType.json;
      if (request.uri.path == '/v1/sync/changes' && holdFirstStream) {
        holdFirstStream = false;
        response.bufferOutput = false;
        response.write('{"changes":[');
        await response.flush();
        streaming.complete();
        return;
      }
      if (request.uri.path == '/v1/me/account') {
        metadataRequested.complete();
        await releaseMetadata.future;
        response.write('{"username":"reader"}');
      } else {
        response.write('{"changes":[]}');
      }
      await response.close();
    });

    await HttpOverrides.runWithHttpOverrides(() async {
      var allowed = true;
      final auth = CloudAuthService(vault: saved())
        ..syncTransportAllowed = () => allowed;
      addTearDown(auth.closeOfficialSyncTransport);
      await auth.restore();
      final interrupted = expectLater(
        auth.request('GET', '/v1/sync/changes?wait_seconds=25', null),
        throwsA(anyOf(isA<HttpException>(), isA<SocketException>())),
      );
      final metadata = auth.request('GET', '/v1/me/account', null);
      await Future.wait([streaming.future, metadataRequested.future]);
      allowed = false;
      auth.closeOfficialSyncTransport();
      releaseMetadata.complete();
      await interrupted.timeout(const Duration(seconds: 3));
      expect(await metadata, {'username': 'reader'});
      await expectLater(
        auth.request('GET', '/v1/sync/changes', null),
        throwsA(
          isA<CloudApiException>().having(
            (e) => e.code,
            'code',
            'sync_inactive',
          ),
        ),
      );
      allowed = true;
      expect(await auth.request('GET', '/v1/sync/changes', null), {
        'changes': [],
      });
    }, _LoopbackCloudHttp(server.port));
  });

  test(
    'concurrent 401s share one rotating refresh and persist before retry',
    () async {
      final vault = saved();
      var rotations = 0;
      var retries = 0;
      final auth = CloudAuthService(
        vault: vault,
        transport: (uri, method, body, headers, form) async {
          if (uri.path == '/v1/auth/token') {
            rotations++;
            await Future<void>.delayed(const Duration(milliseconds: 20));
            expect(body!['refresh_token'], tokens()['refresh_token']);
            return tokens(suffix: 'new');
          }
          if (headers['Authorization']!.endsWith('-old')) {
            throw CloudApiException(401, 'expired', {});
          }
          expect(
            jsonDecode(vault.value!)['refresh_token'],
            tokens(suffix: 'new')['refresh_token'],
          );
          retries++;
          return {'ok': true};
        },
      );
      await auth.restore();
      await Future.wait([
        auth.request('GET', '/v1/me/entitlements', null),
        auth.request('GET', '/v1/devices', null),
      ]);
      expect(rotations, 1);
      expect(retries, 2);
    },
  );

  test(
    'receipt waits for vault, rejects duplicates, and skips slow metadata',
    () async {
      final vault = _HeldVault();
      final browser = Completer<Uri>();
      final metadata = Completer<Map<String, dynamic>>();
      final metadataStarted = Completer<void>();
      final phases = <CloudLoginPhase>[];
      var exchanges = 0;
      final auth = CloudAuthService(
        vault: vault,
        devicePlatform: CloudDevicePlatform.macOS,
        browserLauncher: (uri) async {
          browser.complete(uri);
          return true;
        },
        transport: (uri, method, body, _, _) async {
          if (uri.path.endsWith('/server-info')) return _discovery();
          if (method == 'PATCH') {
            expect(body!['platform'], 'macos');
            expect(body['display_name'], 'WeekGlass macOS');
            metadataStarted.complete();
            return metadata.future;
          }
          exchanges++;
          return tokens(device: body!['device_id'] as String);
        },
      );
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      final login = auth.login(officialCloudOrigin, onPhaseChanged: phases.add);
      final callback = _callback(await browser.future);
      final first = _getReceipt(http, callback);
      var receiptSent = false;
      unawaited(first.then<void>((_) => receiptSent = true));
      await vault.writing.future;
      expect(receiptSent, isFalse);
      expect(auth.connected, isFalse);
      expect(vault.value, isNull);
      final duplicate = _getReceipt(http, callback);
      final differentCode = await _getReceipt(
        http,
        callback.replace(
          queryParameters: {
            ...callback.queryParameters,
            'code': 'different-code',
          },
        ),
      );
      expect(differentCode.status, 400);
      expect(differentCode.html, contains('连接未完成'));
      expect(exchanges, 1);

      vault.release.complete();
      await login.timeout(const Duration(seconds: 2));
      await metadataStarted.future;
      expect(metadata.isCompleted, isFalse);
      expect(auth.connected, isTrue);
      expect(auth.mergeApproved, isFalse);
      final receipt = await first;
      expect(receipt.status, 200);
      expect(receipt.html, contains('连接已完成'));
      expect(await duplicate, receipt);
      expect(receipt.html, isNot(contains('test-callback-code')));
      expect(phases, CloudLoginPhase.values);
      metadata.complete({});
    },
  );

  test(
    'token error gives a failure receipt without writing or leaking details',
    () async {
      final vault = MemoryVault();
      final browser = Completer<Uri>();
      final auth = CloudAuthService(
        vault: vault,
        browserLauncher: (uri) async {
          browser.complete(uri);
          return true;
        },
        transport: (uri, _, _, _, _) async {
          if (uri.path.endsWith('/server-info')) return _discovery();
          throw CloudApiException(401, 'invalid_grant', {
            'detail': 'private-detail',
          });
        },
      );
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      final failed = expectLater(
        auth.login(officialCloudOrigin),
        throwsA(isA<CloudApiException>()),
      );
      final receipt = await _getReceipt(http, _callback(await browser.future));
      await failed;
      expect(receipt.status, 502);
      expect(receipt.html, contains('连接未完成'));
      expect(receipt.html, isNot(contains('private-detail')));
      expect(auth.connected, isFalse);
      expect(vault.value, isNull);
    },
  );

  test(
    'cancellation during exchange ignores a late successful response',
    () async {
      final vault = MemoryVault();
      final browser = Completer<Uri>();
      final exchanging = Completer<String>();
      final exchange = Completer<Map<String, dynamic>>();
      final auth = CloudAuthService(
        vault: vault,
        browserLauncher: (uri) async {
          browser.complete(uri);
          return true;
        },
        transport: (uri, _, body, _, _) async {
          if (uri.path.endsWith('/server-info')) return _discovery();
          exchanging.complete(body!['device_id'] as String);
          return exchange.future;
        },
      );
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      final failed = expectLater(
        auth.login(officialCloudOrigin),
        throwsStateError,
      );
      final receipt = _getReceipt(http, _callback(await browser.future));
      final device = await exchanging.future;
      auth.cancelLogin();
      await failed.timeout(const Duration(seconds: 2));
      expect((await receipt).status, 502);
      exchange.complete(tokens(device: device));
      await Future<void>.delayed(Duration.zero);
      expect(auth.connected, isFalse);
      expect(vault.value, isNull);
    },
  );

  test('closing login during vault write rolls the new session back', () async {
    final vault = _HeldVault();
    final browser = Completer<Uri>();
    final auth = CloudAuthService(
      vault: vault,
      browserLauncher: (uri) async {
        browser.complete(uri);
        return true;
      },
      transport: (uri, _, body, _, _) async => uri.path.endsWith('/server-info')
          ? _discovery()
          : tokens(device: body!['device_id'] as String),
    );
    final http = HttpClient();
    addTearDown(() => http.close(force: true));
    final failed = expectLater(
      auth.login(officialCloudOrigin),
      throwsStateError,
    );
    final receipt = _getReceipt(http, _callback(await browser.future));
    await vault.writing.future;
    auth.cancelLogin();
    vault.release.complete();
    await failed;
    expect((await receipt).status, 502);
    expect(auth.connected, isFalse);
    expect(vault.value, isNull);
  });

  test(
    'closing the browser response does not lose the accepted code',
    () async {
      final vault = _HeldVault();
      final browser = Completer<Uri>();
      final auth = CloudAuthService(
        vault: vault,
        browserLauncher: (uri) async {
          browser.complete(uri);
          return true;
        },
        transport: (uri, method, body, _, _) async {
          if (uri.path.endsWith('/server-info')) return _discovery();
          if (method == 'PATCH') return {};
          return tokens(device: body!['device_id'] as String);
        },
      );
      final login = auth.login(officialCloudOrigin);
      final callback = _callback(await browser.future);
      final socket = await Socket.connect(callback.host, callback.port);
      socket.write(
        'GET ${callback.path}?${callback.query} HTTP/1.1\r\n'
        'Host: ${callback.authority}\r\nConnection: close\r\n\r\n',
      );
      await socket.flush();
      await vault.writing.future;
      socket.destroy();
      vault.release.complete();
      await login.timeout(const Duration(seconds: 2));
      expect(auth.connected, isTrue);
      expect(vault.value, isNotNull);
    },
  );

  test('timeout also ends login if the browser launch never returns', () async {
    final browser = Completer<bool>();
    final auth = CloudAuthService(
      vault: MemoryVault(),
      callbackTimeout: const Duration(milliseconds: 20),
      browserLauncher: (_) => browser.future,
      transport: (_, _, _, _, _) async => _discovery(),
    );
    await expectLater(
      auth.login(officialCloudOrigin),
      throwsA(
        isA<CloudLoginException>().having(
          (e) => e.message,
          'message',
          contains('授权超时'),
        ),
      ),
    );
    expect(auth.connected, isFalse);
    browser.complete(false);
  });

  test(
    'connection is visible before account reads and drops stale responses',
    () async {
      sqfliteFfiInit();
      final vault = MemoryVault();
      final browser = Completer<Uri>();
      final entitlements = Completer<Map<String, dynamic>>();
      final accountRequested = Completer<void>();
      final auth = CloudAuthService(
        vault: vault,
        browserLauncher: (uri) async {
          browser.complete(uri);
          return true;
        },
        transport: (uri, _, body, _, _) async {
          switch (uri.path) {
            case '/v1/server-info':
              return _discovery();
            case '/v1/auth/token':
              return tokens(device: body!['device_id'] as String);
            case '/v1/me/entitlements':
              accountRequested.complete();
              return entitlements.future;
            default:
              return {};
          }
        },
      );
      final repository = SqliteEventRepository(
        factory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );
      final cloud = CloudConnection(repository: repository, auth: auth);
      final http = HttpClient();
      addTearDown(() async {
        http.close(force: true);
        cloud.dispose();
        await repository.close();
      });
      final login = cloud.login(officialCloudOrigin);
      final receipt = _getReceipt(http, _callback(await browser.future));
      await login.timeout(const Duration(seconds: 2));
      await accountRequested.future;
      expect(cloud.connected, isTrue);
      expect(cloud.working, isFalse);
      expect(cloud.entitlements, isNull);
      expect(cloud.engine.connected, isFalse);
      expect((await receipt).status, 200);
      await cloud.disconnect();
      entitlements.complete({
        'status': 'active',
        'sync_read': true,
        'sync_write': true,
      });
      await Future<void>.delayed(Duration.zero);
      expect(cloud.connected, isFalse);
      expect(cloud.entitlements, isNull);
      expect(cloud.accountLoading, isFalse);
    },
  );

  test('a 401 arriving during logout cannot start a refresh', () async {
    final vault = saved();
    final response = Completer<Map<String, dynamic>>();
    final revoke = Completer<Map<String, dynamic>>();
    final revoking = Completer<void>();
    var rotations = 0;
    final auth = CloudAuthService(
      vault: vault,
      transport: (uri, _, _, _, _) {
        switch (uri.path) {
          case '/v1/auth/revoke':
            revoking.complete();
            return revoke.future;
          case '/v1/auth/token':
            rotations++;
            return Future.value(tokens(suffix: 'rotated'));
          default:
            return response.future;
        }
      },
    );
    await auth.restore();
    final stale = expectLater(
      auth.request('GET', '/v1/me/entitlements', null),
      throwsA(isA<CloudApiException>()),
    );
    final logout = auth.logout();
    await revoking.future;
    response.completeError(CloudApiException(401, 'expired', {}));
    await stale;
    expect(rotations, 0);
    revoke.complete({});
    await logout;
    expect(vault.value, isNull);
    expect(auth.connected, isFalse);
  });

  test(
    'logout revokes an in-flight rotation without saving it locally',
    () async {
      final vault = _HeldVault()..value = saved().value;
      vault.release.complete();
      final rotating = Completer<void>();
      final rotation = Completer<Map<String, dynamic>>();
      final rotated = tokens(suffix: 'rotated');
      String? revoked;
      final auth = CloudAuthService(
        vault: vault,
        transport: (uri, _, body, _, _) async {
          switch (uri.path) {
            case '/v1/auth/token':
              rotating.complete();
              return rotation.future;
            case '/v1/auth/revoke':
              revoked = body!['refresh_token'] as String;
              return {};
            default:
              throw CloudApiException(401, 'expired', {});
          }
        },
      );
      await auth.restore();
      final request = expectLater(
        auth.request('GET', '/v1/me/entitlements', null),
        throwsA(isA<CloudApiException>()),
      );
      await rotating.future;
      final logout = auth.logout();
      rotation.complete(rotated);
      await Future.wait([request, logout]);
      expect(revoked, rotated['refresh_token']);
      expect(vault.writing.isCompleted, isFalse);
      expect(vault.value, isNull);
      expect(auth.connected, isFalse);
    },
  );

  test('a response from a prior session never retries with a same-origin new login', () async {
    final vault = saved();
    final browser = Completer<Uri>();
    final oldResponse = Completer<Map<String, dynamic>>();
    var oldRequests = 0;
    final auth = CloudAuthService(
      vault: vault,
      browserLauncher: (uri) async {
        browser.complete(uri);
        return true;
      },
      transport: (uri, method, body, _, _) async {
        if (uri.path.endsWith('/server-info')) return _discovery();
        if (uri.path.endsWith('/token')) {
          return tokens(device: body!['device_id'] as String, suffix: 'new');
        }
        if (uri.path.endsWith('/revoke') || method == 'PATCH') return {};
        oldRequests++;
        return oldResponse.future;
      },
    );
    await auth.restore();
    final rejected = expectLater(
      auth.request('GET', '/v1/me/entitlements', null),
      throwsA(isA<CloudApiException>()),
    );
    await auth.logout();
    final http = HttpClient();
    addTearDown(() => http.close(force: true));
    final login = auth.login(officialCloudOrigin);
    expect(
      (await _getReceipt(http, _callback(await browser.future))).status,
      200,
    );
    await login;
    oldResponse.completeError(CloudApiException(401, 'expired', {}));
    await rejected;
    expect(oldRequests, 1);
    expect(
      jsonDecode(vault.value!)['access_token'],
      tokens(suffix: 'new')['access_token'],
    );
  });

  test(
    'identity change during refresh is rejected without replacing session',
    () async {
      final vault = saved();
      final original = vault.value;
      final auth = CloudAuthService(
        vault: vault,
        transport: (uri, method, body, headers, form) async {
          if (uri.path.endsWith('/token')) {
            return {
              ...tokens(suffix: 'bad'),
              'account_id': '66666666-6666-4666-8666-666666666666',
            };
          }
          throw CloudApiException(401, 'expired', {});
        },
      );
      await auth.restore();
      await expectLater(
        auth.request('GET', '/v1/devices', null),
        throwsFormatException,
      );
      expect(vault.value, original);
    },
  );

  test('offline logout clears only the stored cloud session', () async {
    final vault = saved();
    final auth = CloudAuthService(
      vault: vault,
      transport: (uri, method, body, headers, form) async {
        throw const SocketException('offline');
      },
    );
    await auth.restore();
    await auth.logout();
    expect(vault.value, isNull);
    expect(auth.connected, isFalse);
  });

  test('foreign API origins cannot receive bearer credentials', () async {
    var calls = 0;
    final auth = CloudAuthService(
      vault: saved(),
      transport: (uri, method, body, headers, form) async {
        calls++;
        return {};
      },
    );
    await auth.restore();
    await expectLater(
      auth.request('GET', '//evil.example/v1', null),
      throwsArgumentError,
    );
    await expectLater(
      auth.request('GET', 'https://evil.example/v1', null),
      throwsArgumentError,
    );
    expect(calls, 0);
  });

  test(
    'PKCE login ignores forged callback state and requires merge consent',
    () async {
      final vault = MemoryVault();
      String? expectedDevice;
      String? challenge;
      final browserReceipt = Completer<void>();
      final auth = CloudAuthService(
        vault: vault,
        browserLauncher: (uri) async {
          expect(uri.origin, officialCloudOrigin);
          expect(uri.queryParameters['code_challenge_method'], 'S256');
          challenge = uri.queryParameters['code_challenge'];
          expectedDevice = uri.queryParameters['device_id'];
          final redirect = Uri.parse(uri.queryParameters['redirect_uri']!);
          final http = HttpClient();
          try {
            final wrong = await http.getUrl(
              redirect.replace(
                queryParameters: {'state': 'forged', 'code': 'bad'},
              ),
            );
            final response = await wrong.close();
            expect(response.statusCode, 400);
            expect(
              response.headers.value('Content-Security-Policy'),
              cloudAuthCallbackCsp,
            );
            expect(response.headers.value('Cache-Control'), 'no-store');
            final rejectedPage = await utf8.decoder.bind(response).join();
            expect(rejectedPage, contains('连接未完成'));
            expect(rejectedPage, isNot(contains('forged')));
            final good = await http.getUrl(
              redirect.replace(
                queryParameters: {
                  'state': uri.queryParameters['state']!,
                  'code': 'valid-code',
                },
              ),
            );
            final accepted = await good.close();
            expect(accepted.statusCode, 200);
            expect(
              accepted.headers.value('Content-Security-Policy'),
              cloudAuthCallbackCsp,
            );
            expect(accepted.headers.value('Referrer-Policy'), 'no-referrer');
            expect(accepted.headers.value('X-Content-Type-Options'), 'nosniff');
            final acceptedPage = await utf8.decoder.bind(accepted).join();
            expect(acceptedPage, contains('连接已完成'));
            expect(acceptedPage, contains('返回 WeekGlass 继续'));
            expect(acceptedPage, isNot(contains('valid-code')));
            expect(
              acceptedPage,
              isNot(contains(uri.queryParameters['state']!)),
            );
            browserReceipt.complete();
          } catch (error, stack) {
            browserReceipt.completeError(error, stack);
            rethrow;
          } finally {
            http.close();
          }
          return true;
        },
        transport: (uri, method, body, headers, form) async {
          if (uri.path.endsWith('/server-info')) {
            return {
              'protocol_version': '1',
              'server_id': tokens()['server_id'],
              'authorization_endpoint':
                  '$officialCloudOrigin/v1/auth/authorize',
              'token_endpoint': '$officialCloudOrigin/v1/auth/token',
            };
          }
          if (uri.path.endsWith('/token')) {
            expect(body!['code'], 'valid-code');
            expect(body['code_verifier'], isNot(challenge));
            expect(form, isTrue);
            return tokens(device: expectedDevice);
          }
          if (method == 'PATCH') {
            expect(body!['device_id'], expectedDevice);
            expect(body['display_name'], isNotEmpty);
            expect(body['platform'], anyOf('windows', 'android'));
            expect(body['app_version'], matches(r'^\d+\.\d+\.\d+\+\d+$'));
          }
          return {};
        },
      );
      await Future.wait([
        auth.login(officialCloudOrigin),
        browserReceipt.future,
      ]);
      expect(auth.connected, isTrue);
      expect(auth.mergeApproved, isFalse);
      expect(jsonDecode(vault.value!)['merge_approved'], isFalse);
      await auth.approveMerge();
      expect(auth.mergeApproved, isTrue);
    },
  );

  test(
    'invalid callback does not reveal query values or complete login',
    () async {
      final vault = MemoryVault();
      final rejected = Completer<void>();
      var tokenRequests = 0;
      const secretCode = '<script>privateCallbackCode()</script>';
      const secretState = 'private-forged-state';
      final auth = CloudAuthService(
        vault: vault,
        browserLauncher: (authorization) async {
          final callback = Uri.parse(
            authorization.queryParameters['redirect_uri']!,
          );
          final http = HttpClient();
          try {
            final request = await http.getUrl(
              callback.replace(
                queryParameters: {
                  'state': secretState,
                  'code': secretCode,
                  'error_description': 'private-server-diagnostic',
                },
              ),
            );
            final response = await request.close();
            expect(response.statusCode, 400);
            final html = await utf8.decoder.bind(response).join();
            expect(html, contains('连接未完成'));
            for (final value in [
              secretCode,
              secretState,
              'private-server-diagnostic',
              authorization.queryParameters['state']!,
            ]) {
              expect(html, isNot(contains(value)));
              expect(html, isNot(contains(const HtmlEscape().convert(value))));
            }
            expect(html, isNot(contains('<script')));
          } finally {
            http.close();
            if (!rejected.isCompleted) rejected.complete();
          }
          return true;
        },
        transport: (uri, method, body, headers, form) async {
          if (uri.path == '/v1/server-info') {
            return {
              'protocol_version': '1',
              'server_id': tokens()['server_id'],
              'authorization_endpoint':
                  '$officialCloudOrigin/v1/auth/authorize',
              'token_endpoint': '$officialCloudOrigin/v1/auth/token',
            };
          }
          tokenRequests++;
          return tokens();
        },
      );
      final login = auth.login(officialCloudOrigin);
      var loginCompleted = false;
      unawaited(
        login.then<void>((_) {
          loginCompleted = true;
        }, onError: (Object _) {}),
      );
      await rejected.future;
      expect(loginCompleted, isFalse);
      expect(tokenRequests, 0);
      expect(vault.value, isNull);
      final cancelled = expectLater(login, throwsStateError);
      auth.cancelLogin();
      await cancelled;
      expect(tokenRequests, 0);
      expect(auth.connected, isFalse);
    },
  );

  test('rejected refresh reports an expired login and preserves offline session data', () async {
    final vault = saved();
    final auth = CloudAuthService(
      vault: vault,
      transport: (uri, method, body, headers, form) async {
        if (uri.path.endsWith('/token')) {
          throw CloudApiException(400, 'invalid_grant', {});
        }
        throw CloudApiException(401, 'unauthenticated', {});
      },
    );
    await auth.restore();
    await expectLater(
      auth.request('GET', '/v1/me/account', null),
      throwsA(isA<CloudApiException>().having((e) => e.status, 'status', 401)),
    );
    expect(auth.mergeApproved, isTrue);
    expect(vault.value, isNotNull);
  });
}
