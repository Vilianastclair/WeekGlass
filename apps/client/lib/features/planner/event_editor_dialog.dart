import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'package:weekglass_domain/weekglass_domain.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

import 'planner_controller.dart';
import 'timed_notice.dart';
import 'batch_edit_scope_dialog.dart';

Future<void> openEventEditor(
  BuildContext context, {
  required PlannerController controller,
  CalendarEvent? event,
  CalendarEvent? copyFrom,
  DateTime? date,
  DateTime? start,
  DateTime? end,
}) async {
  await showDialog<void>(
    context: context,
    animationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : null,
    barrierDismissible: false,
    barrierColor: Colors.black.withValues(alpha: 0.22),
    builder: (_) => EventEditorDialog(
      controller: controller,
      event: event,
      copyFrom: copyFrom,
      onCopyAgain: copyFrom == null
          ? null
          : (source) {
              if (context.mounted) {
                openEventEditor(
                  context,
                  controller: controller,
                  copyFrom: source,
                );
              }
            },
      date: date ?? DateTime.now(),
      start: start,
      end: end,
    ),
  );
}

class EventEditorDialog extends StatefulWidget {
  const EventEditorDialog({
    super.key,
    required this.controller,
    required this.date,
    this.event,
    this.copyFrom,
    this.onCopyAgain,
    this.start,
    this.end,
  });

  final PlannerController controller;
  final CalendarEvent? event;
  final CalendarEvent? copyFrom;
  final ValueChanged<CalendarEvent>? onCopyAgain;
  final DateTime date;
  final DateTime? start;
  final DateTime? end;

  @override
  State<EventEditorDialog> createState() => _EventEditorDialogState();
}

