import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

/// Zero fits the configured time window to its viewport. One preserves the
/// original mobile density, and higher values stretch that density.
class MobileTimeZoom {
  const MobileTimeZoom(this.viewportHeight, this.visibleMinutes);

  static const normal = 1.0;
  static const maximum = 3.0;
  static const _defaultHourHeight = 56.0;

  final double viewportHeight;
  final int visibleMinutes;

  static double normalize(double? value) =>
      value == null || !value.isFinite ? normal : value.clamp(0.0, maximum);

  double get _normalHeight =>
      math.max(viewportHeight, visibleMinutes / 60 * _defaultHourHeight);
  double get maximumHeight => _normalHeight * maximum;

  double heightAt(double zoom) => zoom <= normal
      ? viewportHeight + (_normalHeight - viewportHeight) * zoom
      : _normalHeight * zoom;

  double zoomAt(double height) => height >= _normalHeight
      ? height / _normalHeight
      : (height - viewportHeight) / (_normalHeight - viewportHeight);
}

typedef _Contact = ({double span, double midpoint});

/// A pair of touches reserves the calendar until every contact lifts. A lone
/// finger never wins this recognizer's arena, so scrolling, editing and paging
/// keep their normal recognizers and thresholds.
class MobileTimePinchRecognizer extends OneSequenceGestureRecognizer {
  MobileTimePinchRecognizer({super.debugOwner})
    : super(supportedDevices: const {PointerDeviceKind.touch});

  VoidCallback? onStart;
  void Function(double ratio, double previousY, double currentY)? onUpdate;
  ValueChanged<bool>? onEnd;

  final _positions = <int, double>{};
  _Contact? _contact;
  bool _paired = false;
  bool _moving = false;
  bool _cancelled = false;

  static const _spanSlop = 6.0;
  static const _minimumSpan = 16.0;

  _Contact get _sample {
    final a = _positions.values.first;
    final b = _positions.values.last;
    return (span: (a - b).abs(), midpoint: (a + b) / 2);
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _positions[event.pointer] = event.position.dy;
    if (!_paired && _positions.length == 2) {
      _paired = true;
      _contact = _sample;
      // The first finger may already own an edit or a scroll. Keep observing
      // it after rejection, and let the calendar stop those provisional actions
      // before the pinch can update anything.
      onStart?.call();
      resolve(GestureDisposition.accepted);
    } else if (_paired) {
      _cancelled = true;
      _contact = null;
      resolvePointer(event.pointer, GestureDisposition.accepted);
    }
  }

  @override
  void handleNonAllowedPointer(PointerDownEvent event) {}

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      _positions[event.pointer] = event.position.dy;
      final previous = _contact;
      if (previous == null) return;
      final next = _sample;
      if (!_moving && (next.span - previous.span).abs() < _spanSlop) return;
      _moving = true;
      _contact = next;
      final ratio =
          math.max(_minimumSpan, next.span) /
          math.max(_minimumSpan, previous.span);
      onUpdate?.call(ratio, previous.midpoint, next.midpoint);
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _cancelled |= event is PointerCancelEvent;
      _positions.remove(event.pointer);
      _contact = null;
      resolvePointer(event.pointer, GestureDisposition.rejected);
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    final paired = _paired;
    final cancelled = _cancelled;
    _paired = false;
    _moving = false;
    _cancelled = false;
    if (paired) onEnd?.call(cancelled);
  }

  @override
  String get debugDescription => 'calendar time pinch';
}
