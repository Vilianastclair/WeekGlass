import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:weekglass/features/updates/accepted_update.dart';
import 'package:weekglass/features/updates/android_update_bridge.dart';
import 'package:weekglass/features/updates/android_update_request.dart';
import 'package:weekglass/features/updates/update_protocol.dart';
import 'package:weekglass/features/updates/update_service.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  final writesAndHandoff = <String>[];
  final metadataRequests = <String>[];
  final apk = [1, 2, 3, 4, 5];
  final apkHash = sha256(apk);
  final now = DateTime.utc(2026, 11, 17);
  late Directory root;
  late UpdateService service;
  late int installedBuild;
  late String installedVersion;
  late int channelBuild;
  late String channelVersion;
  late String installResult;
  PlatformException? installError;
  var advanceInstalledDuringHandoff = false;
  var feedUnavailable = false;
  var manifestUnavailable = false;
  Map<String, dynamic> Function(MethodCall)? downloadState;

  Map<String, dynamic> identity() => {
    'schema': 1,
    'product': 'weekglass',
    'platform': 'android-arm64',
    'channel': 'stable',
    'version': channelVersion,
    'build': channelBuild,
    'generated_at': now.toIso8601String(),
    'expires_at': now.add(const Duration(days: 1)).toIso8601String(),
  };

  List<int> manifestBytes() => utf8.encode(
    jsonEncode({
      ...identity(),
      'min_updater': 1,
      'files': [
        {
          'path': 'weekglass.apk',
          'size': apk.length,
          'sha256': apkHash,
          'full': {'encoding': 'raw', 'size': apk.length, 'sha256': apkHash},
          'patches': [],
        },
      ],
    }),
  );
  String manifestHash() => sha256(manifestBytes());
  String manifestPath() =>
      'manifests/android-arm64/stable/$channelBuild/${manifestHash()}.json';
  List<int> channelBytes() => utf8.encode(
    jsonEncode({
      ...identity(),
      'kind': 'weekglass-channel',
      'manifest': {
        'size': manifestBytes().length,
        'sha256': manifestHash(),
        'path': manifestPath(),
      },
    }),
  );

  File local(String name) => File(p.normalize(p.join(root.path, name)));
  File marker() => local('managed-request');
  File cachedApk() => local('apks/$apkHash.apk');
  Future<void> seedRequest({bool legacy = false}) async {
    await local('channel.json').writeAsBytes(channelBytes());
    final manifest = local('manifests/${manifestHash()}.json');
    await manifest.parent.create(recursive: true);
    await manifest.writeAsBytes(manifestBytes());
    final request = AndroidUpdateRequest(
      manifestHash: manifestHash(),
      build: channelBuild,
      apkHash: apkHash,
      objectHash: apkHash,
    );
    await marker().writeAsString(
      legacy
          ? '${request.manifestHash}\n${request.objectHash}'
          : request.encode(),
    );
  }

  UpdateService client() => UpdateService.androidForTesting(
    updateRoot: root,
    metadata: (path, limit, {cache}) async {
      metadataRequests.add(path);
      if (feedUnavailable || (manifestUnavailable && path == manifestPath())) {
        throw const SocketException('offline');
      }
      final bytes = switch (path) {
        'channels/android-arm64/stable.json' => channelBytes(),
        _ when path == manifestPath() => manifestBytes(),
        _ => throw StateError('Unexpected request: $path'),
      };
      await cache?.writeAsBytes(bytes);
      return bytes;
    },
    // The production verifier still authenticates Ed25519 signatures. Here
    // exercise the state machine independently with a validated local feed.
    verifyEnvelope:
        (bytes, {required channel, required floor, required platform}) async {
          final payload =
              jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
          validateUpdatePayload(
            payload,
            channel: channel,
            floor: floor,
            platform: platform,
            clock: now,
          );
          return payload;
        },
  )..beforeAndroidInstall = () async => writesAndHandoff.add('pending writes');

  Iterable<String> methods() => calls.map((call) => call.method);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('weekglass-android-update-');
    installedBuild = UpdateService.currentBuild - 1;
    installedVersion = '0.20.17';
    channelBuild = UpdateService.currentBuild + 1;
    channelVersion = '0.20.19';
    installResult = 'opened';
    installError = null;
    advanceInstalledDuringHandoff = false;
    feedUnavailable = false;
    manifestUnavailable = false;
    downloadState = null;
    calls.clear();
    metadataRequests.clear();
    writesAndHandoff.clear();
    FlutterSecureStorage.setMockInitialValues({});
    service = client();
    messenger.setMockMethodCallHandler(AndroidUpdateBridge.channel, (
      call,
    ) async {
      calls.add(call);
      switch (call.method) {
        case 'deviceInfo':
          return {
            'sourceApk': local('installed.apk').path,
            'arm64': true,
            'build': installedBuild,
            'version': installedVersion,
          };
        case 'requestUpdateNotifications':
        case 'discardUpdateDownload':
          return null;
        case 'updateObject':
          final result =
              downloadState?.call(call) ??
              {'state': 'ready', 'id': 55, 'received': apk.length};
          if (result['state'] == 'ready') {
            await local('objects/$apkHash').writeAsBytes(apk);
          }
          return result;
        case 'installApk':
          writesAndHandoff.add('installer');
          if (advanceInstalledDuringHandoff) {
            installedBuild = channelBuild;
            installedVersion = channelVersion;
          }
          if (installError case final error?) throw error;
          return installResult;
        case 'verifyApk':
          return true;
        default:
          throw StateError('Unexpected native call: ${call.method}');
      }
    });
  });

  tearDown(() async {
    service.dispose();
    messenger.setMockMethodCallHandler(AndroidUpdateBridge.channel, null);
    await root.delete(recursive: true);
  });

  test(
    'check uses the installed Android version even if Dart has older constants',
    () async {
      installedBuild = channelBuild;
      installedVersion = channelVersion;
      expect(installedBuild, isNot(UpdateService.currentBuild));

      await service.check();
      expect(service.message, '已是最新版本 $installedVersion');
      expect(service.available, isNull);
      expect(methods(), ['deviceInfo']);
      await service.download();
      expect(methods(), ['deviceInfo']);
    },
  );

  test(
    'download validates and hands off the exact APK without an Install tap',
    () async {
      await service.check();
      await service.download();

      expect(service.ready, isTrue);
      expect(await cachedApk().readAsBytes(), apk);
      expect(service.message, '已打开 Android 安装器，请在系统界面确认');
      expect(methods(), [
        'deviceInfo',
        'deviceInfo',
        'requestUpdateNotifications',
        'updateObject',
        'installApk',
      ]);
      expect(writesAndHandoff, ['pending writes', 'installer']);
      expect(calls.last.arguments, {
        'path': cachedApk().absolute.path,
        'sha256': apkHash,
        'size': apk.length,
        'build': channelBuild,
        'version': channelVersion,
        'systemPermissionPrompt': true,
      });
      expect(
        AndroidUpdateRequest.parse(await marker().readAsString()).handedOff,
        isTrue,
      );
    },
  );

  test(
    'a deferred handoff opens on foreground resume, but not after cancellation',
    () async {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      installResult = 'deferred';
      await service.check();
      await service.download();

      expect(service.message, '更新已就绪，返回 WeekGlass 后自动打开安装器');
      expect(
        AndroidUpdateRequest.parse(await marker().readAsString()).handedOff,
        isFalse,
      );
      final opened = Completer<void>();
      service.addListener(() {
        if (!opened.isCompleted &&
            !service.busy &&
            service.message == '已打开 Android 安装器，请在系统界面确认') {
          opened.complete();
        }
      });
      installResult = 'opened';
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await opened.future.timeout(const Duration(seconds: 5));
      expect(methods().where((method) => method == 'installApk'), hasLength(2));

      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(service.busy, isFalse);
      expect(methods().where((method) => method == 'installApk'), hasLength(2));

      service.dispose();
      service = client();
      calls.clear();
      await service.restoreAndroidDownload();
      expect(service.ready, isTrue);
      expect(methods(), ['deviceInfo', 'verifyApk']);
      await service.install();
      expect(methods().last, 'installApk');
    },
  );

  test(
    'a user retry deferred to the background survives a process restart',
    () async {
      await service.check();
      await service.download();
      expect(
        AndroidUpdateRequest.parse(await marker().readAsString()).handedOff,
        isTrue,
      );

      installResult = 'deferred';
      await service.install();
      expect(
        AndroidUpdateRequest.parse(await marker().readAsString()).handedOff,
        isFalse,
      );

      service.dispose();
      service = client();
      calls.clear();
      installResult = 'opened';
      await service.restoreAndroidDownload();
      expect(methods(), ['deviceInfo', 'installApk']);
      expect(
        AndroidUpdateRequest.parse(await marker().readAsString()).handedOff,
        isTrue,
      );
    },
  );

  test('reopening a finished system job prepares it and installs without enqueueing', () async {
    await seedRequest();
    await service.restoreAndroidDownload();

    expect(methods(), ['deviceInfo', 'updateObject', 'installApk']);
    expect(calls[1].arguments, {
      'sha256': apkHash,
      'size': apk.length,
      'start': false,
    });
    expect(service.ready, isTrue);
  });

  for (final legacy in [false, true]) {
    test(
      'already installed receipt is retired before restore (legacy: $legacy)',
      () async {
        installedBuild = channelBuild;
        installedVersion = channelVersion;
        await seedRequest(legacy: legacy);
        await cachedApk().parent.create(recursive: true);
        await cachedApk().writeAsBytes(apk);
        final other = await local('apks/${'a' * 64}.apk').writeAsBytes([6]);
        final part = local('objects/$apkHash.partial');
        await part.parent.create(recursive: true);
        await part.writeAsBytes([1, 2]);

        await service.restoreAndroidDownload();
        expect(service.message, '当前版本 $installedVersion');
        expect(service.ready, isFalse);
        expect(await marker().exists(), isFalse);
        expect(await cachedApk().exists(), isFalse);
        expect(await part.exists(), isFalse);
        expect(
          await local('manifests/${manifestHash()}.json').exists(),
          isFalse,
        );
        expect(await other.exists(), isTrue);
        expect(methods(), ['deviceInfo', 'discardUpdateDownload']);
        expect(calls.last.arguments, {'sha256': apkHash});

        await service.check();
        expect(service.message, '已是最新版本 $installedVersion');
        expect(methods(), [
          'deviceInfo',
          'discardUpdateDownload',
          'deviceInfo',
        ]);
      },
    );
  }

  test(
    'a version installed before native handoff is not an APK mismatch',
    () async {
      advanceInstalledDuringHandoff = true;
      installError = PlatformException(code: 'already_installed');

      await service.check();
      await service.download();

      expect(service.message, '当前版本 $installedVersion');
      expect(service.ready, isFalse);
      expect(service.available, isNull);
      expect(await cachedApk().exists(), isFalse);
      expect(await marker().exists(), isFalse);
    },
  );

  test(
    'an APK whose own version disagrees with the manifest is still rejected',
    () async {
      installError = PlatformException(
        code: 'invalid_apk',
        details: 'package_version',
      );

      await service.check();
      await service.download();

      expect(service.ready, isFalse);
      expect(service.message, '更新准备失败：安装包版本不匹配');
    },
  );

  test(
    'Android skips only the chosen build and retains manual checking',
    () async {
      await const FlutterSecureStorage().write(
        key: 'weekglass_skipped_update_windows-x64',
        value: '$channelBuild',
      );
      await service.checkOnStartup();
      expect(service.startupOffer?.version, channelVersion);
      expect(methods(), ['deviceInfo']);
      expect(metadataRequests, ['channels/android-arm64/stable.json']);
      await service.skipStartupVersion(service.startupOffer!);

      service.dispose();
      service = client();
      await service.checkOnStartup();
      expect(service.startupOffer, isNull);
      expect(service.message, '已跳过版本 $channelVersion');
      await service.check();
      expect(service.available?['build'], channelBuild);
      expect(service.startupOffer, isNull);

      service.dispose();
      service = client();
      channelBuild++;
      channelVersion = '0.20.20';
      await service.checkOnStartup();
      expect(service.startupOffer?.build, channelBuild);
      expect(service.startupOffer?.version, channelVersion);
      expect(methods().toSet(), {'deviceInfo'});
    },
  );

  test(
    'Android cold-start reads the installed build, not Dart constants',
    () async {
      installedBuild = channelBuild;
      installedVersion = channelVersion;
      await service.checkOnStartup();
      expect(service.startupOffer, isNull);
      expect(service.message, '已是最新版本 $installedVersion');
      expect(metadataRequests, ['channels/android-arm64/stable.json']);
      expect(methods(), ['deviceInfo']);
    },
  );

  test(
    'accepted Android update survives a stop before reading the manifest',
    () async {
      await AcceptedUpdate.newJob(channelBuild, channelBytes()).save(root);
      await service.checkOnStartup();

      expect(service.startupOffer, isNull);
      expect(metadataRequests, [manifestPath()]);
      expect(methods(), ['deviceInfo', 'updateObject', 'installApk']);
      expect(writesAndHandoff, ['pending writes', 'installer']);
      expect((calls[1].arguments as Map)['start'], isTrue);
    },
  );

  test('cold restart observes the same accepted DownloadManager job', () async {
    await seedRequest();
    await AcceptedUpdate.newJob(channelBuild, channelBytes()).save(root);
    // A refreshed rolling cache cannot redirect previously granted consent.
    await local('channel.json').writeAsString('other channel');
    var hasSystemJob = true;
    var newJobs = 0;
    downloadState = (call) {
      if (!hasSystemJob && (call.arguments as Map)['start'] == true) {
        hasSystemJob = true;
        newJobs++;
      }
      return hasSystemJob
          ? {'state': 'ready', 'id': 55, 'received': apk.length}
          : {'state': 'missing'};
    };

    await service.checkOnStartup();
    expect(service.startupOffer, isNull);
    expect(metadataRequests, isEmpty);
    expect(newJobs, 0);
    expect(methods(), ['deviceInfo', 'updateObject', 'installApk']);
    expect(writesAndHandoff, ['pending writes', 'installer']);

    service.dispose();
    service = client();
    calls.clear();
    await service.checkOnStartup();
    expect(service.startupOffer, isNull);
    expect(methods(), ['deviceInfo', 'verifyApk']);
    expect(newJobs, 0);
  });

  test('legacy Android job resumes before checking the live channel', () async {
    await seedRequest();
    await service.checkOnStartup();
    expect(metadataRequests, isEmpty);
    expect(service.startupOffer, isNull);
    expect(methods(), ['deviceInfo', 'updateObject', 'installApk']);
    expect((calls[1].arguments as Map)['start'], isFalse);
  });

  test('startup acceptance in the background hands off on resume', () async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    installResult = 'deferred';
    await service.checkOnStartup();
    await service.acceptStartupUpdate(service.startupOffer!);

    expect(service.startupOffer, isNull);
    expect(service.message, '更新已就绪，返回 WeekGlass 后自动打开安装器');
    expect(writesAndHandoff, ['pending writes', 'installer']);
    expect(calls.last.arguments, containsPair('systemPermissionPrompt', true));
    final opened = Completer<void>();
    service.addListener(() {
      if (!opened.isCompleted &&
          !service.busy &&
          service.message == '已打开 Android 安装器，请在系统界面确认') {
        opened.complete();
      }
    });
    installResult = 'opened';
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await opened.future.timeout(const Duration(seconds: 5));
    expect(methods().where((method) => method == 'updateObject'), hasLength(1));
    expect(methods().where((method) => method == 'installApk'), hasLength(2));
  });

  test(
    'startup offline and accepted-download failures remain retryable',
    () async {
      feedUnavailable = true;
      await service.checkOnStartup();
      expect(service.startupOffer, isNull);
      expect(service.message, contains('下载更新信息'));
      expect(methods(), ['deviceInfo']);

      feedUnavailable = false;
      await service.check();
      expect(service.available?['build'], channelBuild);

      service.dispose();
      service = client();
      await service.checkOnStartup();
      downloadState = (_) =>
          throw PlatformException(code: 'managed_download', details: 'space');
      await service.acceptStartupUpdate(service.startupOffer!);
      expect(service.startupOffer, isNull);
      expect(service.ready, isFalse);
      expect(service.message, '设备存储空间不足，请腾出空间后重试');
      expect(await AcceptedUpdate.read(root), isNull);
      expect(await marker().exists(), isFalse);

      service.dispose();
      service = client();
      await service.checkOnStartup();
      expect(service.startupOffer?.build, channelBuild);
    },
  );

  test(
    'accepted Android manifest request survives a connection interruption',
    () async {
      await service.checkOnStartup();
      manifestUnavailable = true;
      await service.acceptStartupUpdate(service.startupOffer!);

      expect(service.startupOffer, isNull);
      expect(service.canRetryAcceptedUpdate, isTrue);
      expect(service.message, contains('连接中断（下载更新清单）'));
      expect((await AcceptedUpdate.read(root))?.build, channelBuild);
      expect(methods(), ['deviceInfo', 'deviceInfo', 'discardUpdateDownload']);
      expect(await marker().exists(), isFalse);

      manifestUnavailable = false;
      metadataRequests.clear();
      calls.clear();
      service.dispose();
      service = client();
      await service.checkOnStartup();
      expect(service.startupOffer, isNull);
      expect(metadataRequests, [manifestPath()]);
      expect(methods(), ['deviceInfo', 'updateObject', 'installApk']);
    },
  );

  test(
    'an already presented Android installer does not hide the next build',
    () async {
      await service.checkOnStartup();
      await service.acceptStartupUpdate(service.startupOffer!);
      expect(
        AndroidUpdateRequest.parse(await marker().readAsString()).handedOff,
        isTrue,
      );
      expect(await cachedApk().exists(), isTrue);

      channelBuild++;
      channelVersion = '0.20.20';
      service.dispose();
      service = client();
      metadataRequests.clear();
      calls.clear();
      await service.checkOnStartup();

      expect(service.startupOffer?.build, channelBuild);
      expect(service.startupOffer?.version, channelVersion);
      expect(metadataRequests, ['channels/android-arm64/stable.json']);
      expect(methods(), ['deviceInfo', 'verifyApk', 'discardUpdateDownload']);
      expect(await marker().exists(), isFalse);
      expect(await AcceptedUpdate.read(root), isNull);
      expect(await cachedApk().exists(), isTrue);
    },
  );
}
