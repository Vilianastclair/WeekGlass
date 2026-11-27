import 'package:flutter/material.dart';
import 'package:weekglass_domain/weekglass_domain.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

import '../../app/event_reminders.dart';
import '../cloud/cloud_connection.dart';
import '../cloud/cloud_portal_link.dart';
import '../cloud/cloud_service_button.dart';
import '../cloud/cloud_settings_dialog.dart';
import '../updates/update_service.dart';
import '../updates/update_settings_tile.dart';
import 'planner_actions.dart';
import 'planner_controller.dart';
import 'sidebar_action.dart';
import 'skin_picker_dialog.dart';

Future<void> openPlannerSettings(
  BuildContext context,
  PlannerController controller, {
  UpdateService? updateService,
}) => showDialog<void>(
  context: context,
  builder: (_) => _SettingsDialog(
    controller: controller,
    updateService: updateService ?? UpdateService.instance,
  ),
);

enum _SettingsPage {
  home('设置'),
  calendar('日历与外观'),
  shortcuts('快捷操作'),
  data('本机日程'),
  system('软件与通知');

  const _SettingsPage(this.label);
  final String label;
}

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog({
    required this.controller,
    required this.updateService,
  });
  final PlannerController controller;
  final UpdateService updateService;

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  _SettingsPage _page = _SettingsPage.home;
  PlannerController get controller => widget.controller;
  bool get _windows => Theme.of(context).platform == TargetPlatform.windows;
  bool get _iPhone => Theme.of(context).platform == TargetPlatform.iOS;
  bool get _home => _page == _SettingsPage.home;

  String _pageLabel(_SettingsPage page) =>
      page == _SettingsPage.system && !_windows ? '软件更新' : page.label;
  bool get _editable => switch (_page) {
    _SettingsPage.calendar || _SettingsPage.shortcuts => true,
    _SettingsPage.system => _windows,
    _ => false,
  };

  late SleepSchedule _originalSleep;
  late bool _sleepEnabled;
  late int _sleep;
  late int _wake;
  late bool _showTeachingWeek;
  late bool _notifications;
  late Set<SidebarAction> _shortcuts;
  String? _notificationStatus;
  String? _error;
  bool _saving = false;

  void _open(_SettingsPage page) {
    setState(() {
      _page = page;
      _originalSleep = controller.sleep;
      _sleepEnabled = _originalSleep.enabled;
      _sleep = _originalSleep.sleepMinute;
      _wake = _originalSleep.wakeMinute;
      _showTeachingWeek = controller.showTeachingWeek;
      _notifications = controller.notificationsEnabled;
      _shortcuts = {...controller.sidebarActions};
      _notificationStatus = null;
      _error = null;
    });
  }

  void _back() {
    if (_saving) return;
    if (_home) {
      Navigator.pop(context);
    } else {
      setState(() {
        _page = _SettingsPage.home;
        _error = null;
      });
    }
  }

  String _time(int minutes) =>
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

  Future<void> _pick(bool bedtime) async {
    final value = bedtime ? _sleep : _wake;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: value ~/ 60, minute: value % 60),
      helpText: bedtime ? '入睡时间' : '起床时间',
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (bedtime) {
        _sleep = picked.hour * 60 + picked.minute;
      } else {
        _wake = picked.hour * 60 + picked.minute;
      }
      _error = null;
    });
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      switch (_page) {
        case _SettingsPage.calendar:
          if (_sleepEnabled != _originalSleep.enabled ||
              _sleep != _originalSleep.sleepMinute ||
              _wake != _originalSleep.wakeMinute) {
            await controller.setSleepSchedule(
              SleepSchedule(
                enabled: _sleepEnabled,
                sleepMinute: _sleep,
                wakeMinute: _wake,
              ),
            );
          }
          if (controller.hasTeachingCalendar) {
            await controller.setTeachingWeekVisible(_showTeachingWeek);
          }
        case _SettingsPage.shortcuts:
          await controller.saveSidebarActions(_shortcuts);
        case _SettingsPage.system:
          await controller.setNotificationsEnabled(_notifications);
        case _SettingsPage.home || _SettingsPage.data:
          break;
      }
      if (mounted) setState(() => _page = _SettingsPage.home);
    } on ArgumentError catch (error) {
      if (mounted) setState(() => _error = error.message.toString());
    } catch (_) {
      if (mounted) setState(() => _error = '设置保存失败，请重试。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    return PopScope<void>(
      canPop: _home && !_saving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_home) _back();
      },
      child: GlassAlertDialog(
        insetPadding: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 32,
          vertical: compact ? 12 : 20,
        ),
        titlePadding: EdgeInsets.fromLTRB(compact ? 18 : 24, 10, 12, 0),
        contentPadding: EdgeInsets.fromLTRB(
          compact ? 18 : 24,
          4,
          compact ? 18 : 24,
          _editable ? 4 : 14,
        ),
        actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        title: Row(
          children: [
            if (!_home)
              IconButton(
                tooltip: '返回设置',
                onPressed: _saving ? null : _back,
                icon: const Icon(Icons.arrow_back_rounded),
              ),
            Expanded(child: Text(_pageLabel(_page))),
            if (_home)
              IconButton(
                tooltip: '关闭设置',
                onPressed: _back,
                icon: const Icon(Icons.close_rounded),
              ),
          ],
        ),
        content: SizedBox(
          width: 450,
          child: SingleChildScrollView(
            key: ValueKey(_page),
            child: AnimatedBuilder(
              animation: controller,
              builder: (context, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...switch (_page) {
                    _SettingsPage.home => _homeContent(context),
                    _SettingsPage.calendar => _calendarContent(context),
                    _SettingsPage.shortcuts => _shortcutContent(context),
                    _SettingsPage.data => _dataContent(context),
                    _SettingsPage.system => _systemContent(context),
                  },
                  if (_error case final error?)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        actions: _editable
            ? [
                TextButton(
                  onPressed: _saving ? null : _back,
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: const Text('保存'),
                ),
              ]
            : null,
      ),
    );
  }

  List<Widget> _homeContent(BuildContext context) {
    final palette = WeekGlassPalette.of(context);
    final cloud = controller.cloud;
    return [
      const _SupportLink.star(),
      if (cloud != null) ...[
        const SizedBox(height: 12),
        ListenableBuilder(
          listenable: cloud,
          builder: (context, _) {
            final selfHosted = cloud.connected && !cloud.auth.official;
            final state = cloud.subscriptionState;
            return CloudServiceButton.entry(
              key: const ValueKey('cloud-service-entry'),
              state: selfHosted ? null : state,
              detail: selfHosted
                  ? '已连接自己的服务器'
                  : switch (state) {
                      CloudSubscriptionState.signedOut => '连接官方云或自托管',
                      CloudSubscriptionState.checking => '确认服务状态后才能同步日程',
                      CloudSubscriptionState.notSubscribed => '开通后才能跨设备同步日程',
                      CloudSubscriptionState.active => '管理此设备的同步',
                      CloudSubscriptionState.expired => '同步已暂停，本机日程照常使用',
                    },
              onPressed: () => openCloudSettings(context, cloud),
            );
          },
        ),
      ],
      const SizedBox(height: 12),
      Padding(
        padding: const EdgeInsets.only(left: 8, bottom: 5),
        child: Text(
          '本机设置',
          style: Theme.of(context).textTheme.labelMedium
              ?.copyWith(color: palette.muted, fontWeight: FontWeight.w600),
        ),
      ),
      DecoratedBox(
        decoration: BoxDecoration(
          color: palette.surfaceSoft,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          children: [
            _SettingsRow(
              icon: Icons.palette_outlined,
              title: _SettingsPage.calendar.label,
              subtitle: '皮肤与睡眠时段',
              onTap: () => _open(_SettingsPage.calendar),
            ),
            _SettingsRow(
              icon: Icons.dashboard_customize_outlined,
              title: _SettingsPage.shortcuts.label,
              subtitle: _windows ? '自定义侧边栏' : '自定义底部和更多菜单',
              onTap: () => _open(_SettingsPage.shortcuts),
            ),
            _SettingsRow(
              icon: Icons.calendar_month_outlined,
              title: _SettingsPage.data.label,
              subtitle: '导入与导出',
              onTap: () => _open(_SettingsPage.data),
            ),
            if (!_iPhone)
              _SettingsRow(
                icon: Icons.settings_suggest_outlined,
                title: _pageLabel(_SettingsPage.system),
                subtitle: _windows ? '日程提醒与软件更新' : '检查或安装新版本',
                onTap: () => _open(_SettingsPage.system),
              ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      const _SupportLink.sponsor(),
    ];
  }

  List<Widget> _calendarContent(BuildContext context) => [
    _SettingsRow(
      key: const ValueKey('appearance-settings'),
      icon: Icons.water_drop_outlined,
      title: '皮肤与外观',
      subtitle:
          '${controller.skin.label}，${switch (controller.themeMode) {
            ThemeMode.light => '浅色',
            ThemeMode.dark => '深色',
            ThemeMode.system => '跟随系统',
          }}',
      onTap: _saving ? null : () => openSkinPicker(context, controller),
    ),
    const Divider(height: 24),
    SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      title: const Text('睡眠时段'),
      subtitle: const Text('日历只显示清醒时段内的日程部分，原有时间不变'),
      value: _sleepEnabled,
      onChanged: _saving
          ? null
          : (value) => setState(() {
              _sleepEnabled = value;
              _error = null;
            }),
    ),
    if (_sleepEnabled) ...[
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          OutlinedButton(
            onPressed: _saving ? null : () => _pick(true),
            child: Text('入睡 ${_time(_sleep)}'),
          ),
          OutlinedButton(
            onPressed: _saving ? null : () => _pick(false),
            child: Text('起床 ${_time(_wake)}'),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        '日历显示 ${_time(_wake)} 至 ${_sleep <= _wake ? '次日 ' : ''}${_time(_sleep)}。',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ],
    if (controller.hasTeachingCalendar) ...[
      const Divider(height: 24),
      CheckboxListTile(
        key: const ValueKey('show-teaching-week'),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: const Text('在顶部日期旁显示教学周'),
        subtitle: const Text('随当前查看日期变化'),
        value: _showTeachingWeek,
        onChanged: _saving
            ? null
            : (value) => setState(() => _showTeachingWeek = value!),
      ),
    ],
  ];

  List<Widget> _shortcutContent(BuildContext context) => [
    Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        _windows ? '选择侧边栏要显示的工具。设置始终保留。' : '选择底部和更多菜单的工具。设置始终保留。',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    ),
    for (final action in SidebarAction.values)
      if (action.availableOn(Theme.of(context).platform) &&
          (action != SidebarAction.view || !_windows) &&
          (action != SidebarAction.cloud || controller.cloud != null))
        CheckboxListTile(
          key: ValueKey('sidebar-${action.name}'),
          contentPadding: EdgeInsets.zero,
          secondary: Icon(action.icon, size: 19),
          title: Text(action.label),
          value: _shortcuts.contains(action),
          onChanged: _saving
              ? null
              : (value) => setState(() {
                  if (value == true) {
                    _shortcuts.add(action);
                  } else {
                    _shortcuts.remove(action);
                  }
                }),
        ),
  ];

  List<Widget> _dataContent(BuildContext context) => [
    for (final (action, text) in [
      (SidebarAction.importEvents, _iPhone ? 'ICS、CSV 或 JSON' : '从日历文件或课表图片导入'),
      (SidebarAction.courses, '从学校教务系统导入'),
      (SidebarAction.exportEvents, '导出或打印此设备的日程'),
    ])
      if (action.availableOn(Theme.of(context).platform))
        _SettingsRow(
          icon: action.icon,
          title: action.label,
          subtitle: text,
          onTap: () => openPlannerAction(context, controller, action),
        ),
  ];

  List<Widget> _systemContent(BuildContext context) => [
    if (_windows) ...[
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: const Text('日程开始或结束时通知'),
        subtitle: const Text('收起到托盘后继续提醒'),
        value: _notifications,
        onChanged: _saving
            ? null
            : (value) => setState(() => _notifications = value!),
      ),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          icon: const Icon(Icons.notifications_outlined, size: 18),
          label: const Text('发送测试通知'),
          onPressed: _saving ? null : _testNotification,
        ),
      ),
      if (_notificationStatus case final status?)
        Text(status, style: Theme.of(context).textTheme.bodySmall),
      const Divider(height: 24),
    ],
    UpdateSettingsTile(service: widget.updateService, showTitle: _windows),
  ];

  Future<void> _testNotification() async {
    var sent = false;
    try {
      sent = await WindowsReminders.testNotification();
    } catch (_) {
      // The Windows notification service can be unavailable.
    }
    if (mounted && _page == _SettingsPage.system) {
      setState(
        () => _notificationStatus = sent
            ? '已发送。如未收到，请检查 Windows 通知与勿扰设置。'
            : '发送失败，请稍后重试。',
      );
    }
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title, subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = WeekGlassPalette.of(context);
    final text = Theme.of(context).textTheme;
    final corners = BorderRadius.circular(12);
    return Material(
      type: MaterialType.transparency,
      borderRadius: corners,
      child: InkWell(
        onTap: onTap,
        borderRadius: corners,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 7, 10, 7),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 38),
            child: Row(
              children: [
                Icon(icon, size: 21, color: palette.accentStrong),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: text.titleSmall),
                      Text(
                        subtitle,
                        style: text.bodySmall?.copyWith(color: palette.muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: palette.muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SupportLink extends StatelessWidget {
  const _SupportLink.star() : star = true;
  const _SupportLink.sponsor() : star = false;

  final bool star;

  @override
  Widget build(BuildContext context) {
    final palette = WeekGlassPalette.of(context);
    final style = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: palette.muted, fontSize: 13);
    final corners = BorderRadius.circular(10);
    return Material(
      type: MaterialType.transparency,
      borderRadius: corners,
      child: InkWell(
        key: ValueKey(star ? 'github-star' : 'sponsorship'),
        borderRadius: corners,
        onTap: () => openBrowserLink(
          context,
          Uri.parse(
            star
                ? 'https://github.com/Vilianastclair/WeekGlass'
                : 'https://cloud.viliana.cn/support',
          ),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                Icon(
                  star ? Icons.star_rounded : Icons.favorite_border_rounded,
                  color: star
                      ? (palette.isDark
                            ? const Color(0xFFF5CC77)
                            : const Color(0xFF96621C))
                      : palette.accentStrong,
                  size: 19,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: star
                      ? Text.rich(
                          TextSpan(
                            text: '有帮助的话还请在 ',
                            children: [
                              TextSpan(
                                text: 'GitHub 点个 Star',
                                style: style?.copyWith(
                                  color: palette.text,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const TextSpan(text: '，这对我真的很重要'),
                            ],
                          ),
                          style: style,
                        )
                      : Text('友情赞助', style: style),
                ),
                const SizedBox(width: 6),
                Icon(
                  Icons.arrow_outward_rounded,
                  size: 15,
                  color: palette.muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
