import 'dart:convert';

import 'dedicated_school_portal_route.dart';
import 'whu_timetable.dart';

/// Shanghai Jiao Tong University's undergraduate personal timetable only.
abstract final class SjtuPortalTimetable {
  static const name = '上海交通大学';
  static const _host = 'i.sjtu.edu.cn';
  static const origin = 'https://$_host';
  static const entry = '$origin/';
  static const path = '/kbcx/xskbcx_cxXskbcxIndex.html';
  static const asset = 'assets/school_portal/read_sjtu_personal.js';
  static const route = DedicatedSchoolPortalRoute(
    name: name,
    entry: entry,
    asset: asset,
    matchesSystem: onCampusSystem,
    matchesPersonalPage: matchesPersonalPage,
    script: script,
    parse: parse,
    personalPageHint: '用 jAccount 登录，在「信息查询」打开个人课表，选择与应用相同的学年学期。',
  );

  static bool onCampusSystem(Uri? uri) => uri?.host == _host;

  static bool matchesPersonalPage(Uri? uri) =>
      onCampusSystem(uri) &&
      uri!.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      !uri.authority.contains('@') &&
      uri.origin == origin &&
      uri.path == path;

  static String script(String js, WhuTerm term) {
    if (!const {3, 12, 16}.contains(term.semester)) {
      throw const FormatException('请选择上海交通大学的秋季、春季或夏季学期。');
    }
    return '(${js.trim()})(${jsonEncode(origin)},${jsonEncode(path)},'
        '${jsonEncode('${term.year}')},${jsonEncode('${term.semester}')})';
  }

  static WhuTimetable parse(Map data, WhuTerm term) {
    final rows = data['kbList'];
    if (rows is! List || rows.length > 1000) {
      throw const FormatException('上海交通大学没有返回可识别的本科课表。');
    }
    final timetable = WhuTimetable.parse({
      'kbList': [
        for (final row in rows)
          if (row is Map)
            {
              ...row,
              'jcs': row['jcs'] ?? row['jc'],
              'cdmc': [
                if (_text(row['xqmc']).isNotEmpty &&
                    !_text(row['cdmc']).startsWith(_text(row['xqmc'])))
                  _text(row['xqmc']),
                if (_text(row['cdmc']).isNotEmpty) _text(row['cdmc']),
              ].join(' '),
            }
          else
            row,
      ],
    });
    if (timetable.meetings.isEmpty) {
      throw FormatException(
        timetable.warnings.isEmpty
            ? '所选学期没有可导入的课程。'
            : '没有可安排的课程。${timetable.warnings.first}',
      );
    }
    return WhuTimetable(
      meetings: timetable.meetings,
      warnings: timetable.warnings,
      account: '',
      // https://jwc.sjtu.edu.cn/info/1252/127301.htm
      suggestedFirstMonday: term.key == '2026-3' ? DateTime(2026, 9, 14) : null,
    );
  }

  static String _text(Object? value) =>
      value is String ? schoolText(value) : '';
}
