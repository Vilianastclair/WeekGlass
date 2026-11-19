import 'dart:convert';

import 'whu_timetable.dart';

/// 深圳大学本科「我的课表」。The separate kcbcx app is a school-wide catalog.
abstract final class SzuPortalTimetable {
  static const name = '深圳大学';
  static const origin = 'https://ehall.szu.edu.cn';
  static const _root = '/jwapp/sys';
  static const _path = '$_root/wdkb/*default/index.do';
  static const entry = '$origin$_path';
  static const asset = 'assets/school_portal/read_szu.js';

  static bool onCampusSystem(Uri? uri) =>
      uri?.host == 'ehall.szu.edu.cn' &&
      (uri!.path == '$_root/wdkb' ||
          uri.path.startsWith('$_root/wdkb/') ||
          uri.path == '$_root/kcbcx' ||
          uri.path.startsWith('$_root/kcbcx/'));

  static bool matchesPersonalPage(Uri? uri) =>
      onCampusSystem(uri) &&
      uri!.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      !uri.authority.contains('@') &&
      uri.origin == origin &&
      uri.path == _path;

  static String script(String js, WhuTerm term) {
    final semester = switch (term.semester) {
      3 => 1,
      12 => 2,
      _ => throw const FormatException('深圳大学本科课表目前支持秋季和春季学期。'),
    };
    return '(${js.trim()})(${jsonEncode(origin)},${jsonEncode(_path)},'
        '${jsonEncode('${term.year}-${term.year + 1}-$semester')})';
  }

  // The official grid numbers teaching weeks from Sunday; use the Monday of
  // the same teaching week to match the calendar preview's reference date.
  static DateTime? _firstMonday(WhuTerm term) => switch (term.key) {
    '2025-12' => DateTime(2026, 3, 9),
    '2026-3' => DateTime(2026, 8, 31),
    _ => null,
  };

  // The school publishes 11–12 and 13–14 as whole evening blocks, not four
  // individual periods. Do not split those blocks into invented start times.
  static const _dayClock = [
    ClassPeriod(510, 550),
    ClassPeriod(555, 595),
    ClassPeriod(615, 655),
    ClassPeriod(660, 700),
    ClassPeriod(705, 745),
    ClassPeriod(810, 850),
    ClassPeriod(855, 895),
    ClassPeriod(900, 940),
    ClassPeriod(960, 1000),
    ClassPeriod(1005, 1045),
  ];

  static const _eveningClock = {
    '11-12': ClassPeriod(1140, 1220),
    '13-14': ClassPeriod(1230, 1305),
  };

  // Ehall combines each meeting in YPSJDD as weeks, weekday, periods, room.
  // Its comma-separated week list stays inside the same meeting.
  static final _separators = RegExp(r'(?<![周)）])[,，]|[;；\r\n]+');
  static final _slot = RegExp(
    r'^([\d第周单双(),，、（）\s\-–—－~～至]+)\s+(?:星期|周)([一二三四五六日天])\s+'
    r'(?:第\s*)?(\d{1,2}(?:\s*[-–—－~～至]\s*\d{1,2})?)\s*节(?:\s+(.*))?$',
  );
  static final _bareParity = RegExp(r'周([单双])周?(?=\s*[,，、]|$)');

  static WhuTimetable parse(Map data, WhuTerm term) {
    final rows = data['rows'];
    if (rows is! List || rows.length > 500) {
      throw const FormatException('深圳大学没有返回可识别的本科课表。');
    }
    final monday = _firstMonday(term);
    final meetings = <WhuCourseMeeting>[];
    final warnings = <String>[];
    final seen = <String>{};
    var needsEveningClock = false;
    for (final row in rows) {
      if (row is! Map || _text(row['title']).isEmpty) {
        warnings.add('有一条课程缺少课程名，未安排。');
        continue;
      }
      final title = _text(row['title']);
      final teacher = _text(row['teacher']);
      final code = _text(row['code']), section = _text(row['section']);
      final key = whuHash(
        jsonEncode(code.isEmpty ? [title, teacher] : [code, section]),
      ).substring(0, 24);
      final arrangement = _text(row['arrangement']);
      for (final part in arrangement.split(_separators)) {
        try {
          final fields = _slot.firstMatch(part.trim());
          if (fields == null) throw const FormatException('上课安排没有明确的周、星期和节次');
          final day = '一二三四五六日天'.indexOf(fields[2]!) + 1;
          final weekday = day == 8 ? DateTime.sunday : day;
          final weekText = fields[1]!.trim();
          final schoolWeeks = parseTeachingWeeks(
            weekText
                .replaceAll(RegExp(r'[–~]'), '-')
                .replaceAllMapped(_bareParity, (m) => '周(${m[1]})'),
          );
          final weeks = weekday == DateTime.sunday
              ? schoolWeeks.map((week) => week - 1).toList()
              : schoolWeeks;
          final periods = parsePeriods(
            fields[3]!.replaceAll(RegExp(r'[–—－~～至]'), '-'),
          );
          if (periods.last > 14)
            throw const FormatException('节次超出学校的 1 至 14 节');
          final room = fields[4] ?? '';
          final fixed = monday == null
              ? null
              : _eveningClock['${periods.first}-${periods.last}'];
          if (fixed == null && periods.last > _dayClock.length) {
            needsEveningClock = true;
          }
          if (!seen.add(
            jsonEncode([key, weekday, weeks, periods, teacher, room]),
          ))
            continue;
          meetings.add(
            WhuCourseMeeting(
              courseKey: key,
              title: title,
              weekday: weekday,
              periods: periods,
              weeks: weeks,
              weekText: weekText,
              room: room,
              teacher: teacher,
              fixedTime: fixed,
            ),
          );
        } on FormatException catch (e) {
          final warning = '$title：${e.message}，未安排。';
          if (!warnings.contains(warning)) warnings.add(warning);
        }
      }
    }
    if (meetings.isEmpty) {
      throw FormatException(
        warnings.isEmpty ? '深圳大学没有返回所选学期的课程。' : '没有可安排的课程。${warnings.first}',
      );
    }
    if (monday != null && needsEveningClock) {
      warnings.add('有课程需要晚间单节时间，请按学校原课表核对并补齐节次时间。');
    }
    return WhuTimetable(
      meetings: meetings,
      warnings: warnings,
      account: '',
      suggestedFirstMonday: monday,
      suggestedClock: monday == null ? null : _dayClock,
    );
  }

  static String _text(Object? value) =>
      value is String ? schoolText(value) : '';
}
