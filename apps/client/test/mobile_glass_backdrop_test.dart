import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weekglass/features/mobile/mobile_glass_backdrop.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

void main() {
  testWidgets(
    'mobile atmosphere stays retained while its lake reflection moves',
    (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(LiquidGlass.load);
      await tester.pumpWidget(
        MaterialApp(
          theme: WeekGlassTheme.light(),
          home: const LiquidGlassScope(
            mobile: true,
            child: MobileGlassBackdrop(child: SizedBox.expand()),
          ),
        ),
      );
      await tester.runAsync(() async {
        await precacheImage(
          const AssetImage('assets/brand/atmosphere.png'),
          tester.element(find.byType(MobileGlassBackdrop)),
        );
      });
      await tester.pump();
      final atmosphere = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('mobile-static-atmosphere')),
      );
      final reflection = tester.renderObject<RenderRepaintBoundary>(
        find.descendant(
          of: find.byType(LiquidGlassSurface),
          matching: find.byType(RepaintBoundary),
        ),
      );
      atmosphere.debugResetMetrics();
      reflection.debugResetMetrics();
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(microseconds: 16667));
      }
      expect(atmosphere.debugAsymmetricPaintCount, 0);
      expect(atmosphere.debugSymmetricPaintCount, 0);
      expect(reflection.debugAsymmetricPaintCount, greaterThan(0));
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.byType(ImageFiltered), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
