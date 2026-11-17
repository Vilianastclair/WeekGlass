import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleListener, AppLifecycleState, WidgetsBinding;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'android_update_bridge.dart';
import 'android_update_request.dart';
import 'update_object_download.dart';
import 'update_protocol.dart';
import 'update_reconstruction.dart';

typedef UpdateMetadata = Future<List<int>> Function(
  String path,
  int limit, {
  File? cache,
});
typedef UpdateEnvelopeVerifier = Future<Map<String, dynamic>> Function(
  List<int> bytes, {
  required bool channel,
  required int floor,
  required String platform,
});

class UpdateService extends ChangeNotifier {
  UpdateService._({
    bool? android,
    this._updateRoot,
    this._fetchMetadata,
    this._verifyEnvelope = verifyUpdateEnvelope,
  }) : isAndroid = android ?? Platform.isAndroid;

  @visibleForTesting
  UpdateService.androidForTesting({
    required Directory updateRoot,
    required UpdateMetadata metadata,
    required UpdateEnvelopeVerifier verifyEnvelope,
  }) : this._(
         android: true,
         updateRoot: updateRoot,
         fetchMetadata: metadata,
         verifyEnvelope: verifyEnvelope,
       );

  static final instance = UpdateService._();
  static const currentVersion = '0.20.16';
  static const currentBuild = 42;
  Future<void> Function()? beforeInstall;
  Future<void> Function()? beforeAndroidInstall;
  Future<void> Function()? afterInstallFailure;
  bool busy = false;
  double? progress;
  String message = '当前版本 $currentVersion';
  Map<String, dynamic>? available;
  Directory? _stage;
  File? _manifestFile;
  Directory? _job;
  AndroidUpdateArtifact? _androidArtifact;
  AndroidUpdateRequest? _androidRequest;
  bool _androidHandoffPending = false;
  AppLifecycleListener? _androidLifecycle;
  bool _resumedWhileBusy = false;
  bool needsInstallPermission = false;
  bool androidBackgroundDownloadUnavailable = false;
  bool get supportsUpdates => Platform.isWindows || isAndroid;
  final bool isAndroid;
  bool get ready => isAndroid ? _androidArtifact != null : _stage != null;
  String get _platform => isAndroid ? 'android-arm64' : 'windows-x64';
  String get _floorKey => isAndroid
      ? 'weekglass_update_floor_android_arm64'
      : 'weekglass_update_floor';
  final _android = const AndroidUpdateBridge();
  final _secure = const FlutterSecureStorage();
  final Directory? _updateRoot;
  final UpdateMetadata? _fetchMetadata;
  final UpdateEnvelopeVerifier _verifyEnvelope;

  Future<Directory> _root() async =>
      (_updateRoot ??
            Directory(
              p.join(
                (await getApplicationSupportDirectory()).path,
                'updates',
                isAndroid ? 'android-arm64' : '',
              ),
            ))
        ..createSync(recursive: true);
  void _show(String value) {
    message = value;
    notifyListeners();
  }

