import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

import '../mobile/mobile_time_zoom.dart';
import 'event_editor_dialog.dart';
import 'event_details_dialog.dart';
import 'planner_controller.dart';
import 'batch_edit_scope_dialog.dart';
import 'glass_event_card.dart';
import 'spring_positioned.dart';

/// A single build's immutable day geometry, shared by header and event cards.
@visibleForTesting
class CalendarDayLayout {
  CalendarDayLayout({
    required this.day,
    required List<CalendarEvent> events,
    required this.startMinute,
    required this.endMinute,
    required this.scale,
    required this.minimumHeight,
  }) : events = List.unmodifiable(events),
       lanes = layoutTimedEvents(events) {
    final intervals = [
      for (final event in events)
        (
          id: event.id,
          start: _relativeMinute(event.startLocal, day),
          end: _relativeMinute(event.endLocal, day),
        ),
    ];
    _starts = [...intervals]..sort((a, b) => a.start.compareTo(b.start));
    _ends = [...intervals]..sort((a, b) => a.end.compareTo(b.end));
  }

  final DateTime day;
  final List<CalendarEvent> events;
  final Map<String, EventLaneLayout> lanes;
  final int startMinute, endMinute;
  final double scale, minimumHeight;
  late final List<({String id, double start, double end})> _starts, _ends;
  final _bands = <CalendarEvent, (double, double)>{};

  (double, double) band(CalendarEvent event, {bool cache = true}) => cache
      ? _bands.putIfAbsent(event, () => _calculateBand(event))
      : _calculateBand(event);

  (double, double) _calculateBand(CalendarEvent event) {
    final actualStart = _relativeMinute(event.startLocal, day);
    final actualEnd = _relativeMinute(event.endLocal, day);
    final start = actualStart.clamp(startMinute, endMinute).toDouble();
    final end = actualEnd.clamp(startMinute, endMinute).toDouble();
    if (start != actualStart || end != actualEnd) {
      // A continuation meets the edge exactly. Keep the minimum card height
      // for complete events; short continuations are still in the day header.
      return ((start - startMinute) * scale, (end - start) * scale);
    }
    var before = startMinute.toDouble();
    var after = endMinute.toDouble();
    var low = 0;
    var high = _ends.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (_ends[middle].end <= start) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    var index = low - 1;
    if (index >= 0 && _ends[index].id == event.id) index--;
    if (index >= 0) before = math.max(before, _ends[index].end);

    low = 0;
    high = _starts.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (_starts[middle].start < end) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    index = low;
    if (index < _starts.length && _starts[index].id == event.id) index++;
    if (index < _starts.length) after = math.min(after, _starts[index].start);

    final gridHeight = (endMinute - startMinute) * scale;
    final available = math.max(0.01, (after - before) * scale);
    final height = math.min(
      available,
      math.max(minimumHeight, (end - start) * scale),
    );
    final earliest = (before - startMinute) * scale;
    final latest = math.max(earliest, (after - startMinute) * scale - height);
    final top = ((start - startMinute) * scale).clamp(earliest, latest);
    return (top.clamp(0.0, math.max(0.0, gridHeight - height)), height);
  }
}

double _relativeMinute(DateTime value, DateTime date) =>
    DateTime.utc(
      value.year,
      value.month,
      value.day,
      value.hour,
      value.minute,
      value.second,
      value.millisecond,
      value.microsecond,
    ).difference(DateTime.utc(date.year, date.month, date.day)).inMicroseconds /
    Duration.microsecondsPerMinute;

class CalendarGrid extends StatefulWidget {
  const CalendarGrid({
    super.key,
    required this.controller,
    this.touchMode = false,
    this.visibleDays,
    this.initialVerticalOffset = 0,
    this.onVerticalOffsetChanged,
    this.onInteractionChanged,
  });

  final PlannerController controller;
  final bool touchMode;

  /// Only the phone pager supplies an inert adjacent date window.
  final List<DateTime>? visibleDays;
  final double initialVerticalOffset;
  final ValueChanged<double>? onVerticalOffsetChanged;
  final ValueChanged<bool>? onInteractionChanged;

  @override
  CalendarGridState createState() => CalendarGridState();
}

