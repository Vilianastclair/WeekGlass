import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import 'whu_timetable.dart';

class WakeUpEngineException extends FormatException {
  const WakeUpEngineException(this.code, super.message);
  final String code;
}

/// Sends only the selected offline timetable to the parser bundled in this app.
abstract final class WakeUpEngine {
  static const maxSourceBytes = 4 * 1024 * 1024;
  static const _deadline = Duration(seconds: 15);
  static const _channel = MethodChannel('com.viliana.weekglass/courseadapter');

  static Future<List<Map<String, dynamic>>> list() async {
    final reply = await _call({'op': 'list'});
    return (reply['adapters'] as List).cast<Map<String, dynamic>>();
  }

  static Future<WhuTimetable> parse({
    required String adapter,
    required String source,
    int? termWeeks,
  }) async {
    if (source.length > maxSourceBytes ||
        utf8.encode(source).length > maxSourceBytes) {
      throw const WakeUpEngineException('TOO_LARGE', '课表超过 4 MB，请选择单学期的课表。');
    }
    final reply = await _call({
      'op': 'parse',
      'adapter': adapter,
      'source': source,
      'termWeeks': ?termWeeks,
    });
    return toTimetable(reply);
  }

  static Future<Map<String, dynamic>> _call(Map<String, Object> request) async {
    final input = jsonEncode(request);
    try {
      final String? raw;
      if (defaultTargetPlatform == TargetPlatform.android) {
        raw = await _channel
            .invokeMethod<String>('handle', input)
            .timeout(_deadline);
      } else if (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS) {
        final executableDirectory = path.dirname(Platform.resolvedExecutable);
        final home = Directory(
          Platform.isMacOS
              ? path.join(path.dirname(executableDirectory), 'Resources', 'course_adapter')
              : path.join(executableDirectory, 'data', 'course_adapter'),
        );
        raw = await DesktopWakeUpRunner(home).handle(input);
      } else {
        throw const WakeUpEngineException('UNAVAILABLE', '当前平台没有内置课表解析器。');
      }
      final result = jsonDecode(raw ?? '') as Map<String, dynamic>;
      if (result['ok'] != true) {
        throw _error(result['code'] as String? ?? 'PARSE_ERROR');
      }
      return result;
    } on WakeUpEngineException {
      rethrow;
    } on TimeoutException {
      throw _error('TIMEOUT');
    } on PlatformException catch (e) {
      throw _error(e.code);
    } on MissingPluginException {
      throw _error('UNAVAILABLE');
    } on IOException {
      throw _error('UNAVAILABLE');
    } on FormatException {
      throw _error('INVALID_RESPONSE');
    } on TypeError {
      throw _error('INVALID_RESPONSE');
    }
  }

  static WakeUpEngineException _error(String code) =>
      WakeUpEngineException(code, switch (code) {
        'UNKNOWN_ADAPTER' => '没有找到所选的课表格式。',
        'UNSUPPORTED_INPUT' => '这份内容不能直接用所选格式解析，请检查课表来源。',
        'NEED_TERM_WEEKS' => '课表未注明学期总周数，请按学校校历填写本学期的教学周数。',
        'NO_COURSES' => '没有读到课程，请核对课表格式和学期。',
        'TIMEOUT' => '课表解析超时，请选择单学期的课表重试。',
        'BUSY' => '上一份课表仍在解析，请稍后重试。',
        'UNAVAILABLE' => '内置课表解析器不可用，请检查应用安装是否完整。',
        'TOO_LARGE' => '课表内容过大，请选择单学期的课表。',
        _ => '无法解析这份课表，请检查所选格式和课表内容。',
      });