class _EventEditorDialogState extends State<EventEditorDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _notesController;
  late DateTime _date;
  late TimeOfDay _startTime;
  late TimeOfDay _endTime;
  late EventColor _color;
  String? _error;
  bool _saving = false;
  int _copyEndDayOffset = 0;
  RepeatFrequency _frequency = RepeatFrequency.none;
  int _weekCount = 16;
  late DateTime _until;
  late Set<int> _weekdays;
  bool get _converting =>
      widget.event != null && _frequency != RepeatFrequency.none;
  RepeatPlan get _plan => RepeatPlan(
    frequency: _frequency,
    until: _frequency == RepeatFrequency.weekly
        ? DateTime(
            _date.year,
            _date.month,
            _date.day - (_date.weekday - 1) + _weekCount * 7 - 1,
          )
        : _until,
    weekdays: _weekdays,
  );
  int get _repeatCount {
    try {
      final dates = _plan.datesFrom(_date);
      return dates.length + (_converting && !dates.contains(_date) ? 1 : 0);
    } catch (_) {
      return 0;
    }
  }

  @override
  void initState() {
    super.initState();
    final event = widget.event ?? widget.copyFrom;
    if (widget.copyFrom != null) {
      _copyEndDayOffset =
          DateTime.utc(
                event!.endLocal.year,
                event.endLocal.month,
                event.endLocal.day,
              )
              .difference(
                DateTime.utc(
                  event.startLocal.year,
                  event.startLocal.month,
                  event.startLocal.day,
                ),
              )
              .inDays;
    }
    _titleController = TextEditingController(text: event?.title ?? '');
    _notesController = TextEditingController(text: event?.notes ?? '');
    _date = dateOnly(event?.startLocal ?? widget.start ?? widget.date);
    _until = DateTime(_date.year, _date.month + 3, _date.day);
    _weekdays = {_date.weekday};
    _frequency = RepeatFrequency.none;
    final start = event?.isAllDay == false ? event!.startLocal : widget.start;
    final end = event?.isAllDay == false ? event!.endLocal : widget.end;
    final visibleStart = widget.controller.sleep.visibleStart;
    final visibleEnd = widget.controller.sleep.visibleEnd;
    final defaultMinute = 540 >= visibleStart && 600 <= visibleEnd
        ? 540
        : visibleStart;
    _startTime = TimeOfDay.fromDateTime(
      start ?? DateTime(_date.year, _date.month, _date.day, 0, defaultMinute),
    );
    _endTime = TimeOfDay.fromDateTime(
      end ??
          DateTime(
            _date.year,
            _date.month,
            _date.day,
            0,
            (defaultMinute + 60).clamp(defaultMinute + 15, visibleEnd),
          ),
    );
    _color = event?.color ?? EventColor.mistBlue;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: '选择日期',
    );
    if (picked == null || !mounted) return;
    setState(() {
      final previousDay = _date.weekday;
      _date = dateOnly(picked);
      if (_weekdays.length == 1 && _weekdays.contains(previousDay)) {
        _weekdays = {_date.weekday};
      }
      _error = null;
    });
  }

  Future<void> _pickTime({required bool start}) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: start ? _startTime : _endTime,
      helpText: start ? '开始时间' : '结束时间',
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (start) {
        if (widget.copyFrom != null) {
          final span =
              _copyEndDayOffset * 1440 +
              _endTime.hour * 60 +
              _endTime.minute -
              _startTime.hour * 60 -
              _startTime.minute;
          if (span > 0) {
            final endMinute = picked.hour * 60 + picked.minute + span;
            _copyEndDayOffset = endMinute ~/ 1440;
            _endTime = TimeOfDay(
              hour: endMinute ~/ 60 % 24,
              minute: endMinute % 60,
            );
          }
        }
        _startTime = picked;
      } else {
        _endTime = picked;
      }
      _error = null;
    });
  }

  DateTime _atTime(TimeOfDay time) =>
      DateTime(_date.year, _date.month, _date.day, time.hour, time.minute);

  Future<void> _save() async {
    if (_saving) return;
    final title = _titleController.text.trim();
    final notes = _notesController.text.trim();
    final event = widget.event;
    final seed = event ?? widget.copyFrom;
    final id = event?.id ?? const Uuid().v4();
    final now = DateTime.now().toUtc();

    final timed = seed != null && !seed.isAllDay;
    DateTime preserveClock(DateTime value) => DateTime(
      _date.year,
      _date.month,
      _date.day,
      value.hour,
      value.minute,
      value.second,
      value.millisecond,
      value.microsecond,
    );
    final start = timed && _startTime == TimeOfDay.fromDateTime(seed.startLocal)
        ? preserveClock(seed.startLocal)
        : _atTime(_startTime);
    final endDay = widget.copyFrom != null
        ? _copyEndDayOffset
        : timed
        ? DateTime.utc(
                seed.endLocal.year,
                seed.endLocal.month,
                seed.endLocal.day,
              )
              .difference(
                DateTime.utc(
                  seed.startLocal.year,
                  seed.startLocal.month,
                  seed.startLocal.day,
                ),
              )
              .inDays
        : 0;
    var end = timed && _endTime == TimeOfDay.fromDateTime(seed.endLocal)
        ? preserveClock(seed.endLocal)
        : _atTime(_endTime);
    end = DateTime(
      end.year,
      end.month,
      end.day + endDay,
      end.hour,
      end.minute,
      end.second,
      end.millisecond,
      end.microsecond,
    );
    if (endDay == 0 &&
        _endTime.hour == 0 &&
        _endTime.minute == 0 &&
        start.hour > 0) {
      end = DateTime(_date.year, _date.month, _date.day + 1);
    }
    if (!end.isAfter(start)) {
      setState(() => _error = '结束时间须晚于开始时间。');
      return;
    }
    if (end.difference(start).inMinutes < 1) {
      setState(() => _error = '日程时长至少为 1 分钟。');
      return;
    }

    final result = CalendarEvent.timed(
      id: id,
      title: title,
      notes: notes.isEmpty ? null : notes,
      color: _color,
      startLocal: start,
      endLocal: end,
      timeZoneId: widget.controller.timeZoneId,
      importSource: event?.importSource,
      importFingerprint: event?.importFingerprint,
      recurrenceRule: event?.recurrenceRule,
      seriesId: event?.seriesId,
      createdAtUtc: event?.createdAtUtc,
      updatedAtUtc: now,
      version: (event?.version ?? 0) + 1,
    );
    await _commit(result);
  }

  Future<void> _commit(CalendarEvent event) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_frequency == RepeatFrequency.weekly &&
          (_weekCount < 1 || _weekCount > 520)) {
        throw ArgumentError('周数须为 1–520。');
      }
      final scope = await askBatchEditScope(
        context,
        controller: widget.controller,
        edited: event,
      );
      if (!mounted || scope == null) return;
      final int count;
      if (scope.scope == BatchEditScope.batch) {
        count = await widget.controller.saveBatchChanges(
          event,
          fields: scope.fields,
        );
      } else if (_converting) {
        count = await widget.controller.convertToRepeat(event, _plan);
      } else {
        final events = _frequency == RepeatFrequency.none
            ? [event]
            : expandRepeatedEvent(
                event,
                _plan,
                newId: () => const Uuid().v4(),
                seriesId: const Uuid().v4(),
              );
        if (events.isEmpty) throw ArgumentError('所选日期范围内没有符合条件的日程。');
        await widget.controller.saveEvents(events);
        count = events.length;
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      final palette = WeekGlassPalette.of(context);
      final noticeWidth = (MediaQuery.sizeOf(context).width - 32).clamp(
        0.0,
        340.0,
      );
      final copyAgain = widget.onCopyAgain;
      Navigator.of(context).pop();
      if (copyAgain != null) {
        showTimedNotice(
          context,
          message: '已复制 $count 条日程',
          actionLabel: '再复制',
          duration: const Duration(seconds: 3),
          onAction: () => copyAgain(event),
        );
        return;
      }
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            _converting
                ? '已改为${_frequency == RepeatFrequency.weekly ? '周' : '月'}日程 · 新增 ${count - 1} 条'
                : widget.copyFrom != null
                ? '已复制 $count 条日程'
                : '已保存 $count 条日程',
            style: TextStyle(color: palette.text),
          ),
          width: noticeWidth,
          backgroundColor: palette.surface.withValues(alpha: .97),
          shape: RoundedRectangleBorder(
            borderRadius: WeekGlassGeometry.corners,
            side: BorderSide(color: palette.line),
          ),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } on ArgumentError catch (error) {
      if (mounted) setState(() => _error = error.message.toString());
    } catch (_) {
      if (mounted) setState(() => _error = '保存失败，本次修改未生效。请重试。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _repeatControls(WeekGlassPalette palette) {
    if (widget.event?.seriesId != null ||
        widget.event?.recurrenceRule != null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<RepeatFrequency>(
            showSelectedIcon: false,
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              foregroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? Theme.of(context).colorScheme.onPrimary
                    : palette.text,
              ),
              backgroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? palette.accentStrong
                    : Colors.transparent,
              ),
            ),
            segments: [
              ButtonSegment(
                value: RepeatFrequency.none,
                label: Text(widget.event == null ? '单次' : '仅此日程'),
              ),
              ButtonSegment(
                value: RepeatFrequency.weekly,
                label: Text(widget.event == null ? '每周' : '改为周日程'),
              ),
              ButtonSegment(
                value: RepeatFrequency.monthly,
                label: Text(widget.event == null ? '每月' : '改为月日程'),
              ),
            ],
            selected: {_frequency},
            onSelectionChanged: _saving
                ? null
                : (value) => setState(() => _frequency = value.first),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            alignment: Alignment.topCenter,
            curve: Curves.easeOutCubic,
            child: _frequency == RepeatFrequency.none
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_frequency == RepeatFrequency.weekly) ...[
                          Text(
                            '星期',
                            style: TextStyle(
                              color: palette.muted,
                              fontSize: 11,
                            ),
                          ),
                          Wrap(
                            spacing: 4,
                            children: [
                              for (var day = 1; day <= 7; day++)
                                FilterChip(
                                  showCheckmark: false,
                                  visualDensity: VisualDensity.compact,
                                  selectedColor: palette.accentStrong,
                                  backgroundColor: palette.surfaceSoft,
                                  labelStyle: TextStyle(
                                    color: _weekdays.contains(day)
                                        ? Theme.of(context)
                                              .colorScheme
                                              .onPrimary
                                        : palette.text,
                                  ),
                                  label: Text(
                                    const [
                                      '一',
                                      '二',
                                      '三',
                                      '四',
                                      '五',
                                      '六',
                                      '日',
                                    ][day - 1],
                                  ),
                                  selected: _weekdays.contains(day),
                                  onSelected: _saving
                                      ? null
                                      : (selected) => setState(() {
                                          if (selected) {
                                            _weekdays.add(day);
                                          } else {
                                            _weekdays.remove(day);
                                          }
                                        }),
                                ),
                            ],
                          ),
                          Row(
                            children: [
                              const Text('连续 ', style: TextStyle(fontSize: 12)),
                              SizedBox(
                                width: 70,
                                child: TextFormField(
                                  key: const ValueKey('repeat-week-count'),
                                  initialValue: _weekCount.toString(),
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly,
                                  ],
                                  enabled: !_saving,
                                  style: const TextStyle(fontSize: 12),
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    contentPadding: EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 8,
                                    ),
                                  ),
                                  onChanged: (value) => setState(
                                    () => _weekCount = int.tryParse(value) ?? 0,
                                  ),
                                ),
                              ),
                              const Text(' 周', style: TextStyle(fontSize: 12)),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _converting
                                ? '本条保留；周数从此日期所在周算起，后续按所选星期安排。'
                                : '从所选日期所在周算起；首周只安排该日期及之后。',
                            style: TextStyle(
                              color: palette.muted,
                              fontSize: 11,
                            ),
                          ),
                        ] else ...[
                          TextButton(
                            onPressed: _saving
                                ? null
                                : () async {
                                    final until = await showDatePicker(
                                      context: context,
                                      initialDate: _until.isBefore(_date)
                                          ? _date
                                          : _until,
                                      firstDate: _date,
                                      lastDate: DateTime(2100),
                                      helpText: '截止日期（含当天）',
                                    );
                                    if (until != null && mounted) {
                                      setState(() => _until = until);
                                    }
                                  },
                            child: Text(
                              '截至 ${_until.year}/${_until.month}/${_until.day}',
                            ),
                          ),
                          Text(
                            '每月 ${_date.day} 日；没有该日期的月份自动跳过。',
                            style: TextStyle(
                              color: palette.muted,
                              fontSize: 11,
                            ),
                          ),
                        ],
                        const SizedBox(height: 6),
                        Text(
                          _converting
                              ? '保留本条，新增 ${(_repeatCount - 1).clamp(0, 2000)} 条日程'
                              : '共 $_repeatCount 条日程',
                          style: TextStyle(
                            color: palette.accentStrong,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = WeekGlassPalette.of(context);

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
      child: ClipRRect(
        borderRadius: WeekGlassGeometry.corners,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            width: 460,
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
            decoration: palette.glassDecoration(elevated: true),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.copyFrom != null
                                        ? '复制日程'
                                        : widget.event == null
                                        ? '新建日程'
                                        : '编辑日程',
                                    style: TextStyle(
                                      color: palette.text,
                                      fontSize: 21,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: -.8,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            _iconButton(
                              context,
                              icon: Icons.close_rounded,
                              onPressed: () {
                                if (!_saving) Navigator.of(context).pop();
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        _fieldLabel('标题', palette, optional: true),
                        const SizedBox(height: 7),
                        TextField(
                          controller: _titleController,
                          autofocus: true,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: const InputDecoration(
                            hintText: '留空即可预留一段时间',
                          ),
                        ),
                        const SizedBox(height: 16),
                        _dateField(
                          context,
                          label: '日期',
                          value: DateFormat(
                            'y年M月d日 EEEE',
                            'zh_CN',
                          ).format(_date),
                          onTap: _pickDate,
                          palette: palette,
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: _dateField(
                                context,
                                label: '开始时间',
                                value: _startTime.format(context),
                                onTap: () => _pickTime(start: true),
                                palette: palette,
                                icon: Icons.schedule_rounded,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _dateField(
                                context,
                                label: '结束时间',
                                value:
                                    '${widget.copyFrom != null && _copyEndDayOffset > 0 ? (_copyEndDayOffset == 1 ? '次日 ' : '$_copyEndDayOffset 天后 ') : ''}${_endTime.format(context)}',
                                onTap: () => _pickTime(start: false),
                                palette: palette,
                                icon: Icons.schedule_rounded,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 17),
                        _fieldLabel('日程颜色', palette),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 11,
                          runSpacing: 9,
                          children: EventColor.values.map((color) {
                            final selected = _color == color;
                            return Tooltip(
                              message: color.label,
                              child: InkWell(
                                borderRadius: WeekGlassGeometry.corners,
                                onTap: () => setState(() => _color = color),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 140),
                                  width: 27,
                                  height: 27,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: palette.eventColor(
                                      color.key,
                                      selected:
                                          Theme.of(context).brightness ==
                                          Brightness.dark,
                                    ),
                                    border: Border.all(
                                      color: selected
                                          ? palette.text
                                          : palette.lineStrong,
                                      width: selected ? 1.5 : 1,
                                    ),
                                    boxShadow: selected
                                        ? [
                                            BoxShadow(
                                              color: palette.accent.withValues(
                                                alpha: .18,
                                              ),
                                              blurRadius: 0,
                                              spreadRadius: 3,
                                            ),
                                          ]
                                        : null,
                                  ),
                                  child: selected
                                      ? Icon(
                                          Icons.check_rounded,
                                          size: 14,
                                          color:
                                              Theme.of(context).brightness ==
                                                  Brightness.dark
                                              ? Theme.of(context)
                                                    .colorScheme
                                                    .onPrimary
                                              : palette.eventColor(
                                                  color.key,
                                                  selected: true,
                                                ),
                                        )
                                      : null,
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                        _repeatControls(palette),
                        const SizedBox(height: 8),
                        Material(
                          type: MaterialType.transparency,
                          child: ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            childrenPadding: const EdgeInsets.only(bottom: 4),
                            visualDensity: VisualDensity.compact,
                            dense: true,
                            initiallyExpanded: _notesController.text.isNotEmpty,
                            title: Text(
                              '备注（选填）',
                              style: TextStyle(
                                color: palette.muted,
                                fontSize: 12,
                              ),
                            ),
                            children: [
                              TextField(
                                controller: _notesController,
                                minLines: 1,
                                maxLines: 3,
                                decoration: const InputDecoration(
                                  hintText: '记录想法、地点或准备事项…',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ),
                const SizedBox(height: 10),
                Divider(color: palette.line, height: 1),
                const SizedBox(height: 14),
                Row(
                  children: [
                    const Spacer(),
                    TextButton(
                      onPressed: () {
                        if (!_saving) Navigator.of(context).pop();
                      },
                      child: const Text('取消', style: TextStyle(fontSize: 13)),
                    ),
                    const SizedBox(width: 7),
                    FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      style: FilledButton.styleFrom(
                        backgroundColor: palette.accentStrong,
                        foregroundColor:
                            Theme.of(context).brightness == Brightness.dark
                            ? Theme.of(context).colorScheme.onPrimary
                            : Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 15,
                          vertical: 12,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: WeekGlassGeometry.corners,
                        ),
                      ),
                      icon: const Icon(Icons.check_rounded, size: 15),
                      label: Text(
                        widget.copyFrom == null ? '保存日程' : '创建副本',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _dateField(
    BuildContext context, {
    required String label,
    required String value,
    required VoidCallback onTap,
    required WeekGlassPalette palette,
    IconData icon = Icons.calendar_today_rounded,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: WeekGlassGeometry.corners,
      child: Container(
        constraints: const BoxConstraints(minHeight: 57),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
        decoration: BoxDecoration(
          color: palette.surfaceSoft,
          borderRadius: WeekGlassGeometry.corners,
          border: Border.all(color: palette.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: TextStyle(
                color: palette.mutedSoft,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: 5),
            Row(
              children: [
                Icon(icon, size: 13, color: palette.accent),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.text,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _fieldLabel(
    String value,
    WeekGlassPalette palette, {
    bool optional = false,
  }) {
    return Row(
      children: [
        Text(
          value,
          style: TextStyle(
            color: palette.muted,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.1,
          ),
        ),
        if (optional) ...[
          const SizedBox(width: 7),
          Text(
            '选填',
            style: TextStyle(
              color: palette.mutedSoft,
              fontSize: 9,
              letterSpacing: .8,
            ),
          ),
        ],
      ],
    );
  }

  Widget _iconButton(
    BuildContext context, {
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    final palette = WeekGlassPalette.of(context);
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, size: 17),
      color: palette.muted,
      splashRadius: 18,
      visualDensity: VisualDensity.compact,
    );
  }
}
