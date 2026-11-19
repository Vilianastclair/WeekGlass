import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

/// One optical surface behind the fixed command targets. The moving reflection
/// has its own repaint layer, so a finger does not rebuild the rail or calendar.
class MobileActionDock extends StatefulWidget {
  const MobileActionDock({super.key, required this.child});

  final Widget child;

  @override
  State<MobileActionDock> createState() => _MobileActionDockState();
}

class _MobileActionDockState extends State<MobileActionDock> {
  final _contact = ValueNotifier<Offset?>(null);

  @override
  void dispose() {
    _contact.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = WeekGlassPalette.of(context);
    final glass = LiquidGlassScope.settingsOf(context);
    final strength = glass.strength / LiquidGlass.maxStrength;
    final reflect = glass.motion && strength > 0;
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      gestures: {
        _DockDragGuard: GestureRecognizerFactoryWithHandlers<_DockDragGuard>(
          _DockDragGuard.new,
          (guard) {
            guard.contains = (position) =>
                (Offset.zero & context.size!).contains(position);
            guard.onContact = (position) => _contact.value = position;
          },
        ),
      },
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _DockMaterial(palette: palette, strength: strength),
              ),
            ),
          ),
          if (reflect)
            Positioned.fill(
              child: RepaintBoundary(
                child: CustomPaint(
                  key: const ValueKey('mobile-action-dock-glass'),
                  painter: _DockReflection(
                    palette: palette,
                    strength: strength,
                    contact: _contact,
                  ),
                ),
              ),
            ),
          Material(type: MaterialType.transparency, child: widget.child),
        ],
      ),
    );
  }
}

/// The dock's standard icon, caption and touch target, including Cloud.
class MobileDockButton extends StatelessWidget {
  const MobileDockButton({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
    this.primary = false,
  });

