import 'dart:async';

import 'package:flutter/material.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

/// One real deadline drives both the progress line and dismissal. Actions are
/// ordinary buttons so accessible navigation cannot keep the notice forever.
void showTimedNotice(
  BuildContext context, {
  required String message,
  required String actionLabel,
  required Duration duration,
  required FutureOr<void> Function() onAction,
}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.removeCurrentSnackBar();
  late ScaffoldFeatureController<SnackBar, SnackBarClosedReason> notice;
  notice = messenger.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      width: (MediaQuery.sizeOf(context).width - 32).clamp(0.0, 380.0),
      padding: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: WeekGlassGeometry.shape,
      backgroundColor: Theme.of(context).colorScheme.surface
          .withValues(alpha: .98),
      // The content owns expiration, including while focus/hover is inside.
      duration: const Duration(days: 1),
      content: TimedNotice(
        message: message,
        actionLabel: actionLabel,
        duration: duration,
        onExpired: () => notice.close(),
        onAction: () async {
          notice.close();
          await onAction();
        },
      ),
    ),
  );
}

class TimedNotice extends StatefulWidget {
  const TimedNotice({
    super.key,
    required this.message,
    required this.actionLabel,
    required this.duration,
    required this.onAction,
    required this.onExpired,
  });
  final String message, actionLabel;
  final Duration duration;
  final FutureOr<void> Function() onAction;
  final VoidCallback onExpired;
  @override
  State<TimedNotice> createState() => _TimedNoticeState();
}

class _TimedNoticeState extends State<TimedNotice>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress;
  late final Timer _deadline;
  bool _acted = false;

  @override
  void initState() {
    super.initState();
    _progress = AnimationController(
      vsync: this,
      duration: widget.duration,
      animationBehavior: AnimationBehavior.preserve,
    )..forward();
    _deadline = Timer(widget.duration, () {
      if (!_acted && mounted) widget.onExpired();
    });
  }

  @override
  void dispose() {
    _deadline.cancel();
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 5, 10, 5),
        child: Row(
          children: [
            Expanded(
              child: Text(
                widget.message,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _acted
                  ? null
                  : () async {
                      _acted = true;
                      _deadline.cancel();
                      _progress.stop();
                      setState(() {});
                      await widget.onAction();
                    },
              child: Text(widget.actionLabel),
            ),
          ],
        ),
      ),
      AnimatedBuilder(
        animation: _progress,
        builder: (_, _) => Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: 1 - _progress.value,
            child: Container(
              key: const ValueKey('notice-progress'),
              height: 2,
              color: const Color(0xFF64B88A),
            ),
          ),
        ),
      ),
    ],
  );
}
