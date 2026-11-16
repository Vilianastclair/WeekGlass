import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weekglass/features/cloud/cloud_auth_callback_page.dart';

class MissingBrandBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async =>
      throw StateError('asset unavailable');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('callback copy is escaped in the document title and page content', () {
    const title = '<img src=x onerror="alert(1)"> & "title"';
    const message = '</p><script>callbackSecret()</script><p data-x=\'value\'>';
    final html = buildCloudAuthCallbackPage(
      success: false,
      title: title,
      message: message,
    );
    expect(
      html,
      contains('<title>${const HtmlEscape().convert(title)} WeekGlass</title>'),
    );
    expect(
      html,
      contains(
        '<h1 id="status-title">${const HtmlEscape().convert(title)}</h1>',
      ),
    );
    expect(
      html,
      contains('<p class="message">${const HtmlEscape().convert(message)}</p>'),
    );
    expect(html, isNot(contains('<script')));
    expect(html, isNot(contains('<img src=x')));
  });

  test(
    'strict CSP permits the exact stylesheet without scripts or remote assets',
    () {
      final pages = CloudAuthCallbackPages();
      for (final html in [pages.success, pages.invalid]) {
        final style = RegExp(r'<style>([\s\S]*?)</style>')
            .firstMatch(html)!
            .group(1)!;
        final styleHash = base64Encode(
          sha256.convert(utf8.encode(style)).bytes,
        );
        expect(cloudAuthCallbackCsp, contains("default-src 'none'"));
        expect(cloudAuthCallbackCsp, contains("style-src 'sha256-$styleHash'"));
        expect(cloudAuthCallbackCsp, contains('img-src data:'));
        expect(cloudAuthCallbackCsp, contains("base-uri 'none'"));
        expect(cloudAuthCallbackCsp, contains("form-action 'none'"));
        expect(cloudAuthCallbackCsp, contains("frame-ancestors 'none'"));
        expect(cloudAuthCallbackCsp, isNot(contains('unsafe-inline')));
        expect(cloudAuthCallbackCsp, isNot(contains('unsafe-eval')));
        expect(html, isNot(matches(r'<(?:script|form|iframe|a)\b')));
        expect(html, isNot(matches(r'(?:src|href)\s*=\s*["\x27]https?:')));
        expect(html, isNot(contains('http-equiv="refresh"')));
        expect(html, isNot(contains('window.close')));
      }
    },
  );

  test('missing decorative assets preserve both callback receipts', () async {
    final pages = await loadCloudAuthCallbackPages(
      bundle: MissingBrandBundle(),
    );
    expect(pages.success, contains('连接已完成'));
    expect(pages.success, contains('返回 WeekGlass 继续'));
    expect(pages.invalid, contains('连接未完成'));
    expect(pages.invalid, contains('重新发起连接'));
    expect(pages.success, contains('class="brand-fallback"'));
  });

  test('bundled mark is embedded locally in both responsive callback pages', () async {
    final pages = await loadCloudAuthCallbackPages();
    for (final html in [pages.success, pages.invalid]) {
      final source = RegExp(r'src="data:image/png;base64,([A-Za-z0-9+/=]+)"')
          .firstMatch(html)!
          .group(1)!;
      expect(base64Decode(source).take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
      expect(html, contains('name="viewport"'));
      expect(html, contains('prefers-color-scheme:dark'));
      expect(html, contains('forced-colors:active'));
    }

    // Optional synthetic fixtures for the local browser preview, from the exact
    // same renderer and bundled mark used in a real callback response.
    final previewPath = Platform.environment['WG_AUTH_CALLBACK_PREVIEW_DIR'];
    if (previewPath != null && previewPath.isNotEmpty) {
      final directory = await Directory(previewPath).create(recursive: true);
      await File('${directory.path}/callback-success.html')
          .writeAsString(pages.success);
      await File('${directory.path}/callback-invalid.html')
          .writeAsString(pages.invalid);
    }
  });
}
