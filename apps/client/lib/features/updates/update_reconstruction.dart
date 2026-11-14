import 'dart:io';
import 'dart:isolate';

import 'update_object_download.dart';
import 'update_protocol.dart';

typedef AndroidUpdateObjectLoader = Future<File> Function(
  Map<String, dynamic> descriptor, {
  File? destination,
  void Function(int received, int total)? onProgress,
});

enum AndroidUpdatePreparationStage {
  inspectSource,
  downloadPatch,
  downloadFull,
  retryFull,
  reconstruct,
  verify,
}

/// Keeps the worker closure outside any UI callback's captured context.
Future<List<int>> decodeUpdateObjectInBackground(
  List<int> bytes,
  String encoding,
  int expected, [
  List<int>? source,
]) => Isolate.run(() => decodeUpdateObject(bytes, encoding, expected, source));

/// Only paths and scalar values cross into the reconstruction isolate.
Future<void> _reconstructAndroidApk({
  required String objectPath,
  required String sourcePath,
  required String outputPath,
  required int sourceSize,
  required String sourceSha256,
  required int outputSize,
  required String outputSha256,
}) => Isolate.run(() async {
  final base = await File(sourcePath).readAsBytes();
  if (base.length != sourceSize || sha256(base) != sourceSha256) {
    throw const FormatException('已安装版本在更新期间改变');
  }
  final rebuilt = decodeUpdateObject(
    await File(objectPath).readAsBytes(),
    'bsdiff4',
    outputSize,
    base,
  );
  if (sha256(rebuilt) != outputSha256) {
    throw const FormatException('重建安装包校验失败');
  }
  await File(outputPath).writeAsBytes(rebuilt, flush: true);
});

Future<bool> _matchesFile(File file, int size, String digest) async =>
    await file.exists() &&
    await file.length() == size &&
    await fileSha256(file) == digest;

Future<void> _verifyObject(File file, Map<String, dynamic> descriptor) async {
  if (!await _matchesFile(
    file,
    descriptor['size'] as int,
    descriptor['sha256'] as String,
  )) {
    throw const FormatException('下载内容校验失败');
  }
}

/// Prepares the APK from an already authenticated Android manifest entry.
///
/// Download and progress callbacks remain on the calling isolate. A missing
/// patch or failed reconstruction falls back once to the full object
/// from that same signed entry. Both routes must produce the exact signed APK
/// before replacing its cache file.
/// Native package identity and certificate verification still follow this step.
Future<File> prepareAndroidUpdateFile({
  required Map<String, dynamic> entry,
  required String sourceApkPath,
  required String outputApkPath,
  required AndroidUpdateObjectLoader loadObject,
  String? resumeObject,
  void Function(AndroidUpdatePreparationStage stage)? onStage,
  void Function(int received, int total)? onProgress,
}) async {
  final apk = File(outputApkPath);
  final expectedSize = entry['size'] as int;
  final expectedHash = entry['sha256'] as String;
  final pending = File('$outputApkPath.partial');
  onStage?.call(AndroidUpdatePreparationStage.verify);
  if (await _matchesFile(apk, expectedSize, expectedHash)) return apk;
  if (await _matchesFile(pending, expectedSize, expectedHash)) {
    return pending.rename(apk.path);
  }

  onStage?.call(AndroidUpdatePreparationStage.inspectSource);
  final source = File(sourceApkPath);
  int? sourceSize;
  String? sourceHash;
  try {
    sourceSize = await source.exists() ? await source.length() : null;
    final possiblePatch = (entry['patches'] as List)
        .cast<Map<String, dynamic>>()
        .any((patch) => patch['base_size'] == sourceSize);
    if (possiblePatch && sourceSize! <= maximumUpdateFile) {
      sourceHash = await fileSha256(source);
    }
  } on FileSystemException {
    // An unreadable installed APK only disables the optional delta route.
    sourceSize = null;
    sourceHash = null;
  }
  final full = entry['full'] as Map<String, dynamic>;
  final selected = resumeObject == full['sha256']
      ? full
      : smallestUpdateObject(
          entry,
          baseSha256: sourceHash,
          baseSize: sourceSize,
        );
  try {
    if (selected['encoding'] == 'bsdiff4') {
      onStage?.call(AndroidUpdatePreparationStage.downloadPatch);
      File? object;
      try {
        object = await loadObject(selected, onProgress: onProgress);
      } on UpdateObjectUnavailable {
        // A missing optional delta does not invalidate the signed full APK.
      }
      if (object != null) {
        await _verifyObject(object, selected);
        var rebuilt = false;
        try {
          onStage?.call(AndroidUpdatePreparationStage.reconstruct);
          await _reconstructAndroidApk(
            objectPath: object.path,
            sourcePath: source.path,
            outputPath: pending.path,
            sourceSize: selected['base_size'] as int,
            sourceSha256: selected['base_sha256'] as String,
            outputSize: expectedSize,
            outputSha256: expectedHash,
          );
          onStage?.call(AndroidUpdatePreparationStage.verify);
          rebuilt = await _matchesFile(pending, expectedSize, expectedHash);
        } catch (_) {
          // The signed full object remains available if reconstruction fails.
        }
        if (rebuilt) return await pending.rename(apk.path);
        if (await pending.exists()) await pending.delete();
      }
      onStage?.call(AndroidUpdatePreparationStage.retryFull);
    } else {
      onStage?.call(AndroidUpdatePreparationStage.downloadFull);
    }
    await loadObject(full, destination: pending, onProgress: onProgress);
    onStage?.call(AndroidUpdatePreparationStage.verify);
    if (!await _matchesFile(pending, expectedSize, expectedHash)) {
      throw const FormatException('安装包校验失败');
    }
    return await pending.rename(apk.path);
  } finally {
    if (await pending.exists()) await pending.delete();
  }
}
