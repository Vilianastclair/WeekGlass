import 'dart:async';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

import '../features/planner/planner_controller.dart';

class ScheduleNotice {
  const ScheduleNotice(this.title, this.body, this.eventId);
  final String title, body, eventId;
}

/// Evaluates actual stored timestamps, not the viewed week or painted blocks.
/// A bounded catch-up window prevents a burst of stale alerts after sleep.
class ReminderEngine {
  ReminderEngine({
    required DateTime startedAt,
    Iterable<String> delivered = const [],
  }) : eligibleAfter = startedAt,
       delivered = {...delivered};
  DateTime eligibleAfter;
  final Set<String> delivered;

  List<({CalendarEvent event, bool start, String key, DateTime at})> due(
    Iterable<CalendarEvent> events,
    DateTime now,
  ) {
    final cutoff = now.subtract(const Duration(seconds: 90));
    final result =
        <({CalendarEvent event, bool start, String key, DateTime at})>[];
    for (final event in events) {
      if (event.isAllDay || event.deletedAtUtc != null) continue;
      for (final start in [false, true]) {
        final at = start ? event.startUtc! : event.endUtc!;
        final key =
            '${event.id}|${start ? 'start' : 'end'}|${at.millisecondsSinceEpoch}';
        if (at.isAfter(eligibleAfter) &&
            at.isAfter(cutoff) &&
            !at.isAfter(now) &&
            !delivered.contains(key)) {
          result.add((event: event, start: start, key: key, at: at));
        }
      }
    }
    result.sort((a, b) {
      final time = a.at.compareTo(b.at);
      if (time != 0) return time;
      return (a.start ? 1 : 0).compareTo(b.start ? 1 : 0);
    });
    return result;
  }

  static ScheduleNotice notice(
    List<({CalendarEvent event, bool start, String key, DateTime at})>
    boundaries,
  ) {
    final starts = boundaries.where((b) => b.start).toList();
    final ends = boundaries.where((b) => !b.start).toList();
    final heading = starts.isEmpty
        ? '日程结束'
        : ends.isEmpty
        ? '日程开始'
        : '日程交接';
    final lines = boundaries.take(4).map((b) {
      final name = b.event.title.trim().isEmpty ? '预留时间' : b.event.title.trim();
      final at = b.at.toLocal();
      final time =
          '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
      return '${b.start ? '开始' : '结束'} $time · $name';
    }).toList();
    if (boundaries.length > 4) lines.add('另有 ${boundaries.length - 4} 项日程');
    return ScheduleNotice(
      heading,
      lines.join('\n'),
      (starts.isNotEmpty ? starts.first : ends.first).event.id,
    );
  }
}

class WindowsReminders {
  WindowsReminders(this.controller, {MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('weekglass/desktop');
  final PlannerController controller;
  final MethodChannel _channel;
  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();
  late ReminderEngine _engine;
  Timer? _timer;
  bool _busy = false;
  bool _enabled = true;

  Future<void> start() async {
    _engine = ReminderEngine(
      startedAt: DateTime.now().toUtc(),
      delivered:
          await _preferences.getStringList('notification_delivered_v1') ?? [],
    );
    _enabled = controller.notificationsEnabled;
    controller.addListener(_preferencesChanged);
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openEvent' && call.arguments is String) {
        for (final event in controller.events) {
          if (event.id == call.arguments) {
            controller.setAnchorDate(event.startLocal);
            break;
          }
        }
      }
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  void _preferencesChanged() {
    if (_enabled != controller.notificationsEnabled) {
      _enabled = controller.notificationsEnabled;
      _engine.eligibleAfter = DateTime.now().toUtc();
    }
  }

  Future<void> tick() async {
    if (_busy || !_enabled) return;
    _busy = true;
    try {
      final due = _engine.due(controller.events, DateTime.now().toUtc());
      if (due.isEmpty) return;
      final notice = ReminderEngine.notice(due);
      final accepted =
          await _channel.invokeMethod<bool>('notify', {
            'title': notice.title,
            'body': notice.body,
            'eventId': notice.eventId,
          }) ??
          false;
      if (accepted) {
        _engine.delivered.addAll(due.map((b) => b.key));
        final recent = _engine.delivered.toList();
        if (recent.length > 512) recent.removeRange(0, recent.length - 512);
        _engine.delivered
          ..clear()
          ..addAll(recent);
        await _preferences.setStringList('notification_delivered_v1', recent);
      }
    } on PlatformException {
      // Retry transient shell failures within 90 seconds.
    } on MissingPluginException {
      // Non-Windows test hosts have no shell channel.
    } catch (_) {
      // Notification/persistence failures must never interrupt the calendar.
    } finally {
      _busy = false;
    }
  }

  static Future<bool> testNotification() async =>
      await const MethodChannel('weekglass/desktop')
          .invokeMethod<bool>('notify', {
            'title': 'WeekGlass · 通知已连接',
            'body': '日程开始或结束时会在这里提醒你。收起到托盘后仍然有效。',
            'eventId': '',
          }) ??
      false;

  void dispose() {
    _timer?.cancel();
    controller.removeListener(_preferencesChanged);
    _channel.setMethodCallHandler(null);
  }
}
