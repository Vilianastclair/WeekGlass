import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

import '../cloud/cloud_service_button.dart';
import 'mobile_action_dock.dart';
import 'mobile_calendar_pager.dart';
import 'mobile_glass_backdrop.dart';
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
            action.availableOn(Theme.of(context).platform) &&
            action != SidebarAction.view &&
            action != SidebarAction.cloud &&
            controller.sidebarActions.contains(action),
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
                padding: const EdgeInsets.fromLTRB(8, 2, 8, 3),
                child: Column(
                  children: [
                    AbsorbPointer(
                      absorbing: _editing,
                      child: _header(context, p),
                    ),
                    const SizedBox(height: 3),
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
                    const SizedBox(height: 4),
                    AbsorbPointer(absorbing: _editing, child: _dock(context)),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _dock(BuildContext context) {
    final actions = _actions;
    final showCloud =
        controller.cloud != null &&
        controller.sidebarActions.contains(SidebarAction.cloud);
    return MobileActionDock(
      key: const ValueKey('mobile-action-dock'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: LayoutBuilder(
          builder: (context, box) {
            // The six-slot row needs wider targets. Cloud and Settings always
            // retain the tail of the dock, even when More is needed.
            final direct = showCloud && actions.length > 3 && box.maxWidth < 336
                ? 2
                : 3;
            final iPhone = Theme.of(context).platform == TargetPlatform.iOS;
            final slots = actions
                .where((action) => !iPhone || !action.isCalendarFileAction)
                .take(direct)
                .toSet();
            final overflow = actions
                .where((action) => !slots.contains(action))
                .toList();
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final action in slots)
                    Expanded(
                      child: MobileDockButton(
                        key: ValueKey('mobile-action-${action.name}'),
                        icon: Icon(action.icon),
                        label: _shortLabel(action),
                        tooltip: action == SidebarAction.undo
                            ? controller.undoLabel
                            : action.label,
                        primary: action == SidebarAction.create,
                        onPressed:
                            action == SidebarAction.undo && !controller.canUndo
                            ? null
                            : () => _run(context, action),
                      ),
                    ),
                  if (overflow.isNotEmpty)
                    Expanded(
                      child: MobileDockButton(
                        key: const ValueKey('mobile-action-more'),
                        icon: const Icon(Icons.more_horiz_rounded),
                        label: '更多',
                        tooltip: '更多快捷操作',
                        onPressed: () => _more(context, overflow),
                      ),
                    ),
                  if (showCloud)
                    Expanded(
                      child: CloudServiceButton.dock(
                        key: const ValueKey('mobile-action-cloud'),
                        onPressed: () => _run(context, SidebarAction.cloud),
                      ),
                    ),
                  Expanded(
                    child: MobileDockButton(
                      key: const ValueKey('mobile-action-settings'),
                      icon: const Icon(Icons.tune_rounded),
                      label: '设置',
                      tooltip: '设置',
                      onPressed: () => openPlannerSettings(context, controller),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
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
    SidebarAction.cloud => action.label,
    SidebarAction.updates => '更新',
    SidebarAction.view => '视图',
  };

  Widget _header(BuildContext context, WeekGlassPalette p) {
    final days = controller.visibleDays;
    final first = days.first, last = days.last;
    final sameMonth = first.year == last.year && first.month == last.month;
    final single = days.length == 1;
    final longDate = single
        ? '${first.month}月${first.day}日'
        : '${first.month}月${first.day}日至${sameMonth ? "" : "${last.month}月"}${last.day}日';
    final shortDate = single
        ? '${first.month}/${first.day}'
        : '${first.month}/${first.day}至${sameMonth ? "" : "${last.month}/"}${last.day}';
    final term = controller.visibleTeachingTerm;
    final week = term?.weekAt(controller.anchorDate);
    final subtitle = term == null
        ? '${controller.anchorDate.year}年 ${DateFormat('EEEE', 'zh_CN').format(controller.anchorDate)}'
        : '第${term.number}学期 第$week周';
    final shortSubtitle = term == null ? '${first.year}年' : '第$week周';
    final showViews = controller.sidebarActions.contains(SidebarAction.view);
    final theme = Theme.of(context).textTheme;
    final dateStyle = theme.bodyMedium!.copyWith(
      fontSize: 15,
      height: 1.21,
      fontWeight: FontWeight.w600,
      color: p.text,
    );
    final subtitleStyle = theme.bodySmall!.copyWith(
      fontSize: 11,
      height: 1.15,
      fontWeight: FontWeight.w500,
      color: p.muted,
    );
    final labelStyle = theme.labelMedium!.copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w600,
    );
    final today = TextButton(
      key: const ValueKey('mobile-today'),
      style: TextButton.styleFrom(
        textStyle: labelStyle,
        foregroundColor: p.accentStrong,
        minimumSize: const Size(52, 48),
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      onPressed: controller.goToday,
      child: const Text('今天'),
    );
    return Column(
      key: const ValueKey('mobile-date-header'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            _PeriodButton(
              key: const ValueKey('mobile-previous-period'),
              icon: Icons.chevron_left_rounded,
              tooltip: '上一段日期',
              onPressed: () => _navigate(-1),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) {
                  bool fits(String value, TextStyle style) {
                    final measure = TextPainter(
                      text: TextSpan(text: value, style: style),
                      textScaler: MediaQuery.textScalerOf(context),
                      textDirection: Directionality.of(context),
                      locale: Localizations.maybeLocaleOf(context),
                      maxLines: 1,
                    )..layout();
                    final fits = measure.width <= box.maxWidth;
                    measure.dispose();
                    return fits;
                  }

                  return Semantics(
                    button: true,
                    label: '$longDate，$subtitle，选择日期',
                    excludeSemantics: true,
                    onTap: () => _date(context),
                    child: InkWell(
                      key: const ValueKey('mobile-choose-date'),
                      borderRadius: WeekGlassGeometry.corners,
                      onTap: () => _date(context),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 48),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              fits(longDate, dateStyle) ? longDate : shortDate,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: dateStyle,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              fits(subtitle, subtitleStyle)
                                  ? subtitle
                                  : shortSubtitle,
                              key: const ValueKey('mobile-teaching-week'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: subtitleStyle,
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            _PeriodButton(
              key: const ValueKey('mobile-next-period'),
              icon: Icons.chevron_right_rounded,
              tooltip: '下一段日期',
              onPressed: () => _navigate(1),
            ),
            if (!showViews) today,
          ],
        ),
        if (showViews)
          Row(
            children: [
              const SizedBox(width: 4),
              Expanded(
                child: Row(
                  key: const ValueKey('mobile-view-switch'),
                  children: [
                    for (final (view, label) in const [
                      (PlannerView.day, '单日'),
                      (PlannerView.threeDays, '三日'),
                      (PlannerView.week, '整周'),
                    ])
                      Expanded(
                        key: ValueKey('mobile-view-${view.name}'),
                        child: Semantics(
                          button: true,
                          label: label,
                          onTap: () => controller.setView(view),
                          excludeSemantics: true,
                          selected: controller.view == view,
                          inMutuallyExclusiveGroup: true,
                          child: TextButton(
                            style: TextButton.styleFrom(
                              textStyle: labelStyle,
                              backgroundColor: controller.view == view
                                  ? p.accentSoft
                                  : Colors.transparent,
                              foregroundColor: controller.view == view
                                  ? p.accentStrong
                                  : p.muted,
                              minimumSize: const Size(0, 34),
                              tapTargetSize: MaterialTapTargetSize.padded,
                              padding: const EdgeInsets.fromLTRB(1, 3, 1, 3),
                              shape: WeekGlassGeometry.shape,
                            ),
                            onPressed: () => controller.setView(view),
                            child: Text(label, textAlign: TextAlign.center),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              today,
            ],
          ),
      ],
    );
  }
}

class _PeriodButton extends StatelessWidget {
  const _PeriodButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 48,
    child: IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      icon: Icon(icon, color: WeekGlassPalette.of(context).muted, size: 21),
    ),
  );
}
