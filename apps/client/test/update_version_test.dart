import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:weekglass/features/updates/update_service.dart';

void main() {
  test(
    'update identity matches the packaged application version and build',
    () {
      final version = RegExp(
        r'^version:\s*([^\s+]+)\+(\d+)\s*$',
        multiLine: true,
      ).firstMatch(File('pubspec.yaml').readAsStringSync());
      expect(version, isNotNull, reason: 'pubspec must declare version+build');
      expect(UpdateService.currentVersion, version!.group(1));
      expect(UpdateService.currentBuild, int.parse(version.group(2)!));
    },
  );
}
