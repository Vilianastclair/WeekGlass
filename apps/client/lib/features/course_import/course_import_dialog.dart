import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weekglass_data/weekglass_data.dart';
import 'package:weekglass_domain/weekglass_domain.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

import '../planner/planner_controller.dart';
import '../planner/planner_settings_dialog.dart';
import 'whu_portal.dart';
import 'school_portal.dart';
import 'school_portal_timetable.dart';
import 'whu_timetable.dart';
import 'teaching_term.dart';
import 'school_adapter.dart';
import 'course_holidays.dart';

Future<void> openCourseImport(
  BuildContext context,
  PlannerController controller,
) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  barrierColor: Colors.black.withValues(alpha: .28),
  builder: (_) => CourseImportDialog(controller: controller),
);

class CourseImportDialog extends StatefulWidget {
  const CourseImportDialog({
    super.key,
    required this.controller,
    this.portal,
    this.portalFactory,
    this.schoolReader = openSchoolPortal,
  });
  final PlannerController controller;
  final WhuPortal? portal;
  final Future<WhuTimetable?> Function(BuildContext, SchoolPortalSite, WhuTerm)
  schoolReader;
  final WhuPortal Function(SchoolAdapter)? portalFactory;
  @override
  State<CourseImportDialog> createState() => _CourseImportDialogState();
}

class _CourseImportDialogState extends State<CourseImportDialog> {
  static final school = SchoolAdapter.available.first;
  late final WhuPortal portal =
      widget.portal ??
      widget.portalFactory?.call(school) ??
      NativeWhuPortal(school: school);
  final preferences = SharedPreferencesAsync();
  final account = TextEditingController();
  late int year = DateTime.now().month >= 8
      ? DateTime.now().year
      : DateTime.now().year - 1;
  late int semester = DateTime.now().month >= 8 ? 3 : 12;
  DateTime? firstMonday;
  List<ClassPeriod> clock = [...ClassPeriod.standard];
  bool connecting = false,
      reading = false,
      saving = false,
      attempted = false,
      confirmed = false;
  bool removeMissing = false, restoreDeleted = false;
  bool excludeHolidays = false;
  bool removeImportedHolidays = false;
  List<CourseHoliday> holidays = [];
  int holidayCount = 0, expandedCount = 0;
  Set<String> holidayRemovalCandidates = {};
  bool awaitingSchool = false;
  WhuTimetable? timetable;
  SchoolPortalSite? site;
  bool get schoolWeb => site != null;
  Set<String> selected = {};
  CourseImportPlan? plan;
  String? error;
  int sleepConflicts = 0, overlaps = 0, previewGeneration = 0;
  WhuTerm get term => WhuTerm(year, semester);
  bool get busy => reading || saving;
  String get sourceId => schoolWeb ? SchoolPortalTimetable.sourceId : school.id;
  String get settingsKey => schoolWeb
      ? '${sourceId}_${site!.entry.origin}_schedule_${term.key}'
      : '${sourceId}_schedule_${term.key}';
  String get accountKey => schoolWeb
      ? jsonEncode([site!.entry.origin, account.text.trim()])
      : account.text;
  @override
  void initState() {
    super.initState();
    firstMonday = school.firstMonday(term);
    portal.addListener(_portalChanged);
    unawaited(_loadSettings());
  }

  @override
  void dispose() {
    portal.removeListener(_portalChanged);
    unawaited(portal.close());
    account.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final key = settingsKey;
    try {
      final saved = await preferences.getString(key);
      if (!mounted || key != settingsKey) return;
      if (saved != null) {
        final value = jsonDecode(saved) as Map;
        final date = DateTime.parse(value['firstMonday'] as String);
        final periods = (value['periods'] as List)
            .map((p) => ClassPeriod(p[0] as int, p[1] as int))
            .toList();
        final savedHolidays = (value['holidays'] as List? ?? [])
            .map(
              (h) =>
                  CourseHoliday.fromJson(Map<String, dynamic>.from(h as Map)),
            )
            .toList();
        setState(() {
          firstMonday = date;
          clock = periods;
          confirmed = !schoolWeb;
          excludeHolidays = value['excludeHolidays'] == true;
          holidays = savedHolidays;
        });
        if (timetable != null) await _preview();
      }
    } catch (_) {
      /* Invalid local settings fall back to explicit confirmation. */
    }
  }

  void _portalChanged() {
    if (!mounted || schoolWeb) return;
    setState(() {});
    if (portal.hasTimetable(term) && !reading && !saving) {
      unawaited(_read());
      return;
    }
    if (connecting && portal.canRead && !attempted && !reading) {
      attempted = true;
      unawaited(_read());
    }
  }

  Future<void> _connect() async {
    setState(() {
      connecting = true;
      attempted = false;
      error = null;
    });
    await portal.initialize();
    if (!mounted) return;
    if (portal.canRead && !attempted) {
      attempted = true;
      await _read();
    }
  }

