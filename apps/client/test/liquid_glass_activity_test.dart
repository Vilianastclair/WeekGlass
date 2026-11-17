import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

const _frame = Duration(microseconds: 16667);
const _surfaceKeys = [ValueKey('material-a'), ValueKey('material-b')];

Widget _host({
  required List<GlobalKey> captures,
  required List<bool> active,
  VoidCallback? onContentBuild,
  VoidCallback? onTap,
  bool mobile = false,
}) => MaterialApp(
  theme: ThemeData.light(),
  home: LiquidGlassScope(
    mobile: mobile,
    child: Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < captures.length; i++)
            RepaintBoundary(
              key: captures[i],
              child: ColoredBox(
                color: const Color(0xffdce5f4),
                child: SizedBox(
                  width: 220,
                  height: 160,
                  child: LiquidGlassSurface.event(
                    key: _surfaceKeys[i],
                    active: active[i],
                    colorKey: 'mist_blue',
                    child: Builder(
                      builder: (_) {
                        onContentBuild?.call();
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: onTap,
                          child: const SizedBox.expand(),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  ),
);

RenderRepaintBoundary _opticalBoundary(WidgetTester tester, int index) =>
    tester.renderObject<RenderRepaintBoundary>(
      find.descendant(
        of: find.byKey(_surfaceKeys[index]),
        matching: find.byType(RepaintBoundary),
      ),
    );

Future<List<int>> _pixels(WidgetTester tester, GlobalKey key) async =>
    (await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return bytes!.buffer.asUint8List();
    }))!;

Future<void> _advance(WidgetTester tester, int frames) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(_frame);
  }
}

void main() {
  testWidgets(
    'inactive material stops painting, keeps content, and rejoins shared phase',
    (tester) async {
      await tester.runAsync(LiquidGlass.load);
      final captures = [GlobalKey(), GlobalKey()];
      final active = [true, true];
      var contentBuilds = 0;
      var taps = 0;
      Widget host() => _host(
        captures: captures,
        active: active,
        onContentBuild: () => contentBuilds++,
        onTap: () => taps++,
      );
      await tester.pumpWidget(host());
      await tester.pump();
      final bounds = tester.getRect(find.byKey(captures.first));
      expect(
        await _pixels(tester, captures.first),
        orderedEquals(await _pixels(tester, captures.last)),
      );

      active[0] = false;
      await tester.pumpWidget(host());
      await tester.pump();
      final frozen = await _pixels(tester, captures.first);
      final moving = await _pixels(tester, captures.last);
      final firstBoundary = _opticalBoundary(tester, 0);
      final lastBoundary = _opticalBoundary(tester, 1);
      firstBoundary.debugResetMetrics();
      lastBoundary.debugResetMetrics();
      final buildsBeforeFrames = contentBuilds;
      await _advance(tester, 120);
      expect(firstBoundary.debugAsymmetricPaintCount, 0);
      expect(firstBoundary.debugSymmetricPaintCount, 0);
      expect(lastBoundary.debugAsymmetricPaintCount, greaterThan(0));
      expect(contentBuilds, buildsBeforeFrames);
      expect(await _pixels(tester, captures.first), orderedEquals(frozen));
      expect(
        await _pixels(tester, captures.last),
        isNot(orderedEquals(moving)),
        reason: 'Another visible surface must keep the shared lake moving.',
      );

      // Even unrelated repaint work must not advance a frozen surface's phase.
      firstBoundary.markNeedsPaint();
      await tester.pump(_frame);
      expect(await _pixels(tester, captures.first), orderedEquals(frozen));
      await tester.tap(find.byKey(captures.first));
      expect(
        taps,
        1,
        reason: 'Visibility controls optics, not child gestures.',
      );

      active[0] = true;
      await tester.pumpWidget(host());
      await tester.pump();
      expect(
        await _pixels(tester, captures.first),
        orderedEquals(await _pixels(tester, captures.last)),
        reason: 'Reactivation must use the current shared phase.',
      );
      expect(tester.getRect(find.byKey(captures.first)), bounds);

      active[0] = active[1] = false;
      await tester.pumpWidget(host());
      await tester.pump();
      final allFrozen = await _pixels(tester, captures.first);
      await _advance(tester, 30);
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(await _pixels(tester, captures.first), orderedEquals(allFrozen));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final mobile in [false, true]) {
    testWidgets(
      '${mobile ? 'Phone' : 'Desktop'} touch wake returns to the lake field',
      (tester) async {
        await tester.runAsync(LiquidGlass.load);
        final captures = [GlobalKey(), GlobalKey()];
        await tester.pumpWidget(
          _host(captures: captures, active: [true, true], mobile: mobile),
        );
        await tester.pump();
        final bounds = tester.getRect(find.byKey(captures.first));
        final finger = await tester.startGesture(
          bounds.topLeft + const Offset(35, 45),
        );
        await finger.moveTo(bounds.center + const Offset(30, 20));
        await _advance(tester, 24);
        expect(
          await _pixels(tester, captures.first),
          isNot(orderedEquals(await _pixels(tester, captures.last))),
          reason: 'The fast path must preserve an active touch response.',
        );
        await finger.cancel();
        await _advance(tester, 240);
        expect(
          await _pixels(tester, captures.first),
          orderedEquals(await _pixels(tester, captures.last)),
          reason:
              'Expired ripple and negligible hover must leave no idle tail.',
        );
        expect(tester.getRect(find.byKey(captures.first)), bounds);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
