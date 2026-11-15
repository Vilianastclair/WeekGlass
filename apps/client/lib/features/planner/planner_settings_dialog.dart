import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:weekglass_domain/weekglass_domain.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

import 'planner_controller.dart';
import 'sidebar_action.dart';
import 'planner_actions.dart';
import 'skin_picker_dialog.dart';
import '../../app/event_reminders.dart';
import '../cloud/cloud_settings_dialog.dart';
import '../updates/update_service.dart';
import '../updates/update_settings_tile.dart';

Future<void> openPlannerSettings(
  BuildContext context,
  PlannerController controller,
) => showDialog<void>(
  context: context,
  builder: (_) => _SettingsDialog(controller: controller),
);

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog({required this.controller});
  final PlannerController controller;
  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late bool enabled = widget.controller.sleep.enabled;
  late int sleep = widget.controller.sleep.sleepMinute;
  late int wake = widget.controller.sleep.wakeMinute;
  late bool showTeachingWeek = widget.controller.showTeachingWeek;
  late bool notifications = widget.controller.notificationsEnabled;
  String? notificationStatus;
  String? error;
  bool saving = false;
  late final Set<SidebarAction> shortcuts = {
    ...widget.controller.sidebarActions,
  };
  String time(int value) =>
      '${(value ~/ 60).toString().padLeft(2, '0')}:${(value % 60).toString().padLeft(2, '0')}';
  Future<void> pick(bool bedtime) async {
    final value = bedtime ? sleep : wake;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: value ~/ 60, minute: value % 60),
      helpText: bedtime ? '入睡时间' : '起床时间',
    );
    if (picked != null && mounted) {
      setState(() {
        if (bedtime) {
          sleep = picked.hour * 60 + picked.minute;
        } else {
          wake = picked.hour * 60 + picked.minute;
        }
        error = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) => GlassAlertDialog(
    title: const Text('设置'),
    content: SizedBox(
      width: 360,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _ProjectSupportActions(),
            const Divider(height: 24),
            if (widget.controller.cloud case final cloud?) ...[
              AnimatedBuilder(
                animation: cloud,
                builder: (context, _) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.cloud_outlined),
                  title: const Text('云同步'),
                  subtitle: Text(
                    cloud.connected ? cloud.displayName : '官方托管 · 自托管',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => openCloudSettings(context, cloud),
                ),
              ),
              const Divider(height: 28),
            ],
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('睡眠时段'),
              subtitle: Text(
                !enabled && widget.controller.sleepConflictCount > 0
                    ? '已有 ${widget.controller.sleepConflictCount} 条日程位于该时段，当前保留完整显示'
                    : '不显示，也不安排日程',
              ),
              value: enabled,
              onChanged: saving
                  ? null
                  : (value) => setState(() {
                      enabled = value;
                      error = null;
                    }),
            ),
            if (enabled) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: saving ? null : () => pick(true),
                      child: Text('入睡 ${time(sleep)}'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: saving ? null : () => pick(false),
                      child: Text('起床 ${time(wake)}'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '日历显示 ${time(wake)} – ${sleep <= wake ? '次日 ' : ''}${time(sleep)}。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const Divider(height: 28),
            Text('显示', style: Theme.of(context).textTheme.titleSmall),
            ExpansionTile(
              key: const ValueKey('sidebar-customization'),
              tilePadding: EdgeInsets.zero,
              title: Text(Platform.isAndroid ? '快捷操作' : '侧边栏'),
              subtitle: Text(
                Platform.isAndroid ? '选择底部和更多菜单的功能，设置始终保留' : '选择常用功能，设置始终保留',
              ),
              children: [
                for (final action in SidebarAction.values)
                  if ((action != SidebarAction.view || !Platform.isWindows) &&
                      (action != SidebarAction.cloud ||
                          widget.controller.cloud != null))
                    CheckboxListTile(
                      key: ValueKey('sidebar-${action.name}'),
                      contentPadding: EdgeInsets.zero,
                      title: Row(
                        children: [
                          Icon(action.icon, size: 18),
                          const SizedBox(width: 10),
                          Text(action.label),
                        ],
                      ),
                      value: shortcuts.contains(action),
                      onChanged: saving
                          ? null
                          : (value) => setState(() {
                              if (value == true) {
                                shortcuts.add(action);
                              } else {
                                shortcuts.remove(action);
                              }
                            }),
                    ),
              ],
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.file_download_outlined),
              title: const Text('导入日程'),
              onTap: () => openPlannerAction(
                context,
                widget.controller,
                SidebarAction.importEvents,
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.ios_share_rounded),
              title: const Text('导出日程'),
              onTap: () => openPlannerAction(
                context,
                widget.controller,
                SidebarAction.exportEvents,
              ),
            ),
            if (widget.controller.whuConnected)
              CheckboxListTile(
                key: const ValueKey('show-teaching-week'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text(
                  '在顶部日期旁显示教学周',
                  style: TextStyle(fontSize: 13),
                ),
                subtitle: const Text('随当前查看日期变化'),
                value: showTeachingWeek,
                onChanged: saving
                    ? null
                    : (value) => setState(() => showTeachingWeek = value!),
              ),
            AnimatedBuilder(
              animation: widget.controller,
              builder: (context, _) => ListTile(
                key: const ValueKey('appearance-settings'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  Icons.palette_outlined,
                  color: WeekGlassPalette.of(context).accentStrong,
                ),
                title: const Text('皮肤与外观'),
                subtitle: Text(
                  '${widget.controller.skin.label} · ${switch (widget.controller.themeMode) {
                    ThemeMode.light => '浅色',
                    ThemeMode.dark => '深色',
                    ThemeMode.system => '跟随系统',
                  }}',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: saving
                    ? null
                    : () => openSkinPicker(context, widget.controller),
              ),
            ),
            if (Platform.isWindows) ...[
              const Divider(height: 28),
              Text('通知', style: Theme.of(context).textTheme.titleSmall),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('日程开始或结束时通知', style: TextStyle(fontSize: 13)),
                subtitle: const Text('收起到托盘后继续提醒'),
                value: notifications,
                onChanged: saving
                    ? null
                    : (value) => setState(() => notifications = value!),
              ),
              TextButton.icon(
                icon: const Icon(Icons.notifications_outlined, size: 18),
                label: const Text('发送测试通知'),
                onPressed: () async {
                  try {
                    final ok = await WindowsReminders.testNotification();
                    if (mounted) {
                      setState(
                        () => notificationStatus = ok
                            ? '已发送；若未看到，请检查 Windows 通知与勿扰设置。'
                            : '发送失败，请稍后重试。',
                      );
                    }
                  } catch (_) {
                    if (mounted) {
                      setState(() => notificationStatus = '发送失败，请稍后重试。');
                    }
                  }
                },
              ),
              if (notificationStatus != null)
                Text(
                  notificationStatus!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
            const Divider(height: 28),
            UpdateSettingsTile(service: UpdateService.instance),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: saving ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: saving
            ? null
            : () async {
                setState(() {
                  saving = true;
                  error = null;
                });
                try {
                  await widget.controller.setSleepSchedule(
                    SleepSchedule(
                      enabled: enabled,
                      sleepMinute: sleep,
                      wakeMinute: wake,
                    ),
                  );
                  if (widget.controller.whuConnected) {
                    await widget.controller.setTeachingWeekVisible(
                      showTeachingWeek,
                    );
                  }
                  if (Platform.isWindows) {
                    await widget.controller.setNotificationsEnabled(
                      notifications,
                    );
                  }
                  await widget.controller.saveSidebarActions(shortcuts);
                  if (context.mounted) Navigator.pop(context);
                } on ArgumentError catch (e) {
                  if (mounted) setState(() => error = e.message.toString());
                } catch (_) {
                  if (mounted) setState(() => error = '设置保存失败，请重试。');
                } finally {
                  if (mounted) setState(() => saving = false);
                }
              },
        child: const Text('保存'),
      ),
    ],
  );
}