  final Widget icon;
  final String label, tooltip;
  final bool primary;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final p = WeekGlassPalette.of(context);
    final color = onPressed == null
        ? p.mutedSoft
        : primary
        ? p.accentStrong
        : p.text;
    final style = Theme.of(context).textTheme.labelSmall!.copyWith(
      fontSize: 10.5,
      height: 1.15,
      color: color,
      fontWeight: primary ? FontWeight.w600 : FontWeight.w500,
    );
    return Tooltip(
      message: tooltip,
      excludeFromSemantics: true,
      child: Semantics(
        label: tooltip,
        button: true,
        enabled: onPressed != null,
        child: InkWell(
          onTap: onPressed,
          borderRadius: const BorderRadius.all(Radius.circular(24)),
          child: ExcludeSemantics(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconTheme.merge(
                      data: IconThemeData(size: 21, color: color),
                      child: SizedBox.square(dimension: 21, child: icon),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Yields an ordinary tap to the original button. A scrub claims the arena
/// early without executing anything, leaving ink, semantics and keyboard
/// activation to the underlying Material controls.
class _DockDragGuard extends OneSequenceGestureRecognizer {
  _DockDragGuard() : super(allowedButtonsFilter: _primaryButton) {
    GestureBinding.instance.pointerRouter.addGlobalRoute(_observePointers);
  }

  static bool _primaryButton(int buttons) => buttons == kPrimaryButton;
  static const _dragSlop = 8.0;

  late bool Function(Offset) contains;
  late ValueChanged<Offset?> onContact;
  final _downPointers = <int>{};
  int? _finger;
  Offset? _origin;

  @override
  String get debugDescription => 'dock drag';

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    if (_downPointers.isNotEmpty) {
      resolvePointer(event.pointer, GestureDisposition.accepted);
      return;
    }
    _finger = event.pointer;
    _origin = event.localPosition;
    if (event.kind != PointerDeviceKind.mouse) onContact(_origin);
  }

  @override
  void handleNonAllowedPointer(PointerDownEvent event) {}

  void _observePointers(PointerEvent event) {
    if (event is PointerDownEvent) {
      _downPointers.add(event.pointer);
      final finger = _finger;
      if (finger != null && finger != event.pointer) {
        resolvePointer(finger, GestureDisposition.accepted);
        _clear();
      }
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _downPointers.remove(event.pointer);
    }
  }

  void _clear() {
    _finger = null;
    _origin = null;
    onContact(null);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer == _finger) {
      final position = event.localPosition;
      if (event is PointerMoveEvent) {
        if (!contains(position)) {
          resolvePointer(event.pointer, GestureDisposition.accepted);
          _clear();
        } else {
          if ((position - _origin!).distanceSquared > _dragSlop * _dragSlop) {
            resolvePointer(event.pointer, GestureDisposition.accepted);
          }
          if (event.kind != PointerDeviceKind.mouse) onContact(position);
        }
      } else if (event is PointerUpEvent || event is PointerCancelEvent) {
        resolvePointer(
          event.pointer,
          event is PointerUpEvent && contains(position)
              ? GestureDisposition.rejected
              : GestureDisposition.accepted,
        );
        _clear();
      }
    }
    stopTrackingIfPointerNoLongerDown(event);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_observePointers);
    super.dispose();
  }
}

RRect _capsule(Size size, [double inset = .65]) => RRect.fromRectAndRadius(
  (Offset.zero & size).deflate(inset),
  Radius.circular(size.height / 2),
);

class _DockMaterial extends CustomPainter {
  const _DockMaterial({required this.palette, required this.strength});

  final WeekGlassPalette palette;
  final double strength;

  @override
  void paint(Canvas canvas, Size size) {
    final dark = palette.isDark;
    final rail = _capsule(size);
    final rect = rail.outerRect;
    final paint = Paint();

    Color mix(Color a, Color b, double t) => Color.lerp(a, b, t)!;
    ui.Shader vertical(List<Color> colors, [List<double>? stops]) =>
        ui.Gradient.linear(rect.topCenter, rect.bottomCenter, colors, stops);

    canvas.drawShadow(
      Path()..addRRect(rail),
      palette.shadow.withValues(alpha: dark ? .57 : .36),
      5,
      true,
    );
    final base = dark
        ? mix(palette.canvas, palette.glassMiddle, .68)
        : mix(palette.canvas, Colors.white, .48);
    canvas.drawRRect(
      rail,
      paint
        ..shader = vertical(
          [
            mix(
              base,
              palette.reflection,
              dark ? .07 + strength * .15 : .56,
            ).withValues(alpha: .93 - strength * .24),
            base.withValues(alpha: .93 - strength * .40),
            mix(
              base,
              dark ? palette.glassBottom : palette.accentSoft,
              .53,
            ).withValues(alpha: .96 - strength * .22),
          ],
          const [0, .46, 1],
        ),
    );
    canvas.drawRRect(
      rail,
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..shader = vertical([
          mix(
            palette.lineStrong,
            palette.reflection,
            .42 + strength * .44,
          ).withValues(alpha: dark ? .83 : 1),
          palette.lineStrong.withValues(alpha: dark ? .64 : .78),
        ]),
    );
    if (strength > 0) {
      canvas.drawRRect(
        _capsule(size, 2.1),
        paint
          ..strokeWidth = .8
          ..shader = vertical(
            [
              Colors.white.withValues(alpha: strength * (dark ? .23 : .93)),
              Colors.white.withValues(alpha: 0),
              palette.reflection.withValues(
                alpha: strength * (dark ? .10 : .35),
              ),
            ],
            const [0, .62, 1],
          ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DockMaterial oldDelegate) =>
      palette != oldDelegate.palette || strength != oldDelegate.strength;
}

class _DockReflection extends CustomPainter {
  _DockReflection({
    required this.palette,
    required this.strength,
    required this.contact,
  }) : super(repaint: contact);

  final WeekGlassPalette palette;
  final double strength;
  final ValueListenable<Offset?> contact;

  @override
  void paint(Canvas canvas, Size size) {
    final finger = contact.value;
    if (finger == null) return;
    final dark = palette.isDark;
    final rail = _capsule(size, 1.1);
    final paint = Paint();

    canvas.drawRRect(
      rail,
      paint
        ..shader = ui.Gradient.radial(
          finger,
          size.height * 1.25,
          [
            palette.reflection.withValues(alpha: strength * (dark ? .27 : .87)),
            palette.accent.withValues(alpha: strength * (dark ? .16 : .14)),
            palette.accent.withValues(alpha: 0),
          ],
          const [0, .53, 1],
        ),
    );
    // The bright rim is strongest on the edge closest to the contact.
    canvas.drawRRect(
      rail,
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..shader = ui.Gradient.radial(
          finger,
          size.height * 1.14,
          [
            Colors.white.withValues(alpha: strength * .97),
            palette.reflection.withValues(alpha: strength * (dark ? .61 : .86)),
            palette.accent.withValues(alpha: 0),
          ],
          const [0, .45, 1],
        ),
    );
  }

  @override
  bool shouldRepaint(covariant _DockReflection oldDelegate) =>
      palette != oldDelegate.palette || strength != oldDelegate.strength;
}
