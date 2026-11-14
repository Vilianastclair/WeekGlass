import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weekglass/features/planner/timed_notice.dart';

void main() {
  for (final seconds in [3, 5]) {
    testWidgets(
      'notice line shrinks and expires at $seconds seconds even with accessible navigation',
      (tester) async {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(accessibleNavigation: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showTimedNotice(
                    context,
                    message: '已完成',
                    actionLabel: '继续',
                    duration: Duration(seconds: seconds),
                    onAction: () {},
                  ),
                  child: const Text('显示'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('显示'));
        await tester.pump();
        final bar = find.byKey(const ValueKey('notice-progress'));
        final width = tester.getSize(bar).width;
        expect(width, greaterThan(250));
        await tester.pump(Duration(milliseconds: seconds * 500));
        expect(tester.getSize(bar).width, closeTo(width / 2, 1));
        expect(find.text('继续'), findsOneWidget);
        await tester.pump(Duration(milliseconds: seconds * 500 + 10));
        await tester.pumpAndSettle();
        expect(find.text('继续'), findsNothing);
      },
    );
  }
  testWidgets('action runs once and removes the notice before deadline', (
    tester,
  ) async {
    var count = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showTimedNotice(
                context,
                message: '已复制',
                actionLabel: '再复制',
                duration: const Duration(seconds: 3),
                onAction: () {
                  count++;
                },
              ),
              child: const Text('显示'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('显示'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('再复制'));
    await tester.pumpAndSettle();
    expect(count, 1);
    expect(find.text('再复制'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });
}
