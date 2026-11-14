import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:weekglass/features/calendar_io/calendar_codec.dart';
import 'package:weekglass/features/calendar_io/calendar_pdf.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

void main() {
  final codec = CalendarCodec();
  CalendarImportResult decode(
    String text, {
    CalendarFileFormat format = CalendarFileFormat.ics,
    List<CalendarEvent> existing = const [],
  }) => codec.decode(
    text: text,
    format: format,
    timeZoneId: 'Asia/Shanghai',
    rangeStart: DateTime(2026),
    rangeEnd: DateTime(2027),
    existing: existing,
  );
  String ics(String body) =>
      'BEGIN:VCALENDAR\r\nVERSION:2.0\r\n$body\r\nEND:VCALENDAR';
  String event(String body) => 'BEGIN:VEVENT\r\n$body\r\nEND:VEVENT';
  CalendarEvent example({String id = 'fictional-a', String title = '洗漱与阅读'}) =>
      CalendarEvent.timed(
        id: id,
        title: title,
        startLocal: DateTime.utc(2026, 11, 2, 0, 15),
        endLocal: DateTime.utc(2026, 11, 2, 0, 45),
        timeZoneId: 'Asia/Shanghai',
        notes: '第一行，逗号；分号\n第二行 "引号" 和 \\ 路径',
        color: EventColor.lavender,
        seriesId: 'fictional-series',
      );

  test('ICS local TZID, folded Chinese, escaped notes and location', () {
    final result = decode(
      ics(
        event(
          'UID:abc\r\nDTSTART;TZID="Asia/Shanghai":20261102T081500\r\nDTEND;TZID=Asia/Shanghai:20261102T084500\r\nSUMMARY:洗漱与\r\n 阅读\r\nDESCRIPTION:第一行\\n第二行\\,还有\\;分号\r\nLOCATION:图书馆',
        ),
      ),
    );
    final e = result.events.single;
    expect(e.startUtc, DateTime.utc(2026, 11, 2, 0, 15));
    expect(e.title, '洗漱与阅读');
    expect(e.notes, '第一行\n第二行,还有;分号\n地点：图书馆');
  });

  test('UTC and floating times have correct independent offsets', () {
    final result = decode(
      ics(
        '${event('UID:utc\r\nDTSTART:20261102T001500Z\r\nDTEND:20261102T004500Z\r\nSUMMARY:UTC')}\r\n${event('UID:float\r\nDTSTART:20261102T081500\r\nDURATION:PT30M\r\nSUMMARY:浮动')}',
      ),
    );
    expect(result.events.map((e) => e.startUtc).toSet(), {
      DateTime.utc(2026, 11, 2, 0, 15),
    });
    expect(result.events.length, 2);
  });

  test('UTF-16 file bytes and calendar-level timezone are respected', () {
    final source = '名称,开始,结束\n阅读,2026-11-02 08:00,2026-11-02 09:00';
    final bytes = [
      255,
      254,
      for (final unit in source.codeUnits) ...[unit & 255, unit >> 8],
    ];
    expect(CalendarCodec.decodeText(bytes), source);
    expect(
      () => CalendarCodec.decodeText([255, 0, 128]),
      throwsFormatException,
    );
    final result = decode(
      ics(
        'X-WR-TIMEZONE:America/New_York\r\n${event('UID:calendar-zone\r\nDTSTART:20261102T080000\r\nDURATION:PT1H\r\nSUMMARY:日历时区')}',
      ),
    );
    expect(result.events.single.startUtc, DateTime.utc(2026, 11, 2, 13));
  });

  test('weekly RRULE preserves 9 AM wall time across DST', () {
    final result = decode(
      ics(
        event(
          'UID:dst\r\nDTSTART;TZID=America/New_York:20260301T090000\r\nDTEND;TZID=America/New_York:20260301T100000\r\nRRULE:FREQ=WEEKLY;COUNT=3\r\nSUMMARY:晨间研讨',
        ),
      ),
    );
    expect(result.events.map((e) => e.startUtc!.hour), [14, 13, 13]);
    expect(result.events.map((e) => e.seriesId).toSet().length, 1);
    expect(result.events.first.seriesId, isNotNull);
  });

  test('monthly BYDAY and EXDATE, cancellation, moved override', () {
    final result = decode(
      ics(
        [
          event(
            'UID:series\r\nDTSTART;TZID=Asia/Shanghai:20261102T080000\r\nDTEND;TZID=Asia/Shanghai:20261102T090000\r\nRRULE:FREQ=WEEKLY;COUNT=4\r\nEXDATE;TZID=Asia/Shanghai:20261109T080000\r\nSUMMARY:原日程',
          ),
          event(
            'UID:series\r\nRECURRENCE-ID;TZID=Asia/Shanghai:20261116T080000\r\nDTSTART;TZID=Asia/Shanghai:20261117T100000\r\nDTEND;TZID=Asia/Shanghai:20261117T110000\r\nSUMMARY:调课',
          ),
          event(
            'UID:series\r\nRECURRENCE-ID;TZID=Asia/Shanghai:20261123T080000\r\nSTATUS:CANCELLED',
          ),
        ].join('\r\n'),
      ),
    );
    expect(result.events.length, 2);
    expect(result.events.last.title, '调课');
    expect(result.events.last.startUtc, DateTime.utc(2026, 11, 17, 2));
    final monthly = decode(
      ics(
        event(
          'UID:month\r\nDTSTART:20260907T080000Z\r\nDURATION:PT1H\r\nRRULE:FREQ=MONTHLY;BYDAY=1MO;COUNT=3\r\nSUMMARY:月会',
        ),
      ),
    );
    expect(monthly.events.map((e) => e.startUtc!.day), [7, 5, 2]);
  });

  test('UTC UNTIL includes its last local recurrence', () {
    final result = decode(
      ics(
        event(
          'UID:until\r\nDTSTART;TZID=Asia/Shanghai:20261102T080000\r\nDURATION:PT1H\r\nRRULE:FREQ=WEEKLY;UNTIL=20261116T000000Z\r\nSUMMARY:直到',
        ),
      ),
    );
    expect(result.events.length, 3);
  });

  test('cancelled series and unsupported future overrides never create misleading dates', () {
    final cancelled = decode(
      ics(
        [
          event(
            'UID:cancelled\r\nDTSTART:20261102T080000Z\r\nDURATION:PT1H\r\nRRULE:FREQ=WEEKLY;COUNT=3\r\nSTATUS:CANCELLED\r\nSUMMARY:取消',
          ),
          event(
            'UID:cancelled\r\nRECURRENCE-ID:20261109T080000Z\r\nDTSTART:20261110T080000Z\r\nDURATION:PT1H\r\nSUMMARY:已取消的例外',
          ),
        ].join('\r\n'),
      ),
    );
    expect(cancelled.events, isEmpty);
    final unsupported = decode(
      ics(
        [
          event(
            'UID:future\r\nDTSTART:20261102T080000Z\r\nDURATION:PT1H\r\nRRULE:FREQ=WEEKLY;COUNT=3\r\nSUMMARY:原日程',
          ),
          event(
            'UID:future\r\nRECURRENCE-ID;RANGE=THISANDFUTURE:20261109T080000Z\r\nDTSTART:20261110T080000Z\r\nDURATION:PT1H\r\nSUMMARY:此后更改',
          ),
        ].join('\r\n'),
      ),
    );
    expect(unsupported.events, isEmpty);
    expect(unsupported.messages.join(), contains('THISANDFUTURE'));
  });

  test('RDATE expands and duplicates collapse across a file and reimport', () {
    final text = ics(
      event(
        'UID:rdates\r\nDTSTART:20261102T080000Z\r\nDURATION:PT1H\r\nRDATE:20261102T080000Z,20261103T080000Z\r\nSUMMARY:特别日程',
      ),
    );
    final initial = decode(text);
    expect(initial.events.length, 2);
    final again = decode(text, existing: initial.events);
    expect(again.events, isEmpty);
    expect(again.duplicateCount, 2);
    final deleted = initial.events.first.markedDeleted(
      DateTime.utc(2026, 11, 5),
    );
    expect(
      decode(text, existing: [deleted, initial.events.last]).events,
      isEmpty,
    );
  });

  test('invalid dates, unknown zones, all-day and negative durations skip without losing valid rows', () {
    final result = decode(
      ics(
        [
          event(
            'UID:date\r\nDTSTART:20260230T080000Z\r\nDURATION:PT1H\r\nSUMMARY:无效日期',
          ),
          event(
            'UID:zone\r\nDTSTART;TZID=Mars/City:20261102T080000\r\nDURATION:PT1H\r\nSUMMARY:未知时区',
          ),
          event(
            'UID:all\r\nDTSTART;VALUE=DATE:20261102\r\nDTEND;VALUE=DATE:20261103\r\nSUMMARY:全天',
          ),
          event(
            'UID:negative\r\nDTSTART:20261102T080000Z\r\nDTEND:20261102T070000Z\r\nSUMMARY:负时长',
          ),
          event(
            'UID:valid\r\nDTSTART:20261102T080000Z\r\nDURATION:PT15M\r\nSUMMARY:有效',
          ),
        ].join('\r\n'),
      ),
    );
    expect(result.events.single.title, '有效');
    expect(result.skippedCount, 4);
    expect(result.messages.length, greaterThanOrEqualTo(4));
  });

  test('nonexistent DST time is reported rather than silently shifted', () {
    final result = decode(
      ics(
        event(
          'UID:gap\r\nDTSTART;TZID=America/New_York:20260308T023000\r\nDURATION:PT1H\r\nSUMMARY:不存在的时间',
        ),
      ),
    );
    expect(result.events, isEmpty);
    expect(result.messages.join(), contains('夏令时'));
  });

  test('JSON, ICS and CSV preserve Unicode, time, notes and color', () {
    for (final format in CalendarFileFormat.values) {
      final source = example();
      final encoded = codec.encode([source], format);
      final result = decode(encoded, format: format);
      expect(result.events.single.title, source.title, reason: format.name);
      expect(result.events.single.notes, source.notes, reason: format.name);
      expect(
        result.events.single.startUtc,
        source.startUtc,
        reason: format.name,
      );
      expect(result.events.single.color, source.color, reason: format.name);
      expect(
        result.events.single.timeZoneId,
        'Asia/Shanghai',
        reason: format.name,
      );
      expect(result.events.single.seriesId, isNotNull);
      expect(
        decode(encoded, format: format, existing: [source]).events,
        isEmpty,
      );
    }
  });

  test('ICS lines are folded on UTF-8 octets without broken characters', () {
    final encoded = codec.encode([
      example(title: '晨光与阅读' * 30),
    ], CalendarFileFormat.ics);
    expect(
      encoded.split('\r\n').every((line) => utf8.encode(line).length <= 75),
      isTrue,
    );
    expect(decode(encoded).events.single.title, '晨光与阅读' * 30);
  });

  test('CSV rejects malformed quotes, reads Chinese headers, prevents formulas on export', () {
    final result = decode(
      '名称,开始,结束,备注,颜色\r\n"阅读,写作",2026-11-02 08:00,2026-11-02 09:00,"第一行\n第二行",鸢尾紫',
      format: CalendarFileFormat.csv,
    );
    expect(result.events.single.title, '阅读,写作');
    expect(result.events.single.color, EventColor.lavender);
    expect(
      () => decode(
        'title,start,end\n"missing quote',
        format: CalendarFileFormat.csv,
      ),
      throwsFormatException,
    );
    final text = codec.encode([
      example(title: '=SUM(A1:A3)'),
    ], CalendarFileFormat.csv);
    expect(text, contains("'=SUM"));
    expect(
      decode(text, format: CalendarFileFormat.csv).events.single.title,
      '=SUM(A1:A3)',
    );
  });

  test(
    'cloud JSON reads active snake_case rows; tombstones never delete locals',
    () {
      final json = jsonEncode({
        'format': 'weekglass-json-v1',
        'records': [
          {
            'id': 'cloud-a',
            'deleted_at_utc': null,
            'event': {
              'id': 'cloud-a',
              'title': '虚构云日程',
              'start_utc': '2026-11-02T00:00:00Z',
              'end_utc': '2026-11-02T01:00:00Z',
              'time_zone_id': 'Asia/Shanghai',
              'color_key': 'rose',
              'notes': '地点：测试房间',
            },
          },
          {
            'id': 'deleted',
            'deleted_at_utc': '2026-11-01T00:00:00Z',
            'event': null,
          },
        ],
      });
      final result = decode(json, format: CalendarFileFormat.json);
      expect(result.events.single.id, 'cloud-a');
      expect(result.events.single.color, EventColor.rose);
      expect(result.events.single.notes, '地点：测试房间');
    },
  );

  test('unbounded recurrence expands only the selected range', () {
    final result = codec.decode(
      text: ics(
        event(
          'UID:forever\r\nDTSTART:20200101T080000Z\r\nDURATION:PT1H\r\nRRULE:FREQ=DAILY\r\nSUMMARY:每天',
        ),
      ),
      format: CalendarFileFormat.ics,
      timeZoneId: 'UTC',
      rangeStart: DateTime(2026, 11, 2),
      rangeEnd: DateTime(2026, 11, 9),
    );
    expect(result.events.length, 7);
    expect(result.messages.join(), contains('所选日期范围'));
  });

  test(
    'color and monochrome weekly PDFs support Chinese and long-note pagination',
    () async {
      final fontFile = File('assets/fonts/NotoSansSC-Variable.ttf');
      final font = ByteData.sublistView(await fontFile.readAsBytes());
      final events = <CalendarEvent>[
        for (var i = 0; i < 22; i++)
          CalendarEvent.timed(
            id: 'fictional-$i',
            title: '虚构日程 ${i + 1}：阅读与练习',
            startLocal: DateTime.utc(2026, 11, 2 + i % 7, i % 12),
            endLocal: DateTime.utc(2026, 11, 2 + i % 7, i % 12, 45),
            timeZoneId: 'Asia/Shanghai',
            color: EventColor.values[i % EventColor.values.length],
            notes: i == 0
                ? '${'较长备注用于检查自动续页，文字必须完整。\n' * 70}备注结尾校验'
                : '地点：测试房间\n教师：示例老师',
          ),
        CalendarEvent.timed(
          id: 'fictional-next',
          title: '下一周的虚构日程',
          startLocal: DateTime.utc(2026, 11, 9, 1),
          endLocal: DateTime.utc(2026, 11, 9, 2),
          timeZoneId: 'Asia/Shanghai',
          notes: '第二周分页校验',
        ),
      ];
      for (final monochrome in [false, true]) {
        final bytes = await CalendarPdf.build(
          events: events,
          rangeStart: DateTime(2026, 11, 2),
          rangeEnd: DateTime(2026, 11, 16),
          timeZoneId: 'Asia/Shanghai',
          chineseFont: font,
          monochrome: monochrome,
        );
        expect(bytes.take(5), '%PDF-'.codeUnits);
        expect(bytes.length, greaterThan(10000));
        final output = Platform.environment['WG_CALENDAR_QA_OUTPUT'];
        if (output != null) {
          await Directory(output).create(recursive: true);
          await File('$output/calendar-${monochrome ? 'mono' : 'color'}.pdf')
              .writeAsBytes(bytes);
        }
      }
    },
  );
}
