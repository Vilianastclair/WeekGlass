import 'dart:convert';

import 'dedicated_school_portal_route.dart';
import 'whu_timetable.dart';

/// Southern University of Science and Technology undergraduate TIS.
abstract final class SustechPersonalTimetable {
  static const name = '南方科技大学';
  static const origin = 'https://tis.sustech.edu.cn';
  static const entry = '$origin/';
  static const _path = '/authentication/main';
  static const asset = 'assets/school_portal/read_sustech_personal.js';

  static const route = DedicatedSchoolPortalRoute(
    name: name,
    entry: entry,
    asset: asset,
    matchesSystem: matchesSystem,
    matchesPersonalPage: matchesPersonalPage,
    script: script,
    parse: parse,
    personalPageHint: '请在本科教务系统首页打开左侧的「课表」，切换到整学期视图，待课程显示后再读取。',
  );

  static bool matchesSystem(Uri? uri) =>
      uri != null &&
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      !uri.authority.contains('@') &&
      uri.origin == origin;

  // At this location the asset still requires an open personal timetable.
  static bool matchesPersonalPage(Uri? uri) =>
      matchesSystem(uri) && uri!.path == _path;

  static Map<String, String> _term(WhuTerm term) => {
    'xn': '${term.year}-${term.year + 1}',
    'xq': switch (term.semester) {
      3 => '1',
      12 => '2',
      16 => '3',
      _ => throw const FormatException('请选择南科大的秋季、春季或夏季学期。'),
    },
  };

  static String script(String js, WhuTerm term) =>
      '(${js.trim()})(${jsonEncode(origin)},${jsonEncode(_path)},'
      '${jsonEncode(_term(term))})';

  static final _gridPosition = RegExp(
    r'^xq([1-7])_jc\d{1,2}$',
    caseSensitive: false,
  );
  // SKSJ describes one meeting, with an optional or empty fifth group when
  // the structured KSJC and JSJC fields already specify the periods.
  static final _details = RegExp(
    r'^([^\[\]]+)\[([^\]]*)\]\s*\[([^\]]*)\]\s*\[([^\]]*)\]\s*\[([^\]]*)\]\s*(?:\[([^\]]*)\]\s*)?$',
  );
  static final _singleParity = RegExp(r'^([\d,，、\-–—－~～至\s]+)([单双])周$');
  static final _weekParity = RegExp(
    r'周([单双])周?(?=\s*[,，、;；]|\s*$)|([单双])周(?=\s*[,，、;；]|\s*$)',
  );
  static final _bitmap = RegExp(r'^[01]{2,54}$');

  // Published by the teaching office. The official grid stops at period 11;
  // preserve longer arrangements for manual confirmation rather than guessing.
  static const _publishedClock = [
    ClassPeriod(480, 530),
    ClassPeriod(540, 590),
    ClassPeriod(620, 670),
    ClassPeriod(680, 730),
    ClassPeriod(840, 890),
    ClassPeriod(900, 950),
    ClassPeriod(980, 1030),
    ClassPeriod(1040, 1090),
    ClassPeriod(1140, 1190),
    ClassPeriod(1200, 1250),
    ClassPeriod(1260, 1310),
  ];

  static DateTime? _firstMonday(WhuTerm term) => switch (term.key) {
    '2025-12' => DateTime(2026, 2, 23),
    '2025-16' => DateTime(2026, 6, 29),
    '2026-3' => DateTime(2026, 9, 7),
    _ => null,
  };

