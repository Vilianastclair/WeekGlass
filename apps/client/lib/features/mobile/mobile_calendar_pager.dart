import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

import '../planner/calendar_grid.dart';
import '../planner/planner_controller.dart';
import 'mobile_time_zoom.dart';

/// The live calendar follows the finger. Its adjacent dates are inert previews;
/// only a completed release changes the controller's date. Vertical scroll and
/// a recognized long press win their own gesture arena before paging can start.
class MobileCalendarPager extends StatefulWidget {
  const MobileCalendarPager({
    super.key,
    required this.controller,
    this.onInteractionChanged,
  });

  final PlannerController controller;
  final ValueChanged<bool>? onInteractionChanged;

  @override
  State<MobileCalendarPager> createState() => MobileCalendarPagerState();
}

class MobileCalendarPagerState extends State<MobileCalendarPager>
    with SingleTickerProviderStateMixin {
  late final AnimationController _slide;
  GlobalKey<CalendarGridState> _grid = GlobalKey<CalendarGridState>();
  (PlannerView, int, int)? _gridWindow;
  CalendarGridState? _pinchGrid;
  double _width = 1;
  double _verticalOffset = 0;
  double _rawDrag = 0;
  int _direction = 0;
  bool _settling = false;
  bool _interactionActive = false;
  DateTime? _gestureDate;
  PlannerView? _gestureView;

  bool get _reduced => MediaQuery.disableAnimationsOf(context);
  bool get _canSwipe => widget.controller.view != PlannerView.week;

  @override
  void initState() {
    super.initState();
    _slide = AnimationController.unbounded(vsync: this);
  }

  @override
  void dispose() {
    _slide.dispose();
    super.dispose();
  }

  void _begin() {
    _slide.stop();
    _rawDrag = _slide.value;
    _gestureDate = widget.controller.anchorDate;
    _gestureView = widget.controller.view;
  }

  void _update(double delta) {
    if (_settling || _interactionActive || _gestureDate == null) return;
    _rawDrag += delta;
    // Keep direct contact through a normal swipe, then resist pulling beyond
    // one page. No overshooting card scale or moving light source is involved.
    final distance = _rawDrag.abs();
    final limit = _width * .92;
    final travel = distance <= limit
        ? distance
        : limit + (distance - limit) * .18;
    final nextDirection = _rawDrag < 0 ? 1 : -1;
    if (_direction != nextDirection) {
      setState(() => _direction = nextDirection);
    }
    _slide.value = _rawDrag.sign * math.min(travel, _width);
  }

  Future<void> _release(double velocity, {bool cancel = false}) async {
    if (_settling || _interactionActive || _direction == 0) return;
    final unchanged =
        _gestureDate == widget.controller.anchorDate &&
        _gestureView == widget.controller.view;
    final distance = _slide.value.abs();
    final forwardVelocity = velocity * _slide.value.sign;
    final commit =
        !cancel &&
        unchanged &&
        ((distance >= _width * .25 && forwardVelocity > -650) ||
            (distance >= 32 && forwardVelocity >= 650));
    await _settle(commit ? _direction : 0);
  }

  /// Header arrows use the same transition as a finger release.
  Future<void> navigate(int direction) async {
    if (_settling || _interactionActive) return;
    if (!_canSwipe || _reduced) {
      HapticFeedback.selectionClick();
      widget.controller.navigatePeriod(direction);
      return;
    }
    _begin();
    setState(() => _direction = direction);
    await _settle(direction);
  }

  Future<void> _settle(int commitDirection) async {
    setState(() => _settling = true);
    if (!_reduced) {
      await _slide.animateTo(
        commitDirection == 0 ? 0 : -commitDirection * _width,
        duration: Duration(milliseconds: commitDirection == 0 ? 190 : 210),
        curve: Curves.easeOutCubic,
      );
    }
    if (!mounted) return;
    if (commitDirection != 0) {
      widget.controller.navigatePeriod(commitDirection);
      HapticFeedback.selectionClick();
    }
    _slide.value = 0;
    setState(() {
      _direction = 0;
      _rawDrag = 0;
      _settling = false;
    });
  }

  void _onInteractionChanged(bool active) {
    if (_interactionActive == active) return;
    _interactionActive = active;
    if (active) {
      // A second touch can take over a swipe that already passed drag slop.
      // Discard its provisional translation without navigating.
      _gestureDate = null;
      _gestureView = null;
      if (!_settling && _direction != 0) {
        _slide.value = 0;
        setState(() {
          _direction = 0;
          _rawDrag = 0;
        });
      }
    }
    widget.onInteractionChanged?.call(active);
  }

  Widget _withTimePinch(Widget child) => RawGestureDetector(
    behavior: HitTestBehavior.opaque,
    excludeFromSemantics: true,
    gestures: {
      MobileTimePinchRecognizer:
          GestureRecognizerFactoryWithHandlers<MobileTimePinchRecognizer>(
            () => MobileTimePinchRecognizer(debugOwner: this),
            (recognizer) => recognizer
              ..onStart = () {
                if (_settling) return;
                _pinchGrid = _grid.currentState;
                _pinchGrid?.beginTimePinch();
              }
              ..onUpdate = (ratio, previousY, currentY) {
                final grid = _pinchGrid;
                if (grid != null && grid.mounted) {
                  grid.updateTimePinch(ratio, previousY, currentY);
                }
              }
              ..onEnd = (cancelled) {
                final grid = _pinchGrid;
                _pinchGrid = null;
                if (grid == null) return;
                if (grid.mounted) {
                  grid.endTimePinch(cancelled);
                } else {
                  _verticalOffset = 0;
                  _onInteractionChanged(false);
                }
              },
          ),
    },
    child: child,
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _width = constraints.maxWidth;
      final controller = widget.controller;
      final window = (
        controller.view,
        controller.sleep.visibleStart,
        controller.sleep.visibleEnd,
      );
      if (_gridWindow != window) {
        _gridWindow = window;
        _grid = GlobalKey<CalendarGridState>();
      }
      final current = CalendarGrid(
        key: _grid,
        controller: controller,
        touchMode: true,
        initialVerticalOffset: _verticalOffset,
        onVerticalOffsetChanged: (value) => _verticalOffset = value,
        onInteractionChanged: _onInteractionChanged,
      );
      final days = controller.visibleDays;
      final adjacentDays = [
        for (final day in days)
          day.add(Duration(days: days.length * _direction)),
      ];
      // Construct the adjacent subtree once per gesture direction, outside the
      // animation builder. Only its transform changes on animation frames.
      final adjacent = _direction == 0 || _reduced
          ? null
          : ExcludeSemantics(
              child: IgnorePointer(
                child: TickerMode(
                  enabled: false,
                  child: LiquidGlassScope(
                    strength: controller.glassStrength,
                    motion: false,
                    mobile: true,
                    child: RepaintBoundary(
                      child: CalendarGrid(
                        key: ValueKey('mobile-adjacent-$_direction'),
                        controller: controller,
                        touchMode: true,
                        visibleDays: adjacentDays,
                        initialVerticalOffset: _verticalOffset,
                      ),
                    ),
                  ),
                ),
              ),
            );
      return Semantics(
        hint: _canSwipe
            ? '左右滑动切换日期。上下滑动浏览时间，双指捏合可查看全天。'
            : '左右滑动浏览整周。双指捏合可查看全天。',
        child: _withTimePinch(
          Listener(
            // A recognized drag can report an end after PointerCancel. Handle
            // the raw cancellation first so an OS interruption never commits a
            // long swipe that happened to cross the navigation threshold.
            onPointerCancel: (_) => _release(0, cancel: true),
            child: GestureDetector(
              key: const ValueKey('mobile-calendar-pager'),
              dragStartBehavior: DragStartBehavior.down,
              behavior: HitTestBehavior.translucent,
              onHorizontalDragStart: _canSwipe
                  ? (_) {
                      if (!_settling && !_interactionActive) _begin();
                    }
                  : null,
              onHorizontalDragUpdate: _canSwipe
                  ? (details) => _update(details.primaryDelta ?? 0)
                  : null,
              onHorizontalDragEnd: _canSwipe
                  ? (details) => _release(details.primaryVelocity ?? 0)
                  : null,
              onHorizontalDragCancel: _canSwipe
                  ? () => _release(0, cancel: true)
                  : null,
              child: ClipRRect(
                borderRadius: WeekGlassGeometry.corners,
                child: AnimatedBuilder(
                  animation: _slide,
                  child: RepaintBoundary(child: current),
                  builder: (context, child) => Stack(
                    fit: StackFit.expand,
                    children: [
                      // Reduced motion keeps the gesture available without moving
                      // the whole calendar or mounting a second moving surface.
                      if (adjacent != null)
                        Transform.translate(
                          offset: Offset(_slide.value + _direction * _width, 0),
                          child: adjacent,
                        ),
                      Transform.translate(
                        key: const ValueKey('mobile-calendar-translation'),
                        offset: Offset(_reduced ? 0 : _slide.value, 0),
                        child: AbsorbPointer(
                          absorbing: _settling,
                          child: child,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
