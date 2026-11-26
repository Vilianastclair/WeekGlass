import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';

import 'dedicated_school_portal_routes.dart';
import 'school_portal_timetable.dart';
import 'wakeup_engine.dart';
import 'whu_timetable.dart';

enum SchoolPortalSystem {
  auto('自动识别', []),
  zhengfang('正方教务', ['NewZFParser', 'ZhengFangParser', 'zf_1']),
  qiangzhi('强智教务', [
    'QzWithNodeParser',
    'Qz2017Parser',
    'QzParser',
    'OldQzParser',
    'QzBrParser',
    'QzCrazyParser',
  ]),
  urp('URP 教务', ['UrpParser', 'NewUrpParser']),
  jinZhi('金智教务', ['JinZhiParser']),
  kingosoft('青果教务', ['KingosoftZXParser']),
  chengfang('乘方教务', ['ChengFangParser']),
  supwisdom('树维教务', ['SupwisdomParser']);

  const SchoolPortalSystem(this.label, this.parsers);
  final String label;
  final List<String> parsers;
}

class SchoolReadCancelled implements Exception {
  const SchoolReadCancelled();
}

typedef SchoolExecute = Future<Object?> Function(String script);

/// Called from the native read button, not from page loads or JavaScript bridges.
abstract final class SchoolPortalReader {
  static const collectorAsset = 'assets/school_portal/read_adapter.js';
  static const modelAsset = 'assets/school_portal/read_model.js';
  static const _auto = [
    'UrpParser',
    'JinZhiParser',
    'KingosoftZXParser',
    'SupwisdomParser',
    'ChengFangParser',
    'NewUrpParser',
  ];
  static const _direct = {
    'NewZFParser',
    'ZhengFangParser',
    'QzParser',
    'zf',
    'zf_new',
    'qz',
  };
  static String originCheck(Uri uri) =>
      '''
    (() => {
      if (location.origin!==${jsonEncode(uri.origin)}) return false;
      const docs=[document], visible=e=>e.getClientRects().length && e.ownerDocument.defaultView.getComputedStyle(e).visibility!=='hidden';
      for (const doc of docs) {
        if ([...doc.querySelectorAll('input[type="password"],input[autocomplete="one-time-code"]')].some(visible)) return false;
        for(const f of doc.querySelectorAll('iframe,frame')) {
          try {if(visible(f) && f.contentDocument?.location.origin===location.origin && docs.length<24 && !docs.includes(f.contentDocument)) docs.push(f.contentDocument);} catch(_) {}
        }
      }
      return true;
    })()
  ''';
  static Future<WhuTimetable> read({
    required Uri page,
    required WhuTerm term,
    required List<String> parsers,
    bool allowBundledEngine = true,
    Future<List<Map<String, dynamic>>> Function() listAdapters =
        WakeUpEngine.list,
    Future<WhuTimetable> Function({
          required String adapter,
          required String source,
          int? termWeeks,
        })
        parse =
        WakeUpEngine.parse,
    Future<int?> Function()? requestWeeks,
    required SchoolExecute execute,
    required bool Function() current,
  }) async {
    void check() {
      if (!current()) throw StateError('页面已切换，请在当前课表重新读取。');
    }

    Future<Object?> run(String script) async {
      check();
      final value = await execute(script).timeout(const Duration(seconds: 15));
      check();
      return value;
    }

    final dedicated = dedicatedSchoolPortalFor(page);
    if (dedicated != null) {
      if (!SchoolPortalSite.fromEntry(
        dedicated.entry,
        name: dedicated.name,
      ).canRead(page)) {
        throw const FormatException('请完成学校登录后再打开本人学期课表。');
      }
      final asset = await rootBundle.loadString(dedicated.asset);
      final data = await _runAsync(page, dedicated.script(asset, term), run);
      final error = data['error'];
      if (error != null) throw FormatException(_failure(error));
      final timetable = await dedicated.parse(data, term);
      check();
      return timetable;
    }

    Future<WhuTimetable?> direct() async {
      final js = await rootBundle.loadString(SchoolPortalTimetable.asset);
      final result = _map(await run(SchoolPortalTimetable.script(js, page)));
      if (const {
        'origin',
        'login',
        'large',
        'multiple',
      }.contains(result['error'])) {
        return SchoolPortalTimetable.parse(result);
      }
      try {
        return SchoolPortalTimetable.parse(result);
      } on FormatException {
        return null;
      }
    }

    // Keep the established day/period corrections and source IDs for these
    // grids. The bundled engine is used only when an adapter needs it.
    final directFirst = parsers.isEmpty || _direct.contains(parsers.first);
    if (directFirst || !allowBundledEngine) {
      final resolved = await direct();
      if (resolved != null) return resolved;
    }
    if (!allowBundledEngine) {
      throw const FormatException('此课表格式尚未适配 macOS，请使用学校导出的日历文件。');
    }
    final registry = await listAdapters();
    final pending = <String, String>{};
    for (final id in {...parsers, ..._auto}) {
      for (final row in registry) {
        if (row['available'] == true &&
            ['html', 'json'].contains(row['inputKind']) &&
            (row['id'] == id || (row['aliases'] as List).contains(id))) {
          // A few upstream filenames differ from their actual class names.
          final key = switch (row['id']) {
            'gxic' => 'GXICParser',
            'ccsu_qz_old' => 'CSXYParser',
            _ => (row['className'] as String).split('.').last,
          };
          // Distinct parameterizations of a class are tried separately if the
          // first version rejects this DOM.
          pending[id] = key;
          break;
        }
      }
    }
    final js = await rootBundle.loadString(collectorAsset);
    final model = await rootBundle.loadString(modelAsset);
    String? reason;
    while (pending.isNotEmpty) {
      final data = await _collect(
        page,
        term,
        js,
        model,
        pending.values.toSet().toList(),
        run,
      );
      final error = data['error'];
      if (error == 'missing' || error == 'endpoint') {
        reason ??= error as String;
        break;
      }
      if (error != null) throw FormatException(_failure(error));
      final type = data['adapter'], source = data['source'];
      if (source is! String || !pending.containsValue(type)) {
        throw const FormatException('学校页面没有返回可识别的课表。');
      }
      final choice = pending.entries.firstWhere((e) => e.value == type).key;
      pending.remove(choice);
      try {
        check();
        return await parse(adapter: choice, source: source);
      } on WakeUpEngineException catch (e) {
        if (e.code == 'NEED_TERM_WEEKS') {
          if (requestWeeks == null) rethrow;
          check();
          final weeks = await requestWeeks();
          if (weeks == null) throw const SchoolReadCancelled();
          check();
          return await parse(adapter: choice, source: source, termWeeks: weeks);
        }
        if (!{
          'NO_COURSES',
          'PARSE_ERROR',
          'UNSUPPORTED_INPUT',
        }.contains(e.code)) {
          rethrow;
        }
        if (choice == 'THUParser' && e.code == 'UNSUPPORTED_INPUT') {
          reason = 'termWeeks';
        } else {
          reason ??= 'shape';
        }
      }
    }
    if (!directFirst) {
      final resolved = await direct();
      if (resolved != null) return resolved;
    }
    throw FormatException(_failure(reason));
  }

