import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:rrule/rrule.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:weekglass_domain/weekglass_domain.dart';

enum CalendarFileFormat { ics, json, csv }

class CalendarImportResult {
  const CalendarImportResult({
    required this.events,
    required this.duplicateCount,
    required this.skippedCount,
    required this.messages,
  });
  final List<CalendarEvent> events;
  final int duplicateCount, skippedCount;
  final List<String> messages;
}

/// Interchange is deliberately additive. Existing records, including imported
/// tombstones supplied by the caller, are never overwritten by a file.
class CalendarCodec {
  CalendarCodec() {
    if (!_initialized) {
      tzdata.initializeTimeZones();
      _initialized = true;
    }
  }
  static bool _initialized = false;
  static const maxBytes = 10 * 1024 * 1024;
  static const maxEvents = 5000;
  static const sourcePrefix = 'calendar-io:';

  static String decodeText(List<int> bytes) {
    if (bytes.length > maxBytes) {
      throw const FormatException('文件超过 10 MB，请先拆分日历。');
    }
    if (bytes.length >= 2 &&
        ((bytes[0] == 255 && bytes[1] == 254) ||
            (bytes[0] == 254 && bytes[1] == 255))) {
      if (bytes.length.isOdd) throw const FormatException('UTF-16 文件不完整。');
      final littleEndian = bytes[0] == 255;
      return String.fromCharCodes([
        for (var i = 2; i < bytes.length; i += 2)
          littleEndian
              ? bytes[i] | bytes[i + 1] << 8
              : bytes[i] << 8 | bytes[i + 1],
      ]);
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw const FormatException('请将文件另存为 UTF-8 编码后再导入。');
    }
  }

  tz.Location location(String name) {
    if (name == 'UTC' ||
        name == 'Etc/UTC' ||
        name == 'GMT' ||
        name == 'Etc/GMT') {
      return tz.UTC;
    }
    const aliases = {
      'China Standard Time': 'Asia/Shanghai',
      'Eastern Standard Time': 'America/New_York',
      'Pacific Standard Time': 'America/Los_Angeles',
      'GMT Standard Time': 'Europe/London',
      'Tokyo Standard Time': 'Asia/Tokyo',
      'GMT': 'UTC',
    };
    try {
      return tz.getLocation(aliases[name] ?? name);
    } catch (_) {
      throw FormatException('无法识别时区“$name”，此项未导入。');
    }
  }

