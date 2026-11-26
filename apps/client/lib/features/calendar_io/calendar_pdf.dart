import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:timezone/timezone.dart' as tz;
import 'package:weekglass_domain/weekglass_domain.dart';

import 'calendar_codec.dart';

part 'calendar_pdf_week.dart';

/// A compact black-and-white agenda for printing.
class CalendarPdf {
  static Future<Uint8List> build({
    required Iterable<CalendarEvent> events,
    required DateTime rangeStart,
    required DateTime rangeEnd,
    required String timeZoneId,
    required ByteData chineseFont,
  }) async {
    if (!rangeEnd.isAfter(rangeStart) ||
        rangeEnd.difference(rangeStart).inDays > 366) {
      throw const FormatException('PDF 日期范围请控制在一年以内。');
    }
    final codec = CalendarCodec();
    final zone = codec.location(timeZoneId);
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
    final items =
        events
            .where(
              (e) =>
                  !e.isAllDay &&
                  e.deletedAtUtc == null &&
                  e.startUtc!.isBefore(last) &&
                  e.endUtc!.isAfter(first),
            )
            .toList()
          ..sort((a, b) => a.startUtc!.compareTo(b.startUtc!));
    if (items.length > CalendarCodec.maxEvents) {
      throw const FormatException('导出日程超过 5000 条，请缩小日期范围。');
    }
    final font = pw.Font.ttf(chineseFont);
    final doc = pw.Document(title: 'WeekGlass 周日程', author: 'WeekGlass');
    final printFont = font.getFont(pw.Context(document: doc.document));
    var week = DateTime.utc(
      first.year,
      first.month,
      first.day,
    ).subtract(Duration(days: first.weekday - 1));
    while (week.isBefore(DateTime.utc(last.year, last.month, last.day))) {
      final weekStart = week;
      final nextWeek = week.add(const Duration(days: 7));
      final weekStartInstant = tz.TZDateTime(
        zone,
        week.year,
        week.month,
        week.day,
      );
      final weekEndInstant = tz.TZDateTime(
        zone,
        nextWeek.year,
        nextWeek.month,
        nextWeek.day,
      );
      final weekly = items
          .where(
            (e) =>
                e.startUtc!.isBefore(weekEndInstant) &&
                e.endUtc!.isAfter(weekStartInstant),
          )
          .toList();
      _PrintWeek(weekStart, first, last, zone, weekly).addTo(doc, printFont);
      week = nextWeek;
    }
    return doc.save();
  }

  static String _time(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  static String _weekday(int n) =>
      const ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][n - 1];
}
