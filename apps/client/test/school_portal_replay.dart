import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:weekglass/features/course_import/school_portal_reader.dart';
import 'package:weekglass/features/course_import/wakeup_engine.dart';
import 'package:weekglass/features/course_import/whu_timetable.dart';

// Uses the actual Dart read/poll/parse coordinator and desktop production
// runner. Only the WebView transport and installed app location are injected.
Future<WhuTimetable> replaySchoolPage(
  String file, {
  required List<String> parsers,
  WhuTerm term = const WhuTerm(2026, 3),
  void Function(String id, String source)? checkSource,
  Future<int?> Function()? requestWeeks,
}) async {
  final process = await Process.start('node', [
    '../../tooling/scripts/school-portal-replay.mjs',
    file,
  ]);
  final lines = StreamIterator(
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
  );
  final errors = process.stderr.transform(utf8.decoder).join();
  final engine = DesktopWakeUpRunner(
    Directory(
      Platform.environment['WG_SCHOOL_ENGINE_DIR'] ??
          'build/windows/x64/runner/Release/data/course_adapter',
    ),
  );
  Future<Map> next() async {
    if (!await lines.moveNext().timeout(const Duration(seconds: 25))) {
      throw StateError(await errors);
    }
    return jsonDecode(lines.current) as Map;
  }

  Future<Map<String, dynamic>> call(Map request) async {
    final data = jsonDecode(
      await engine.handle(jsonEncode(request)),
    ) as Map<String, dynamic>;
    if (data['ok'] != true) throw WakeUpEngineException(data['code'], '解析未完成');
    return data;
  }

  try {
    final start = await next();
    return await SchoolPortalReader.read(
      page: Uri.parse(start['url']),
      term: term,
      parsers: parsers,
      current: () => true,
      requestWeeks: requestWeeks,
      execute: (js) async {
        process.stdin.writeln(jsonEncode(js));
        await process.stdin.flush();
        final reply = await next();
        if (reply['error'] != null) throw FormatException(reply['error']);
        return reply['value'];
      },
      listAdapters: () async =>
          ((await call({'op': 'list'}))['adapters'] as List)
              .cast<Map<String, dynamic>>(),
      parse: ({required adapter, required source, termWeeks}) async {
        checkSource?.call(adapter, source);
        return WakeUpEngine.toTimetable(
          await call({
            'op': 'parse',
            'adapter': adapter,
            'source': source,
            'termWeeks': ?termWeeks,
          }),
        );
      },
    );
  } finally {
    await process.stdin.close();
    await lines.cancel();
    await process.exitCode.timeout(const Duration(seconds: 15));
  }
}
