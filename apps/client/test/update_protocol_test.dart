import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:weekglass/features/updates/update_protocol.dart';

void main() {
  final fixture = Directory('test/fixtures/updater');
  test('Python BSDIFF40 patch reconstructs exact Dart bytes', () {
    final base = File('${fixture.path}/base.bin').readAsBytesSync();
    final target = File('${fixture.path}/target.bin').readAsBytesSync();
    final patch = File('${fixture.path}/patch.bin').readAsBytesSync();
    expect(applyBsdiff(base, patch, target.length), target);
  });
  test('zlib output exact and expansion is bounded', () {
    final target = File('${fixture.path}/target.bin').readAsBytesSync();
    final data = File('${fixture.path}/target.zlib').readAsBytesSync();
    expect(decodeUpdateObject(data, 'zlib', target.length), target);
    expect(() => decodeUpdateObject(data, 'zlib', 10), throwsA(anything));
  });
  test('patch rejects malformed header and mismatched output size', () {
    final patch = File('${fixture.path}/patch.bin').readAsBytesSync();
    expect(() => applyBsdiff([], patch, 1), throwsFormatException);
    patch[0] = 0;
    expect(() => applyBsdiff([], patch, 0), throwsFormatException);
  });
  test('Windows unsafe paths rejected', () {
    for (final name in [
      '../evil',
      '/root',
      'a//b',
      'C:evil',
      'CON.txt',
      'a/NUL',
      'a\\b',
      'a.',
      'a ',
      'x:y',
      'a/../b',
    ]) {
      expect(() => safeUpdatePath(name), throwsFormatException, reason: name);
    }
    expect(
      safeUpdatePath('data/flutter_assets/字体.ttf'),
      'data/flutter_assets/字体.ttf',
    );
  });
  test(
    'pinned real channel accepted, tampering and rollback rejected',
    () async {
      final data = File('${fixture.path}/channel.json').readAsBytesSync();
      final outer = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      final payload = jsonDecode(
        utf8.decode(base64Decode(outer['signed'] as String)),
      ) as Map<String, dynamic>;
      final time = DateTime.parse(payload['generated_at'] as String)
          .add(const Duration(minutes: 1));
      expect(
        (await verifyUpdateEnvelope(
          data,
          channel: true,
          floor: 16,
          clock: time,
        ))['build'],
        16,
      );
      await expectLater(
        verifyUpdateEnvelope(data, channel: true, floor: 17, clock: time),
        throwsFormatException,
      );
      await expectLater(
        verifyUpdateEnvelope(
          data,
          channel: true,
          floor: 16,
          clock: time.add(const Duration(days: 8)),
        ),
        throwsFormatException,
      );
      outer['signed'] = base64Encode(
        utf8.encode(jsonEncode({...payload, 'build': 999})),
      );
      await expectLater(
        verifyUpdateEnvelope(
          utf8.encode(jsonEncode(outer)),
          channel: true,
          floor: 16,
          clock: time,
        ),
        throwsFormatException,
      );
    },
  );
  test('staging verifies hashes and rejects unexpected executable', () async {
    final root = await Directory.systemTemp.createTemp('wg-update-test-');
    try {
      await File('${root.path}/safe.bin').writeAsBytes([1, 2, 3]);
      final manifest = {
        'files': [
          {
            'path': 'safe.bin',
            'size': 3,
            'sha256': sha256([1, 2, 3]),
          },
        ],
      };
      await verifyStagedUpdate(root, manifest);
      await File('${root.path}/unexpected.exe').writeAsBytes([4]);
      await expectLater(
        verifyStagedUpdate(root, manifest),
        throwsFormatException,
      );
    } finally {
      await root.delete(recursive: true);
    }
  });
}
