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

import 'accepted_update.dart';
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

typedef LaunchWindowsUpdate = Future<void> Function(File helper, File job);

enum _OpenUpdateCheck { startup, reopen }

/// A signed candidate for this launch, never itself permission to install.
class StartupUpdateOffer {
  const StartupUpdateOffer({required this.version, required this.build});

  final String version;
  final int build;
}

class UpdateService extends ChangeNotifier {
  UpdateService._({
    bool? android,
    this._updateRoot,
    this._fetchMetadata,
    this._verifyEnvelope = verifyUpdateEnvelope,
    this._windowsInstallation,
    this._launchWindowsUpdate = _runWindowsHelper,
    this._origin = updateOrigin,
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

  @visibleForTesting
  UpdateService.windowsForTesting({
    required Directory updateRoot,
    required Directory installation,
    required UpdateEnvelopeVerifier verifyEnvelope,
    required LaunchWindowsUpdate launchInstaller,
    UpdateMetadata? metadata,
    String origin = updateOrigin,
  }) : this._(
         android: false,
         updateRoot: updateRoot,
         windowsInstallation: installation,
         fetchMetadata: metadata,
         verifyEnvelope: verifyEnvelope,
         launchWindowsUpdate: launchInstaller,
         origin: origin,
       );

  static final instance = UpdateService._();
  static const currentVersion = '0.22.8';
  static const currentBuild = 57;
  Future<void> Function()? beforeInstall;
  Future<void> Function()? beforeAndroidInstall;
  Future<void> Function()? afterInstallFailure;

  /// The planner supplies this gate so a new modal or a drag is not cut off.
  bool Function()? canInstallAutomatically;
  bool get _automaticInstallAllowed => canInstallAutomatically?.call() ?? true;
  bool get sealingWindowsInstall => _sealingWindowsInstall;
  bool _sealingWindowsInstall = false;
  bool _windowsAutoInstallPending = false;
  bool _androidRespectsPlanner = false;
  bool _startupChecked = false;
  bool _openCheckInProgress = false;
  _OpenUpdateCheck? _queuedOpenCheck;
  StartupUpdateOffer? _startupOffer;
  StartupUpdateOffer? get startupOffer => _startupOffer;
  List<int>? _checkedChannel;
  AcceptedUpdate? _activeAcceptance;
  bool get canRetryAcceptedUpdate => _activeAcceptance != null && !ready;

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
  bool _resumeWhenIdle = false;
  bool needsInstallPermission = false;
  bool androidBackgroundDownloadUnavailable = false;
  bool get supportsUpdates =>
      Platform.isWindows || isAndroid || _windowsInstallation != null;
  final bool isAndroid;
  bool get ready => isAndroid ? _androidArtifact != null : _stage != null;
  String get _platform => isAndroid ? 'android-arm64' : 'windows-x64';
  String get _floorKey => isAndroid
      ? 'weekglass_update_floor_android_arm64'
      : 'weekglass_update_floor';
  String get _skipKey => 'weekglass_skipped_update_$_platform';

  final _android = const AndroidUpdateBridge();
  final _secure = const FlutterSecureStorage();
  final Directory? _updateRoot;
  final UpdateMetadata? _fetchMetadata;
  final UpdateEnvelopeVerifier _verifyEnvelope;
  final Directory? _windowsInstallation;
  final LaunchWindowsUpdate _launchWindowsUpdate;
  final String _origin;
  Directory get _installation =>
      _windowsInstallation ?? File(Platform.resolvedExecutable).parent;

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
      final request = await http.getUrl(Uri.parse(_origin).resolve(relative));
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
      if (response.statusCode == 404 || response.statusCode == 410) {
        throw const FormatException('更新信息已撤回');
      }
      if (response.contentLength > limit) {
        throw const FormatException('更新信息过大');
      }
      if (response.statusCode != 200) {
        throw const HttpException('无法读取更新信息');
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        bytes.addAll(chunk);
        if (bytes.length > limit) throw const FormatException('更新信息过大');
      }
      if (cache != null) {
        final partial = await updateChild(
          cache.parent,
          '${p.basename(cache.path)}.partial',
        );
        await partial.writeAsBytes(bytes, flush: true);
        await partial.rename(cache.path);
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

  Future<void> _runUpdateWork(Future<void> Function() work) async {
    if (busy || !supportsUpdates) return;
    busy = true;
    try {
      await work();
    } finally {
      _finishUpdateWork();
    }
  }

  Future<void> check() => _runUpdateWork(() => _check(startup: false));

  /// Resume an already authorized job first. A normal startup reaches only
  /// the stable channel (ETag and signed cached body), not the manifest or APK.
  Future<void> checkOnStartup() async {
    if (_startupChecked || !supportsUpdates) return;
    _queuedOpenCheck = _OpenUpdateCheck.startup;
    await _runQueuedOpenCheck();
  }

  /// The Windows tray and shortcuts can open the same process again. Check
  /// again without resuming a job already owned by that process.
  Future<void> checkOnWindowsReopen() async {
    // The first planner frame handles activations during startup.
    if (isAndroid || !_startupChecked || _openCheckInProgress) return;
    _queuedOpenCheck ??= _OpenUpdateCheck.reopen;
    await _runQueuedOpenCheck();
  }

  Future<void> _runQueuedOpenCheck() async {
    final check = _queuedOpenCheck;
    if (busy || check == null) return;
    _queuedOpenCheck = null;
    final startup = check == _OpenUpdateCheck.startup;
    if (startup) {
      _startupChecked = true;
    } else if (_startupOffer != null || ready || _activeAcceptance != null) {
      // Keep the displayed choice, staged files, or accepted job intact.
      return;
    }
    await _runUpdateWork(() async {
      _openCheckInProgress = true;
      try {
        await _check(startup: startup, reopening: !startup);
      } finally {
        _openCheckInProgress = false;
      }
    });
  }

  Future<void> _check({required bool startup, bool reopening = false}) async {
    final manuallyAvailableBuild = reopening ? (available?['build']) : null;
    _startupOffer = null;
    _checkedChannel = null;
    progress = null;
    androidBackgroundDownloadUnavailable = false;
    _show('正在检查更新…');
    var step = '读取设备信息';
    Directory? root;
    int? resolvedBuild;
    String? resolvedMessage;
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
      final updateRoot = root = await _root();
      final pending = device == null
          ? null
          : await _readPendingAndroidRequest(updateRoot, device);
      if (startup) {
        step = '读取已接受的更新';
        final accepted = await AcceptedUpdate.read(updateRoot);
        if (accepted != null && accepted.build > installedBuild) {
          _activeAcceptance = accepted;
          await _continueAcceptedUpdate(
            accepted,
            restoring: true,
            existingRoot: updateRoot,
            existingInfo: device,
            existingRequest: pending,
          );
          final wasHandedOff =
              pending?.handedOff == true && _androidRequest?.handedOff == true;
          if (_activeAcceptance != null && !wasHandedOff) return;
          // The installer was already presented or the old job terminated.
          // Keep its status for this build, but let a new release be offered.
          resolvedBuild = accepted.build;
          resolvedMessage = message;
        } else {
          if (accepted != null) await AcceptedUpdate.clear(updateRoot);
          if (device != null && pending != null) {
            if (await _downloadAndroid(
              restoring: true,
              existingRoot: updateRoot,
              existingInfo: device,
              existingRequest: pending,
            )) {
              if (!pending.handedOff || _androidRequest?.handedOff != true) {
                return;
              }
              resolvedBuild = pending.build;
              resolvedMessage = message;
            }
          }
        }
      }
      step = '读取更新记录';
      final floor = await _updateFloor(installedBuild);
      step = '下载更新信息';
      final bytes = await _metadata(
        'channels/$_platform/stable.json',
        16384,
        cache: await updateChild(updateRoot, 'channel.json'),
      );
      step = '校验更新信息';
      final channel = await _verifyEnvelope(
        bytes,
        channel: true,
        floor: floor,
        platform: _platform,
      );
      step = '保存更新记录';
      final build = channel['build'] as int;
      await _secure.write(key: _floorKey, value: '$build');
      if (resolvedBuild != null) {
        if (build <= resolvedBuild) {
          _show(resolvedMessage!);
          return;
        }
        if (device != null && _androidRequest != null) {
          // The system installer may still own a URI for this verified APK.
          await _retireAndroidRequest(
            updateRoot,
            _androidRequest,
            purgeFiles: false,
          );
        }
        if (_activeAcceptance != null) await _forgetAcceptance(updateRoot);
        if (!isAndroid) _clearWindowsStage();
      }
      available = build > installedBuild ? channel : null;
      _checkedChannel = available == null ? null : bytes;
      if (device != null && _androidArtifact?.build != available?['build']) {
        _clearAndroidArtifact();
      }
      final version = channel['version'] as String;
      if ((startup || reopening) && available != null && !ready) {
        if (await _secure.read(key: _skipKey) == '$build') {
          // A background reopen must not take away a skipped build that the
          // user explicitly found again in Settings.
          if (manuallyAvailableBuild != build) {
            _hideSkippedVersion(version);
            return;
          }
        } else {
          _startupOffer = StartupUpdateOffer(version: version, build: build);
        }
      }
      _show(available == null ? '已是最新版本 $installedVersion' : '发现新版本 $version');
    } catch (_) {
      if (startup && step == '读取已接受的更新' && root != null) {
        await _forgetAcceptance(root);
      }
      if (!ready) available = null;
      _show(resolvedMessage ?? '检查更新失败（$step），请稍后重试；版本或签名异常时不会安装');
    }
  }

  Future<void> skipStartupVersion(StartupUpdateOffer offer) =>
      _runUpdateWork(() async {
        if (!identical(offer, _startupOffer)) return;
        _startupOffer = null;
        try {
          await _secure.write(key: _skipKey, value: '${offer.build}');
          _hideSkippedVersion(offer.version);
        } catch (_) {
          _show('未能记住跳过的版本，仍可在设置中检查更新');
        }
      });

  void _hideSkippedVersion(String version) {
    available = null;
    _checkedChannel = null;
    _show('已跳过版本 $version');
  }

  Future<void> acceptStartupUpdate(StartupUpdateOffer offer) =>
      _runUpdateWork(() async {
        final bytes = _checkedChannel;
        if (!identical(offer, _startupOffer) || bytes == null) return;
        _startupOffer = null;
        final accepted = AcceptedUpdate.newJob(offer.build, bytes);
        try {
          await accepted.save(await _root());
          _activeAcceptance = accepted;
        } catch (_) {
          _show('未能保存更新任务，请在设置中重试');
          return;
        }
        await _continueAcceptedUpdate(accepted);
      });

  Future<void> retryAcceptedUpdate() => _runUpdateWork(() async {
    final accepted = _activeAcceptance;
    if (accepted != null && !ready) {
      await _continueAcceptedUpdate(accepted, restoring: true);
    }
  });

  Future<void> _continueAcceptedUpdate(
    AcceptedUpdate accepted, {
    bool restoring = false,
    Directory? existingRoot,
    AndroidUpdateInfo? existingInfo,
    AndroidUpdateRequest? existingRequest,
  }) async {
    if (isAndroid) {
      await _downloadAndroid(
        accepted: accepted,
        restoring: restoring,
        existingRoot: existingRoot,
        existingInfo: existingInfo,
        existingRequest: existingRequest,
      );
    } else {
      await _downloadWindows(accepted: accepted, restoring: restoring);
      if (_windowsAutoInstallPending) {
        await _installWindows(automatic: true);
      }
    }
  }

  bool _interruptedTransfer(Object error) =>
      error is SocketException ||
      error is TimeoutException ||
      error is HttpException;

  Future<void> _forgetAcceptance(Directory root) async {
    _activeAcceptance = null;
    try {
      await AcceptedUpdate.clear(root);
    } on FileSystemException {
      // A write-protected update directory should leave the failure visible.
    } on FormatException {
      // Do not cross links to remove an update receipt.
    }
  }

  Future<int> _updateFloor(int installedBuild) async => max(
    installedBuild,
    int.tryParse(await _secure.read(key: _floorKey) ?? '') ?? installedBuild,
  );

  Future<Map<String, dynamic>> _acceptedChannel(
    AcceptedUpdate accepted,
    int floor,
  ) async {
    final channel = await _verifyEnvelope(
      accepted.channel,
      channel: true,
      floor: floor,
      platform: _platform,
    );
    if (channel['build'] != accepted.build) {
      throw const FormatException('更新任务与签名版本不一致');
    }
    return channel;
  }

  Future<File> _object(Directory cache, Map<String, dynamic> descriptor) {
    final digest = descriptor['sha256'] as String;
    return downloadUpdateObject(
      uri: Uri.parse('${_origin}objects/${digest.substring(0, 2)}/$digest'),
      cacheFile: File(p.join(cache.path, digest)),
      digest: digest,
      size: descriptor['size'] as int,
    );
  }

  Future<void> download() => _runUpdateWork(() async {
    if (available == null || ready) return;
    _startupOffer = null;
    if (isAndroid) {
      await _downloadAndroid();
    } else {
      await _downloadWindows();
    }
  });

  Future<void> _downloadWindows({
    AcceptedUpdate? accepted,
    bool restoring = false,
  }) async {
    progress = 0;
    _show(restoring ? '正在恢复更新…' : '正在准备增量更新…');
    Directory? staging;
    Directory? root;
    var step = '读取更新目录';
    try {
      final updateRoot = root = await _root();
      final nonce =
          accepted?.jobId ??
          '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}';
      final manifestFile = await updateChild(
        updateRoot,
        'jobs/$nonce/manifest.json',
      );
      final job = manifestFile.parent;
      if (restoring && await (await updateChild(job, 'result.json')).exists()) {
        // The detached helper already attempted this job. A restored copy of
        // the old app must not automatically repeat a failed installation.
        await _forgetAcceptance(updateRoot);
        available = null;
        _show('上次更新安装未完成，请重新检查更新');
        return;
      }
      final current = _installation;
      final floor = await _updateFloor(currentBuild + 1);
      step = '校验更新信息';
      final channel = accepted == null
          ? await _verifyEnvelope(
              _checkedChannel ??
                  await (await updateChild(
                    updateRoot,
                    'channel.json',
                  )).readAsBytes(),
              channel: true,
              floor: floor,
              platform: _platform,
            )
          : await _acceptedChannel(accepted, floor);
      final targetBuild = channel['build'] as int;
      if (accepted == null && targetBuild != available?['build']) {
        throw const FormatException('更新版本不匹配');
      }
      available = channel;

      final descriptor = channel['manifest'] as Map<String, dynamic>;
      step = '读取更新清单';
      final manifestBytes = restoring && await manifestFile.exists()
          ? await manifestFile.readAsBytes()
          : await _metadata(descriptor['path'] as String, 4194304);
      step = '校验更新清单';
      if (manifestBytes.length != descriptor['size'] ||
          sha256(manifestBytes) != descriptor['sha256']) {
        throw const FormatException('更新清单不匹配');
      }
      final manifest = await _verifyEnvelope(
        manifestBytes,
        channel: false,
        floor: targetBuild,
        platform: _platform,
      );
      if (manifest['build'] != targetBuild ||
          manifest['version'] != channel['version']) {
        throw const FormatException('更新版本不匹配');
      }

      step = '准备更新目录';
      final stageName = '.weekglass-stage-$nonce';
      staging = Directory((await updateChild(current.parent, stageName)).path);
      await staging.create(recursive: true);
      await job.create(recursive: true);
      if (!restoring || !await manifestFile.exists()) {
        final partial = await updateChild(job, 'manifest.partial');
        await partial.writeAsBytes(manifestBytes, flush: true);
        await partial.rename(manifestFile.path);
      }

      final cache = Directory((await updateChild(updateRoot, 'objects')).path);
      await cache.create(recursive: true);
      final entries = (manifest['files'] as List).cast<Map<String, dynamic>>();
      var done = 0;
      step = '下载并重建更新';
      for (final entry in entries) {
        final name = entry['path'] as String;
        final output = await updateChild(staging, name);
        final expectedSize = entry['size'] as int;
        final expectedHash = entry['sha256'] as String;
        if (!restoring ||
            !await output.exists() ||
            await output.length() != expectedSize ||
            await fileSha256(output) != expectedHash) {
          final old = await updateChild(current, name);
          final sourceSize = await old.exists() ? await old.length() : null;
          final sourceHash =
              sourceSize != null && sourceSize <= maximumUpdateFile
              ? await fileSha256(old)
              : null;
          await output.parent.create(recursive: true);
          if (sourceHash == expectedHash && sourceSize == expectedSize) {
            await old.copy(output.path);
          } else {
            final selected = smallestUpdateObject(
              entry,
              baseSha256: sourceHash,
              baseSize: sourceSize,
            );
            final object = await _object(cache, selected);
            final encoding = selected['encoding'] as String;
            final result = await decodeUpdateObjectInBackground(
              await object.readAsBytes(),
              encoding,
              expectedSize,
              encoding == 'bsdiff4' ? await old.readAsBytes() : null,
            );
            if (result.length != expectedSize ||
                sha256(result) != expectedHash) {
              throw const FormatException('更新重建校验失败');
            }
            await output.writeAsBytes(result, flush: true);
          }
        }
        progress = ++done / entries.length;
        _show('正在准备更新 $done / ${entries.length}');
      }
      step = '校验更新文件';
      await verifyStagedUpdate(staging, manifest);
      _stage = staging;
      _job = job;
      _manifestFile = manifestFile;
      _windowsAutoInstallPending = accepted != null;
      _show('更新已就绪，重启后完成安装');
    } catch (error) {
      final resumable = accepted != null && _interruptedTransfer(error);
      // Only remove the exact staging folder created above, never the
      // installation, helper recovery directories, or resumable objects.
      if (!resumable && staging != null && !isUpdateLink(staging.path)) {
        try {
          if (await staging.exists()) await staging.delete(recursive: true);
        } on FileSystemException {
          // The damaged staging directory is not used for a new job.
        }
      }
      if (accepted != null && root != null && !resumable) {
        await _forgetAcceptance(root);
      }
      available = null;
      _clearWindowsStage();
      _show(
        resumable
            ? '连接中断（$step），可重试并继续已接受的更新'
            : '更新准备失败（$step），请重新检查；已下载内容会复用，原版本保持可用',
      );
    }
  }

  void _clearWindowsStage() {
    _stage = null;
    _job = null;
    _manifestFile = null;
    _windowsAutoInstallPending = false;
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
    _androidRespectsPlanner = false;
    needsInstallPermission = false;
  }

  void _watchAndroidForeground() {
    _androidLifecycle ??= AppLifecycleListener(
      onResume: resumePendingInstallation,
    );
  }

  void _finishUpdateWork() {
    busy = false;
    final retry = _resumeWhenIdle;
    _resumeWhenIdle = false;
    notifyListeners();
    if (retry) resumePendingInstallation();
    if (_queuedOpenCheck != null) unawaited(_runQueuedOpenCheck());
  }

  /// Called by the planner when it has no modal or gesture in progress.
  /// Neither a failed handoff nor a cancelled system installer retries here.
  void resumePendingInstallation() {
    if (busy) {
      _resumeWhenIdle = true;
      return;
    }
    if (isAndroid) {
      if (_androidHandoffPending &&
          (!_androidRespectsPlanner || _automaticInstallAllowed) &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        unawaited(_runUpdateWork(() => _installAndroid(automatic: true)));
      }
    } else if (_windowsAutoInstallPending && _automaticInstallAllowed) {
      unawaited(_runUpdateWork(() => _installWindows(automatic: true)));
    }
  }

  @override
  void dispose() {
    _androidLifecycle?.dispose();
    super.dispose();
  }

  Future<void> restoreAndroidDownload() => _runUpdateWork(() async {
    if (isAndroid) await _downloadAndroid(restoring: true);
  });

  /// Returns false for an obsolete or absent legacy request; a startup can
  /// then check the live channel normally.
  Future<bool> _downloadAndroid({
    bool restoring = false,
    AcceptedUpdate? accepted,
    Directory? existingRoot,
    AndroidUpdateInfo? existingInfo,
    AndroidUpdateRequest? existingRequest,
  }) async {
    _watchAndroidForeground();
    _androidRespectsPlanner = restoring || accepted != null;
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
      final info = existingInfo ?? await _android.info();
      installedVersion = info.version;
      if (!info.arm64) {
        available = null;
        _show('当前版本 ${info.version}；此设备暂不支持应用内更新');
        return true;
      }
      step = '读取更新目录';
      final updateRoot = root = existingRoot ?? await _root();
      request =
          existingRequest ?? await _readPendingAndroidRequest(updateRoot, info);
      if (restoring && accepted == null && request == null) {
        if (available == null && !ready) _show('当前版本 ${info.version}');
        return false;
      }
      step = '读取更新记录';
      final floor = await _androidFloor(info.build);
      step = '校验更新信息';
      final channel = accepted != null
          ? await _acceptedChannel(accepted, floor)
          : await _verifyEnvelope(
              restoring
                  ? await (await updateChild(
                      updateRoot,
                      'channel.json',
                    )).readAsBytes()
                  : _checkedChannel ??
                        await (await updateChild(
                          updateRoot,
                          'channel.json',
                        )).readAsBytes(),
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
      if (restoring && accepted == null && request == null) {
        _show('当前版本 ${info.version}');
        return false;
      }
      _androidRespectsPlanner = restoring || accepted != null;
      if (restoring) _show('正在恢复 Android 更新…');
      final manifests = Directory(p.join(updateRoot.path, 'manifests'));
      final manifestFile = await updateChild(
        updateRoot,
        'manifests/$manifestHash.json',
      );
      await manifests.create(recursive: true);
      step = '下载更新清单';
      final useSavedManifest =
          restoring && (accepted == null || await manifestFile.exists());
      final bytes = useSavedManifest
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
          if (restoring && accepted == null && active.objectHash != hash) {
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
            // The accepted operation may have stopped before enqueueing.
            // DownloadManager matches and reuses the exact existing row first.
            start: !restoring || accepted != null,
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
        await _handoffAndroid(
          updateRoot,
          artifact,
          active,
          respectPlanner: _androidRespectsPlanner,
        );
      }
    } catch (error) {
      if (root != null &&
          await _resolveInstalledAndroidUpdate(error, root, request)) {
        return false;
      }
      final packageIssue = androidPackageVerificationIssue(error);
      final canRetryHandoff =
          error is PlatformException && error.code == 'installer_unavailable';
      if (canRetryHandoff && ready) {
        await _discardAndroidDownload(null);
        _show('无法打开 Android 安装器，可重试安装');
        return true;
      }
      final keepDownload =
          error is AndroidManagedDownloadFailure && error.reason == 'storage';
      final resumable =
          accepted != null && (keepDownload || _interruptedTransfer(error));
      if (error is AndroidManagedDownloadFailure) {
        androidBackgroundDownloadUnavailable = error.reason == 'unavailable';
      }
      final failedRequest = request;
      if (!keepDownload &&
          !resumable &&
          failedRequest != null &&
          root != null) {
        await _removeAndroidFile(root, 'managed-request');
        await _discardAndroidDownload(failedRequest.objectHash);
      }
      if (accepted != null && root != null && !resumable) {
        await _forgetAcceptance(root);
      }
      _clearAndroidArtifact();
      available = null;
      if (restoring &&
          accepted == null &&
          !manifestReady &&
          installedVersion != null) {
        // A retired channel or expired cached request should not surface as
        // a failed install on launch. An explicit check reads the live channel.
        if (root != null && request != null) {
          await _retireAndroidRequest(root, request);
        }
        _show('当前版本 $installedVersion');
        return false;
      } else {
        await _discardAndroidDownload(null);
        _show(
          error is AndroidManagedDownloadFailure
              ? error.message
              : resumable
              ? '连接中断（$step），可重试并继续已接受的更新'
              : packageIssue == null
              ? '更新准备失败（$step），请重新检查'
              : '更新准备失败：$packageIssue',
        );
      }
    }
    return true;
  }

  Future<int> _androidFloor(int installedBuild) =>
      _updateFloor(installedBuild + 1);

  bool _waitForAndroidPlanner(bool respectPlanner) {
    if (!respectPlanner || _automaticInstallAllowed) return false;
    _androidHandoffPending = true;
    _show('更新已就绪，当前操作完成后打开 Android 安装器');
    return true;
  }

  Future<void> _handoffAndroid(
    Directory root,
    AndroidUpdateArtifact artifact,
    AndroidUpdateRequest request, {
    required bool respectPlanner,
  }) async {
    if (_waitForAndroidPlanner(respectPlanner)) return;
    _androidHandoffPending = false;
    _show('正在校验并打开 Android 安装器…');
    await beforeAndroidInstall?.call();
    if (_waitForAndroidPlanner(respectPlanner)) return;
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
    if (_activeAcceptance != null) await _forgetAcceptance(root);
    available = null;
    final installed = await _android.info();
    _show('当前版本 ${installed.version}');
    return true;
  }

  Future<void> _installAndroid({bool automatic = false}) async {
    final artifact = _androidArtifact;
    final request = _androidRequest;
    final file = _manifestFile;
    if (artifact == null || request == null || file == null) return;
    if (!automatic) _androidRespectsPlanner = false;
    progress = null;
    Directory? root;
    try {
      root = await _root();
      final installed = await _android.info();
      if (artifact.build <= installed.build) {
        await _retireAndroidRequest(root, request);
        if (_activeAcceptance != null) await _forgetAcceptance(root);
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
      await _handoffAndroid(
        root,
        artifact,
        request,
        respectPlanner: _androidRespectsPlanner,
      );
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
      if (root != null) {
        await _retireAndroidRequest(root, request);
        if (_activeAcceptance != null) await _forgetAcceptance(root);
      }
      _clearAndroidArtifact();
      available = null;
      final issue = androidPackageVerificationIssue(error);
      _show(issue == null ? '未能开始安装，请重新检查更新' : '未能开始安装：$issue');
    }
  }

  Future<void> install() =>
      _runUpdateWork(isAndroid ? _installAndroid : _installWindows);

  bool _waitForWindowsPlanner(bool automatic) {
    if (!automatic || _automaticInstallAllowed) return false;
    _show('更新已就绪，当前操作完成后自动重启更新');
    return true;
  }

  Future<void> _installWindows({bool automatic = false}) async {
    final stage = _stage, job = _job, manifestFile = _manifestFile;
    if (stage == null ||
        job == null ||
        manifestFile == null ||
        _waitForWindowsPlanner(automatic)) {
      return;
    }
    _show('正在核对安装文件…');
    var quiesced = false;
    var stageVerified = false;
    var step = '校验更新文件';
    try {
      final floor = await _updateFloor(currentBuild + 1);
      final manifest = await _verifyEnvelope(
        await manifestFile.readAsBytes(),
        channel: false,
        floor: floor,
        platform: _platform,
      );
      await verifyStagedUpdate(stage, manifest);
      stageVerified = true;
      step = '准备更新安装器';
      final current = _installation;
      final helper = File(p.join(current.path, 'weekglass_updater.exe'));
      if (!await helper.exists()) throw const FileSystemException('缺少更新安装器');
      final copy = await helper.copy(
        (await updateChild(job, 'weekglass_updater.exe')).path,
      );
      final file = await updateChild(job, 'job.json');
      await file.writeAsString(
        jsonEncode({
          'target': current.absolute.path,
          'stage': stage.absolute.path,
          'manifest': manifestFile.absolute.path,
          'pid': pid,
          'floor': floor,
          'health': p.join(job.path, 'boot-ready'),
          'result': p.join(job.path, 'result.json'),
        }),
        flush: true,
      );
      // Another dialog may have opened while the stage was verified.
      if (_waitForWindowsPlanner(automatic)) return;
      step = '保存日程和设置';
      _sealingWindowsInstall = automatic;
      _show('正在保存并重启…');
      quiesced = beforeInstall != null;
      await beforeInstall?.call();
      if (_waitForWindowsPlanner(automatic)) {
        if (quiesced) await afterInstallFailure?.call();
        return;
      }
      step = '启动更新安装器';
      _windowsAutoInstallPending = false;
      await _launchWindowsUpdate(copy, file);
    } catch (_) {
      _windowsAutoInstallPending = false;
      if (_activeAcceptance != null) {
        await _forgetAcceptance(job.parent.parent);
      }
      if (!stageVerified) {
        available = null;
        _clearWindowsStage();
      }
      _show('更新失败（$step），当前版本未改动');
      if (quiesced) await afterInstallFailure?.call();
    } finally {
      _sealingWindowsInstall = false;
    }
  }

  static Future<void> _runWindowsHelper(File helper, File job) async {
    await Process.start(
      helper.path,
      [job.path],
      mode: ProcessStartMode.detached,
      workingDirectory: job.parent.path,
    );
    exit(0);
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
