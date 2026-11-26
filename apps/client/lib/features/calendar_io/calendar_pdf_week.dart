part of 'calendar_pdf.dart';

class _ColorWeek {
  _ColorWeek(
    this.week,
    this.first,
    this.last,
    this.zone,
    this.zoneName,
    this.events,
  );

  final DateTime week, first, last;
  final tz.Location zone;
  final String zoneName;
  final List<CalendarEvent> events;

  static final _ink = PdfColor.fromHex('#172640');
  static final _muted = PdfColor.fromHex('#4C5C74');
  static final _line = PdfColor.fromHex('#D9E1EC');
  static final _light = PdfColor.fromHex('#F3F6FA');
  static final _accent = PdfColor.fromHex('#39528B');
  static final _paper = PdfPageFormat.a4.landscape;
  static const _margin = pw.EdgeInsets.fromLTRB(30, 24, 30, 24);

  DateTime _day(int index) => week.add(Duration(days: index));

  tz.TZDateTime _midnight(int index) {
    final day = _day(index);
    return tz.TZDateTime(zone, day.year, day.month, day.day);
  }

  bool _selected(int index) =>
      !_midnight(index).isBefore(first) && _midnight(index).isBefore(last);

  void addTo(pw.Document doc) {
    final columns = [for (var d = 0; d < 7; d++) _segments(d)];
    final segments = columns.expand((column) => column).toList();
    var from = 8 * 60, to = 22 * 60;
    if (segments.isNotEmpty) {
      from = segments.map((s) => s.start).reduce(math.min) ~/ 60 * 60;
      to = math.min(
        1440,
        (segments.map((s) => s.end).reduce(math.max) / 60).ceil() * 60,
      );
      if (to - from < 8 * 60) {
        to = math.min(1440, from + 8 * 60);
        from = math.min(from, to - 8 * 60);
      }
    }
    doc.addPage(
      pw.Page(
        pageFormat: _paper,
        margin: _margin,
        build: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            _header('周日程', '${events.length} 项日程'),
            pw.SizedBox(height: 14),
            _grid(columns, from, to),
            pw.SizedBox(height: 9),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                _text(zoneName, 8, color: _muted),
                _text(
                  events.isEmpty ? '这一周没有日程' : '完整时间和备注见日程明细',
                  8,
                  color: _muted,
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (events.isNotEmpty) _addDetails(doc);
  }

  pw.Widget _header(String title, String meta) => pw.Row(
    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
    crossAxisAlignment: pw.CrossAxisAlignment.end,
    children: [
      pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          _text('WEEKGLASS  $title', 10, color: _accent),
          pw.SizedBox(height: 3),
          _text(
            '${CalendarPdf._date(week)} 至 ${CalendarPdf._date(_day(6))}',
            22,
          ),
        ],
      ),
      _text(meta, 10, color: _muted),
    ],
  );

  List<_PrintSegment> _segments(int day) {
    if (!_selected(day)) return [];
    final from = _midnight(day), to = _midnight(day + 1);
    final segments = <_PrintSegment>[];
    for (final event in events) {
      final start = event.startUtc!, end = event.endUtc!;
      if (!start.isBefore(to) || !end.isAfter(from)) continue;
      final a = start.isAfter(from) ? start : from;
      final b = end.isBefore(to) ? end : to;
      final localA = tz.TZDateTime.from(a, zone);
      final localB = tz.TZDateTime.from(b, zone);
      final low = localA.hour * 60 + localA.minute;
      final high = b.isAtSameMomentAs(to)
          ? 1440
          : localB.hour * 60 + localB.minute;
      segments.add(
        _PrintSegment(low, math.min(1440, math.max(low + 1, high)), event),
      );
    }
    segments.sort((a, b) => a.start.compareTo(b.start));
    return segments;
  }

  pw.Widget _grid(List<List<_PrintSegment>> columns, int from, int to) {
    const axis = 34.0, header = 35.0, height = 410.0;
    final width = _paper.width - _margin.left - _margin.right;
    final slot = (width - axis) / 7;
    double y(int minute) => header + (minute - from) * height / (to - from);
    return pw.SizedBox(
      width: width,
      height: header + height,
      child: pw.Stack(
        children: [
          for (var d = 0; d < 7; d++) ...[
            _rect(
              axis + d * slot,
              0,
              slot,
              header + height,
              !_selected(d) || d >= 5 ? _light : PdfColors.white,
            ),
            _rect(axis + d * slot, 0, slot, header, _light),
          ],
          for (var minute = from; minute <= to; minute += 60) ...[
            _rect(
              axis,
              y(minute),
              width - axis,
              minute % 120 == 0 ? .55 : .3,
              _line,
            ),
            if (minute < to &&
                (minute == from || minute % (to - from > 780 ? 120 : 60) == 0))
              pw.Positioned(
                left: 0,
                top: y(minute) + 2,
                child: pw.SizedBox(
                  width: axis - 6,
                  child: _text(_clock(minute), 8, color: _muted),
                ),
              ),
          ],
          for (var d = 0; d <= 7; d++)
            _rect(axis + d * slot, 0, .5, header + height, _line),
          for (var d = 0; d < 7; d++) ...[
            pw.Positioned(
              left: axis + d * slot + 8,
              top: 6,
              child: _text(CalendarPdf._weekday(d + 1), 8, color: _muted),
            ),
            pw.Positioned(
              left: axis + d * slot + 8,
              top: 16,
              child: _text('${_day(d).month}/${_day(d).day}', 13),
            ),
            for (final placement in _lanes(columns[d]))
              _block(placement, axis + d * slot, slot, y),
          ],
        ],
      ),
    );
  }

  // Events which actually overlap share the column. A second appointment must
  // never paint over a shorter one, and adjacent events keep their full width.
  Iterable<({_PrintSegment event, int lane, int count})> _lanes(
    List<_PrintSegment> column,
  ) sync* {
    var at = 0;
    while (at < column.length) {
      var next = at, end = column[at].end;
      final ends = <int>[];
      final lanes = <int>[];
      do {
        final event = column[next++];
        final lane = ends.indexWhere((time) => time <= event.start);
        if (lane == -1) {
          lanes.add(ends.length);
          ends.add(event.end);
        } else {
          lanes.add(lane);
          ends[lane] = event.end;
        }
        end = math.max(end, event.end);
      } while (next < column.length && column[next].start < end);
      for (var i = at; i < next; i++) {
        yield (event: column[i], lane: lanes[i - at], count: ends.length);
      }
      at = next;
    }
  }

  pw.Widget _block(
    ({_PrintSegment event, int lane, int count}) placement,
    double left,
    double slot,
    double Function(int) y,
  ) {
    final segment = placement.event;
    final laneWidth = (slot - 4) / placement.count;
    final width = math.max(.2, laneWidth - math.min(2, laneWidth * .2));
    final top = y(segment.start);
    final height = math.max(.6, y(segment.end) - top - .55);
    final labelWidth = width - 9;
    final showTitle = labelWidth >= 18 && height >= 9.2;
    final showTime = labelWidth >= 47 && height >= 25;
    final titleSize = height < 12 ? 8.1 : 8.7;
    final radius = pw.BorderRadius.circular(math.min(3, height / 3));
    return pw.Positioned(
      left: left + 2 + placement.lane * laneWidth,
      top: top,
      child: pw.Container(
        width: width,
        height: height,
        decoration: pw.BoxDecoration(
          color: CalendarPdf._fill(segment.event.color),
          borderRadius: radius,
        ),
        child: pw.Stack(
          children: [
            _rect(
              0,
              0,
              math.min(2.6, width),
              height,
              _rail(segment.event.color),
            ),
            if (showTitle)
              pw.Positioned(
                left: 6,
                right: 3,
                top: showTime
                    ? 3
                    : height < 12
                    ? 0
                    : 1,
                child: pw.Column(
                  mainAxisSize: pw.MainAxisSize.min,
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    _text(
                      _fit(segment.event.title, labelWidth, titleSize),
                      titleSize,
                      maxLines: 1,
                    ),
                    if (showTime) ...[
                      pw.SizedBox(height: 1),
                      _text(
                        '${_clock(segment.start)}-${_clock(segment.end)}',
                        7.1,
                        color: _muted,
                        maxLines: 1,
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _addDetails(pw.Document doc) {
    final rows = <pw.TableRow>[
      pw.TableRow(
        repeat: true,
        decoration: pw.BoxDecoration(color: _light),
        children: [
          for (final heading in ['日期', '时间', '日程', '备注'])
            _cell(heading, 8.8, color: _muted),
        ],
      ),
    ];
    DateTime? previous;
    final weekStart = _midnight(0);
    for (final event in events) {
      final start = tz.TZDateTime.from(event.startUtc!, zone);
      final end = tz.TZDateTime.from(event.endUtc!, zone);
      final shownDay = start.isBefore(weekStart)
          ? weekStart
          : start.isBefore(first)
          ? first
          : start;
      final freshDate =
          previous == null || !CalendarPdf._sameDay(previous, shownDay);
      final titles = CalendarPdf._chunks(event.title, 120);
      final notes = CalendarPdf._chunks(event.notes ?? '', 250);
      for (var i = 0; i < math.max(titles.length, notes.length); i++) {
        rows.add(
          pw.TableRow(
            children: [
              _cell(
                i != 0
                    ? ''
                    : '${freshDate ? '${CalendarPdf._weekday(shownDay.weekday)}\n' : ''}${shownDay.month}/${shownDay.day}',
                9,
                color: _muted,
              ),
              _cell(
                i == 0
                    ? '${start.isBefore(shownDay) ? '${start.month}/${start.day} ' : ''}${CalendarPdf._time(start)} 至 ${CalendarPdf._time(end)}${CalendarPdf._sameDay(start, end) ? '' : '\n结束于 ${end.month}/${end.day}'}'
                    : '续',
                8.7,
                color: _muted,
              ),
              if (i == 0)
                pw.Padding(
                  padding: const pw.EdgeInsets.fromLTRB(6, 3, 5, 3),
                  child: pw.Row(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Container(
                        width: 4,
                        height: 8,
                        margin: const pw.EdgeInsets.only(top: 2, right: 6),
                        color: _rail(event.color),
                      ),
                      pw.Expanded(child: _text(titles.first, 10.2)),
                    ],
                  ),
                )
              else
                _cell(i < titles.length ? titles[i] : '', 10.2),
              _cell(i < notes.length ? notes[i] : '', 9.5),
            ],
          ),
        );
      }
      previous = shownDay;
    }
    doc.addPage(
      pw.MultiPage(
        pageFormat: _paper,
        margin: _margin,
        maxPages: 500,
        header: (_) => pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 12),
          child: _header('日程明细', zoneName),
        ),
        footer: (context) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: _text('第 ${context.pageNumber} 页', 8, color: _muted),
        ),
        build: (_) => [
          pw.Table(
            border: pw.TableBorder(
              horizontalInside: pw.BorderSide(color: _line, width: .35),
            ),
            columnWidths: const {
              0: pw.FixedColumnWidth(48),
              1: pw.FixedColumnWidth(106),
              2: pw.FlexColumnWidth(1.1),
              3: pw.FlexColumnWidth(1.75),
            },
            children: rows,
          ),
        ],
      ),
    );
  }

  static pw.Widget _rect(
    double x,
    double y,
    double w,
    double h,
    PdfColor color,
  ) => pw.Positioned(
    left: x,
    top: y,
    child: pw.Container(width: w, height: h, color: color),
  );

  static pw.Widget _text(
    String text,
    double size, {
    PdfColor? color,
    int? maxLines,
  }) => CalendarPdf._text(
    text,
    style: pw.TextStyle(fontSize: size, color: color ?? _ink, lineSpacing: 1.8),
    maxLines: maxLines,
  );

  static pw.Widget _cell(String text, double size, {PdfColor? color}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.fromLTRB(6, 3, 5, 3),
        child: _text(text, size, color: color),
      );

  static String _fit(String title, double width, double size) {
    final line = title.split(RegExp(r'\s+')).join(' ').trim();
    var available = width / size;
    double advance(int code) => code < 128 ? .63 : 1;
    if (line.runes.fold(0.0, (total, code) => total + advance(code)) <=
        available) {
      return line;
    }
    available -= .9;
    final result = StringBuffer();
    for (final code in line.runes) {
      available -= advance(code);
      if (available < 0) return '${result.toString().trimRight()}…';
      result.writeCharCode(code);
    }
    return line;
  }

  static String _clock(int minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

  static PdfColor _rail(EventColor c) => PdfColor.fromHex(switch (c) {
    EventColor.mistBlue => '#4F79C4',
    EventColor.lavender => '#8063B4',
    EventColor.sageGreen => '#42856F',
    EventColor.softPeach => '#BC6F46',
    EventColor.rose => '#B35471',
    EventColor.warmSand => '#A67A32',
    EventColor.slate => '#68778D',
  });
}

class _PrintSegment {
  const _PrintSegment(this.start, this.end, this.event);
  final int start, end;
  final CalendarEvent event;
}
