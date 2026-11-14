import 'weekglass_geometry.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Paints elevation outside translucent glass, never underneath its content.
class GlassShadow extends StatelessWidget {
  const GlassShadow({
    super.key,
    required this.child,
    required this.shadows,
    this.radius = WeekGlassGeometry.radius,
  });

  final Widget child;
  final List<BoxShadow> shadows;
  final double radius;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _GlassShadowPainter(radius, shadows), child: child);
}

class _GlassShadowPainter extends CustomPainter {
  const _GlassShadowPainter(this.radius, this.shadows);
  final double radius;
  final List<BoxShadow> shadows;

  @override
  void paint(Canvas canvas, Size size) {
    final outline = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    canvas.save();
    final extent = shadows.fold<double>(
      0,
      (value, shadow) => math.max(
        value,
        shadow.blurRadius * 3 +
            shadow.spreadRadius.abs() +
            shadow.offset.distance,
      ),
    );
    canvas.clipPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect((Offset.zero & size).inflate(extent))
        ..addRRect(outline),
    );
    for (final shadow in shadows) {
      canvas.drawRRect(
        outline.shift(shadow.offset).inflate(shadow.spreadRadius),
        shadow.toPaint(),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlassShadowPainter oldDelegate) =>
      oldDelegate.radius != radius || oldDelegate.shadows != shadows;
}
