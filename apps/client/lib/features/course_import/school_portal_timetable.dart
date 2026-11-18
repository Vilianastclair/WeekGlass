import 'dart:convert';

import 'whu_timetable.dart';
import 'school_portal_catalog.dart';
import 'wakeup_catalog.dart';

/// Exact-origin reads are independent of the school's SSO navigation.
class SchoolPortalSite {
  SchoolPortalSite._(
    this.name,
    this.entry,
    this.campusDomain,
    this.parsers,
    this.readOrigins,
  );
  final String name;
  final Uri entry;
  final String campusDomain;
  final List<String> parsers;
  final Set<String> readOrigins;

  factory SchoolPortalSite.fromEntry(String raw, {String? name}) {
    final uri = Uri.tryParse(raw.trim());
    final host = uri?.host.toLowerCase() ?? '';
    final labels = host.split('.');
    final trustedCampusDomain =
        wakeupCampusDomains.containsKey(host) &&
            schoolPortalCatalog.any((s) => s.name == name && s.entry == raw)
        ? wakeupCampusDomains[host]
        : null;
    final parsers = wakeupParsersFor(name ?? '', host);
    final readOrigins = wakeupReadOrigins[name] ?? const <String>[];
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.authority.contains('@') ||
        uri.query.isNotEmpty ||
        uri.hasFragment ||
        labels.length < 3 ||
        (!host.endsWith('.edu.cn') &&
            !(trustedCampusDomain != null &&
                (host == trustedCampusDomain ||
                    host.endsWith('.$trustedCampusDomain')))) ||
        labels.any(
          (s) => !RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(s),
        )) {
      throw const FormatException(
        '请填写学校官网提供的 HTTPS 教务地址，使用本校 edu.cn 域名，不含登录票据、查询参数或片段。',
      );
    }
    return SchoolPortalSite._(
      name ?? host,
      uri,
      trustedCampusDomain ?? labels.sublist(labels.length - 3).join('.'),
      List.unmodifiable(parsers),
      Set.unmodifiable({uri.origin, ...readOrigins}),
    );
  }

  bool permits(Uri? uri) =>
      uri != null &&
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      !uri.authority.contains('@') &&
      (uri.host == campusDomain || uri.host.endsWith('.$campusDomain'));
  bool mayReadLocation(Uri? uri) =>
      permits(uri) &&
      !RegExp(
        r'^(?:cas|newcas|sso|newsso|auth(?:entication|server)?|ids|identity|iam|idp|uis|tpass|passport|mfa)(?:[-.0-9]|$)',
        caseSensitive: false,
      ).hasMatch(uri!.host) &&
      !RegExp(
        r'(?:^|[?&#])(?:ticket|(?:access|id)_token|SAMLResponse|SAMLRequest|code)=',
        caseSensitive: false,
      ).hasMatch('${uri.query}&${uri.fragment}') &&
      !RegExp(
        r'(?:^|/)(?:login|sso|cas|authserver|captcha|signin)(?:[./_;-]|$)',
        caseSensitive: false,
      ).hasMatch('${uri.path}/${uri.fragment}');
  bool canRead(Uri? uri) =>
      mayReadLocation(uri) && readOrigins.contains(uri!.origin);
  bool mayConfirmOrigin(Uri? uri) =>
      mayReadLocation(uri) && !readOrigins.contains(uri!.origin);
}

class SchoolPortalTimetable {
  static const sourceId = 'school_web';
  static const asset = 'assets/school_portal/read_timetable.js';
  static String script(String assetText, Uri entry) =>
      '(${assetText.trim()})(${jsonEncode(entry.origin)})';

