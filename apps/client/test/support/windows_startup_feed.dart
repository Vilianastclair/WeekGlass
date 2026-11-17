import 'dart:convert';
import 'dart:io';

import 'package:weekglass/features/updates/update_protocol.dart';
import 'package:weekglass/features/updates/update_service.dart';

/// Synthetic install files and a payload-verifying fixture. Cryptographic
/// envelope and object transport have their own production contract tests.
class WindowsStartupFeed {
  static final clock = DateTime.utc(2026, 11, 17);
  final executable = [5, 4, 3, 2, 1];
  final helper = [1, 3, 5];
  int build = UpdateService.currentBuild + 1;
  String version = '0.20.19';
  bool invalidChannel = false;

  static const channelPath = 'channels/windows-x64/stable.json';

  Map<String, dynamic> get _identity => {
    'schema': 1,
    'product': 'weekglass',
    'platform': 'windows-x64',
    'channel': 'stable',
    'version': version,
    'build': build,
    'generated_at': clock.toIso8601String(),
    'expires_at': clock.add(const Duration(days: 1)).toIso8601String(),
  };

  List<int> get manifest => utf8.encode(
    jsonEncode({
      ..._identity,
      'min_updater': 1,
      'files': [
        for (final (name, bytes) in [
          ('weekglass.exe', executable),
          ('weekglass_updater.exe', helper),
        ])
          {
            'path': name,
            'size': bytes.length,
            'sha256': sha256(bytes),
            'full': {
              'encoding': 'raw',
              'size': bytes.length,
              'sha256': sha256(bytes),
            },
            'patches': [],
          },
      ],
    }),
  );

  String get manifestPath =>
      'manifests/windows-x64/stable/$build/${sha256(manifest)}.json';
  String get objectPath =>
      'objects/${sha256(executable).substring(0, 2)}/${sha256(executable)}';
  String get tag => '"channel-$build"';
  List<int> get channel => utf8.encode(
    jsonEncode({
      ..._identity,
      if (invalidChannel) 'product': 'invalid-release',
      'kind': 'weekglass-channel',
      'manifest': {
        'size': manifest.length,
        'sha256': sha256(manifest),
        'path': manifestPath,
      },
    }),
  );

  Future<Map<String, dynamic>> verify(
    List<int> bytes, {
    required bool channel,
    required int floor,
    required String platform,
  }) async {
    final payload = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    validateUpdatePayload(
      payload,
      channel: channel,
      floor: floor,
      platform: platform,
      clock: clock,
    );
    return payload;
  }

  Future<List<int>> metadata(String path, int limit, {File? cache}) async =>
      switch (path) {
        channelPath => channel,
        _ when path == manifestPath => manifest,
        _ => throw StateError('Unexpected metadata: $path'),
      };
}
