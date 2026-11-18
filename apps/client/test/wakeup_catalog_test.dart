import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:weekglass/features/course_import/school_portal_catalog.dart';
import 'package:weekglass/features/course_import/school_portal_reader.dart';
import 'package:weekglass/features/course_import/wakeup_catalog.dart';

void main() {
  test('every native reader has a school or human-readable system route', () {
    final registry =
        jsonDecode(
              File('../../tooling/course_adapter_engine/registry.json')
                  .readAsStringSync(),
            )['adapters']
            as List;
    final bound = {
      for (final route in wakeupSchoolBindings.values) ...route,
      for (final system in SchoolPortalSystem.values) ...system.parsers,
    };
    final recognized = <String>{};
    for (final row in registry) {
      final names = {
        row['id'] as String,
        ...(row['aliases'] as List).cast<String>(),
      };
      recognized.addAll(names);
      if (row['inputKind'] == 'csv') {
        expect(names.intersection(bound), isEmpty);
      } else {
        expect(names.intersection(bound), isNotEmpty, reason: row['id']);
      }
    }
    expect(bound.difference(recognized), isEmpty);
  });
  test('school and host routing preserves graduate and alternate portals', () {
    final entries = {
      for (final site in schoolPortalCatalog) site.name: Uri.parse(site.entry),
    };
    for (final e in entries.entries) {
      expect(e.value.scheme, 'https');
      expect(
        e.value.hasQuery || e.value.hasFragment || e.value.userInfo.isNotEmpty,
        false,
      );
      expect(wakeupParsersFor(e.key, e.value.host), isNotEmpty, reason: e.key);
    }
    expect(entries['上海大学']!.host, 'jwxt.shu.edu.cn');
    expect(entries['上海大学（选课系统）']!.host, 'jwxk.shu.edu.cn');
    expect(wakeupParsersFor('西北工业大学（研究生）', ''), contains('NWPUGraduateParser'));
    expect(
      wakeupParsersFor('西北工业大学', ''),
      isNot(contains('NWPUGraduateParser')),
    );
    expect(wakeupParsersFor('', 'byxt.buaa.edu.cn'), contains('BUAAParser'));
    expect(wakeupParsersFor('', 'byxt.buaa.edu.cn.invalid'), isEmpty);
    expect(entries.containsKey('武汉大学'), isFalse);
  });
}
