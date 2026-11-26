part of 'calendar_pdf.dart';

// A paper week is read by day, then by time. Give a five-minute errand the
// same readable line as a lecture; duration should not determine type size.
class _PrintWeek {
  _PrintWeek(this.week, this.first, this.last, this.zone, this.events);

  final DateTime week, first, last;
  final tz.Location zone;
  final List<CalendarEvent> events;
  static final _paper = PdfPageFormat.a4.landscape;
  static const _margin = 23.0, _dayWidth = 49.0, _gutter = 11.0;
  static const _topRule = 59.0, _bottom = 18.0;
  static const _ink = PdfColorGrey(.1);
  static const _quiet = PdfColorGrey(.30);
  static const _rule = PdfColorGrey(.80);
  double get _column => (_paper.width - 2 * _margin - _dayWidth) / 3;
  double get _height => _paper.height - _topRule - _bottom;

  List<_DayAgenda> _days() {
    final days = <_DayAgenda>[];
    for (var i = 0; i < 7; i++) {
      final day = DateTime.utc(week.year, week.month, week.day + i);
      final a = tz.TZDateTime(zone, day.year, day.month, day.day);
      final b = tz.TZDateTime(zone, day.year, day.month, day.day + 1);
      if (a.isBefore(first) || !a.isBefore(last)) continue;
      final entries = <_Appointment>[];
      for (final e in events) {
        if (!e.startUtc!.isBefore(b) || !e.endUtc!.isAfter(a)) continue;
        final s = tz.TZDateTime.from(e.startUtc!, zone);
        final t = tz.TZDateTime.from(e.endUtc!, zone);
        final start = s.isBefore(a) ? a : s;
        final end = t.isBefore(b) ? CalendarPdf._time(t) : '24:00';
        entries.add(
          _Appointment(
            start.hour < 12
                ? 0
                : start.hour < 18
                ? 1
                : 2,
            '${CalendarPdf._time(start)}-$end',
            e,
          ),
        );
      }
      days.add(_DayAgenda(day, entries));
    }
    return days;
  }

  void addTo(pw.Document doc, PdfFont font) {
    final days = _days();
    final clock = PdfFont.helvetica(doc.document);
    final timeWidth = clock.stringMetrics('00:00-00:00').advanceWidth * 7.6 + 6;
    final textWidth = _column - _gutter - timeWidth;
    var compact = false, periods = true;
    List<_Band> layout() => [
      for (final day in days)
        _band(day, font, textWidth, compact: compact, periods: periods),
    ];
    var bands = layout();
    double total() => bands.fold(0.0, (s, b) => s + b.height);
    if (total() > _height) {
      compact = true;
      bands = layout();
    }
    // If the week's events cluster in one time period, use all three columns
    // in chronological order before allocating another sheet.
    if (total() > _height) {
      periods = false;
      bands = layout();
    }
    final pages = <List<_Band>>[[]];
    var free = _height;
    for (final band in bands) {
      var offset = 0;
      do {
        final count = band.count - offset;
        final whole = band.slice(offset, count);
        if (whole.height <= free) {
          pages.last.add(whole);
          free -= whole.height;
          break;
        }
        // Keep an ordinary day together. Only divide a day taller than paper.
        if (pages.last.isNotEmpty) {
          pages.add([]);
          free = _height;
          continue;
        }
        final fit = ((free - _Band.padding) / band.leading).floor();
        pages.last.add(band.slice(offset, fit));
        offset += fit;
        pages.add([]);
        free = _height;
      } while (offset < band.count);
    }
    for (final page in pages) {
      final canvas = PdfPage(doc.document, pageFormat: _paper).getGraphics();
      _paint(canvas, font, clock, timeWidth, days, page, periods);
    }
  }

  _Band _band(
    _DayAgenda day,
    PdfFont font,
    double width, {
    required bool compact,
    required bool periods,
  }) {
    final size = compact ? 8.1 : 9.0;
    final notesSize = compact ? 7.1 : 7.6;
    final entries = <List<_AgendaLine>>[];
    for (final entry in day.entries) {
      final titles = _wrap(entry.event.title, font, size, width);
      final lines = [
        for (var i = 0; i < titles.length; i++)
          _AgendaLine(i == 0 ? entry : null, titles[i], size),
      ];
      final note = (entry.event.notes ?? '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (note.isNotEmpty) {
        final used = font.stringMetrics(titles.last).advanceWidth * size + 6;
        if (used + font.stringMetrics(note).advanceWidth * notesSize <= width) {
          lines.last = lines.last.withNote(note, used, notesSize);
        } else {
          lines.addAll(
            _wrap(note, font, notesSize, width).map(
              (s) => _AgendaLine(null, '', size, note: s, noteSize: notesSize),
            ),
          );
        }
      }
      entries.add(lines);
    }
    final columns = List.generate(3, (_) => <_AgendaLine>[]);
    if (periods) {
      for (var i = 0; i < entries.length; i++) {
        columns[day.entries[i].period].addAll(entries[i]);
      }
    } else {
      // Read down each column before moving right. Keep each appointment with
      // its note wherever possible and balance by printed lines, not entries.
      var remaining = entries.fold(0, (n, e) => n + e.length), col = 0;
      for (final lines in entries) {
        final filled = columns[col].length;
        if (col < 2 &&
            filled > 0 &&
            (filled + lines.length / 2) > (remaining + filled) / (3 - col)) {
          col++;
        }
        columns[col].addAll(lines);
        remaining -= lines.length;
      }
    }
    return _Band(day.date, columns, compact ? 10.6 : 13.1);
  }