  static WhuTimetable toTimetable(Map<String, dynamic> reply) {
    final rows = reply['courses'];
    if (rows is! List || rows.length > 5000) throw _error('INVALID_RESPONSE');
    final warnings = <String>[];
    final validClock = _schoolClock(reply['timeTable']);
    if (reply['timeTable'] != null && validClock == null) {
      warnings.add('学校作息表缺少连续有效的节次，请在预览中核对上课时间。');
    }
    final meetings = <WhuCourseMeeting>[];
    final seen = <String>{};
    for (final row in rows.whereType<Map>()) {
      final title = schoolText(row['name']);
      final teacher = schoolText(row['teacher']),
          room = schoolText(row['room']);
      final start = row['startWeek'], end = row['endWeek'];
      final type = row['type'], day = row['day'];
      final first = row['startNode'], last = row['endNode'];
      final fixed = _clockRange(row);
      final hasClock =
          (row['startTime'] ?? '') != '' || (row['endTime'] ?? '') != '';
      final nodes =
          first is int &&
              last is int &&
              first >= 1 &&
              last >= first &&
              last <= 24
          ? [for (var n = first; n <= last; n++) n]
          : <int>[];
      if (title.isEmpty ||
          day is! int ||
          day < 1 ||
          day > 7 ||
          start is! int ||
          end is! int ||
          start < 1 ||
          end > 53 ||
          start > end ||
          !const {0, 1, 2}.contains(type) ||
          (hasClock && fixed == null) ||
          (fixed == null && nodes.isEmpty)) {
        warnings.add('${title.isEmpty ? '未命名课程' : title}：星期、教学周或上课时间不完整，未安排。');
        continue;
      }
      final weeks = [
        for (var w = start; w <= end; w++)
          if (type == 0 || (type == 1 ? w.isOdd : w.isEven)) w,
      ];
      if (weeks.isEmpty) {
        warnings.add('$title：单双周与周次范围不符，未安排。');
        continue;
      }
      final weekText =
          '${start == end ? start : '$start～$end'}周${type == 1
              ? '（单）'
              : type == 2
              ? '（双）'
              : ''}';
      final credit = row['credit'];
      final note = [
        if (schoolText(row['note']).isNotEmpty) schoolText(row['note']),
        if (credit is num && credit > 0)
          '学分：${credit == credit.toInt() ? credit.toInt() : credit}',
      ].join('\n');
      final key = whuHash('$title|$teacher').substring(0, 24);
      if (!seen.add(
        jsonEncode([
          key,
          room,
          day,
          nodes,
          weeks,
          fixed?.start,
          fixed?.end,
          note,
        ]),
      )) {
        continue;
      }
      meetings.add(
        WhuCourseMeeting(
          courseKey: key,
          title: title,
          weekday: day,
          periods: nodes,
          weeks: weeks,
          weekText: weekText,
          room: room,
          teacher: teacher,
          note: note,
          fixedTime: fixed,
        ),
      );
    }
    if (meetings.isEmpty) {
      if (warnings.isEmpty) throw _error('NO_COURSES');
      throw WakeUpEngineException('NO_COURSES', '没有可安排的课程。${warnings.first}');
    }
    return WhuTimetable(
      meetings: meetings,
      warnings: warnings,
      account: '',
      suggestedClock: validClock,
      suggestedFirstMonday: _firstMonday(reply['startDate']),
    );
  }

  static DateTime? _firstMonday(Object? date) {
    if (date is! String) return null;
    final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(date);
    if (m == null) return null;
    final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
    final value = DateTime(y, mo, d);
    return value.month == mo &&
            value.day == d &&
            value.weekday == DateTime.monday
        ? value
        : null;
  }

  static ClassPeriod? _clockRange(Map row) {
    int? minute(Object? raw) {
      if (raw is! String) return null;
      final m = RegExp(r'^(\d{1,2}):(\d{2})(?::00)?$').firstMatch(raw.trim());
      if (m == null) return null;
      final h = int.parse(m[1]!), n = int.parse(m[2]!);
      return h < 24 && n < 60 ? h * 60 + n : null;
    }

    final start = minute(row['startTime']), end = minute(row['endTime']);
    return start != null && end != null && end > start
        ? ClassPeriod(start, end)
        : null;
  }

  static List<ClassPeriod>? _schoolClock(Object? table) {
    final rows = table is Map ? table['timeList'] : null;
    if (rows is! List || rows.isEmpty || rows.length > 24) return null;
    final indexed = <int, ClassPeriod>{};
    for (final row in rows) {
      if (row is! Map) return null;
      final node = row['node'], period = _clockRange(row);
      if (node is! int ||
          node < 1 ||
          node > rows.length ||
          period == null ||
          indexed.containsKey(node)) {
        return null;
      }
      indexed[node] = period;
    }
    final clock = [for (var n = 1; n <= rows.length; n++) indexed[n]!];
    for (var i = 1; i < clock.length; i++) {
      if (clock[i].start < clock[i - 1].end) return null;
    }
    return clock;
  }
}

/// One local process per read. No PATH lookup, files of timetable contents,
/// shell interpolation or JVM options inherited from the user's environment.
final class DesktopWakeUpRunner {
  const DesktopWakeUpRunner(this.home);
  final Directory home;

  Future<String> handle(String request) async {
    final java = path.join(home.path, 'runtime', 'bin', Platform.isWindows ? 'java.exe' : 'java');
    final process = await Process.start(
      java,
      [
        '-Xmx96m',
        '-XX:+PerfDisableSharedMem',
        '-XX:-CreateCoredumpOnCrash',
        '-XX:ErrorFile=${Platform.isWindows ? 'NUL' : '/dev/null'}',
        if (Platform.isMacOS) '-Xint',
        if (Platform.isMacOS) '-XX:-UsePerfData',
        '-Dfile.encoding=UTF-8',
        '-Djava.security.manager',
        '-Djava.security.policy==parser.policy',
        '-jar',
        'engine.jar',
      ],
      workingDirectory: home.path,
      includeParentEnvironment: false,
      environment: {
        for (final key in ['SystemRoot', 'TEMP', 'TMP'])
          if (Platform.environment[key] != null)
            key: Platform.environment[key]!,
      },
    );
    Future<String> readReply() async {
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in process.stdout) {
        if (bytes.length + chunk.length > 8 * 1024 * 1024) {
          throw WakeUpEngine._error('TOO_LARGE');
        }
        bytes.add(chunk);
      }
      return utf8.decode(bytes.takeBytes());
    }

    Future<void> writeRequest() async {
      process.stdin.add(utf8.encode(request));
      await process.stdin.close();
    }

    var exited = false;
    final exitCode = process.exitCode.then((code) {
      exited = true;
      return code;
    });
    try {
      final results = await Future.wait<dynamic>([
        readReply(),
        process.stderr.drain<void>(),
        exitCode,
        writeRequest(),
      ], eagerError: true).timeout(WakeUpEngine._deadline);
      if (results[2] != 0) throw WakeUpEngine._error('UNAVAILABLE');
      return results.first as String;
    } finally {
      if (!exited) process.kill();
    }
  }
}
