import 'dart:convert';

import 'dedicated_school_portal_route.dart';
import 'whu_timetable.dart';

// These campuses publish this exact personal EMAP action. No other host or
// application (especially the all-school kcbcx) inherits the binding.
final emapPersonalRoutes = [
  _route('北京理工大学', 'https://jxzxehallapp.bit.edu.cn', 'wdkbby'),
  _route('吉林大学', 'https://iedu.jlu.edu.cn', 'wdkb', portal: true),
  _route('哈尔滨工程大学', 'https://jwgl.hrbeu.edu.cn', 'wdkb'),
  _route('南京信息工程大学', 'https://jwxt.nuist.edu.cn', 'wdkb'),
  _route('西北农林科技大学', 'https://newehall.nwafu.edu.cn', 'wdkbby', portal: true),
];

DedicatedSchoolPortalRoute _route(
  String name,
  String origin,
  String app, {
  bool portal = false,
}) {
  final root = '/jwapp/sys/$app';
  final path = '$root/*default/index.do';
  return DedicatedSchoolPortalRoute(
    name: name,
    entry: portal ? '$origin/' : '$origin$path',
    asset: 'assets/school_portal/read_emap_personal.js',
    matchesSystem: (u) =>
        u != null &&
        u.isAbsolute &&
        u.host == Uri.parse(origin).host &&
        (u.path == '/' || u.path == root || u.path.startsWith('$root/')),
    matchesPersonalPage: (u) =>
        u != null &&
        u.isAbsolute &&
        u.host.isNotEmpty &&
        u.origin == origin &&
        u.path == path &&
        u.userInfo.isEmpty &&
        !RegExp(
          r'(?:^|[?&#])(?:ticket|code|access_token|id_token|SAMLResponse)=',
          caseSensitive: false,
        ).hasMatch('${u.query}&${u.fragment}'),
    script: (js, term) {
      final season = switch (term.semester) {
        3 => 1,
        12 => 2,
        _ => throw const FormatException('此校仅核对了秋季和春季的个人课表。'),
      };
      final code = '${term.year}-${term.year + 1}-$season';
      return '(${js.trim()})(${jsonEncode(origin)},${jsonEncode(root)},${jsonEncode(code)})';
    },
    parse: (data, _) => parseEmapTimetable(data),
  );
}

WhuTimetable parseEmapTimetable(Map data) {
  final rows = data['rows'];
  if (rows is! List || rows.isEmpty || rows.length > 500) {
    throw const FormatException('教务系统没有返回所选学期的已排课程。');
  }
  final meetings = <WhuCourseMeeting>[];
  final seen = <String>{};
  final pending = data['pending'];
  final warnings = <String>{
    if (pending is int && pending > 0) '另有 $pending 门课程尚未排定时间，未加入周历。',
  };
  for (final r in rows) {
    if (r is! Map) throw const FormatException('学校返回的课表行无法识别。');
    String t(String key) => r[key] is String ? schoolText(r[key]) : '';
    final name = t('name');
    final day = int.tryParse('${r["day"]}'),
        first = int.tryParse('${r["first"]}'),
        last = int.tryParse('${r["last"]}');
    final bits = t('bits');
    final weeks = RegExp(r'^[01]{1,53}$').hasMatch(bits)
        ? [
            for (var n = 0; n < bits.length; n++)
              if (bits[n] == '1') n + 1,
          ]
        : bits.isEmpty && t('weekText').isNotEmpty
        ? parseTeachingWeeks(t('weekText'))
        : <int>[];
    if (name.isEmpty ||
        day == null ||
        day < 1 ||
        day > 7 ||
        first == null ||
        last == null ||
        first < 1 ||
        last < first ||
        last > 30 ||
        weeks.isEmpty) {
      warnings.add('${name.isEmpty ? "未命名课程" : name}：校方未给出可识别的星期、节次或周次，未安排。');
      continue;
    }
    final teacher = t('teacher'), room = t('room');
    final key = whuHash(
      jsonEncode(
        t('course').isNotEmpty ? [t('course'), t('section')] : [name, teacher],
      ),
    ).substring(0, 24);
    if (!seen.add(jsonEncode([key, day, first, last, weeks, teacher, room])))
      continue;
    meetings.add(
      WhuCourseMeeting(
        courseKey: key,
        title: name,
        weekday: day,
        periods: [for (var i = first; i <= last; i++) i],
        weeks: weeks,
        weekText: '${weeks.join('、')}周',
        room: room,
        teacher: teacher,
      ),
    );
  }
  if (meetings.isEmpty) throw const FormatException('未找到有明确周次和节次的个人课程。');
  return WhuTimetable(
    meetings: meetings,
    warnings: warnings.toList(),
    account: '',
  );
}
