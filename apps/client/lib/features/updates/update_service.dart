import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'android_update_bridge.dart';
import 'update_object_download.dart';
import 'update_protocol.dart';
import 'update_reconstruction.dart';

class UpdateService extends ChangeNotifier {
  UpdateService._();
  static final instance = UpdateService._();
  static const currentVersion = '0.20.12';
  static const currentBuild = 36;
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
  bool needsInstallPermission = false;
  bool androidBackgroundDownloadUnavailable = false;
  bool get supportsUpdates => Platform.isWindows || Platform.isAndroid;
  bool get isAndroid => Platform.isAndroid;
  bool get ready =>
      Platform.isAndroid ? _androidArtifact != null : _stage != null;
  String get _platform => Platform.isAndroid ? 'android-arm64' : 'windows-x64';
  String get _floorKey => Platform.isAndroid
      ? 'weekglass_update_floor_android_arm64'
      : 'weekglass_update_floor';
  final _android = const AndroidUpdateBridge();
  final _secure = const FlutterSecureStorage();

  Future<Directory> _root() async => Directory(
    p.join(
      (await getApplicationSupportDirectory()).path,
      'updates',
      Platform.isAndroid ? 'android-arm64' : '',
    ),
  )..createSync(recursive: true);
  void _show(String value) {
    message = value;
    notifyListeners();
  }

