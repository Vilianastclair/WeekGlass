import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';
import 'package:path/path.dart' as p;

Future<void> main() async {
  final output = Platform.environment['WEEKGLASS_MAC_SMOKE_ARTIFACTS'];
  if (output == null || !p.isAbsolute(output)) {
    throw StateError('Set WEEKGLASS_MAC_SMOKE_ARTIFACTS to an absolute path.');
  }
  await Directory(output).create(recursive: true);
  await integrationDriver(
    responseDataCallback: null,
    onScreenshot: (name, bytes, [args]) async {
      if (!const {
        'create-planner',
        'reopen-details',
        'create-failure',
        'reopen-failure',
      }.contains(name)) {
        throw FormatException('Unexpected screenshot name: $name');
      }
      await File(p.join(output, '$name.png')).writeAsBytes(bytes, flush: true);
      return true;
    },
  );
}
