import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'cloud_connection.dart';

/// The paid account's next step, shared by cloud settings and billing.
class CloudEmailVerification extends StatefulWidget {
  const CloudEmailVerification({
    super.key,
    required this.cloud,
    this.readProblem,
  });

  final CloudConnection cloud;
  final String? readProblem;

  @override
  State<CloudEmailVerification> createState() => _CloudEmailVerificationState();
}

class _CloudEmailVerificationState extends State<CloudEmailVerification> {
  bool _opening = false;
  bool _opened = false;
  bool _refreshing = false;
  String? _feedback;
  String? _problem;

  Future<void> _openBrowser() async {
    setState(() {
      _opening = true;
      _feedback = _problem = null;
    });
    var opened = false;
    try {
      opened = await widget.cloud.openEmailVerification();
    } catch (_) {
      // The launcher can throw on platforms without a usable browser.
    }
    if (!mounted) return;
    setState(() {
      _opening = false;
      if (opened) {
        _opened = true;
      } else {
        _problem = '未能打开浏览器。请重试。';
      }
    });
  }

  Future<void> _refresh() async {
    setState(() {
      _refreshing = true;
      _feedback = _problem = null;
    });
    try {
      await widget.cloud.refreshAccountProfile();
      if (mounted && widget.cloud.emailVerificationRequired) {
        setState(() => _feedback = '邮箱尚未验证。');
      }
    } catch (_) {
      if (mounted) setState(() => _problem = '暂时无法刷新验证状态。请重试。');
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _copyAccount(String username) async {
    try {
      await Clipboard.setData(ClipboardData(text: username));
      if (mounted) setState(() => _feedback = '已复制云账号。');
    } catch (_) {
      if (mounted) setState(() => _problem = '复制失败，可在云同步中查看账号。');
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.cloud,
    builder: (context, _) {
      final cloud = widget.cloud;
      if (cloud.emailVerified) {
        return Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Semantics(liveRegion: true, child: const Text('邮箱已验证')),
        );
      }
      if (!cloud.emailVerificationRequired) {
        if (widget.readProblem case final problem?) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Semantics(liveRegion: true, child: Text(problem)),
          );
        }
        return const SizedBox.shrink();
      }
      final theme = Theme.of(context);
      final available = cloud.emailVerificationAvailable;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: .10),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  liveRegion: true,
                  child: Text('订阅邮箱待验证', style: theme.textTheme.titleMedium),
                ),
                const SizedBox(height: 4),
                Text(
                  !available
                      ? '邮箱验证暂不可用。请稍后刷新状态。'
                      : _opened
                      ? '请在浏览器中完成验证，再返回 WeekGlass。'
                      : '在浏览器登录同一云账号后，可验证原邮箱或更换邮箱。',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    if (available)
                      FilledButton.icon(
                        onPressed: _opening || _refreshing
                            ? null
                            : _openBrowser,
                        icon: const Icon(Icons.open_in_new_rounded, size: 18),
                        label: Text(_opening ? '正在打开…' : '验证邮箱'),
                      ),
                    if (cloud.account?['username'] case final String username
                        when available)
                      TextButton(
                        onPressed: () => _copyAccount(username),
                        child: const Text('复制云账号'),
                      ),
                    if (_opened || !available)
                      TextButton(
                        onPressed: _opening || _refreshing ? null : _refresh,
                        child: Text(_refreshing ? '正在刷新…' : '刷新状态'),
                      ),
                  ],
                ),
                if (_problem ?? _feedback case final feedback?)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        feedback,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: _problem == null
                              ? theme.colorScheme.onSurface
                              : theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
