import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:weekglass_domain/weekglass_domain.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';
import 'package:window_manager/window_manager.dart';

import 'cloud_auth_service.dart';
import 'cloud_account_dialog.dart';
import 'cloud_billing_client.dart';
import 'cloud_connection.dart';
import 'cloud_subscription_dialog.dart';

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
  CloudConnection get cloud => widget.cloud;

  Future<void> login() async {
    if (_ownsLogin) return;
    _ownsLogin = true;
    setState(() => localError = null);
    try {
      await cloud.login(hosted ? officialCloudOrigin : address.text);
      if (!mounted ||
          !_ownsLogin ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      _ownsLogin = false;
      unawaited(_returnToWindow());
      await confirmMerge();
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
    if (!Platform.isWindows || !mounted) return;
    try {
      await windowManager.show();
      if (mounted) await windowManager.focus();
    } catch (_) {
      // Focus is best effort. The confirmed connection remains visible.
    }
  }

  Future<void> confirmMerge() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('已连接云账号'),
        content: Text(
          '现在要将本机所有日程（包括曾从其他账号下载的日程）与「${cloud.displayName}」中的日程合并，并同步以后的修改吗？\n\n服务器：${cloud.auth.origin}\n账号：${cloud.auth.accountId.substring(0, 8)}\n\n相同日程发生冲突时由你选择，本机日程会保留。',
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
    if (confirmed == true) {
      try {
        await cloud.approveAndConnect();
      } catch (error) {
        if (mounted) setState(() => localError = cloudErrorMessage(error));
      }
    }
  }

  Future<void> disconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('断开云同步？'),
        content: const Text('本机日程与未上传的修改会保留；重新连接同一账号后可继续同步。'),
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
    if (confirmed == true) await cloud.disconnect();
  }

  Future<void> resolve(String id, bool useLocal) async {
    setState(() => localError = null);
    try {
      await cloud.engine.resolveConflict(id, useLocal: useLocal);
    } catch (error) {
      if (mounted) setState(() => localError = cloudErrorMessage(error));
    }
  }

  Future<void> renameDevice(Map<String, dynamic> device) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _DeviceNameDialog(
        name: device['display_name'] as String? ?? 'WeekGlass',
      ),
    );
    if (name == null) return;
    try {
      await cloud.renameDevice(device, name);
    } catch (error) {
      if (mounted) setState(() => localError = cloudErrorMessage(error));
    }
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
    builder: (context, _) {
      final theme = Theme.of(context);
      final pending = cloud.engine.pendingCount;
      final time = cloud.engine.lastSync;
      final paused =
          cloud.engine.uploadPaused ||
          cloud.entitlements?['sync_write'] == false;
      final end = DateTime.tryParse(
        cloud.entitlements?['current_period_end']?.toString() ?? '',
      );
      return PopScope<void>(
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) _cancelOwnedLogin();
        },
        child: GlassAlertDialog(
          title: const Row(
            children: [
              Icon(Icons.cloud_outlined, size: 23),
              SizedBox(width: 12),
              Text('云同步'),
            ],
          ),
          content: SizedBox(
            width: 430,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!cloud.connected) ...[
                    const Text('同一份安排，随处接续。'),
                    const SizedBox(height: 18),
                    SegmentedButton<bool>(
                      direction:
                          MediaQuery.sizeOf(context).width < 560 ||
                              MediaQuery.textScalerOf(context).scale(14) > 20
                          ? Axis.vertical
                          : Axis.horizontal,
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
                          : (v) => setState(() => hosted = v.single),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      hosted ? '官方云同步写入需要有效权益。' : '自托管同步免费，由你的服务器保存日程。',
                      style: theme.textTheme.bodySmall,
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
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: cloud.busy ? null : login,
                      icon: const Icon(Icons.open_in_new_rounded, size: 18),
                      label: const Text('在浏览器中登录'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '登录页可注册独立账号，或使用恢复码找回密码。',
                      style: theme.textTheme.bodySmall,
                    ),
                    if (cloud.loginPhase case final phase?) ...[
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child: Text(switch (phase) {
                          CloudLoginPhase.checkingServer => '正在检查云服务器…',
                          CloudLoginPhase.waitingForBrowser =>
                            '等待浏览器授权。请在浏览器中完成登录。',
                          CloudLoginPhase.exchanging => '已收到浏览器回传，正在验证授权…',
                          CloudLoginPhase.saving => '授权已验证，正在安全保存连接…',
                        }),
                      ),
                      TextButton(
                        onPressed: _cancelOwnedLogin,
                        child: const Text('取消登录'),
                      ),
                    ],
                  ] else ...[
                    Text(cloud.displayName, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(cloud.auth.origin!, style: theme.textTheme.bodySmall),
                    if (cloud.account?['username'] case final String username)
                      Text('账号：$username', style: theme.textTheme.bodySmall),
                    const SizedBox(height: 14),
                    Text(
                      paused
                          ? '已暂停上传，仍可读取及导出云端日程'
                          : cloud.entitlements == null
                          ? (cloud.accountLoading ? '正在读取账号权限…' : '暂时无法读取账号权限')
                          : '已获得同步权限',
                      style: theme.textTheme.bodyMedium,
                    ),
                    if (paused)
                      Text(
                        '本机编辑照常可用，待同步修改会保留。',
                        style: theme.textTheme.bodySmall,
                      ),
                    if (cloud.entitlementsStale && cloud.entitlements != null)
                      Text('权限为上次确认的状态。', style: theme.textTheme.bodySmall),
                    if (end != null)
                      Text(
                        '同步权益截止：${cloudBillingTime(end)}',
                        style: theme.textTheme.bodySmall,
                      ),
                    const SizedBox(height: 8),
                    if (cloud.auth.mergeApproved) ...[
                      Text(
                        cloud.engine.busy
                            ? (paused ? '正在读取云端更新…' : '正在同步…')
                            : pending > 0
                            ? '$pending 条修改等待同步'
                            : paused
                            ? '没有待上传的修改'
                            : time == null
                            ? '等待首次同步'
                            : '本机修改已同步',
                      ),
                      if (time != null)
                        Text(
                          '上次同步 ${time.toLocal().toString().substring(0, 16)}',
                          style: theme.textTheme.bodySmall,
                        ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: cloud.busy
                            ? null
                            : () {
                                setState(() => localError = null);
                                cloud.sync();
                              },
                        icon: const Icon(Icons.sync_rounded, size: 18),
                        label: const Text('立即同步'),
                      ),
                    ] else ...[
                      Semantics(
                        liveRegion: true,
                        child: const Text('已连接云账号。确认合并后才会上传本机日程。'),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: cloud.busy ? null : confirmMerge,
                        child: const Text('合并日程'),
                      ),
                    ],
                    if (cloud.auth.official) ...[
                      const Divider(height: 28),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          OutlinedButton.icon(
                            onPressed: cloud.working
                                ? null
                                : () => openCloudSubscription(context, cloud),
                            icon: const Icon(
                              Icons.credit_card_outlined,
                              size: 18,
                            ),
                            label: const Text('管理订阅'),
                          ),
                          TextButton(
                            onPressed: cloud.working
                                ? null
                                : () => openCloudSubscription(
                                    context,
                                    cloud,
                                    orders: true,
                                  ),
                            child: const Text('查看订单'),
                          ),
                        ],
                      ),
                    ],
                    if (cloud.engine.conflicts.isNotEmpty) ...[
                      const Divider(height: 28),
                      Text(
                        '${cloud.engine.conflicts.length} 个日程需要确认',
                        style: theme.textTheme.titleSmall,
                      ),
                      for (final conflict in cloud.engine.conflicts) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest
                                .withValues(alpha: .5),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('本机：${_summary(conflict.local)}'),
                              const SizedBox(height: 8),
                              Text('云端：${_summary(conflict.remote)}'),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                children: [
                                  TextButton(
                                    onPressed: cloud.busy
                                        ? null
                                        : () => resolve(conflict.id, true),
                                    child: const Text('保留本机'),
                                  ),
                                  TextButton(
                                    onPressed: cloud.busy
                                        ? null
                                        : () => resolve(conflict.id, false),
                                    child: const Text('采用云端'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                    const Divider(height: 28),
                    OutlinedButton.icon(
                      onPressed: cloud.busy
                          ? null
                          : () => openCloudAccount(context, cloud),
                      icon: const Icon(
                        Icons.manage_accounts_outlined,
                        size: 19,
                      ),
                      label: const Text('账号安全与云端导出'),
                    ),
                    const SizedBox(height: 20),
                    Text('已连接设备', style: theme.textTheme.titleSmall),
                    Text('点击设备名称可修改。', style: theme.textTheme.bodySmall),
                    for (final device in cloud.devices.where(
                      (d) => d['revoked_at'] == null,
                    ))
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        onTap: cloud.busy ? null : () => renameDevice(device),
                        leading: const Icon(Icons.devices_rounded, size: 20),
                        title: Text('${device['display_name'] ?? 'WeekGlass'}'),
                        subtitle: device['device_id'] == cloud.auth.deviceId
                            ? const Text('本机')
                            : null,
                        trailing: device['device_id'] == cloud.auth.deviceId
                            ? null
                            : IconButton(
                                tooltip: '撤销此设备',
                                icon: const Icon(
                                  Icons.link_off_rounded,
                                  size: 19,
                                ),
                                onPressed: cloud.busy
                                    ? null
                                    : () async {
                                        final ok = await showDialog<bool>(
                                          context: context,
                                          builder: (context) => AlertDialog(
                                            title: const Text('撤销此设备？'),
                                            content: const Text(
                                              '此设备需重新登录才能同步，已有日程不会删除。',
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () => Navigator.pop(
                                                  context,
                                                  false,
                                                ),
                                                child: const Text('取消'),
                                              ),
                                              FilledButton(
                                                onPressed: () => Navigator.pop(
                                                  context,
                                                  true,
                                                ),
                                                child: const Text('撤销'),
                                              ),
                                            ],
                                          ),
                                        );
                                        if (ok == true) {
                                          try {
                                            await cloud.revokeDevice(
                                              device['device_id'] as String,
                                            );
                                          } catch (e) {
                                            if (mounted) {
                                              setState(
                                                () => localError =
                                                    cloudErrorMessage(e),
                                              );
                                            }
                                          }
                                        }
                                      },
                              ),
                      ),
                    TextButton.icon(
                      onPressed: cloud.busy ? null : disconnect,
                      icon: const Icon(Icons.link_off_rounded, size: 18),
                      label: const Text('断开连接'),
                    ),
                  ],
                  if (cloud.busy)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                  if (localError ??
                          cloud.problem ??
                          cloud.accountProblem ??
                          cloud.engine.error
                      case final error?)
                    Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: Text(
                        error,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Text(
                    '学校登录凭据、设备外观与通知设置不会上传。',
                    style: theme.textTheme.bodySmall,
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
      );
    },
  );

  String _summary(Map<String, dynamic>? value) {
    if (value == null || value['deleted_at_utc'] != null) return '已删除';
    final event = value['event'] is Map<String, dynamic>
        ? value['event'] as Map<String, dynamic>
        : value;
    final title = event['title'] as String?;
    final notes = event['notes'] as String?;
    final color = EventColorPresentation.fromKey(event['color_key'] as String?);
    final start = DateTime.tryParse(event['start_utc']?.toString() ?? '')
        ?.toLocal();
    final end = DateTime.tryParse(event['end_utc']?.toString() ?? '')
        ?.toLocal();
    return '${title == null || title.isEmpty ? '预留时间' : title}\n'
        '${start?.toString().substring(0, 16) ?? ''} – ${end?.toString().substring(11, 16) ?? ''}'
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
