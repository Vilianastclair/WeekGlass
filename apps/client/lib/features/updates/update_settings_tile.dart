import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'startup_update_prompt.dart';
import 'update_service.dart';

class UpdateSettingsTile extends StatelessWidget {
  const UpdateSettingsTile({
    super.key,
    required this.service,
    this.showTitle = true,
    this.allowRestart = true,
  });
  final UpdateService service;
  final bool showTitle;
  final bool allowRestart;
  @override
  Widget build(BuildContext context) {
    final tile = _content(context);
    return service.isAndroid
        ? tile
        : StartupUpdatePrompt.inSettings(
            service: service,
            allowRestart: allowRestart,
            child: tile,
          );
  }

  Widget _content(BuildContext context) => AnimatedBuilder(
    animation: service,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showTitle) ...[
          const Text('软件更新', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
        ],
        Text(
          service.supportsUpdates
              ? service.message
              : '当前版本 ${UpdateService.currentVersion}',
        ),
        if (service.busy)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(value: service.progress),
          ),
        if (service.startupOffer case final offer?) ...[
          const SizedBox(height: 8),
          Text(
            service.isAndroid ? '返回日程后，在系统确认安装。' : '下载完成后会询问是否重启安装。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton(
                onPressed: service.busy
                    ? null
                    : () => service.skipStartupVersion(offer),
                child: const Text('跳过此版本'),
              ),
              FilledButton(
                onPressed: service.busy
                    ? null
                    : () => service.acceptStartupUpdate(offer),
                child: const Text('立即更新'),
              ),
            ],
          ),
          if (!service.isAndroid) const SizedBox(height: 8),
        ] else if (service.supportsUpdates)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed:
                  service.busy ||
                      (!service.isAndroid && service.ready && !allowRestart)
                  ? null
                  : service.ready
                  ? () async {
                      if (service.isAndroid) {
                        await service.install();
                        return;
                      }
                      await showWindowsRestartPrompt(context, service);
                    }
                  : service.canRetryAcceptedUpdate
                  ? service.retryAcceptedUpdate
                  : service.available != null
                  ? service.download
                  : service.check,
              icon: Icon(
                service.ready
                    ? service.isAndroid
                          ? Icons.install_mobile_rounded
                          : Icons.restart_alt_rounded
                    : Icons.system_update_alt_rounded,
                size: 18,
              ),
              label: Text(
                service.ready
                    ? service.isAndroid
                          ? service.needsInstallPermission
                                ? '允许安装更新'
                                : '打开安装器'
                          : '重启更新'
                    : service.canRetryAcceptedUpdate
                    ? '重试更新'
                    : service.available != null
                    ? '下载更新'
                    : '检查更新',
              ),
            ),
          ),
        if (service.androidBackgroundDownloadUnavailable)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () async {
                try {
                  if (await launchUrl(
                    Uri.parse(
                      'https://cloud.viliana.cn/download/WeekGlass-Android-arm64.apk',
                    ),
                    mode: LaunchMode.externalApplication,
                  )) {
                    return;
                  }
                } on PlatformException {
                  // The device could not open a browser.
                }
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('无法打开系统浏览器')));
                }
              },
              child: const Text('用浏览器下载 APK'),
            ),
          ),
      ],
    ),
  );
}
