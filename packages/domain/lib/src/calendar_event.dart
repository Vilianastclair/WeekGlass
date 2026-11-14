enum EventColor {
  mistBlue,
  lavender,
  sageGreen,
  softPeach,
  rose,
  warmSand,
  slate,
}

extension EventColorPresentation on EventColor {
  String get key => switch (this) {
    EventColor.mistBlue => 'mist_blue',
    EventColor.lavender => 'lavender',
    EventColor.sageGreen => 'sage_green',
    EventColor.softPeach => 'soft_peach',
    EventColor.rose => 'rose',
    EventColor.warmSand => 'warm_sand',
    EventColor.slate => 'slate',
  };

  String get label => switch (this) {
    EventColor.mistBlue => '雾蓝',
    EventColor.lavender => '鸢尾紫',
    EventColor.sageGreen => '冰青',
    EventColor.softPeach => '暮杏',
    EventColor.rose => '蔷薇',
    EventColor.warmSand => '琥珀',
    EventColor.slate => '月灰',
  };

  static EventColor fromKey(String? value) => switch (value) {
    'lavender' => EventColor.lavender,
    'sage_green' => EventColor.sageGreen,
    'soft_peach' => EventColor.softPeach,
    'rose' => EventColor.rose,
    'warm_sand' => EventColor.warmSand,
    'slate' => EventColor.slate,
    _ => EventColor.mistBlue,
  };
}

class CalendarEvent {
  const CalendarEvent._({
    required this.id,
    required this.title,
    required this.color,
    required this.timeZoneId,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    required this.version,
    this.notes,
    this.startUtc,
    this.endUtc,
    this.allDayStartDate,
    this.allDayEndDateExclusive,
    this.recurrenceRule,
    this.seriesId,
    this.deletedAtUtc,
    this.importSource,
    this.importFingerprint,
  });

  factory CalendarEvent.timed({
    required String id,
    required String title,
    required DateTime startLocal,
    required DateTime endLocal,
    required String timeZoneId,
    EventColor color = EventColor.mistBlue,
    String? notes,
    String? importSource,
    String? importFingerprint,
    String? recurrenceRule,
    String? seriesId,
    DateTime? createdAtUtc,
    DateTime? updatedAtUtc,
    int version = 1,
  }) {
    if (!endLocal.isAfter(startLocal)) {
      throw ArgumentError.value(
        endLocal,
        'endLocal',
        'Must be after startLocal.',
      );
    }
    final now = DateTime.now().toUtc();
    return CalendarEvent._(
      id: id,
      title: title,
      notes: notes,
      color: color,
      timeZoneId: timeZoneId,
      startUtc: startLocal.toUtc(),
      endUtc: endLocal.toUtc(),
      createdAtUtc: createdAtUtc ?? now,
      updatedAtUtc: updatedAtUtc ?? now,
      version: version,
      importSource: importSource,
      importFingerprint: importFingerprint,
      recurrenceRule: recurrenceRule,
      seriesId: seriesId,
    );
  }

  factory CalendarEvent.allDay({
    required String id,
    required String title,
    required DateTime startDate,
    required DateTime endDateExclusive,
    required String timeZoneId,
    String? importSource,
    String? importFingerprint,
    String? recurrenceRule,
    String? seriesId,
    EventColor color = EventColor.warmSand,
    String? notes,
    DateTime? createdAtUtc,
    DateTime? updatedAtUtc,
    int version = 1,
  }) {
    final start = DateTime(startDate.year, startDate.month, startDate.day);
    final end = DateTime(
      endDateExclusive.year,
      endDateExclusive.month,
      endDateExclusive.day,
    );
    if (!end.isAfter(start)) {
      throw ArgumentError.value(endDateExclusive, 'endDateExclusive');
    }
    final now = DateTime.now().toUtc();
    return CalendarEvent._(
      id: id,
      title: title,
      notes: notes,
      color: color,
      timeZoneId: timeZoneId,
      allDayStartDate: start,
      allDayEndDateExclusive: end,
      importSource: importSource,
      importFingerprint: importFingerprint,
      recurrenceRule: recurrenceRule,
      seriesId: seriesId,
      createdAtUtc: createdAtUtc ?? now,
      updatedAtUtc: updatedAtUtc ?? now,
      version: version,
    );
  }

