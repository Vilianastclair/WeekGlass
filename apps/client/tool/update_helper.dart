// Standalone executable: no Flutter runtime, no network, no credential access.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:weekglass/features/updates/update_protocol.dart';

typedef _OpenNative = Pointer<Void> Function(Uint32, Int32, Uint32);
typedef _OpenDart = Pointer<Void> Function(int, int, int);
typedef _WaitNative = Uint32 Function(Pointer<Void>, Uint32);
typedef _WaitDart = int Function(Pointer<Void>, int);
typedef _CloseNative = Int32 Function(Pointer<Void>);
typedef _CloseDart = int Function(Pointer<Void>);

Future<void> waitForProcess(int processId) async {
  if (!Platform.isWindows || processId <= 0 || processId == pid) {
    throw const FormatException('Invalid source process');
  }
  final kernel = DynamicLibrary.open('kernel32.dll');
  final open = kernel.lookupFunction<_OpenNative, _OpenDart>('OpenProcess');
  final wait = kernel.lookupFunction<_WaitNative, _WaitDart>(
    'WaitForSingleObject',
  );
  final close = kernel.lookupFunction<_CloseNative, _CloseDart>('CloseHandle');
  final handle = open(0x00100000, 0, processId);
  if (handle.address == 0) {
    return; // Already exited, then filesystem checks remain authoritative.
  }
  try {
    if (wait(handle, 60000) != 0) {
      throw const FileSystemException('Application did not exit');
    }
  } finally {
    close(handle);
  }
}

Future<void> main(List<String> args) async {
  if (args.length != 1) exit(2);
  Directory? old, target, backup, failed;
  File? result;
  var swapped = false;
  var exitedSource = false;
  try {
    final jobFile = File(p.absolute(args.single));
    if (p.basename(jobFile.path) != 'job.json' ||
        p.dirname(jobFile.path) != p.dirname(Platform.resolvedExecutable) ||
        isUpdateLink(jobFile.path) ||
        await jobFile.length() > 16384) {
      throw const FormatException('Invalid job path');
    }
    final job =
        jsonDecode(await jobFile.readAsString()) as Map<String, dynamic>;
    target = Directory(job['target'] as String).absolute;
    final stage = Directory(job['stage'] as String).absolute;
    final manifestFile = File(job['manifest'] as String);
    final health = File(job['health'] as String);
    final nonce = p.basename(jobFile.parent.path);
    if (p.dirname(target.path) != p.dirname(stage.path) ||
        p.basename(stage.path) != '.weekglass-stage-$nonce' ||
        p.dirname(target.path) == target.path ||
        !await File(p.join(target.path, 'weekglass.exe')).exists() ||
        manifestFile.path != p.join(jobFile.parent.path, 'manifest.json') ||
        health.path != p.join(jobFile.parent.path, 'boot-ready') ||
        job['result'] != p.join(jobFile.parent.path, 'result.json') ||
        !p.isAbsolute(target.path) ||
        isUpdateLink(target.path) ||
        isUpdateLink(stage.path)) {
      throw const FormatException('Invalid installation paths');
    }
    result = File(job['result'] as String);
    final manifest = await verifyUpdateEnvelope(
      await manifestFile.readAsBytes(),
      channel: false,
      floor: job['floor'] as int,
    );
    await verifyStagedUpdate(stage, manifest);
    await waitForProcess(job['pid'] as int);
    exitedSource = true;
    await verifyStagedUpdate(stage, manifest);
    backup = Directory(
      p.join(target.parent.path, '.weekglass-previous-$nonce'),
    );
    failed = Directory(p.join(target.parent.path, '.weekglass-failed-$nonce'));
    if (await backup.exists() || await failed.exists()) {
      throw const FileSystemException('Backup already exists');
    }
    old = await target.rename(backup.path);
    try {
      await stage.rename(target.path);
      swapped = true;
    } catch (_) {
      await old.rename(target.path);
      old = null;
      rethrow;
    }
    if (await health.exists()) await health.delete();
    final process = await Process.start(p.join(target.path, 'weekglass.exe'), [
      '--weekglass-update-job=${jobFile.path}',
    ], workingDirectory: target.path);
    var ended = false;
    process.stdout.drain<void>();
    process.stderr.drain<void>();
    process.exitCode.then((_) {
      ended = true;
    });
    for (var i = 0; i < 150 && !ended && !await health.exists(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (!await health.exists() || ended) {
      if (!ended) {
        process.kill();
        await process.exitCode.timeout(const Duration(seconds: 10));
      }
      throw const FileSystemException(
        'Updated application health check failed',
      );
    }
    await result.writeAsString(
      jsonEncode({'ok': true, 'build': manifest['build'], 'backup': old.path}),
      flush: true,
    );
    // Previous signed installation remains available for explicit recovery.
    exit(0);
  } catch (_) {
    var restored = false;
    if (swapped && target != null && old != null && failed != null) {
      try {
        await target.rename(failed.path);
        await old.rename(target.path);
        restored = true;
      } catch (_) {
        /* Preserve both directories for operator recovery. */
      }
    }
    if (result != null) {
      await result.writeAsString(
        jsonEncode({
          'ok': false,
          'restored': restored,
          'message': '更新未完成，已保留原版本与恢复目录',
        }),
        flush: true,
      );
    }
    if ((restored || (!swapped && exitedSource)) && target != null) {
      await Process.start(
        p.join(target.path, 'weekglass.exe'),
        const [],
        workingDirectory: target.path,
        mode: ProcessStartMode.detached,
      );
    }
    exit(1);
  }
}