  Future<List<int>> _metadata(String relative, int limit, {File? cache}) async {
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
      if (Platform.isAndroid && !(await _android.info()).arm64) {
        available = null;
        _show('当前版本 $currentVersion；此设备暂不支持应用内更新');
        return;
      }
      step = '读取更新目录';
      final root = await _root();
      step = '读取更新记录';
      final floor = max(
        currentBuild,
        int.tryParse(await _secure.read(key: _floorKey) ?? '') ?? currentBuild,
      );
      step = '下载更新信息';
      final bytes = await _metadata(
        'channels/$_platform/stable.json',
        16384,
        cache: File(p.join(root.path, 'channel.json')),
      );
      step = '校验更新信息';
      final channel = await verifyUpdateEnvelope(
        bytes,
        channel: true,
        floor: floor,
        platform: _platform,
      );
      step = '保存更新记录';
      await _secure.write(key: _floorKey, value: '${channel['build']}');
      available = (channel['build'] as int) > currentBuild ? channel : null;
      if (Platform.isAndroid &&
          _androidArtifact?.build != available?['build']) {
        _androidArtifact = null;
        needsInstallPermission = false;
      }
      _show(
        available == null
            ? '已是最新版本 $currentVersion'
            : '发现新版本 ${channel['version']}',
      );
    } catch (_) {
      _show(
        Platform.isAndroid
            ? '检查更新失败（$step），请稍后重试；版本或签名异常时不会安装'
            : '暂时无法检查更新，请稍后重试；版本或签名异常时不会安装',
      );
    } finally {
      busy = false;
      notifyListeners();
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
    if (Platform.isAndroid) return _downloadAndroid();
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

  Future<void> restoreAndroidDownload() async {
    if (!Platform.isAndroid || busy) return;
    await _downloadAndroid(restoring: true);
  }

  Future<void> _downloadAndroid({bool restoring = false}) async {
    busy = true;
    progress = null;
    needsInstallPermission = false;
    androidBackgroundDownloadUnavailable = false;
    if (!restoring) _show('正在核对 Android 更新…');
    var step = '读取更新目录';
    var downloadKind = '完整安装包（arm64）';
    File? marker;
    var retainMarker = false;
    try {
      final root = await _root();
      final savedRequest = File(p.join(root.path, 'managed-request'));
      if (restoring && !await savedRequest.exists()) return;
      marker = savedRequest;
      final saved = restoring
          ? (await marker.readAsString()).split('\n')
          : null;
      step = '读取设备信息';
      final info = await _android.info();
      if (!info.arm64) throw const FormatException('不支持此设备架构');
      step = '读取更新记录';
      final floor = max(
        restoring ? currentBuild : currentBuild + 1,
        int.tryParse(await _secure.read(key: _floorKey) ?? '') ?? currentBuild,
      );
      step = '校验更新信息';
      final channel = await verifyUpdateEnvelope(
        await File(p.join(root.path, 'channel.json')).readAsBytes(),
        channel: true,
        floor: floor,
        platform: _platform,
      );
      if (restoring && channel['build'] == currentBuild) return;
      if (restoring) _show('正在恢复 Android 更新…');
      final descriptor = channel['manifest'] as Map<String, dynamic>;
      if (saved != null &&
          (saved.length != 2 || saved.first != descriptor['sha256'])) {
        throw const AndroidManagedDownloadFailure('missing');
      }
      final manifests = Directory(p.join(root.path, 'manifests'));
      await manifests.create(recursive: true);
      final manifestFile = File(
        p.join(manifests.path, '${descriptor['sha256']}.json'),
      );
      step = '下载更新清单';
      final bytes = restoring
          ? await manifestFile.readAsBytes()
          : await _metadata(
              descriptor['path'] as String,
              4194304,
              cache: manifestFile,
            );
      step = '校验更新清单';
      if (bytes.length != descriptor['size'] ||
          sha256(bytes) != descriptor['sha256']) {
        throw const FormatException('更新清单不匹配');
      }
      final manifest = await verifyUpdateEnvelope(
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
      step = '准备更新目录';
      final apks = Directory(p.join(root.path, 'apks'));
      await apks.create(recursive: true);
      final apk = await updateChild(apks, '${entry['sha256']}.apk');
      final cache = Directory(p.join(root.path, 'objects'));
      await cache.create(recursive: true);
      AndroidObjectDownloadState? lastState;
      await prepareAndroidUpdateFile(
        entry: entry,
        sourceApkPath: info.sourceApk.path,
        outputApkPath: apk.path,
        resumeObject: saved?.last,
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
          if (restoring && saved?.last != hash) {
            throw const AndroidManagedDownloadFailure('missing');
          }
          if (!restoring) {
            // The app resumes only the signed object the user asked it to download.
            final nextMarker = File('${savedRequest.path}.partial');
            await nextMarker.writeAsString(
              '${descriptor['sha256']}\n$hash',
              flush: true,
            );
            await nextMarker.rename(savedRequest.path);
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
                    _show('等待网络 · 恢复后继续下载');
                  case AndroidObjectDownloadState.waitingWifi:
                    _show('等待 Wi‑Fi · 连接后继续下载');
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
            _show('正在后台下载$downloadKind ${(value * 100).floor()}% · 可以离开此页');
          }
        },
      );
      final artifact = AndroidUpdateArtifact(
        file: apk,
        sha256: entry['sha256'] as String,
        size: entry['size'] as int,
        build: manifest['build'] as int,
        version: manifest['version'] as String,
      );
      step = '校验安装包身份与签名';
      _show('正在由 Android 校验安装包身份与签名…');
      await _android.verify(artifact);
      _manifestFile = manifestFile;
      _androidArtifact = artifact;
      retainMarker = true;
      progress = 1;
      _show('更新已校验，点击安装后由 Android 系统确认');
    } catch (error) {
      final packageIssue = androidPackageVerificationIssue(error);
      if (error is AndroidManagedDownloadFailure) {
        androidBackgroundDownloadUnavailable = error.reason == 'unavailable';
        retainMarker = error.reason == 'storage';
      }
      _androidArtifact = null;
      _manifestFile = null;
      available = null;
      _show(
        error is AndroidManagedDownloadFailure
            ? error.message
            : packageIssue == null
            ? '更新准备失败（$step），请重新检查'
            : '更新准备失败：$packageIssue',
      );
    } finally {
      if (!retainMarker && marker != null) {
        try {
          if (await marker.exists()) await marker.delete();
        } on FileSystemException {
          // Stale local bookkeeping cannot block future checks or install.
        }
      }
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _installAndroid() async {
    final artifact = _androidArtifact;
    if (busy || artifact == null || _manifestFile == null) return;
    busy = true;
    progress = null;
    var step = '读取更新记录';
    try {
      if (needsInstallPermission) {
        step = '打开安装授权设置';
        await _android.openInstallSettings();
        needsInstallPermission = false;
        _show('允许后返回此处，再点击“安装更新”；也可以选择稍后安装');
        return;
      }
      _show('正在再次校验安装包…');
      final floor = max(
        currentBuild + 1,
        int.tryParse(await _secure.read(key: _floorKey) ?? '') ?? currentBuild,
      );
      step = '重新校验更新清单';
      final manifest = await verifyUpdateEnvelope(
        await _manifestFile!.readAsBytes(),
        channel: false,
        floor: floor,
        platform: _platform,
      );
      final entry = (manifest['files'] as List).single as Map<String, dynamic>;
      if (manifest['build'] != artifact.build ||
          manifest['version'] != artifact.version ||
          entry['sha256'] != artifact.sha256 ||
          entry['size'] != artifact.size) {
        throw const FormatException('安装内容与签名版本不一致');
      }
      step = '保存日程';
      await beforeAndroidInstall?.call();
      step = '打开 Android 安装器';
      final result = await _android.install(artifact);
      needsInstallPermission =
          result == AndroidInstallResult.permissionRequired;
      _show(
        needsInstallPermission
            ? 'Android 尚未允许 WeekGlass 安装更新；点击下方按钮可前往系统设置'
            : '已打开系统安装器；如取消，可再次点击“安装更新”',
      );
    } catch (error) {
      if (error is PlatformException) {
        step = switch (error.code) {
          'invalid_apk' => androidPackageVerificationIssue(error)!,
          'installer_unavailable' => '打开 Android 安装器',
          'settings_unavailable' => '打开安装授权设置',
          _ => step,
        };
      }
      _androidArtifact = null;
      available = null;
      needsInstallPermission = false;
      _show('未能开始安装（$step）；请重新检查更新，当前版本保持可用');
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> install() async {
    if (Platform.isAndroid) return _installAndroid();
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
