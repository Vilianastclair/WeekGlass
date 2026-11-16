import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

import 'cloud_auth_service.dart';

const cloudSubscriptionLinksAllowed = bool.fromEnvironment(
  'WG_DIRECT_BILLING',
  defaultValue: true,
);

Future<bool> openCloudPortal(
  BuildContext context,
  CloudAuthService auth,
  CloudPortalPage page,
) => openBrowserLink(context, page.uri, open: (_) => auth.openPortal(page));

Future<bool> openBrowserLink(
  BuildContext context,
  Uri uri, {
  Future<bool> Function(Uri)? open,
}) async {
  try {
    final opened = await (open == null
        ? launchUrl(uri, mode: LaunchMode.externalApplication)
        : open(uri));
    if (opened) return true;
  } catch (_) {
    // The system URL handler may not be available.
  }
  if (!context.mounted) return false;
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
  return false;
}
