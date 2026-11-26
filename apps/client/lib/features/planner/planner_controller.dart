import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:weekglass_data/weekglass_data.dart';
import 'package:weekglass_domain/weekglass_domain.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

import '../course_import/teaching_term.dart';
import '../course_import/school_adapter.dart';
import '../course_import/whu_timetable.dart';
import '../mobile/mobile_time_zoom.dart';
import 'batch_edit_field.dart';
import 'sidebar_action.dart';
import '../cloud/cloud_connection.dart';
export 'batch_edit_field.dart';

enum PlannerView { day, threeDays, week }

class _UndoEntry {
  const _UndoEntry({required this.eventId, required this.before});

  final String eventId;
  final CalendarEvent? before;
}

/// Identifies one deletion so its toast never undoes a different action.
class DeletionReceipt {
  DeletionReceipt._(this._entries);
  final List<_UndoEntry> _entries;
  int get count => _entries.length;
}

class PlannerController extends ChangeNotifier {
  PlannerController({
    required this.repository,
    required this.timeZoneId,
    this.cloud,
  });

  final EventRepository repository;
  final String timeZoneId;
  final CloudConnection? cloud;

  Future<void> waitForPendingWrites() async {
    while (_writing || _savingSleep) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }

  Future<void> reloadAfterSync() async {
    await waitForPendingWrites();
    final events = List<CalendarEvent>.of(await repository.getAllEvents());
    if (_writing) return reloadAfterSync();
    _events = events..sort(_compareEvents);
    _undoStack.clear();
    notifyListeners();
  }

  Future<void> reloadSleepSchedule() async {
    if (repository case final SqliteEventRepository repo) {
      await waitForPendingWrites();
      final revision = _sleepRevision;
      final stored = await repo.readSleepSchedule();
      if (_savingSleep || revision != _sleepRevision) {
        return reloadSleepSchedule();
      }
      if (stored == null ||
          (stored.enabled == _sleep.enabled &&
              stored.sleepMinute == _sleep.sleepMinute &&
              stored.wakeMinute == _sleep.wakeMinute)) {
        return;
      }
      _sleep = stored;
      notifyListeners();
    }
  }

  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();
  static const _mobileTimeZoomKey = 'mobile_time_zoom';
  double _mobileTimeZoom = MobileTimeZoom.normal;
  Future<void> _mobileTimeZoomWrite = Future<void>.value();
  double get mobileTimeZoom => _mobileTimeZoom;

  Future<void> saveMobileTimeZoom(double value) async {
    final zoom = MobileTimeZoom.normalize(value);
    if (zoom == _mobileTimeZoom) return;
    _mobileTimeZoom = zoom;
    final write = _mobileTimeZoomWrite.then(
      (_) => _preferences.setDouble(_mobileTimeZoomKey, zoom),
    );
    // Preserve the order of successive gestures even on slow storage;
    // the current caller still receives the error from its own write.
    _mobileTimeZoomWrite = write.catchError((Object _) {});
    notifyListeners();
    await write;
  }

  final List<List<_UndoEntry>> _undoStack = [];
  bool _writing = false;
  bool _whuConnected = false;
  bool _showTeachingWeek = true;
  bool _notificationsEnabled = true;
  bool get notificationsEnabled => _notificationsEnabled;
  Future<void> setNotificationsEnabled(bool enabled) async {
    await _preferences.setBool('event_notifications_enabled', enabled);
    _notificationsEnabled = enabled;
    notifyListeners();
  }

  final Map<String, TeachingTerm> _teachingTerms = {};
  bool get whuConnected => _whuConnected;
  bool get showTeachingWeek => _showTeachingWeek;
  TeachingTerm? get visibleTeachingTerm {
    if (!_whuConnected || !_showTeachingWeek) return null;
    final matching =
        _teachingTerms.values
            .where((term) => term.weekAt(_anchorDate) != null)
            .toList()
          ..sort((a, b) => b.firstMonday.compareTo(a.firstMonday));
    return matching.isEmpty ? null : matching.first;
  }

