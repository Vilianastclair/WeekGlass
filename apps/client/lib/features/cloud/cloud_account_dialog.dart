import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

import '../calendar_io/calendar_file_store.dart';
import 'cloud_auth_service.dart';
import 'cloud_connection.dart';
import 'cloud_portal_link.dart';

Future<void> openCloudAccount(
  BuildContext context,
  CloudConnection cloud,
) async {
  if (cloud.auth.official) {
    await openCloudPortal(context, cloud.auth, CloudPortalPage.account);
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (_) => _AccountDialog(cloud: cloud),
  );
}

class _AccountDialog extends StatefulWidget {
  const _AccountDialog({required this.cloud});
  final CloudConnection cloud;
  @override
  State<_AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<_AccountDialog> {
  CloudConnection get cloud => widget.cloud;
  String? message;
  String? problem;

  Future<void> export() async {
    setState(() {
      message = null;
      problem = null;
    });
    try {
      final data = await cloud.exportCalendar();
      final path = await saveCalendarFile(
        bytes: Uint8List.fromList(utf8.encode(jsonEncode(data))),
        suggestedName:
            'WeekGlass-cloud-${DateTime.now().toIso8601String().substring(0, 10)}.json',
        extension: 'json',
        mimeType: 'application/json',
      );
      if (mounted && path != null) setState(() => message = '云端日历已导出。');
    } catch (error) {
      if (mounted) setState(() => problem = cloudErrorMessage(error));
    }
  }

  Future<void> manage(_AccountAction action) async {
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CredentialDialog(cloud: cloud, action: action),
    );
    if (!mounted || result == null) return;
    if (!cloud.connected) {
      Navigator.pop(context);
      return;
    }
    if (action == _AccountAction.recovery) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => GlassAlertDialog(
          title: const Text('保存新的恢复码'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '忘记密码时可用它恢复账号。此恢复码仅显示一次，旧恢复码已失效。请保存到密码管理器或其他安全位置。',
                  ),
                  const SizedBox(height: 20),
                  SelectableText(
                    result,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('我已保存'),
            ),
          ],
        ),
      );
    } else {
      setState(() {
        message = '其他设备已退出登录。';
        problem = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: cloud,
    builder: (context, _) {
      final profile = cloud.account;
      final used =
          ((profile?['usage']?['storage_bytes'] as num? ?? 0) / (1024 * 1024))
              .toStringAsFixed(1);
      return GlassAlertDialog(
        title: const Text('云账号与数据'),
        content: SizedBox(
          width: 430,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  profile?['username'] as String? ?? cloud.displayName,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  cloud.auth.origin ?? '',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (profile != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    '${profile['usage']?['event_count'] ?? 0} 条云端日程，已用 $used MiB',
                  ),
                  const SizedBox(height: 6),
                  Text(
                    profile['recovery_configured'] == true
                        ? '已设置账号恢复码'
                        : '尚未设置恢复码，建议先生成并保存。',
                  ),
                ],
                const SizedBox(height: 18),
                OutlinedButton.icon(
                  onPressed: cloud.busy ? null : export,
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('导出云端日历'),
                ),
                const SizedBox(height: 6),
                const Text(
                  '导出包含云端日程与同步版本信息，不含密码或令牌。',
                  style: TextStyle(fontSize: 12),
                ),
                if (profile != null) ...[
                  const Divider(height: 28),
                  OutlinedButton(
                    onPressed: cloud.busy
                        ? null
                        : () => manage(_AccountAction.password),
                    child: const Text('修改密码'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: cloud.busy
                        ? null
                        : () => manage(_AccountAction.recovery),
                    child: Text(
                      profile['recovery_configured'] == true
                          ? '重新生成恢复码'
                          : '生成账号恢复码',
                    ),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: cloud.busy
                        ? null
                        : () => manage(_AccountAction.sessions),
                    child: const Text('退出其他设备'),
                  ),
                  const Divider(height: 28),
                  TextButton(
                    onPressed: cloud.busy
                        ? null
                        : () => manage(_AccountAction.delete),
                    child: const Text('删除云账号'),
                  ),
                ],
                if (message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(message!),
                  ),
                if (problem != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      problem!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (cloud.busy)
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
            onPressed: cloud.working ? null : () => Navigator.pop(context),
            child: const Text('完成'),
          ),
        ],
      );
    },
  );
}

enum _AccountAction { password, recovery, sessions, delete }

class _CredentialDialog extends StatefulWidget {
  const _CredentialDialog({required this.cloud, required this.action});
  final CloudConnection cloud;
  final _AccountAction action;
  @override
  State<_CredentialDialog> createState() => _CredentialDialogState();
}

class _CredentialDialogState extends State<_CredentialDialog> {
  final current = TextEditingController();
  final next = TextEditingController();
  final confirmation = TextEditingController();
  bool busy = false;
  String? error;
  _AccountAction get action => widget.action;

  String? _validateNewPassword() {
    final password = next.text;
    if (password.length < 16) {
      return '新密码需至少 16 字符。';
    }
    return password == confirmation.text ? null : '两次输入的新密码不一致。';
  }

  String get title => switch (action) {
    _AccountAction.password => '修改密码',
    _AccountAction.recovery => '生成新的恢复码',
    _AccountAction.sessions => '退出其他设备',
    _AccountAction.delete => '删除云账号',
  };

  Future<void> submit() async {
    if (current.text.isEmpty) {
      setState(() => error = '请输入当前密码。');
      return;
    }
    if (action == _AccountAction.password) {
      final problem = _validateNewPassword();
      if (problem != null) {
        setState(() => error = problem);
        return;
      }
    }
    if (action == _AccountAction.delete &&
        confirmation.text.trim() != widget.cloud.account?['username']) {
      setState(() => error = '请输入当前账号名以确认。');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      var result = 'done';
      switch (action) {
        case _AccountAction.password:
          await widget.cloud.changePassword(current.text, next.text);
        case _AccountAction.recovery:
          result = await widget.cloud.rotateRecoveryKey(current.text);
        case _AccountAction.sessions:
          await widget.cloud.revokeOtherDevices(current.text);
        case _AccountAction.delete:
          await widget.cloud.deleteAccount(
            current.text,
            confirmation.text.trim(),
          );
      }
      if (mounted) Navigator.pop(context, result);
    } catch (problem) {
      if (mounted) {
        setState(() {
          error = cloudErrorMessage(problem);
          busy = false;
        });
      }
    }
  }

  @override
  void dispose() {
    current.dispose();
    next.dispose();
    confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: GlassAlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(switch (action) {
                _AccountAction.password =>
                  '修改后所有设备会退出登录，请用新密码重新连接。本机日程与待同步修改会保留。',
                _AccountAction.recovery => '新的恢复码会立即替换旧恢复码，请在下一步妥善保存。',
                _AccountAction.sessions => '其他设备需重新登录才能继续同步；此设备保持连接。',
                _AccountAction.delete => '将永久删除此服务器上的账号、日程和会话，无法撤销。本机日程保留。',
              }),
              const SizedBox(height: 16),
              TextField(
                controller: current,
                obscureText: true,
                enabled: !busy,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: '当前密码'),
              ),
              if (action == _AccountAction.password) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: next,
                  obscureText: true,
                  enabled: !busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: '新密码（至少 16 字符）'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: confirmation,
                  obscureText: true,
                  enabled: !busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: '再次输入新密码'),
                ),
              ],
              if (action == _AccountAction.delete) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: confirmation,
                  enabled: !busy,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: '输入账号名：${widget.cloud.account?['username']}',
                  ),
                ),
              ],
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (busy)
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
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: busy ? null : submit,
          child: Text(action == _AccountAction.delete ? '永久删除云账号' : '确认'),
        ),
      ],
    ),
  );
}