  Future<List<int>> _metadata(String relative, int limit, {File? cache}) async {
    if (_fetchMetadata case final fetch?) {
      return fetch(relative, limit, cache: cache);
    }
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await http.getUrl(
        Uri.parse(updateOrigin).resolve(relative),
      );
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final tag = cache == null ? null : File('${cache.path}.etag');
      if (cache != null && await cache.exists() && await tag!.exists()) {
        request.headers.set(
          HttpHeaders.ifNoneMatchHeader,
          await tag.readAsString(),
        );
      }
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode == 304 && cache != null && await cache.exists()) {
        return await cache.readAsBytes();
      }
      if (response.statusCode != 200 || response.contentLength > limit) {
        throw const HttpException('无法读取更新信息');
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        bytes.addAll(chunk);
        if (bytes.length > limit) throw const FormatException('更新信息过大');
      }
      if (cache != null) {
        await cache.writeAsBytes(bytes, flush: true);
        final etag = response.headers.value(HttpHeaders.etagHeader);
        if (etag != null) {
          await tag!.writeAsString(etag);
        } else if (await tag!.exists()) {
          await tag.delete();
        }
      }
      return bytes;
    } finally {
      http.close(force: true);
    }
  }

  Future<void> check() async {
    if (busy || !supportsUpdates) return;
    busy = true;
    progress = null;
    androidBackgroundDownloadUnavailable = false;
    _show('正在检查更新…');
    var step = '读取设备信息';
    try {
      final device = isAndroid ? await _android.info() : null;
      final installedBuild = device?.build ?? currentBuild;
      final installedVersion = device?.version ?? currentVersion;
      if (device != null && !device.arm64) {
        available = null;
        _show('当前版本 $installedVersion；此设备暂不支持应用内更新');
        return;
      }
      step = '读取更新目录';
      final root = await _root();
      if (device != null) {
        await _readPendingAndroidRequest(root, device);
      }
      step = '读取更新记录';
      final floor = max(
        installedBuild,
        int.tryParse(await _secure.read(key: _floorKey) ?? '') ??
            installedBuild,
      );
      step = '下载更新信息';
      final bytes = await _metadata(
        'channels/$_platform/stable.json',
        16384,
        cache: File(p.join(root.path, 'channel.json')),
      );
      step = '校验更新信息';
      final channel = await _verifyEnvelope(
        bytes,
        channel: true,
        floor: floor,
        platform: _platform,
      );
      step = '保存更新记录';
      await _secure.write(key: _floorKey, value: '${channel['build']}');
      available = (channel['build'] as int) > installedBuild ? channel : null;
      if (device != null && _androidArtifact?.build != available?['build']) {
        _clearAndroidArtifact();
      }
      _show(
        available == null
            ? '已是最新版本 $installedVersion'
            : '发现新版本 ${channel['version']}',
      );
    } catch (_) {
      _show(
        isAndroid
            ? '检查更新失败（$step），请稍后重试；版本或签名异常时不会安装'
            : '暂时无法检查更新，请稍后重试；版本或签名异常时不会安装',
      );
    } finally {
      _finishUpdateWork();
    }
  }

  Future<File> _object(
    Directory cache,
    Map<String, dynamic> descriptor, {
    File? destination,
    void Function(int received, int total)? onProgress,
  }) {
    final digest = descriptor['sha256'] as String;
    return downloadUpdateObject(
      uri: Uri.parse(
        '${updateOrigin}objects/${digest.substring(0, 2)}/$digest',
      ),
      cacheFile: File(p.join(cache.path, digest)),
      digest: digest,
      size: descriptor['size'] as int,
      destination: destination,
      onProgress: onProgress,
    );
  }

  Future<void> download() async {
    if (busy || available == null || !supportsUpdates) return;
    if (isAndroid) return _downloadAndroid();
    busy = true;
    progress = 0;
    _show('正在准备增量更新…');
    Directory? staging;
    try {
      final root = await _root(), channel = available!;
      // Revalidate a cached channel before spending bytes or staging executable files.
      final channelBytes = await File(p.join(root.path, 'channel.json'))
          .readAsBytes();
      await verifyUpdateEnvelope(
        channelBytes,
        channel: true,
        floor: channel['build'] as int,
      );
      final descriptor = channel['manifest'] as Map<String, dynamic>;
      final manifestBytes = await _metadata(
        descriptor['path'] as String,
        4194304,
      );
      if (manifestBytes.length != descriptor['size'] ||
          sha256(manifestBytes) != descriptor['sha256']) {
        throw const FormatException('更新清单不匹配');
      }
      final manifest = await verifyUpdateEnvelope(
        manifestBytes,
        channel: false,
        floor: channel['build'] as int,
      );
      if (manifest['build'] != channel['build'] ||
          manifest['version'] != channel['version']) {
        throw const FormatException('更新版本不匹配');
      }
      final current = File(Platform.resolvedExecutable).parent;
      final nonce =
          '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}';
      staging = Directory(
        p.join(current.parent.path, '.weekglass-stage-$nonce'),
      );
      await staging.create();
      final jobs = Directory(p.join(root.path, 'jobs'));
      await jobs.create(recursive: true);
      final job = Directory(p.join(jobs.path, nonce));
      await job.create();
      final manifestFile = File(p.join(job.path, 'manifest.json'));
      await manifestFile.writeAsBytes(manifestBytes, flush: true);
      final cache = Directory(p.join(root.path, 'objects'));
      await cache.create(recursive: true);
      final entries = (manifest['files'] as List).cast<Map<String, dynamic>>();
      var done = 0;
      for (final entry in entries) {
        final name = entry['path'] as String;
        final old = await updateChild(current, name);
        List<int>? source;
        if (await old.exists() && await old.length() <= maximumUpdateFile) {
          source = await old.readAsBytes();
        }
        final sourceHash = source == null ? null : sha256(source);
        List<int> result;
        if (sourceHash == entry['sha256']) {
          result = source!;
        } else {
          final selected = smallestUpdateObject(
            entry,
            baseSha256: sourceHash,
            baseSize: source?.length,
          );
          final object = await _object(cache, selected);
          final bytes = await object.readAsBytes();
          final encoding = selected['encoding'] as String;
          final expected = entry['size'] as int;
          final base = source;
          result = await decodeUpdateObjectInBackground(
            bytes,
            encoding,
            expected,
            base,
          );
        }
        if (result.length != entry['size'] ||
            sha256(result) != entry['sha256']) {
          throw const FormatException('更新重建校验失败');
        }
        final output = await updateChild(staging, name);
        await output.parent.create(recursive: true);
        await output.writeAsBytes(result, flush: true);
        progress = ++done / entries.length;
        _show('正在准备更新 $done / ${entries.length}');
      }
      await verifyStagedUpdate(staging, manifest);
      _stage = staging;
      _job = job;
      _manifestFile = manifestFile;
      _show('更新已就绪，重启后完成安装');
    } catch (_) {
      if (staging != null && await staging.exists()) {
        await staging.delete(recursive: true);
      }
      // Publication may have retired the manifest after this client checked it.
      // Return to channel checking instead of repeatedly retrying that old URL.
      available = null;
      _stage = null;
      _job = null;
      _manifestFile = null;
      _show('更新准备失败，请重新检查；已下载内容会复用，原版本保持可用');
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// A startup after package replacement can still see the previous app's
  /// download receipt. Resolve that receipt before considering any APK.
  Future<AndroidUpdateRequest?> _readPendingAndroidRequest(
    Directory root,
    AndroidUpdateInfo installed,
  ) async {
    final marker = await updateChild(root, 'managed-request');
    if (!await marker.exists()) return null;

    AndroidUpdateRequest? request;
    try {
      request = AndroidUpdateRequest.parse(await marker.readAsString());
      if (request.build == null) {
        // Older receipts have no build or APK hash. Recover them from the
        // authenticated manifest, independently of a refreshed channel cache.
        final file = await updateChild(
          root,
          'manifests/${request.manifestHash}.json',
        );
        final bytes = await file.readAsBytes();
        if (sha256(bytes) != request.manifestHash) {
          throw const FormatException('更新清单不匹配');
        }
        final manifest = await _verifyEnvelope(
          bytes,
          channel: false,
          floor: 1,
          platform: _platform,
        );
        final entry =
            (manifest['files'] as List).single as Map<String, dynamic>;
        request = request.forArtifact(
          manifest['build'] as int,
          entry['sha256'] as String,
        );
      }
    } catch (_) {
      // A broken local receipt does not turn a fresh update check into an
      // installation error.
    }
    if (request?.build == null || request!.build! <= installed.build) {
      await _retireAndroidRequest(root, request);
      return null;
    }
    return request;
  }

  Future<void> _saveAndroidRequest(
    Directory root,
    AndroidUpdateRequest request,
  ) async {
    final marker = await updateChild(root, 'managed-request');
    final pending = await updateChild(root, 'managed-request.partial');
    await pending.writeAsString(request.encode(), flush: true);
    await pending.rename(marker.path);
  }

  Future<void> _removeAndroidFile(Directory root, String name) async {
    try {
      final file = await updateChild(root, name);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // The next check can still compare the actual installed build.
    } on FormatException {
      // Never traverse links while cleaning the private update cache.
    }
  }

  Future<void> _retireAndroidRequest(
    Directory root,
    AndroidUpdateRequest? request, {
    bool purgeFiles = true,
  }) async {
    _clearAndroidArtifact();
    await _removeAndroidFile(root, 'managed-request');
    await _removeAndroidFile(root, 'managed-request.partial');
    await _discardAndroidDownload(purgeFiles ? request?.objectHash : null);
    if (request == null || !purgeFiles) return;
    await _removeAndroidFile(root, 'manifests/${request.manifestHash}.json');
    await _removeAndroidFile(
      root,
      'manifests/${request.manifestHash}.json.etag',
    );
    if (request.apkHash case final hash?) {
      await _removeAndroidFile(root, 'apks/$hash.apk');
      await _removeAndroidFile(root, 'apks/$hash.apk.partial');
    }
    for (final hash in {request.objectHash, request.apkHash}.nonNulls) {
      await _removeAndroidFile(root, 'objects/$hash');
      await _removeAndroidFile(root, 'objects/$hash.partial');
      await _removeAndroidFile(root, 'objects/$hash.managed-partial');
    }
  }

  Future<void> _discardAndroidDownload(String? hash) async {
    try {
      await _android.discardDownload(hash);
    } on PlatformException {
      // An unavailable DownloadManager must not block checking for updates.
    }
  }

  void _clearAndroidArtifact() {
    _androidArtifact = null;
    _androidRequest = null;
    _manifestFile = null;
    _androidHandoffPending = false;
    needsInstallPermission = false;
  }

  void _watchAndroidForeground() {
    _androidLifecycle ??= AppLifecycleListener(
      onResume: () {
        if (busy) {
          _resumedWhileBusy = true;
        } else if (_androidHandoffPending) {
          unawaited(_installAndroid());
        }
      },
    );
  }

  void _finishUpdateWork() {
    busy = false;
    final retry =
        _resumedWhileBusy &&
        _androidHandoffPending &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _resumedWhileBusy = false;
    notifyListeners();
    if (retry) unawaited(_installAndroid());
  }

  @override
  void dispose() {
    _androidLifecycle?.dispose();
    super.dispose();
  }

  Future<void> restoreAndroidDownload() async {
    if (!isAndroid || busy) return;
    _watchAndroidForeground();
    await _downloadAndroid(restoring: true);
  }

  Future<void> _downloadAndroid({bool restoring = false}) async {
    _watchAndroidForeground();
    busy = true;
    progress = null;
    needsInstallPermission = false;
    androidBackgroundDownloadUnavailable = false;
    if (!restoring) _show('正在核对 Android 更新…');
    var step = '读取设备信息';
    var downloadKind = '完整安装包（arm64）';
    Directory? root;
    AndroidUpdateRequest? request;
    String? installedVersion;
    var manifestReady = false;
    try {
      final info = await _android.info();
      installedVersion = info.version;
      if (!info.arm64) {
        available = null;
        _show('当前版本 ${info.version}；此设备暂不支持应用内更新');
        return;
      }
      step = '读取更新目录';
      final updateRoot = root = await _root();
      request = await _readPendingAndroidRequest(updateRoot, info);
      if (restoring && request == null) {
        if (available == null && !ready) _show('当前版本 ${info.version}');
        return;
      }
      step = '读取更新记录';
      final floor = await _androidFloor(info.build);
      step = '校验更新信息';
      final channel = await _verifyEnvelope(
        await (await updateChild(updateRoot, 'channel.json')).readAsBytes(),
        channel: true,
        floor: floor,
        platform: _platform,
      );
      final descriptor = channel['manifest'] as Map<String, dynamic>;
      final manifestHash = descriptor['sha256'] as String;
      if (request != null && request.manifestHash != manifestHash) {
        await _retireAndroidRequest(
          updateRoot,
          request,
          purgeFiles: request.build != channel['build'],
        );
        request = null;
      }
      if (restoring && request == null) {
        _show('当前版本 ${info.version}');
        return;
      }
      if (restoring) _show('正在恢复 Android 更新…');
      final manifests = Directory(p.join(updateRoot.path, 'manifests'));
      final manifestFile = await updateChild(
        updateRoot,
        'manifests/$manifestHash.json',
      );
      await manifests.create(recursive: true);
      step = '下载更新清单';
      final bytes = restoring
          ? await manifestFile.readAsBytes()
          : await _metadata(
              descriptor['path'] as String,
              4194304,
              cache: manifestFile,
            );
      step = '校验更新清单';
      if (bytes.length != descriptor['size'] || sha256(bytes) != manifestHash) {
        throw const FormatException('更新清单不匹配');
      }
      final manifest = await _verifyEnvelope(
        bytes,
        channel: false,
        floor: floor,
        platform: _platform,
      );
      if (manifest['build'] != channel['build'] ||
          manifest['version'] != channel['version']) {
        throw const FormatException('更新版本不匹配');
      }
      final entry = (manifest['files'] as List).single as Map<String, dynamic>;
      final build = manifest['build'] as int;
      final apkHash = entry['sha256'] as String;
      var active = (request ?? AndroidUpdateRequest(manifestHash: manifestHash))
          .forArtifact(build, apkHash);
      if (!restoring) active = active.copyWith(handedOff: false);
      await _saveAndroidRequest(updateRoot, active);
      request = active;
      manifestReady = true;
      available = channel;
      if (!restoring) await _android.requestUpdateNotifications();

      step = '准备更新目录';
      final apk = await updateChild(updateRoot, 'apks/$apkHash.apk');
      await apk.parent.create(recursive: true);
      final cache = Directory(p.join(updateRoot.path, 'objects'));
      await cache.create(recursive: true);
      AndroidObjectDownloadState? lastState;
      await prepareAndroidUpdateFile(
        entry: entry,
        sourceApkPath: info.sourceApk.path,
        outputApkPath: apk.path,
        resumeObject: active.objectHash,
        loadObject: (object, {destination, onProgress}) async {
          final hash = object['sha256'] as String;
          final size = object['size'] as int;
          final cached = await updateChild(cache, hash);
          final oldPart = await updateChild(cache, '$hash.partial');
          Future<bool> matches(File file) async =>
              await file.exists() &&
              await file.length() == size &&
              await fileSha256(file) == hash;
          if (await matches(cached)) {
            return destination == null
                ? cached
                : cached.rename(destination.path);
          }
          if (await matches(oldPart)) {
            return oldPart.rename((destination ?? cached).path);
          }
          if (restoring && active.objectHash != hash) {
            throw const AndroidManagedDownloadFailure('missing');
          }
          if (active.objectHash != hash) {
            active = active.copyWith(objectHash: hash);
            await _saveAndroidRequest(updateRoot, active);
            request = active;
          }
          await _android.downloadObject(
            sha256: hash,
            size: size,
            start: !restoring,
            onState: (state, received) {
              if (state != lastState) {
                lastState = state;
                progress = null;
                switch (state) {
                  case AndroidObjectDownloadState.pending:
                    _show('等待系统开始下载…');
                  case AndroidObjectDownloadState.waitingNetwork:
                    _show('网络恢复后继续下载');
                  case AndroidObjectDownloadState.waitingWifi:
                    _show('连接 Wi‑Fi 后继续下载');
                  case AndroidObjectDownloadState.waitingRetry:
                    _show('系统暂时暂停下载，稍后继续');
                  case AndroidObjectDownloadState.running:
                  case AndroidObjectDownloadState.ready:
                    break;
                }
              }
              if (state == AndroidObjectDownloadState.running) {
                onProgress?.call(received, size);
              } else if (state != AndroidObjectDownloadState.ready &&
                  received > 0) {
                final value = received / size;
                if (progress != value) {
                  progress = value;
                  notifyListeners();
                }
              }
            },
          );
          return destination == null ? cached : cached.rename(destination.path);
        },
        onStage: (stage) {
          progress = null;
          lastState = null;
          step = switch (stage) {
            AndroidUpdatePreparationStage.inspectSource => '读取已安装版本',
            AndroidUpdatePreparationStage.downloadPatch => '下载差分更新',
            AndroidUpdatePreparationStage.downloadFull ||
            AndroidUpdatePreparationStage.retryFull => '下载完整安装包',
            AndroidUpdatePreparationStage.reconstruct => '重建安装包',
            AndroidUpdatePreparationStage.verify => '校验安装包文件',
          };
          if (stage == AndroidUpdatePreparationStage.downloadPatch) {
            downloadKind = '差分更新';
          } else if (stage == AndroidUpdatePreparationStage.downloadFull ||
              stage == AndroidUpdatePreparationStage.retryFull) {
            downloadKind = '完整安装包（arm64）';
          }
          _show(switch (stage) {
            AndroidUpdatePreparationStage.inspectSource => '正在选择更新内容…',
            AndroidUpdatePreparationStage.downloadPatch ||
            AndroidUpdatePreparationStage.downloadFull =>
              '正在准备下载$downloadKind…',
            AndroidUpdatePreparationStage.retryFull => '差分更新未成功，正在改用完整安装包…',
            AndroidUpdatePreparationStage.reconstruct => '正在重建并校验安装包…',
            AndroidUpdatePreparationStage.verify => '正在校验安装包…',
          });
        },
        onProgress: (received, total) {
          final value = total == 0 ? 1.0 : received / total;
          if (progress == null || value != progress) {
            progress = value;
            _show('正在后台下载$downloadKind ${(value * 100).floor()}%，可离开此页');
          }
        },
      );
      final artifact = AndroidUpdateArtifact(
        file: apk,
        sha256: apkHash,
        size: entry['size'] as int,
        build: build,
        version: manifest['version'] as String,
      );
      _manifestFile = manifestFile;
      _androidArtifact = artifact;
      _androidRequest = active;
      progress = 1;
      step = '校验安装包身份与签名';
      if (active.handedOff) {
        await _android.verify(artifact);
        _show('更新已就绪，可重新打开安装器');
      } else {
        await _handoffAndroid(updateRoot, artifact, active);
      }
    } catch (error) {
      if (root != null &&
          await _resolveInstalledAndroidUpdate(error, root, request)) {
        return;
      }
      final packageIssue = androidPackageVerificationIssue(error);
      final canRetryHandoff =
          error is PlatformException && error.code == 'installer_unavailable';
      if (canRetryHandoff && ready) {
        await _discardAndroidDownload(null);
        _show('无法打开 Android 安装器，可重试安装');
        return;
      }
      final keepDownload =
          error is AndroidManagedDownloadFailure && error.reason == 'storage';
      if (error is AndroidManagedDownloadFailure) {
        androidBackgroundDownloadUnavailable = error.reason == 'unavailable';
      }
      if (!keepDownload && request != null && root != null) {
        await _removeAndroidFile(root, 'managed-request');
      }
      _clearAndroidArtifact();
      available = null;
      if (restoring && !manifestReady && installedVersion != null) {
        // A retired channel or expired cached request should not surface as
        // a failed install on launch. An explicit check reads the live channel.
        if (root != null && request != null) {
          await _retireAndroidRequest(root, request);
        }
        _show('当前版本 $installedVersion');
      } else {
        await _discardAndroidDownload(null);
        _show(
          error is AndroidManagedDownloadFailure
              ? error.message
              : packageIssue == null
              ? '更新准备失败（$step），请重新检查'
              : '更新准备失败：$packageIssue',
        );
      }
    } finally {
      _finishUpdateWork();
    }
  }

  Future<int> _androidFloor(int installedBuild) async => max(
    installedBuild + 1,
    int.tryParse(await _secure.read(key: _floorKey) ?? '') ?? installedBuild,
  );

  Future<void> _handoffAndroid(
    Directory root,
    AndroidUpdateArtifact artifact,
    AndroidUpdateRequest request,
  ) async {
    _androidHandoffPending = false;
    _show('正在校验并打开 Android 安装器…');
    await beforeAndroidInstall?.call();
    // A user pressing retry authorizes a new handoff. Remember it before
    // attempting to launch, in case a deferred attempt outlives this process.
    if (request.handedOff) {
      final retry = request.copyWith(handedOff: false);
      await _saveAndroidRequest(root, retry);
      _androidRequest = retry;
    }
    final result = await _android.install(
      artifact,
      systemPermissionPrompt: true,
    );
    switch (result) {
      case AndroidInstallResult.opened:
        final handedOff = request.copyWith(handedOff: true);
        _androidRequest = handedOff;
        await _saveAndroidRequest(root, handedOff);
        _show('已打开 Android 安装器，请在系统界面确认');
      case AndroidInstallResult.deferred:
        _androidHandoffPending = true;
        _show('更新已就绪，返回 WeekGlass 后自动打开安装器');
      case AndroidInstallResult.permissionRequired:
        needsInstallPermission = true;
        _show('Android 需要授权 WeekGlass 安装更新');
    }
  }

  Future<bool> _resolveInstalledAndroidUpdate(
    Object error,
    Directory root,
    AndroidUpdateRequest? request,
  ) async {
    if (error is! PlatformException || error.code != 'already_installed') {
      return false;
    }
    await _retireAndroidRequest(root, request);
    available = null;
    final installed = await _android.info();
    _show('当前版本 ${installed.version}');
    return true;
  }

  Future<void> _installAndroid() async {
    final artifact = _androidArtifact;
    final request = _androidRequest;
    final file = _manifestFile;
    if (busy || artifact == null || request == null || file == null) return;
    busy = true;
    progress = null;
    Directory? root;
    try {
      root = await _root();
      final installed = await _android.info();
      if (artifact.build <= installed.build) {
        await _retireAndroidRequest(root, request);
        available = null;
        _show('当前版本 ${installed.version}');
        return;
      }
      if (needsInstallPermission) {
        await _android.openInstallSettings();
        needsInstallPermission = false;
        _androidHandoffPending = true;
        _show('授权后将继续打开 Android 安装器');
        return;
      }
      _show('正在再次校验安装包…');
      final manifest = await _verifyEnvelope(
        await file.readAsBytes(),
        channel: false,
        floor: await _androidFloor(installed.build),
        platform: _platform,
      );
      final entry = (manifest['files'] as List).single as Map<String, dynamic>;
      if (manifest['build'] != artifact.build ||
          manifest['version'] != artifact.version ||
          entry['sha256'] != artifact.sha256 ||
          entry['size'] != artifact.size) {
        throw const FormatException('安装内容与签名版本不一致');
      }
      await _handoffAndroid(root, artifact, request);
    } catch (error) {
      if (root != null &&
          await _resolveInstalledAndroidUpdate(error, root, request)) {
        return;
      }
      if (error is PlatformException && error.code == 'installer_unavailable') {
        _show('无法打开 Android 安装器，可重试安装');
        return;
      }
      if (error is PlatformException && error.code == 'settings_unavailable') {
        _show('无法打开 Android 安装授权设置，可重试');
        return;
      }
      if (root != null) await _retireAndroidRequest(root, request);
      _clearAndroidArtifact();
      available = null;
      final issue = androidPackageVerificationIssue(error);
      _show(issue == null ? '未能开始安装，请重新检查更新' : '未能开始安装：$issue');
    } finally {
      _finishUpdateWork();
    }
  }

  Future<void> install() async {
    if (isAndroid) return _installAndroid();
    if (busy || _stage == null || _job == null) return;
    busy = true;
    _show('正在保存并重启…');
    var quiesced = false;
    try {
      final floor = max(
        currentBuild,
        int.tryParse(await _secure.read(key: 'weekglass_update_floor') ?? '') ??
            currentBuild,
      );
      final manifest = await verifyUpdateEnvelope(
        await _manifestFile!.readAsBytes(),
        channel: false,
        floor: floor,
      );
      await verifyStagedUpdate(_stage!, manifest);
      final current = File(Platform.resolvedExecutable).parent;
      final helper = File(p.join(current.path, 'weekglass_updater.exe'));
      if (!await helper.exists()) throw const FileSystemException('缺少更新安装器');
      final copy = await helper.copy(
        p.join(_job!.path, 'weekglass_updater.exe'),
      );
      final file = File(p.join(_job!.path, 'job.json'));
      await file.writeAsString(
        jsonEncode({
          'target': current.absolute.path,
          'stage': _stage!.absolute.path,
          'manifest': _manifestFile!.absolute.path,
          'pid': pid,
          'floor': floor,
          'health': p.join(_job!.path, 'boot-ready'),
          'result': p.join(_job!.path, 'result.json'),
        }),
        flush: true,
      );
      await beforeInstall?.call();
      quiesced = true;
      await Process.start(
        copy.path,
        [file.path],
        mode: ProcessStartMode.detached,
        workingDirectory: _job!.path,
      );
      exit(0);
    } catch (_) {
      if (quiesced) await afterInstallFailure?.call();
      busy = false;
      _show('无法启动更新安装器，当前版本未改动');
    }
  }

  static Future<void> completePendingUpdateBoot() async {
    final args = Platform.executableArguments; // Flutter application arguments are supplied separately below.
    await completeUpdateBoot(args);
  }

  static List<String> launchArguments = const [];
  static Future<void> completeUpdateBoot(List<String> args) async {
    final all = [...args, ...launchArguments];
    final values = all
        .where((x) => x.startsWith('--weekglass-update-job='))
        .toList();
    if (values.length != 1) return;
    try {
      final root = await instance._root();
      final file = File(
        values.single.substring('--weekglass-update-job='.length),
      );
      final jobs = p.join(root.absolute.path, 'jobs');
      if (!p.isWithin(jobs, file.absolute.path) ||
          p.basename(file.path) != 'job.json' ||
          await FileSystemEntity.isLink(file.path)) {
        return;
      }
      final job = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (job['target'] !=
              File(Platform.resolvedExecutable).parent.absolute.path ||
          job['health'] != p.join(file.parent.path, 'boot-ready')) {
        return;
      }
      await File(job['health'] as String).writeAsString('ready', flush: true);
    } catch (_) {
      /* An invalid launch hint never changes application files. */
    }
  }
}
