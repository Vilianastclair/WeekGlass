import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:weekglass/features/updates/update_protocol.dart';

void main() {
  final now = DateTime.utc(2026, 11, 6);
  final digest = sha256([1, 2, 3]);

  Map<String, dynamic> identity() => {
    'schema': 1,
    'product': 'weekglass',
    'platform': 'android-arm64',
    'channel': 'stable',
    'version': '0.20.2',
    'build': 26,
    'generated_at': now.toIso8601String(),
    'expires_at': now.add(const Duration(days: 7)).toIso8601String(),
  };

  Map<String, dynamic> apk() => {
    'path': 'weekglass.apk',
    'size': 3,
    'sha256': digest,
    'full': {'encoding': 'raw', 'size': 3, 'sha256': digest},
    'patches': <Map<String, dynamic>>[],
  };

  Map<String, dynamic> manifest() => {
    ...identity(),
    'min_updater': 1,
    'files': [apk()],
  };

  void validate(Map<String, dynamic> data, {bool channel = false}) =>
      validateUpdatePayload(
        data,
        channel: channel,
        floor: 26,
        platform: 'android-arm64',
        clock: now,
      );

  test('Android channel only references the signed platform and build', () {
    final data = {
      ...identity(),
      'kind': 'weekglass-channel',
      'manifest': {
        'path': 'manifests/android-arm64/stable/26/$digest.json',
        'size': 1000,
        'sha256': digest,
      },
    };
    validate(data, channel: true);
    (data['manifest'] as Map)['path'] =
        'manifests/windows-x64/stable/26/$digest.json';
    expect(() => validate(data, channel: true), throwsFormatException);
  });

  test(
    'Android rejects wrong platform, rollback, expiry and future metadata',
    () {
      final mutations = <Map<String, dynamic>>[
        {'platform': 'windows-x64'},
        {'build': 25},
        {'expires_at': now.toIso8601String()},
        {'generated_at': now.add(const Duration(hours: 1)).toIso8601String()},
        {'min_updater': 2},
      ];
      for (final mutation in mutations) {
        expect(
          () => validate({...manifest(), ...mutation}),
          throwsFormatException,
          reason: mutation.toString(),
        );
      }
    },
  );

  test(
    'Android manifest accepts exactly one full raw APK with matching hash',
    () {
      validate(manifest());
      final invalid = <Map<String, dynamic>>[
        {...apk(), 'path': '../weekglass.apk'},
        {...apk(), 'path': 'other.apk'},
        {
          ...apk(),
          'full': {'encoding': 'zlib', 'size': 3, 'sha256': digest},
        },
        {
          ...apk(),
          'full': {'encoding': 'raw', 'size': 2, 'sha256': digest},
        },
        {
          ...apk(),
          'full': {
            'encoding': 'raw',
            'size': 3,
            'sha256': sha256([0]),
          },
        },
      ];
      for (final item in invalid) {
        expect(
          () => validate({
            ...manifest(),
            'files': [item],
          }),
          throwsFormatException,
          reason: item.toString(),
        );
      }
      expect(
        () => validate({
          ...manifest(),
          'files': [
            apk(),
            {...apk(), 'path': 'extra.apk'},
          ],
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'Android patch must have bounded, hashed source and supported encoding',
    () {
      final patch = {
        'encoding': 'bsdiff4',
        'sha256': digest,
        'size': 2,
        'base_sha256': sha256([4, 5, 6]),
        'base_size': 3,
      };
      final entry = apk()..['patches'] = [patch];
      validate({
        ...manifest(),
        'files': [entry],
      });
      for (final changes in [
        {'encoding': 'unknown'},
        {'base_sha256': 'bad'},
        {'base_size': maximumUpdateFile + 1},
      ]) {
        entry['patches'] = [
          {...patch, ...changes},
        ];
        expect(
          () => validate({
            ...manifest(),
            'files': [entry],
          }),
          throwsFormatException,
        );
      }
      entry['patches'] = List.filled(4, patch);
      expect(
        () => validate({
          ...manifest(),
          'files': [entry],
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'smallest matching APK patch wins, changed or absent source uses full',
    () {
      final baseHash = sha256([4, 5, 6]);
      final patch = {
        'encoding': 'bsdiff4',
        'sha256': digest,
        'size': 2,
        'base_sha256': baseHash,
        'base_size': 3,
      };
      final entry = apk()
        ..['patches'] = [
          {...patch, 'size': 4},
          patch,
          {...patch, 'size': 1},
        ];
      expect(
        smallestUpdateObject(entry, baseSha256: baseHash, baseSize: 3)['size'],
        1,
      );
      expect(
        smallestUpdateObject(entry, baseSha256: baseHash, baseSize: 2),
        same(entry['full']),
      );
      expect(
        smallestUpdateObject(entry, baseSha256: sha256([0]), baseSize: 3),
        same(entry['full']),
      );
      expect(smallestUpdateObject(entry), same(entry['full']));
      entry['patches'] = [
        {...patch, 'size': 3},
      ];
      expect(
        smallestUpdateObject(entry, baseSha256: baseHash, baseSize: 3),
        same(entry['full']),
      );
    },
  );

  test('authentic Windows channel cannot cross into Android', () async {
    final data = File('test/fixtures/updater/channel.json').readAsBytesSync();
    final envelope = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
    final payload = jsonDecode(
      utf8.decode(base64Decode(envelope['signed'] as String)),
    ) as Map<String, dynamic>;
    await expectLater(
      verifyUpdateEnvelope(
        data,
        channel: true,
        floor: 1,
        platform: 'android-arm64',
        clock: DateTime.parse(payload['generated_at'] as String)
            .add(const Duration(minutes: 1)),
      ),
      throwsFormatException,
    );
  });
}
