import 'dart:ui';

import 'package:flutter/material.dart';

import 'crystal_decoration.dart';
import 'weekglass_geometry.dart';
import 'weekglass_theme.dart';

/// Keep Material's accessible, responsive dialog layout while sharing the
/// calendar's optical surface. Blur is confined to the modal route's backdrop.
class GlassAlertDialog extends StatelessWidget {
  const GlassAlertDialog({
    super.key,
    this.title,
    this.content,
    this.actions,
    this.insetPadding = const EdgeInsets.symmetric(
      horizontal: 40,
      vertical: 24,
    ),
    this.titlePadding,
    this.contentPadding = const EdgeInsets.fromLTRB(24, 20, 24, 24),
    this.actionsPadding = const EdgeInsets.only(left: 8, right: 8, bottom: 8),
  });

  final Widget? title, content;
  final List<Widget>? actions;
  final EdgeInsets insetPadding, contentPadding, actionsPadding;
  final EdgeInsets? titlePadding;

  @override
  Widget build(BuildContext context) {
    final p = WeekGlassPalette.of(context);
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 7, sigmaY: 7),
      child: AlertDialog(
        backgroundColor: p.surface.withValues(alpha: p.isDark ? .88 : .82),
        surfaceTintColor: Colors.transparent,
        shadowColor: p.shadow.withValues(alpha: .3),
        elevation: 12,
        shape: _GlassDialogBorder(p.glassDecoration(elevated: true)),
        title: title,
        content: content,
        actions: actions,
        insetPadding: insetPadding,
        titlePadding: titlePadding,
        contentPadding: contentPadding,
        actionsPadding: actionsPadding,
      ),
    );
  }
}

class _GlassDialogBorder extends RoundedRectangleBorder {
  const _GlassDialogBorder(this.decoration)
    : super(borderRadius: WeekGlassGeometry.corners);
  final CrystalDecoration decoration;

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) => a is _GlassDialogBorder
      ? _GlassDialogBorder(
          CrystalDecoration.interpolate(a.decoration, decoration, t),
        )
      : super.lerpFrom(a, t);

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) => b is _GlassDialogBorder
      ? _GlassDialogBorder(
          CrystalDecoration.interpolate(decoration, b.decoration, t),
        )
      : super.lerpTo(b, t);

  @override
  bool operator ==(Object other) =>
      other is _GlassDialogBorder && other.decoration == decoration;

  @override
  int get hashCode => Object.hash(runtimeType, decoration);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    // Material paints its translucent fill in PhysicalShape. Its ShapeBorder
    // paints above the child, so restrict the optical treatment to the rim.
    final outer = borderRadius.resolve(textDirection).toRRect(rect);
    canvas.save();
    canvas.clipPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRRect(outer)
        ..addRRect(outer.deflate(3.5)),
    );
    final painter = decoration.createBoxPainter();
    painter.paint(
      canvas,
      rect.topLeft,
      ImageConfiguration(size: rect.size, textDirection: textDirection),
    );
    painter.dispose();
    canvas.restore();
  }
}
