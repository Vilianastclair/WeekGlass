import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

import '../cloud/cloud_service_button.dart';
import '../course_import/course_import_dialog.dart';
import 'calendar_grid.dart';
import 'event_editor_dialog.dart';
import 'planner_controller.dart';
import 'planner_settings_dialog.dart';
import 'planner_actions.dart';
import 'sidebar_action.dart';

class PlannerScreen extends StatelessWidget {
  const PlannerScreen({super.key, required this.controller});
  final PlannerController controller;

  @override
  Widget build(BuildContext context) {
    final p = WeekGlassPalette.of(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(
          LogicalKeyboardKey.arrowLeft,
          control: true,
        ): () =>
            controller.navigatePeriod(-1),
        const SingleActivator(
          LogicalKeyboardKey.arrowRight,
          control: true,
        ): () =>
            controller.navigatePeriod(1),
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () =>
            controller.undo(),
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () =>
            openEventEditor(
              context,
              controller: controller,
              date: controller.anchorDate,
            ),
        const SingleActivator(LogicalKeyboardKey.keyI, control: true): () =>
            openCourseImport(context, controller),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: p.canvas,
          body: DecoratedBox(
            decoration: BoxDecoration(
              image: DecorationImage(
                image: const AssetImage('assets/brand/atmosphere.png'),
                fit: BoxFit.cover,
                opacity: p.atmosphereOpacity,
                colorFilter: p.atmosphereFilter,
              ),
            ),
            child: LiquidGlassSurface(
              background: true,
              colorKey: 'mist_blue',
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      _FloatingPane(
                        key: const ValueKey('sidebar-surface'),
                        palette: p,
                        child: ClipRRect(
                          borderRadius: WeekGlassGeometry.corners,
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                            child: Container(
                              width: 44,
                              decoration: p.glassDecoration(),
                              child: Column(
                                children: [
                                  const SizedBox(height: 10),
                                  Tooltip(
                                    message: 'WeekGlass 周计划',
                                    child: Image.asset(
                                      'assets/brand/mark.png',
                                      width: 28,
                                      height: 28,
                                    ),
                                  ),
                                  const SizedBox(height: 15),
                                  Expanded(
                                    child: SingleChildScrollView(
                                      child: Column(
                                        children: [
                                          for (final action
                                              in SidebarAction.values)
                                            if (action != SidebarAction.cloud &&
                                                controller.sidebarActions
                                                    .contains(action))
                                              if (action ==
                                                  SidebarAction.view) ...[
                                                if (!Platform.isWindows)
                                                  _ViewMenu(
                                                    controller: controller,
                                                  ),
                                              ] else
                                                _RailButton(
                                                  icon: action.icon,
                                                  label: action.label,
                                                  hint:
                                                      action ==
                                                          SidebarAction.undo
                                                      ? controller.undoLabel
                                                      : action.label,
                                                  primary:
                                                      action ==
                                                      SidebarAction.create,
                                                  onTap:
                                                      action ==
                                                              SidebarAction
                                                                  .undo &&
                                                          !controller.canUndo
                                                      ? null
                                                      : () => openPlannerAction(
                                                          context,
                                                          controller,
                                                          action,
                                                        ),
                                                ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  if (controller.cloud != null &&
                                      controller.sidebarActions.contains(
                                        SidebarAction.cloud,
                                      ))
                                    CloudServiceButton.rail(
                                      key: const ValueKey('rail-cloud-service'),
                                      onPressed: () => openPlannerAction(
                                        context,
                                        controller,
                                        SidebarAction.cloud,
                                      ),
                                    ),
                                  _RailButton(
                                    icon: Icons.tune_rounded,
                                    label: '设置',
                                    hint: '打开设置',
                                    onTap: () => openPlannerSettings(
                                      context,
                                      controller,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          children: [
                            _CompactBar(controller: controller),
                            const SizedBox(height: 8),
                            Expanded(
                              child: _FloatingPane(
                                key: const ValueKey('calendar-surface'),
                                palette: p,
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 180),
                                  switchInCurve: Curves.easeOutCubic,
                                  transitionBuilder: (child, animation) =>
                                      FadeTransition(
                                        opacity: animation,
                                        child: SlideTransition(
                                          position: Tween(
                                            begin: const Offset(.012, 0),
                                            end: Offset.zero,
                                          ).animate(animation),
                                          child: child,
                                        ),
                                      ),
                                  child: CalendarGrid(
                                    key: ValueKey(
                                      '${controller.view.name}-${controller.anchorDate}-${controller.sleep.visibleStart}-${controller.sleep.visibleEnd}',
                                    ),
                                    controller: controller,
                                  ),
                                ),
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
        ),
      ),
    );
  }
}

class _FloatingPane extends StatelessWidget {
  const _FloatingPane({super.key, required this.palette, required this.child});
  final WeekGlassPalette palette;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final dark = palette.isDark;
    return GlassShadow(
      shadows: [
        BoxShadow(
          color: palette.shadow.withValues(alpha: dark ? .34 : .16),
          blurRadius: 20,
          spreadRadius: -3,
          offset: const Offset(0, 7),
        ),
        BoxShadow(
          color: palette.shadow.withValues(alpha: dark ? .20 : .09),
          blurRadius: 6,
          offset: const Offset(0, 2),
        ),
      ],
      child: child,
    );
  }
}

class _CompactBar extends StatelessWidget {
  const _CompactBar({required this.controller});
  final PlannerController controller;

  Future<void> _pickDate(BuildContext context) async {
    final date = await showDatePicker(
      context: context,
      initialDate: controller.anchorDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: '跳转到日期',
    );
    if (date != null) controller.setAnchorDate(date);
  }

  @override
  Widget build(BuildContext context) {
    final p = WeekGlassPalette.of(context);
    final start = controller.visibleDays.first;
    final end = controller.visibleDays.last;
    final fullRange =
        '${start.year}年${start.month}月${start.day}日 – ${end.year != start.year ? '${end.year}年' : ''}${end.month}月${end.day}日';
    final term = controller.visibleTeachingTerm;
    return SizedBox(
      height: (MediaQuery.textScalerOf(context).scale(16) * 1.2 + 12).clamp(
        38.0,
        double.infinity,
      ),
      child: LayoutBuilder(
        builder: (context, size) {
          final windowControls = Platform.isWindows && size.maxWidth >= 600;
          final compact =
              size.maxWidth < 600 ||
              (size.maxWidth < 900 &&
                  MediaQuery.textScalerOf(context).scale(1) > 1.1);
          final small = size.maxWidth < 400;
          final range = small
              ? '${start.month}.${start.day.toString().padLeft(2, '0')} – ${end.month}.${end.day.toString().padLeft(2, '0')}'
              : '${start.month}月${start.day.toString().padLeft(2, '0')}日 — ${start.month == end.month ? '' : '${end.month}月'}${end.day.toString().padLeft(2, '0')}日';
          final teaching = controller.teachingWeekLabel;
          return Row(
            children: [
              Flexible(
                flex: compact ? 6 : 0,
                child: _ChronologySurface(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _RailButton(
                        icon: Icons.chevron_left_rounded,
                        label: '上一时段',
                        hint: '上一时段 · Ctrl+←',
                        onTap: () => controller.navigatePeriod(-1),
                      ),
                      Flexible(
                        flex: compact ? 1 : 0,
                        child: Tooltip(
                          message: '$fullRange · 跳转到日期',
                          child: Semantics(
                            button: true,
                            label: '$fullRange，跳转到日期',
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                key: const ValueKey('date-jump'),
                                borderRadius: WeekGlassGeometry.corners,
                                hoverColor: p.accent.withValues(alpha: .10),
                                onTap: () => _pickDate(context),
                                child: Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: small ? 2 : 10,
                                    vertical: 5,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (!compact) ...[
                                        Text(
                                          start.year == end.year
                                              ? '${start.year}'
                                              : '${start.year}–${end.year.toString().substring(2)}',
                                          style: TextStyle(
                                            color: p.muted,
                                            fontSize: 10,
                                            letterSpacing: 1.2,
                                            fontFeatures: const [
                                              FontFeature.tabularFigures(),
                                            ],
                                          ),
                                        ),
                                        Container(
                                          width: 1,
                                          height: 13,
                                          margin: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                          ),
                                          color: p.lineStrong.withValues(
                                            alpha: .6,
                                          ),
                                        ),
                                      ],
                                      Flexible(
                                        flex: compact ? 1 : 0,
                                        child: Text(
                                          range,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: p.text,
                                            fontSize: small ? 11 : 13,
                                            fontWeight: FontWeight.w600,
                                            letterSpacing: .3,
                                            fontFeatures: const [
                                              FontFeature.tabularFigures(),
                                            ],
                                          ),
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
                      _RailButton(
                        icon: Icons.chevron_right_rounded,
                        label: '下一时段',
                        hint: '下一时段 · Ctrl+→',
                        onTap: () => controller.navigatePeriod(1),
                      ),
                    ],
                  ),
                ),
              ),
              if (teaching != null && term != null) ...[
                SizedBox(width: small ? 6 : 10),
                Flexible(
                  flex: compact ? 4 : 0,
                  child: Tooltip(
                    message: '${term.year}–${term.year + 1} 学年 · $teaching',
                    child: _ChronologySurface(
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: small ? 8 : 14,
                          vertical: 6,
                        ),
                        child: Text.rich(
                          key: const ValueKey('teaching-week-label'),
                          TextSpan(
                            children: [
                              TextSpan(
                                text: small
                                    ? '${term.number}学期'
                                    : '第 ${term.number} 学期',
                              ),
                              TextSpan(
                                text: small ? ' · ' : '   ·   ',
                                style: TextStyle(color: p.mutedSoft),
                              ),
                              TextSpan(
                                text: '${term.weekAt(controller.anchorDate)}',
                                style: TextStyle(
                                  color: p.accentStrong,
                                  fontSize: small ? 13 : 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const TextSpan(text: ' 周'),
                            ],
                          ),
                          semanticsLabel: teaching,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: p.muted,
                            fontSize: small ? 10 : 11,
                            height: 1.15,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
              Expanded(
                flex: compact ? 0 : 1,
                child: Platform.isWindows && !compact
                    ? DragToMoveArea(
                        child: Container(color: Colors.transparent),
                      )
                    : const SizedBox(),
              ),
              if (windowControls) ...[
                _RailButton(
                  icon: Icons.remove_rounded,
                  label: '最小化',
                  hint: '最小化',
                  onTap: () => windowManager.minimize(),
                ),
                _RailButton(
                  icon: Icons.crop_square_rounded,
                  label: '最大化或还原',
                  hint: '最大化 / 还原 · 拖动空白处移动窗口',
                  onTap: () async {
                    if (await windowManager.isMaximized()) {
                      await windowManager.unmaximize();
                    } else {
                      await windowManager.maximize();
                    }
                  },
                ),
                _RailButton(
                  icon: Icons.close_rounded,
                  label: '收起到托盘',
                  hint: '收起到托盘',
                  onTap: () => windowManager.close(),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Compact instrument surfaces share the calendar's optics and corner geometry.
class _ChronologySurface extends StatelessWidget {
  const _ChronologySurface({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final p = WeekGlassPalette.of(context);
    return GlassShadow(
      shadows: [
        BoxShadow(
          color: p.shadow.withValues(alpha: dark ? .26 : .12),
          blurRadius: 14,
          offset: const Offset(0, 4),
        ),
      ],
      child: ClipRRect(
        borderRadius: WeekGlassGeometry.corners,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: DecoratedBox(
            decoration: p.glassDecoration(layer: GlassLayer.control),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _RailButton extends StatefulWidget {
  const _RailButton({
    required this.icon,
    required this.label,
    required this.hint,
    this.onTap,
    this.primary = false,
  });
  final IconData icon;
  final String label;
  final String hint;
  final VoidCallback? onTap;
  final bool primary;
  @override
  State<_RailButton> createState() => _RailButtonState();
}

class _RailButtonState extends State<_RailButton> {
  bool hover = false;
  @override
  Widget build(BuildContext context) {
    final p = WeekGlassPalette.of(context);
    final active = hover;
    return Tooltip(
      message: widget.hint,
      waitDuration: const Duration(milliseconds: 180),
      child: Semantics(
        button: true,
        label: widget.label,
        enabled: widget.onTap != null,
        child: MouseRegion(
          cursor: widget.onTap == null
              ? SystemMouseCursors.basic
              : SystemMouseCursors.click,
          onEnter: (_) => setState(() => hover = true),
          onExit: (_) => setState(() => hover = false),
          child: AnimatedScale(
            scale: active && widget.onTap != null ? 1.08 : 1,
            duration: const Duration(milliseconds: 140),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              margin: const EdgeInsets.all(2),
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: widget.primary
                    ? p.accentSoft
                    : active
                    ? p.surfaceHover
                    : Colors.transparent,
                borderRadius: WeekGlassGeometry.corners,
                border: active ? Border.all(color: p.lineStrong) : null,
              ),
              child: IconButton(
                onPressed: widget.onTap,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 30,
                  height: 30,
                ),
                iconSize: 17,
                color: widget.primary ? p.accentStrong : p.muted,
                disabledColor: p.mutedSoft.withValues(alpha: .35),
                icon: Icon(widget.icon),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ViewMenu extends StatelessWidget {
  const _ViewMenu({required this.controller});
  final PlannerController controller;
  @override
  Widget build(BuildContext context) => PopupMenuButton<PlannerView>(
    tooltip:
        '切换视图 · 当前${switch (controller.view) {
          PlannerView.day => '日视图',
          PlannerView.threeDays => '三日视图',
          PlannerView.week => '周视图',
        }}',
    icon: const Icon(Icons.calendar_view_week_outlined, size: 17),
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(minWidth: 130),
    onSelected: controller.setView,
    itemBuilder: (_) => [
      for (final entry in [
        (PlannerView.day, '日视图'),
        (PlannerView.threeDays, '三日视图'),
        (PlannerView.week, '周视图'),
      ])
        CheckedPopupMenuItem(
          value: entry.$1,
          checked: controller.view == entry.$1,
          child: Text(entry.$2),
        ),
    ],
  );
}
