import 'dart:io';

import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as mobile_sqlite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:weekglass_data/weekglass_data.dart';

import '../features/cloud/cloud_auth_service.dart';
import '../features/cloud/cloud_connection.dart';

class AppServices {
  const AppServices({
    required this.eventRepository,
    required this.timeZoneId,
    required this.cloud,
  });

  final EventRepository eventRepository;
  final String timeZoneId;
  final CloudConnection cloud;

  static Future<AppServices> create({
    Directory? dataDirectory,
    CloudAuthService? cloudAuth,
  }) async {
    final supportDirectory =
        dataDirectory ?? await getApplicationSupportDirectory();
    final databasePath = p.join(supportDirectory.path, 'weekglass.sqlite3');

    final factory = Platform.isWindows
        ? _createWindowsFactory()
        : mobile_sqlite.databaseFactory;

    String timeZoneId = DateTime.now().timeZoneName;
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      timeZoneId = info.identifier;
    } catch (_) {
      // The local offset still works for the first local-only release.
    }

    final repository = SqliteEventRepository(
      factory: factory,
      databasePath: databasePath,
    );
    await repository.getAllEvents();

    return AppServices(
      eventRepository: repository,
      timeZoneId: timeZoneId,
      cloud: CloudConnection(repository: repository, auth: cloudAuth),
    );
  }

  static DatabaseFactory _createWindowsFactory() {
    sqfliteFfiInit();
    return databaseFactoryFfi;
  }
}
