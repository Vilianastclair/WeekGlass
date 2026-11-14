import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:weekglass/main.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass/features/planner/sidebar_action.dart';

import 'whu_import_test.dart' show MemoryImportRepo;

void main() {
  testWidgets(
    'all shortcuts can be hidden but settings stays reachable after restart',
    (tester) async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      await initializeDateFormatting('zh_CN');
      final first = PlannerController(
        repository: MemoryImportRepo(),
        timeZoneId: 'Asia/Shanghai',
      );
      await first.initialize();
      await first.saveSidebarActions({
        SidebarAction.appearance,
        SidebarAction.exportEvents,
      });
      final restored = PlannerController(
        repository: MemoryImportRepo(),
        timeZoneId: 'Asia/Shanghai',
      );
      await restored.initialize();
      expect(restored.sidebarActions, {
        SidebarAction.appearance,
        SidebarAction.exportEvents,
      });
      await tester.pumpWidget(WeekGlassApp(controller: restored));
      await tester.pumpAndSettle();
      expect(find.byTooltip('皮肤与外观'), findsOneWidget);
      expect(find.byTooltip('导出日程'), findsOneWidget);
      await restored.saveSidebarActions({});
      await tester.pumpAndSettle();
      expect(find.byTooltip('皮肤与外观'), findsNothing);
      expect(find.byTooltip('设置 · 睡眠与外观'), findsOneWidget);
      await tester.tap(find.byTooltip('设置 · 睡眠与外观'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('sidebar-customization')),
      );
      await tester.tap(find.text('侧边栏'));
      await tester.pumpAndSettle();
      final appearance = find.byKey(const ValueKey('sidebar-appearance'));
      await tester.ensureVisible(appearance);
      await tester.tap(appearance);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(restored.sidebarActions, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      first.dispose();
      restored.dispose();
    },
  );
}