  static WhuTimetable parse(Object? value) {
    // Windows decodes one JSON layer in the plugin. Android can return the
    // JavaScript string itself wrapped in one additional JSON string.
    for (var i = 0; i < 2 && value is String; i++) {
      if (value.length > 3000000) {
        throw const FormatException('页面课表过大，请选择单学期的个人课表。');
      }
      value = jsonDecode(value);
    }
    if (value is! Map) throw const FormatException('教务页没有返回可识别的课表。');
    final error = value['error'];
    if (error != null) {
      throw FormatException(switch (error) {
        'origin' || 'login' => '请先完成学校登录，再打开本人课表。',
        'multiple' => '当前页显示多张课表，请单独打开本学期的个人课表。',
        'shape' => '页面未标明完整的星期或节次，请切换到学期课表视图。',
        'large' => '页面课程过多，请选择单学期的个人课表。',
        _ => '未找到支持的课表。请在教务页打开有课程的学期课表；若已经打开，此版式暂不支持。',
      });
    }
    final rows = value['rows'];
    if (rows is! List || rows.length > 1000) {
      throw const FormatException('教务页课表条目无法识别。');
    }
    final mapped = <Map<String, dynamic>>[];
    final warnings = <String>[];
    for (final row in rows.whereType<Map>()) {
      String field(String k) => schoolText(row[k] ?? '');
      final title = field('title'), time = field('time');
      String weeks = '', periods = '';
      switch (row['kind']) {
        case 'zf':
          final m = RegExp(r'[（(]第?\s*([\d节\s,，、～~至—－-]+)\s*节[）)]')
              .firstMatch(time);
          if (m != null) {
            periods = m[1]!;
            weeks = time.replaceRange(m.start, m.end, '').trim();
          }
        case 'qz':
          final m = RegExp(r'^(.*?)\s*\[\s*([\d\s,，、～~至—－-]+)\s*节?\s*\]$')
              .firstMatch(time);
          weeks = m?[1] ?? (field('weeks').isNotEmpty ? field('weeks') : time);
          periods = m?[2] ?? field('periods');
          // Some installations encode consecutive two-digit periods as 010203.
          if (RegExp(r'^\d{1,2}(?:-\d{1,2}){2,}$').hasMatch(periods)) {
            periods = periods.replaceAll('-', ',');
          }
          final packed = RegExp(r'^\d{4}(?:\d{2})*$').firstMatch(periods);
          if (packed != null) {
            periods = RegExp(r'\d{2}')
                .allMatches(periods)
                .map((m) => m[0]!)
                .join(',');
          }
        case 'oldzf':
          final m = RegExp(
            r'^(?:周|星期)(?:[一二三四五六日天1-7])\s*第?\s*([\d\s,，、～~至—－-]+)节\s*\{([^{}]+)\}$',
          ).firstMatch(time);
          if (m != null) {
            periods = m[1]!;
            weeks = m[2]!
                .replaceAll(RegExp(r'\|单周$'), '(单)')
                .replaceAll(RegExp(r'\|双周$'), '(双)');
          }
      }
      if (periods.isEmpty || weeks.isEmpty || row['invalid'] == true) {
        warnings.add('${title.isEmpty ? '未命名课程' : title}：没有明确的教学周和节次，未安排。');
        continue;
      }
      mapped.add({
        'kcmc': title,
        'xqj': row['day'],
        'jcs': periods.replaceAll(RegExp(r'[～~至–]'), '-'),
        'zcd': weeks
            .replaceAll(RegExp(r'[～~至–]'), '-')
            .replaceAll('（周）', '周')
            .replaceAll('(周)', '周'),
        'xm': field('teacher'),
        'cdmc': field('room'),
      });
    }
    final result = WhuTimetable.parse({'kbList': mapped});
    final allWarnings = [
      ...warnings,
      ...result.warnings,
      if (value['supplemental'] == true) '页面另有实践或调课记录，请对照学校原表单独安排。',
    ];
    if (result.meetings.isEmpty) {
      throw FormatException(
        allWarnings.isNotEmpty
            ? '没有可安排的课程。${allWarnings.first}'
            : '当前课表没有课程，请确认所选学期。',
      );
    }
    return WhuTimetable(
      meetings: result.meetings,
      warnings: allWarnings,
      account: '',
    );
  }
}
