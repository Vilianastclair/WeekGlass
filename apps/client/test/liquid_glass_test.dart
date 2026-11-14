import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

void main() {
  testWidgets('water responds to pointer and touch without swallowing taps', (
    tester,
  ) async {
    await tester.runAsync(LiquidGlass.load);
    final keys = [GlobalKey(), GlobalKey()];
    var taps = 0;
    var reduced = false;
    Widget host() => MaterialApp(
      home: Material(
        child: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: LiquidGlassScope(
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final key in keys)
                    RepaintBoundary(
                      key: key,
                      child: ColoredBox(
                        color: const Color(0xffdce5f4),
                        child: SizedBox(
                          width: 240,
                          height: 200,
                          child: LiquidGlassSurface(
                            colorKey: 'mist_blue',
                            background: true,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => taps++,
                              child: const Center(child: Text('稳定内容')),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    Future<Uint8List> pixels(GlobalKey key) async => (await tester.runAsync(
      () async {
        final render =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await render.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        image.dispose();
        return data!.buffer.asUint8List();
      },
    ))!;
    await tester.pumpWidget(host());
    await tester.pump();
    final bounds = tester.getRect(find.byKey(keys.first));
    expect(await pixels(keys.first), orderedEquals(await pixels(keys.last)));
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(bounds.center);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 34));
    }
    expect(
      await pixels(keys.first),
      isNot(orderedEquals(await pixels(keys.last))),
      reason: 'Only the hovered surface should refract its reflection.',
    );
    await mouse.down(bounds.center);
    await mouse.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(taps, 1);
    expect(tester.getRect(find.byKey(keys.first)), bounds);
    reduced = true;
    await tester.pumpWidget(host());
    await tester.pump(const Duration(seconds: 1));
    expect(await pixels(keys.first), orderedEquals(await pixels(keys.last)));
    expect(tester.binding.hasScheduledFrame, isFalse);
    await mouse.removePointer();
    reduced = false;
    await tester.pumpWidget(host());
    final finger = await tester.startGesture(
      bounds.topLeft + const Offset(30, 40),
    );
    await finger.moveTo(bounds.center);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      await pixels(keys.first),
      isNot(orderedEquals(await pixels(keys.last))),
      reason: 'Touch creates a wake even when no mouse hover is available.',
    );
    expect(tester.getRect(find.byKey(keys.first)), bounds);
    await finger.cancel();
    expect(taps, 1, reason: 'A cancelled touch must not activate the content.');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'flow changes only pixels; pause, reduced motion and hidden window freeze it',
    (tester) async {
      await tester.runAsync(LiquidGlass.load);
      final key = GlobalKey();
      const contentKey = ValueKey('stable-content');
      var motion = true;
      var reduced = false;
      var strength = .72;
      Widget host() => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: LiquidGlassScope(
            motion: motion,
            strength: strength,
            child: Center(
              child: RepaintBoundary(
                key: key,
                child: ColoredBox(
                  color: const Color(0xffdce5f4),
                  child: SizedBox(
                    width: 158,
                    height: 80,
                    child: LiquidGlassSurface(
                      colorKey: 'mist_blue',
                      child: const Center(child: Text('专注工作', key: contentKey)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      Future<Uint8List> pixels() async => (await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        image.dispose();
        return bytes!.buffer.asUint8List();
      }))!;
      Future<void> advance() async {
        for (var i = 0; i < 120; i++) {
          await tester.pump(const Duration(milliseconds: 17));
        }
      }

      await tester.pumpWidget(host());
      await tester.pump();
      final bounds = tester.getRect(find.byKey(contentKey));
      final first = await pixels();
      await advance();
      expect(
        await pixels(),
        isNot(orderedEquals(first)),
        reason: 'The compiled shader must actually animate.',
      );
      expect(tester.getRect(find.byKey(contentKey)), bounds);

      motion = false;
      await tester.pumpWidget(host());
      final paused = await pixels();
      await advance();
      expect(await pixels(), orderedEquals(paused));
      expect(tester.binding.hasScheduledFrame, isFalse);

      motion = true;
      reduced = true;
      await tester.pumpWidget(host());
      final still = await pixels();
      await advance();
      expect(await pixels(), orderedEquals(still));
      expect(tester.binding.hasScheduledFrame, isFalse);

      reduced = false;
      await tester.pumpWidget(host());
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      final hidden = await pixels();
      await advance();
      expect(await pixels(), orderedEquals(hidden));
      expect(tester.binding.hasScheduledFrame, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await advance();
      expect(await pixels(), isNot(orderedEquals(hidden)));

      strength = 0;
      await tester.pumpWidget(host());
      final clear = await pixels();
      await advance();
      expect(await pixels(), orderedEquals(clear));
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.getRect(find.byKey(contentKey)), bounds);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
