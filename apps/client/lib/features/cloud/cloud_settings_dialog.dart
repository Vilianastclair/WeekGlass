import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:weekglass_domain/weekglass_domain.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';
import 'package:window_manager/window_manager.dart';

import 'cloud_account_dialog.dart';
import 'cloud_auth_service.dart';
import 'cloud_connection.dart';
import 'cloud_portal_link.dart';
import 'cloud_service_button.dart';
import 'cloud_subscription_state_chip.dart';
import 'cloud_sync_engine.dart';

Future<void> openCloudSettings(BuildContext context, CloudConnection cloud) =>
    showDialog<void>(
      context: context,
      builder: (_) => _CloudDialog(cloud: cloud),
    );

class _CloudDialog extends StatefulWidget {
  const _CloudDialog({required this.cloud});
  final CloudConnection cloud;

  @override
  State<_CloudDialog> createState() => _CloudDialogState();
}

class _CloudDialogState extends State<_CloudDialog> {
  bool hosted = true;
  final address = TextEditingController();
  String? localError;
  bool _ownsLogin = false;
  bool _refreshing = false;
  bool _browserOpened = false;
  CloudConnection get cloud => widget.cloud;

  @override
  void initState() {
    super.initState();
    unawaited(cloud.loadOfficialIdentity());
  }

