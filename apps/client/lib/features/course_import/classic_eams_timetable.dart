import 'dart:convert';

import 'dedicated_school_portal_route.dart';
import 'print_data_course_timetable.dart';

const _home = '/eams/home.action';
const _personal = '/eams/courseTableForStd.action';
const _grid = '/eams/courseTableForStd!courseTable.action';
const _asset = 'assets/school_portal/read_classic_eams.js';
final classicEamsRoutes = [_nuaa, _uestc];

final _nuaa = _route('南京航空航天大学', 'https://aao-eas.nuaa.edu.cn', 'nuaa');
final _uestc = _route('电子科技大学', 'https://eams.uestc.edu.cn', 'uestc');

DedicatedSchoolPortalRoute _route(String name, String origin, String campus) {
  bool system(Uri? uri) =>
      uri != null &&
      uri.scheme == 'https' &&
      uri.origin == origin &&
      (uri.path == '/eams' || uri.path.startsWith('/eams/'));
  return DedicatedSchoolPortalRoute(
    name: name,
    entry: '$origin/eams/login.action',
    asset: _asset,
    matchesSystem: system,
    // The home shell can contain the school's own AJAX personal form.
    // The in-page script verifies that form before processing its grid.
    matchesPersonalPage: (uri) =>
        system(uri) && {_home, _personal, _grid}.contains(uri!.path),
    script: (js, term) =>
        '(${js.trim()})(${jsonEncode(origin)},${jsonEncode(campus)},'
        '${jsonEncode({'year': term.year, 'semester': term.semester})})',
    parse: (data, term) => PrintDataCourseTimetable.parse(
      data['rows'],
      // Both universities publish 31 August as the first Monday for this
      // term. The schools have multiple bell schedules, so leave times to
      // the existing preview instead of picking a campus for the student.
      suggestedFirstMonday: term.key == '2026-3' ? DateTime(2026, 8, 31) : null,
    ),
  );
}