  static Future<Map> _collect(
    Uri page,
    WhuTerm term,
    String js,
    String model,
    List<String> keys,
    SchoolExecute run,
  ) => _runAsync(
    page,
    '($js)(${jsonEncode(page.origin)},${jsonEncode(keys)},'
    '${jsonEncode({'year': term.year, 'semester': term.semester})},($model))',
    run,
  );

  // Android evaluateJavascript and WebView2 do not both await JS Promises.
  // A single unguessable, short-lived reply slot avoids installing any native
  // message channel that an unrelated page could invoke.
  static Future<Map> _runAsync(
    Uri page,
    String invocation,
    SchoolExecute run,
  ) async {
    final slot = jsonEncode(
      '__wgRead${List.generate(4, (_) => Random.secure().nextInt(1 << 30).toRadixString(36)).join()}',
    );
    final start =
        '''
      (() => {
        const k=$slot, href=location.href;
        Object.defineProperty(window,k,{configurable:true,writable:true,value:{pending:true}});
        setTimeout(()=>{ delete window[k]; }, 14000);
        $invocation
          .then(data=>{ if (Object.hasOwn(window,k)) window[k]=location.href===href?data:{error:'origin'}; })
          .catch(e=>{ if(Object.hasOwn(window,k)) window[k]={error:e?.message==='large'?'large':'shape'}; });
        return true;
      })()
    ''';
    await run(start);
    final poll =
        '''
      (()=>{const k=$slot; if(location.origin!==${jsonEncode(page.origin)} || !Object.hasOwn(window,k)) return JSON.stringify({error:'origin'});
        const data=window[k]; if(!data.pending) delete window[k]; return JSON.stringify(data);})()
    ''';
    final timer = Stopwatch()..start();
    while (timer.elapsed < const Duration(seconds: 12)) {
      final result = _map(await run(poll));
      if (result['pending'] != true) return result;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    throw const FormatException('学校没有及时返回课表，请稍后重试。');
  }

  static Map _map(Object? data) {
    for (var i = 0; i < 2 && data is String; i++) {
      if (data.length > 16 * 1024 * 1024) {
        throw const FormatException('课表过大，请选择单学期的本人课表。');
      }
      data = jsonDecode(data);
    }
    if (data is! Map) throw const FormatException('学校页面没有返回可识别的课表。');
    return data;
  }

  static String _failure(Object? reason) => switch (reason) {
    'origin' || 'login' => '请完成学校登录后再打开本人学期课表。',
    'termWeeks' => '当前清华课表没有明确的教学周范围。请切换到列明具体教学周的课表再读取。',
    'term' => '学校页面的学期与所选学期不一致。请在教务页面选择同一学期后再读取。',
    'classicTerm' => '当前课表没有显示可识别的学期。请在学期选择器里选中学期并打开本人课表。',
    'multiple' => '当前页同时显示多份课表，请单独打开要导入的学期课表。',
    'incomplete' => '学校没有返回完整课表，请在学校页面核对学期后重试。',
    'large' => '课表内容过大，请选择单学期的本人课表。',
    'endpoint' => '学校未返回当前学期的课表数据。请在学校页面重新查询后再读取。',
    'shape' => '已找到课表区域，但无法识别这版课表。请切换到学校的学期课表视图。',
    _ => '未找到可读取的课表。请先在教务页面显示本人整个学期的课表，再点读取。',
  };
}