  Future<void> _read() async {
    if (busy || schoolWeb) return;
    setState(() {
      reading = true;
      error = null;
      awaitingSchool = false;
    });
    try {
      final data = await portal.read(term);
      if (!mounted) return;
      try {
        await widget.controller.setWhuConnected(true);
      } catch (_) {}
      if (data.meetings.isEmpty && data.warnings.isEmpty) {
        setState(() {
          timetable = null;
          plan = null;
          awaitingSchool = true;
          error = '学校未返回所选学期的课程。请在下方完成查询；如出现验证，完成后会自动读取。';
        });
        return;
      }
      setState(() {
        timetable = data;
        selected = data.courseKeys;
        account.text = data.account;
      });
      if (confirmed ||
          firstMonday != null && firstMonday == school.firstMonday(term)) {
        await _rememberTeachingCalendar();
      }
      await _preview();
    } catch (e) {
      if (mounted) {
        setState(() {
          error = _message(e);
          awaitingSchool = e is WhuSchoolQueryPending;
        });
      }
    } finally {
      if (mounted) setState(() => reading = false);
    }
  }

  void _resetSourceSettings() {
    firstMonday = schoolWeb ? null : school.firstMonday(term);
    if (schoolWeb) clock = [];
    holidays = [];
    excludeHolidays = false;
    confirmed = false;
  }

  Future<void> _chooseSchool() async {
    final picked = await chooseSchoolPortal(context);
    if (!mounted || picked == null) return;
    setState(() {
      site = picked.entry.origin == SchoolAdapter.whu.origin ? null : picked;
      account.clear();
      clock = [...ClassPeriod.standard];
      _resetSourceSettings();
      error = null;
      removeMissing = false;
      restoreDeleted = false;
      removeImportedHolidays = false;
      holidayRemovalCandidates = {};
    });
    await _loadSettings();
  }

  Future<void> _readSchool() async {
    final current = site;
    if (busy || current == null) return;
    setState(() {
      reading = true;
      error = null;
    });
    try {
      final data = await widget.schoolReader(context, current, term);
      if (!mounted || data == null) return;
      setState(() {
        timetable = data;
        selected = data.courseKeys;
        confirmed = false;
      });
      await _preview();
    } catch (e) {
      if (mounted) setState(() => error = _message(e));
    } finally {
      if (mounted) setState(() => reading = false);
    }
  }

  String _message(Object e) => switch (e) {
    ArgumentError() => e.message.toString(),
    FormatException() => e.message,
    StateError() => e.message,
    _ => '操作未完成，请重试。原有日程已保留。',
  };
  Future<void> _rememberTeachingCalendar() async {
    if (schoolWeb || firstMonday == null || timetable == null) return;
    final lastWeek = timetable!.meetings
        .expand((m) => m.weeks)
        .fold<int>(1, (a, b) => a > b ? a : b);
    try {
      await widget.controller.rememberTeachingTerm(
        TeachingTerm(
          year: year,
          semester: semester,
          firstMonday: firstMonday!,
          weeks: school.calendarWeeks(term) ?? lastWeek,
        ),
      );
    } catch (_) {
      /* Display preferences must not block course importing. */
    }
  }

  Future<void> _preview() async {
    final generation = ++previewGeneration;
    setState(() {
      plan = null;
      error = null;
      sleepConflicts = 0;
      overlaps = 0;
      holidayCount = 0;
      expandedCount = 0;
    });
    if (timetable == null ||
        firstMonday == null ||
        clock.isEmpty ||
        accountKey.trim().isEmpty) {
      return;
    }
    try {
      final expanded = timetable!.expand(
        term: term,
        accountKey: accountKey,
        firstMonday: firstMonday!,
        clock: clock,
        selectedCourses: selected,
        schoolId: sourceId,
      );
      final holidayPreview = CourseHolidayPreview.apply(
        events: expanded,
        holidays: holidays,
        exclude: excludeHolidays,
      );
      final source = WhuTimetable.scopeFor(
        term,
        accountKey,
        schoolId: sourceId,
      );
      final repo = widget.controller.repository;
      final previous = repo is ImportedEventRepository
          ? await (repo as ImportedEventRepository).getImportedEvents(source)
          : widget.controller.events
                .where((e) => e.importSource?.startsWith(source) ?? false)
                .toList();
      final candidates = previous
          .where(
            (e) =>
                e.deletedAtUtc == null &&
                holidayPreview.excludedSources.contains(e.importSource) &&
                e.importFingerprint == eventImportFingerprint(e),
          )
          .map((e) => e.importSource!)
          .toSet();
      final removeHolidayCourses =
          removeImportedHolidays &&
          setEquals(candidates, holidayRemovalCandidates);
      final preview = CourseImportPlan.compare(
        incoming: holidayPreview.incoming,
        previous: previous,
        allActive: widget.controller.events,
        removeMissing:
            !schoolWeb &&
            removeMissing &&
            timetable!.warnings.isEmpty &&
            selected.length == timetable!.courseKeys.length,
        restoreDeleted: restoreDeleted,
        excludedSources: removeHolidayCourses
            ? holidayPreview.excludedSources
            : {},
        preservedSources: removeHolidayCourses
            ? {}
            : holidayPreview.excludedSources,
      );
      final writes = preview.changes
          .where((e) => e.deletedAtUtc == null)
          .toList();
      final replaced = preview.changes.map((e) => e.id).toSet();
      final active = widget.controller.events.where(
        (e) => !replaced.contains(e.id),
      );
      var collisions = 0;
      for (final e in writes) {
        if (active.any(
          (old) =>
              e.startLocal.isBefore(old.endLocal) &&
              e.endLocal.isAfter(old.startLocal),
        )) {
          collisions++;
        }
      }
      if (!mounted || generation != previewGeneration) return;
      setState(() {
        plan = preview;
        holidayCount = holidayPreview.affected.length;
        expandedCount = expanded.length;
        holidayRemovalCandidates = candidates;
        removeImportedHolidays = removeHolidayCourses;
        sleepConflicts = writes
            .where((e) => !widget.controller.sleep.allows(e))
            .length;
        overlaps = collisions;
      });
    } catch (e) {
      if (mounted && generation == previewGeneration) {
        setState(() => error = _message(e));
      }
    }
  }

