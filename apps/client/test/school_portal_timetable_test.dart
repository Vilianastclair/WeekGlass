import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:weekglass/features/course_import/school_portal_catalog.dart';
import 'package:weekglass/features/course_import/school_portal_timetable.dart';

Object? _dom(String fixture) {
  final p = Process.runSync(
    'node',
    [
      '../../tooling/scripts/test-school-portal-dom.mjs',
      'test/fixtures/school_portal/$fixture.html',
    ],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  expect(p.exitCode, 0, reason: p.stderr.toString());
  return jsonDecode(p.stdout as String);
}

void main() {
  test('every school shortcut opens through the same validated site model', () {
    for (final e in schoolPortalCatalog) {
      final site = SchoolPortalSite.fromEntry(e.entry, name: e.name);
      expect(site.permits(site.entry), isTrue, reason: e.name);
    }
  });

  test('same university SSO can navigate and return but cannot be read', () {
    final site = SchoolPortalSite.fromEntry('https://jwxt.shu.edu.cn/');
    final sso = Uri.parse('https://newsso.shu.edu.cn/login');
    expect(site.permits(sso), isTrue);
    expect(site.canRead(sso), isFalse);
    expect(
      site.canRead(Uri.parse('https://jwxt.shu.edu.cn/xtgl/login_slogin.html')),
      isFalse,
    );
    expect(site.canRead(Uri.parse('https://jwxt.shu.edu.cn/kbcx')), isTrue);
    for (final url in [
      'https://shu.edu.cn.example.org/',
      'http://jwxt.shu.edu.cn/',
      'file:///tmp/site.html',
      'https://user@jwxt.shu.edu.cn/',
      'https://other.edu.cn/',
    ]) {
      expect(site.permits(Uri.parse(url)), isFalse, reason: url);
    }
    for (final entry in [
      'https://jwxt.shu.edu.cn/?ticket=example',
      'https://shu.edu.cn.example.org/',
      'https://jwxt.shu.edu.cn/#token',
      'https://name:secret@jwxt.shu.edu.cn/',
      'https://edu.cn',
      'javascript:void(1)',
    ]) {
      expect(
        () => SchoolPortalSite.fromEntry(entry),
        throwsFormatException,
        reason: entry,
      );
    }
  });

  final browser =
      Platform.isWindows || Platform.environment['WG_TEST_BROWSER'] != null;
  test('Qiangzhi Sunday and actual three-period detail override two-period row label', () {
    final rows = SchoolPortalTimetable.parse(_dom('qiangzhi'));
    expect(rows.warnings, isEmpty);
    final m = rows.meetings.single;
    expect(m.weekday, 7);
    expect(m.periods, [5, 6, 7]);
    expect(m.weeks, [1, 3, 5]);
    expect(m.teacher, '示例老师');
  }, skip: !browser);
  test('a password page or blank timetable returns no timetable data', () {
    final login = _dom('login');
    expect(login, {'error': 'login', 'rows': []});
    final empty = _dom('empty');
    expect(empty, {'error': 'missing', 'rows': []});
    for (final p in [login, empty]) {
      expect(() => SchoolPortalTimetable.parse(p), throwsFormatException);
    }
  }, skip: !browser);
}
