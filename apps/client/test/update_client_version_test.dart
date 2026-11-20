import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weekglass/features/updates/android_update_bridge.dart';
import 'package:weekglass/features/updates/update_client_version.dart';
import 'package:weekglass/features/updates/update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late HttpServer server;
  late Directory root;
  late UpdateService service;
  var version = '0.22.4';
  var build = 53;
  var failInfo = false;
  final requests = <Map<String, String?>>[];
  final paths = <String>[];
  var responseStatus = 200;
  var body = 'signed-channel-placeholder';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('weekglass-version-header-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    version = '0.22.4';
    build = 53;
    failInfo = false;
    responseStatus = 200;
    body = 'signed-channel-placeholder';
    requests.clear();
    paths.clear();
    server.listen((request) async {
      paths.add(request.uri.path);
      requests.add({
        'version': request.headers.value('X-WeekGlass-Version'),
        'build': request.headers.value('X-WeekGlass-Build'),
        'etag': request.headers.value('If-None-Match'),
        'authorization': request.headers.value('Authorization'),
        'cookie': request.headers.value('Cookie'),
      });
      request.response.statusCode = responseStatus;
      request.response.headers.set('ETag', '"test-release"');
      if (responseStatus == 200) request.response.write(body);
      await request.response.close();
    });
    messenger.setMockMethodCallHandler(AndroidUpdateBridge.channel, (
      call,
    ) async {
      expect(call.method, 'deviceInfo');
      if (failInfo) throw PlatformException(code: 'device_info');
      return {
        'sourceApk': '/unused.apk',
        'arm64': true,
        'version': version,
        'build': build,
      };
    });
    service = UpdateService.androidForTesting(
      updateRoot: root,
      origin: 'http://127.0.0.1:${server.port}/updates/v1/',
      verifyEnvelope: (
        bytes, {
        required channel,
        required floor,
        required platform,
      }) async => throw StateError('not reached'),
    );
  });
  tearDown(() async {
    service.dispose();
    messenger.setMockMethodCallHandler(AndroidUpdateBridge.channel, null);
    await server.close(force: true);
    await root.delete(recursive: true);
  });

  test('metadata uses current PackageManager identity on unchanged channel and manifest paths', () async {
    version = '9.88.77';
    build = 98765;
    await service.metadataForTesting(
      'channels/android-arm64/stable.json',
      1000,
    );
    await service.metadataForTesting(
      'manifests/android-arm64/stable/98766/example.json',
      1000,
    );
    expect(paths.first, '/updates/v1/channels/android-arm64/stable.json');
    expect(
      paths.last,
      '/updates/v1/manifests/android-arm64/stable/98766/example.json',
    );
    for (final request in requests) {
      expect(request['version'], version);
      expect(request['build'], '$build');
      expect(request['authorization'], isNull);
      expect(request['cookie'], isNull);
    }
    expect(requests.length, 2);
  });
  test('invalid or unavailable Android identity fails before HTTP, never falls back', () async {
    failInfo = true;
    await expectLater(
      service.metadataForTesting('channels/android-arm64/stable.json', 1000),
      throwsA(isA<PlatformException>()),
    );
    failInfo = false;
    version = 'bad\r\nheader';
    await expectLater(
      service.metadataForTesting('channels/android-arm64/stable.json', 1000),
      throwsFormatException,
    );
    version = '0.22.4';
    build = 0;
    await expectLater(
      service.metadataForTesting('channels/android-arm64/stable.json', 1000),
      throwsFormatException,
    );
    expect(requests, isEmpty);
  });
  test('only two non-identifying headers, bounded valid values', () {
    expect(UpdateClientVersion('0.22.4', 53).headers, {
      'X-WeekGlass-Version': '0.22.4',
      'X-WeekGlass-Build': '53',
    });
    for (final bad in ['', 'a b', 'x\nheader', 'x' * 65]) {
      expect(() => UpdateClientVersion(bad, 53), throwsFormatException);
    }
  });
  test('headerless old cache cannot be reused by transition even on unsolicited 304', () async {
    final cache = File('${root.path}/channel.json');
    await cache.writeAsString('old-headerless-head');
    await File('${cache.path}.etag').writeAsString('"test-release"');
    responseStatus = 304;
    await expectLater(
      service.metadataForTesting(
        'channels/android-arm64/stable.json',
        1000,
        cache: cache,
      ),
      throwsA(isA<HttpException>()),
    );
    expect(requests.single['etag'], isNull);
    expect(await cache.readAsString(), 'old-headerless-head');
  });
  test('same-client ETag works but .4 cache cannot satisfy .5 check', () async {
    final cache = File('${root.path}/channel.json');
    await service.metadataForTesting(
      'channels/android-arm64/stable.json',
      1000,
      cache: cache,
    );
    responseStatus = 304;
    expect(
      await service.metadataForTesting(
        'channels/android-arm64/stable.json',
        1000,
        cache: cache,
      ),
      body.codeUnits,
    );
    expect(requests.last['etag'], '"test-release"');
    version = '0.22.5';
    build = 54;
    await expectLater(
      service.metadataForTesting(
        'channels/android-arm64/stable.json',
        1000,
        cache: cache,
      ),
      throwsA(isA<HttpException>()),
    );
    expect(requests.last['etag'], isNull);
    responseStatus = 200;
    body = 'new-release-head';
    expect(
      await service.metadataForTesting(
        'channels/android-arm64/stable.json',
        1000,
        cache: cache,
      ),
      body.codeUnits,
    );
    expect(
      await File('${cache.path}.client-version').readAsString(),
      '0.22.5\n54',
    );
  });
}