  Future<void> _pickMonday() async {
    final date = await showDatePicker(
      context: context,
      initialDate:
          firstMonday ??
          mondayOf(
            DateTime(
              semester == 3 ? year : year + 1,
              semester == 3
                  ? 9
                  : semester == 12
                  ? 2
                  : 7,
              10,
            ),
          ),
      firstDate: DateTime(year, 1),
      lastDate: DateTime(year + 2),
      selectableDayPredicate: (d) => d.weekday == DateTime.monday,
      helpText: '选择第一教学周的周一',
    );
    if (date != null && mounted) {
      setState(() {
        firstMonday = date;
        confirmed = false;
      });
      await _preview();
    }
  }

  Future<void> _editPeriod(int index, bool start) async {
    final p = clock[index];
    final minute = start ? p.start : p.end;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: minute ~/ 60, minute: minute % 60),
      helpText: '第 ${index + 1} 节${start ? '开始' : '结束'}',
    );
    if (time != null && mounted) {
      setState(() {
        clock[index] = ClassPeriod(
          start ? time.hour * 60 + time.minute : p.start,
          start ? p.end : time.hour * 60 + time.minute,
        );
        confirmed = false;
      });
      await _preview();
    }
  }

  Future<void> _editSchoolClock() async {
    final lastPeriod = timetable!.meetings
        .where((meeting) => selected.contains(meeting.courseKey))
        .fold(
          0,
          (last, meeting) =>
              meeting.periods.last > last ? meeting.periods.last : last,
        );
    final result = await showDialog<List<ClassPeriod>>(
      context: context,
      builder: (_) =>
          _SchoolClockEditor(initial: clock, lastPeriod: lastPeriod),
    );
    if (result != null && mounted) {
      setState(() {
        clock = result;
        confirmed = false;
      });
      await _preview();
    }
  }

  Future<void> _save() async {
    if (busy ||
        plan == null ||
        !confirmed ||
        sleepConflicts > 0 ||
        selected.isEmpty) {
      return;
    }
    setState(() => saving = true);
    try {
      // Re-read persistence immediately before committing so stale previews cannot overwrite changes.
      await _preview();
      if (plan == null || sleepConflicts > 0) throw StateError('请重新核对导入预览。');
      final result = plan!;
      await widget.controller.applyCourseImport(result.changes);
      await _rememberTeachingCalendar();
      try {
        await preferences.setString(
          settingsKey,
          jsonEncode({
            'firstMonday': firstMonday!.toIso8601String(),
            'periods': clock.map((p) => [p.start, p.end]).toList(),
            'excludeHolidays': excludeHolidays,
            'holidays': holidays.map((h) => h.toJson()).toList(),
          }),
        );
      } catch (_) {
        /* The import is already committed. */
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result.changes.isEmpty
                ? '导入设置已保存，现有日程没有变化'
                : '课表已导入，新增 ${result.added} 节，更新 ${result.updated} 节${result.removed > 0 ? '，移除 ${result.removed} 节' : ''}，可用侧栏撤销',
          ),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => error = _message(e));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = WeekGlassPalette.of(context);
    final preview = timetable != null;
    final dialogHeight = MediaQuery.sizeOf(context).height * .88;
    return PopScope(
      canPop: !saving,
      child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(20),
        child: ClipRRect(
          borderRadius: WeekGlassGeometry.corners,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
            child: Container(
              width: 980,
              height: !preview && !connecting
                  ? dialogHeight.clamp(0, 560).toDouble()
                  : dialogHeight,
              decoration: p.glassDecoration(elevated: true),
              child: LiquidGlassSurface(
                colorKey: "mist_blue",
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.school_outlined,
                            color: p.accentStrong,
                            size: 22,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  preview ? '核对课程，再放进一周' : '导入学校课表',
                                  style: TextStyle(
                                    fontSize: 21,
                                    fontWeight: FontWeight.w600,
                                    color: p.text,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  preview
                                      ? '${site?.name ?? school.name} ${term.label}'
                                      : '选择学校和学期',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: p.muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: '关闭导入',
                            onPressed: saving
                                ? null
                                : () => Navigator.pop(context),
                            icon: const Icon(Icons.close_rounded, size: 19),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (!preview && !connecting)
                        ListTile(
                          key: const ValueKey('choose-school-portal'),
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.account_balance_outlined),
                          title: Text(site?.name ?? school.name),
                          subtitle: Text(site?.entry.host ?? school.host),
                          trailing: const Icon(Icons.unfold_more),
                          onTap: busy ? null : _chooseSchool,
                        ),
                      if (!preview) _termRow(p),
                      if (reading || (!schoolWeb && portal.loading))
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: LinearProgressIndicator(minHeight: 2),
                        ),
                      if (error != null ||
                          (!preview && !schoolWeb && portal.error != null))
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            error ?? portal.error!,
                            style: TextStyle(
                              color: awaitingSchool
                                  ? p.accentStrong
                                  : Theme.of(context).colorScheme.error,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      Expanded(
                        child: preview ? _previewBody(p) : _connectionBody(p),
                      ),
                      const SizedBox(height: 12),
                      Divider(color: p.line, height: 1),
                      const SizedBox(height: 14),
                      if (preview)
                        _footer(p)
                      else
                        Wrap(
                          alignment: WrapAlignment.end,
                          spacing: 10,
                          runSpacing: 8,
                          children: [
                            if (connecting && portal.canRead)
                              TextButton(
                                onPressed: busy
                                    ? null
                                    : () async {
                                        attempted = true;
                                        await portal.openTimetable();
                                      },
                                child: const Text('打开学校课表'),
                              ),
                            if (connecting)
                              TextButton(
                                onPressed: busy
                                    ? null
                                    : () async {
                                        attempted = false;
                                        await portal.signOut();
                                        await widget.controller.setWhuConnected(
                                          false,
                                        );
                                      },
                                child: const Text('退出登录 / 换账号'),
                              ),
                            if (connecting)
                              OutlinedButton(
                                onPressed: busy
                                    ? null
                                    : () async {
                                        attempted = false;
                                        await portal.reconnect();
                                      },
                                child: const Text('重新连接'),
                              ),
                            FilledButton.icon(
                              autofocus: !connecting,
                              onPressed: busy
                                  ? null
                                  : connecting
                                  ? (portal.canRead ? _read : null)
                                  : schoolWeb
                                  ? _readSchool
                                  : _connect,
                              icon: Icon(
                                reading
                                    ? Icons.hourglass_top_rounded
                                    : schoolWeb
                                    ? Icons.open_in_browser
                                    : Icons.download_rounded,
                                size: 17,
                              ),
                              label: Text(
                                reading
                                    ? '正在读取…'
                                    : connecting
                                    ? '读取课表'
                                    : schoolWeb
                                    ? '打开学校教务'
                                    : '连接并读取课表',
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _editHoliday([int? index]) async {
    final result = await showDialog<CourseHoliday>(
      context: context,
      builder: (_) => _HolidayEditor(
        initial: index == null ? null : holidays[index],
        initialDate: firstMonday ?? DateTime(year, 9, 1),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      if (index == null) {
        holidays.add(result);
      } else {
        holidays[index] = result;
      }
      confirmed = false;
    });
    await _preview();
  }

  Widget _holidaySettings(WeekGlassPalette p) => Container(
    key: const ValueKey('course-holiday-settings'),
    padding: const EdgeInsets.all(12),
    decoration: p.glassDecoration(),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.beach_access_outlined, color: p.accentStrong, size: 18),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                '节假日课程',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            TextButton(
              key: const ValueKey('add-course-holiday'),
              onPressed: busy ? null : () => _editHoliday(),
              child: const Text('添加日期'),
            ),
          ],
        ),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('照常导入')),
            ButtonSegment(value: true, label: Text('排除假期')),
          ],
          selected: {excludeHolidays},
          showSelectedIcon: false,
          style: ButtonStyle(
            textStyle: WidgetStatePropertyAll(
              Theme.of(context).textTheme.labelMedium!.copyWith(fontSize: 12),
            ),
          ),
          onSelectionChanged: busy
              ? null
              : (value) {
                  setState(() {
                    excludeHolidays = value.single;
                    removeImportedHolidays = false;
                    confirmed = false;
                  });
                  unawaited(_preview());
                },
        ),
        const SizedBox(height: 8),
        Text(
          holidays.isEmpty
              ? '尚未设置假期范围，当前保留全部课程。请按学校通知添加日期。'
              : excludeHolidays
              ? '范围内 $holidayCount 节将排除，保留 ${expandedCount - holidayCount} 节。已导入课程默认保留。'
              : '范围内 $holidayCount 节照常导入，共 $expandedCount 节。',
          key: const ValueKey('course-holiday-count'),
          style: TextStyle(fontSize: 11, color: p.muted, height: 1.6),
        ),
        if (excludeHolidays && holidayRemovalCandidates.isNotEmpty)
          CheckboxListTile(
            key: const ValueKey('remove-imported-holiday-courses'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            value: removeImportedHolidays,
            title: Text(
              '同时移除已导入且未调整的 ${holidayRemovalCandidates.length} 条课程',
              style: const TextStyle(fontSize: 12, height: 1.5),
            ),
            subtitle: const Text(
              '整次导入可撤销；手动调整过的课程仍保留。',
              style: TextStyle(fontSize: 10, height: 1.6),
            ),
            onChanged: busy
                ? null
                : (value) {
                    setState(() {
                      removeImportedHolidays = value!;
                      confirmed = false;
                    });
                    unawaited(_preview());
                  },
          ),
        for (var index = 0; index < holidays.length; index++)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    borderRadius: WeekGlassGeometry.corners,
                    onTap: busy ? null : () => _editHoliday(index),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Text(
                        '${holidays[index].name}\n${holidays[index].dateLabel}',
                        style: TextStyle(
                          fontSize: 11,
                          color: p.text,
                          height: 1.6,
                        ),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '移除${holidays[index].name}',
                  visualDensity: VisualDensity.compact,
                  onPressed: busy
                      ? null
                      : () {
                          setState(() {
                            holidays.removeAt(index);
                            confirmed = false;
                          });
                          unawaited(_preview());
                        },
                  icon: const Icon(Icons.close_rounded, size: 16),
                ),
              ],
            ),
          ),
        if (holidays.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            '点日期可修改。调休补课仍以教务课表为准，不自动换日。',
            style: TextStyle(fontSize: 10, color: p.muted, height: 1.6),
          ),
        ],
      ],
    ),
  );

  Widget _termRow(WeekGlassPalette p) => Row(
    children: [
      Expanded(
        child: DropdownButtonFormField<int>(
          isExpanded: true,
          borderRadius: WeekGlassGeometry.corners,
          dropdownColor: p.surface.withValues(alpha: .98),
          key: const ValueKey('import-year'),
          initialValue: year,
          decoration: const InputDecoration(labelText: '学年'),
          items: [
            for (
              var y = DateTime.now().year - 4;
              y <= DateTime.now().year + 1;
              y++
            )
              DropdownMenuItem(value: y, child: Text('$y–${y + 1}')),
          ],
          onChanged: busy
              ? null
              : (v) {
                  setState(() {
                    year = v!;
                    _resetSourceSettings();
                    attempted = true;
                  });
                  unawaited(_loadSettings());
                },
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: DropdownButtonFormField<int>(
          isExpanded: true,
          borderRadius: WeekGlassGeometry.corners,
          dropdownColor: p.surface.withValues(alpha: .98),
          key: const ValueKey('import-semester'),
          initialValue: semester,
          decoration: const InputDecoration(labelText: '学期'),
          items: const [
            DropdownMenuItem(value: 3, child: Text('秋季学期')),
            DropdownMenuItem(value: 12, child: Text('春季学期')),
            DropdownMenuItem(value: 16, child: Text('夏季学期')),
          ],
          onChanged: busy
              ? null
              : (v) {
                  setState(() {
                    semester = v!;
                    _resetSourceSettings();
                    attempted = true;
                  });
                  unawaited(_loadSettings());
                },
        ),
      ),
    ],
  );

  Widget _connectionBody(WeekGlassPalette p) {
    if (!connecting) {
      return Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.calendar_month_outlined,
                size: 48,
                color: p.accentStrong,
              ),
              const SizedBox(height: 20),
              Text(
                '一学期的安排，一次带进来',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 23,
                  color: p.text,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                schoolWeb ? '在学校页面打开个人学期课表，点「读取当前课表」。' : '登录后核对课程，再导入日历。',
                textAlign: TextAlign.center,
                style: TextStyle(color: p.muted),
              ),
              const SizedBox(height: 14),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Text(
                  schoolWeb
                      ? '可识别正方和强智的部分学期课表。首次导入请准备本校校历及节次时间。'
                      : '密码和验证码只在学校官方页面填写。确认第一周、节次与假期后再保存。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: p.muted, fontSize: 12, height: 1.8),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 10),
        Text(
          portal.host.isEmpty ? '正在连接学校…' : '学校页面：${portal.host}',
          style: TextStyle(fontSize: 11, color: p.muted),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: portal.initialized
              ? ClipRRect(
                  borderRadius: WeekGlassGeometry.corners,
                  child: portal.buildView(),
                )
              : Center(
                  child: portal.error == null
                      ? const CircularProgressIndicator()
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.public_off_rounded, size: 36),
                            const SizedBox(height: 10),
                            const Text('暂时无法连接学校'),
                            if (portal.error!.contains('WebView2'))
                              TextButton(
                                onPressed: () async {
                                  await Clipboard.setData(
                                    const ClipboardData(
                                      text: 'https://developer.microsoft.com/microsoft-edge/webview2/',
                                    ),
                                  );
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('已复制 WebView2 官方下载地址'),
                                      ),
                                    );
                                  }
                                },
                                child: const Text('复制 WebView2 下载地址'),
                              ),
                          ],
                        ),
                ),
        ),
      ],
    );
  }

  Widget _previewBody(WeekGlassPalette p) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 680;
      if (wide) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(flex: 6, child: _courses(p)),
            const SizedBox(width: 20),
            Expanded(flex: 5, child: _configuration(p)),
          ],
        );
      }
      return SingleChildScrollView(
        child: Column(
          children: [
            SizedBox(height: 230, child: _courses(p)),
            const SizedBox(height: 16),
            _configuration(p, scroll: false),
          ],
        ),
      );
    },
  );
  Widget _courses(WeekGlassPalette p) {
    final data = timetable!;
    final groups = <String, List<WhuCourseMeeting>>{};
    for (final m in data.meetings) {
      groups.putIfAbsent(m.courseKey, () => []).add(m);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              '${groups.length} 门课程',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: p.text,
              ),
            ),
            const Spacer(),
            TextButton(
              onPressed: busy
                  ? null
                  : () {
                      setState(
                        () => selected = selected.length == groups.length
                            ? {}
                            : groups.keys.toSet(),
                      );
                      unawaited(_preview());
                    },
              child: Text(selected.length == groups.length ? '全不选' : '全选'),
            ),
          ],
        ),
        Expanded(
          child: groups.isEmpty
              ? Center(
                  child: Text(
                    '该学期没有可导入课程。\n可返回重新选择学期。',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: p.muted),
                  ),
                )
              : ListView.separated(
                  itemCount: groups.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final key = groups.keys.elementAt(index);
                    final meetings = groups[key]!;
                    return DecoratedBox(
                      decoration: p.glassDecoration(layer: GlassLayer.card),
                      child: Material(
                        type: MaterialType.transparency,
                        child: CheckboxListTile(
                          dense: true,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: selected.contains(key),
                          onChanged: busy
                              ? null
                              : (v) {
                                  setState(() {
                                    if (v!) {
                                      selected.add(key);
                                    } else {
                                      selected.remove(key);
                                    }
                                  });
                                  unawaited(_preview());
                                },
                          title: Text(
                            meetings.first.title,
                            style: TextStyle(
                              color: p.text,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              meetings
                                  .map(
                                    (m) =>
                                        '${m.scheduleLabel}${m.room.isEmpty ? '' : '\n${m.room}'}',
                                  )
                                  .join('\n'),
                              style: TextStyle(
                                fontSize: 11,
                                color: p.muted,
                                height: 1.6,
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
        if (data.warnings.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              '有 ${data.warnings.length} 项未自动安排，请核对提示。',
              style: TextStyle(fontSize: 12, color: p.accentStrong),
            ),
          ),
      ],
    );
  }

  Widget _configuration(WeekGlassPalette p, {bool scroll = true}) {
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '教学安排',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: p.text,
          ),
        ),
        const SizedBox(height: 12),
        if (schoolWeb || timetable!.account.isEmpty) ...[
          TextField(
            key: ValueKey(schoolWeb ? 'import-profile' : 'import-account'),
            controller: account,
            decoration: schoolWeb
                ? const InputDecoration(
                    labelText: '课表别名（可选）',
                    hintText: '我的课表',
                    helperText: '若在同一学校切换账号，请使用不同别名。',
                  )
                : const InputDecoration(
                    labelText: '学号',
                    helperText: '用于区分课表，不会作为登录凭据',
                  ),
            onChanged: (_) {
              setState(() => confirmed = false);
              unawaited(_preview());
            },
          ),
          const SizedBox(height: 12),
        ],
        OutlinedButton.icon(
          key: const ValueKey('first-teaching-monday'),
          onPressed: busy ? null : _pickMonday,
          icon: const Icon(Icons.event_outlined, size: 17),
          label: Text(
            firstMonday == null
                ? '选择第一教学周的周一'
                : '第一教学周 ${firstMonday!.year}/${firstMonday!.month}/${firstMonday!.day}',
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '周次按教务系统计算，请勿用报到日期代替。',
          style: TextStyle(fontSize: 11, color: p.muted, height: 1.6),
        ),
        const SizedBox(height: 8),
        if (schoolWeb)
          OutlinedButton.icon(
            key: const ValueKey('edit-course-school-clock'),
            onPressed: busy ? null : _editSchoolClock,
            icon: const Icon(Icons.schedule_rounded, size: 17),
            label: Text(clock.isEmpty ? '填写节次时间' : '核对 ${clock.length} 节的时间'),
          )
        else
          Material(
            type: MaterialType.transparency,
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('节次时间', style: TextStyle(fontSize: 13)),
              subtitle: Text(
                '首次使用请对照学校课表核对',
                style: TextStyle(fontSize: 11, color: p.muted),
              ),
              children: [
                if (clock.length < 24)
                  TextButton.icon(
                    onPressed: busy || clock.last.end >= 1390
                        ? null
                        : () {
                            setState(() {
                              clock.add(
                                ClassPeriod(
                                  clock.last.end + 5,
                                  clock.last.end + 50,
                                ),
                              );
                              confirmed = false;
                            });
                            unawaited(_preview());
                          },
                    icon: const Icon(Icons.add_rounded, size: 16),
                    label: const Text('添加节次'),
                  ),
                for (var i = 0; i < clock.length; i++)
                  Row(
                    children: [
                      SizedBox(
                        width: 52,
                        child: Text(
                          '第 ${i + 1} 节',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      Expanded(
                        child: TextButton(
                          onPressed: busy ? null : () => _editPeriod(i, true),
                          child: Text(ClassPeriod.clock(clock[i].start)),
                        ),
                      ),
                      const Text('—'),
                      Expanded(
                        child: TextButton(
                          onPressed: busy ? null : () => _editPeriod(i, false),
                          child: Text(ClassPeriod.clock(clock[i].end)),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        const SizedBox(height: 10),
        _holidaySettings(p),
        const SizedBox(height: 8),
        Material(
          type: MaterialType.transparency,
          child: CheckboxListTile(
            key: const ValueKey('confirm-import-calendar'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            value: confirmed,
            onChanged: busy ? null : (v) => setState(() => confirmed = v!),
            title: const Text(
              '已核对学期、第一周、节次与假期安排',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ),
        Material(
          type: MaterialType.transparency,
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('重复导入与更新', style: TextStyle(fontSize: 13)),
            children: [
              const Text(
                '自动跳过重复课程，保留手动改过的名称、时间和备注；颜色始终保留。',
                style: TextStyle(fontSize: 12, height: 1.6),
              ),
              if (!schoolWeb)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: removeMissing,
                  onChanged:
                      busy ||
                          timetable!.warnings.isNotEmpty ||
                          selected.length != timetable!.courseKeys.length
                      ? null
                      : (v) {
                          setState(() => removeMissing = v!);
                          unawaited(_preview());
                        },
                  title: const Text(
                    '移除教务已取消的课程',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: restoreDeleted,
                onChanged: busy
                    ? null
                    : (v) {
                        setState(() => restoreDeleted = v!);
                        unawaited(_preview());
                      },
                title: const Text(
                  '重新加入我曾删除的课程',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        if (plan != null) ...[
          const SizedBox(height: 10),
          Text(
            '新增 ${plan!.added}，更新 ${plan!.updated}，移除 ${plan!.removed}',
            style: TextStyle(
              color: p.accentStrong,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '跳过 ${plan!.unchanged + plan!.duplicates} 节重复课程；保留 ${plan!.keptEdits} 节手动修改、${plan!.keptDeleted} 节已删除课程。',
            style: TextStyle(color: p.muted, fontSize: 11, height: 1.7),
          ),
          if (overlaps > 0)
            Text(
              '$overlaps 节课与已有安排重叠，导入后并排显示。',
              style: TextStyle(color: p.muted, fontSize: 12),
            ),
          if (sleepConflicts > 0) ...[
            Text(
              '$sleepConflicts 节课与睡眠时段冲突，需先调整睡眠设置。',
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
            TextButton(
              onPressed: () async {
                await openPlannerSettings(context, widget.controller);
                if (mounted) await _preview();
              },
              child: const Text('调整睡眠时段'),
            ),
          ],
        ],
        if (timetable!.warnings.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            '未自动安排的内容',
            style: TextStyle(
              color: p.text,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
          for (final warning in timetable!.warnings)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                warning,
                style: TextStyle(fontSize: 11, color: p.muted, height: 1.6),
              ),
            ),
        ],
      ],
    );
    return scroll ? SingleChildScrollView(child: body) : body;
  }

  Widget _footer(WeekGlassPalette p) => Wrap(
    alignment: WrapAlignment.spaceBetween,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 12,
    runSpacing: 8,
    children: [
      TextButton(
        onPressed: busy
            ? null
            : () {
                setState(() {
                  timetable = null;
                  plan = null;
                  attempted = true;
                  error = null;
                });
              },
        child: Text(schoolWeb ? '返回选择学校或学期' : '返回 / 更换学期'),
      ),
      if (plan != null)
        Text(
          '新增 ${plan!.added}，更新 ${plan!.updated}，移除 ${plan!.removed}',
          style: TextStyle(color: p.muted, fontSize: 11),
        ),
      FilledButton.icon(
        key: const ValueKey('commit-course-import'),
        onPressed:
            busy ||
                plan == null ||
                !confirmed ||
                sleepConflicts > 0 ||
                selected.isEmpty
            ? null
            : _save,
        icon: Icon(
          saving ? Icons.hourglass_top_rounded : Icons.check_rounded,
          size: 17,
        ),
        label: Text(
          saving
              ? '正在导入…'
              : selected.isEmpty
              ? '请选择课程'
              : plan != null && plan!.changes.isEmpty
              ? '保存导入设置'
              : '导入日历',
        ),
      ),
    ],
  );
}

class _SchoolClockEditor extends StatefulWidget {
  const _SchoolClockEditor({required this.initial, required this.lastPeriod});

  final List<ClassPeriod> initial;
  final int lastPeriod;

  @override
  State<_SchoolClockEditor> createState() => _SchoolClockEditorState();
}

class _SchoolClockEditorState extends State<_SchoolClockEditor> {
  late final clock = TextEditingController(
    text: [
      for (var i = 0; i < widget.initial.length; i++)
        '${i + 1} ${ClassPeriod.clock(widget.initial[i].start)}-${ClassPeriod.clock(widget.initial[i].end)}',
    ].join('\n'),
  );
  String? error;

  @override
  void dispose() {
    clock.dispose();
    super.dispose();
  }

  void _confirm() {
    try {
      final periods = ClassPeriod.parseClock(clock.text);
      if (periods.length < widget.lastPeriod) {
        throw FormatException('所选课程用到第 ${widget.lastPeriod} 节，请补齐时刻。');
      }
      Navigator.pop(context, periods);
    } on FormatException catch (e) {
      setState(() => error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) => GlassAlertDialog(
    title: const Text('填写节次时间'),
    insetPadding: const EdgeInsets.all(16),
    content: SizedBox(
      width: 430,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.lastPeriod == 0
                  ? '请参照学校或校区公布的作息时间，从第 1 节起每行填写一节。'
                  : '所选课程用到第 ${widget.lastPeriod} 节。请按校区作息时间，从第 1 节连续填写。',
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('course-school-clock-text'),
              controller: clock,
              minLines: 4,
              maxLines: 8,
              keyboardType: TextInputType.multiline,
              decoration: InputDecoration(
                labelText: '开始和结束时刻',
                hintText: '1 08:00-08:45\n2 08:50-09:35',
                alignLabelWithHint: true,
                errorText: error,
                errorMaxLines: 3,
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _confirm, child: const Text('应用时刻')),
    ],
  );
}

class _HolidayEditor extends StatefulWidget {
  const _HolidayEditor({this.initial, required this.initialDate});
  final CourseHoliday? initial;
  final DateTime initialDate;
  @override
  State<_HolidayEditor> createState() => _HolidayEditorState();
}

class _HolidayEditorState extends State<_HolidayEditor> {
  late final name = TextEditingController(text: widget.initial?.name ?? '学校假期');
  late DateTime start = widget.initial?.start ?? widget.initialDate;
  late DateTime end = widget.initial?.end ?? widget.initialDate;
  String? error;
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> _pick(bool first) async {
    final value = await showDatePicker(
      context: context,
      helpText: first ? '假期开始日期' : '假期结束日期（包含当天）',
      initialDate: first ? start : end,
      firstDate: DateTime(widget.initialDate.year - 1),
      lastDate: DateTime(widget.initialDate.year + 2, 12, 31),
    );
    if (value != null && mounted) {
      setState(() {
        if (first) {
          start = value;
          if (end.isBefore(start)) end = start;
        } else {
          end = value;
          if (start.isAfter(end)) start = end;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) => GlassAlertDialog(
    title: Text(widget.initial == null ? '添加假期日期' : '修改假期日期'),
    insetPadding: const EdgeInsets.all(20),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: name,
            decoration: InputDecoration(labelText: '假期名称', errorText: error),
            maxLength: 40,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _pick(true),
            icon: const Icon(Icons.event_outlined, size: 18),
            label: Text('开始 · ${start.year}/${start.month}/${start.day}'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _pick(false),
            icon: const Icon(Icons.event_outlined, size: 18),
            label: Text('结束 · ${end.year}/${end.month}/${end.day}'),
          ),
          const SizedBox(height: 8),
          const Text(
            '包含开始和结束当天。请使用学校公布的放假日期。',
            style: TextStyle(fontSize: 12, height: 1.7),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (name.text.trim().isEmpty) {
            setState(() => error = '请填写假期名称');
            return;
          }
          Navigator.pop(
            context,
            CourseHoliday(name: name.text.trim(), start: start, end: end),
          );
        },
        child: const Text('保存日期'),
      ),
    ],
  );
}
