import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:weekglass_data/weekglass_data.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';
import 'package:weekglass_domain/weekglass_domain.dart';

import '../planner/planner_controller.dart';
import 'calendar_codec.dart';
import 'calendar_file_store.dart';
import 'calendar_pdf.dart';
import 'timetable_image_import_dialog.dart';

Future<void> openCalendarImport(
  BuildContext context,
  PlannerController controller,
) => showDialog<void>(
  context: context,
  builder: (_) => CalendarImportDialog(controller: controller),
);

Future<void> openCalendarExport(
  BuildContext context,
  PlannerController controller,
) => showDialog<void>(
  context: context,
  builder: (_) => CalendarExportDialog(controller: controller),
);

class CalendarImportDialog extends StatefulWidget {
  const CalendarImportDialog({super.key, required this.controller});
  final PlannerController controller;
  @override
  State<CalendarImportDialog> createState() => _CalendarImportDialogState();
}

class _CalendarImportDialogState extends State<CalendarImportDialog> {
  late DateTimeRange _range;
  String? _text, _name, _error;
  CalendarFileFormat? _format;
  CalendarImportResult? _preview;
  final _selected = <String>{};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final day = widget.controller.anchorDate;
    _range = DateTimeRange(
      start: DateTime(day.year, 1, 1),
      end: DateTime(day.year + 1, 12, 31),
    );
  }

  Future<List<CalendarEvent>> _existing() async {
    final repository = widget.controller.repository;
    final imported = repository is ImportedEventRepository
        ? await (repository as ImportedEventRepository).getImportedEvents(
            CalendarCodec.sourcePrefix,
          )
        : <CalendarEvent>[];
    return [...widget.controller.events, ...imported];
  }

  Future<CalendarImportResult> _parse() async => compute(
    _decode,
    _ImportRequest(
      _text!,
      _format!,
      widget.controller.timeZoneId,
      _range.start,
      DateTime(_range.end.year, _range.end.month, _range.end.day + 1),
      await _existing(),
    ),
  );

  Future<void> _chooseFile() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final file = await FilePicker.pickFile(
        dialogTitle: '选择日历文件',
        type: FileType.custom,
        allowedExtensions: ['ics', 'json', 'csv'],
        windowsOptions: const WindowsOptions(lockParentWindow: true),
      );
      if (file == null) return;
      if ((await file.length() ?? 0) > CalendarCodec.maxBytes) {
        throw const FormatException('文件超过 10 MB，请先拆分日历。');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final part in file.readAsByteStream()) {
        bytes.add(part);
        if (bytes.length > CalendarCodec.maxBytes) {
          throw const FormatException('文件超过 10 MB，请先拆分日历。');
        }
      }
      _format = switch (file.extension?.toLowerCase()) {
        'ics' => CalendarFileFormat.ics,
        'json' => CalendarFileFormat.json,
        'csv' => CalendarFileFormat.csv,
        _ => throw const FormatException('请选择 ICS、JSON 或 CSV 文件。'),
      };
      _text = CalendarCodec.decodeText(bytes.takeBytes());
      _name = file.name;
      final result = await _parse();
      if (!mounted) return;
      setState(() {
        _preview = result;
        _selected
          ..clear()
          ..addAll(result.events.map((e) => e.id));
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = _message(error);
          _preview = null;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changeRange() async {
    final range = await _pickRange(context, _range, maximumDays: 731);
    if (range == null || !mounted) return;
    setState(() {
      _range = range;
      _busy = true;
      _error = null;
    });
    try {
      if (_text != null) {
        final result = await _parse();
        if (mounted) {
          setState(() {
            _preview = result;
            _selected
              ..clear()
              ..addAll(result.events.map((e) => e.id));
          });
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = _message(error);
          _preview = null;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Refresh after the preview: another window/device may have synced while
      // the dialog was open. Skip new duplicates before the atomic write.
      final current = await _parse();
      final events = current.events
          .where((e) => _selected.contains(e.id))
          .toList();
      if (events.isEmpty) throw const FormatException('所选日程已在日历中，无需重复导入。');
      final conflicts = events
          .where((e) => !widget.controller.sleep.allows(e))
          .length;
      if (conflicts > 0) {
        throw FormatException('$conflicts 项日程与睡眠时间重叠。请取消勾选这些日程，或先在设置中调整睡眠时段。');
      }
      await widget.controller.saveEvents(events);
      if (!mounted) return;
      final controller = widget.controller;
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(
        SnackBar(
          content: Text('已导入 ${events.length} 项日程'),
          duration: const Duration(seconds: 5),
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
      Navigator.of(context).pop();
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final palette = WeekGlassPalette.of(context);
    return PopScope(
      canPop: !_busy,
      child: GlassAlertDialog(
        title: const Text('导入日程'),
        insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
        content: SizedBox(
          width: 620,
          height: (MediaQuery.sizeOf(context).height * .64).clamp(240, 570),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '支持课表截图与文字，以及 Apple、Outlook 等日历导出的 ICS、JSON / CSV。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () async {
                            final imported = await openTimetableImageImport(
                              context,
                              widget.controller,
                            );
                            if (imported == true && context.mounted) {
                              Navigator.pop(context);
                            }
                          },
                    icon: const Icon(Icons.image_outlined, size: 18),
                    label: const Text('课表图片 / 文字'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _chooseFile,
                    icon: const Icon(Icons.folder_open_rounded, size: 18),
                    label: Text(_name == null ? '选择文件' : '更换文件'),
                  ),
                  TextButton.icon(
                    onPressed: _busy ? null : _changeRange,
                    icon: const Icon(Icons.date_range_rounded, size: 18),
                    label: Text(_rangeLabel(_range)),
                  ),
                ],
              ),
              if (_name != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _name!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              const SizedBox(height: 8),
              Expanded(
                child: preview == null
                    ? Container(
                        decoration: palette.glassDecoration(),
                        padding: const EdgeInsets.all(18),
                        child: const Center(
                          child: Text(
                            '选择文件后先核对预览。\n相同日程会自动跳过，导入后可撤销。\n\nCSV 列：名称、开始、结束、备注、颜色、时区\n时间示例：2026-11-06 08:00',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : ListView(
                        children: [
                          Container(
                            decoration: palette.glassDecoration(),
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '可导入 ${preview.events.length} 项 · 重复 ${preview.duplicateCount} 项 · 跳过 ${preview.skippedCount} 项',
                                ),
                                if (preview.messages.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: Text(
                                      preview.messages.join('\n'),
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (preview.events.isNotEmpty)
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => setState(() {
                                        if (_selected.length ==
                                            preview.events.length) {
                                          _selected.clear();
                                        } else {
                                          _selected.addAll(
                                            preview.events.map((e) => e.id),
                                          );
                                        }
                                      }),
                                child: Text(
                                  _selected.length == preview.events.length
                                      ? '全不选'
                                      : '全选',
                                ),
                              ),
                            ),
                          for (final event in preview.events)
                            CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                              value: _selected.contains(event.id),
                              onChanged: _busy
                                  ? null
                                  : (checked) => setState(() {
                                      checked == true
                                          ? _selected.add(event.id)
                                          : _selected.remove(event.id);
                                    }),
                              title: Text(
                                event.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${DateFormat('M月d日 HH:mm').format(event.startLocal)} — ${DateFormat('M月d日 HH:mm').format(event.endLocal)}${widget.controller.sleep.allows(event) ? '' : ' · 与睡眠重叠'}',
                              ),
                            ),
                          if (preview.events.isEmpty)
                            const Padding(
                              padding: EdgeInsets.all(24),
                              child: Text(
                                '没有新的日程可导入。',
                                textAlign: TextAlign.center,
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: _busy || _selected.isEmpty || preview == null
                ? null
                : _save,
            child: Text('导入 ${_selected.length} 项'),
          ),
        ],
      ),
    );
  }
}

enum CalendarExportFormat { colorPdf, monochromePdf, ics, json, csv }

class CalendarExportDialog extends StatefulWidget {
  const CalendarExportDialog({super.key, required this.controller});
  final PlannerController controller;
  @override
  State<CalendarExportDialog> createState() => _CalendarExportDialogState();
}

class _CalendarExportDialogState extends State<CalendarExportDialog> {
  late DateTimeRange _range;
  var _format = CalendarExportFormat.colorPdf;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final start = widget.controller.weekStart;
    _range = DateTimeRange(
      start: start,
      end: DateTime(start.year, start.month, start.day + 6),
    );
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final end = DateTime(
        _range.end.year,
        _range.end.month,
        _range.end.day + 1,
      );
      final events = widget.controller.events
          .where(
            (e) =>
                !e.isAllDay &&
                e.deletedAtUtc == null &&
                e.startLocal.isBefore(end) &&
                e.endLocal.isAfter(_range.start),
          )
          .toList();
      final pdf =
          _format == CalendarExportFormat.colorPdf ||
          _format == CalendarExportFormat.monochromePdf;
      final extension = pdf ? 'pdf' : _format.name;
      final bytes = pdf
          ? await compute(
              _renderPdf,
              _PdfRequest(
                events,
                _range.start,
                end,
                widget.controller.timeZoneId,
                await rootBundle.load('assets/fonts/NotoSansSC-Variable.ttf'),
                _format == CalendarExportFormat.monochromePdf,
              ),
            )
          : Uint8List.fromList(
              utf8.encode(
                CalendarCodec().encode(
                  events,
                  CalendarFileFormat.values.byName(extension),
                ),
              ),
            );
      final saved = await saveCalendarFile(
        bytes: bytes,
        suggestedName:
            'WeekGlass-${DateFormat('yyyyMMdd').format(_range.start)}${pdf ? (_format == CalendarExportFormat.monochromePdf ? '-黑白' : '-彩色') : ''}.$extension',
        extension: extension,
        mimeType: pdf
            ? 'application/pdf'
            : extension == 'ics'
            ? 'text/calendar'
            : extension == 'json'
            ? 'application/json'
            : 'text/csv',
      );
      if (saved == null || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已导出 ${events.length} 项日程'),
          duration: const Duration(seconds: 4),
        ),
      );
      Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: GlassAlertDialog(
      title: const Text('导出日历'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
      content: SizedBox(
        width: 470,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final format in CalendarExportFormat.values)
                    ChoiceChip(
                      label: Text(switch (format) {
                        CalendarExportFormat.colorPdf => '彩色 PDF',
                        CalendarExportFormat.monochromePdf => '黑白 PDF',
                        CalendarExportFormat.ics => 'ICS',
                        CalendarExportFormat.json => 'JSON',
                        CalendarExportFormat.csv => 'CSV',
                      }),
                      selected: _format == format,
                      onSelected: _busy
                          ? null
                          : (_) => setState(() => _format = format),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                decoration: WeekGlassPalette.of(context).glassDecoration(),
                child: ListTile(
                  leading: const Icon(Icons.date_range_rounded),
                  title: const Text('日期范围'),
                  subtitle: Text(_rangeLabel(_range)),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _busy
                      ? null
                      : () async {
                          final range = await _pickRange(
                            context,
                            _range,
                            maximumDays: 365,
                          );
                          if (range != null && mounted) {
                            setState(() => _range = range);
                          }
                        },
                ),
              ),
              const SizedBox(height: 12),
              Text(switch (_format) {
                CalendarExportFormat.colorPdf => 'A4 横向周表',
                CalendarExportFormat.monochromePdf => '按周列出时间和备注，适合黑白打印。',
                CalendarExportFormat.ics => '兼容主流日历；已展开的周/月日程按各次时间导出。',
                CalendarExportFormat.json =>
                  '保留名称、时间、颜色、备注与批次，可重新导入 WeekGlass。',
                CalendarExportFormat.csv => '可用表格软件查看和编辑，中文以 UTF-8 保存。',
              }, style: Theme.of(context).textTheme.bodySmall),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('导出')),
      ],
    ),
  );
}

String _rangeLabel(DateTimeRange range) =>
    '${DateFormat('yyyy/M/d').format(range.start)} — ${DateFormat('yyyy/M/d').format(range.end)}';
String _message(Object error) {
  final message = error is FormatException
      ? error.message.toString()
      : error is StateError
      ? error.message.toString()
      : '';
  return RegExp(r'[\u4e00-\u9fff]').hasMatch(message)
      ? message
      : '未能完成操作，请检查文件格式或保存位置后重试。';
}

Future<DateTimeRange?> _pickRange(
  BuildContext context,
  DateTimeRange current, {
  required int maximumDays,
}) async {
  final range = await showDateRangePicker(
    context: context,
    initialDateRange: current,
    firstDate: DateTime(1970),
    lastDate: DateTime(2100),
    helpText: '选择日期范围',
    saveText: '确定',
    locale: const Locale('zh', 'CN'),
  );
  if (range != null && range.duration.inDays > maximumDays) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('日期范围不能超过 ${maximumDays + 1} 天')));
    }
    return null;
  }
  return range;
}

class _ImportRequest {
  const _ImportRequest(
    this.text,
    this.format,
    this.zone,
    this.start,
    this.end,
    this.existing,
  );
  final String text, zone;
  final CalendarFileFormat format;
  final DateTime start, end;
  final List<CalendarEvent> existing;
}

CalendarImportResult _decode(_ImportRequest r) => CalendarCodec().decode(
  text: r.text,
  format: r.format,
  timeZoneId: r.zone,
  rangeStart: r.start,
  rangeEnd: r.end,
  existing: r.existing,
);

class _PdfRequest {
  const _PdfRequest(
    this.events,
    this.start,
    this.end,
    this.zone,
    this.font,
    this.monochrome,
  );
  final List<CalendarEvent> events;
  final DateTime start, end;
  final String zone;
  final ByteData font;
  final bool monochrome;
}

Future<Uint8List> _renderPdf(_PdfRequest r) => CalendarPdf.build(
  events: r.events,
  rangeStart: r.start,
  rangeEnd: r.end,
  timeZoneId: r.zone,
  chineseFont: r.font,
  monochrome: r.monochrome,
);
