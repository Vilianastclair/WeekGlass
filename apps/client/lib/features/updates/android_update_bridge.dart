import 'dart:io';

import 'package:flutter/services.dart';

import 'update_object_download.dart';

class AndroidUpdateInfo {
  const AndroidUpdateInfo({required this.sourceApk, required this.arm64});

  final File sourceApk;
  final bool arm64;
}

class AndroidUpdateArtifact {
  const AndroidUpdateArtifact({
    required this.file,
    required this.sha256,
    required this.size,
    required this.build,
    required this.version,
  });

  final File file;
  final String sha256;
  final int size;
  final int build;
  final String version;

  Map<String, dynamic> get arguments => {
    'path': file.absolute.path,
    'sha256': sha256,
    'size': size,
    'build': build,
    'version': version,
  };
}

enum AndroidInstallResult { opened, permissionRequired }

enum AndroidObjectDownloadState {
  pending,
  running,
  waitingNetwork,
  waitingWifi,
  waitingRetry,
  ready,
}

class AndroidManagedDownloadFailure implements Exception {
  const AndroidManagedDownloadFailure(this.reason);

  final String reason;

  String get message => switch (reason) {
    'unavailable' => '系统不支持后台下载',
    'missing' => '后台下载任务已不存在，请重新下载',
    'space' => '设备存储空间不足，请腾出空间后重试',
    'storage' => '系统无法保存更新文件，请检查可用空间后重试',
    'cannot_resume' => '系统无法继续本次下载，请重试',
    'integrity' => '下载文件不完整或校验不符，请重试',
    'source' => '更新文件下载地址异常',
    _ => '系统下载未完成（$reason），请重试',
  };
}

String? androidPackageVerificationIssue(Object error) {
  if (error is! PlatformException || error.code != 'invalid_apk') return null;
  return switch (error.details) {
    'file_location' => '系统无法读取更新目录',
    'file_content' => '安装包文件不完整或已改变',
    'archive_unreadable' => '系统无法解析安装包',
    'package_name' => '应用标识不匹配',
    'package_version' => '安装包版本不匹配',
    'installed_signer_unavailable' => '系统无法读取已安装应用的签名',
    'archive_signer_unavailable' => '系统无法读取安装包的签名',
    'signer_mismatch' => '安装包与已安装应用的签名不同',
    'archive_abi' => '安装包缺少 ARM64 文件',
    'package_access' => '系统读取或校验安装包时出错',
    _ => '安装包身份或签名校验未通过',
  };
}

/// The native side checks the APK identity and signing certificate again before
/// granting the system installer read access to this one private file.
class AndroidUpdateBridge {
  const AndroidUpdateBridge();

  static const channel = MethodChannel('com.viliana.weekglass/updates');

  Future<AndroidUpdateInfo> info() async {
    final value = await channel.invokeMapMethod<String, dynamic>('deviceInfo');
    if (value == null || value['sourceApk'] is! String) {
      throw const FormatException('无法读取已安装版本');
    }
    return AndroidUpdateInfo(
      sourceApk: File(value['sourceApk'] as String),
      arm64: value['arm64'] == true,
    );
  }

  /// Observe the existing OS job; only an explicit user action can start one.
  Future<void> downloadObject({
    required String sha256,
    required int size,
    required bool start,
    required void Function(AndroidObjectDownloadState state, int received)
    onState,
  }) async {
    int? id;
    while (true) {
      Map<String, dynamic>? value;
      try {
        value = await channel.invokeMapMethod<String, dynamic>('updateObject', {
          'sha256': sha256,
          'size': size,
          'id': ?id,
          'start': start && id == null,
        });
      } on MissingPluginException {
        throw const AndroidManagedDownloadFailure('unavailable');
      } on PlatformException catch (error) {
        if (error.code != 'managed_download') rethrow;
        final reason = error.details;
        if (reason == 'object_missing') throw const UpdateObjectUnavailable();
        throw AndroidManagedDownloadFailure(
          reason is String ? reason : 'unavailable',
        );
      }
      final state = switch (value?['state']) {
        'pending' => AndroidObjectDownloadState.pending,
        'running' => AndroidObjectDownloadState.running,
        'waiting_network' => AndroidObjectDownloadState.waitingNetwork,
        'waiting_wifi' => AndroidObjectDownloadState.waitingWifi,
        'waiting_retry' => AndroidObjectDownloadState.waitingRetry,
        'ready' => AndroidObjectDownloadState.ready,
        'missing' => throw const AndroidManagedDownloadFailure('missing'),
        _ => throw const AndroidManagedDownloadFailure('unavailable'),
      };
      final nextId = value?['id'];
      final received = value?['received'];
      if (nextId is! int ||
          nextId < 1 ||
          (id != null && nextId != id) ||
          received is! int ||
          received < 0 ||
          received > size) {
        throw const AndroidManagedDownloadFailure('unavailable');
      }
      id = nextId;
      onState(state, received);
      if (state == AndroidObjectDownloadState.ready) return;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }

  Future<void> verify(AndroidUpdateArtifact artifact) async {
    if (await channel.invokeMethod<bool>('verifyApk', artifact.arguments) !=
        true) {
      throw const FormatException('安装包身份校验失败');
    }
  }

  Future<AndroidInstallResult> install(AndroidUpdateArtifact artifact) async {
    final result = await channel.invokeMethod<String>(
      'installApk',
      artifact.arguments,
    );
    return switch (result) {
      'opened' => AndroidInstallResult.opened,
      'permission_required' => AndroidInstallResult.permissionRequired,
      _ => throw const FormatException('无法打开系统安装器'),
    };
  }

  Future<void> openInstallSettings() async {
    await channel.invokeMethod<void>('openInstallSettings');
  }
}
