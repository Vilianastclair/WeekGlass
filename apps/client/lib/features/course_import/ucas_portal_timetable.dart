import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:html/parser.dart' as html;

import 'whu_timetable.dart';

/// Personal grid membership comes from SEP; public teaching details need no
/// WebView cookies. Only course IDs, never account or login data, cross origins.
abstract final class UcasPortalTimetable {
  static const name = '中国科学院大学';
  static const entry = 'https://sep.ucas.ac.cn/';
  static const origin = 'https://xkgo.ucas.ac.cn:3000';
  static const page = '$origin/course/personSchedule';
  static const asset = 'assets/school_portal/read_ucas.js';
  static bool onCampusSystem(Uri? uri) =>
      uri != null &&
      (uri.host == 'sep.ucas.ac.cn' || uri.host == 'xkgo.ucas.ac.cn');
  static bool matchesPersonalPage(Uri? uri) => uri?.toString() == page;
  static (String, String) _titles(WhuTerm term) {
    final (season, seq) = switch (term.semester) {
      3 => ('秋', '一'),
      12 => ('春', '二'),
      16 => ('夏', '三'),
      _ => throw const FormatException('请选择国科大的秋季、春季或夏季学期。'),
    };
    return (
      '${term.semester == 3 ? term.year : term.year + 1}年$season季学期的个人课表',
      '${term.year}—${term.year + 1}学年($season)第$seq学期',
    );
  }

