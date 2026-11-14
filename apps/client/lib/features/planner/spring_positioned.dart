import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

/// A transient placement hint that keeps its velocity when the snap target
/// changes. Its animated geometry never determines the event's saved time.
class SpringPositioned extends StatefulWidget {
  const SpringPositioned({super.key, required this.rect, required this.child});

  final Rect rect;
  final Widget child;

  @override
  State<SpringPositioned> createState() => _SpringPositionedState();
}

class _SpringPositionedState extends State<SpringPositioned>
    with TickerProviderStateMixin {
  static final _spring = SpringDescription.withDurationAndBounce(
    duration: const Duration(milliseconds: 260),
    bounce: .12,
  );
  late final List<AnimationController> _axes;
  late final Listenable _motion;
  bool _reduceMotion = false;

  List<double> _coordinates(Rect rect) => [
    rect.left,
    rect.top,
    rect.width,
    rect.height,
  ];

  @override
  void initState() {
    super.initState();
    _axes = [
      for (final value in _coordinates(widget.rect))
        AnimationController.unbounded(value: value, vsync: this),
    ];
    _motion = Listenable.merge(_axes);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion != reduceMotion) {
      _reduceMotion = reduceMotion;
      if (reduceMotion) _retarget(immediate: true);
    }
  }

  @override
  void didUpdateWidget(SpringPositioned oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rect == widget.rect) return;
    _retarget(immediate: _reduceMotion, previous: oldWidget.rect);
  }

  void _retarget({required bool immediate, Rect? previous}) {
    final targets = _coordinates(widget.rect);
    final previousTargets = previous == null ? null : _coordinates(previous);
    for (var i = 0; i < _axes.length; i++) {
      final axis = _axes[i];
      if (immediate) {
        axis.value = targets[i];
      } else if (previousTargets == null || targets[i] != previousTargets[i]) {
        axis.animateWith(
          SpringSimulation(
            _spring,
            axis.value,
            targets[i],
            axis.velocity,
            tolerance: const Tolerance(distance: .05, velocity: .1),
            snapToEnd: true,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    for (final axis in _axes) {
      axis.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _motion,
    child: widget.child,
    builder: (context, child) => Positioned.fromRect(
      rect: Rect.fromLTWH(
        _axes[0].value,
        _axes[1].value,
        math.max(2, _axes[2].value),
        math.max(2, _axes[3].value),
      ),
      child: child!,
    ),
  );
}
