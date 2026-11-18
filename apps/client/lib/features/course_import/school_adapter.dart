import 'school_html_format.dart';
import 'school_portal_timetable.dart';
import 'whu_timetable.dart';

/// A reviewed official school origin, not a user supplied script or URL.
/// New Zhengfang deployments share the personal-timetable response schema;
/// an accessible login page does not establish a successful account import.
class SchoolAdapter {
  const SchoolAdapter({
    required this.id,
    required this.name,
    required this.entry,
    required this.origin,
    required this.pathPrefix,
    required this.loginHosts,
    required this.evidenceUrl,
    this.verifiedImport = false,
    this.loginDescription = '学校统一身份认证',
  });

  final String id, name, entry, origin, pathPrefix, evidenceUrl;
  final String loginDescription;
  final Set<String> loginHosts;
  final bool verifiedImport;

  String get host => Uri.parse(origin).host;
  String get status => verifiedImport ? '课程读取已验证' : '官方入口已核验 · 课程读取待验证';
  String get timetablePath => '$pathPrefix/kbcx/xskbcx_cxXskbcxIndex.html';
  String get responsePath => '$pathPrefix/kbcx/xskbcx_cxXsgrkb.html';
  String get timetableUrl =>
      '$origin$timetablePath?gnmkdm=N2151&layout=default';

  bool allowed(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.port == 443 &&
        uri.userInfo.isEmpty &&
        (uri.host == host || loginHosts.contains(uri.host));
  }

  bool isTeachingPage(String url) {
    final uri = Uri.tryParse(url);
    return allowed(url) && uri!.origin == origin;
  }

  DateTime? firstMonday(WhuTerm term) =>
      id == 'whu' ? term.calendarFirstMonday : null;
  int? calendarWeeks(WhuTerm term) => id == 'whu' ? term.calendarWeeks : null;

  // Sources and verification boundaries are documented in
  // docs/product/school-import-adapters.md. No wildcard login domains.
  static const whu = SchoolAdapter(
    id: 'whu',
    name: '武汉大学',
    entry: 'https://jwgl.whu.edu.cn/',
    origin: 'https://jwgl.whu.edu.cn',
    pathPrefix: '',
    loginHosts: {'cas.whu.edu.cn'},
    evidenceUrl: 'https://jwgl.whu.edu.cn/',
    verifiedImport: true,
  );
  static const shu = SchoolAdapter(
    id: 'shu',
    name: '上海大学',
    entry: 'https://jwxt.shu.edu.cn/',
    origin: 'https://jwxt.shu.edu.cn',
    pathPrefix: '/jwglxt',
    loginHosts: {'newsso.shu.edu.cn'},
    evidenceUrl: 'https://bksy.shu.edu.cn/info/1445/321844.htm',
  );
  static const buct = SchoolAdapter(
    id: 'buct',
    name: '北京化工大学',
    entry: 'https://jwglxt.buct.edu.cn/jwglxt/xtgl/login_slogin.html',
    origin: 'https://jwglxt.buct.edu.cn',
    pathPrefix: '/jwglxt',
    loginHosts: {},
    loginDescription: '学校官方教务登录',
    evidenceUrl: 'https://jiaowuchu.buct.edu.cn/main.htm',
  );

  // Keep legacy source IDs recognized even when a school is paused.
  static const all = [whu, shu, buct];

  // Expose only schools that have passed an end-to-end account import.
  static const available = [whu];

  static bool acceptsImportSource(String? source) =>
      source != null &&
      (source.startsWith('${SchoolPortalTimetable.sourceId}:') ||
          all.any((school) => source.startsWith('${school.id}:')) ||
          SchoolHtmlFormat.values.any(
            (format) => source.startsWith('${format.sourceId}:'),
          ));
}
