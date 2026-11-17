import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:weekglass/features/updates/accepted_update.dart';
import 'package:weekglass/features/updates/update_service.dart';

import 'support/windows_startup_feed.dart';

void main() {
  late WindowsStartupFeed feed;
  late Directory sandbox;
  late Directory root;
  late Directory installation;
  late HttpServer server;
  late List<(String, String?)> requests;
  late List<String> sequence;
  var failHealth = false;
  void Function(HttpRequest)? objectResponse;

  UpdateService client() {
    final service =
        UpdateService.windowsForTesting(
            updateRoot: root,
            installation: installation,
            origin: 'http://127.0.0.1:${server.port}/',
            verifyEnvelope: feed.verify,
            launchInstaller: (helper, job) async {
              sequence.add('launcher');
              expect(await helper.readAsBytes(), feed.helper);
              final data =
                  jsonDecode(await job.readAsString()) as Map<String, dynamic>;
              expect(data['target'], installation.absolute.path);
              expect(data['pid'], pid);
              final stage = Directory(data['stage'] as String);
              expect(p.dirname(stage.path), installation.parent.path);
              expect(
                p.basename(stage.path),
                '.weekglass-stage-${p.basename(job.parent.path)}',
              );
              expect(
                await File(p.join(stage.path, 'weekglass.exe')).readAsBytes(),
                feed.executable,
              );
              if (failHealth) {
                throw const FileSystemException('launch unavailable');
              }
            },
          )
          ..beforeInstall = () async {
            sequence.add('save & close');
          }
          ..afterInstallFailure = () async {
            sequence.add('resume');
          };
    addTearDown(service.dispose);
    return service;
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    feed = WindowsStartupFeed();
    sandbox = await Directory.systemTemp.createTemp(
      'weekglass-windows-update-',
    );
    root = await Directory(p.join(sandbox.path, 'updates')).create();
    installation = await Directory(p.join(sandbox.path, 'install')).create();
    await File(p.join(installation.path, 'weekglass.exe')).writeAsBytes([8]);
    await File(p.join(installation.path, 'weekglass_updater.exe'))
        .writeAsBytes(feed.helper);
    requests = [];
    sequence = [];
    failHealth = false;
    objectResponse = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      final relative = request.uri.path.substring(1);
      final tag = request.headers.value(HttpHeaders.ifNoneMatchHeader);
      requests.add((relative, tag));
      final response = request.response;
      if (relative == feed.objectPath && objectResponse != null) {
        objectResponse!.call(request);
        return;
      }
      final body = switch (relative) {
        WindowsStartupFeed.channelPath => feed.channel,
        _ when relative == feed.manifestPath => feed.manifest,
        _ when relative == feed.objectPath => feed.executable,
        _ => null,
      };
      if (relative == WindowsStartupFeed.channelPath) {
        response.headers.set(HttpHeaders.etagHeader, feed.tag);
        if (tag == feed.tag) {
          response.statusCode = 304;
          unawaited(response.close());
          return;
        }
      }
      response.statusCode = body == null ? 404 : 200;
      response.contentLength = body?.length ?? 0;
      if (body != null) response.add(body);
      unawaited(response.close());
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await sandbox.delete(recursive: true);
  });

  test(
    'latest startup sends one conditional channel request and no manifest',
    () async {
      feed.build = UpdateService.currentBuild;
      feed.version = UpdateService.currentVersion;
      final first = client();
      await first.checkOnStartup();
      await first.checkOnStartup();
      final reopened = client();
      await reopened.checkOnStartup();

      expect(first.startupOffer, isNull);
      expect(reopened.startupOffer, isNull);
      expect(reopened.message, '已是最新版本 ${UpdateService.currentVersion}');
      expect(requests, [
        (WindowsStartupFeed.channelPath, null),
        (WindowsStartupFeed.channelPath, feed.tag),
      ]);
    },
  );

  test(
    'skip is exact to Windows and build, and Settings can still check',
    () async {
      const secure = FlutterSecureStorage();
      await secure.write(
        key: 'weekglass_skipped_update_android-arm64',
        value: '${feed.build}',
      );
      final first = client();
      await first.checkOnStartup();
      final offer = first.startupOffer!;
      await first.skipStartupVersion(offer);

      final reopened = client();
      await reopened.checkOnStartup();
      expect(reopened.startupOffer, isNull);
      expect(reopened.available, isNull);
      expect(reopened.message, '已跳过版本 ${feed.version}');
      await reopened.check();
      expect(reopened.available?['build'], offer.build);
      expect(reopened.startupOffer, isNull);

      feed.build++;
      feed.version = '0.20.20';
      final next = client();
      await next.checkOnStartup();
      expect(next.startupOffer?.build, feed.build);
      expect(next.startupOffer?.version, '0.20.20');
      expect(requests.map((request) => request.$1).toSet(), {
        WindowsStartupFeed.channelPath,
      });
    },
  );

  test(
    'accepted update continues after restart before the manifest is saved',
    () async {
      final intent = AcceptedUpdate.newJob(feed.build, feed.channel);
      await intent.save(root);
      final app = client();

      await app.checkOnStartup();

      expect(app.startupOffer, isNull);
      expect(requests, [(feed.manifestPath, null), (feed.objectPath, null)]);
      expect(sequence, ['save & close', 'launcher']);
      expect(
        await File(p.join(root.path, 'jobs', intent.jobId, 'job.json'))
            .exists(),
        isTrue,
      );
    },
  );

  test(
    'ready accepted job survives a second startup without a redownload',
    () async {
      final app = client()..canInstallAutomatically = () => false;
      await app.checkOnStartup();
      await app.acceptStartupUpdate(app.startupOffer!);
      expect(sequence, isEmpty);
      expect(app.ready, isTrue);
      expect(app.message, '更新已就绪，当前操作完成后自动重启更新');
      final accepted = (await AcceptedUpdate.read(root))!;

      requests.clear();
      // Replacing the rolling cache neither replaces the accepted release nor
      // requests it again. The signed snapshot identifies the prepared job.
      await File(p.join(root.path, 'channel.json'))
          .writeAsString('different cache');
      final resumed = client();
      await resumed.checkOnStartup();
      expect(requests, isEmpty);
      expect(resumed.startupOffer, isNull);
      expect(sequence, ['save & close', 'launcher']);
      expect(
        await File(p.join(root.path, 'jobs', accepted.jobId, 'job.json'))
            .exists(),
        isTrue,
      );
    },
  );

  test('Windows downloads while its planner gate is closed and hands off after saving', () async {
    final began = Completer<HttpResponse>();
    objectResponse = (request) => began.complete(request.response);
    var editorOpen = false;
    final app = client()..canInstallAutomatically = () => !editorOpen;
    await app.checkOnStartup();
    final completion = app.acceptStartupUpdate(app.startupOffer!);
    final response = await began.future;
    editorOpen = true;
    expect(app.startupOffer, isNull);
    expect(app.busy, isTrue);
    expect(sequence, isEmpty);
    response.contentLength = feed.executable.length;
    response.add(feed.executable);
    await response.close();
    await completion;
    expect(app.ready, isTrue);
    expect(sequence, isEmpty);

    final handoff = Completer<void>();
    app.addListener(() {
      if (!app.busy && sequence.contains('launcher') && !handoff.isCompleted) {
        handoff.complete();
      }
    });
    editorOpen = false;
    app.resumePendingInstallation();
    await handoff.future;
    expect(sequence, ['save & close', 'launcher']);
    expect(requests.where((r) => r.$1 == feed.objectPath), hasLength(1));
  });

  test(
    'helper launch failure resumes services and leaves a manual retry',
    () async {
      final app = client();
      await app.checkOnStartup();
      failHealth = true;
      await app.acceptStartupUpdate(app.startupOffer!);

      expect(app.ready, isTrue);
      expect(app.message, '更新失败（启动更新安装器），当前版本未改动');
      expect(sequence, ['save & close', 'launcher', 'resume']);
      expect(await AcceptedUpdate.read(root), isNull);
      app.resumePendingInstallation();
      expect(app.busy, isFalse);

      failHealth = false;
      await app.install();
      expect(sequence, [
        'save & close',
        'launcher',
        'resume',
        'save & close',
        'launcher',
      ]);
    },
  );

  test('rolled-back automatic job does not restart or silently skip', () async {
    final intent = AcceptedUpdate.newJob(feed.build, feed.channel);
    await intent.save(root);
    final job = Directory(p.join(root.path, 'jobs', intent.jobId));
    await job.create(recursive: true);
    await File(p.join(job.path, 'result.json'))
        .writeAsString('{"ok":false,"restored":true}');
    final app = client();

    await app.checkOnStartup();

    expect(app.message, '上次更新安装未完成，请重新检查更新');
    expect(app.startupOffer, isNull);
    expect(requests, [(WindowsStartupFeed.channelPath, null)]);
    expect(sequence, isEmpty);
    expect(await AcceptedUpdate.read(root), isNull);
    await app.check();
    expect(app.available?['build'], feed.build);
  });

  test(
    'invalid channel produces a Settings status and never accepts or skips',
    () async {
      feed.invalidChannel = true;
      final app = client();
      await app.checkOnStartup();
      expect(app.startupOffer, isNull);
      expect(app.available, isNull);
      expect(app.message, contains('校验更新信息'));
      expect(requests.single.$1, WindowsStartupFeed.channelPath);
      expect(sequence, isEmpty);
      expect(await AcceptedUpdate.read(root), isNull);
    },
  );

  test(
    'interrupted accepted object keeps its receipt and resumes exact bytes',
    () async {
      const objectTag = '"update-object"';
      objectResponse = (request) {
        unawaited(() async {
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.write(
            'HTTP/1.1 200 OK\r\nContent-Length: ${feed.executable.length}'
            '\r\nETag: $objectTag\r\nConnection: close\r\n\r\n',
          );
          socket.add(feed.executable.take(2).toList());
          await socket.flush();
          await socket.close();
        }());
      };
      final app = client();
      await app.checkOnStartup();
      await app.acceptStartupUpdate(app.startupOffer!);
      final acceptance = (await AcceptedUpdate.read(root))!;

      expect(app.canRetryAcceptedUpdate, isTrue);
      expect(app.message, contains('连接中断'));
      expect(sequence, isEmpty);
      expect(
        await File(
          p.join(
            root.path,
            'objects',
            '${p.basename(feed.objectPath)}.partial',
          ),
        ).readAsBytes(),
        feed.executable.take(2),
      );

      final ranges = <String?>[];
      objectResponse = (request) {
        ranges.add(request.headers.value(HttpHeaders.rangeHeader));
        expect(request.headers.value(HttpHeaders.ifRangeHeader), objectTag);
        final response = request.response;
        response.statusCode = HttpStatus.partialContent;
        response.contentLength = feed.executable.length - 2;
        response.headers.set(HttpHeaders.etagHeader, objectTag);
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 2-${feed.executable.length - 1}/${feed.executable.length}',
        );
        response.add(feed.executable.skip(2).toList());
        unawaited(response.close());
      };
      requests.clear();
      final resumed = client();
      await resumed.checkOnStartup();

      expect(resumed.startupOffer, isNull);
      expect(ranges, ['bytes=2-']);
      expect(requests, [(feed.objectPath, null)]);
      expect(sequence, ['save & close', 'launcher']);
      expect((await AcceptedUpdate.read(root))?.jobId, acceptance.jobId);
    },
  );
}
