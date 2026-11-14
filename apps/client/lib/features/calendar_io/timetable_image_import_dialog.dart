import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:weekglass_data/weekglass_data.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

import '../course_import/whu_timetable.dart';
import '../planner/planner_controller.dart';
import 'calendar_codec.dart';
import 'timetable_image_parser.dart';
import 'timetable_ocr_service.dart';

Future<bool?> openTimetableImageImport(
  BuildContext context,
  PlannerController controller,
) => showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (_) => TimetableImageImportDialog(controller: controller),
);

class TimetableImageImportDialog extends StatefulWidget {
  const TimetableImageImportDialog({
    super.key,
    required this.controller,
    this.ocr = const TimetableOcrService(),
    this.initialText = '',
  });
  final PlannerController controller;
  final TimetableOcrService ocr;
  final String initialText;
  @override
  State<TimetableImageImportDialog> createState() =>
      _TimetableImageImportDialogState();
}

class _TimetableImageImportDialogState
    extends State<TimetableImageImportDialog> {
  final _text = TextEditingController();
  final _firstMonday = TextEditingController();
  final _weeks = TextEditingController();
  final _clock = TextEditingController();
  final _scroll = ScrollController();
  final _courses = <_CourseEditor>[];
  final _selected = <String>{};
  List<String> _messages = [];
  Uint8List? _image;
  String? _imageName, _error;
  bool _busy = false, _reviewed = false, _sourceDirty = false;
  CalendarImportResult? _preview;

  @override
  void initState() {
    super.initState();
    _text.text = widget.initialText;
    if (widget.initialText.isNotEmpty) {
      _accept(TimetableImageParser().parseText(widget.initialText));
    }
  }

  @override
  void dispose() {
    for (final editor in _courses) {
      editor.dispose();
    }
    for (final input in [_text, _firstMonday, _weeks, _clock]) {
      input.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  void _changed() => setState(() {
    _preview = null;
    _reviewed = false;
    _error = null;
  });

  void _accept(TimetableRecognition recognition) {
    for (final editor in _courses) {
      editor.dispose();
    }
    _courses.clear();
    _courses.addAll(recognition.courses.map(_CourseEditor.new));
    _messages = recognition.messages;
    _preview = null;
    _reviewed = false;
    _sourceDirty = false;
    _selected.clear();
  }

  Future<void> _work(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseImage() => _work(() async {
    final file = await FilePicker.pickFile(
      dialogTitle: '选择课表图片',
      type: FileType.custom,
      allowedExtensions: [
        'png',
        'jpg',
        'jpeg',
        'webp',
        'bmp',
        'gif',
        'tif',
        'tiff',
      ],
      windowsOptions: const WindowsOptions(lockParentWindow: true),
    );
    if (file == null) return;
    if ((await file.length() ?? 0) > TimetableOcrService.maxImageBytes) {
      throw const FormatException('请选择不超过 25 MB 的课表图片。');
    }
    final builder = BytesBuilder(copy: false);
    await for (final part in file.readAsByteStream()) {
      builder.add(part);
      if (builder.length > TimetableOcrService.maxImageBytes) {
        throw const FormatException('请选择不超过 25 MB 的课表图片。');
      }
    }
    await _recognize(builder.takeBytes(), file.name);
  });

  Future<void> _pasteImage() => _work(() async {
    final image = await widget.ocr.clipboardImage();
    if (image == null) {
      throw const FormatException('剪贴板没有图片。可复制截图后重试，或使用“粘贴文字”。');
    }
    await _recognize(image, '剪贴板图片');
  });

  Future<void> _recognize(Uint8List image, String name) async {
    if (mounted) {
      setState(() {
        _image = image;
        _imageName = name;
        _text.clear();
        _accept(const TimetableRecognition([], []));
      });
    }
    final page = await widget.ocr.recognize(image);
    if (!mounted) return;
    final parsed = TimetableImageParser().parseOcr(page);
    setState(() {
      _text.text = page.text;
      _accept(parsed);
      if (page.text.trim().isEmpty) _error = '没有识别到文字。请换用清晰图片，或在下方输入课表。';
    });
  }

  Future<void> _pasteText() => _work(() async {
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    if (clipboard == null || clipboard.text?.trim().isEmpty != false) {
      throw const FormatException('剪贴板没有文字。');
    }
    final text = clipboard.text!;
    final parsed = TimetableImageParser().parseText(text);
    setState(() {
      _image = null;
      _imageName = null;
      _text.text = text;
      _accept(parsed);
    });
  });

  void _parseText() {
    try {
      setState(() {
        _error = null;
        _accept(TimetableImageParser().parseText(_text.text));
      });
    } catch (error) {
      setState(() => _error = _message(error));
    }
  }

  Future<void> _pickMonday() async {
    final current = DateTime.tryParse(_firstMonday.text);
    final anchor = current ?? widget.controller.anchorDate;
    final monday = DateTime(
      anchor.year,
      anchor.month,
      anchor.day - anchor.weekday + 1,
    );
    final chosen = await showDatePicker(
      context: context,
      initialDate: monday,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: '选择第一教学周的周一',
      selectableDayPredicate: (day) => day.weekday == DateTime.monday,
    );
    if (chosen != null && mounted) {
      setState(() {
        _firstMonday.text = DateFormat('yyyy-MM-dd').format(chosen);
        _preview = null;
        _reviewed = false;
      });
    }
  }

  TimetableImportPlan _plan() {
    final text = _firstMonday.text.trim();
    final date = DateTime.tryParse(text);
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text) ||
        date == null ||
        DateFormat('yyyy-MM-dd').format(date) != text) {
      throw const FormatException('请明确填写第一教学周的周一，格式为 YYYY-MM-DD。');
    }
    return TimetableImportPlan(
      courses: _courses
          .where((course) => course.included)
          .map((course) => course.value)
          .toList(),
      firstMonday: date,
      totalWeeks: int.tryParse(_weeks.text.trim()) ?? 0,
      clock: TimetableImportPlan.parseClock(_clock.text),
      timeZoneId: widget.controller.timeZoneId,
    );
  }

  Future<List<CalendarEvent>> _existing() async {
    final repository = widget.controller.repository;
    return [
      ...await repository.getAllEvents(),
      if (repository is ImportedEventRepository)
        ...await (repository as ImportedEventRepository).getImportedEvents(
          CalendarCodec.sourcePrefix,
        ),
    ];
  }

  Future<void> _makePreview() => _work(() async {
    if (_sourceDirty) {
      throw const FormatException('识别原文已修改，请先点“按文字重新整理课程”，再核对下方课程。');
    }
    if (!_reviewed) throw const FormatException('请先核对课程、第一教学周和节次时刻，再勾选确认。');
    final plan = _plan();
    final preview = plan.preview(existing: await _existing());
    if (!mounted) return;
    setState(() {
      _preview = preview;
      _selected
        ..clear()
        ..addAll(preview.events.map((event) => event.id));
    });
    _scroll.jumpTo(0);
  });

  Future<void> _save() => _work(() async {
    final current = _plan().preview(existing: await _existing());
    final events = current.events
        .where((event) => _selected.contains(event.id))
        .toList();
    if (events.isEmpty) throw const FormatException('所选课程日程已在日历中，无需重复导入。');
    final conflicts = events
        .where((event) => !widget.controller.sleep.allows(event))
        .length;
    if (conflicts > 0) {
      throw FormatException('$conflicts 项与睡眠时段重叠，请先取消勾选这些日程或调整睡眠时间。');
    }
    await widget.controller.saveEvents(events);
    if (!mounted) return;
    final controller = widget.controller;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context, true);
    messenger.showSnackBar(
      SnackBar(
        content: Text('已导入 ${events.length} 项课程日程'),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () async {
            try {
              await controller.undo();
            } catch (error) {
              if (messenger.mounted) {
                messenger.showSnackBar(
                  SnackBar(content: Text(_message(error))),
                );
              }
            }
          },
        ),
      ),
    );
  });

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return PopScope(
      canPop: !_busy,
      child: GlassAlertDialog(
        title: Text(preview == null ? '从课表图片导入' : '核对课程日程'),
        insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
        content: SizedBox(
          width: 760,
          height: (MediaQuery.sizeOf(context).height * .69).clamp(230, 680),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: preview == null
                    ? SingleChildScrollView(
                        controller: _scroll,
                        child: _review(),
                      )
                    : _previewList(preview),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          if (preview != null)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _preview = null;
                      _reviewed = false;
                    }),
              child: const Text('返回修改'),
            ),
          FilledButton(
            onPressed: _busy
                ? null
                : preview == null
                ? (_courses.isEmpty || !_reviewed ? null : _makePreview)
                : (_selected.isEmpty ? null : _save),
            child: Text(
              preview == null ? '生成日程预览' : '导入 ${_selected.length} 项',
            ),
          ),
        ],
      ),
    );
  }

  Widget _review() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        widget.ocr.supportsImages
            ? '本地识别，图片不会上传。支持 PNG、JPEG、WebP、BMP、GIF、TIFF；动画仅识别首帧。'
            : '当前平台可粘贴或填写课表文字并核对导入。图片本地识别暂在 Windows 提供。',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (widget.ocr.supportsImages)
            OutlinedButton.icon(
              onPressed: _busy ? null : _chooseImage,
              icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
              label: const Text('选择课表图片'),
            ),
          if (widget.ocr.supportsImages)
            OutlinedButton.icon(
              onPressed: _busy ? null : _pasteImage,
              icon: const Icon(Icons.content_paste_rounded, size: 18),
              label: const Text('粘贴图片'),
            ),
          TextButton.icon(
            onPressed: _busy ? null : _pasteText,
            icon: const Icon(Icons.text_snippet_outlined, size: 18),
            label: const Text('粘贴文字'),
          ),
        ],
      ),
      if (_image != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${_imageName ?? '课表图片'} · 可缩放核对',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 210,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: InteractiveViewer(
                    minScale: .5,
                    maxScale: 5,
                    child: Image.memory(
                      _image!,
                      fit: BoxFit.contain,
                      cacheWidth: 1300,
                      errorBuilder: (_, _, _) =>
                          const Center(child: Text('此图片格式无法缩略预览，识别结果仍可在下方核对。')),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ExpansionTile(
        key: ValueKey('timetable-raw-${_courses.isEmpty}'),
        title: const Text('识别原文 / 手动填写'),
        initiallyExpanded: _courses.isEmpty,
        tilePadding: EdgeInsets.zero,
        children: [
          TextField(
            key: const Key('timetable-source-text'),
            controller: _text,
            enabled: !_busy,
            onChanged: (_) => setState(() {
              _sourceDirty = true;
              _reviewed = false;
              _preview = null;
            }),
            minLines: 4,
            maxLines: 8,
            maxLength: TimetableImageParser.maxTextLength,
            decoration: const InputDecoration(
              labelText: '课表文字',
              hintText: '高等数学 | 周一 | 1-2节 | 1-16周 | 教一101 | 张老师\n大学物理 | 周三 | 3-4节 | 2-16周(双) | 实验楼201',
              alignLabelWithHint: true,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _busy ? null : _parseText,
              child: const Text('按文字重新整理课程'),
            ),
          ),
          const Text(
            '每门课程用空行分隔。重新整理会替换下方课程核对项。',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
      for (final message in _messages)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(message, style: Theme.of(context).textTheme.bodySmall),
        ),
      const SizedBox(height: 18),
      Text('1  核对课程', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      if (_courses.isEmpty) const Text('选择图片或整理文字后，课程会出现在这里。也可以直接添加课程。'),
      for (var index = 0; index < _courses.length; index++) _courseCard(index),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _busy
              ? null
              : () => setState(() {
                  _courses.add(
                    _CourseEditor(
                      const TimetableCourseDraft(
                        title: '',
                        weekday: null,
                        periodText: '',
                        weekText: '',
                      ),
                    ),
                  );
                  _preview = null;
                  _reviewed = false;
                }),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('添加一门课程'),
        ),
      ),
      const SizedBox(height: 14),
      Text('2  确认学期与时刻', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 10),
      TextField(
        key: const Key('timetable-first-monday'),
        controller: _firstMonday,
        enabled: !_busy,
        onChanged: (_) => _changed(),
        decoration: InputDecoration(
          labelText: '第一教学周的周一',
          hintText: 'YYYY-MM-DD，必须明确填写',
          suffixIcon: IconButton(
            onPressed: _busy ? null : _pickMonday,
            icon: const Icon(Icons.calendar_month_outlined),
          ),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        key: const Key('timetable-total-weeks'),
        controller: _weeks,
        enabled: !_busy,
        keyboardType: TextInputType.number,
        onChanged: (_) => _changed(),
        decoration: const InputDecoration(
          labelText: '学期总周数',
          hintText: '例如 16；每门课程仍按自己的周次重复',
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        key: const Key('timetable-clock'),
        controller: _clock,
        enabled: !_busy,
        minLines: 3,
        maxLines: 6,
        onChanged: (_) => _changed(),
        decoration: const InputDecoration(
          labelText: '每节课的时刻',
          hintText: '1 08:00-08:45\n2 08:50-09:35\n3 09:50-10:35',
          alignLabelWithHint: true,
        ),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                  _clock.text = [
                    for (var i = 0; i < ClassPeriod.standard.length; i++)
                      '${i + 1} ${ClassPeriod.clock(ClassPeriod.standard[i].start)}-${ClassPeriod.clock(ClassPeriod.standard[i].end)}',
                  ].join('\n');
                  _preview = null;
                  _reviewed = false;
                }),
          child: const Text('填入武大参考节次，再核对'),
        ),
      ),
      Text(
        '按 ${widget.controller.timeZoneId} 排程；日期、重复周次和时刻都以本页确认内容为准。',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      CheckboxListTile(
        key: const Key('timetable-confirm'),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: _reviewed,
        onChanged: _busy
            ? null
            : (value) => setState(() => _reviewed = value == true),
        title: const Text('已逐项核对课程，并确认第一周、重复周次和节次时刻'),
      ),
    ],
  );

  Widget _courseCard(int index) {
    final editor = _courses[index];
    Widget input(
      TextEditingController controller,
      String label,
      String hint,
      String suffix,
    ) => TextField(
      key: Key('timetable-course-$index-$suffix'),
      controller: controller,
      enabled: !_busy && editor.included,
      onChanged: (_) => _changed(),
      decoration: InputDecoration(labelText: label, hintText: hint),
    );
    return Container(
      key: ObjectKey(editor),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: WeekGlassPalette.of(context).glassDecoration(),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(top: 8),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        shape: const Border(),
        collapsedShape: const Border(),
        initiallyExpanded:
            editor.title.text.isEmpty ||
            editor.day == null ||
            editor.periods.text.isEmpty ||
            editor.weeks.text.isEmpty,
        title: Text(
          editor.title.text.isEmpty
              ? '课程 ${index + 1} · 待填写'
              : editor.title.text,
        ),
        subtitle: Text(
          '${editor.day == null ? '星期待填写' : '周${'一二三四五六日'[editor.day! - 1]}'} · ${editor.periods.text.isEmpty ? '节次待填写' : '${editor.periods.text}节'} · ${editor.weeks.text.isEmpty ? '周次待填写' : editor.weeks.text}\n点开核对与修改',
        ),
        leading: Checkbox(
          value: editor.included,
          onChanged: _busy
              ? null
              : (value) => setState(() {
                  editor.included = value == true;
                  _preview = null;
                  _reviewed = false;
                }),
        ),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '课程 ${index + 1}${editor.source.layoutSuggestion ? ' · 表格识别待核对' : ''}',
                ),
              ),
              IconButton(
                tooltip: '移除此课程',
                onPressed: _busy
                    ? null
                    : () => setState(() {
                        _courses.removeAt(index).dispose();
                        _reviewed = false;
                        _preview = null;
                      }),
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
          input(editor.title, '课程名称', '填写课程名称', 'title'),
          const SizedBox(height: 10),
          DropdownButtonFormField<int>(
            key: Key('timetable-course-$index-day-${editor.day}'),
            initialValue: editor.day,
            decoration: const InputDecoration(labelText: '星期'),
            hint: const Text('请选择'),
            items: [
              for (var day = 1; day <= 7; day++)
                DropdownMenuItem(
                  value: day,
                  child: Text('周${'一二三四五六日'[day - 1]}'),
                ),
            ],
            onChanged: _busy || !editor.included
                ? null
                : (value) => setState(() {
                    editor.day = value;
                    _reviewed = false;
                    _preview = null;
                  }),
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final children = [
                input(editor.periods, '节次', '1-2 或 1、3', 'periods'),
                input(editor.weeks, '重复周次', '1-16周 / 2-16周(双)', 'weeks'),
              ];
              if (constraints.maxWidth < 430) {
                return Column(
                  children: [
                    children[0],
                    const SizedBox(height: 10),
                    children[1],
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: children[0]),
                  const SizedBox(width: 10),
                  Expanded(child: children[1]),
                ],
              );
            },
          ),
          const SizedBox(height: 10),
          input(editor.room, '地点（可选）', '', 'room'),
          const SizedBox(height: 10),
          input(editor.teacher, '教师（可选）', '', 'teacher'),
          if (editor.source.sourceText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '原文：${editor.source.sourceText}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }

  Widget _previewList(CalendarImportResult preview) => ListView.builder(
    controller: _scroll,
    itemCount: preview.events.length + 1,
    itemBuilder: (context, index) {
      if (index > 0) {
        final event = preview.events[index - 1];
        return CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _selected.contains(event.id),
          onChanged: _busy
              ? null
              : (value) => setState(() {
                  value == true
                      ? _selected.add(event.id)
                      : _selected.remove(event.id);
                }),
          title: Text(event.title),
          subtitle: Text(
            '${DateFormat('M月d日 E HH:mm', 'zh_CN').format(event.startLocal)}—${DateFormat('HH:mm').format(event.endLocal)}${event.notes?.isNotEmpty == true ? '\n${event.notes}' : ''}${widget.controller.sleep.allows(event) ? '' : '\n与睡眠时段重叠'}',
          ),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '可导入 ${preview.events.length} 项 · 重复 ${preview.duplicateCount} 项',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            '第一周：${_firstMonday.text} · 学期 ${_weeks.text} 周。课程已展开为具体日期，保存前还会再次去重。',
          ),
          const SizedBox(height: 8),
          if (preview.events.isNotEmpty)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                        if (_selected.length == preview.events.length) {
                          _selected.clear();
                        } else {
                          _selected.addAll(
                            preview.events.map((event) => event.id),
                          );
                        }
                      }),
                child: Text(
                  _selected.length == preview.events.length ? '全不选' : '全选',
                ),
              ),
            ),
          if (preview.events.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text('没有新的日程可导入。'),
            ),
        ],
      );
    },
  );

  static String _message(Object error) => switch (error) {
    FormatException() => error.message,
    ArgumentError() => error.message.toString(),
    _ => '操作未完成，请重试。已有日程未改变。',
  };
}

class _CourseEditor {
  _CourseEditor(this.source)
    : title = TextEditingController(text: source.title),
      periods = TextEditingController(text: source.periodText),
      weeks = TextEditingController(text: source.weekText),
      room = TextEditingController(text: source.room),
      teacher = TextEditingController(text: source.teacher),
      day = source.weekday;
  final TimetableCourseDraft source;
  final TextEditingController title, periods, weeks, room, teacher;
  int? day;
  bool included = true;
  TimetableCourseDraft get value => TimetableCourseDraft(
    title: title.text,
    weekday: day,
    periodText: periods.text,
    weekText: weeks.text,
    room: room.text,
    teacher: teacher.text,
  );
  void dispose() {
    for (final controller in [title, periods, weeks, room, teacher]) {
      controller.dispose();
    }
  }
}