  static List<String> _wrap(
    String raw,
    PdfFont font,
    double size,
    double width,
  ) {
    final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return [''];
    final result = <String>[];
    final runes = text.runes.toList();
    var start = 0;
    while (start < runes.length) {
      var end = start, wordBreak = start;
      var advance = 0.0;
      while (end < runes.length) {
        final c = runes[end];
        final next = advance + font.glyphMetrics(c).advanceWidth * size;
        if (next > width && end > start) break;
        advance = next;
        end++;
        if (c == 32 || c >= 0x2e80) wordBreak = end;
      }
      if (end < runes.length && wordBreak > start) end = wordBreak;
      result.add(String.fromCharCodes(runes, start, end).trimRight());
      start = end;
      while (start < runes.length && runes[start] == 32) {
        start++;
      }
    }
    return result;
  }

  void _paint(
    PdfGraphics g,
    PdfFont f,
    PdfFont clock,
    double timeWidth,
    List<_DayAgenda> weekDays,
    List<_Band> bands,
    bool periods,
  ) {
    double y(double fromTop) => _paper.height - fromTop;
    void text(
      String value,
      double x,
      double top,
      double size,
      PdfColor color, {
      double weight = .021,
    }) {
      if (value.isEmpty) return;
      g
        ..setColor(color)
        ..setLineWidth(size * weight)
        ..drawString(
          f,
          size,
          value,
          x,
          y(top),
          mode: PdfTextRenderingMode.fillAndStroke,
        );
    }

    void rule(double top, {bool major = false}) {
      g
        ..setStrokeColor(major ? _ink : _rule)
        ..setLineWidth(major ? .8 : .4)
        ..drawLine(_margin, y(top), _paper.width - _margin, y(top))
        ..strokePath();
    }

    final a = weekDays.first.date, b = weekDays.last.date;
    final begin = '${a.year}年${a.month}月${a.day}日';
    final end = a.year != b.year
        ? '${b.year}年${b.month}月${b.day}日'
        : a.month != b.month
        ? '${b.month}月${b.day}日'
        : '${b.day}日';
    text(a == b ? begin : '$begin至$end', _margin, 31, 15, _ink, weight: .037);
    if (periods) {
      for (var c = 0; c < 3; c++) {
        text(
          const ['上午', '下午', '晚间'][c],
          _margin + _dayWidth + c * _column,
          _topRule - 6,
          8.4,
          _ink,
          weight: .04,
        );
      }
    }
    var top = _topRule;
    rule(top, major: true);
    final occupied = bands.fold(0.0, (s, b) => s + b.height);
    final pad = math.min(
      11.0,
      math.max(0.0, (_height - occupied) / bands.length),
    );
    for (final band in bands) {
      final baseline = top + 14 + pad * .4;
      final d = band.date;
      text(
        CalendarPdf._weekday(d.weekday),
        _margin,
        baseline,
        10.0,
        _ink,
        weight: .045,
      );
      text('${d.month}/${d.day}', _margin, baseline + 11, 7.6, _quiet);
      for (var col = 0; col < 3; col++) {
        final x = _margin + _dayWidth + col * _column;
        final entries = band.columns[col];
        for (var i = 0; i < entries.length; i++) {
          final line = entries[i], base = baseline + band.leading * i;
          if (line.entry case final entry?) {
            g
              ..setColor(_quiet)
              ..setLineWidth(.025)
              ..drawString(
                clock,
                7.6,
                entry.time,
                x,
                y(base),
                mode: PdfTextRenderingMode.fillAndStroke,
              );
          }
          final titleX = x + timeWidth;
          text(line.title, titleX, base, line.size, _ink, weight: .033);
          text(
            line.note,
            titleX + line.noteOffset,
            base,
            line.noteSize,
            _quiet,
          );
        }
      }
      top += band.height + pad;
      rule(top);
    }
  }
}

class _DayAgenda {
  _DayAgenda(this.date, this.entries);
  final DateTime date;
  final List<_Appointment> entries;
}

class _Appointment {
  _Appointment(this.period, this.time, this.event);
  final int period;
  final String time;
  final CalendarEvent event;
}

class _AgendaLine {
  const _AgendaLine(
    this.entry,
    this.title,
    this.size, {
    this.note = '',
    this.noteOffset = 0,
    this.noteSize = 7.6,
  });
  final _Appointment? entry;
  final String title, note;
  final double size, noteOffset, noteSize;
  _AgendaLine withNote(String value, double offset, double fontSize) =>
      _AgendaLine(
        entry,
        title,
        size,
        note: value,
        noteOffset: offset,
        noteSize: fontSize,
      );
}

class _Band {
  const _Band(this.date, this.columns, this.leading);
  final DateTime date;
  final List<List<_AgendaLine>> columns;
  final double leading;
  static const padding = 12.0;
  int get count => columns.fold(0, (n, c) => math.max(n, c.length));
  double get height => math.max(34.0, padding + count * leading);
  _Band slice(int offset, int length) => _Band(date, [
    for (final col in columns) col.skip(offset).take(length).toList(),
  ], leading);
}