class CalendarGridState extends State<CalendarGrid>
    with SingleTickerProviderStateMixin {
  late final AnimationController _dropClock;
  static const double _timeRailWidth = 44;
  static const double _topInset = 8;
  static const double _bottomInset = 12;
  double _headerHeight = 40;
  double _hourHeight = 24;
  int get _startMinute => widget.controller.sleep.visibleStart;
  int get _endMinute => widget.controller.sleep.visibleEnd;
  DateTime? _resizeDay;
  static const double _desktopMinimumDayWidth = 80;
  static const double _mobileMinimumDayWidth = 78;

  final ScrollController _headerHorizontalController = ScrollController();
  final ScrollController _gridHorizontalController = ScrollController();
  late final _CalendarTimeScrollController _timeController;
  late final _CalendarTimeScrollController _gridController;
  final GlobalKey _gridContentKey = GlobalKey();
  late MobileTimeZoom _mobileTimeScale;
  double _gridHeight = 0;
  double? _previewTimeZoom;
  ({double zoom, double offset})? _timePinchStart;
  double get _timeZoom => _previewTimeZoom ?? widget.controller.mobileTimeZoom;
  bool get _pinching => _timePinchStart != null;
  double get _verticalOffset =>
      _gridController.zoomOffset ??
      (_gridController.hasClients
          ? _gridController.offset
          : widget.initialVerticalOffset);

  bool _syncingVertical = false;
  bool _syncingHorizontal = false;
  final _viewport = ValueNotifier<Rect>(Rect.zero);
  // Pointer updates only change transient overlays. Keep the stationary grid
  // and its day layouts mounted until a gesture starts/ends or data changes.
  final _dragFrame = ValueNotifier<int>(0);
  final _landingFrame = ValueNotifier<int>(0);
  final _resizeFrame = ValueNotifier<int>(0);
  final _selectionFrame = ValueNotifier<int>(0);
  Size _viewportSize = Size.zero;
  double _dayWidth = _desktopMinimumDayWidth;
  List<DateTime> _visibleDays = <DateTime>[];

  DateTime? _selectionDate;
  int? _selectionStart;
  int? _selectionEnd;
  double? _selectionRawEnd;

  CalendarEvent? _dragOriginal;
  CalendarEvent? _dragPreview;
  CalendarEvent? _dragLanding;
  bool _settling = false;
  bool _returnMagnet = false;
  bool _leftOrigin = false;
  Offset? _dragStartLocal;
  int _dragStartVisibleIndex = 0;
  double _dragDayWidth = _desktopMinimumDayWidth;

  CalendarEvent? _resizeOriginal;
  CalendarEvent? _resizePreview;
  Offset? _resizeStartGlobal;
  bool _resizeStartEdge = false;

  String? _selectedEventId;
  double _dragOriginLeft = 0;
  double _dragVisualLeft = 0;
  double _dragCardWidth = 0;
  DateTime? _dragTargetDate;
  DateTime? _lastHapticTime;
  Duration _lastHapticFrame = Duration.zero;
  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  @override
  void initState() {
    super.initState();
    _timeController = _CalendarTimeScrollController(
      initialScrollOffset: widget.initialVerticalOffset,
    );
    _gridController = _CalendarTimeScrollController(
      initialScrollOffset: widget.initialVerticalOffset,
    );
    _dropClock = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 170),
    );
    _gridController.addListener(_syncTimeRail);
    _timeController.addListener(_syncGrid);
    _headerHorizontalController.addListener(_syncHeaderHorizontal);
    _gridHorizontalController.addListener(_syncGridHorizontal);
  }

  @override
  void dispose() {
    _gridController.removeListener(_syncTimeRail);
    _timeController.removeListener(_syncGrid);
    _headerHorizontalController.removeListener(_syncHeaderHorizontal);
    _gridHorizontalController.removeListener(_syncGridHorizontal);
    _dropClock.dispose();
    _headerHorizontalController.dispose();
    _gridHorizontalController.dispose();
    _timeController.dispose();
    _gridController.dispose();
    _viewport.dispose();
    _dragFrame.dispose();
    _landingFrame.dispose();
    _resizeFrame.dispose();
    _selectionFrame.dispose();
    super.dispose();
  }

  void _syncTimeRail() {
    _syncVertical(_gridController, _timeController);
    if (_gridController.hasClients) {
      widget.onVerticalOffsetChanged?.call(_gridController.offset);
    }
    _updateViewport();
  }

  void _syncGrid() {
    _syncVertical(_timeController, _gridController);
    if (_timeController.hasClients) {
      widget.onVerticalOffsetChanged?.call(_timeController.offset);
    }
    _updateViewport();
  }

  void _syncHeaderHorizontal() =>
      _syncHorizontal(_headerHorizontalController, [_gridHorizontalController]);
  void _syncGridHorizontal() {
    _syncHorizontal(_gridHorizontalController, [_headerHorizontalController]);
    _updateViewport();
  }

  DateTime? _revealedAnchor;

  void _revealIPhoneWeekday() {
    if (!widget.touchMode ||
        defaultTargetPlatform != TargetPlatform.iOS ||
        widget.visibleDays != null ||
        widget.controller.view != PlannerView.week) {
      _revealedAnchor = null;
      return;
    }
    final anchor = widget.controller.anchorDate;
    if (_revealedAnchor == anchor) return;
    _revealedAnchor = anchor;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _revealedAnchor != anchor ||
          !_gridHorizontalController.hasClients) {
        return;
      }
      final index = _visibleDays.indexWhere(
        (d) => DateUtils.isSameDay(d, anchor),
      );
      if (index < 0) return;
      final position = _gridHorizontalController.position;
      final left = index * _dayWidth;
      final target = position.pixels
          .clamp(left + _dayWidth - position.viewportDimension, left)
          .clamp(0.0, position.maxScrollExtent);
      if (target != position.pixels) _gridHorizontalController.jumpTo(target);
    });
  }

  void _updateViewport() {
    final horizontal = _gridHorizontalController.hasClients
        ? _gridHorizontalController.offset
        : 0.0;
    final next = (Offset(horizontal, _verticalOffset) & _viewportSize).inflate(
      56,
    );
    if (_viewport.value != next) _viewport.value = next;
  }

  void _syncHorizontal(
    ScrollController source,
    List<ScrollController> targets,
  ) {
    if (_syncingHorizontal || !source.hasClients) return;
    _syncingHorizontal = true;
    final offset = source.position.pixels;
    for (final target in targets) {
      if (!target.hasClients) continue;
      target.jumpTo(
        offset.clamp(0.0, target.position.maxScrollExtent).toDouble(),
      );
    }
    _syncingHorizontal = false;
  }

  void _syncVertical(ScrollController source, ScrollController target) {
    if (_syncingVertical || !source.hasClients || !target.hasClients) return;
    _syncingVertical = true;
    final targetPosition = target.position;
    final offset = source.position.pixels
        .clamp(0.0, targetPosition.maxScrollExtent)
        .toDouble();
    target.jumpTo(offset);
    _syncingVertical = false;
  }

  WeekGlassPalette _palette(BuildContext context) =>
      WeekGlassPalette.of(context);

  void _reportInteraction() => widget.onInteractionChanged?.call(
    _pinching || _dragOriginal != null || _selectionDate != null,
  );

  /// Called by the phone pager, including when its live grid is mid-swipe.
  void beginTimePinch() {
    // Stop a one-finger drag or momentum before asking the time axis to move.
    // A second touch can enter after another recognizer has won the arena.
    for (final controller in [
      _gridController,
      _timeController,
      _gridHorizontalController,
      _headerHorizontalController,
    ]) {
      if (controller.hasClients) controller.jumpTo(controller.offset);
    }
    setState(() {
      _timePinchStart = (zoom: _timeZoom, offset: _verticalOffset);
      _clearSelection();
      if (!_settling) _clearGesture();
    });
    _reportInteraction();
  }

  void updateTimePinch(double ratio, double previousY, double currentY) {
    final scale = _mobileTimeScale;
    if (scale.viewportHeight <= 0) return;
    final box = context.findRenderObject()! as RenderBox;
    double focal(double y) =>
        (box.globalToLocal(Offset(0, y)).dy - _headerHeight).clamp(
          0.0,
          scale.viewportHeight,
        );

    final height = scale.heightAt(_timeZoom);
    final nextHeight = (height * ratio).clamp(
      scale.viewportHeight,
      scale.maximumHeight,
    );
    // Use the last clamped position as the next anchor, so fingers can reverse
    // direction immediately at either zoom limit or either scroll edge.
    final minuteFraction = (_verticalOffset + focal(previousY)) / height;
    final offset = (minuteFraction * nextHeight - focal(currentY)).clamp(
      0.0,
      nextHeight - scale.viewportHeight,
    );
    if (nextHeight != height || offset != _verticalOffset) {
      _previewTimePinch(
        height == nextHeight ? _timeZoom : scale.zoomAt(nextHeight),
        offset,
      );
    }
  }

  void _previewTimePinch(double zoom, double offset) {
    final nextHeight = _mobileTimeScale.heightAt(zoom);
    setState(() => _previewTimeZoom = zoom);
    if (nextHeight != _gridHeight) {
      // Apply after the new scroll extents are known, but before paint. The
      // time labels and cards must move together in the same zoom frame.
      _gridController.zoomOffset = _timeController.zoomOffset = offset;
    } else {
      _gridController.zoomOffset = _timeController.zoomOffset = null;
      _gridController.jumpTo(offset);
    }
    widget.onVerticalOffsetChanged?.call(offset);
  }

  Future<void> endTimePinch(bool cancelled) async {
    final start = _timePinchStart!;
    final zoom = _previewTimeZoom;
    if (cancelled && zoom != null) _previewTimePinch(start.zoom, start.offset);
    setState(() {
      _timePinchStart = null;
      _previewTimeZoom = null;
    });
    _reportInteraction();
    if (cancelled || zoom == null) return;
    try {
      await widget.controller.saveMobileTimeZoom(zoom);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('缩放未保存，下次打开时会恢复到上次的比例。'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = _palette(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        _visibleDays = widget.visibleDays ?? widget.controller.visibleDays;
        final availableDayWidth =
            (constraints.maxWidth - _timeRailWidth) / _visibleDays.length;
        final minimumDayWidth = constraints.maxWidth < 720
            ? _mobileMinimumDayWidth
            : _desktopMinimumDayWidth;
        _dayWidth = math.max(minimumDayWidth, availableDayWidth);
        _dragDayWidth = _dayWidth;
        _revealIPhoneWeekday();
        final contentWidth = _dayWidth * _visibleDays.length;
        _headerHeight = math.max(
          40,
          MediaQuery.textScalerOf(context).scale(40),
        );
        _viewportSize = Size(
          math.max(0, constraints.maxWidth - _timeRailWidth),
          math.max(0, constraints.maxHeight - _headerHeight),
        );
        final visibleMinutes = _endMinute - _startMinute;
        _mobileTimeScale = MobileTimeZoom(_viewportSize.height, visibleMinutes);
        final gridHeight = _gridHeight = widget.touchMode
            ? _mobileTimeScale.heightAt(_timeZoom)
            : math.max(24.0, _viewportSize.height);
        _hourHeight = gridHeight / (visibleMinutes / 60);
        _updateViewport();
        final days = {for (final day in _visibleDays) day: _dayLayout(day)};

        return ClipRRect(
          borderRadius: WeekGlassGeometry.corners,
          child: BackdropFilter(
            enabled: widget.visibleDays == null && !widget.touchMode,
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: DecoratedBox(
              decoration: palette.glassDecoration(),
              child: Column(
                children: [
                  _buildDayHeader(palette, contentWidth, days),
                  Expanded(
                    child: Row(
                      children: [
                        SizedBox(
                          width: _timeRailWidth,
                          child: _buildTimeRail(palette, gridHeight),
                        ),
                        Expanded(
                          child: SingleChildScrollView(
                            controller: _gridHorizontalController,
                            scrollDirection: Axis.horizontal,
                            physics:
                                contentWidth <=
                                    constraints.maxWidth - _timeRailWidth + .5
                                ? const NeverScrollableScrollPhysics()
                                : const ClampingScrollPhysics(),
                            child: SizedBox(
                              width: contentWidth,
                              child: SingleChildScrollView(
                                controller: _gridController,
                                physics: widget.touchMode
                                    ? const ClampingScrollPhysics()
                                    : const NeverScrollableScrollPhysics(),
                                child: CustomPaint(
                                  painter: _GridPainter(
                                    palette: palette,
                                    interval: 30,
                                    startMinute: _startMinute,
                                    endMinute: _endMinute,
                                    dayWidth: _dayWidth,
                                    weekendColumns: [
                                      for (
                                        var i = 0;
                                        i < _visibleDays.length;
                                        i++
                                      )
                                        if (_visibleDays[i].weekday >=
                                            DateTime.saturday)
                                          i,
                                    ],
                                    topInset: 0,
                                    bottomInset: 0,
                                  ),
                                  child: Padding(
                                    padding: EdgeInsets.zero,
                                    child: SizedBox(
                                      key: _gridContentKey,
                                      width: contentWidth,
                                      height: gridHeight,
                                      child: Stack(
                                        clipBehavior: Clip.none,
                                        children: [
                                          Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: List<Widget>.generate(
                                              _visibleDays.length,
                                              (index) => _buildDayLane(
                                                date: _visibleDays[index],
                                                visibleIndex: index,
                                                palette: palette,
                                                height: gridHeight,
                                                day: days[_visibleDays[index]]!,
                                              ),
                                            ),
                                          ),
                                          if (_dragOriginal != null) ...[
                                            Positioned.fill(
                                              child: IgnorePointer(
                                                child: ValueListenableBuilder<int>(
                                                  valueListenable:
                                                      _landingFrame,
                                                  builder:
                                                      (
                                                        context,
                                                        _,
                                                        child,
                                                      ) => Stack(
                                                        clipBehavior: Clip.none,
                                                        children: _buildMoveLanding(
                                                          palette,
                                                          gridHeight,
                                                          days[_dragTargetDate]!,
                                                        ),
                                                      ),
                                                ),
                                              ),
                                            ),
                                            _buildMoveFollower(days),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDayHeader(
    WeekGlassPalette palette,
    double contentWidth,
    Map<DateTime, CalendarDayLayout> days,
  ) {
    final today = dateOnly(DateTime.now());
    final titleHeight = MediaQuery.textScalerOf(context).scale(12.5) * 1.15;
    final compactThreshold =
        widget.touchMode && _timeZoom < MobileTimeZoom.normal
        ? math.max(24.0, titleHeight + 8)
        : titleHeight + 1;
    return SizedBox(
      height: _headerHeight,
      child: Row(
        children: [
          SizedBox(
            width: _timeRailWidth,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 11, bottom: 7),
                child: Text(
                  '时间',
                  style: TextStyle(
                    color: palette.mutedSoft,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              controller: _headerHorizontalController,
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              child: SizedBox(
                width: contentWidth,
                child: Row(
                  children: _visibleDays.map((date) {
                    final isToday = dateOnly(date) == today;
                    final compactEvents =
                        days[date]!.events
                            .where(
                              (e) => days[date]!.band(e).$2 < compactThreshold,
                            )
                            .toList()
                          ..sort(
                            (a, b) => a.startLocal.compareTo(b.startLocal),
                          );
                    return Container(
                      width: _dayWidth,
                      height: _headerHeight,
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: palette.line.withValues(alpha: .32),
                            width: .7,
                          ),
                        ),
                      ),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                const [
                                  '周一',
                                  '周二',
                                  '周三',
                                  '周四',
                                  '周五',
                                  '周六',
                                  '周日',
                                ][date.weekday - 1],
                                style: TextStyle(
                                  color: isToday
                                      ? palette.accentStrong
                                      : palette.muted,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w400,
                                  letterSpacing: .5,
                                ),
                              ),
                              const SizedBox(height: 1),
                              Text(
                                date.day.toString(),
                                style: TextStyle(
                                  color: isToday
                                      ? palette.accentStrong
                                      : palette.text,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w500,
                                  letterSpacing: -.5,
                                ),
                              ),
                            ],
                          ),
                          if (compactEvents.isNotEmpty)
                            Positioned(
                              right: 1,
                              top: 5,
                              child: SizedBox(
                                width: 28,
                                height: 28,
                                child: IconButton(
                                  key: ValueKey(
                                    'compact-events-${date.toIso8601String()}',
                                  ),
                                  tooltip: '查看本日 ${compactEvents.length} 条短日程',
                                  padding: EdgeInsets.zero,
                                  iconSize: 17,
                                  icon: const Icon(Icons.more_horiz_rounded),
                                  onPressed: () =>
                                      _openCompactEvents(date, compactEvents),
                                ),
                              ),
                            ),
                          if (isToday)
                            Positioned(
                              bottom: 1,
                              child: Container(
                                width: 4,
                                height: 4,
                                decoration: BoxDecoration(
                                  color: palette.accent,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimeRail(WeekGlassPalette palette, double gridHeight) {
    final marks = <int>[
      _startMinute,
      for (
        var minute = ((_startMinute ~/ 60) + 1) * 60;
        minute < _endMinute;
        minute += 60
      )
        minute,
      _endMinute,
    ];
    final labelHeight = MediaQuery.textScalerOf(context).scale(16);
    final firstTop = math.min(
      _topInset,
      math.max(0.0, gridHeight - labelHeight),
    );
    final lastTop = math.max(firstTop, gridHeight - labelHeight - _bottomInset);
    final compressed = widget.touchMode && _timeZoom < MobileTimeZoom.normal;
    final spacing = compressed
        ? math.max(22.0, labelHeight + 4)
        : labelHeight + 2;
    final canShowEnd = lastTop - firstTop >= labelHeight;
    final labelInterval = compressed
        ? const [1, 2, 3, 4, 6, 8, 12, 24].firstWhere(
                (hours) => _hourHeight * hours >= spacing,
                orElse: () => 24,
              ) *
              60
        : 60;
    var previousTop = double.negativeInfinity;
    return Container(
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(
            color: palette.line.withValues(alpha: .22),
            width: .7,
          ),
        ),
      ),
      child: SingleChildScrollView(
        controller: _timeController,
        physics: widget.touchMode
            ? const ClampingScrollPhysics()
            : const NeverScrollableScrollPhysics(),
        child: Padding(
          padding: EdgeInsets.zero,
          child: SizedBox(
            height: gridHeight,
            child: Stack(
              children: marks.map((minute) {
                final top =
                    ((minute - _startMinute) / 60 * _hourHeight -
                            labelHeight / 2)
                        .clamp(firstTop, lastTop);
                if (minute != _startMinute && minute != _endMinute) {
                  final skipForDensity = compressed
                      ? minute % labelInterval != 0
                      : _hourHeight < 22 && (minute ~/ 60).isOdd;
                  // Clamping the endpoints can place a fractional start/end
                  // next to a regular hour even at normal zoom.
                  if (skipForDensity ||
                      top - previousTop < spacing ||
                      (canShowEnd && lastTop - top < spacing)) {
                    return const SizedBox.shrink();
                  }
                } else if (minute == _endMinute && !canShowEnd) {
                  return const SizedBox.shrink();
                }
                previousTop = top;
                return Positioned(
                  top: top,
                  right: 9,
                  child: Text(
                    _formatTime(minute),
                    key: ValueKey(
                      minute % 60 == 0
                          ? 'time-${minute ~/ 60}'
                          : 'time-minute-$minute',
                    ),
                    style: TextStyle(
                      color: palette.mutedSoft,
                      fontSize: 10,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDayLane({
    required DateTime date,
    required int visibleIndex,
    required WeekGlassPalette palette,
    required double height,
    required CalendarDayLayout day,
  }) {
    // Keep the original card mounted while its drag recognizer owns the
    // pointer. A separate inert preview can cross into another day lane.
    final events = day.events;
    final lanes = day.lanes;

    return SizedBox(
      width: _dayWidth,
      height: height,
      child: Listener(
        onPointerCancel: (_) {
          if (_selectionDate == null) return;
          setState(_clearSelection);
          _reportInteraction();
        },
        child: Semantics(
          container: widget.touchMode,
          label: widget.touchMode ? '${date.month}月${date.day}日时间表' : null,
          hint: widget.touchMode ? '长按空白选择时段，也可使用底部新建' : null,
          child: GestureDetector(
            key: ValueKey('day-lane-${date.toIso8601String()}'),
            dragStartBehavior: DragStartBehavior.down,
            behavior: HitTestBehavior.opaque,
            onTapUp: widget.touchMode
                ? null
                : (details) => _createFromTap(date, details.localPosition.dy),
            onPanStart: widget.touchMode
                ? null
                : (details) => _beginSelection(date, details.localPosition.dy),
            onPanUpdate: widget.touchMode
                ? null
                : (details) => _updateSelection(details.localPosition.dy),
            onPanEnd: widget.touchMode ? null : (_) => _finishSelection(),
            onPanCancel: widget.touchMode
                ? null
                : () => setState(_clearSelection),
            onLongPressStart: widget.touchMode
                ? (details) => _beginSelection(date, details.localPosition.dy)
                : null,
            onLongPressMoveUpdate: widget.touchMode
                ? (details) => _updateSelection(details.localPosition.dy)
                : null,
            onLongPressEnd: widget.touchMode ? (_) => _finishSelection() : null,
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                ...events.map((event) {
                  final layout =
                      lanes[event.id] ??
                      const EventLaneLayout(laneIndex: 0, laneCount: 1);
                  final original = _dragOriginal?.id == event.id
                      ? _dragOriginal!
                      : _resizeOriginal?.id == event.id
                      ? _resizeOriginal!
                      : event;
                  return _buildEvent(
                    event: event,
                    original: original,
                    layout: layout,
                    palette: palette,
                    date: date,
                    visibleIndex: visibleIndex,
                    day: day,
                  );
                }),
                if (_resizeOriginal != null)
                  ValueListenableBuilder<int>(
                    valueListenable: _resizeFrame,
                    builder: (context, _, child) => _buildResizePreview(
                      date: date,
                      visibleIndex: visibleIndex,
                      palette: palette,
                      day: day,
                    ),
                  ),
                if (_selectionDate == date &&
                    _selectionStart != null &&
                    _selectionEnd != null)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: ValueListenableBuilder<int>(
                        valueListenable: _selectionFrame,
                        builder: (context, _, child) => Stack(
                          clipBehavior: Clip.none,
                          children: _buildSelectionPreview(
                            palette,
                            height,
                            visibleIndex,
                          ),
                        ),
                      ),
                    ),
                  ),
                _buildCurrentTimeIndicator(palette, date),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openCompactEvents(
    DateTime date,
    List<CalendarEvent> events,
  ) async {
    if (_pinching) return;
    final selected = await showDialog<CalendarEvent>(
      context: context,
      builder: (context) => GlassAlertDialog(
        title: Text('${date.month}月${date.day}日短日程'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final event in events)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      Icons.schedule_rounded,
                      color: WeekGlassPalette.of(context)
                          .eventColor(event.color.key, selected: true),
                    ),
                    title: Text(event.title.isEmpty ? '预留时间' : event.title),
                    subtitle: Text(
                      '${_formatTime(event.startLocal.hour * 60 + event.startLocal.minute)} – ${_formatTime(event.endLocal.hour * 60 + event.endLocal.minute)}',
                    ),
                    onTap: () => Navigator.pop(context, event),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (selected != null && mounted) {
      await openEventDetails(
        context,
        controller: widget.controller,
        event: selected,
      );
    }
  }

  CalendarDayLayout _dayLayout(DateTime day) {
    final comfortableHeight = math.max(
      18.0,
      MediaQuery.textScalerOf(context).scale(12.5) * 1.15 + 3,
    );
    return CalendarDayLayout(
      day: day,
      events: widget.controller.timedEventsInWindow(day),
      startMinute: _startMinute,
      endMinute: _endMinute,
      scale: _hourHeight / 60,
      minimumHeight: widget.touchMode && _timeZoom < MobileTimeZoom.normal
          ? lerpDouble(2, comfortableHeight, _timeZoom)!
          : comfortableHeight,
    );
  }

  Widget _buildResizePreview({
    required DateTime date,
    required int visibleIndex,
    required WeekGlassPalette palette,
    required CalendarDayLayout day,
  }) {
    final preview = _resizePreview;
    if (preview == null ||
        !preview.startLocal.isBefore(
          DateTime(date.year, date.month, date.day, 0, _endMinute),
        ) ||
        !preview.endLocal.isAfter(
          DateTime(date.year, date.month, date.day, 0, _startMinute),
        )) {
      return const SizedBox.shrink();
    }
    final previewLanes = layoutTimedEvents([
      for (final event in day.events)
        if (event.id != preview.id) event,
      preview,
    ]);
    return _buildEvent(
      event: preview,
      original: preview,
      layout:
          previewLanes[preview.id] ??
          const EventLaneLayout(laneIndex: 0, laneCount: 1),
      palette: palette,
      date: date,
      visibleIndex: visibleIndex,
      preview: true,
      day: day,
    );
  }

  Widget _buildMoveFollower(Map<DateTime, CalendarDayLayout> days) =>
      ValueListenableBuilder<int>(
        valueListenable: _landingFrame,
        builder: (context, _, child) => ValueListenableBuilder<int>(
          valueListenable: _dragFrame,
          // The card displays the snapped time. Its text and material only
          // need rebuilding when that target changes, not on every pixel.
          child: IgnorePointer(
            child: GlassEventCard(
              materialActive: true,
              touchMode: widget.touchMode,
              event: _dragLanding!,
              preview: true,
              selected: true,
              onTap: () {},
              onMoveStart: (_) {},
              onMoveUpdate: (_) {},
              onMoveEnd: () {},
              onCancel: () {},
              onResizeStart: (_, _) {},
              onResizeUpdate: (_) {},
              onResizeEnd: () {},
            ),
          ),
          builder: (context, _, card) {
            final preview = _dragPreview!;
            final date = _dragTargetDate!;
            final startMinute = _relativeMinute(preview.startLocal, date);
            final endMinute = _relativeMinute(preview.endLocal, date);
            if (endMinute <= _startMinute || startMinute >= _endMinute) {
              return const SizedBox.shrink();
            }
            final band = days[date]!.band(preview, cache: false);
            return AnimatedPositioned(
              duration: (_settling || _returnMagnet) && !_reduceMotion
                  ? const Duration(milliseconds: 160)
                  : Duration.zero,
              curve: Curves.easeOutCubic,
              key: ValueKey('preview-${preview.id}'),
              top: band.$1,
              left: _dragVisualLeft,
              width: math.max(2, _dragCardWidth),
              height: band.$2,
              child: card!,
            );
          },
        ),
      );

  Widget _buildEvent({
    required CalendarEvent event,
    required CalendarEvent original,
    required EventLaneLayout layout,
    required WeekGlassPalette palette,
    required DateTime date,
    required int visibleIndex,
    required CalendarDayLayout day,
    bool preview = false,
  }) {
    final start = event.startLocal;
    final end = event.endLocal;
    final startMinute = _relativeMinute(start, date);
    final endMinute = _relativeMinute(end, date);
    if (endMinute <= _startMinute || startMinute >= _endMinute) {
      return const SizedBox.shrink();
    }

    // Live previews are new event objects on each pointer update, so retaining
    // them in the day snapshot would grow the cache for the whole gesture.
    final band = day.band(event, cache: !preview);
    final top = band.$1;
    final cardHeight = band.$2;
    final horizontal = _laneGeometry(layout, visibleIndex);
    final left = horizontal.left;
    final width = horizontal.width;
    final selected =
        _selectedEventId == event.id || _dragPreview?.id == event.id;

    return AnimatedPositioned(
      duration: Duration.zero,
      curve: Curves.easeOutCubic,
      key: ValueKey('${preview ? 'preview' : 'event'}-${event.id}'),
      top: top,
      left: left,
      width: math.max(2, width),
      height: cardHeight,
      child: IgnorePointer(
        ignoring: preview,
        child: Opacity(
          opacity:
              !preview &&
                  (event.id == _dragOriginal?.id ||
                      event.id == _resizeOriginal?.id)
              ? .22
              : 1,
          child: _ViewportEvent(
            viewport: _viewport,
            bounds: Rect.fromLTWH(
              visibleIndex * _dayWidth + left,
              top,
              math.max(2, width),
              cardHeight,
            ),
            forceActive:
                event.id == _dragOriginal?.id ||
                event.id == _resizeOriginal?.id,
            builder: (materialActive) => GlassEventCard(
              materialActive: materialActive,
              touchMode: widget.touchMode,
              event: event,
              preview: preview,
              selected: selected,
              canResizeStart: startMinute >= _startMinute,
              canResizeEnd: endMinute <= _endMinute,
              onTap: () {
                if (_pinching) return;
                setState(() => _selectedEventId = event.id);
                openEventDetails(
                  context,
                  controller: widget.controller,
                  event: original,
                );
              },
              onMoveStart: (position) =>
                  _beginEventMove(original, visibleIndex, position),
              onMoveUpdate: _updateEventMove,
              onMoveEnd: _finishEventMove,
              onCancel: _cancelGesture,
              onResizeStart: (position, startEdge) =>
                  _beginResize(original, position, startEdge, date),
              onResizeUpdate: _updateResize,
              onResizeEnd: _finishResize,
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _placement({
    required String id,
    required double left,
    required double top,
    required double width,
    required double height,
    required double gridHeight,
    required String range,
    required WeekGlassPalette palette,
  }) {
    final accent = palette.accentStrong;
    final badgeBelow = top + height + 6;
    final badgeTop = badgeBelow + 27 <= gridHeight
        ? badgeBelow
        : math.max(3.0, top - 32);
    return [
      SpringPositioned(
        key: ValueKey(id),
        rect: Rect.fromLTWH(left, top, math.max(2, width), height),
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: accent.withValues(alpha: .14),
              borderRadius: WeekGlassGeometry.corners,
              border: Border.all(
                color: accent.withValues(alpha: .55),
                width: 1,
              ),
            ),
          ),
        ),
      ),
      SpringPositioned(
        key: ValueKey('$id-label'),
        rect: Rect.fromLTWH(left + 2, badgeTop, math.max(2, width - 4), 26),
        child: IgnorePointer(
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: palette.surface.withValues(alpha: .98),
                borderRadius: WeekGlassGeometry.corners,
                border: Border.all(
                  color: palette.lineStrong.withValues(alpha: .55),
                ),
              ),
              child: Text(
                range,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'WeekGlassSans',
                  color: palette.text,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  height: 1.2,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ),
      ),
    ];
  }

  List<Widget> _buildSelectionPreview(
    WeekGlassPalette palette,
    double gridHeight,
    int visibleIndex,
  ) {
    final horizontal = _laneGeometry(
      const EventLaneLayout(laneIndex: 0, laneCount: 1),
      visibleIndex,
    );
    var start = math.min(_selectionStart!, _selectionEnd!);
    var end = math.max(_selectionStart!, _selectionEnd!);
    if (start == end) end = math.min(_endMinute, start + 15);
    final rawEnd = _selectionRawEnd ?? end.toDouble();
    final liveStart = math.min(_selectionStart!.toDouble(), rawEnd);
    final liveEnd = math.max(_selectionStart!.toDouble(), rawEnd);
    return [
      ..._placement(
        id: 'creation-landing',
        left: horizontal.left,
        top: (start - _startMinute) / 60 * _hourHeight,
        width: horizontal.width,
        height: math.max(3, (end - start) / 60 * _hourHeight),
        gridHeight: gridHeight,
        range: '${_formatTime(start)} – ${_formatTime(end)}',
        palette: palette,
      ),
      Positioned(
        key: const ValueKey('creation-live'),
        left: horizontal.left,
        width: horizontal.width,
        top: (liveStart - _startMinute) / 60 * _hourHeight,
        height: math.max(2, (liveEnd - liveStart) / 60 * _hourHeight),
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: WeekGlassGeometry.corners,
              border: Border.all(
                color: palette.text.withValues(alpha: .32),
                width: .8,
              ),
            ),
          ),
        ),
      ),
    ];
  }

  ({double left, double width}) _landingGeometry([
    CalendarDayLayout? snapshot,
  ]) {
    final day = _dragTargetDate!;
    final events = (snapshot ?? _dayLayout(day)).events;
    final layout = layoutTimedEvents([
      for (final event in events)
        if (event.id != _dragLanding!.id) event,
      _dragLanding!,
    ])[_dragLanding!.id]!;
    final index = _visibleDays.indexOf(day);
    final horizontal = _laneGeometry(layout, index);
    return (left: index * _dayWidth + horizontal.left, width: horizontal.width);
  }

  // Only internal lanes need breathing room. The outside edges belong to the
  // calendar's own clip, so cards and placement hints can meet it precisely.
  ({double left, double width}) _laneGeometry(
    EventLaneLayout layout,
    int index,
  ) {
    final leftInset = index == 0 && layout.laneIndex == 0 ? 0.0 : 5.0;
    final rightInset =
        index == _visibleDays.length - 1 &&
            layout.laneIndex == layout.laneCount - 1
        ? 0.0
        : 5.0;
    return (
      left: layout.leftFraction * _dayWidth + leftInset,
      width: math.max(
        2,
        layout.widthFraction * _dayWidth - leftInset - rightInset,
      ),
    );
  }

  List<Widget> _buildMoveLanding(
    WeekGlassPalette palette,
    double gridHeight,
    CalendarDayLayout day,
  ) {
    final event = _dragLanding!;
    final geometry = _landingGeometry(day);
    final start = _relativeMinute(event.startLocal, _dragTargetDate!);
    final end = _relativeMinute(event.endLocal, _dragTargetDate!);
    final band = day.band(event, cache: false);
    return _placement(
      id: 'drop-target-${event.id}',
      left: geometry.left,
      top: band.$1,
      width: geometry.width,
      height: band.$2,
      gridHeight: gridHeight,
      range: '${_formatTime(start.round())} – ${_formatTime(end.round())}',
      palette: palette,
    );
  }

  Widget _buildCurrentTimeIndicator(WeekGlassPalette palette, DateTime date) {
    final now = DateTime.now();
    final minute = DateTime.utc(
      now.year,
      now.month,
      now.day,
      now.hour,
      now.minute,
    ).difference(DateTime.utc(date.year, date.month, date.day)).inMinutes;
    if (minute < _startMinute || minute > _endMinute) {
      return const SizedBox.shrink();
    }
    final top = ((minute - _startMinute) / 60) * _hourHeight;
    return Positioned(
      top: top,
      left: 0,
      right: 0,
      height: 1,
      child: IgnorePointer(
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(child: ColoredBox(color: palette.currentTime)),
            Positioned(
              left: -3,
              top: -3,
              child: Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: palette.currentTime,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: palette.currentTime.withValues(alpha: .2),
                      blurRadius: 0,
                      spreadRadius: 3,
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 5,
              top: -17,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: palette.currentTime,
                  borderRadius: WeekGlassGeometry.corners,
                ),
                child: Text(
                  _formatTime(minute),
                  style: TextStyle(
                    color: palette.onCurrentTime,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _createFromTap(DateTime date, double y) {
    if (_dragOriginal != null || _resizeOriginal != null) return;
    final startMinute = _minuteFromY(y);
    final start = _dateAtMinute(date, startMinute);
    final endMinute = _snapQuarter(
      startMinute + 60,
      minimum: startMinute + 15,
      maximum: _endMinute,
    );
    final end = _dateAtMinute(date, endMinute);
    openEventEditor(
      context,
      controller: widget.controller,
      date: date,
      start: start,
      end: end,
    );
  }

  void _beginSelection(DateTime date, double y) {
    if (_settling || _pinching) return;
    final start = _minuteFromY(y);
    if (widget.touchMode) HapticFeedback.lightImpact();
    _lastHapticTime = _dateAtMinute(date, start + 15);
    _lastHapticFrame = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    setState(() {
      _selectionDate = date;
      _selectionStart = start;
      _selectionEnd = math.min(_endMinute, start + 15);
      _selectionRawEnd = _selectionEnd!.toDouble();
    });
    _reportInteraction();
  }

  void _updateSelection(double y) {
    if (_selectionDate == null || _selectionStart == null) return;
    final current = _minuteFromY(y, allowEnd: true);
    _tickLanding(_dateAtMinute(_selectionDate!, current));
    _selectionEnd = current;
    _selectionRawEnd = (_startMinute + y / _hourHeight * 60).clamp(
      _startMinute.toDouble(),
      _endMinute.toDouble(),
    );
    _selectionFrame.value++;
  }

  void _finishSelection() {
    if (_pinching ||
        _selectionDate == null ||
        _selectionStart == null ||
        _selectionEnd == null) {
      return;
    }
    final date = _selectionDate!;
    final startMinute = math.min(_selectionStart!, _selectionEnd!);
    final endMinute = math.max(_selectionStart!, _selectionEnd!);
    final start = _dateAtMinute(date, startMinute);
    final end = _dateAtMinute(
      date,
      endMinute <= startMinute ? startMinute + 15 : endMinute,
    );
    setState(_clearSelection);
    _reportInteraction();
    if (end.isAfter(start)) {
      openEventEditor(
        context,
        controller: widget.controller,
        date: date,
        start: start,
        end: end,
      );
    }
  }

  void _clearSelection() {
    _selectionDate = null;
    _selectionStart = null;
    _selectionEnd = null;
    _selectionRawEnd = null;
  }

  int _snapQuarter(num value, {required num minimum, required num maximum}) {
    final first = (minimum / 15).ceil() * 15;
    final last = (maximum / 15).floor() * 15;
    if (first > last) return minimum.round();
    return ((value / 15).round() * 15).clamp(first, last).toInt();
  }

  int _minuteFromY(double y, {bool allowEnd = false}) => _snapQuarter(
    _startMinute + y / _hourHeight * 60,
    minimum: _startMinute,
    maximum: _endMinute - (allowEnd ? 0 : 15),
  );

  DateTime _dateAtMinute(DateTime date, num minute) =>
      DateTime(date.year, date.month, date.day).add(
        Duration(
          microseconds: (minute * Duration.microsecondsPerMinute).round(),
        ),
      );

  DateTime _nearestMinute(DateTime value) => DateTime(
    value.year,
    value.month,
    value.day,
    value.hour,
    value.minute,
  ).add(Duration(minutes: value.second >= 30 ? 1 : 0));

  Future<void> _saveGesture(CalendarEvent event) async {
    try {
      final scope = await askBatchEditScope(
        context,
        controller: widget.controller,
        edited: event,
      );
      if (!mounted || scope == null) return;
      if (scope.scope == BatchEditScope.batch) {
        await widget.controller.saveBatchChanges(event, fields: scope.fields);
      } else {
        await widget.controller.saveEvent(event);
      }
      if (widget.touchMode) HapticFeedback.lightImpact();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is ArgumentError ? error.message.toString() : '调整未保存，请重试。',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _beginEventMove(
    CalendarEvent event,
    int visibleIndex,
    Offset globalPosition,
  ) {
    if (_settling || _pinching) return;
    final box =
        _gridContentKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(globalPosition);
    if (widget.touchMode) HapticFeedback.lightImpact();
    _lastHapticTime = event.startLocal;
    _lastHapticFrame = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    setState(() {
      final layout =
          _dayLayout(_visibleDays[visibleIndex]).lanes[event.id] ??
          const EventLaneLayout(laneIndex: 0, laneCount: 1);
      final horizontal = _laneGeometry(layout, visibleIndex);
      _dragOriginLeft = visibleIndex * _dayWidth + horizontal.left;
      _dragVisualLeft = _dragOriginLeft;
      _dragCardWidth = horizontal.width;
      _returnMagnet = false;
      _leftOrigin = false;
      _dragTargetDate = _visibleDays[visibleIndex];
      _dragOriginal = event;
      _dragPreview = event;
      _dragLanding = event;
      _dragStartLocal = local;
      _dragStartVisibleIndex = visibleIndex;
      _selectedEventId = event.id;
    });
    _reportInteraction();
  }

  void _updateEventMove(Offset globalPosition) {
    final original = _dragOriginal;
    final startLocal = _dragStartLocal;
    if (original == null || startLocal == null || _settling) return;
    final box =
        _gridContentKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(globalPosition);
    final deltaX = local.dx - startLocal.dx;
    final deltaY = local.dy - startLocal.dy;
    final targetIndex = (local.dx / _dragDayWidth).floor().clamp(
      0,
      _visibleDays.length - 1,
    );
    final targetDate = _visibleDays[targetIndex];
    final initialStart = original.startLocal;
    final duration = original.duration;
    final originDay = _visibleDays[_dragStartVisibleIndex];
    final initialMinute = _relativeMinute(initialStart, originDay);
    final deltaMinutes = deltaY / _hourHeight * 60;
    final durationMinutes =
        duration.inMicroseconds / Duration.microsecondsPerMinute;
    final latestStart = math.max(_startMinute, _endMinute - durationMinutes);
    final targetMinute = (initialMinute + deltaMinutes).clamp(
      _startMinute,
      latestStart,
    );
    final nextStart = _dateAtMinute(targetDate, targetMinute);
    final nextEnd = nextStart.add(duration);
    // A small hysteresis zone makes the original position a reliable target,
    // independent of quarter-hour rounding, without chattering at its edge.
    final magneticRadius = _returnMagnet ? 7.0 : 4.5;
    final nearOrigin =
        targetIndex == _dragStartVisibleIndex &&
        deltaX.abs() <= math.min(18.0, _dayWidth * .2) &&
        deltaY.abs() <= magneticRadius;
    if (!nearOrigin) _leftOrigin = true;
    final returning = _leftOrigin && nearOrigin;
    final previousLanding = _dragLanding;
    _returnMagnet = returning;
    if (returning) {
      _dragVisualLeft = _dragOriginLeft;
      _dragTargetDate = originDay;
      _dragPreview = original;
      _dragLanding = original;
    } else {
      _dragVisualLeft = (_dragOriginLeft + deltaX).clamp(
        0.0,
        _dayWidth * _visibleDays.length - _dragCardWidth,
      );
      _dragTargetDate = targetDate;
      _dragPreview = original.withTimedRange(nextStart, nextEnd);
      final landingStart = _dateAtMinute(
        targetDate,
        _snapQuarter(targetMinute, minimum: _startMinute, maximum: latestStart),
      );
      _dragLanding = nearOrigin
          ? original
          : previousLanding?.startLocal == landingStart
          ? previousLanding
          : original.withTimedRange(landingStart, landingStart.add(duration));
    }
    if (previousLanding?.startUtc != _dragLanding!.startUtc ||
        previousLanding?.endUtc != _dragLanding!.endUtc) {
      _landingFrame.value++;
    }
    _dragFrame.value++;
    _tickLanding(_dragLanding!.startLocal);
  }

  void _tickLanding(DateTime landing) {
    if (!widget.touchMode || landing == _lastHapticTime) return;
    _lastHapticTime = landing;
    // One tick per new snap target, capped during quick sweeps. Returning to
    // an exact non-quarter origin remains a distinct, reliable snap target.
    final frame = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    if (frame - _lastHapticFrame < const Duration(milliseconds: 65)) return;
    _lastHapticFrame = frame;
    HapticFeedback.selectionClick();
  }

  void _clearGesture() {
    _dragOriginal = null;
    _dragPreview = null;
    _dragLanding = null;
    _dragStartLocal = null;
    _resizeOriginal = null;
    _resizePreview = null;
    _resizeStartGlobal = null;
    _settling = false;
    _returnMagnet = false;
  }

  Future<void> _cancelGesture() async {
    if (_settling || _pinching) return;
    final original = _dragOriginal;
    if (!widget.touchMode || original == null || _reduceMotion) {
      setState(_clearGesture);
      _reportInteraction();
      return;
    }
    // System cancellation must not silently persist the nearest quarter hour.
    // Return the inert preview to the exact original and never call save.
    setState(() {
      _settling = true;
      _dragTargetDate = _visibleDays[_dragStartVisibleIndex];
      _dragLanding = original;
      _dragPreview = original;
      _dragVisualLeft = _dragOriginLeft;
    });
    await _dropClock.forward(from: 0);
    if (mounted) {
      setState(_clearGesture);
      _reportInteraction();
    }
  }

  Future<void> _finishEventMove() async {
    final original = _dragOriginal;
    final landing = _dragLanding;
    if (original == null || landing == null || _settling || _pinching) return;
    final geometry = _landingGeometry();
    setState(() {
      _settling = true;
      _dragPreview = landing;
      _dragVisualLeft = geometry.left;
      _dragCardWidth = geometry.width;
    });
    await Future.wait([
      if (original.startUtc != landing.startUtc ||
          original.endUtc != landing.endUtc)
        _saveGesture(landing),
      if (!_reduceMotion) _dropClock.forward(from: 0),
    ]);
    if (!mounted) return;
    setState(_clearGesture);
    _reportInteraction();
  }

  void _beginResize(
    CalendarEvent event,
    Offset globalPosition,
    bool startEdge,
    DateTime date,
  ) {
    _resizeDay = date;
    setState(() {
      _resizeOriginal = event;
      _resizePreview = event;
      _resizeStartGlobal = globalPosition;
      _resizeStartEdge = startEdge;
      _selectedEventId = event.id;
    });
  }

  void _updateResize(Offset globalPosition) {
    final original = _resizeOriginal;
    final startPosition = _resizeStartGlobal;
    if (original == null || startPosition == null) return;
    final deltaY = globalPosition.dy - startPosition.dy;
    final deltaMinutes = deltaY / _hourHeight * 60;
    final start = original.startLocal;
    final end = original.endLocal;
    final anchor = _resizeDay ?? dateOnly(start);
    final startMinute = _relativeMinute(start, anchor);
    final endMinute = _relativeMinute(end, anchor);

    DateTime nextStart = start;
    DateTime nextEnd = end;
    if (_resizeStartEdge) {
      final nextMinute = (startMinute + deltaMinutes).clamp(
        _startMinute,
        endMinute - 1,
      );
      nextStart = _dateAtMinute(anchor, nextMinute);
    } else {
      final nextMinute = (endMinute + deltaMinutes).clamp(
        startMinute + 1,
        _endMinute,
      );
      nextEnd = _dateAtMinute(anchor, nextMinute);
    }
    _resizePreview = original.withTimedRange(nextStart, nextEnd);
    _resizeFrame.value++;
  }

  void _finishResize() {
    final original = _resizeOriginal;
    final preview = _resizePreview;
    setState(() {
      _resizeOriginal = null;
      _resizePreview = null;
      _resizeStartGlobal = null;
    });
    if (original == null || preview == null) return;
    final rounded = preview.withTimedRange(
      _nearestMinute(preview.startLocal),
      _nearestMinute(preview.endLocal),
    );
    if (original.startUtc != rounded.startUtc ||
        original.endUtc != rounded.endUtc) {
      _saveGesture(rounded);
    }
  }

  String _formatTime(int minute) => minute == 1440
      ? '24:00'
      : '${((minute ~/ 60) % 24).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';
}

class _CalendarTimeScrollController extends ScrollController {
  _CalendarTimeScrollController({required super.initialScrollOffset});

  double? zoomOffset;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _CalendarTimeScrollPosition(
    physics: physics,
    context: context,
    initialPixels: initialScrollOffset,
    oldPosition: oldPosition,
    controller: this,
  );
}

class _CalendarTimeScrollPosition extends ScrollPositionWithSingleContext {
  _CalendarTimeScrollPosition({
    required super.physics,
    required super.context,
    required super.initialPixels,
    required super.oldPosition,
    required this.controller,
  });

  final _CalendarTimeScrollController controller;

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final offset = controller.zoomOffset;
    if (offset != null) {
      controller.zoomOffset = null;
      correctPixels(offset.clamp(minScrollExtent, maxScrollExtent));
    }
    return super.applyContentDimensions(minScrollExtent, maxScrollExtent);
  }
}

class _ViewportEvent extends StatefulWidget {
  const _ViewportEvent({
    required this.viewport,
    required this.bounds,
    required this.forceActive,
    required this.builder,
  });

  final ValueListenable<Rect> viewport;
  final Rect bounds;
  final bool forceActive;
  final Widget Function(bool active) builder;

  @override
  State<_ViewportEvent> createState() => _ViewportEventState();
}

class _ViewportEventState extends State<_ViewportEvent> {
  late bool _active;
  bool get _visible =>
      widget.forceActive || widget.bounds.overlaps(widget.viewport.value);

  @override
  void initState() {
    super.initState();
    _active = _visible;
    widget.viewport.addListener(_viewportChanged);
  }

  @override
  void didUpdateWidget(_ViewportEvent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.viewport != widget.viewport) {
      oldWidget.viewport.removeListener(_viewportChanged);
      widget.viewport.addListener(_viewportChanged);
    }
    _active = _visible;
  }

  void _viewportChanged() {
    final next = _visible;
    if (next != _active) setState(() => _active = next);
  }

  @override
  void dispose() {
    widget.viewport.removeListener(_viewportChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_active);
}

class _GridPainter extends CustomPainter {
  const _GridPainter({
    required this.palette,
    required this.interval,
    required this.startMinute,
    required this.endMinute,
    required this.dayWidth,
    required this.weekendColumns,
    required this.topInset,
    required this.bottomInset,
  });

  final WeekGlassPalette palette;
  final int interval;
  final int startMinute;
  final int endMinute;
  final double dayWidth;
  final List<int> weekendColumns;
  final double topInset;
  final double bottomInset;

  @override
  void paint(Canvas canvas, Size size) {
    // The whole calendar shares one material. Column seams continue through
    // the optical insets, so the last tick never sits on a separate footer.
    final weekendPaint = Paint()
      ..color = palette.accent.withValues(alpha: .025);
    for (final index in weekendColumns) {
      canvas.drawRect(
        Rect.fromLTWH(index * dayWidth, 0, dayWidth, size.height),
        weekendPaint,
      );
    }
    final columnPaint = Paint()
      ..color = palette.line.withValues(alpha: .25)
      ..strokeWidth = .7;
    for (var x = dayWidth; x < size.width - .5; x += dayWidth) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), columnPaint);
    }
    final hourPaint = Paint()
      ..color = palette.gridLine.withValues(alpha: .30)
      ..strokeWidth = .7;
    final subPaint = Paint()
      ..color = palette.gridSubline.withValues(alpha: .20)
      ..strokeWidth = .7;

    final totalMinutes = endMinute - startMinute;
    final contentHeight = size.height - topInset - bottomInset;
    for (
      var minute = (startMinute / interval).ceil() * interval;
      minute < endMinute;
      minute += interval
    ) {
      if (minute == startMinute) continue;
      final y =
          topInset + (minute - startMinute) / totalMinutes * contentHeight;
      if (minute % 60 != 0 && contentHeight / (totalMinutes / 60) < 32) {
        continue;
      }
      final isHour = minute % 60 == 0;
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        isHour ? hourPaint : subPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) =>
      oldDelegate.palette != palette ||
      oldDelegate.interval != interval ||
      oldDelegate.startMinute != startMinute ||
      oldDelegate.endMinute != endMinute ||
      oldDelegate.dayWidth != dayWidth ||
      oldDelegate.topInset != topInset ||
      oldDelegate.bottomInset != bottomInset ||
      oldDelegate.weekendColumns.join(',') != weekendColumns.join(',');
}
