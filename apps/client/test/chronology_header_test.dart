import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:weekglass/main.dart';
import 'package:weekglass/features/planner/planner_controller.dart';
import 'package:weekglass/features/course_import/teaching_term.dart';

import 'whu_import_test.dart' show MemoryImportRepo;

void main() {
  for (final width in [390.0, 800.0]) {
    testWidgets(
      'glass date navigation works across year at width $width with enlarged text',
      (tester) async {
        SharedPreferencesAsyncPlatform.instance =
            InMemorySharedPreferencesAsync.empty();
        await initializeDateFormatting('zh_CN');
        tester.view.physicalSize = Size(width, 760);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final controller = PlannerController(
          repository: MemoryImportRepo(),
          timeZoneId: 'Asia/Shanghai',
        );
        await controller.initialize();
        controller.setAnchorDate(DateTime(2026, 12, 31));
        await controller.rememberTeachingTerm(
          TeachingTerm(
            year: 2026,
            semester: 3,
            firstMonday: DateTime(2026, 9, 7),
            weeks: 19,
          ),
        );
        await tester.pumpWidget(WeekGlassApp(controller: controller));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('teaching-week-label')),
          findsOneWidget,
        );
        expect(
          find.byTooltip('2026年12月28日 – 2027年1月3日 · 跳转到日期'),
          findsOneWidget,
        );
        final before = controller.anchorDate;
        await tester.tap(find.byTooltip('下一时段 · Ctrl+→'));
        await tester.pumpAndSettle();
        expect(controller.anchorDate.difference(before).inDays, 7);
        await tester.tap(find.byTooltip('上一时段 · Ctrl+←'));
        await tester.pumpAndSettle();
        expect(controller.anchorDate, before);
        await tester.tap(find.byKey(const ValueKey('date-jump')));
        await tester.pumpAndSettle();
        expect(find.byType(DatePickerDialog), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      },
    );
  }
}