  factory CalendarEvent.fromStorage({
    required String id,
    required String title,
    required String colorKey,
    required String timeZoneId,
    required DateTime createdAtUtc,
    required DateTime updatedAtUtc,
    required int version,
    String? notes,
    DateTime? startUtc,
    DateTime? endUtc,
    DateTime? allDayStartDate,
    DateTime? allDayEndDateExclusive,
    String? importSource,
    String? importFingerprint,
    String? recurrenceRule,
    String? seriesId,
    DateTime? deletedAtUtc,
  }) {
    return CalendarEvent._(
      id: id,
      title: title,
      notes: notes,
      color: EventColorPresentation.fromKey(colorKey),
      timeZoneId: timeZoneId,
      startUtc: startUtc?.toUtc(),
      endUtc: endUtc?.toUtc(),
      allDayStartDate: allDayStartDate == null
          ? null
          : DateTime(
              allDayStartDate.year,
              allDayStartDate.month,
              allDayStartDate.day,
            ),
      allDayEndDateExclusive: allDayEndDateExclusive == null
          ? null
          : DateTime(
              allDayEndDateExclusive.year,
              allDayEndDateExclusive.month,
              allDayEndDateExclusive.day,
            ),
      createdAtUtc: createdAtUtc.toUtc(),
      updatedAtUtc: updatedAtUtc.toUtc(),
      version: version,
      importSource: importSource,
      importFingerprint: importFingerprint,
      recurrenceRule: recurrenceRule,
      seriesId: seriesId,
      deletedAtUtc: deletedAtUtc?.toUtc(),
    );
  }

  final String id;
  final String title;
  final String? notes;
  final EventColor color;
  final String timeZoneId;
  final DateTime? startUtc;
  final DateTime? endUtc;
  final DateTime? allDayStartDate;
  final DateTime? allDayEndDateExclusive;
  final String? importSource;
  final String? importFingerprint;
  final String? recurrenceRule;
  final String? seriesId;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;
  final int version;
  final DateTime? deletedAtUtc;

  bool get isAllDay => allDayStartDate != null;

  DateTime get startLocal => isAllDay ? allDayStartDate! : startUtc!.toLocal();

  DateTime get endLocal =>
      isAllDay ? allDayEndDateExclusive! : endUtc!.toLocal();

  Duration get duration => endLocal.difference(startLocal);

  /// Retain the complete record while applying the same soft-delete semantics
  /// as the repository, allowing mixed undo operations in one transaction.
  CalendarEvent markedDeleted(DateTime timestamp) => CalendarEvent._(
    id: id,
    title: title,
    notes: notes,
    color: color,
    timeZoneId: timeZoneId,
    startUtc: startUtc,
    endUtc: endUtc,
    allDayStartDate: allDayStartDate,
    allDayEndDateExclusive: allDayEndDateExclusive,
    importSource: importSource,
    importFingerprint: importFingerprint,
    recurrenceRule: recurrenceRule,
    seriesId: seriesId,
    createdAtUtc: createdAtUtc,
    updatedAtUtc: timestamp.toUtc(),
    version: version + 1,
    deletedAtUtc: timestamp.toUtc(),
  );

  CalendarEvent withTimedRange(DateTime startLocal, DateTime endLocal) {
    return CalendarEvent.timed(
      id: id,
      title: title,
      notes: notes,
      color: color,
      startLocal: startLocal,
      endLocal: endLocal,
      timeZoneId: timeZoneId,
      importSource: importSource,
      importFingerprint: importFingerprint,
      recurrenceRule: recurrenceRule,
      seriesId: seriesId,
      createdAtUtc: createdAtUtc,
      updatedAtUtc: DateTime.now().toUtc(),
      version: version + 1,
    );
  }

  CalendarEvent withDetails({
    required String title,
    required String? notes,
    required EventColor color,
  }) {
    final now = DateTime.now().toUtc();
    if (isAllDay) {
      return CalendarEvent.allDay(
        id: id,
        title: title,
        notes: notes,
        color: color,
        startDate: allDayStartDate!,
        endDateExclusive: allDayEndDateExclusive!,
        timeZoneId: timeZoneId,
        createdAtUtc: createdAtUtc,
        updatedAtUtc: now,
        version: version + 1,
      );
    }
    return CalendarEvent.timed(
      id: id,
      title: title,
      notes: notes,
      color: color,
      startLocal: startLocal,
      endLocal: endLocal,
      timeZoneId: timeZoneId,
      importSource: importSource,
      importFingerprint: importFingerprint,
      recurrenceRule: recurrenceRule,
      seriesId: seriesId,
      createdAtUtc: createdAtUtc,
      updatedAtUtc: now,
      version: version + 1,
    );
  }
}