  static String script(String js, WhuTerm term) =>
      '(${js.trim()})(${jsonEncode(_titles(term).$1)})';
  static const clock = [
    ClassPeriod(510, 555),
    ClassPeriod(560, 605),
    ClassPeriod(625, 670),
    ClassPeriod(675, 720),
    ClassPeriod(810, 855),
    ClassPeriod(860, 905),
    ClassPeriod(925, 970),
    ClassPeriod(975, 1020),
    ClassPeriod(1025, 1070),
    ClassPeriod(1110, 1155),
    ClassPeriod(1160, 1205),
    ClassPeriod(1215, 1260),
    ClassPeriod(1265, 1310),
  ];
  static Future<WhuTimetable> parse(Map data, WhuTerm term) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..maxConnectionsPerHost = 3;
    try {
      return await readPublicDetails(data, term, (uri) async {
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        final response = await request.close().timeout(
          const Duration(seconds: 7),
        );
        if (response.statusCode != 200 ||
            response.headers.contentType?.mimeType != 'text/html') {
          throw const FormatException('学校未返回公开教学页面。');
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.timeout(
          const Duration(seconds: 5),
        )) {
          if (bytes.length + chunk.length > 512 * 1024) {
            throw const FormatException('学校返回的课程页面过大。');
          }
          bytes.add(chunk);
        }
        return utf8.decode(bytes.takeBytes());
      }).timeout(
        const Duration(seconds: 45),
        onTimeout: () => throw const FormatException('国科大公开课时查询超时，请核对网络后重试。'),
      );
    } finally {
      client.close(force: true);
    }
  }

  static Future<WhuTimetable> readPublicDetails(
    Map data,
    WhuTerm term,
    Future<String> Function(Uri) load,
  ) async {
    final (gridTerm, detailTerm) = _titles(term);
    final courses = data['courses'];
    if (data['termTitle'] != gridTerm ||
        courses is! List ||
        courses.isEmpty ||
        courses.length > 48) {
      throw const FormatException('国科大个人课表学期或课程数量不符，请重新打开本人课表。');
    }
    final entries = <({String id, String title, Set<int> slots})>[],
        ids = <String>{};
    for (final c in courses) {
      if (c is! Map ||
          c['id'] is! String ||
          !RegExp(r'^[1-9]\d{0,8}$').hasMatch(c['id']) ||
          !ids.add(c['id']) ||
          c['title'] is! String ||
          (c['title'] as String).trim().isEmpty ||
          (c['title'] as String).length > 250 ||
          c['slots'] is! List ||
          (c['slots'] as List).isEmpty ||
          (c['slots'] as List).length > 7 * 13) {
        throw const FormatException('个人课表有无法辨认的教学班，请重新读取。');
      }
      final slots = <int>{};
      for (final s in c['slots']) {
        if (s is! List ||
            s.length != 2 ||
            s[0] is! int ||
            s[0] < 1 ||
            s[0] > 7 ||
            s[1] is! int ||
            s[1] < 1 ||
            s[1] > 13) {
          throw const FormatException('个人课表节次不完整。');
        }
        slots.add((s[0] as int) * 100 + (s[1] as int));
      }
      entries.add((
        id: c['id'] as String,
        title: (c['title'] as String).trim(),
        slots: slots,
      ));
    }
    final out = <WhuCourseMeeting>[], warnings = <String>{};
    Future<List<WhuCourseMeeting>> fetch(
      ({String id, String title, Set<int> slots}) c,
    ) async {
      Uri publicPage(String type) =>
          Uri.https('jwba.ucas.ac.cn', '/sc/course/$type/${c.id}');
      late final String details;
      try {
        details = await load(publicPage('coursetime'));
      } on Exception {
        throw FormatException('${c.title}：校方公开课时暂不可用，请核对网络并重新读取。');
      }
      final doc = html.parse(details);
      final bodies = doc
          .querySelectorAll('.mc-body')
          .where(
            (b) => b.children.any(
              (p) =>
                  p.localName == 'p' &&
                  RegExp(
                    r'^(?:课程名称|Course Name)\s*[:：]\s*',
                    caseSensitive: false,
                  ).hasMatch(p.text.trim()) &&
                  p.text.trim().replaceFirst(
                        RegExp(
                          r'^(?:课程名称|Course Name)\s*[:：]\s*',
                          caseSensitive: false,
                        ),
                        '',
                      ) ==
                      c.title,
            ),
          );
      if (bodies.length != 1) {
        throw FormatException('${c.title}：公开详情中的课程名与本人课表不一致，请核对教学班。');
      }
      final terms = bodies.single.children.where(
        (p) =>
            p.localName == 'p' &&
            p.text
                    .trim()
                    .replaceAll(RegExp(r'\s|[:：]'), '')
                    .replaceAll('（', '(')
                    .replaceAll('）', ')') ==
                detailTerm,
      );
      final table = terms.length == 1 ? terms.single.nextElementSibling : null;
      if (table?.localName != 'table') {
        throw FormatException('${c.title}：公开详情未列出所选学期，请核对学期后重试。');
      }
      final rows = table!.querySelectorAll('tr');
      if (rows.isEmpty || rows.length % 3 != 0 || rows.length > 600) {
        throw FormatException('${c.title}：公开详情缺少完整课时，请核对教学班后重试。');
      }
      final schedules =
          <
            ({
              int day,
              List<int> periods,
              List<int> weeks,
              String weekText,
              String room,
            })
          >[];
      final all = <int>{};
      for (var i = 0; i < rows.length; i += 3) {
        String field(int offset, String label) {
          final cells = rows[i + offset].children;
          if (cells.length != 2 || cells[0].text.trim() != label) {
            throw FormatException('${c.title}：公开课时缺少「$label」。');
          }
          return cells[1].text.trim();
        }

        final pattern = field(0, '上课时间'),
            room = field(1, '上课地点'),
            weekText = field(2, '上课周次');
        final m = RegExp(
          r'^星期([一二三四五六日天])\s*[:：]\s*第?\s*([\d\s、,，\-—－]+)节[。.]?$',
        ).firstMatch(pattern);
        if (m == null) {
          throw FormatException('${c.title}：无法辨认「$pattern」，请核对校方课时。');
        }
        final d = '一二三四五六日天'.indexOf(m[1]!) + 1, day = d == 8 ? 7 : d;
        final periods = parsePeriods(m[2]!),
            weeks = parseTeachingWeeks(weekText);
        all.addAll(periods.map((p) => 100 * day + p));
        schedules.add((
          day: day,
          periods: periods,
          weeks: weeks,
          weekText: weekText,
          room: room,
        ));
      }
      if (all.length != c.slots.length || !all.containsAll(c.slots)) {
        throw FormatException('${c.title}：本人网格与公开课时的星期或节次不一致，请在选课系统核对后再读取。');
      }
      String teacher = '';
      try {
        final plan = html.parse(await load(publicPage('courseplan')));
        if (plan
            .querySelectorAll('h4 strong')
            .any((e) => e.text.trim() == c.title)) {
          for (final s in plan.querySelectorAll('span')) {
            final m = RegExp(
              r'^(?:主讲教师|Main Teachers)\s*[:：]\s*(.{1,250})$',
              caseSensitive: false,
            ).firstMatch(s.text.trim());
            if (m != null) {
              teacher = m[1]!.trim();
              break;
            }
          }
        }
      } on Exception {
        warnings.add('${c.title}：公开大纲暂不可用，教师留空。');
      }
      return [
        for (final s in schedules)
          WhuCourseMeeting(
            courseKey: whuHash('ucas-${c.id}').substring(0, 24),
            title: c.title,
            weekday: s.day,
            periods: s.periods,
            weeks: s.weeks,
            weekText: s.weekText,
            room: s.room,
            teacher: teacher,
          ),
      ];
    }

    for (var i = 0; i < entries.length; i += 3) {
      final group = await Future.wait(
        entries.skip(i).take(3).map((course) async {
          try {
            return await fetch(course);
          } on FormatException catch (error) {
            final message = error.message.toString();
            warnings.add(
              '${message.startsWith(course.title) ? message : '${course.title}：$message'} 此课程未导入。',
            );
            return <WhuCourseMeeting>[];
          }
        }),
      );
      out.addAll(group.expand((v) => v));
    }
    if (out.isEmpty) throw FormatException(warnings.first);
    return WhuTimetable(
      meetings: out,
      warnings: warnings.toList(),
      account: '',
      suggestedClock: clock,
      suggestedFirstMonday: switch (term.key) {
        '2026-3' => DateTime(2026, 8, 31),
        '2026-12' => DateTime(2027, 2, 22),
        _ => null,
      },
    );
  }
}