  CalendarImportResult decode({
    required String text,
    required CalendarFileFormat format,
    required String timeZoneId,
    required DateTime rangeStart,
    required DateTime rangeEnd,
    Iterable<CalendarEvent> existing = const [],
  }) {
    if (utf8.encode(text).length > maxBytes) {
      throw const FormatException('文件超过 10 MB，请先拆分日历。');
    }
    if (!rangeEnd.isAfter(rangeStart) ||
        rangeEnd.difference(rangeStart).inDays > 732) {
      throw const FormatException('请选择不超过两年的导入范围。');
    }
    final zone = location(timeZoneId);
    final first = tz.TZDateTime(
      zone,
      rangeStart.year,
      rangeStart.month,
      rangeStart.day,
    );
    final last = tz.TZDateTime(
      zone,
      rangeEnd.year,
      rangeEnd.month,
      rangeEnd.day,
    );
    final messages = <String>{};
    var skipped = 0;
    final raw = <CalendarEvent>[];
    void invalid(Object error) {
      skipped++;
      if (messages.length < 12) {
        messages.add(
          error is FormatException
              ? error.message.toString()
              : '一项日程格式不完整，已跳过。',
        );
      }
    }

    void add(CalendarEvent event) {
      if (raw.length >= maxEvents) {
        throw const FormatException('日程超过 5000 条，请缩小导入日期范围。');
      }
      if (event.startUtc!.isBefore(last) && event.endUtc!.isAfter(first)) {
        raw.add(event);
      } else {
        skipped++;
        messages.add('范围外的日程已跳过；可更改日期范围重新预览。');
      }
    }

    text = text.replaceFirst(RegExp(r'^\uFEFF'), '');
    if (format == CalendarFileFormat.ics) {
      _readIcs(text, timeZoneId, first, last, add, invalid, messages);
    } else {
      final rows = format == CalendarFileFormat.json
          ? _jsonRows(text)
          : _csvRows(text);
      if (rows.length > maxEvents) {
        throw const FormatException('文件超过 5000 条，请拆分后导入。');
      }
      for (final row in rows) {
        try {
          add(_record(row, timeZoneId));
        } catch (error) {
          invalid(error);
        }
      }
    }
    final ids = existing.map((e) => e.id).toSet();
    final fingerprints = existing.map(fingerprint).toSet();
    final result = <CalendarEvent>[];
    var duplicate = 0;
    for (final event in raw) {
      final fp = fingerprint(event);
      if (ids.contains(event.id) || fingerprints.contains(fp)) {
        duplicate++;
      } else {
        ids.add(event.id);
        fingerprints.add(fp);
        result.add(event);
      }
    }
    result.sort((a, b) => a.startUtc!.compareTo(b.startUtc!));
    return CalendarImportResult(
      events: result,
      duplicateCount: duplicate,
      skippedCount: skipped,
      messages: messages.toList(),
    );
  }

  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();
  static String fingerprint(CalendarEvent e) => _hash(
    jsonEncode([
      e.title.trim(),
      e.startUtc?.toIso8601String(),
      e.endUtc?.toIso8601String(),
      (e.notes ?? '').trim(),
    ]),
  );

  CalendarEvent _event({
    required String title,
    required DateTime start,
    required DateTime end,
    required String zone,
    String? uid,
    String? series,
    String? notes,
    EventColor color = EventColor.mistBlue,
    String? nativeId,
  }) {
    // TZDateTime.toLocal() follows timezone's global local location (UTC until
    // explicitly set), not the operating system clock. Domain records must
    // retain ordinary UTC DateTimes so CalendarEvent.startLocal stays correct.
    start = DateTime.fromMicrosecondsSinceEpoch(
      start.microsecondsSinceEpoch,
      isUtc: true,
    );
    end = DateTime.fromMicrosecondsSinceEpoch(
      end.microsecondsSinceEpoch,
      isUtc: true,
    );
    title = title.trim();
    if (title.isEmpty || title.length > 500) {
      throw const FormatException('日程名称为空或超过 500 字，已跳过。');
    }
    if ((notes?.length ?? 0) > 20000 ||
        !end.isAfter(start) ||
        end.difference(start).inDays > 31) {
      throw const FormatException('一项日程的时间或备注无效，已跳过。');
    }
    final identity =
        uid ??
        jsonEncode([
          title,
          start.toUtc().toIso8601String(),
          end.toUtc().toIso8601String(),
          notes,
        ]);
    final id =
        nativeId != null &&
            RegExp(r'^[a-zA-Z0-9_.:@-]{1,128}$').hasMatch(nativeId)
        ? nativeId
        : 'cio-${_hash(identity).substring(0, 40)}';
    final event = CalendarEvent.timed(
      id: id,
      title: title,
      startLocal: start,
      endLocal: end,
      timeZoneId: zone,
      notes: notes,
      color: color,
      seriesId: series,
      importSource: '$sourcePrefix${_hash(identity).substring(0, 24)}',
    );
    return CalendarEvent.timed(
      id: event.id,
      title: event.title,
      startLocal: start,
      endLocal: end,
      timeZoneId: zone,
      notes: notes,
      color: color,
      seriesId: series,
      importSource: event.importSource,
      importFingerprint: fingerprint(event),
    );
  }

