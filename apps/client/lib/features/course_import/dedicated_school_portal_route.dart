import 'dart:async';

import 'whu_timetable.dart';

/// The school system may navigate to login or catalog pages; only the
/// personal route may invoke its timetable script.
class DedicatedSchoolPortalRoute {
  const DedicatedSchoolPortalRoute({
    required this.name,
    required this.entry,
    required this.asset,
    required this.matchesSystem,
    required this.matchesPersonalPage,
    required this.script,
    required this.parse,
    this.personalPageHint,
    this.campusDomain,
  });

  final String name;
  final String entry;
  final String asset;
  final bool Function(Uri?) matchesSystem;
  final bool Function(Uri?) matchesPersonalPage;
  final String Function(String, WhuTerm) script;
  final FutureOr<WhuTimetable> Function(Map, WhuTerm) parse;
  final String? personalPageHint;
  final String? campusDomain;
}
