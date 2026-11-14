import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

/// Places notes outside the whole event, including tall or edge-aligned cards.
class NotesHover extends StatefulWidget {
  const NotesHover({
    super.key,
    required this.id,
    required this.notes,
    required this.child,
    this.title,
    this.time,
    this.enabled = true,
  });
  final String id;
  final String notes;
  final String? title;
  final String? time;
  final Widget child;
  final bool enabled;
  @override
  State<NotesHover> createState() => _NotesHoverState();
}

class _NotesHoverState extends State<NotesHover> {
  final _portal = OverlayPortalController();
  Timer? _delay;
  bool _inside = false;
  bool _pressed = false;

  void _schedule() {
    if (!widget.enabled ||
        !_inside ||
        _pressed ||
        _portal.isShowing ||
        _delay != null) {
      return;
    }
    _delay = Timer(const Duration(milliseconds: 320), () {
      _delay = null;
      if (mounted && _inside && !_pressed && widget.enabled) _portal.show();
    });
  }

  void _hide() {
    _delay?.cancel();
    _delay = null;
    if (_portal.isShowing) _portal.hide();
  }

  @override
  void didUpdateWidget(covariant NotesHover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled ||
        widget.notes != oldWidget.notes ||
        widget.title != oldWidget.title ||
        widget.time != oldWidget.time) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _hide();
      });
    }
  }

  @override
  void dispose() {
    _delay?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => OverlayPortal.overlayChildLayoutBuilder(
    controller: _portal,
    overlayChildBuilder: (context, info) {
      final anchor = MatrixUtils.transformRect(
        info.childPaintTransform,
        Offset.zero & info.childSize,
      );
      final plan = _NotesPosition.plan(anchor, info.overlaySize);
      if (plan == null) return const SizedBox.shrink();
      final dark = Theme.of(context).brightness == Brightness.dark;
      final palette = WeekGlassPalette.of(context);
      final scale = MediaQuery.textScalerOf(context);
      final headerHeight = widget.title == null ? 0.0 : scale.scale(64) + 12;
      final maxLines =
          ((plan.maxHeight - 24 - headerHeight) / scale.scale(13 * 1.7))
              .floor()
              .clamp(1, 8);
      return IgnorePointer(
        child: CustomSingleChildLayout(
          delegate: plan,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 120),
            builder: (_, opacity, child) =>
                Opacity(opacity: opacity, child: child),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: WeekGlassGeometry.corners,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: dark ? .24 : .12),
                    blurRadius: 20,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: WeekGlassGeometry.corners,
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: Container(
                    key: ValueKey('notes-popover-${widget.id}'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: palette.glassDecoration(elevated: true),
                    child: ClipRect(
                      child: SingleChildScrollView(
                        physics: const NeverScrollableScrollPhysics(),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (widget.title != null) ...[
                              Text(
                                widget.title!,
                                maxLines: 4,
                                overflow: TextOverflow.ellipsis,
                                key: ValueKey('hover-title-${widget.id}'),
                                style: TextStyle(
                                  color: palette.text,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  height: 1.4,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                widget.time!,
                                key: ValueKey('hover-time-${widget.id}'),
                                style: TextStyle(
                                  color: palette.muted,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 9),
                              Divider(height: 1, color: palette.line),
                              const SizedBox(height: 9),
                            ],
                            Text(
                              widget.notes.trim().isEmpty
                                  ? '暂无备注'
                                  : widget.notes.trim(),
                              maxLines: maxLines,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'WeekGlassSans',
                                color: palette.text,
                                fontSize: 13,
                                height: 1.7,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          ],
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
    child: Listener(
      onPointerDown: (_) {
        _pressed = true;
        _hide();
      },
      onPointerUp: (_) => _pressed = false,
      onPointerCancel: (_) {
        _pressed = false;
        _hide();
      },
      child: MouseRegion(
        onEnter: (_) {
          _inside = true;
          _schedule();
        },
        onHover: (_) => _schedule(),
        onExit: (_) {
          _inside = false;
          _hide();
        },
        child: widget.child,
      ),
    ),
  );
}

enum _Side { right, left, below, above }

class _NotesPosition extends SingleChildLayoutDelegate {
  const _NotesPosition(
    this.anchor,
    this.safe,
    this.side,
    this.width,
    this.maxHeight,
  );
  final Rect anchor;
  final Rect safe;
  final _Side side;
  final double width;
  final double maxHeight;
  static const gap = 16.0;

  static _NotesPosition? plan(Rect anchor, Size viewport) {
    final safe = Rect.fromLTWH(
      12,
      12,
      math.max(0, viewport.width - 24),
      math.max(0, viewport.height - 24),
    );
    final right = safe.right - anchor.right - gap;
    final left = anchor.left - safe.left - gap;
    if (math.max(right, left) >= 180 && safe.height >= 52) {
      final side = right >= 288 || right >= left ? _Side.right : _Side.left;
      final available = side == _Side.right ? right : left;
      return _NotesPosition(
        anchor,
        safe,
        side,
        math.min(320, available),
        math.min(380, safe.height),
      );
    }
    final below = safe.bottom - anchor.bottom - gap;
    final above = anchor.top - safe.top - gap;
    if (math.max(below, above) < 52 || safe.width < 100) return null;
    final side = below >= above ? _Side.below : _Side.above;
    return _NotesPosition(
      anchor,
      safe,
      side,
      math.min(320, safe.width),
      math.min(380, side == _Side.below ? below : above),
    );
  }

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(minWidth: width, maxWidth: width, maxHeight: maxHeight);

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final y = (anchor.center.dy - childSize.height / 2).clamp(
      safe.top,
      safe.bottom - childSize.height,
    );
    final x = (anchor.center.dx - childSize.width / 2).clamp(
      safe.left,
      safe.right - childSize.width,
    );
    return switch (side) {
      _Side.right => Offset(anchor.right + gap, y),
      _Side.left => Offset(anchor.left - gap - childSize.width, y),
      _Side.below => Offset(x, anchor.bottom + gap),
      _Side.above => Offset(x, anchor.top - gap - childSize.height),
    };
  }

  @override
  bool shouldRelayout(covariant _NotesPosition oldDelegate) =>
      anchor != oldDelegate.anchor ||
      safe != oldDelegate.safe ||
      side != oldDelegate.side;
}
