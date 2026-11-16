import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

const cloudAuthCallbackMarkAsset = 'assets/brand/mark.png';

// These are the Moonstone account-surface tokens, not a second form theme.
const _callbackStyle = '''
:root{color-scheme:light dark;--canvas:#e9eff7;--ink:#222b48;--muted:#53617f;--accent:#5366aa;--edge:#ffffffda;--panel-top:#f8fbff8c;--panel-bottom:#eaf1ff45;--shade:#374a6e24;--reflection:#ffffff45;--status:#ffffff35;--error:#9d405c;--radius:12px}
*{box-sizing:border-box}
html{min-height:100%;background:var(--canvas)}
body{margin:0;min-height:100vh;min-height:100svh;display:grid;place-items:center;padding:28px 20px;color:var(--ink);background:radial-gradient(ellipse at 8% 6%,#b3d3f16b,transparent 53%),radial-gradient(ellipse at 95% 94%,#a5a6d54d,transparent 58%);font:15px/1.7 'Noto Sans SC','PingFang SC','Microsoft YaHei',system-ui,sans-serif;-webkit-font-smoothing:antialiased}
.panel{width:min(440px,100%);min-width:0;padding:30px 32px 32px;border:1px solid var(--edge);border-radius:var(--radius);background:linear-gradient(180deg,var(--panel-top),var(--panel-bottom));box-shadow:0 7px 20px var(--shade),0 28px 70px -30px var(--shade),inset 0 1px 0 var(--reflection);backdrop-filter:blur(20px) saturate(1.18);-webkit-backdrop-filter:blur(20px) saturate(1.18)}
.brand{display:flex;align-items:center;gap:10px;margin-bottom:30px}
.brand img,.brand-fallback{display:block;width:32px;height:32px;flex:none;object-fit:contain}
.brand-fallback{border:1px solid var(--edge);border-radius:var(--radius);background:var(--status);color:var(--accent);text-align:center;font-size:20px;line-height:30px;font-weight:600}
.brand-name{display:block;font-size:17px;line-height:1.35;font-weight:600;letter-spacing:-.35px}
.brand-label{display:block;color:var(--muted);font-size:11px;line-height:1.5;letter-spacing:1.8px;margin-top:2px}
.panel.invalid h1{color:var(--error)}
h1{margin:0 0 8px;font-size:25px;line-height:1.45;font-weight:550;letter-spacing:.1px;overflow-wrap:anywhere}
.message{margin:0;color:var(--muted);font-size:16px;overflow-wrap:anywhere}
@media(prefers-color-scheme:dark){:root{--canvas:#0a0f20;--ink:#eef3ff;--muted:#b3c1de;--accent:#b8caff;--edge:#d5e5ff59;--panel-top:#c8dbff24;--panel-bottom:#7e9dd80c;--shade:#02061559;--reflection:#ffffff18;--status:#bdd5ff0d;--error:#ffbfcc}body{background:radial-gradient(ellipse at 6% 3%,#32648e31,transparent 50%),radial-gradient(ellipse at 93% 94%,#7762b72e,transparent 58%)}}
@media(max-width:480px){body{padding:24px 16px}.panel{padding:26px 24px 28px}h1{font-size:23px}}
@media(forced-colors:active){html,body,.panel,.status,.brand-fallback{background:Canvas;color:CanvasText}.panel,.status,.brand-fallback{border:1px solid CanvasText;box-shadow:none;backdrop-filter:none;-webkit-backdrop-filter:none}.message,.brand-label{color:CanvasText}}
''';

// Permit only this exact local stylesheet and the bundled PNG. No scripts,
// remote assets, navigation, or form submission are needed by this receipt.
final cloudAuthCallbackCsp =
    "default-src 'none'; "
    "style-src 'sha256-${base64Encode(sha256.convert(utf8.encode(_callbackStyle)).bytes)}'; "
    "img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

String buildCloudAuthCallbackPage({
  required bool success,
  required String title,
  required String message,
  List<int>? brandMarkPng,
}) {
  const escape = HtmlEscape();
  final safeTitle = escape.convert(title);
  final safeMessage = escape.convert(message);
  final mark = brandMarkPng == null || brandMarkPng.isEmpty
      ? '<span class="brand-fallback" aria-hidden="true">W</span>'
      : '<img src="data:image/png;base64,${base64Encode(brandMarkPng)}" '
            'alt="" width="32" height="32">';
  return '''<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark">
<meta name="referrer" content="no-referrer">
<title>$safeTitle WeekGlass</title>
<style>$_callbackStyle</style>
</head>
<body>
<main class="panel ${success ? 'complete' : 'invalid'}" aria-labelledby="status-title">
<header class="brand">$mark<div><span class="brand-name">WeekGlass</span><span class="brand-label">云同步</span></div></header>
<h1 id="status-title">$safeTitle</h1>
<p class="message">$safeMessage</p>
</main>
</body>
</html>''';
}

class CloudAuthCallbackPages {
  CloudAuthCallbackPages({List<int>? brandMarkPng})
    : success = buildCloudAuthCallbackPage(
        success: true,
        title: '连接已完成',
        message: '返回 WeekGlass 继续',
        brandMarkPng: brandMarkPng,
      ),
      invalid = buildCloudAuthCallbackPage(
        success: false,
        title: '连接未完成',
        message: '请返回 WeekGlass，重新发起连接。',
        brandMarkPng: brandMarkPng,
      ),
      failed = buildCloudAuthCallbackPage(
        success: false,
        title: '连接未完成',
        message: '请返回 WeekGlass 查看原因，再重新发起连接。',
        brandMarkPng: brandMarkPng,
      );

  final String success;
  final String invalid;
  final String failed;
}

Future<CloudAuthCallbackPages> loadCloudAuthCallbackPages({
  AssetBundle? bundle,
}) async {
  try {
    final data = await (bundle ?? rootBundle).load(cloudAuthCallbackMarkAsset);
    return CloudAuthCallbackPages(
      brandMarkPng: data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      ),
    );
  } catch (_) {
    // A missing decorative asset must never prevent the OAuth callback.
    return CloudAuthCallbackPages();
  }
}
