import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'weekglass_geometry.dart';

enum GlassLayer { panel, control, card, overlay }

/// A translucent body with a rounded optical rim. Decoration only: no padding,
/// hit regions, transforms or timers are introduced into calendar geometry.
class CrystalDecoration extends BoxDecoration {
  CrystalDecoration({
    required this.dark,
    required this.tint,
    required this.ink,
    this.layer = GlassLayer.panel,
    this.radius = WeekGlassGeometry.radius,
    this.activity = 0,
    this.light = const Offset(.18, .08),
  }) : super(
         borderRadius: BorderRadius.circular(radius),
         gradient: _body(dark, tint, layer, activity),
       );

  final bool dark;
  final Color tint, ink;
  final GlassLayer layer;
  final double radius, activity;
  final Offset light;

  static LinearGradient _body(
    bool dark,
    Color tint,
    GlassLayer layer,
    double activity,
  ) {
    final overlay = layer == GlassLayer.overlay;
    final card = layer == GlassLayer.card;
    if (layer == GlassLayer.panel) {
      // A continuous top-lit body stays convex at every aspect ratio. The
      // previous diagonal bright-dark-bright ramp read as an inset at the
      // middle of a tall rail and the upper-right of a wide calendar.
      return LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        stops: const [0, .42, 1],
        colors: dark
            ? [
                Color.lerp(tint, Colors.white, .13)!.withValues(alpha: .20),
                tint.withValues(alpha: .14),
                tint.withValues(alpha: .10),
              ]
            : [
                Colors.white.withValues(alpha: .42),
                Color.lerp(tint, Colors.white, .35)!.withValues(alpha: .20),
                tint.withValues(alpha: .12),
              ],
      );
    }
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      stops: const [0, .28, .68, 1],
      colors: dark
          ? [
              Color.lerp(tint, Colors.white, .16)!.withValues(
                alpha: overlay
                    ? .86
                    : card
                    ? .38
                    : .18,
              ),
              tint.withValues(
                alpha: overlay
                    ? .88
                    : card
                    ? .30
                    : .12,
              ),
              tint.withValues(
                alpha: overlay
                    ? .90
                    : card
                    ? .25
                    : .08,
              ),
              Color.lerp(tint, Colors.white, .10)!.withValues(
                alpha: overlay
                    ? .88
                    : card
                    ? .38
                    : .16,
              ),
            ]
          : [
              Colors.white.withValues(
                alpha: overlay ? .90 : .38 + activity * .08,
              ),
              tint.withValues(
                alpha: overlay
                    ? .82
                    : card
                    ? .24
                    : .10,
              ),
              tint.withValues(
                alpha: overlay
                    ? .78
                    : card
                    ? .16
                    : .06,
              ),
              Colors.white.withValues(
                alpha: overlay ? .88 : .24 + activity * .05,
              ),
            ],
    );
  }

  @override
  EdgeInsetsGeometry get padding => EdgeInsets.zero;

  @override
  bool get isComplex => true;

  static CrystalDecoration interpolate(
    CrystalDecoration a,
    CrystalDecoration b,
    double t,
  ) => CrystalDecoration(
    dark: t < .5 ? a.dark : b.dark,
    tint: Color.lerp(a.tint, b.tint, t)!,
    ink: Color.lerp(a.ink, b.ink, t)!,
    layer: t < .5 ? a.layer : b.layer,
    radius: ui.lerpDouble(a.radius, b.radius, t)!,
    activity: ui.lerpDouble(a.activity, b.activity, t)!,
    light: Offset.lerp(a.light, b.light, t)!,
  );

  @override
  BoxDecoration? lerpFrom(Decoration? a, double t) =>
      a is CrystalDecoration ? interpolate(a, this, t) : super.lerpFrom(a, t);

  @override
  BoxDecoration? lerpTo(Decoration? b, double t) =>
      b is CrystalDecoration ? interpolate(this, b, t) : super.lerpTo(b, t);

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _CrystalPainter(this, onChanged);

  @override
  bool operator ==(Object other) =>
      other is CrystalDecoration &&
      other.dark == dark &&
      other.tint == tint &&
      other.ink == ink &&
      other.layer == layer &&
      other.radius == radius &&
      other.activity == activity &&
      other.light == light;

  @override
  int get hashCode =>
      Object.hash(dark, tint, ink, layer, radius, activity, light);
}

class _CrystalPainter extends BoxPainter {
  _CrystalPainter(this.surface, super.onChanged);
  final CrystalDecoration surface;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size!;
    if (size.isEmpty) return;
    final rect = offset & size;
    final radius = math.min(surface.radius, size.shortestSide / 2);
    final shape = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    final dark = surface.dark;
    final compact = size.height < 26;
    final panel = surface.layer == GlassLayer.panel;
    final white = Colors.white;
    canvas.save();
    canvas.clipRRect(shape);
    canvas.drawRRect(
      shape,
      Paint()..shader = surface.gradient!.createShader(rect),
    );

    // Broad, quiet reflection, concentrated near the light rather than a white
    // layer over the whole surface. The rim is what carries most of the gloss.
    final focus = Offset(
      rect.left + rect.width * surface.light.dx,
      rect.top + rect.height * surface.light.dy,
    );
    final reflectionRadius = math.max(size.width * .85, size.height * 1.5);
    canvas.drawRRect(
      shape,
      Paint()
        ..shader = panel
            ? LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  white.withValues(alpha: dark ? .045 : .10),
                  white.withValues(alpha: 0),
                ],
                stops: const [0, .48],
              ).createShader(rect)
            : ui.Gradient.radial(
                focus - Offset(0, size.height * .4),
                reflectionRadius,
                [
                  white.withValues(
                    alpha: (dark ? .07 : .16) + surface.activity * .09,
                  ),
                  white.withValues(alpha: dark ? .018 : .035),
                  white.withValues(alpha: 0),
                ],
                const [0, .52, 1],
              ),
    );

    if (surface.layer == GlassLayer.card ||
        surface.layer == GlassLayer.control) {
      // Small surfaces need one stable silhouette. Multiple offset bright/dark
      // rims make their straight edges appear bent, especially at 1x density.
      canvas.drawRRect(
        shape.deflate(.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = white.withValues(alpha: dark ? .32 : .72),
      );
      canvas.restore();
      return;
    }

    // One unbroken luminous edge. A dark inner rim or a second bright lower
    // rim reverses the perceived depth into a well; depth belongs outside the
    // glass (GlassShadow), not in a dark notch around its content.
    canvas.drawRRect(
      shape.deflate(.55),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            white.withValues(alpha: dark ? .48 : .92),
            white.withValues(alpha: dark ? .28 : .62),
            white.withValues(alpha: dark ? .18 : .40),
          ],
          stops: const [0, .46, 1],
        ).createShader(rect),
    );
    if (!compact) {
      canvas.drawRRect(
        shape.deflate(1.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = .65
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              white.withValues(alpha: dark ? .10 : .22),
              white.withValues(alpha: 0),
            ],
            stops: const [0, .38],
          ).createShader(rect),
      );
    }
    canvas.restore();
  }
}
