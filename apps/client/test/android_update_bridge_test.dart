import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weekglass/features/updates/android_update_bridge.dart';
import 'package:weekglass/features/updates/update_object_download.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const bridge = AndroidUpdateBridge();
  final artifact = AndroidUpdateArtifact(
    file: File('verified-update.apk'),
    sha256: 'a' * 64,
    size: 123,
    build: 26,
    version: '0.20.2',
  );
  final calls = <MethodCall>[];

  setUp(calls.clear);
  tearDown(
    () => messenger.setMockMethodCallHandler(AndroidUpdateBridge.channel, null),
  );

  test(
    'device inspection and verification never request installation permission',
    () async {
      messenger.setMockMethodCallHandler(AndroidUpdateBridge.channel, (
        call,
      ) async {
        calls.add(call);
        return switch (call.method) {
          'deviceInfo' => {'sourceApk': '/data/app/base.apk', 'arm64': true},
          'verifyApk' => true,
          _ => throw StateError('Unexpected installation action'),
        };
      });
      final info = await bridge.info();
      expect(info.arm64, isTrue);
      expect(info.sourceApk.path, '/data/app/base.apk');
      await bridge.verify(artifact);
      expect(calls.map((call) => call.method), ['deviceInfo', 'verifyApk']);
      expect(calls.last.arguments, artifact.arguments);
    },
  );

  test(
    'permission-required result waits for a separate explicit settings action',
    () async {
      messenger.setMockMethodCallHandler(AndroidUpdateBridge.channel, (
        call,
      ) async {
        calls.add(call);
        return call.method == 'installApk' ? 'permission_required' : null;
      });
      expect(
        await bridge.install(artifact),
        AndroidInstallResult.permissionRequired,
      );
      expect(calls.map((call) => call.method), ['installApk']);
      expect(calls.single.arguments, artifact.arguments);
      await bridge.openInstallSettings();
      expect(calls.last.method, 'openInstallSettings');
    },
  );

  test(
    'only confirmed native handoff counts as opening the installer',
    () async {
      messenger.setMockMethodCallHandler(
        AndroidUpdateBridge.channel,
        (_) async => 'opened',
      );
      expect(await bridge.install(artifact), AndroidInstallResult.opened);
      messenger.setMockMethodCallHandler(
        AndroidUpdateBridge.channel,
        (_) async => 'unknown',
      );
      await expectLater(bridge.install(artifact), throwsFormatException);
    },
  );

  test(
    'native identity verification failure is not treated as verified',
    () async {
      messenger.setMockMethodCallHandler(
        AndroidUpdateBridge.channel,
        (_) async => false,
      );
      await expectLater(bridge.verify(artifact), throwsFormatException);
    },
  );

  test('package parse, signer availability and mismatch are distinct', () {
    String? issue(String reason) => androidPackageVerificationIssue(
      PlatformException(code: 'invalid_apk', details: reason),
    );
    expect(issue('archive_unreadable'), '系统无法解析安装包');
    expect(issue('installed_signer_unavailable'), '系统无法读取已安装应用的签名');
    expect(issue('archive_signer_unavailable'), '系统无法读取安装包的签名');
    expect(issue('signer_mismatch'), '安装包与已安装应用的签名不同');
    expect(
      androidPackageVerificationIssue(
        PlatformException(code: 'installer_unavailable'),
      ),
      isNull,
    );
  });

  test('explicit download keeps one system job through running, pause and completion', () async {
    final updates = <(AndroidObjectDownloadState, int)>[];
    final snapshots = [
      {'state': 'running', 'received': 12},
      {'state': 'waiting_network', 'received': 12},
      {'state': 'waiting_wifi', 'received': 12},
      {'state': 'ready', 'received': artifact.size},
    ];
    messenger.setMockMethodCallHandler(AndroidUpdateBridge.channel, (
      call,
    ) async {
      calls.add(call);
      return {'id': 57, ...snapshots[calls.length - 1]};
    });
    await bridge.downloadObject(
      sha256: artifact.sha256,
      size: artifact.size,
      start: true,
      onState: (state, received) => updates.add((state, received)),
    );
    expect(updates, [
      (AndroidObjectDownloadState.running, 12),
      (AndroidObjectDownloadState.waitingNetwork, 12),
      (AndroidObjectDownloadState.waitingWifi, 12),
      (AndroidObjectDownloadState.ready, artifact.size),
    ]);
    expect(calls.map((call) => call.method), List.filled(4, 'updateObject'));
    final object = {'sha256': artifact.sha256, 'size': artifact.size};
    expect(calls.first.arguments, {...object, 'start': true});
    for (final call in calls.skip(1)) {
      expect(call.arguments, {...object, 'start': false, 'id': 57});
    }
  });

  for (final present in [true, false]) {
    test('reopening never enqueues a job (existing job: $present)', () async {
      messenger.setMockMethodCallHandler(AndroidUpdateBridge.channel, (
        call,
      ) async {
        calls.add(call);
        return present
            ? {'state': 'ready', 'id': 57, 'received': artifact.size}
            : {'state': 'missing'};
      });
      final observed = <AndroidObjectDownloadState>[];
      final result = const AndroidUpdateBridge().downloadObject(
        sha256: artifact.sha256,
        size: artifact.size,
        start: false,
        onState: (state, _) => observed.add(state),
      );
      if (present) {
        await result;
        expect(observed, [AndroidObjectDownloadState.ready]);
      } else {
        await expectLater(
          result,
          throwsA(
            isA<AndroidManagedDownloadFailure>().having(
              (e) => e.reason,
              'reason',
              'missing',
            ),
          ),
        );
        expect(observed, isEmpty);
      }
      expect(calls.single.arguments, {
        'sha256': artifact.sha256,
        'size': artifact.size,
        'start': false,
      });
    });
  }

  for (final reason in [
    'unavailable',
    'integrity',
    'space',
    'object_missing',
  ]) {
    test(
      'managed download reports $reason without another transport',
      () async {
        messenger.setMockMethodCallHandler(AndroidUpdateBridge.channel, (
          call,
        ) async {
          calls.add(call);
          throw PlatformException(code: 'managed_download', details: reason);
        });
        await expectLater(
          bridge.downloadObject(
            sha256: artifact.sha256,
            size: artifact.size,
            start: true,
            onState: (_, _) =>
                fail('Failed native request must not look active'),
          ),
          reason == 'object_missing'
              ? throwsA(isA<UpdateObjectUnavailable>())
              : throwsA(
                  isA<AndroidManagedDownloadFailure>().having(
                    (e) => e.reason,
                    'reason',
                    reason,
                  ),
                ),
        );
        expect(calls.single.method, 'updateObject');
      },
    );
  }
}