  String? get teachingWeekLabel {
    final term = visibleTeachingTerm;
    return term == null
        ? null
        : '第 ${term.number} 学期 · 第 ${term.weekAt(_anchorDate)} 周';
  }

  Future<void> setTeachingWeekVisible(bool value) async {
    await _preferences.setBool('show_teaching_week', value);
    _showTeachingWeek = value;
    notifyListeners();
  }

  Future<void> setWhuConnected(bool value) async {
    if (_whuConnected == value) return;
    await _preferences.setBool('whu_connected', value);
    _whuConnected = value;
    notifyListeners();
  }

  Future<void> rememberTeachingTerm(TeachingTerm term) async {
    if (!term.valid) throw ArgumentError('教学周设置无效，请核对学期与第一周日期。');
    final next = {..._teachingTerms, term.key: term};
    await _preferences.setString(
      'whu_teaching_terms',
      jsonEncode(next.values.map((e) => e.toJson()).toList()),
    );
    _teachingTerms.addAll(next);
    await setWhuConnected(true);
    notifyListeners();
  }

  Future<void> _loadTeachingTerms() async {
    final imported = _events.where(
      (e) => e.importSource?.startsWith('whu:') ?? false,
    );
    _whuConnected =
        await _preferences.getBool('whu_connected') ?? imported.isNotEmpty;
    _showTeachingWeek =
        await _preferences.getBool('show_teaching_week') ?? true;
    try {
      final saved = await _preferences.getString('whu_teaching_terms');
      if (saved != null) {
        for (final row in jsonDecode(saved) as List) {
          final term = TeachingTerm.fromJson(
            Map<String, dynamic>.from(row as Map),
          );
          if (term.valid) _teachingTerms[term.key] = term;
        }
      }
    } catch (_) {
      /* Ignore malformed display preferences. */
    }
    // Recover calendars already confirmed and imported in 0.11, without login.
    final keys = imported
        .map((e) => e.importSource!.split(':'))
        .where((parts) => parts.length > 2)
        .map((parts) => parts[2])
        .toSet();
    for (final key in keys) {
      if (_teachingTerms.containsKey(key)) continue;
      try {
        final parts = key.split('-').map(int.parse).toList();
        final saved = await _preferences.getString('whu_schedule_$key');
        if (saved == null || parts.length != 2) continue;
        final monday = DateTime.parse(
          (jsonDecode(saved) as Map)['firstMonday'] as String,
        );
        final whuTerm = WhuTerm(parts[0], parts[1]);
        final dates = imported
            .where((e) => e.importSource!.split(':')[2] == key)
            .map((e) => int.tryParse(e.importSource!.split(':')[6]) ?? 1);
        final lastWeek = dates.fold<int>(1, (a, b) => a > b ? a : b);
        final term = TeachingTerm(
          year: parts[0],
          semester: parts[1],
          firstMonday: monday,
          weeks: whuTerm.calendarWeeks ?? lastWeek,
        );
        if (term.valid) _teachingTerms[key] = term;
      } catch (_) {
        /* Only confirmed, valid calendars are recovered. */
      }
    }
  }

  List<CalendarEvent> _events = <CalendarEvent>[];
  DateTime _anchorDate = DateTime.now();
  PlannerView _view = PlannerView.week;
  ThemeMode _themeMode = ThemeMode.dark;
  WeekGlassSkin _skin = WeekGlassSkin.moonstone;
  double _glassStrength = LiquidGlass.defaultStrength;
  bool _glassMotion = true;
  Set<SidebarAction> _sidebarActions = {
    ...(defaultTargetPlatform == TargetPlatform.iOS
        ? SidebarAction.iPhoneDefaults
        : SidebarAction.defaults),
  };
  Set<SidebarAction> get sidebarActions => Set.unmodifiable(_sidebarActions);
  Future<void> saveSidebarActions(Set<SidebarAction> actions) async {
    await _preferences.setStringList(
      'sidebar_actions_v1',
      actions.map((a) => a.name).toList(),
    );
    _sidebarActions = {...actions};
    notifyListeners();
  }

