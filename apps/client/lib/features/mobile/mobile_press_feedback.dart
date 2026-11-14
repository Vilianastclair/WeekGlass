import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// A quiet touch response which never enters the gesture arena. Scrolling and
/// long-press dragging remain owned by the surrounding calendar recognizers.
class MobilePressFeedback extends StatefulWidget {
  const MobilePressFeedback({
    super.key,
    required this.child,
    this.enabled = true,
    this.scale = .975,
  });

  final Widget child;
  final bool enabled;
  final double scale;

  @override
  State<MobilePressFeedback> createState() => _MobilePressFeedbackState();
}

class _MobilePressFeedbackState extends State<MobilePressFeedback> {
  int? _pointer;
  Offset? _origin;
  bool _pressed = false;

  void _release() {
    _pointer = null;
    _origin = null;
    if (_pressed) setState(() => _pressed = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final reduced = MediaQuery.disableAnimationsOf(context);
    return Listener(
      onPointerDown: widget.enabled
          ? (event) {
              if (_pointer != null || event.kind == PointerDeviceKind.mouse) {
                return;
              }
              _pointer = event.pointer;
              _origin = event.position;
              setState(() => _pressed = true);
            }
          : null,
      onPointerMove: (event) {
        if (event.pointer == _pointer &&
            (event.position - _origin!).distance > kTouchSlop) {
          _release();
        }
      },
      onPointerUp: (event) {
        if (event.pointer == _pointer) _release();
      },
      onPointerCancel: (event) {
        if (event.pointer == _pointer) _release();
      },
      child: AnimatedScale(
        scale: _pressed && !reduced ? widget.scale : 1,
        duration: reduced
            ? Duration.zero
            : Duration(milliseconds: _pressed ? 80 : 150),
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}
