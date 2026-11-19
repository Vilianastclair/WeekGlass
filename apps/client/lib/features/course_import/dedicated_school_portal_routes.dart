import 'classic_eams_timetable.dart';
import 'dedicated_school_portal_route.dart';
import 'eams_print_sites.dart';
import 'emap_personal_timetable.dart';
import 'fudan_portal_timetable.dart';
import 'modern_qz_routes.dart';
import 'print_data_school_site.dart';
import 'sjtu_portal_timetable.dart';
import 'sustech_personal_timetable.dart';
import 'szu_portal_timetable.dart';
import 'ucas_portal_timetable.dart';

final dedicatedSchoolPortalRoutes =
    List<DedicatedSchoolPortalRoute>.unmodifiable([
      for (final site in [
        FudanPortalTimetable.site,
        ...additionalPrintDataSites,
      ])
        DedicatedSchoolPortalRoute(
          name: site.name,
          entry: site.entry,
          asset: PrintDataSchoolSite.asset,
          matchesSystem: site.matchesSystem,
          matchesPersonalPage: site.matchesPersonalPage,
          script: site.script,
          parse: site.parse,
        ),
      ...emapPersonalRoutes,
      ...modernQzRoutes,
      ...classicEamsRoutes,
      SustechPersonalTimetable.route,
      SjtuPortalTimetable.route,
      const DedicatedSchoolPortalRoute(
        name: UcasPortalTimetable.name,
        entry: UcasPortalTimetable.entry,
        campusDomain: 'ucas.ac.cn',
        personalPageHint: '登录 SEP 后，进入「选课系统」，打开所选学期的「查看个人课表」。',
        asset: UcasPortalTimetable.asset,
        matchesSystem: UcasPortalTimetable.onCampusSystem,
        matchesPersonalPage: UcasPortalTimetable.matchesPersonalPage,
        script: UcasPortalTimetable.script,
        parse: UcasPortalTimetable.parse,
      ),
      const DedicatedSchoolPortalRoute(
        name: SzuPortalTimetable.name,
        entry: SzuPortalTimetable.entry,
        asset: SzuPortalTimetable.asset,
        matchesSystem: SzuPortalTimetable.onCampusSystem,
        matchesPersonalPage: SzuPortalTimetable.matchesPersonalPage,
        script: SzuPortalTimetable.script,
        parse: SzuPortalTimetable.parse,
      ),
    ]);

DedicatedSchoolPortalRoute? dedicatedSchoolPortalFor(Uri? uri) {
  for (final route in dedicatedSchoolPortalRoutes) {
    if (route.matchesSystem(uri)) return route;
  }
  return null;
}