  static WhuTimetable parse(Map data, WhuTerm term) {
    final requested = _term(term);
    if (data['term'] != "${requested['xn']}-${requested['xq']}") {
      throw const FormatException('南科大课表与所选学期不一致。');
    }
    final rows = data['rows'];
    if (rows is! List || rows.length > 1200) {
      throw const FormatException('南科大没有返回可识别的本科课表。');
    }
    final meetings = <WhuCourseMeeting>[];
    final seen = <String>{};
    final warnings = <String>{};
    for (final row in rows) {
      if (row is! Map) {
        warnings.add('有一条课程格式无法识别，未安排。');
        continue;
      }
      final position = _text(row['KEY']);
      if (position.toLowerCase() == 'bz') continue; // Schedule notes.
      final detail = _text(row['SKSJ'], preserveLines: true);
      final fields = _details.firstMatch(detail);
      final title = fields?[1]?.trim() ?? '';
      try {
        if (title.isEmpty) throw const FormatException('课程详情格式无法识别');
        final day = _gridPosition.firstMatch(position);
        if (day == null) throw const FormatException('没有明确的上课星期');
        final weekday = int.parse(day[1]!);
        final teacher = fields![2]!.trim(), section = fields[3]!.trim();
        final declaredWeeks = fields[4]!.trim(), room = fields[5]!.trim();
        final weeks = _weeks(declaredWeeks, _text(row['ZC']));
        final periods = _periods(row, fields[6]?.trim() ?? '');
        // Keep the former live reader's course identity so existing events
        // still match when their schedule and ordinal are unchanged.
        final courseKey = whuHash('$title|$teacher').substring(0, 24);
        if (!seen.add(
          jsonEncode([courseKey, weekday, periods, weeks, room, section]),
        )) {
          continue;
        }
        meetings.add(
          WhuCourseMeeting(
            courseKey: courseKey,
            title: title,
            weekday: weekday,
            periods: periods,
            weeks: weeks,
            weekText: declaredWeeks.isEmpty
                ? '${weeks.join('、')}周'
                : declaredWeeks,
            room: room,
            teacher: teacher,
            note: section.isEmpty ? '' : '教学班：$section',
          ),
        );
      } on FormatException catch (e) {
        warnings.add('${title.isEmpty ? '未识别课程' : title}：${e.message}，未安排。');
      }
    }
    if (meetings.isEmpty) {
      throw FormatException(
        warnings.isEmpty ? '南科大没有返回所选学期的课程。' : '南科大没有可安排的课程。${warnings.first}',
      );
    }
    final monday = _firstMonday(term);
    if (monday != null) {
      warnings.add('预览按学校校历和整学期课表排课，遇节假日或调停课请按学校最新通知核对。');
      if (meetings.any((m) => m.periods.last > _publishedClock.length)) {
        warnings.add('有课程超过学校公布的常规节次，请按本人课表补齐上课时间。');
      }
    }
    return WhuTimetable(
      meetings: meetings,
      warnings: warnings.toList(),
      account: '',
      suggestedFirstMonday: monday,
      suggestedClock: monday == null ? null : _publishedClock,
    );
  }

  static List<int> _periods(Map row, String detail) {
    final stated = detail.isEmpty
        ? null
        : parsePeriods(detail.replaceAll(RegExp(r'[–~～至]'), '-'));
    final first = int.tryParse(row['KSJC']?.toString() ?? '');
    final last = int.tryParse(row['JSJC']?.toString() ?? '');
    if (first == null && last == null && stated != null) return stated;
    if (first == null || last == null) throw const FormatException('缺少完整节次');
    final structured = parsePeriods('$first-$last');
    if (stated != null && !_same(stated, structured)) {
      throw const FormatException('节次字段与课表说明不一致');
    }
    return structured;
  }

  static List<int> _weeks(String detail, String bitmap) {
    final allParity = _singleParity.firstMatch(detail);
    final normalized = allParity == null
        ? detail.replaceAllMapped(_weekParity, (m) => '周(${m[1] ?? m[2]})')
        : allParity[1]!;
    final declared = detail.isEmpty
        ? null
        : parseTeachingWeeks(normalized.replaceAll(RegExp(r'[–~]'), '-'))
              .where(
                (week) =>
                    allParity == null ||
                    (allParity[2] == '单' ? week.isOdd : week.isEven),
              )
              .toList();
    if (bitmap.isEmpty && declared != null && declared.isNotEmpty) {
      return declared;
    }
    if (!_bitmap.hasMatch(bitmap)) throw const FormatException('教学周字段无法识别');
    final indexed = [
      for (var i = 1; i < bitmap.length; i++)
        if (bitmap[i] == '1') i,
    ];
    if (bitmap[0] == '0' &&
        indexed.isNotEmpty &&
        (declared == null || _same(declared, indexed))) {
      return indexed;
    }
    // The alternative off-by-one interpretation is only accepted when the
    // school's explicit week text agrees; do not infer it from overlap alone.
    final alternate = [
      for (var i = 0; i < bitmap.length && i < 53; i++)
        if (bitmap[i] == '1') i + 1,
    ];
    if (declared != null && declared.isNotEmpty && _same(declared, alternate)) {
      return declared;
    }
    throw const FormatException('教学周位图与课表说明不一致');
  }

  static bool _same(List<int> a, List<int> b) =>
      a.length == b.length &&
      Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);

  static String _text(Object? value, {bool preserveLines = false}) =>
      value is String
      ? schoolText(
          preserveLines
              ? value.replaceAll(
                  RegExp(r'<br\s*/?>', caseSensitive: false),
                  '\n',
                )
              : value,
        )
      : '';
}
