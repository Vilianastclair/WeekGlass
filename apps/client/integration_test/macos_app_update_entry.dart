// Alternate integration entry only. Both releases run the production planner,
// startup check and installer; this fixture never initiates an installation.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:weekglass/app/app_services.dart';
import 'package:weekglass/features/updates/mac_update_bridge.dart';
import 'package:weekglass/main.dart' as weekglass;
import 'package:weekglass_domain/weekglass_domain.dart';

const _id = 'com.viliana.weekglass.updatesmoke';
const _vault = FlutterSecureStorage(
  mOptions: MacOsOptions(accountName: _id, usesDataProtectionKeychain: false),
);
const _appearance =
    '{"skin":"moonstone","mode":"dark","glassStrength":0.6,"glassMotion":false}';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final bundle = await MacUpdateBridge.channel.invokeMapMethod<String, String>(
    'bundle',
  );
  final dir = await getApplicationSupportDirectory();
  if (bundle?['id'] != _id ||
      !(await dir.resolveSymbolicLinks()).contains(
        '/Library/Containers/$_id/Data/',
      )) {
    throw StateError(
      'The upgrade fixture requires its isolated application container.',
    );
  }
  final fixture = File('${dir.path}/upgrade-input.json');
  final evidence = File('${dir.path}/upgrade-result.json');
  final build = int.parse(bundle!['build']!);
  try {
    // Fail instead of authorizing access interactively. This switch belongs
    // only to this process in the disposable integration login.
    final security = DynamicLibrary.open(
      '/System/Library/Frameworks/Security.framework/Security',
    );
    final allowUI = security
        .lookupFunction<Int32 Function(Uint8), int Function(int)>(
          'SecKeychainSetUserInteractionAllowed',
        );
    if (allowUI(0) != 0) {
      throw StateError('Could not require non-interactive Keychain access.');
    }
    final services = await AppServices.create();
    final preferences = SharedPreferencesAsync();
    final old = !await fixture.exists();
    final input = old
        ? <String, dynamic>{
            'marker': const Uuid().v4(),
            'build': build,
            'pid': pid,
          }
        : jsonDecode(await fixture.readAsString()) as Map<String, dynamic>;
    final marker = input['marker'] as String;
    final title = '升级前的日程 $marker';
    final start = DateTime.utc(2026, 11, 26, 9, 15);
    final end = start.add(const Duration(minutes: 45));
    if (old) {
      await services.eventRepository.save(
        CalendarEvent.timed(
          id: marker,
          title: title,
          startLocal: start,
          endLocal: end,
          timeZoneId: 'UTC',
        ),
      );
      await preferences.setString('appearance_v1', _appearance);
      await _vault.write(key: marker, value: 'fixture:$marker');
      await fixture.writeAsString(jsonEncode(input), flush: true);
    } else {
      if (build <= (input['build'] as int) || pid == input['pid']) {
        throw StateError(
          'A different successor build and process are required.',
        );
      }
      final event = (await services.eventRepository.getAllEvents()).singleWhere(
        (e) => e.id == marker,
      );
      if (event.title != title ||
          event.startUtc != start ||
          event.endUtc != end ||
          await preferences.getString('appearance_v1') != _appearance) {
        throw StateError(
          'The successor did not preserve the schedule or appearance.',
        );
      }
      if (await _vault.read(key: marker) != 'fixture:$marker') {
        throw StateError(
          'The successor did not read the file-based Keychain item.',
        );
      }
      await _vault.delete(key: marker);
    }
    await weekglass.runWeekGlass(args, createServices: () async => services);
    await WidgetsBinding.instance.endOfFrame;
    if (!old) {
      await evidence.writeAsString(
        jsonEncode({
          'version': bundle['version'],
          'build': build,
          'previousBuild': input['build'],
          'pid': pid,
          'previousPid': input['pid'],
          'executable': Platform.resolvedExecutable,
          'plannerFrame': true,
          'schedule': true,
          'appearance': true,
          'fileKeychain': true,
        }),
        flush: true,
      );
    }
  } catch (error) {
    await evidence.writeAsString(
      jsonEncode({'build': build, 'error': error.toString()}),
      flush: true,
    );
    rethrow;
  }
}