class _ProjectSupportActions extends StatelessWidget {
  const _ProjectSupportActions();

  static final _support = Uri.https('cloud.viliana.cn', '/support');
  static final _repository = Uri.https(
    'github.com',
    '/Vilianastclair/WeekGlass',
  );

  @override
  Widget build(BuildContext context) {
    final palette = WeekGlassPalette.of(context);
    final style = OutlinedButton.styleFrom(
      foregroundColor: palette.text,
      backgroundColor: palette.surfaceSoft,
      side: BorderSide(color: palette.line),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    );
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        OutlinedButton.icon(
          style: style,
          onPressed: () => _open(context, _support),
          icon: Icon(
            Icons.favorite_border_rounded,
            color: palette.accentStrong,
            size: 17,
          ),
          label: const Text('微信赞赏'),
        ),
        OutlinedButton.icon(
          style: style,
          onPressed: () => _open(context, _repository),
          icon: Icon(
            Icons.star_border_rounded,
            color: palette.accentStrong,
            size: 17,
          ),
          label: const Text('GitHub Star'),
        ),
      ],
    );
  }

  Future<void> _open(BuildContext context, Uri uri) async {
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    } on PlatformException {
      // The system could not open a browser.
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => GlassAlertDialog(
        title: const Text('无法打开链接'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('可复制地址，在浏览器中打开。'),
            const SizedBox(height: 8),
            SelectableText(uri.toString()),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('返回设置'),
          ),
        ],
      ),
    );
  }
}
