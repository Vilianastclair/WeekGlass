// Standalone native smoke target. Does not initialize the WeekGlass database,
// a WebView, accounts or update services. Run only on a test installation.
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:weekglass/features/course_import/wakeup_engine.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String message;
  try {
    final adapters = await WakeUpEngine.list();
    if (!adapters.any((a) => a['id'] == 'ccibe')) throw StateError('registry');
    // JSON bean fields retain their original school API names after R8.
    // A payload over Binder's limit also exercises the descriptor transport.
    final source = jsonEncode([
      {
        'kcmc': '示例物理',
        'xqj': '三',
        'jc': '3-4',
        'qsz': 1,
        'jsz': 5,
        'jsxm': '示例教师',
        'jxdd': '测试楼',
        'padding': ' ' * (1100 * 1024),
      },
    ]);
    final table = await WakeUpEngine.parse(adapter: 'ccibe', source: source);
    final m = table.meetings.single;
    if (m.title != '示例物理' ||
        m.weekday != 3 ||
        m.room != '测试楼' ||
        m.teacher != '示例教师' ||
        m.periods.join(',') != '3,4' ||
        m.weeks.join(',') != '1,3,5') {
      throw StateError('course fields');
    }
    try {
      await WakeUpEngine.parse(adapter: 'not_registered', source: '<table/>');
      throw StateError('unexpected parser');
    } on WakeUpEngineException catch (e) {
      if (e.code != 'UNKNOWN_ADAPTER') rethrow;
    }
    message =
        'COURSE_ADAPTER_OK registry=${adapters.length} bytes=${utf8.encode(source).length}';
  } catch (e) {
    message = 'COURSE_ADAPTER_FAILED ${e.runtimeType}: $e';
  }
  debugPrint(message);
  runApp(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: Text(message)),
    ),
  );
}
