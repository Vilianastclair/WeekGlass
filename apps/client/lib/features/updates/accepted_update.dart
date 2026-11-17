import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'update_protocol.dart';

/// The exact release accepted in the startup prompt. The receipt records
/// consent and a stable job ID; its channel must still pass signature checks.
class AcceptedUpdate {
  AcceptedUpdate.newJob(this.build, this.channel)
    : jobId =
          '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}';

  const AcceptedUpdate._(this.build, this.channel, this.jobId);

  static const _name = 'accepted-update.json';

  final int build;
  final List<int> channel;
  final String jobId;

  static Future<AcceptedUpdate?> read(Directory root) async {
    final file = await updateChild(root, _name);
    if (!await file.exists()) return null;
    if (await file.length() > 32768) {
      throw const FormatException('更新任务记录过大');
    }
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final jobId = data['job'] as String;
    final build = data['build'] as int;
    final channel = base64Decode(data['channel'] as String);
    if (!RegExp(r'^\d{1,20}-\d{1,10}$').hasMatch(jobId) ||
        build < 1 ||
        channel.length > 16384) {
      throw const FormatException('更新任务记录无效');
    }
    return AcceptedUpdate._(build, channel, jobId);
  }

  Future<void> save(Directory root) async {
    final file = await updateChild(root, _name);
    final partial = await updateChild(root, '$_name.partial');
    await partial.writeAsString(
      jsonEncode({
        'job': jobId,
        'build': build,
        'channel': base64Encode(channel),
      }),
      flush: true,
    );
    await partial.rename(file.path);
  }

  static Future<void> clear(Directory root) async {
    final file = await updateChild(root, _name);
    if (await file.exists()) await file.delete();
  }
}
