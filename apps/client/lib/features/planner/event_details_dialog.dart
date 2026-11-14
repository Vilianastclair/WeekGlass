import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

import 'event_editor_dialog.dart';
import 'planner_controller.dart';
import 'timed_notice.dart';

enum _DetailAction { adjust, copy }

Future<void> openEventDetails(
  BuildContext context, {
  required PlannerController controller,
  required CalendarEvent event,
}) async {
  final result = await showDialog<Object>(
    context: context,
    animationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : null,
    barrierColor: Colors.black.withValues(alpha: .25),
    builder: (_) => _EventDetails(controller: controller, event: event),
  );
  if (!context.mounted) return;
  if (result == _DetailAction.adjust) {
    await openEventEditor(context, controller: controller, event: event);
  } else if (result == _DetailAction.copy) {
    await openEventEditor(context, controller: controller, copyFrom: event);
  } else if (result is DeletionReceipt) {
    final messenger = ScaffoldMessenger.of(context);
    showTimedNotice(
      context,
      message: '已删除 ${result.count} 条日程',
      actionLabel: '撤销',
      duration: const Duration(seconds: 5),
      onAction: () async {
        try {
          await controller.undoDeletion(result);
        } catch (error) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                error is StateError ? error.message.toString() : '撤销失败，请重试。',
              ),
            ),
          );
        }
      },
    );
  }
}

class _EventDetails extends StatefulWidget {
  const _EventDetails({required this.controller, required this.event});
  final PlannerController controller;
  final CalendarEvent event;

  @override
  State<_EventDetails> createState() => _EventDetailsState();
}

class _EventDetailsState extends State<_EventDetails> {
  bool _busy = false;
  String? _error;

  Future<void> _delete() async {
    final event = widget.event;
    final isBatch = event.seriesId != null;
    final future = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface
            .withValues(alpha: .97),
        title: const Text('确认删除日程？'),
        content: Text(
          isBatch
              ? '本条开始于 ${DateFormat('y年M月d日 HH:mm').format(event.startLocal)}。\n此条及之后共有 ${widget.controller.batchFrom(event).length} 条同批日程。'
              : '将删除“${event.title.isEmpty ? '预留时间' : event.title}”。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(isBatch ? '仅删除本日程' : '确认删除'),
          ),
          if (isBatch)
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除此后所有同批日程'),
            ),
        ],
      ),
    );
    if (future == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final receipt = await widget.controller.deleteEvent(
        event.id,
        futureInBatch: future,
      );
      if (mounted) Navigator.pop(context, receipt);
    } catch (_) {
      if (mounted) setState(() => _error = '删除失败，日程已保留。请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = WeekGlassPalette.of(context);
    final event = widget.event;
    final notes = event.notes?.trim();
    final time =
        '${DateFormat('M月d日 EEEE', 'zh_CN').format(event.startLocal)}\n'
        '${DateFormat('HH:mm').format(event.startLocal)} — '
        '${DateFormat(dateOnly(event.startLocal) == dateOnly(event.endLocal) ? 'HH:mm' : 'M月d日 HH:mm').format(event.endLocal)}';
    return PopScope(
      canPop: !_busy,
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        backgroundColor: Colors.transparent,
        child: ClipRRect(
          borderRadius: WeekGlassGeometry.corners,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              width: 460,
              constraints: const BoxConstraints(maxHeight: 540),
              padding: const EdgeInsets.all(24),
              decoration: palette.glassDecoration(elevated: true),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 10, right: 10),
                        child: Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: palette.eventColor(
                              event.color.key,
                              selected: true,
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          event.title.isEmpty ? '预留时间' : event.title,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.text,
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        visualDensity: VisualDensity.compact,
                        onPressed: _busy ? null : () => Navigator.pop(context),
                        icon: Icon(
                          Icons.close_rounded,
                          size: 19,
                          color: palette.muted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    time,
                    style: TextStyle(
                      color: palette.muted,
                      fontSize: 12,
                      height: 1.7,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Divider(color: palette.line, height: 1),
                  const SizedBox(height: 18),
                  Flexible(
                    child: SingleChildScrollView(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 120),
                        child: SelectableText(
                          notes == null || notes.isEmpty
                              ? '暂无备注'
                              : event.notes!,
                          style: TextStyle(
                            color: notes == null || notes.isEmpty
                                ? palette.muted
                                : palette.text,
                            fontSize: 15,
                            height: 1.85,
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  const SizedBox(height: 20),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final actions = <Widget>[
                        TextButton.icon(
                          onPressed: _busy ? null : _delete,
                          style: TextButton.styleFrom(
                            foregroundColor: Theme.of(context)
                                .colorScheme
                                .error,
                          ),
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            size: 17,
                          ),
                          label: const Text('删除'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _busy
                              ? null
                              : () =>
                                    Navigator.pop(context, _DetailAction.copy),
                          icon: const Icon(
                            Icons.content_copy_rounded,
                            size: 16,
                          ),
                          label: const Text('复制'),
                        ),
                        FilledButton.icon(
                          onPressed: _busy
                              ? null
                              : () => Navigator.pop(
                                  context,
                                  _DetailAction.adjust,
                                ),
                          icon: const Icon(Icons.tune_rounded, size: 17),
                          label: const Text('调整'),
                        ),
                      ];
                      if (constraints.maxWidth <
                          MediaQuery.textScalerOf(context).scale(300)) {
                        return Wrap(
                          alignment: WrapAlignment.end,
                          spacing: 8,
                          runSpacing: 4,
                          children: actions,
                        );
                      }
                      return Row(
                        children: [
                          actions[0],
                          const Spacer(),
                          actions[1],
                          const SizedBox(width: 8),
                          actions[2],
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