  bool _isLoading = true;
  SleepSchedule _sleep = const SleepSchedule(enabled: false);
  bool _savingSleep = false;
  int _sleepRevision = 0;
  SleepSchedule get sleep => _sleep;

  List<CalendarEvent> get events => List.unmodifiable(_events);
  DateTime get anchorDate => _anchorDate;
  PlannerView get view => _view;
  ThemeMode get themeMode => _themeMode;
  WeekGlassSkin get skin => _skin;
  double get glassStrength => _glassStrength;
  bool get glassMotion => _glassMotion;
  bool get isLoading => _isLoading;
  bool get canUndo => _undoStack.isNotEmpty && !_writing;
  String get undoLabel => _undoStack.isEmpty
      ? '暂无可撤销操作'
      : '撤销上次操作 · ${_undoStack.last.length} 条日程 · Ctrl+Z';

  Future<void> initialize() async {
    final shortcuts = await _preferences.getStringList('sidebar_actions_v1');
    if (shortcuts != null) {
      _sidebarActions = SidebarAction.values
          .where((a) => shortcuts.contains(a.name))
          .toSet();
    }
    _notificationsEnabled =
        await _preferences.getBool('event_notifications_enabled') ?? true;
    final savedTheme = await _preferences.getString('theme_mode');
    _themeMode = switch (savedTheme) {
      'dark' => ThemeMode.dark,
      'system' => ThemeMode.system,
      'light' => ThemeMode.light,
      _ => ThemeMode.dark,
    };
    try {
      final appearance = await _preferences.getString('appearance_v1');
      if (appearance != null) {
        final value = jsonDecode(appearance) as Map<String, dynamic>;
        _skin = WeekGlassSkin.fromId(value['skin'] as String?);
        _themeMode = switch (value['mode']) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          'system' => ThemeMode.system,
          _ => _themeMode,
        };
        final strength = value['glassStrength'];
        if (strength is num) {
          _glassStrength = LiquidGlass.normalizeStrength(strength.toDouble());
        }
        if (value['glassMotion'] is bool) {
          _glassMotion = value['glassMotion'] as bool;
        }
      }
    } catch (_) {
      // A malformed local appearance preference never blocks the calendar.
      _skin = WeekGlassSkin.moonstone;
    }
    try {
      _mobileTimeZoom = MobileTimeZoom.normalize(
        await _preferences.getDouble(_mobileTimeZoomKey),
      );
    } catch (_) {
      _mobileTimeZoom = MobileTimeZoom.normal;
    }
    final savedView = await _preferences.getString('planner_view');
    _view = switch (savedView) {
      'day' => PlannerView.day,
      'threeDays' => PlannerView.threeDays,
      'week' => PlannerView.week,
      _ => Platform.isAndroid ? PlannerView.threeDays : PlannerView.week,
    };

