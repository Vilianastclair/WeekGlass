import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:timezone/timezone.dart' as tz;
import 'package:weekglass_domain/weekglass_domain.dart';

import 'calendar_codec.dart';

/// A print layout, with repeated column headings and continuation rows. No
/// screenshots are embedded: Chinese text remains selectable and searchable.
class CalendarPdf {
  static Future<Uint8List> build({
    required Iterable<CalendarEvent> events,
    required DateTime rangeStart,
    required DateTime rangeEnd,
    required String timeZoneId,
    required ByteData chineseFont,
    bool monochrome = false,
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
    final ink = monochrome ? PdfColors.black : PdfColor.fromHex('#24324A');
    final accent = monochrome ? PdfColors.black : PdfColor.fromHex('#536CAB');
    final line = monochrome ? PdfColors.grey600 : PdfColor.fromHex('#DCE3EF');
    final doc = pw.Document(
      title: 'WeekGlass 周日程',
      author: 'WeekGlass',
      theme: pw.ThemeData.withFont(
        base: font,
        bold: font,
        italic: font,
        boldItalic: font,
      ),
    );
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
      final rows = <pw.TableRow>[
        pw.TableRow(
          repeat: true,
          decoration: pw.BoxDecoration(
            color: monochrome ? PdfColors.grey200 : PdfColor.fromHex('#ECF0F8'),
          ),
          children: [
            for (final text in ['日期', '时间', '日程', '备注'])
              _cell(text, ink, size: 9, padding: 9),
          ],
        ),
      ];
      for (final event in weekly) {
        final start = tz.TZDateTime.from(event.startUtc!, zone);
        final end = tz.TZDateTime.from(event.endUtc!, zone);
        final titles = _chunks(event.title, 70);
        final notes = _chunks(event.notes ?? '', 220);
        final count = titles.length > notes.length
            ? titles.length
            : notes.length;
        for (var index = 0; index < count; index++) {
          final bg = monochrome ? PdfColors.white : _fill(event.color);
          rows.add(
            pw.TableRow(
              decoration: pw.BoxDecoration(color: bg),
              children: [
                _cell(
                  index == 0
                      ? '${start.month}/${start.day}\n${_weekday(start.weekday)}'
                      : '续',
                  ink,
                  size: 9,
                ),
                _cell(
                  index == 0
                      ? '${_time(start)} - ${_time(end)}${_sameDay(start, end) ? '' : '\n至 ${end.month}/${end.day}'}'
                      : '',
                  ink,
                  size: 9,
                ),
                _cell(
                  index < titles.length ? titles[index] : '',
                  ink,
                  size: 10,
                ),
                _cell(index < notes.length ? notes[index] : '', ink, size: 9),
              ],
            ),
          );
        }
      }
      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4.landscape,
          margin: const pw.EdgeInsets.fromLTRB(30, 26, 30, 25),
          maxPages: 500,
          header: (context) => pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 16),
            child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    _text(
                      'WEEKGLASS',
                      style: pw.TextStyle(
                        fontSize: 9,
                        color: accent,
                        letterSpacing: 2,
                      ),
                    ),
                    pw.SizedBox(height: 5),
                    _text(
                      '${_date(weekStart)} — ${_date(nextWeek.subtract(const Duration(days: 1)))}',
                      style: pw.TextStyle(fontSize: 19, color: ink),
                    ),
                  ],
                ),
                _text(
                  '${weekly.length} 项日程 · ${monochrome ? '黑白打印' : '彩色打印'}',
                  style: pw.TextStyle(fontSize: 9, color: ink),
                ),
              ],
            ),
          ),
          footer: (context) => pw.Container(
            margin: const pw.EdgeInsets.only(top: 10),
            padding: const pw.EdgeInsets.only(top: 8),
            decoration: pw.BoxDecoration(
              border: pw.Border(top: pw.BorderSide(color: line, width: .4)),
            ),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                _text(
                  '时区：$timeZoneId  ·  ${_date(rangeStart)} 至 ${_date(DateTime.utc(rangeEnd.year, rangeEnd.month, rangeEnd.day - 1))}',
                  style: pw.TextStyle(fontSize: 8, color: ink),
                ),
                _text(
                  '第 ${context.pageNumber} / ${context.pagesCount} 页',
                  style: pw.TextStyle(fontSize: 8, color: ink),
                ),
              ],
            ),
          ),
          build: (context) => weekly.isEmpty
              ? [
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(32),
                    child: _text(
                      '这一周没有日程。',
                      style: pw.TextStyle(fontSize: 12, color: ink),
                    ),
                  ),
                ]
              : [
                  pw.Table(
                    border: pw.TableBorder(
                      horizontalInside: pw.BorderSide(color: line, width: .4),
                    ),
                    columnWidths: const {
                      0: pw.FixedColumnWidth(55),
                      1: pw.FixedColumnWidth(95),
                      2: pw.FlexColumnWidth(1.1),
                      3: pw.FlexColumnWidth(2.2),
                    },
                    children: rows,
                  ),
                ],
        ),
      );
      week = nextWeek;
    }
    return doc.save();
  }

  // The bundled variable font's default outlines are very light. A restrained
  // matching stroke keeps small print legible without shipping a second CJK
  // font or rasterizing text; the original Unicode mapping stays intact.
  static pw.Widget _text(String text, {required pw.TextStyle style}) =>
      pw.CustomPaint(
        painter: (canvas, size) => canvas
          ..setStrokeColor(style.color ?? PdfColors.black)
          ..setLineWidth((style.fontSize ?? 10) * .014),
        child: pw.Text(
          text,
          style: style.copyWith(
            renderingMode: PdfTextRenderingMode.fillAndStroke,
          ),
        ),
      );

  static pw.Widget _cell(
    String text,
    PdfColor ink, {
    double size = 9,
    double padding = 8,
  }) => pw.Padding(
    padding: pw.EdgeInsets.all(padding),
    child: _text(
      text,
      style: pw.TextStyle(fontSize: size, color: ink, lineSpacing: 3),
    ),
  );

  // Bound both character count and explicit newlines. A single extremely long
  // note must not create a table row taller than a printable page.
  static List<String> _chunks(String text, int limit) {
    if (text.isEmpty) return [''];
    final chunks = <String>[];
    var part = StringBuffer(), lines = 0, count = 0;
    for (final rune in text.replaceAll('\r\n', '\n').runes) {
      if (count >= limit || lines >= 8) {
        chunks.add(part.toString());
        part = StringBuffer();
        count = 0;
        lines = 0;
      }
      part.writeCharCode(rune);
      count++;
      if (rune == 10) lines++;
    }
    if (part.isNotEmpty) chunks.add(part.toString());
    return chunks;
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
  static String _time(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  static String _date(DateTime d) =>
      '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';
  static String _weekday(int n) =>
      const ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][n - 1];
  static PdfColor _fill(EventColor c) => PdfColor.fromHex(switch (c) {
    EventColor.mistBlue => '#EDF3FC',
    EventColor.lavender => '#F2EDFA',
    EventColor.sageGreen => '#EBF5F0',
    EventColor.softPeach => '#FFF1E7',
    EventColor.rose => '#FCEFF3',
    EventColor.warmSand => '#FAF3E3',
    EventColor.slate => '#F0F2F5',
  });
}
