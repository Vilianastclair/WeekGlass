import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

import 'notes_hover.dart';
import '../mobile/mobile_press_feedback.dart';

class GlassEventCard extends StatefulWidget {
  const GlassEventCard({
    super.key,
    required this.event,
    required this.selected,
    this.preview = false,
    this.touchMode = false,
    this.materialActive = true,
    required this.onTap,
    required this.onMoveStart,
    required this.onMoveUpdate,
    required this.onMoveEnd,
    required this.onCancel,
    required this.onResizeStart,
    required this.onResizeUpdate,
    required this.onResizeEnd,
  });

  final CalendarEvent event;
  final bool selected;
  final bool preview;
  final bool touchMode;
  final bool materialActive;
  final VoidCallback onTap;
  final ValueChanged<Offset> onMoveStart;
  final ValueChanged<Offset> onMoveUpdate;
  final VoidCallback onMoveEnd;
  final VoidCallback onCancel;
  final void Function(Offset, bool) onResizeStart;
  final ValueChanged<Offset> onResizeUpdate;
  final VoidCallback onResizeEnd;

  @override
  State<GlassEventCard> createState() => _GlassEventCardState();
}

class _GlassEventCardState extends State<GlassEventCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final palette = WeekGlassPalette.of(context);
    final ink = palette.eventColor(widget.event.color.key, selected: true);
    final eventTitle = widget.event.title.trim();
    final title = eventTitle.isEmpty ? '预留时间' : eventTitle;
    final time =
        '${_time(widget.event.startLocal)} – ${_time(widget.event.endLocal)}';
    final active = _hovered || widget.selected || widget.preview;
    final notes = widget.event.notes?.trim() ?? '';
    return LayoutBuilder(
      builder: (context, bounds) {
        final text = _CardTextPlan(context, bounds, title, time, palette, ink);
        return Listener(
          onPointerCancel: (_) => widget.onCancel(),
          child: Semantics(
            container: true,
            button: true,
            excludeSemantics: true,
            label: '$title，$time',
            hint: widget.touchMode ? '轻点查看或调整，长按后拖动时间' : null,
            onTap: widget.onTap,
            child: NotesHover(
              id: widget.event.id,
              notes: notes,
              title: text.overflow ? title : null,
              time: text.overflow ? time : null,
              enabled: !widget.preview && !widget.touchMode,
              child: MouseRegion(
                cursor: widget.preview
                    ? SystemMouseCursors.grabbing
                    : SystemMouseCursors.grab,
                onEnter: widget.touchMode
                    ? null
                    : (_) => setState(() => _hovered = true),
                onExit: widget.touchMode
                    ? null
                    : (_) => setState(() => _hovered = false),
                child: GestureDetector(
                  dragStartBehavior: DragStartBehavior.down,
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onTap,
                  onPanStart: widget.touchMode
                      ? null
                      : (details) {
                          Tooltip.dismissAllToolTips();
                          widget.onMoveStart(details.globalPosition);
                        },
                  onPanUpdate: widget.touchMode
                      ? null
                      : (details) =>
                            widget.onMoveUpdate(details.globalPosition),
                  onPanEnd: widget.touchMode ? null : (_) => widget.onMoveEnd(),
                  onPanCancel: widget.touchMode ? null : widget.onCancel,
                  onLongPressStart: widget.touchMode
                      ? (details) {
                          Tooltip.dismissAllToolTips();
                          widget.onMoveStart(details.globalPosition);
                        }
                      : null,
                  onLongPressMoveUpdate: widget.touchMode
                      ? (details) => widget.onMoveUpdate(details.globalPosition)
                      : null,
                  onLongPressEnd: widget.touchMode
                      ? (_) => widget.onMoveEnd()
                      : null,
                  child: MobilePressFeedback(
                    key: ValueKey('mobile-card-press-${widget.event.id}'),
                    enabled: widget.touchMode && !widget.preview,
                    scale: .985,
                    child: GlassShadow(
                      radius: WeekGlassGeometry.radius,
                      shadows: [
                        BoxShadow(
                          color: palette.shadow.withValues(
                            alpha: dark
                                ? (active ? .36 : .24)
                                : (active ? .19 : .12),
                          ),
                          blurRadius: active ? 20 : 12,
                          offset: Offset(0, active ? 8 : 5),
                        ),
                        if (active)
                          BoxShadow(
                            color: ink.withValues(alpha: dark ? .08 : .04),
                            blurRadius: 18,
                          ),
                      ],
                      child: LiquidGlassSurface(
                        active: widget.materialActive,
                        colorKey: widget.event.color.key,
                        child: LayoutBuilder(
                          builder: (context, size) => _content(
                            size,
                            title: title,
                            time: time,
                            notes: notes,
                            palette: palette,
                            ink: ink,
                            text: text,
                          ),
                        ),
                      ),
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

  Widget _content(
    BoxConstraints size, {
    required String title,
    required String time,
    required String notes,
    required WeekGlassPalette palette,
    required Color ink,
    required _CardTextPlan text,
  }) {
    return Stack(
      children: [
        if (text.showTitle)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: text.inset),
              child: text.compact
                  ? Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            key: ValueKey('card-title-${widget.event.id}'),
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                            style: text.titleStyle,
                          ),
                        ),
                        if (text.showTime) ...[
                          const SizedBox(width: _CardTextPlan.inlineGap),
                          Text(
                            time,
                            key: ValueKey('card-time-${widget.event.id}'),
                            maxLines: 1,
                            style: text.timeStyle,
                          ),
                        ],
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          key: ValueKey('card-title-${widget.event.id}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleStyle,
                        ),
                        const SizedBox(height: 5),
                        Text(
                          time,
                          key: ValueKey('card-time-${widget.event.id}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.timeStyle,
                        ),
                        if (size.maxHeight >=
                                120 *
                                    MediaQuery.textScalerOf(context).scale(1) &&
                            notes.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text(
                            notes.replaceAll('\n', ' '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.muted,
                              fontSize: 11,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ],
                    ),
            ),
          ),
        if (size.maxHeight >= 16 && !widget.touchMode) ...[
          for (final top in [true, false])
            _edge(
              top: top,
              visible: _hovered && !widget.preview && size.maxHeight >= 24,
              ink: ink,
              hitHeight: size.maxHeight < 24 ? 3 : 6,
            ),
        ],
      ],
    );
  }

  Widget _edge({
    required bool top,
    required bool visible,
    required Color ink,
    required double hitHeight,
  }) => Positioned(
    top: top ? 0 : null,
    bottom: top ? null : 0,
    left: 0,
    right: 0,
    height: hitHeight,
    child: MouseRegion(
      cursor: SystemMouseCursors.resizeUpDown,
      child: GestureDetector(
        dragStartBehavior: DragStartBehavior.down,
        behavior: HitTestBehavior.translucent,
        onTap: widget.onTap,
        onPanStart: (details) {
          Tooltip.dismissAllToolTips();
          widget.onResizeStart(details.globalPosition, top);
        },
        onPanUpdate: (details) => widget.onResizeUpdate(details.globalPosition),
        onPanEnd: (_) => widget.onResizeEnd(),
        onPanCancel: widget.onCancel,
        child: Center(
          child: AnimatedOpacity(
            opacity: visible ? .65 : 0,
            duration: const Duration(milliseconds: 120),
            child: Container(
              width: 18,
              height: 1.5,
              decoration: BoxDecoration(
                color: ink,
                borderRadius: WeekGlassGeometry.corners,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  String _time(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
}

class _CardTextPlan {
  static const inlineGap = 6.0;

  _CardTextPlan(
    BuildContext context,
    BoxConstraints size,
    String title,
    String time,
    WeekGlassPalette palette,
    Color ink,
  ) {
    final scaler = MediaQuery.textScalerOf(context);
    inset = size.maxWidth < 92 ? 8 : 12;
    final available = (size.maxWidth - inset * 2).clamp(0.0, double.infinity);
    titleStyle = TextStyle(
      fontFamily: 'WeekGlassSans',
      color: palette.text,
      fontSize: size.maxHeight >= 64 ? 14 : 12.5,
      fontWeight: FontWeight.w500,
      fontVariations: const [FontVariation('wght', 480)],
      height: 1.15,
      letterSpacing: .15,
    );
    timeStyle = TextStyle(
      fontFamily: 'WeekGlassSans',
      color: ink.withValues(alpha: .88),
      fontSize: 10.5,
      height: 1.15,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    ({Size size, bool exceedsOneLine}) measure(String value, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(
          text: value,
          style: DefaultTextStyle.of(context).style.merge(style),
        ),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final result = (
        size: painter.size,
        exceedsOneLine: painter.didExceedMaxLines,
      );
      painter.dispose();
      return result;
    }

    // Measure a fixed sample so titles with different glyphs have the same
    // visibility thresholds at a given card size and text scale.
    final sample = measure('日程信息', titleStyle).size;
    if (size.maxHeight < 24 ||
        size.maxHeight < sample.height + 8 ||
        available < sample.width / 2) {
      compact = true;
      showTitle = false;
      showTime = false;
      overflow = true;
      return;
    }
    final titleLine = measure(title, titleStyle);
    final timeSize = measure(time, timeStyle).size;
    compact = size.maxHeight < sample.height + timeSize.height + 11;

    var titleSpace = available;
    var inlineTime =
        compact && available >= sample.width + inlineGap + timeSize.width;
    if (inlineTime) titleSpace -= inlineGap + timeSize.width;

    var titleVisible = true;
    if (titleLine.exceedsOneLine || titleLine.size.width > titleSpace) {
      // A wide first grapheme (for example an emoji) still needs room beside
      // the ellipsis. Reclaim the time slot before hiding the title.
      final firstWithEllipsis = measure(
        '${title.characters.first}…',
        titleStyle,
      ).size.width;
      if (firstWithEllipsis > titleSpace) {
        inlineTime = false;
        titleSpace = available;
        titleVisible =
            firstWithEllipsis <= titleSpace ||
            (!titleLine.exceedsOneLine && titleLine.size.width <= titleSpace);
      }
    }
    showTitle = titleVisible;
    showTime = showTitle && (!compact || inlineTime);
    overflow =
        !showTitle ||
        !showTime ||
        titleLine.exceedsOneLine ||
        titleLine.size.width > titleSpace ||
        timeSize.width > available;
  }
  late final double inset;
  late final bool compact, showTitle, showTime, overflow;
  late final TextStyle titleStyle, timeStyle;
}
