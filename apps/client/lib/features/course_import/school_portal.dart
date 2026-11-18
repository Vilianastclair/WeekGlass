import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart' as mobile;
import 'package:webview_windows/webview_windows.dart' as win;
import 'package:weekglass_design_system/weekglass_design_system.dart';

import 'school_portal_catalog.dart';
import 'school_portal_timetable.dart';
import 'whu_portal.dart';
import 'whu_timetable.dart';

/// Selecting the verified WHU route leaves its original flow intact.
Future<SchoolPortalSite?> chooseSchoolPortal(BuildContext context) =>
    showDialog<SchoolPortalSite>(
      context: context,
      builder: (_) => const _SchoolPicker(),
    );

class _SchoolPicker extends StatefulWidget {
  const _SchoolPicker();
  @override
  State<_SchoolPicker> createState() => _SchoolPickerState();
}

class _SchoolPickerState extends State<_SchoolPicker> {
  final search = TextEditingController();
  bool custom = false;
  String? error;
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  void choose(String raw, [String? name]) {
    try {
      Navigator.pop(context, SchoolPortalSite.fromEntry(raw, name: name));
    } on FormatException catch (e) {
      setState(() => error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = search.text.trim().toLowerCase();
    final matches =
        [(name: '武汉大学', entry: NativeWhuPortal.entry), ...schoolPortalCatalog]
            .where(
              (e) => e.name.contains(q) || Uri.parse(e.entry).host.contains(q),
            )
            .toList();
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: Theme.of(context).colorScheme.surface
          .withValues(alpha: 1),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 520,
          maxHeight: custom ? 360 : size.height * .8,
        ),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      custom ? '填写学校教务网址' : '选择学校',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭选校',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('school-portal-search'),
                controller: search,
                autocorrect: false,
                keyboardType: custom ? TextInputType.url : TextInputType.text,
                decoration: InputDecoration(
                  prefixIcon: Icon(custom ? Icons.link : Icons.search),
                  labelText: custom ? '学校教务 HTTPS 网址' : '搜索学校名称或教务域名',
                  errorText: error,
                  errorMaxLines: 3,
                ),
                onChanged: (_) => setState(() => error = null),
                onSubmitted: custom ? (_) => choose(search.text) : null,
              ),
              const SizedBox(height: 10),
              if (custom) ...[
                const Flexible(
                  child: SingleChildScrollView(
                    child: Text('从学校官网复制教务入口，不要粘贴登录后的临时链接。'),
                  ),
                ),
                const SizedBox(height: 10),
                FilledButton(
                  onPressed: () => choose(search.text),
                  child: const Text('使用这个网址'),
                ),
              ] else ...[
                Flexible(
                  child: matches.isEmpty
                      ? const Center(child: Text('未找到学校，可填写本校教务网址。'))
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: matches.length,
                          itemBuilder: (_, i) {
                            final e = matches[i];
                            return ListTile(
                              title: Text(e.name),
                              subtitle: Text(Uri.parse(e.entry).host),
                              onTap: () => choose(e.entry, e.name),
                            );
                          },
                        ),
                ),
              ],
              TextButton(
                onPressed: () {
                  setState(() {
                    custom = !custom;
                    search.clear();
                    error = null;
                  });
                },
                child: Text(custom ? '返回学校列表' : '填写其他学校教务网址'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<WhuTimetable?> openSchoolPortal(
  BuildContext context,
  SchoolPortalSite site,
  WhuTerm term,
) => Navigator.push<WhuTimetable>(
  context,
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => SchoolPortalPage(site: site, term: term),
  ),
);

class SchoolPortalPage extends StatefulWidget {
  const SchoolPortalPage({super.key, required this.site, required this.term});
  final SchoolPortalSite site;
  final WhuTerm term;
  @override
  State<SchoolPortalPage> createState() => _SchoolPortalPageState();
}

class _SchoolPortalPageState extends State<SchoolPortalPage> {
  win.WebviewController? windows;
  mobile.WebViewController? android;
  final subs = <StreamSubscription<dynamic>>[];
  Uri? uri;
  bool ready = false,
      loading = true,
      reading = false,
      blocked = false,
      canBack = false;
  bool closed = false;
  String? error;
  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  void update(VoidCallback f) {
    if (mounted && !closed) setState(f);
  }

  void _location(String url) {
    if (closed || url == 'about:blank') return;
    final next = Uri.tryParse(url);
    update(() {
      uri = next;
      blocked = !widget.site.permits(next);
      if (blocked) {
        loading = false;
        error = '此链接离开了本校域名。请返回学校教务入口。';
      }
    });
    if (blocked && windows != null) unawaited(windows!.stop());
  }

  Future<void> _start() async {
    try {
      if (Platform.isWindows) {
        if (await win.WebviewController.getWebViewVersion() == null) {
          throw StateError('需要安装 Microsoft Edge WebView2 Runtime。');
        }
        await NativeWhuPortal.initializeWindowsEnvironment();
        if (closed) return;
        final w = windows = win.WebviewController();
        await w.initialize();
        if (closed) {
          await w.dispose();
          return;
        }
        await w.setPopupWindowPolicy(win.WebviewPopupWindowPolicy.sameWindow);
        if (closed) return;
        subs.addAll([
          w.url.listen(_location),
          w.historyChanged.listen((s) => update(() => canBack = s.canGoBack)),
          w.loadingState.listen(
            (s) => update(() {
              loading = s == win.LoadingState.loading;
              if (loading && !blocked) error = null;
            }),
          ),
          w.onLoadError.listen(
            (_) => update(() {
              loading = false;
              if (!blocked) error = '学校页面无法打开，请检查校园网或学校 VPN 后重试。';
            }),
          ),
        ]);
      } else if (Platform.isAndroid) {
        final m = android = mobile.WebViewController();
        await m.setJavaScriptMode(mobile.JavaScriptMode.unrestricted);
        await m.setNavigationDelegate(
          mobile.NavigationDelegate(
            onNavigationRequest: (r) {
              if (widget.site.permits(Uri.tryParse(r.url))) {
                return mobile.NavigationDecision.navigate;
              }
              if (r.isMainFrame) update(() => error = '此链接不在本校域名内，未打开。');
              return mobile.NavigationDecision.prevent;
            },
            onUrlChange: (s) {
              if (s.url != null) _location(s.url!);
            },
            onPageStarted: (url) {
              _location(url);
              update(() {
                loading = true;
                if (!blocked) error = null;
              });
            },
            onPageFinished: (url) async {
              _location(url);
              final back = await m.canGoBack();
              update(() {
                loading = false;
                canBack = back;
              });
            },
            onWebResourceError: (e) {
              if (e.isForMainFrame == true) {
                update(() {
                  loading = false;
                  error = '学校页面无法打开，请检查校园网或学校 VPN 后重试。';
                });
              }
            },
          ),
        );
      } else {
        throw StateError('学校教务网页支持 Windows 和 Android。');
      }
      if (closed) return;
      update(() => ready = true);
      await _entry();
    } catch (e) {
      update(() {
        loading = false;
        error = e is StateError ? e.message : '学校网页组件启动失败，请关闭后再试。';
      });
    }
  }

  Future<void> _entry() async {
    update(() {
      error = null;
      blocked = false;
      loading = true;
      uri = null;
    });
    try {
      if (windows != null) {
        await windows!.loadUrl(widget.site.entry.toString());
      } else {
        await android!.loadRequest(widget.site.entry);
      }
    } catch (_) {
      update(() {
        loading = false;
        error = '未能打开学校入口，请重新选择学校。';
      });
    }
  }

  Future<void> _read() async {
    if (reading || !widget.site.canRead(uri) || blocked) return;
    update(() {
      reading = true;
      error = null;
    });
    try {
      final asset = await rootBundle.loadString(SchoolPortalTimetable.asset);
      if (closed) return;
      final script = SchoolPortalTimetable.script(asset, widget.site.entry);
      final raw =
          await (windows != null
                  ? windows!.executeScript(script)
                  : android!.runJavaScriptReturningResult(script))
              .timeout(const Duration(seconds: 15));
      if (closed) return;
      final result = SchoolPortalTimetable.parse(raw);
      if (!widget.site.canRead(uri)) throw StateError('页面已切换，请重新打开课表。');
      if (mounted) Navigator.pop(context, result);
    } catch (e) {
      update(
        () => error = e is FormatException
            ? e.message
            : e is StateError
            ? e.message
            : '未能读取当前页面，请打开个人学期课表后重试。',
      );
    } finally {
      update(() => reading = false);
    }
  }

  @override
  void dispose() {
    closed = true;
    for (final s in subs) {
      unawaited(s.cancel());
    }
    if (windows?.value.isInitialized == true) unawaited(windows!.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = WeekGlassPalette.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.site.name, overflow: TextOverflow.ellipsis),
        actions: [
          if (canBack)
            IconButton(
              tooltip: '返回上一网页',
              onPressed: () async {
                if (windows != null) {
                  await windows!.goBack();
                } else {
                  await android!.goBack();
                }
              },
              icon: const Icon(Icons.arrow_back),
            ),
          IconButton(
            tooltip: '重新打开学校入口',
            onPressed: ready && !reading ? _entry : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
              child: Row(
                children: [
                  Icon(
                    blocked ? Icons.block : Icons.language,
                    size: 17,
                    color: p.muted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      (uri ?? widget.site.entry).host,
                      style: TextStyle(color: p.text),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            if (loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: ready && !blocked && widget.site.permits(uri)
                  ? (windows != null
                        ? win.Webview(
                            windows!,
                            permissionRequested: (_, _, _) =>
                                win.WebviewPermissionDecision.deny,
                          )
                        : mobile.WebViewWidget(controller: android!))
                  : Center(
                      child: Icon(
                        Icons.school_outlined,
                        size: 48,
                        color: p.muted,
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    error ?? '在学校页面登录，打开${widget.term.label}的本人课表。',
                    style: TextStyle(
                      color: error == null
                          ? p.muted
                          : Theme.of(context).colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed:
                        ready &&
                            !loading &&
                            !reading &&
                            !blocked &&
                            widget.site.canRead(uri)
                        ? _read
                        : null,
                    icon: const Icon(Icons.calendar_view_week_outlined),
                    label: Text(reading ? '正在读取…' : '读取当前课表'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
