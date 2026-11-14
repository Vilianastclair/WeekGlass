import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

import 'planner_controller.dart';

enum BatchEditScope { current, batch }

class BatchEditChoice {
  const BatchEditChoice(this.scope, [this.fields = const {}]);
  final BatchEditScope scope;
  final Set<BatchEditField> fields;
}

/// A null result cancels this save without discarding the editor's draft.
Future<BatchEditChoice?> askBatchEditScope(
  BuildContext context, {
  required PlannerController controller,
  required CalendarEvent edited,
}) async {
  final fields = controller.batchChangedFields(edited);
  final selected = fields.toSet();
  final count = controller.batchEvents(edited).length;
  if (count < 2 || fields.isEmpty) {
    return const BatchEditChoice(BatchEditScope.current);
  }
  return showDialog<BatchEditChoice>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black.withValues(alpha: .22),
    builder: (context) => StatefulBuilder(
      builder: (context, setSelection) {
        final palette = WeekGlassPalette.of(context);
        return Dialog(
          key: const ValueKey('batch-edit-scope'),
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
          child: ClipRRect(
            borderRadius: WeekGlassGeometry.corners,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Container(
                width: 380,
                decoration: palette.glassDecoration(elevated: true),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '将修改应用到？',
                        style: TextStyle(
                          color: palette.text,
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '已调整${fields.map((e) => e.label).join('、')}',
                        style: TextStyle(
                          color: palette.accentStrong,
                          fontSize: 13,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '同批共 $count 条，包含本条之前与之后的日程。\n'
                        '${fields.length > 1 ? '本条保存全部修改，其他日程只同步勾选项。' : '同步${fields.single.label}，其他内容保持原样。'}',
                        style: TextStyle(
                          color: palette.muted,
                          fontSize: 12,
                          height: 1.7,
                        ),
                      ),
                      if (fields.length > 1) ...[
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            for (final field in fields)
                              FilterChip(
                                key: ValueKey('sync-${field.name}'),
                                label: Text(
                                  field.label,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: selected.contains(field)
                                        ? palette.text
                                        : palette.muted,
                                  ),
                                ),
                                selected: selected.contains(field),
                                selectedColor: palette.accentStrong.withValues(
                                  alpha: .18,
                                ),
                                checkmarkColor: palette.accentStrong,
                                side: BorderSide(
                                  color: selected.contains(field)
                                      ? palette.accentStrong.withValues(
                                          alpha: .45,
                                        )
                                      : palette.lineStrong,
                                ),
                                onSelected: (value) => setSelection(() {
                                  if (value) {
                                    selected.add(field);
                                  } else {
                                    selected.remove(field);
                                  }
                                }),
                              ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 18),
                      FilledButton(
                        onPressed: selected.isEmpty
                            ? null
                            : () => Navigator.pop(
                                context,
                                BatchEditChoice(
                                  BatchEditScope.batch,
                                  Set.of(selected),
                                ),
                              ),
                        style: FilledButton.styleFrom(
                          backgroundColor: palette.accentStrong,
                          foregroundColor:
                              Theme.of(context).brightness == Brightness.dark
                              ? Theme.of(context).colorScheme.onPrimary
                              : Colors.white,
                          minimumSize: const Size.fromHeight(42),
                        ),
                        child: const Text('修改同批日程'),
                      ),
                      const SizedBox(height: 9),
                      OutlinedButton(
                        onPressed: () => Navigator.pop(
                          context,
                          const BatchEditChoice(BatchEditScope.current),
                        ),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(42),
                        ),
                        child: const Text('仅修改本日程'),
                      ),
                      const SizedBox(height: 6),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('返回调整'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}
