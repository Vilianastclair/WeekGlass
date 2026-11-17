import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weekglass/features/cloud/cloud_service_button.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

void main() {
  testWidgets('cloud reflection stays local and pauses when not visible', (
    tester,
  ) async {
    await tester.runAsync(LiquidGlass.load);
    final navigator = GlobalKey<NavigatorState>();
    final capture = GlobalKey();
    final nearby = GlobalKey();
    final reduced = ValueNotifier(false);
    final ticking = ValueNotifier(true);
    addTearDown(reduced.dispose);
    addTearDown(ticking.dispose);
    var builds = 0;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        builder: (context, child) => LiquidGlassScope(child: child!),
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ValueListenableBuilder(
                  valueListenable: ticking,
                  builder: (context, enabled, child) =>
                      TickerMode(enabled: enabled, child: child!),
                  child: ValueListenableBuilder(
                    valueListenable: reduced,
                    builder: (context, disable, child) => MediaQuery(
                      data: MediaQuery.of(context)
                          .copyWith(disableAnimations: disable),
                      child: child!,
                    ),
                    child: RepaintBoundary(
                      key: capture,
                      child: SizedBox(
                        width: 300,
                        child: CloudServiceButton.entry(
                          detail: '连接官方云或自己的服务器',
                          onPressed: () {},
                        ),
                      ),
                    ),
                  ),
                ),
                RepaintBoundary(
                  key: nearby,
                  child: Builder(
                    builder: (_) {
                      builds++;
                      return const Text('相邻日历内容');
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    Future<List<int>> pixels() async => (await tester.runAsync(() async {
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return bytes!.buffer.asUint8List();
    }))!;
    Future<void> advance() async {
      for (var i = 0; i < 32; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    final bounds = tester.getRect(find.byKey(capture));
    final original = await pixels();
    final nearbyRender = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(nearby),
    )..debugResetMetrics();
    final initialBuilds = builds;
    await advance();
    expect(await pixels(), isNot(orderedEquals(original)));
    expect(tester.getRect(find.byKey(capture)), bounds);
    expect(builds, initialBuilds);
    expect(nearbyRender.debugSymmetricPaintCount, 0);
    expect(nearbyRender.debugAsymmetricPaintCount, 0);

    reduced.value = true;
    await tester.pump();
    final reducedPixels = await pixels();
    await advance();
    expect(await pixels(), orderedEquals(reducedPixels));
    expect(tester.binding.hasScheduledFrame, isFalse);

    reduced.value = false;
    await tester.pump();
    await advance();
    expect(await pixels(), isNot(orderedEquals(reducedPixels)));
    ticking.value = false;
    await tester.pump();
    final mutedPixels = await pixels();
    await advance();
    expect(await pixels(), orderedEquals(mutedPixels));
    expect(tester.binding.hasScheduledFrame, isFalse);

    ticking.value = true;
    await tester.pump();
    await advance();
    expect(await pixels(), isNot(orderedEquals(mutedPixels)));
    showDialog<void>(
      context: navigator.currentContext!,
      builder: (_) => const AlertDialog(title: Text('前台弹窗')),
    );
    await tester.pumpAndSettle();
    final coveredPixels = await pixels();
    await advance();
    expect(await pixels(), orderedEquals(coveredPixels));
    expect(tester.binding.hasScheduledFrame, isFalse);
    navigator.currentState!.pop();
    await advance();
    expect(await pixels(), isNot(orderedEquals(coveredPixels)));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
