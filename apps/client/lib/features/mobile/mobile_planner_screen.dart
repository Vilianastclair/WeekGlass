import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

import 'mobile_calendar_pager.dart';
import 'mobile_glass_backdrop.dart';
import 'mobile_press_feedback.dart';
import '../planner/planner_actions.dart';
import '../planner/planner_controller.dart';
import '../planner/planner_settings_dialog.dart';
import '../planner/sidebar_action.dart';

/// Phone navigation around the shared calendar and event workflows.
/// No desktop window controls, independent data model or alternate editor.
class MobilePlannerScreen extends StatefulWidget {
  const MobilePlannerScreen({super.key, required this.controller});
  final PlannerController controller;

  @override
  State<MobilePlannerScreen> createState() => _MobilePlannerScreenState();
}

class _MobilePlannerScreenState extends State<MobilePlannerScreen> {
  final _pager = GlobalKey<MobileCalendarPagerState>();
  bool _editing = false;
  PlannerController get controller => widget.controller;

  void _navigate(int direction) {
    final pager = _pager.currentState;
    if (pager != null) {
      pager.navigate(direction);
    } else {
      controller.navigatePeriod(direction);
    }
  }

  Future<void> _run(BuildContext context, SidebarAction action) async {
    try {
      await openPlannerAction(context, controller, action);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is StateError ? error.message.toString() : '操作未完成，请重试。日程已保留。',
          ),
        ),
      );
    }
  }

  Future<void> _date(BuildContext context) async {
    final value = await showDatePicker(
      context: context,
      initialDate: controller.anchorDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100, 12, 31),
      helpText: '跳转到日期',
    );
    if (value != null && context.mounted) controller.setAnchorDate(value);
  }

  List<SidebarAction> get _actions => SidebarAction.values
      .where(
        (action) =>
            action != SidebarAction.view &&
            controller.sidebarActions.contains(action) &&
            (action != SidebarAction.cloud || controller.cloud != null),
      )
      .toList();

  Future<void> _more(BuildContext context, List<SidebarAction> actions) async {
    final selected = await showModalBottomSheet<SidebarAction>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : const AnimationStyle(
              duration: Duration(milliseconds: 240),
              reverseDuration: Duration(milliseconds: 180),
            ),
      builder: (context) {
        final p = WeekGlassPalette.of(context);
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: LiquidGlassSurface(
              colorKey: 'mist_blue',
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * .75,
                ),
                decoration: p.glassDecoration(elevated: true),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '更多操作',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭更多操作',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
                            for (final action in actions)
                              ListTile(
                                key: ValueKey('mobile-more-${action.name}'),
                                leading: Icon(
                                  action.icon,
                                  color: p.accentStrong,
                                ),
                                title: Text(action.label),
                                enabled:
                                    action != SidebarAction.undo ||
                                    controller.canUndo,
                                shape: const RoundedRectangleBorder(
                                  borderRadius: WeekGlassGeometry.corners,
                                ),
                                onTap: () => Navigator.pop(context, action),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
    if (selected != null && context.mounted) await _run(context, selected);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final p = WeekGlassPalette.of(context);
      final actions = _actions;
      final primary = actions.take(3).toList();
      final overflow = actions.skip(3).toList();
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: p.isDark
              ? Brightness.light
              : Brightness.dark,
          systemNavigationBarColor: p.canvas,
          systemNavigationBarIconBrightness: p.isDark
              ? Brightness.light
              : Brightness.dark,
        ),
        child: Scaffold(
          key: const ValueKey('mobile-planner-screen'),
          backgroundColor: p.canvas,
          body: MobileGlassBackdrop(
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                child: Column(
                  children: [
                    AbsorbPointer(
                      absorbing: _editing,
                      child: _header(context, p),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: MobileCalendarPager(
                        key: _pager,
                        controller: controller,
                        onInteractionChanged: (active) {
                          if (_editing != active) {
                            setState(() => _editing = active);
                          }
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      key: const ValueKey('mobile-action-dock'),
                      decoration: p.glassDecoration(elevated: true),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 4,
                      ),
                      child: Row(
                        children: [
                          for (final action in primary)
                            Expanded(
                              child: _DockButton(
                                key: ValueKey('mobile-action-${action.name}'),
                                icon: action.icon,
                                label: _shortLabel(action),
                                tooltip: action == SidebarAction.undo
                                    ? controller.undoLabel
                                    : action.label,
                                primary: action == SidebarAction.create,
                                onPressed:
                                    action == SidebarAction.undo &&
                                        !controller.canUndo
                                    ? null
                                    : () => _run(context, action),
                              ),
                            ),
                          if (overflow.isNotEmpty)
                            Expanded(
                              child: _DockButton(
                                key: const ValueKey('mobile-action-more'),
                                icon: Icons.more_horiz_rounded,
                                label: '更多',
                                tooltip: '更多快捷操作',
                                onPressed: () => _more(context, overflow),
                              ),
                            ),
                          Expanded(
                            child: _DockButton(
                              key: const ValueKey('mobile-action-settings'),
                              icon: Icons.tune_rounded,
                              label: '设置',
                              tooltip: '设置',
                              onPressed: () =>
                                  openPlannerSettings(context, controller),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _header(BuildContext context, WeekGlassPalette p) {
    final days = controller.visibleDays;
    final date = DateFormat('M月d日', 'zh_CN');
    final label = days.length == 1
        ? date.format(days.first)
        : '${date.format(days.first)} – ${date.format(days.last)}';
    return Container(
      key: const ValueKey('mobile-date-header'),
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
      decoration: p.glassDecoration(),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                key: const ValueKey('mobile-previous-period'),
                tooltip: '上一段日期',
                onPressed: () => _navigate(-1),
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              Expanded(
                child: InkWell(
                  key: const ValueKey('mobile-choose-date'),
                  borderRadius: WeekGlassGeometry.corners,
                  onTap: () => _date(context),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      children: [
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: p.text,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          controller.teachingWeekLabel ??
                              '${controller.anchorDate.year} 年 · ${DateFormat('EEEE', 'zh_CN').format(controller.anchorDate)}',
                          key: const ValueKey('mobile-teaching-week'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10, color: p.muted),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('mobile-next-period'),
                tooltip: '下一段日期',
                onPressed: () => _navigate(1),
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ],
          ),
          Row(
            children: [
              const SizedBox(width: 8),
              if (controller.sidebarActions.contains(SidebarAction.view))
                Expanded(
                  child: SegmentedButton<PlannerView>(
                    key: const ValueKey('mobile-view-switch'),
                    segments: const [
                      ButtonSegment(value: PlannerView.day, label: Text('单日')),
                      ButtonSegment(
                        value: PlannerView.threeDays,
                        label: Text('三日'),
                      ),
                      ButtonSegment(value: PlannerView.week, label: Text('整周')),
                    ],
                    selected: {controller.view},
                    showSelectedIcon: false,
                    style: ButtonStyle(
                      textStyle: WidgetStatePropertyAll(
                        Theme.of(context).textTheme.labelMedium!
                            .copyWith(fontSize: 12),
                      ),
                      visualDensity: VisualDensity.standard,
                      minimumSize: const WidgetStatePropertyAll(Size(48, 44)),
                    ),
                    onSelectionChanged: (value) =>
                        controller.setView(value.single),
                  ),
                )
              else
                const Spacer(),
              const SizedBox(width: 4),
              TextButton(
                key: const ValueKey('mobile-today'),
                onPressed: controller.goToday,
                style: TextButton.styleFrom(
                  minimumSize: const Size(52, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('今天'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _shortLabel(SidebarAction action) => switch (action) {
    SidebarAction.create => '新建',
    SidebarAction.undo => '撤销',
    SidebarAction.courses => '课表',
    SidebarAction.importEvents => '导入',
    SidebarAction.exportEvents => '导出',
    SidebarAction.appearance => '外观',
    SidebarAction.cloud => '云同步',
    SidebarAction.updates => '更新',
    SidebarAction.view => '视图',
  };
}

class _DockButton extends StatelessWidget {
  const _DockButton({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    this.primary = false,
    required this.onPressed,
  });
  final IconData icon;
  final String label, tooltip;
  final bool primary;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) {
    final p = WeekGlassPalette.of(context);
    final color = onPressed == null
        ? p.mutedSoft
        : primary
        ? p.accentStrong
        : p.text;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        label: tooltip,
        button: true,
        enabled: onPressed != null,
        excludeSemantics: true,
        child: MobilePressFeedback(
          enabled: onPressed != null,
          child: InkWell(
            onTap: onPressed,
            borderRadius: WeekGlassGeometry.corners,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 60, minWidth: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 24, color: color),
                    const SizedBox(height: 3),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        color: color,
                        fontWeight: primary ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
