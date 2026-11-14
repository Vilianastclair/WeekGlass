import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

/// The atmosphere is immutable between appearance/size changes. Blur it once
/// in its own retained layer, then paint the low-frequency moving reflection.
/// A calendar above this backdrop does not need to blur a changing full screen.
class MobileGlassBackdrop extends StatelessWidget {
  const MobileGlassBackdrop({super.key, required this.child});

  final Widget child;
  static final _atmosphereBlur = ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12);

  @override
  Widget build(BuildContext context) {
    final palette = WeekGlassPalette.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: RepaintBoundary(
            key: const ValueKey('mobile-static-atmosphere'),
            child: ImageFiltered(
              imageFilter: _atmosphereBlur,
              child: ColoredBox(
                color: palette.canvas,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    image: DecorationImage(
                      image: const AssetImage('assets/brand/atmosphere.png'),
                      fit: BoxFit.cover,
                      opacity: palette.atmosphereOpacity,
                      colorFilter: palette.atmosphereFilter,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        LiquidGlassSurface(
          background: true,
          colorKey: 'mist_blue',
          child: child,
        ),
      ],
    );
  }
}