  Future<void> login() async {
    if (_ownsLogin) return;
    _ownsLogin = true;
    setState(() {
      localError = null;
      _browserOpened = false;
    });
    try {
      await cloud.login(hosted ? officialCloudOrigin : address.text);
      if (!mounted || !_ownsLogin) return;
      unawaited(cloud.loadOfficialIdentity());
      await cloud.waitForEntitlements();
      if (!mounted ||
          !_ownsLogin ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      _ownsLogin = false;
      // Hosted registration continues in the browser. Only show merge after
      // a successful connection whose service is actually active.
      if (cloud.canSync && !cloud.auth.mergeApproved) {
        unawaited(_returnToWindow());
        await confirmMerge();
      }
    } catch (error) {
      if (mounted) setState(() => localError = cloudErrorMessage(error));
    } finally {
      _ownsLogin = false;
    }
  }

  void _cancelOwnedLogin() {
    if (!_ownsLogin) return;
    _ownsLogin = false;
    cloud.cancelLogin();
  }

  Future<void> _returnToWindow() async {
    if (!mounted) return;
    try {
      if (Platform.isMacOS) {
        await const MethodChannel('weekglass/desktop').invokeMethod<void>('showPlanner');
      } else if (Platform.isWindows) {
        await windowManager.show();
        if (mounted) await windowManager.focus();
      }
    } catch (_) {
      // The confirmed connection remains visible when the user returns.
    }
  }

  Future<void> confirmMerge() async {
    if (!cloud.canSync) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => GlassAlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        title: const Text('合并并同步日程'),
        content: SizedBox(
          width: 390,
          child: Text(
            '将本机所有日程（包括曾从其他账号下载的日程）与${cloud.displayName}中的日程合并。服务器支持时也会同步睡眠时段；遇到冲突时由你选择保留的版本。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('暂不合并'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('合并并同步'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(cloud.approveAndConnect);
  }

  Future<void> disconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => GlassAlertDialog(
        title: const Text('断开连接？'),
        content: const Text('本机日程与未上传的修改会保留。重新连接同一账号后可继续同步。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('断开'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await _run(cloud.disconnect);
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => localError = null);
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => localError = cloudErrorMessage(error));
    }
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    await _run(cloud.refreshEntitlements);
    if (mounted) setState(() => _refreshing = false);
  }

  Future<void> _openPortal(CloudPortalPage page) async {
    final opened = await openCloudPortal(context, cloud.auth, page);
    if (mounted && opened && page == CloudPortalPage.plans) {
      setState(() => _browserOpened = true);
    }
  }

  Future<void> renameDevice(Map<String, dynamic> device) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _DeviceNameDialog(
        name: device['display_name'] as String? ?? 'WeekGlass',
      ),
    );
    if (mounted && name != null) {
      await _run(() => cloud.renameDevice(device, name));
    }
  }

  Future<void> revokeDevice(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => GlassAlertDialog(
        title: const Text('撤销此设备？'),
        content: const Text('此设备需重新登录才能同步，已有日程不会删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('撤销'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await _run(() => cloud.revokeDevice(id));
  }

  @override
  void dispose() {
    _cancelOwnedLogin();
    address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: cloud,
    builder: (context, _) => PopScope<void>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _cancelOwnedLogin();
      },
      child: GlassAlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
        title: const Text(CloudServiceButton.label),
        contentPadding: const EdgeInsets.fromLTRB(24, 14, 24, 8),
        actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        content: SizedBox(
          width: 410,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!cloud.connected)
                  ..._loginFields(context)
                else
                  ..._connectionControls(context),
                if (cloud.working || _refreshing)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                if (localError ??
                        cloud.problem ??
                        cloud.accountProblem ??
                        (cloud.canSync ? cloud.engine.error : null)
                    case final message?)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        message,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('完成'),
          ),
        ],
      ),
    ),
  );

  List<Widget> _loginFields(BuildContext context) {
    final theme = Theme.of(context);
    final narrow =
        MediaQuery.sizeOf(context).width < 520 ||
        MediaQuery.textScalerOf(context).scale(14) > 20;
    return [
      SegmentedButton<bool>(
        direction: narrow ? Axis.vertical : Axis.horizontal,
        segments: const [
          ButtonSegment(
            value: true,
            label: Text('WeekGlass 云'),
            icon: Icon(Icons.cloud_outlined),
          ),
          ButtonSegment(
            value: false,
            label: Text('自己的服务器'),
            icon: Icon(Icons.dns_outlined),
          ),
        ],
        selected: {hosted},
        onSelectionChanged: cloud.busy
            ? null
            : (v) => setState(() {
                hosted = v.single;
                localError = null;
              }),
      ),
      const SizedBox(height: 14),
      Text(
        hosted ? '开通云服务后才会同步日程，本机日程可免费使用。' : '自托管同步免费，由你的服务器保存日程。',
        style: theme.textTheme.bodyMedium,
      ),
      if (!hosted) ...[
        const SizedBox(height: 14),
        TextField(
          controller: address,
          enabled: !cloud.busy,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: '服务器地址',
            hintText: 'https://sync.example.com:8443',
          ),
        ),
      ],
      const SizedBox(height: 18),
      FilledButton.icon(
        onPressed: cloud.busy ? null : login,
        icon: const Icon(Icons.open_in_new_rounded, size: 18),
        label: const Text('在浏览器中登录'),
      ),
      if (hosted &&
          cloudSubscriptionLinksAllowed &&
          cloud.loginPhase == null) ...[
        const SizedBox(height: 10),
        _subscribeButton(),
        if (_browserOpened)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('开通后请在这里登录同一账号。', style: theme.textTheme.bodySmall),
          ),
      ],
      if (cloud.loginPhase case final phase?) ...[
        const SizedBox(height: 12),
        Semantics(
          liveRegion: true,
          child: Text(switch (phase) {
            CloudLoginPhase.checkingServer => '正在检查云服务器…',
            CloudLoginPhase.waitingForBrowser => '等待浏览器授权。请在浏览器中完成登录。',
            CloudLoginPhase.exchanging => '已收到浏览器回传，正在验证授权…',
            CloudLoginPhase.saving => '授权已验证，正在安全保存连接…',
          }),
        ),
        TextButton(onPressed: _cancelOwnedLogin, child: const Text('取消登录')),
      ],
    ];
  }

  List<Widget> _connectionControls(BuildContext context) {
    final theme = Theme.of(context);
    final official = cloud.auth.official;
    final state = cloud.subscriptionState;
    final end = cloud.currentPeriodEnd;
    final canSync = cloud.canSync;
    final pending = cloud.engine.pendingCount;
    final time = cloud.engine.lastSync;
    return [
      Wrap(
        spacing: 12,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(cloud.displayName, style: theme.textTheme.titleMedium),
          if (official) CloudSubscriptionStateChip(state: state),
        ],
      ),
      if (cloud.accountLabel case final String account)
        Text(account, style: theme.textTheme.bodySmall)
      else if (!official)
        Text(cloud.auth.origin!, style: theme.textTheme.bodySmall),
      const SizedBox(height: 12),
      if (official) ...[
        Semantics(
          liveRegion: true,
          child: Text(switch (state) {
            CloudSubscriptionState.active =>
              end == null ? '云服务已开通。' : '有效期至 ${_dateTime(end)}',
            CloudSubscriptionState.expired => '云服务已到期，已停止合并、上传和下载日程。本机修改会保留。',
            CloudSubscriptionState.notSubscribed =>
              '未开通云服务，不能合并或同步日程。本机日程照常使用。',
            _ => '尚未确认云服务状态，同步不会启动。',
          }, style: theme.textTheme.bodyMedium),
        ),
        if (!canSync && state == CloudSubscriptionState.expired)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => _openPortal(CloudPortalPage.calendar),
              icon: const Icon(Icons.download_outlined, size: 18),
              label: Text(
                cloud.entitlements?['export_allowed'] == false
                    ? '查看网页导出状态'
                    : '前往网页导出云端日程',
              ),
            ),
          ),
        if (!canSync && cloudSubscriptionLinksAllowed) ...[
          const SizedBox(height: 12),
          _subscribeButton(),
        ],
        if (_browserOpened && !canSync)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '请在浏览器中使用同一账号，完成后回来刷新订阅状态。',
              style: theme.textTheme.bodySmall,
            ),
          )
        else if (cloud.entitlementsStale && canSync)
          Text('显示上次确认的订阅状态。', style: theme.textTheme.bodySmall),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: _refreshing || cloud.working ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded, size: 17),
            label: Text(_refreshing ? '正在刷新…' : '刷新订阅状态'),
          ),
        ),
      ],
      if (canSync) ...[
        if (cloud.auth.mergeApproved) ...[
          Text(
            cloud.engine.busy
                ? '正在同步…'
                : pending > 0
                ? '$pending 条修改等待同步'
                : time == null
                ? '等待首次同步'
                : '本机修改已同步',
          ),
          if (time != null)
            Text('上次同步 ${_dateTime(time)}', style: theme.textTheme.bodySmall),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: cloud.busy ? null : () => _run(cloud.sync),
            icon: const Icon(Icons.sync_rounded, size: 18),
            label: const Text('立即同步'),
          ),
          if (!cloud.auth.sleepScheduleApproved) ...[
            const SizedBox(height: 12),
            const Text('在同一账号的设备之间同步睡眠和起床时间。'),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: cloud.busy
                    ? null
                    : () => _run(cloud.approveSleepSchedule),
                child: const Text('同步作息'),
              ),
            ),
          ],
          if (cloud.engine.conflicts.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              '${cloud.engine.conflicts.length} 个日程需要确认',
              style: theme.textTheme.titleSmall,
            ),
            for (final conflict in cloud.engine.conflicts)
              _conflict(context, conflict),
          ],
          if (cloud.engine.sleepScheduleConflict case final conflict?) ...[
            const SizedBox(height: 16),
            Text('请选择要保留的睡眠时段', style: theme.textTheme.titleSmall),
            _conflictChoices(
              context,
              local: _sleepSummary(conflict.local),
              remote: _sleepSummary(conflict.remote),
              resolve: (useLocal) => cloud.engine.resolveSleepScheduleConflict(
                conflict,
                useLocal: useLocal,
              ),
            ),
          ] else if (cloud.engine.sleepScheduleSupported == false)
            Text('此服务器尚不支持同步睡眠时段。', style: theme.textTheme.bodySmall),
        ] else ...[
          const Text('确认合并后才会开始同步本机日程。'),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: cloud.busy ? null : confirmMerge,
            child: const Text('合并日程'),
          ),
        ],
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            cloud.auth.sleepScheduleApproved
                ? '同步日程和睡眠时段，不上传学校登录凭据或其他本机设置。'
                : '不上传学校登录凭据或其他本机设置。',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
      if (official && canSync && cloudSubscriptionLinksAllowed) ...[
        const SizedBox(height: 12),
        _subscribeButton(),
      ],
      const Divider(height: 24),
      if (official)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.manage_accounts_outlined),
          title: const Text('云服务账号'),
          subtitle: const Text('订单、设备、安全与云端导出'),
          trailing: const Icon(Icons.open_in_new_rounded, size: 17),
          onTap: () => _openPortal(CloudPortalPage.account),
        )
      else ...[
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.manage_accounts_outlined),
          title: const Text('账号安全与云端导出'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: cloud.busy ? null : () => openCloudAccount(context, cloud),
        ),
        _selfHostedDevices(),
      ],
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          onPressed: cloud.busy ? null : disconnect,
          icon: const Icon(Icons.link_off_rounded, size: 18),
          label: const Text('断开连接'),
        ),
      ),
    ];
  }

  Widget _subscribeButton() => CloudServiceButton.subscription(
    key: const ValueKey('subscribe-cloud-service'),
    onPressed: cloud.working ? null : () => _openPortal(CloudPortalPage.plans),
  );

  Widget _conflict(BuildContext context, CloudConflict conflict) =>
      _conflictChoices(
        context,
        local: _summary(conflict.local),
        remote: _summary(conflict.remote),
        resolve: (useLocal) =>
            cloud.engine.resolveConflict(conflict.id, useLocal: useLocal),
      );

  String _sleepSummary(SleepSchedule schedule) {
    String clock(int minute) =>
        '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';
    final status = schedule.enabled ? '' : '（未启用）';
    return '睡眠 ${clock(schedule.sleepMinute)}，起床 ${clock(schedule.wakeMinute)}$status';
  }

  Widget _conflictChoices(
    BuildContext context, {
    required String local,
    required String remote,
    required Future<void> Function(bool useLocal) resolve,
  }) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: WeekGlassPalette.of(context).surfaceSoft,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('本机：$local'),
            const SizedBox(height: 8),
            Text('云端：$remote'),
            Wrap(
              spacing: 8,
              children: [
                for (final (label, useLocal) in [
                  ('保留本机', true),
                  ('采用云端', false),
                ])
                  TextButton(
                    onPressed: cloud.busy
                        ? null
                        : () => _run(() => resolve(useLocal)),
                    child: Text(label),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  Widget _selfHostedDevices() => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    leading: const Icon(Icons.devices_rounded),
    title: const Text('已连接设备'),
    children: [
      for (final device in cloud.devices.where((d) => d['revoked_at'] == null))
        ListTile(
          contentPadding: const EdgeInsets.only(left: 12),
          title: Text('${device['display_name'] ?? 'WeekGlass'}'),
          subtitle: device['device_id'] == cloud.auth.deviceId
              ? const Text('本机')
              : null,
          onTap: cloud.busy ? null : () => renameDevice(device),
          trailing: device['device_id'] == cloud.auth.deviceId
              ? null
              : IconButton(
                  tooltip: '撤销此设备',
                  icon: const Icon(Icons.link_off_rounded, size: 19),
                  onPressed: cloud.busy
                      ? null
                      : () => revokeDevice(device['device_id'] as String),
                ),
        ),
    ],
  );

  String _dateTime(DateTime value) =>
      DateFormat('yyyy年M月d日 HH:mm').format(value.toLocal());

  String _summary(Map<String, dynamic>? value) {
    if (value == null || value['deleted_at_utc'] != null) return '已删除';
    final event = value['event'] is Map<String, dynamic>
        ? value['event'] as Map<String, dynamic>
        : value;
    final title = event['title'] as String?;
    final notes = event['notes'] as String?;
    final color = EventColorPresentation.fromKey(event['color_key'] as String?);
    final start = DateTime.tryParse(event['start_utc']?.toString() ?? '');
    final end = DateTime.tryParse(event['end_utc']?.toString() ?? '');
    return '${title == null || title.isEmpty ? '预留时间' : title}\n'
        '${start == null ? '' : _dateTime(start)} 至 ${end == null ? '' : _dateTime(end)}'
        '\n颜色：${color.label}'
        '${notes == null || notes.isEmpty ? '' : '\n$notes'}';
  }
}

class _DeviceNameDialog extends StatefulWidget {
  const _DeviceNameDialog({required this.name});
  final String name;

  @override
  State<_DeviceNameDialog> createState() => _DeviceNameDialogState();
}

class _DeviceNameDialogState extends State<_DeviceNameDialog> {
  late final controller = TextEditingController(text: widget.name);

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GlassAlertDialog(
    title: const Text('设备名称'),
    content: TextField(
      controller: controller,
      maxLength: 80,
      autofocus: true,
      decoration: const InputDecoration(labelText: '便于辨认的名称'),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (controller.text.trim().isNotEmpty) {
            Navigator.pop(context, controller.text.trim());
          }
        },
        child: const Text('保存'),
      ),
    ],
  );
}