  CalendarEvent _record(Map<String, dynamic> row, String fallback) {
    if (row['allDay'] == true ||
        row['allDayStartDate'] != null ||
        row['deletedAtUtc'] != null) {
      throw const FormatException('全天或已删除日程已跳过。');
    }
    String field(String key) => (row[key] ?? '').toString();
    final zone = location(
      field('timeZoneId').isEmpty ? fallback : field('timeZoneId'),
    ).name;
    final start = _iso(field('start'), zone);
    final end = _iso(field('end'), zone);
    return _event(
      title: field('title'),
      start: start,
      end: end,
      zone: zone,
      uid: field('id').isEmpty ? null : 'record:${field('id')}',
      nativeId: row['_native'] == true ? field('id') : null,
      series: field('seriesId').isEmpty
          ? null
          : 'cio-series-${_hash(field('seriesId')).substring(0, 24)}',
      notes: field('notes'),
      color: _color(field('color')),
    );
  }

  DateTime _iso(String text, String zone) {
    final match = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?$',
    ).firstMatch(text.trim());
    if (match == null) {
      throw const FormatException('时间应包含日期与时分，例如 2026-11-06 08:00。');
    }
    final parts = [for (var i = 1; i <= 6; i++) int.parse(match[i] ?? '0')];
    _validateDate(parts);
    if (match[7] != null) {
      final offset = match[7]!.replaceAll(':', '');
      if (offset != 'Z' &&
          (int.parse(offset.substring(1, 3)) > 14 ||
              int.parse(offset.substring(3)) > 59)) {
        throw const FormatException('时间中的 UTC 偏移量无效。');
      }
      return DateTime.parse(text.trim()).toUtc();
    }
    return _wall(location(zone), parts);
  }

  static void _validateDate(List<int> p) {
    final d = DateTime.utc(p[0], p[1], p[2], p[3], p[4], p[5]);
    if (d.year != p[0] ||
        d.month != p[1] ||
        d.day != p[2] ||
        d.hour != p[3] ||
        d.minute != p[4] ||
        d.second != p[5]) {
      throw const FormatException('日期或时间不存在，已跳过。');
    }
  }

  static tz.TZDateTime _wall(tz.Location zone, List<int> p) {
    final d = tz.TZDateTime(zone, p[0], p[1], p[2], p[3], p[4], p[5]);
    if (d.hour != p[3] || d.minute != p[4]) {
      throw const FormatException('日程落在夏令时跳过的时刻，已跳过。');
    }
    return d;
  }

  List<Map<String, dynamic>> _jsonRows(String text) {
    final Object? value;
    try {
      value = jsonDecode(text);
    } on FormatException {
      throw const FormatException('JSON 格式无效。');
    }
    final cloud = value is Map && value['format'] == 'weekglass-json-v1';
    final native =
        cloud ||
        (value is Map &&
            value['format'] == 'weekglass-calendar' &&
            value['version'] == 1);
    final list = cloud && value['records'] is List
        ? (value['records'] as List)
              .where(
                (r) =>
                    r is Map &&
                    r['deleted_at_utc'] == null &&
                    r['event'] is Map,
              )
              .map((r) => r['event'])
              .toList()
        : value is List
        ? value
        : (value is Map ? value['events'] : null);
    if (list is! List) {
      throw const FormatException('JSON 应为日程数组或 WeekGlass 导出文件。');
    }
    return list
        .map(
          (row) => row is Map
              ? <String, dynamic>{
                  ...row.map((key, value) => MapEntry(key.toString(), value)),
                  'start': row['start'] ?? row['startUtc'] ?? row['start_utc'],
                  'end': row['end'] ?? row['endUtc'] ?? row['end_utc'],
                  'timeZoneId': row['timeZoneId'] ?? row['time_zone_id'],
                  'color': row['color'] ?? row['color_key'],
                  'seriesId': row['seriesId'] ?? row['series_id'],
                  'allDayStartDate':
                      row['allDayStartDate'] ??
                      row['all_day_start_date'] ??
                      row['all_day_start'],
                  'deletedAtUtc': row['deletedAtUtc'] ?? row['deleted_at_utc'],
                  '_native': native,
                }
              : <String, dynamic>{},
        )
        .toList();
  }

  List<Map<String, dynamic>> _csvRows(String text) {
    final rows = parseCsv(text);
    if (rows.isEmpty) throw const FormatException('CSV 文件为空。');
    const aliases = {
      '名称': 'title',
      '日程': 'title',
      '标题': 'title',
      '开始': 'start',
      '开始时间': 'start',
      '结束': 'end',
      '结束时间': 'end',
      '备注': 'notes',
      '颜色': 'color',
      '时区': 'timeZoneId',
      '批次': 'seriesId',
      '编号': 'id',
    };
    final headers = rows.first
        .map((e) => aliases[e.trim()] ?? e.trim())
        .toList();
    if (!headers.contains('title') ||
        !headers.contains('start') ||
        !headers.contains('end')) {
      throw const FormatException('CSV 需要“名称、开始、结束”三列；也支持 title、start、end。');
    }
    return rows
        .skip(1)
        .where((row) => row.any((s) => s.isNotEmpty))
        .map(
          (row) => {
            for (var i = 0; i < headers.length && i < row.length; i++)
              headers[i]:
                  // Our CSV uses an apostrophe to neutralize spreadsheet formulas.
                  row[i].startsWith("'") &&
                      RegExp(r"^'[=+@\-\t\r]").hasMatch(row[i])
                  ? row[i].substring(1)
                  : row[i],
          },
        )
        .toList();
  }

  static List<List<String>> parseCsv(String text) {
    final rows = <List<String>>[];
    var row = <String>[];
    var cell = StringBuffer();
    var quoted = false;
    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      if (c == '"') {
        if (quoted && i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else if (quoted || cell.isEmpty) {
          quoted = !quoted;
        } else {
          throw const FormatException('CSV 引号位置无效。');
        }
      } else if (c == ',' && !quoted) {
        row.add(cell.toString());
        cell = StringBuffer();
      } else if ((c == '\n' || c == '\r') && !quoted) {
        if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
        row.add(cell.toString());
        rows.add(row);
        row = [];
        cell = StringBuffer();
      } else {
        cell.write(c);
      }
    }
    if (quoted) throw const FormatException('CSV 引号没有闭合。');
    if (cell.isNotEmpty || row.isNotEmpty) {
      row.add(cell.toString());
      rows.add(row);
    }
    return rows;
  }

  void _readIcs(
    String text,
    String fallback,
    DateTime first,
    DateTime last,
    void Function(CalendarEvent) add,
    void Function(Object) invalid,
    Set<String> messages,
  ) {
    if (!text.toUpperCase().contains('BEGIN:VCALENDAR')) {
      throw const FormatException('不是有效的 ICS 日历文件。');
    }
    final lines = text
        .replaceAll(RegExp(r'\r?\n[ \t]'), '')
        .split(RegExp(r'\r?\n'));
    final records = <List<_Property>>[];
    List<_Property>? current;
    var nested = 0;
    for (final line in lines) {
      if (current == null && line.toUpperCase().startsWith('X-WR-TIMEZONE:')) {
        fallback = line.substring(line.indexOf(':') + 1).trim();
      }
      if (line.toUpperCase() == 'BEGIN:VEVENT') {
        current = [];
        nested = 0;
      } else if (line.toUpperCase() == 'END:VEVENT') {
        if (current != null) records.add(current);
        current = null;
      } else if (current != null) {
        if (line.toUpperCase().startsWith('BEGIN:')) {
          nested++;
        } else if (line.toUpperCase().startsWith('END:')) {
          nested--;
        } else if (nested == 0 && line.contains(':')) {
          current.add(_Property.parse(line));
        }
      }
    }
    if (records.length > maxEvents) {
      throw const FormatException('文件超过 5000 项，请拆分后导入。');
    }
    final overrides = <String, Map<int, List<_Property>>>{};
    final used = <List<_Property>>{};
    final unsupportedSeries = <String>{};
    for (final record in records) {
      final recurrence = record.prop('RECURRENCE-ID');
      if (recurrence == null) continue;
      try {
        if (recurrence.params['RANGE'] != null) {
          unsupportedSeries.add(record.value('UID'));
          throw const FormatException('不支持 THISANDFUTURE 例外，请从原日历导出展开后的日程。');
        }
        final key = _icsDate(
          recurrence,
          fallback,
        ).instant.millisecondsSinceEpoch;
        (overrides[record.value('UID')] ??= {})[key] = record;
      } catch (error) {
        invalid(error);
        used.add(record);
      }
    }
    final cancelled = records
        .where(
          (r) =>
              r.prop('RECURRENCE-ID') == null &&
              r.value('STATUS').toUpperCase() == 'CANCELLED',
        )
        .map((r) => r.value('UID'))
        .toSet();
    for (final record in records.where(
      (r) => r.prop('RECURRENCE-ID') == null,
    )) {
      if (record.value('STATUS').toUpperCase() == 'CANCELLED' ||
          unsupportedSeries.contains(record.value('UID'))) {
        continue;
      }
      try {
        if (record.prop('EXRULE') != null ||
            record.where((p) => p.name == 'RRULE').length > 1) {
          throw const FormatException('不支持此日程的组合重复规则，请从原日历导出展开后的日程。');
        }
        final startProp = record.prop('DTSTART');
        if (startProp == null) throw const FormatException('一项日程缺少开始时间。');
        final start = _icsDate(startProp, fallback);
        final end = _icsEnd(record, start);
        final duration = end.difference(start.instant);
        if (duration <= Duration.zero) {
          throw const FormatException('一项日程结束时间早于开始时间。');
        }
        final uid = record.value('UID').isEmpty
            ? _hash(record.map((p) => p.value).join('|'))
            : record.value('UID');
        final occurrenceOverrides = overrides[record.value('UID')] ?? {};
        final excluded = <int>{};
        for (final p in record.where((p) => p.name == 'EXDATE')) {
          for (final value in p.value.split(',')) {
            excluded.add(
              _icsDate(
                p.withValue(value),
                start.zone,
              ).instant.millisecondsSinceEpoch,
            );
          }
        }
        final occurrences = <int, DateTime>{
          start.instant.millisecondsSinceEpoch: start.instant,
        };
        final ruleText = record.value('RRULE');
        if (ruleText.isNotEmpty) {
          if (!RegExp(r'FREQ=(DAILY|WEEKLY|MONTHLY|YEARLY)(;|$)')
              .hasMatch(ruleText)) {
            throw const FormatException('仅支持按日、周、月、年的重复日程。');
          }
          var rule = ruleText;
          final until = RegExp(r'UNTIL=(\d{8}T\d{6}Z)').firstMatch(rule);
          if (until != null) {
            final localUntil = tz.TZDateTime.from(
              _icsDate(_Property('UNTIL', {}, until[1]!), 'UTC').instant,
              location(start.zone),
            );
            rule = rule.replaceFirst(
              until[0]!,
              'UNTIL=${_icsStamp(_asWall(localUntil))}',
            );
          }
          final recurrence = RecurrenceRule.fromString('RRULE:$rule');
          final wallStart = _asWall(
            tz.TZDateTime.from(start.instant, location(start.zone)),
          );
          final wallFirst = _asWall(
            tz.TZDateTime.from(first.subtract(duration), location(start.zone)),
          );
          final wallLast = _asWall(
            tz.TZDateTime.from(last, location(start.zone)),
          );
          var count = 0;
          for (final date in recurrence.getInstances(
            start: wallStart,
            after: wallFirst.isBefore(wallStart) ? wallStart : wallFirst,
            before: wallLast.isBefore(wallStart) ? wallStart : wallLast,
            includeAfter: true,
          )) {
            if (++count > maxEvents) {
              throw const FormatException('重复日程过多，请缩小日期范围。');
            }
            try {
              final instant = _wall(location(start.zone), [
                date.year,
                date.month,
                date.day,
                date.hour,
                date.minute,
                date.second,
              ]);
              occurrences[instant.millisecondsSinceEpoch] = instant;
            } catch (error) {
              invalid(error);
            }
          }
          messages.add('重复规则已按所选日期范围展开；后续日期可再次导入，已有日程会自动跳过。');
        }
        for (final p in record.where((p) => p.name == 'RDATE')) {
          for (final value in p.value.split(',')) {
            final date = _icsDate(p.withValue(value), start.zone).instant;
            occurrences[date.millisecondsSinceEpoch] = date;
          }
        }
        final series = ruleText.isNotEmpty || occurrences.length > 1
            ? 'cio-series-${_hash(uid).substring(0, 24)}'
            : null;
        for (final entry in occurrences.entries) {
          final replacement = occurrenceOverrides[entry.key];
          if (replacement != null) used.add(replacement);
          if (replacement?.value('STATUS').toUpperCase() == 'CANCELLED' ||
              excluded.contains(entry.key)) {
            continue;
          }
          try {
            final data = replacement ?? record;
            final actualStart = replacement == null
                ? entry.value
                : _icsDate(data.prop('DTSTART')!, start.zone).instant;
            final actualEnd = replacement == null
                ? actualStart.add(duration)
                : _icsEnd(data, _IcsDate(actualStart, start.zone));
            add(
              _icsEvent(
                data,
                uid: '$uid:${entry.key}',
                start: actualStart,
                end: actualEnd,
                zone: start.zone,
                series: series,
                fallbackRecord: record,
              ),
            );
          } catch (error) {
            invalid(error);
          }
        }
      } catch (error) {
        invalid(error);
      }
    }
    // A moved occurrence can enter this range even when its original date is
    // outside it, or the exporter can send detached occurrences without a master.
    for (final record in records.where(
      (r) => r.prop('RECURRENCE-ID') != null && !used.contains(r),
    )) {
      if (record.value('STATUS').toUpperCase() == 'CANCELLED' ||
          cancelled.contains(record.value('UID')) ||
          unsupportedSeries.contains(record.value('UID'))) {
        continue;
      }
      try {
        final start = _icsDate(record.prop('DTSTART')!, fallback);
        final original = _icsDate(
          record.prop('RECURRENCE-ID')!,
          start.zone,
        ).instant;
        final uid = record.value('UID');
        add(
          _icsEvent(
            record,
            uid: '$uid:${original.millisecondsSinceEpoch}',
            start: start.instant,
            end: _icsEnd(record, start),
            zone: start.zone,
            series: 'cio-series-${_hash(uid).substring(0, 24)}',
          ),
        );
      } catch (error) {
        invalid(error);
      }
    }
  }

  CalendarEvent _icsEvent(
    List<_Property> record, {
    required String uid,
    required DateTime start,
    required DateTime end,
    required String zone,
    String? series,
    List<_Property>? fallbackRecord,
  }) {
    String value(String key) =>
        record.prop(key)?.value ?? fallbackRecord?.value(key) ?? '';
    final description = _unescape(value('DESCRIPTION'));
    final place = _unescape(value('LOCATION'));
    final notes = [
      description,
      if (place.isNotEmpty && !description.contains(place)) '地点：$place',
    ].where((s) => s.isNotEmpty).join('\n');
    return _event(
      title: _unescape(value('SUMMARY')),
      start: start,
      end: end,
      zone: value('X-WEEKGLASS-TIMEZONE').isEmpty
          ? zone
          : location(value('X-WEEKGLASS-TIMEZONE')).name,
      uid: uid,
      series: value('X-WEEKGLASS-SERIES').isEmpty
          ? series
          : 'cio-series-${_hash(value('X-WEEKGLASS-SERIES')).substring(0, 24)}',
      nativeId: value('X-WEEKGLASS-ID').isEmpty
          ? null
          : value('X-WEEKGLASS-ID'),
      notes: notes,
      color: _color(
        value('X-WEEKGLASS-COLOR').isEmpty
            ? value('COLOR')
            : value('X-WEEKGLASS-COLOR'),
      ),
    );
  }

  _IcsDate _icsDate(_Property p, String fallback) {
    if (p.params['VALUE'] == 'DATE' || RegExp(r'^\d{8}$').hasMatch(p.value)) {
      throw const FormatException('全天日程已跳过；WeekGlass 只显示有起止时间的日程。');
    }
    final m = RegExp(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z)?$')
        .firstMatch(p.value);
    if (m == null) throw const FormatException('ICS 日期格式不完整，已跳过。');
    final parts = [for (var i = 1; i <= 6; i++) int.parse(m[i]!)];
    _validateDate(parts);
    final zone = m[7] == 'Z' ? 'UTC' : (p.params['TZID'] ?? fallback);
    return _IcsDate(_wall(location(zone), parts), location(zone).name);
  }

  DateTime _icsEnd(List<_Property> row, _IcsDate start) {
    final end = row.prop('DTEND');
    if (end != null) return _icsDate(end, start.zone).instant;
    final duration = RegExp(
      r'^P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$',
    ).firstMatch(row.value('DURATION'));
    if (duration == null) throw const FormatException('一项日程缺少结束时间或时长。');
    int part(int i) => int.parse(duration[i] ?? '0');
    return start.instant.add(
      Duration(
        days: part(1) * 7 + part(2),
        hours: part(3),
        minutes: part(4),
        seconds: part(5),
      ),
    );
  }

  static DateTime _asWall(DateTime d) =>
      DateTime.utc(d.year, d.month, d.day, d.hour, d.minute, d.second);
  static String _unescape(String s) => s.replaceAllMapped(
    RegExp(r'\\([nN,;\\])'),
    (m) => m[1]!.toLowerCase() == 'n' ? '\n' : m[1]!,
  );
  static String _escape(String s) => s
      .replaceAll('\\', '\\\\')
      .replaceAll('\r\n', '\n')
      .replaceAll('\n', r'\n')
      .replaceAll(';', r'\;')
      .replaceAll(',', r'\,');
  static String _icsStamp(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}${_two(d.month)}${_two(d.day)}T${_two(d.hour)}${_two(d.minute)}${_two(d.second)}Z';
  static String _two(int n) => n.toString().padLeft(2, '0');
  static EventColor _color(String value) {
    value = value.trim();
    for (final color in EventColor.values) {
      if (value == color.key || value == color.label) return color;
    }
    return switch (value.toLowerCase()) {
      'blue' || '#7f9bc9' || '蓝色' => EventColor.mistBlue,
      'purple' || 'violet' || '紫色' => EventColor.lavender,
      'green' || 'teal' || '绿色' || '青色' => EventColor.sageGreen,
      'orange' || '橙色' => EventColor.softPeach,
      'red' || 'pink' || '红色' || '粉色' => EventColor.rose,
      'yellow' || 'gold' || '黄色' || '金色' => EventColor.warmSand,
      'gray' || 'grey' || '灰色' => EventColor.slate,
      _ => EventColor.mistBlue,
    };
  }

  String encode(Iterable<CalendarEvent> events, CalendarFileFormat format) {
    final items =
        events.where((e) => !e.isAllDay && e.deletedAtUtc == null).toList()
          ..sort((a, b) => a.startUtc!.compareTo(b.startUtc!));
    if (format == CalendarFileFormat.json) {
      return const JsonEncoder.withIndent('  ').convert({
        'format': 'weekglass-calendar',
        'version': 1,
        'events': [
          for (final e in items)
            {
              'id': e.id,
              'title': e.title,
              'start': e.startUtc!.toIso8601String(),
              'end': e.endUtc!.toIso8601String(),
              'timeZoneId': e.timeZoneId,
              'notes': e.notes ?? '',
              'color': e.color.key,
              'seriesId': e.seriesId,
            },
        ],
      });
    }
    if (format == CalendarFileFormat.csv) {
      String cell(String value) {
        if (RegExp(r'^[=+@\-\t\r]').hasMatch(value)) value = "'$value";
        return '"${value.replaceAll('"', '""')}"';
      }

      return '\uFEFF${[
        ['title', 'start', 'end', 'timeZoneId', 'notes', 'color', 'seriesId', 'id'],
        for (final e in items) [e.title, e.startUtc!.toIso8601String(), e.endUtc!.toIso8601String(), e.timeZoneId, e.notes ?? '', e.color.key, e.seriesId ?? '', e.id],
      ].map((row) => row.map(cell).join(',')).join('\r\n')}\r\n';
    }
    final lines = [
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      'PRODID:-//WeekGlass//Calendar//ZH',
      'CALSCALE:GREGORIAN',
      for (final e in items) ...[
        'BEGIN:VEVENT',
        'UID:${_escape(e.id)}@weekglass',
        'DTSTAMP:${_icsStamp(e.updatedAtUtc)}',
        'DTSTART:${_icsStamp(e.startUtc!)}',
        'DTEND:${_icsStamp(e.endUtc!)}',
        'SUMMARY:${_escape(e.title)}',
        'DESCRIPTION:${_escape(e.notes ?? '')}',
        'X-WEEKGLASS-ID:${e.id}',
        'X-WEEKGLASS-COLOR:${e.color.key}',
        'X-WEEKGLASS-TIMEZONE:${e.timeZoneId}',
        if (e.seriesId != null) 'X-WEEKGLASS-SERIES:${_escape(e.seriesId!)}',
        'END:VEVENT',
      ],
      'END:VCALENDAR',
    ];
    // RFC 5545 folding counts UTF-8 octets, never split a Chinese character.
    String fold(String line) {
      final out = StringBuffer();
      var size = 0;
      for (final rune in line.runes) {
        final char = String.fromCharCode(rune),
            length = utf8.encode(String.fromCharCode(rune)).length;
        if (size + length > 75) {
          out.write('\r\n ');
          size = 1;
        }
        out.write(char);
        size += length;
      }
      return out.toString();
    }

    return '${lines.map(fold).join('\r\n')}\r\n';
  }
}

class _IcsDate {
  const _IcsDate(this.instant, this.zone);
  final DateTime instant;
  final String zone;
}

class _Property {
  const _Property(this.name, this.params, this.value);
  final String name, value;
  final Map<String, String> params;
  _Property withValue(String value) => _Property(name, params, value);
  factory _Property.parse(String line) {
    var quoted = false, colon = -1;
    for (var i = 0; i < line.length; i++) {
      if (line[i] == '"') quoted = !quoted;
      if (line[i] == ':' && !quoted) {
        colon = i;
        break;
      }
    }
    if (colon < 0) throw const FormatException('ICS 属性格式无效。');
    final parts = line.substring(0, colon).split(';');
    return _Property(parts.first.toUpperCase(), {
      for (final item in parts.skip(1).where((s) => s.contains('=')))
        item.substring(0, item.indexOf('=')).toUpperCase(): item
            .substring(item.indexOf('=') + 1)
            .replaceAll('"', ''),
    }, line.substring(colon + 1));
  }
}

extension on List<_Property> {
  _Property? prop(String name) {
    for (final p in this) {
      if (p.name == name) return p;
    }
    return null;
  }

  String value(String name) => prop(name)?.value ?? '';
}
