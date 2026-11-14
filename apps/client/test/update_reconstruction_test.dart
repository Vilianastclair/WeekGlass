import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:weekglass/features/updates/update_object_download.dart';
import 'package:weekglass/features/updates/update_protocol.dart';
import 'package:weekglass/features/updates/update_reconstruction.dart';

class _LiveProgress {
  final port = ReceivePort();
  var calls = 0;

  void update(int received, int total) {
    calls++;
    port.sendPort.send((received, total));
  }
}

Future<Map<String, dynamic>> _entry(File base, File target, File patch) async {
  final targetSize = await target.length();
  final targetHash = await fileSha256(target);
  return {
    'path': 'weekglass.apk',
    'size': targetSize,
    'sha256': targetHash,
    'full': {'encoding': 'raw', 'size': targetSize, 'sha256': targetHash},
    'patches': [
      {
        'encoding': 'bsdiff4',
        'size': await patch.length(),
        'sha256': await fileSha256(patch),
        'base_size': await base.length(),
        'base_sha256': await fileSha256(base),
      },
    ],
  };
}

void main() {
  final fixture = Directory('test/fixtures/updater').absolute;
  late Directory work;
  late File base;
  late File target;
  late File patch;
  late File output;
  late Map<String, dynamic> entry;
  late _LiveProgress progress;
  late List<String> requested;
  late List<AndroidUpdatePreparationStage> stages;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('weekglass-reconstruction-');
    base = await File('${fixture.path}/base.bin').copy('${work.path}/base.apk');
    target = File('${fixture.path}/target.bin');
    patch = File('${fixture.path}/patch.bin');
    output = File('${work.path}/verified.apk');
    entry = await _entry(base, target, patch);
    progress = _LiveProgress();
    requested = [];
    stages = [];
  });

  tearDown(() async {
    progress.port.close();
    await work.delete(recursive: true);
  });

  Future<File> loadObject(
    Map<String, dynamic> descriptor, {
    File? destination,
    void Function(int received, int total)? onProgress,
  }) async {
    final encoding = descriptor['encoding'] as String;
    requested.add(encoding);
    onProgress?.call(descriptor['size'] as int, descriptor['size'] as int);
    if (encoding == 'bsdiff4') return patch;
    expect(destination?.path, '${output.path}.partial');
    return target.copy(destination!.path);
  }

  Future<File> prepare() => prepareAndroidUpdateFile(
    entry: entry,
    sourceApkPath: base.path,
    outputApkPath: output.path,
    loadObject: loadObject,
    onStage: stages.add,
    onProgress: progress.update,
  );

  test(
    'production patch caller keeps unsendable progress state off the worker',
    () async {
      final originalBaseHash = await fileSha256(base);
      final result = await prepare();
      expect(await result.readAsBytes(), await target.readAsBytes());
      expect(requested, ['bsdiff4']);
      expect(stages, contains(AndroidUpdatePreparationStage.reconstruct));
      expect(stages, isNot(contains(AndroidUpdatePreparationStage.retryFull)));
      expect(progress.calls, 1);
      expect(await fileSha256(base), originalBaseHash);
      expect(await File('${output.path}.partial').exists(), isFalse);
    },
  );

  test('invalid patch falls back once to the signed full APK', () async {
    patch = await File('${work.path}/broken.patch').writeAsBytes([1, 2, 3]);
    entry = await _entry(base, target, patch);
    final result = await prepare();
    expect(await result.readAsBytes(), await target.readAsBytes());
    expect(requested, ['bsdiff4', 'raw']);
    expect(stages, contains(AndroidUpdatePreparationStage.retryFull));
    expect(await File('${output.path}.partial').exists(), isFalse);
  });

  test(
    'unverified patch download fails without requesting the full APK',
    () async {
      patch = await File('${work.path}/altered.patch').writeAsBytes([1, 2, 3]);
      await expectLater(prepare(), throwsFormatException);
      expect(requested, ['bsdiff4']);
      expect(stages, isNot(contains(AndroidUpdatePreparationStage.retryFull)));
      expect(await output.exists(), isFalse);
    },
  );

  test(
    'patch network failure retains downloaded bytes and never requests full',
    () async {
      final downloadedPart = await File('${work.path}/object.partial')
          .writeAsBytes([1, 2, 3]);
      await expectLater(
        prepareAndroidUpdateFile(
          entry: entry,
          sourceApkPath: base.path,
          outputApkPath: output.path,
          loadObject: (descriptor, {destination, onProgress}) async {
            requested.add(descriptor['encoding'] as String);
            throw const HttpException('download interrupted');
          },
          onStage: stages.add,
          onProgress: progress.update,
        ),
        throwsA(isA<HttpException>()),
      );
      expect(requested, ['bsdiff4']);
      expect(stages, isNot(contains(AndroidUpdatePreparationStage.retryFull)));
      expect(await downloadedPart.readAsBytes(), [1, 2, 3]);
      expect(await output.exists(), isFalse);
    },
  );

  test(
    'unavailable optional patch uses the signed raw APK exactly once',
    () async {
      final result = await prepareAndroidUpdateFile(
        entry: entry,
        sourceApkPath: base.path,
        outputApkPath: output.path,
        loadObject: (descriptor, {destination, onProgress}) {
          if (descriptor['encoding'] == 'bsdiff4') {
            requested.add('bsdiff4');
            throw const UpdateObjectUnavailable();
          }
          return loadObject(
            descriptor,
            destination: destination,
            onProgress: onProgress,
          );
        },
        onStage: stages.add,
      );
      expect(await result.readAsBytes(), await target.readAsBytes());
      expect(requested, ['bsdiff4', 'raw']);
      expect(stages, contains(AndroidUpdatePreparationStage.retryFull));
      expect(
        stages,
        isNot(contains(AndroidUpdatePreparationStage.reconstruct)),
      );
      expect(await File('${output.path}.partial').exists(), isFalse);
    },
  );

  test(
    'fallback rejects an altered full object and leaves no candidate APK',
    () async {
      patch = await File('${work.path}/broken.patch').writeAsBytes([1, 2, 3]);
      entry = await _entry(base, target, patch);
      final altered = await target.readAsBytes();
      altered[0] ^= 1;
      target = await File('${work.path}/altered.apk').writeAsBytes(altered);
      final originalBaseHash = await fileSha256(base);
      await expectLater(prepare(), throwsFormatException);
      expect(requested, ['bsdiff4', 'raw']);
      expect(await output.exists(), isFalse);
      expect(await File('${output.path}.partial').exists(), isFalse);
      expect(await fileSha256(base), originalBaseHash);
    },
  );

  test(
    'verified APK cache needs neither a source APK nor another download',
    () async {
      await target.copy(output.path);
      final result = await prepareAndroidUpdateFile(
        entry: entry,
        sourceApkPath: '${work.path}/missing.apk',
        outputApkPath: output.path,
        loadObject: loadObject,
        onProgress: progress.update,
      );
      expect(await fileSha256(result), entry['sha256']);
      expect(requested, isEmpty);
      expect(progress.calls, 0);
    },
  );

  test('reopens the raw job after a previous fallback selected it', () async {
    final result = await prepareAndroidUpdateFile(
      entry: entry,
      sourceApkPath: base.path,
      outputApkPath: output.path,
      loadObject: loadObject,
      resumeObject: entry['sha256'] as String,
      onStage: stages.add,
    );
    expect(await result.readAsBytes(), await target.readAsBytes());
    expect(requested, ['raw']);
    expect(
      stages,
      isNot(contains(AndroidUpdatePreparationStage.downloadPatch)),
    );
  });

  test('commits a verified staged APK after app stops before rename', () async {
    final staged = await target.copy('${output.path}.partial');
    final result = await prepare();
    expect(await result.readAsBytes(), await target.readAsBytes());
    expect(requested, isEmpty);
    expect(await staged.exists(), isFalse);
  });

  test(
    'Windows decoding also keeps live caller state off the worker',
    () async {
      final bytes = await File('${fixture.path}/target.zlib').readAsBytes();
      progress.update(0, bytes.length);
      final result = await decodeUpdateObjectInBackground(
        bytes,
        'zlib',
        await target.length(),
      );
      progress.update(bytes.length, bytes.length);
      expect(result, await target.readAsBytes());
      expect(progress.calls, 2);
    },
  );

  final realObject = Platform.environment['REAL_APK_OBJECT'];
  final realBase = Platform.environment['REAL_APK_BASE'];
  final realTarget = Platform.environment['REAL_APK_TARGET'];
  final realReport = Platform.environment['REAL_APK_REPORT_FILE'];
  test(
    'real released APK patch passes the production caller with live progress',
    () async {
      base = File(realBase!).absolute;
      target = File(realTarget!).absolute;
      patch = File(realObject!).absolute;
      entry = await _entry(base, target, patch);
      final originalBaseHash = await fileSha256(base);
      final timer = Stopwatch()..start();
      final result = await prepare();
      timer.stop();
      expect(await fileSha256(result), entry['sha256']);
      expect(await result.length(), entry['size']);
      expect(requested, ['bsdiff4']);
      expect(stages, isNot(contains(AndroidUpdatePreparationStage.retryFull)));
      expect(progress.calls, 1);
      expect(await fileSha256(base), originalBaseHash);
      if (realReport != null && realReport.isNotEmpty) {
        await File(realReport).writeAsString(
          jsonEncode({
            'passed': true,
            'patchBytes': await patch.length(),
            'targetBytes': await target.length(),
            'workerMs': timer.elapsedMilliseconds,
            'fallbackUsed': false,
          }),
          flush: true,
        );
      }
    },
    skip: realObject == null || realBase == null || realTarget == null
        ? 'Set REAL_APK_OBJECT, REAL_APK_BASE and REAL_APK_TARGET for release QA.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