    if (Platform.isWindows) _view = PlannerView.week;
    _events = List<CalendarEvent>.of(await repository.getAllEvents());
    final compacted = _events.map(compactLegacyWhuNotes).toList();
    final noteUpdates = [
      for (var i = 0; i < _events.length; i++)
        if (!identical(compacted[i], _events[i])) compacted[i],
    ];
    if (noteUpdates.isNotEmpty) {
      await repository.saveBatch(noteUpdates);
      _events = compacted;
    }
    await _loadTeachingTerms();
    await _loadSleepSchedule();
    if (_events.isEmpty && const bool.fromEnvironment('WG_DEMO_DATA')) {
      await _seedDemoWeek();
    }
    _isLoading = false;
    notifyListeners();
  }

  DateTime get weekStart => mondayOf(_anchorDate);

  List<DateTime> get visibleDays {
    if (_view == PlannerView.week) return daysOfWeek(_anchorDate);
    final count = _view == PlannerView.day ? 1 : 3;
    final start = dateOnly(_anchorDate);
    return List<DateTime>.generate(
      count,
      (index) => start.add(Duration(days: index)),
      growable: false,
    );
  }

  List<CalendarEvent> eventsForDay(DateTime date, {bool allDay = false}) {
    final key = dateOnly(date);
    return _events
        .where((event) {
          if (event.isAllDay != allDay) return false;
          if (event.isAllDay) {
            return !event.allDayStartDate!.isAfter(key) &&
                event.allDayEndDateExclusive!.isAfter(key);
          }
          return event.startLocal.isBefore(
                DateTime(key.year, key.month, key.day + 1),
              ) &&
              event.endLocal.isAfter(key);
        })
        .toList(growable: false);
  }

  void setAnchorDate(DateTime date) {
    _anchorDate = dateOnly(date);
    notifyListeners();
  }

  void goToday() => setAnchorDate(DateTime.now());

  void navigatePeriod(int direction) {
    final days = switch (_view) {
      PlannerView.day => 1,
      PlannerView.threeDays => 3,
      PlannerView.week => 7,
    };
    setAnchorDate(_anchorDate.add(Duration(days: days * direction)));
  }

  void setView(PlannerView value) {
    if (_view == value) return;
    _view = value;
    _preferences.setString('planner_view', value.name);
    notifyListeners();
  }

  void toggleTheme() {
    final next = _themeMode == ThemeMode.dark
        ? ThemeMode.light
        : ThemeMode.dark;
    setThemeMode(next);
  }

  void setThemeMode(ThemeMode value) {
    previewAppearance(skin: _skin, themeMode: value);
    _preferences.setString('appearance_v1', _appearanceJson(_skin, value));
  }

  /// Preview is in-memory; cancelling restores the complete prior appearance.
  void previewAppearance({
    required WeekGlassSkin skin,
    required ThemeMode themeMode,
    double? glassStrength,
    bool? glassMotion,
  }) {
    final strength = LiquidGlass.normalizeStrength(
      glassStrength ?? _glassStrength,
    );
    final motion = glassMotion ?? _glassMotion;
    if (_skin == skin &&
        _themeMode == themeMode &&
        _glassStrength == strength &&
        _glassMotion == motion) {
      return;
    }
    _skin = skin;
    _themeMode = themeMode;
    _glassStrength = strength;
    _glassMotion = motion;
    notifyListeners();
  }

  Future<void> saveAppearance({
    required WeekGlassSkin skin,
    required ThemeMode themeMode,
    double? glassStrength,
    bool? glassMotion,
  }) async {
    // A single local preference atomically commits skin, brightness and light.
    await _preferences.setString(
      'appearance_v1',
      _appearanceJson(skin, themeMode, glassStrength, glassMotion),
    );
    previewAppearance(
      skin: skin,
      themeMode: themeMode,
      glassStrength: glassStrength,
      glassMotion: glassMotion,
    );
  }

  String _appearanceJson(
    WeekGlassSkin skin,
    ThemeMode mode, [
    double? strength,
    bool? motion,
  ]) => jsonEncode({
    'skin': skin.id,
    'mode': mode.name,
    'glassStrength': LiquidGlass.normalizeStrength(strength ?? _glassStrength),
    'glassMotion': motion ?? _glassMotion,
  });

  Future<void> setSleepSchedule(SleepSchedule value) async {
    if (!value.valid) throw ArgumentError('入睡与起床时间须不同，清醒时段至少保留 15 分钟。');
    if (_savingSleep) throw StateError('正在保存睡眠时段，请稍后再试。');
    _savingSleep = true;
    try {
      if (repository case final SqliteEventRepository repo) {
        await repo.saveSleepSchedule(value);
      } else {
        await _preferences.setString(
          'sleep_schedule',
          jsonEncode({
            'enabled': value.enabled,
            'sleep': value.sleepMinute,
            'wake': value.wakeMinute,
          }),
        );
      }
      _sleep = value;
      _sleepRevision++;
    } finally {
      _savingSleep = false;
    }
    notifyListeners();
  }

  Future<void> _loadSleepSchedule() async {
    if (repository case final SqliteEventRepository repo) {
      final stored = await repo.readSleepSchedule();
      if (stored != null) {
        _sleep = stored;
        return;
      }
      final legacy = await _readLegacySleepSchedule();
      if (legacy != null) {
        await repo.migrateSleepSchedule(legacy);
        _sleep = (await repo.readSleepSchedule())!;
        return;
      }
    } else if (await _readLegacySleepSchedule() case final legacy?) {
      _sleep = legacy;
      return;
    }
    _sleep = const SleepSchedule();
  }

  Future<SleepSchedule?> _readLegacySleepSchedule() async {
    try {
      final saved = await _preferences.getString('sleep_schedule');
      if (saved == null) return null;
      final value = jsonDecode(saved);
      if (value is! Map<String, dynamic> ||
          value['enabled'] is! bool ||
          value['sleep'] is! int ||
          value['wake'] is! int) {
        return null;
      }
      final schedule = SleepSchedule(
        enabled: value['enabled'] as bool,
        sleepMinute: value['sleep'] as int,
        wakeMinute: value['wake'] as int,
      );
      return schedule.valid ? schedule : null;
    } on FormatException {
      return null;
    }
  }

  List<CalendarEvent> timedEventsInWindow(DateTime date) {
    final start = DateTime(
      date.year,
      date.month,
      date.day,
      0,
      _sleep.visibleStart,
    );
    final end = DateTime(date.year, date.month, date.day, 0, _sleep.visibleEnd);
    return _events
        .where(
          (event) =>
              !event.isAllDay &&
              event.startLocal.isBefore(end) &&
              event.endLocal.isAfter(start),
        )
        .toList();
  }

  List<CalendarEvent> batchEvents(CalendarEvent event) => event.seriesId == null
      ? [event]
      : _events.where((item) => item.seriesId == event.seriesId).toList();

  List<CalendarEvent> batchFrom(CalendarEvent event) =>
      batchEvents(event)
          .where((item) => !item.startLocal.isBefore(event.startLocal))
          .toList();

  Future<void> saveEvent(CalendarEvent event) => saveEvents([event]);

  Future<void> saveEvents(List<CalendarEvent> events) => _saveEvents(events);

  /// A calendar file already specifies its times. Store them as provided;
  /// the sleep schedule still controls the default visible hours.
  Future<void> importCalendarEvents(List<CalendarEvent> events) =>
      _saveEvents(events, keepImportedTimes: true);

  List<String> batchChangeLabels(CalendarEvent edited) =>
      batchChangedFields(edited).map((e) => e.label).toList();

  Set<BatchEditField> batchChangedFields(CalendarEvent edited) {
    final previous = _findEvent(edited.id);
    if (previous == null ||
        previous.seriesId == null ||
        previous.isAllDay ||
        edited.isAllDay) {
      return {};
    }
    return {
      if (previous.title != edited.title) BatchEditField.title,
      if (previous.color != edited.color) BatchEditField.color,
      if (_clock(previous.startLocal) != _clock(edited.startLocal))
        BatchEditField.start,
      if (_clock(previous.endLocal) != _clock(edited.endLocal) ||
          _daySpan(previous) != _daySpan(edited))
        BatchEditField.end,
      if (previous.notes != edited.notes) BatchEditField.notes,
    };
  }

  static Duration _clock(DateTime value) => Duration(
    hours: value.hour,
    minutes: value.minute,
    seconds: value.second,
    milliseconds: value.millisecond,
    microseconds: value.microsecond,
  );

  static int _daySpan(CalendarEvent event) =>
      DateTime.utc(
            event.endLocal.year,
            event.endLocal.month,
            event.endLocal.day,
          )
          .difference(
            DateTime.utc(
              event.startLocal.year,
              event.startLocal.month,
              event.startLocal.day,
            ),
          )
          .inDays;

  static DateTime _onDate(DateTime date, DateTime clock, {int days = 0}) =>
      DateTime(
        date.year,
        date.month,
        date.day + days,
        clock.hour,
        clock.minute,
        clock.second,
        clock.millisecond,
        clock.microsecond,
      );

  Future<int> saveBatchChanges(
    CalendarEvent edited, {
    Set<BatchEditField>? fields,
  }) async {
    final previous = _findEvent(edited.id);
    if (previous == null) throw StateError('这条日程已不存在，请重新打开。');
    if (previous.seriesId == null || edited.seriesId != previous.seriesId) {
      throw ArgumentError('请选择一条同批日程。');
    }
    if (previous.isAllDay || edited.isAllDay) {
      throw ArgumentError('仅支持有明确时间的日程。');
    }
    final changes = batchChangedFields(edited);
    final selected = fields == null ? changes : changes.intersection(fields);
    final titleChanged = selected.contains(BatchEditField.title);
    final colorChanged = selected.contains(BatchEditField.color);
    final startChanged = selected.contains(BatchEditField.start);
    final endChanged = selected.contains(BatchEditField.end);
    final notesChanged = selected.contains(BatchEditField.notes);
    final updates = <CalendarEvent>[edited];
    for (final item in batchEvents(previous)) {
      if (item.id == edited.id || item.isAllDay) continue;
      final start = startChanged
          ? _onDate(item.startLocal, edited.startLocal)
          : item.startLocal;
      final end = endChanged
          ? _onDate(item.startLocal, edited.endLocal, days: _daySpan(edited))
          : item.endLocal;
      if (!end.isAfter(start)) {
        throw ArgumentError('同批日程中存在结束早于开始的时间；本次未保存，请调整开始或结束时间。');
      }
      if ((titleChanged && item.title != edited.title) ||
          (colorChanged && item.color != edited.color) ||
          (notesChanged && item.notes != edited.notes) ||
          start != item.startLocal ||
          end != item.endLocal) {
        updates.add(
          CalendarEvent.timed(
            id: item.id,
            title: titleChanged ? edited.title : item.title,
            color: colorChanged ? edited.color : item.color,
            notes: notesChanged ? edited.notes : item.notes,
            startLocal: start,
            endLocal: end,
            timeZoneId: item.timeZoneId,
            seriesId: item.seriesId,
            importSource: item.importSource,
            importFingerprint: item.importFingerprint,
            recurrenceRule: item.recurrenceRule,
            createdAtUtc: item.createdAtUtc,
            updatedAtUtc: DateTime.now().toUtc(),
            version: item.version + 1,
          ),
        );
      }
    }
    await _saveEvents(updates, replacingIds: updates.map((e) => e.id).toSet());
    return updates.length;
  }

  Future<int> convertToRepeat(CalendarEvent edited, RepeatPlan plan) async {
    final previous = _findEvent(edited.id);
    if (previous == null) throw StateError('这条日程已不存在，请重新打开。');
    if (previous.seriesId != null || previous.recurrenceRule != null) {
      throw ArgumentError('这条日程已属于重复安排，请直接调整本条。');
    }
    if (edited.isAllDay || plan.frequency == RepeatFrequency.none) {
      throw ArgumentError('请选择每周或每月安排。');
    }
    final series = const Uuid().v4();
    final expanded = expandRepeatedEvent(
      edited,
      plan,
      newId: () => const Uuid().v4(),
      seriesId: series,
    );
    final anchor = CalendarEvent.timed(
      id: previous.id,
      title: edited.title,
      notes: edited.notes,
      color: edited.color,
      startLocal: edited.startLocal,
      endLocal: edited.endLocal,
      timeZoneId: edited.timeZoneId,
      recurrenceRule: plan.rule,
      seriesId: series,
      createdAtUtc: previous.createdAtUtc,
      updatedAtUtc: DateTime.now().toUtc(),
      version: previous.version + 1,
    );
    final events = [
      anchor,
      for (final event in expanded)
        if (dateOnly(event.startLocal) != dateOnly(anchor.startLocal)) event,
    ];
    if (events.length > 2000) throw ArgumentError('单次最多生成 2000 条日程，请缩短日期范围。');
    await _saveEvents(events, replacingIds: {previous.id});
    return events.length;
  }

  Future<void> applyCourseImport(List<CalendarEvent> changes) async {
    if (changes.any(
      (event) => !SchoolAdapter.acceptsImportSource(event.importSource),
    )) {
      throw ArgumentError('课表来源无效，请重新读取。');
    }
    await _saveEvents(changes, replacingIds: changes.map((e) => e.id).toSet());
  }

  Future<void> _saveEvents(
    List<CalendarEvent> events, {
    Set<String> replacingIds = const {},
    bool keepImportedTimes = false,
  }) async {
    if (_writing) throw StateError('正在保存，请稍后再试。');
    if (events.isEmpty) return;
    if (!keepImportedTimes &&
        events.any((event) {
          if (event.deletedAtUtc != null || _sleep.allows(event)) return false;
          final previous = _findEvent(event.id);
          // A visibility change can leave an existing timed event partially or
          // fully hidden. Editing other fields must not require moving it.
          return previous == null ||
              previous.startUtc != event.startUtc ||
              previous.endUtc != event.endUtc;
        })) {
      throw ArgumentError('日程与睡眠时段重叠，请调整时间或在设置中修改睡眠时段。');
    }
    if (events.map((e) => e.id).toSet().length != events.length ||
        (events.length > 1 &&
            events.any(
              (e) => !replacingIds.contains(e.id) && _findEvent(e.id) != null,
            ))) {
      throw ArgumentError('批量新增不能重复或覆盖已有日程。');
    }
    _writing = true;
    final before = [
      for (final event in events)
        _UndoEntry(eventId: event.id, before: _findEvent(event.id)),
    ];
    try {
      await repository.saveBatch(events);
      final merged = {for (final event in _events) event.id: event};
      for (final event in events) {
        if (event.deletedAtUtc != null) {
          merged.remove(event.id);
        } else {
          merged[event.id] = event;
        }
      }
      _events = merged.values.toList()..sort(_compareEvents);
      _undoStack.add(before);
    } finally {
      _writing = false;
      notifyListeners();
    }
  }

  Future<DeletionReceipt?> deleteEvent(
    String id, {
    bool futureInBatch = false,
  }) async {
    if (_writing) throw StateError('正在保存，请稍后再试。');
    final previous = _findEvent(id);
    if (previous == null) return null;
    final victims = futureInBatch ? batchFrom(previous) : [previous];
    final ids = victims.map((event) => event.id).toSet();
    _writing = true;
    try {
      await repository.deleteBatch(ids.toList());
      _events.removeWhere((item) => ids.contains(item.id));
      final entries = [
        for (final event in victims)
          _UndoEntry(eventId: event.id, before: event),
      ];
      _undoStack.add(entries);
      return DeletionReceipt._(entries);
    } finally {
      _writing = false;
      notifyListeners();
    }
  }

  Future<bool> undoDeletion(DeletionReceipt receipt) async {
    if (_writing) throw StateError('正在保存，请稍后再试。');
    final index = _undoStack.indexWhere(
      (entry) => identical(entry, receipt._entries),
    );
    if (index < 0) return false;
    final restores = receipt._entries
        .where((entry) => _findEvent(entry.eventId) == null)
        .map((entry) => entry.before!)
        .toList();
    _writing = true;
    try {
      if (restores.isNotEmpty) await repository.saveBatch(restores);
      for (final event in restores) {
        _replaceInMemory(event);
      }
      _undoStack.removeAt(index);
      return true;
    } finally {
      _writing = false;
      notifyListeners();
    }
  }

  Future<void> undo() async {
    if (!canUndo) return;
    final entries = _undoStack.last;
    _writing = true;
    try {
      // Conversion mixes one original update with new occurrences. Restore the
      // original and tombstone its new occurrences atomically through saveBatch.
      final creates = entries
          .where((e) => e.before == null)
          .map((e) => e.eventId)
          .toList();
      final restores = entries
          .where((e) => e.before != null)
          .map((e) => e.before!)
          .toList();
      if (creates.isNotEmpty && restores.isNotEmpty) {
        final now = DateTime.now().toUtc();
        await repository.saveBatch([
          ...restores,
          for (final id in creates)
            if (_findEvent(id) case final event?) event.markedDeleted(now),
        ]);
      } else {
        if (creates.isNotEmpty) await repository.deleteBatch(creates);
        if (restores.isNotEmpty) await repository.saveBatch(restores);
      }
      _events.removeWhere((e) => creates.contains(e.id));
      for (final event in restores) {
        _replaceInMemory(event);
      }
      _undoStack.removeLast();
    } finally {
      _writing = false;
      notifyListeners();
    }
  }

  CalendarEvent? _findEvent(String id) {
    for (final event in _events) {
      if (event.id == id) return event;
    }
    return null;
  }

  void _replaceInMemory(CalendarEvent event) {
    final index = _events.indexWhere((item) => item.id == event.id);
    if (index < 0) {
      _events.add(event);
    } else {
      _events[index] = event;
    }
    _events.sort(_compareEvents);
  }

  int _compareEvents(CalendarEvent a, CalendarEvent b) {
    if (a.isAllDay != b.isAllDay) return a.isAllDay ? -1 : 1;
    return a.startLocal.compareTo(b.startLocal);
  }

  Future<void> _seedDemoWeek() async {
    final demo = <CalendarEvent>[
      _demo('晨间专注', 0, 8, 30, 10, 0, EventColor.mistBlue),
      _demo('阅读时光', 0, 11, 0, 12, 0, EventColor.lavender),
      _demo('项目工作', 0, 14, 0, 16, 0, EventColor.sageGreen),
      _demo('深度工作', 1, 8, 0, 9, 30, EventColor.lavender),
      _demo('计划整理', 1, 10, 0, 11, 0, EventColor.mistBlue),
      _demo('创作时间', 1, 13, 30, 15, 0, EventColor.sageGreen),
      _demo('静心回顾', 1, 14, 0, 15, 30, EventColor.softPeach),
      _demo('阅读', 2, 9, 0, 10, 30, EventColor.sageGreen),
      _demo('工作室时间', 2, 14, 0, 16, 0, EventColor.softPeach),
      _demo('研究探索', 3, 9, 30, 11, 0, EventColor.mistBlue),
      _demo('进度沟通', 3, 13, 0, 14, 0, EventColor.lavender),
      _demo('深度工作', 4, 8, 30, 10, 30, EventColor.mistBlue),
      _demo('复盘与改进', 4, 13, 0, 14, 0, EventColor.sageGreen),
      _demo('悠闲早晨', 5, 10, 0, 12, 0, EventColor.softPeach),
      _demo('每周整理', 6, 16, 0, 17, 0, EventColor.lavender),
    ];
    for (final event in demo) {
      await repository.save(event);
    }
    _events = List<CalendarEvent>.of(await repository.getAllEvents());
  }

  CalendarEvent _demo(
    String title,
    int day,
    int startHour,
    int startMinute,
    int endHour,
    int endMinute,
    EventColor color,
  ) {
    final date = mondayOf(DateTime.now()).add(Duration(days: day));
    return CalendarEvent.timed(
      id: const Uuid().v4(),
      title: title,
      startLocal: DateTime(
        date.year,
        date.month,
        date.day,
        startHour,
        startMinute,
      ),
      endLocal: DateTime(date.year, date.month, date.day, endHour, endMinute),
      timeZoneId: timeZoneId,
      color: color,
    );
  }

  @override
  void dispose() {
    cloud?.dispose();
    repository.close();
    super.dispose();
  }
}
