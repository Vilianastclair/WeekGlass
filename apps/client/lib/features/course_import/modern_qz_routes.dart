import 'dart:convert';

import 'dedicated_school_portal_route.dart';
import 'print_data_course_timetable.dart';

const _path = '/jsxsd/xskb/xskb_list.do';
const _profiles = {
  '湖南大学': 'https://hdjw.hnu.edu.cn',
  '中国海洋大学': 'https://jwgl2024.ouc.edu.cn',
  '东北林业大学': 'https://jwxt-443.webvpn.nefu.edu.cn',
};

// These campuses expose a term timetable in their personal weeklyTable.
// Read the already displayed table; no proxy, credential or network call.
final modernQzRoutes = [
  for (final site in _profiles.entries)
    DedicatedSchoolPortalRoute(
      name: site.key,
      entry: '${site.value}$_path',
      asset: 'assets/school_portal/read_weekly_table.js',
      matchesSystem: (uri) => _sameCampus(uri, site.value),
      matchesPersonalPage: (uri) =>
          _sameCampus(uri, site.value) && uri!.path == _path,
      script: (text, term) =>
          '(${text.trim()})(${jsonEncode(site.value)},${jsonEncode(_path)},'
          '${jsonEncode('${term.year}-${term.year + 1}-${switch (term.semester) {
            3 => 1,
            12 => 2,
            16 => 3,
            _ => 0,
          }}')})',
      parse: (data, term) =>
          PrintDataCourseTimetable.parse(data['rows']),
    ),
];

bool _sameCampus(Uri? uri, String origin) =>
    uri != null &&
    uri.scheme == 'https' &&
    uri.userInfo.isEmpty &&
    !uri.authority.contains('@') &&
    uri.origin == origin;

