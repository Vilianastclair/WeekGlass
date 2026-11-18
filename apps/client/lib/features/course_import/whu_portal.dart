import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:webview_windows/webview_windows.dart' as win;
import 'package:webview_flutter/webview_flutter.dart' as mobile;

import 'whu_timetable.dart';
import 'school_adapter.dart';

class WhuSchoolQueryPending extends StateError {
  WhuSchoolQueryPending() : super('请在学校页面完成查询；如出现人机验证，完成后会自动进入课程预览。');
}

abstract class WhuPortal extends ChangeNotifier {
  bool get initialized;
  bool get loading;
  bool get canRead;
  String get host;
  String? get error;
  Widget buildView();
  Future<void> initialize();
  Future<void> reconnect();
  Future<void> openTimetable();
  Future<void> signOut();
  Future<WhuTimetable> read(WhuTerm term);
  bool hasTimetable(WhuTerm term) => false;
  Future<void> close();
}

/// Passwords, CAS tickets and cookies stay in the official site's WebView.
class NativeWhuPortal extends WhuPortal {
  NativeWhuPortal({this.school = SchoolAdapter.whu});
  final SchoolAdapter school;
  // WebView2 has one process-wide environment. Keep the existing WHU data
  // directory so a user can use either school reader first.
  static Future<void> initializeWindowsEnvironment() =>
      _environment ??= () async {
        final support = await getApplicationSupportDirectory();
        await win.WebviewController.initializeEnvironment(
          userDataPath: path.join(support.path, 'whu_webview'),
        );
      }();

  static const entry = 'https://jwgl.whu.edu.cn/';
  static Future<void>? _environment;
  win.WebviewController? _windows;
  mobile.WebViewController? _mobile;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _initialized = false, _loading = false, _closed = false;
  String _url = '';
  String? _error;
  Timer? _loadTimeout;
  Completer<WhuTimetable>? _pending;
  String? _requestId;
  final String _observerId = const Uuid().v4();
  WhuTerm? _observedTerm, _readingTerm;
  WhuTimetable? _observed;
  Completer<void>? _pageReady;
  @override
  bool get initialized => _initialized;
  @override
  bool get loading => _loading;
  @override
  bool get canRead =>
      _initialized &&
      _error == null &&
      !_loading &&
      school.isTeachingPage(_url) &&
      !_url.contains('/sso/') &&
      !_url.contains('login');
  @override
  String get host => Uri.tryParse(_url)?.host ?? '';
  @override
  String? get error => _error;
  void _notify() {
    if (!_closed) notifyListeners();
  }

  static bool allowed(String url) => SchoolAdapter.whu.allowed(url);

  @override
  Future<void> initialize() async {
    if (_initialized || _closed) return;
    _loading = true;
    _error = null;
    _notify();
    try {
      if (Platform.isWindows) {
        if (await win.WebviewController.getWebViewVersion() == null) {
          throw StateError('需要安装 Microsoft Edge WebView2 Runtime 后才能打开学校登录。');
        }
        await initializeWindowsEnvironment();
        if (_closed) return;
        final w = _windows = win.WebviewController();
        await w.initialize();
        if (_closed) {
          await w.dispose();
          return;
        }
        await w.setPopupWindowPolicy(win.WebviewPopupWindowPolicy.sameWindow);
        await w.addScriptToExecuteOnDocumentCreated(
          whuObserveScript(_observerId, school: school),
        );
        _subscriptions.add(
          w.url.listen((url) {
            _url = url;
            _completePageReady();
            if (url != 'about:blank' && !school.allowed(url)) {
              unawaited(w.stop());
              _error = '请在学校统一身份认证与教务页面内完成登录。';
            }
            _notify();
          }),
        );
        _subscriptions.add(
          w.loadingState.listen(
            (s) => _onLoading(s == win.LoadingState.loading),
          ),
        );
        _subscriptions.add(
          w.onLoadError.listen((_) {
            _loading = false;
            _error = '学校页面暂时无法打开。请检查网络或校园 VPN 后重试。';
            _notify();
          }),
        );
        _subscriptions.add(w.webMessage.listen(_receive));
      } else if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
        final m = _mobile = mobile.WebViewController();
        await m.setJavaScriptMode(mobile.JavaScriptMode.unrestricted);
        await m.addJavaScriptChannel(
          'WeekGlassWhu',
          onMessageReceived: (message) => _receive(message.message),
        );
        await m.setNavigationDelegate(
          mobile.NavigationDelegate(
            onNavigationRequest: (request) => school.allowed(request.url)
                ? mobile.NavigationDecision.navigate
                : mobile.NavigationDecision.prevent,
            onPageStarted: (url) {
              _url = url;
              _onLoading(true);
            },
            onPageFinished: (url) async {
              _url = url;
              if (school.isTeachingPage(url)) {
                await m.runJavaScript(
                  whuObserveScript(_observerId, school: school),
                );
              }
              _onLoading(false);
            },
            onWebResourceError: (e) {
              if (e.isForMainFrame == true) {
                _loading = false;
                _error = '学校页面暂时无法打开，请检查网络后重试。';
                _notify();
              }
            },
          ),
        );
      } else {
        throw StateError('此平台暂不支持学校网页登录。');
      }
      _initialized = true;
      await reconnect();
    } catch (e) {
      _loading = false;
      _error = e is StateError ? e.message : '学校登录组件启动失败，请关闭后重试。';
      _notify();
    }
  }

  void _onLoading(bool value) {
    _loading = value;
    _loadTimeout?.cancel();
    if (value) {
      _error = null;
      _loadTimeout = Timer(const Duration(seconds: 35), () {
        _loading = false;
        _error = '学校页面响应较慢，可重新连接；已导入的日程仍可正常使用。';
        _notify();
      });
    }
    _completePageReady();
    _notify();
  }

  void _completePageReady() {
    if (!_loading &&
        _url.contains('/kbcx/') &&
        _pageReady?.isCompleted == false) {
      _pageReady!.complete();
    }
  }

  @override
  Widget buildView() {
    if (!_initialized) return const SizedBox.shrink();
    if (_windows != null) {
      return win.Webview(
        _windows!,
        permissionRequested: (url, kind, user) =>
            win.WebviewPermissionDecision.deny,
      );
    }
    return mobile.WebViewWidget(controller: _mobile!);
  }

  @override
  Future<void> reconnect() async {
    if (!_initialized) {
      await initialize();
      return;
    }
    _error = null;
    _onLoading(true);
    if (_windows != null) {
      await _windows!.loadUrl(school.entry);
    } else {
      await _mobile!.loadRequest(Uri.parse(school.entry));
    }
  }

  @override
  Future<void> openTimetable() async {
    if (!_initialized) return;
    _pageReady = Completer<void>();
    final url = school.timetableUrl;
    _onLoading(true);
    if (_windows != null) {
      await _windows!.loadUrl(url);
    } else {
      await _mobile!.loadRequest(Uri.parse(url));
    }
  }

  @override
  Future<void> signOut() async {
    _observed = null;
    _observedTerm = null;
    if (_windows != null) {
      await _windows!.clearCookies();
      await _windows!.clearCache();
    }
    if (_mobile != null) {
      await mobile.WebViewCookieManager().clearCookies();
      await _mobile!.clearCache();
      await _mobile!.clearLocalStorage();
    }
    _url = '';
    _error = null;
    _notify();
    await reconnect();
  }

  void _receive(dynamic message) {
    try {
      final value = message is String ? jsonDecode(message) : message;
      if (value is Map &&
          value['observerId'] == _observerId &&
          school.isTeachingPage(_url)) {
        final query = value['query'];
        if (query is! Map) return;
        final year = int.tryParse('${query['xnm']}');
        final semester = int.tryParse('${query['xqm']}');
        if (year == null || !const [3, 12, 16].contains(semester)) return;
        final data = WhuTimetable.parse(value['data']);
        if (data.meetings.isEmpty && data.warnings.isEmpty) return;
        final term = WhuTerm(year, semester!);
        if (const bool.fromEnvironment('WG_WHU_DIAGNOSTICS')) {
          unawaited(_writeAnonymousFixture(value['data']));
          unawaited(
            _writeDiagnostic({
              'source': 'official-page-query',
              'year': year,
              'semester': semester,
              'courseCount': data.courseKeys.length,
              'meetingCount': data.meetings.length,
              'warningCount': data.warnings.length,
            }),
          );
        }
        if (_pending != null &&
            !_pending!.isCompleted &&
            _readingTerm?.key == term.key) {
          _pending!.complete(data);
        } else {
          _observedTerm = term;
          _observed = data;
          _notify();
        }
        return;
      }
    } catch (_) {
      // Only validated personal timetable responses can reach the calendar.
      return;
    }
    final pending = _pending;
    if (pending == null ||
        pending.isCompleted ||
        !school.isTeachingPage(_url)) {
      return;
    }
    try {
      final value = message is String ? jsonDecode(message) : message;
      if (value is! Map || value['requestId'] != _requestId) return;
      if (const bool.fromEnvironment('WG_WHU_DIAGNOSTICS')) {
        // Development-only, structural metadata: never credentials or course contents.
        unawaited(_writeDiagnostic(value['diagnostic']));
      }
      if (value['error'] != null) {
        if (value['error'] == 'schoolQuery') {
          pending.completeError(WhuSchoolQueryPending());
          return;
        }
        pending.completeError(
          StateError(switch (value['error']) {
            'login' => '登录已过期，请重新连接并在学校页面完成登录。',
            'timeout' => '课表读取超时，请稍后重试。',
            'unverifiedEmpty' =>
              '学校返回了空结果。请在下方学校页面打开“信息查询 → 课表查询”，确认学期后再点“读取课表”。',
            _ => '未能读取课表，请确认学期并重试；学校可能正在维护。',
          }),
        );
      } else {
        pending.complete(WhuTimetable.parse(value['data']));
      }
    } catch (_) {
      pending.completeError(const FormatException('学校返回的课表格式无法识别，本次没有导入。'));
    }
  }

  Future<void> _writeDiagnostic(Object? value) async {
    if (value == null) return;
    try {
      final support = await getApplicationSupportDirectory();
      await File(path.join(support.path, 'whu-reader-diagnostic.json'))
          .writeAsString(jsonEncode(value));
    } catch (_) {
      // Diagnostics must never affect importing.
    }
  }

  Future<void> _writeAnonymousFixture(Object? data) async {
    if (data is! Map) return;
    try {
      final ids = <String, int>{};
      List<Map<String, Object?>> rows(Object? source) => source is! List
          ? []
          : source.whereType<Map>().map((row) {
              final identity =
                  '${row['jxb_id'] ?? row['kch_id'] ?? row['kcmc']}';
              final id = ids.putIfAbsent(identity, () => ids.length + 1);
              return <String, Object?>{
                'kcmc': '示例课程 $id',
                'jxb_id': 'sample-$id',
                'cdmc': '示例教室',
                'xm': '示例教师',
                for (final key in [
                  'xqj',
                  'jcs',
                  'jcd',
                  'zcd',
                  'rq',
                  'qsz',
                  'jsz',
                  'zc',
                  'skrq',
                  'ksrq',
                  'jsrq',
                ])
                  if (row.containsKey(key)) key: row[key],
              };
            }).toList();
      final fixture = {
        'xsxx': {'XH': 'sample-student'},
        'kbList': rows(data['kbList']),
        'sjkList': rows(data['sjkList']),
      };
      final support = await getApplicationSupportDirectory();
      await File(path.join(support.path, 'whu-reader-fixture.json'))
          .writeAsString(jsonEncode(fixture));
    } catch (_) {}
  }

  @override
  bool hasTimetable(WhuTerm term) =>
      _observed != null && _observedTerm?.key == term.key;

  @override
  Future<WhuTimetable> read(WhuTerm term) async {
    if (hasTimetable(term)) {
      final data = _observed!;
      _observed = null;
      return data;
    }
    if (!canRead) throw StateError('请先完成学校登录。');
    if (_pending != null) throw StateError('正在读取课表，请稍候。');
    if (!_url.contains('/kbcx/')) {
      await openTimetable();
      await _pageReady!.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw StateError('学校课表页尚未打开，请完成学校登录后重试。'),
      );
      if (_closed) throw StateError('读取已取消。');
    }
    if (hasTimetable(term)) {
      final data = _observed!;
      _observed = null;
      return data;
    }
    _readingTerm = term;
    final request = _requestId = const Uuid().v4();
    final pending = _pending = Completer<WhuTimetable>();
    try {
      final script = whuFetchScript(request, term, school: school);
      if (_windows != null) {
        await _windows!.executeScript(script);
      } else {
        await _mobile!.runJavaScript(script);
      }
      return await pending.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw StateError('课表读取超时，请重新连接后重试。'),
      );
    } finally {
      _pending = null;
      _requestId = null;
      _readingTerm = null;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_pageReady?.isCompleted == false) _pageReady!.complete();
    _loadTimeout?.cancel();
    for (final s in _subscriptions) {
      await s.cancel();
    }
    if (_windows?.value.isInitialized == true) await _windows!.dispose();
    if (_pending != null && !_pending!.isCompleted) {
      _pending!.completeError(StateError('读取已取消。'));
    }
    super.dispose();
  }
}

// Capture only the official personal-timetable response. The school's own
// query code supplies its verification token; no authentication fields leave the WebView.
String whuObserveScript(
  String observerId, {
  SchoolAdapter school = SchoolAdapter.whu,
}) =>
    '''
(() => {
  if (location.origin!==${jsonEncode(school.origin)} || window.__weekglassObserver) return;
  window.__weekglassObserver = true;
  const open = XMLHttpRequest.prototype.open;
  const send = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(method,url,...rest) {
    this.__wgUrl = String(url);
    return open.call(this,method,url,...rest);
  };
  XMLHttpRequest.prototype.send = function(body) {
    const url = new URL(this.__wgUrl || '',location.href);
    if(url.origin===location.origin && url.pathname===${jsonEncode(school.responsePath)}) {
      const params = new URLSearchParams(typeof body==='string'?body:'');
      const query = {
        xnm:params.get('xnm') || document.querySelector('#xnm')?.value || '',
        xqm:params.get('xqm') || document.querySelector('#xqm')?.value || ''
      };
      this.addEventListener('load',()=>{
        try {
          const data = this.responseType==='json'?this.response:JSON.parse(this.responseText);
          if (!Array.isArray(data.kbList)) return;
          const message = JSON.stringify({observerId:${jsonEncode(observerId)},query,data});
          if(window.chrome?.webview) window.chrome.webview.postMessage(message);
          else if(window.WeekGlassWhu) window.WeekGlassWhu.postMessage(message);
        } catch (_) {}
      },{once:true});
    }
    return send.call(this,body);
  };
})();
''';

String whuFetchScript(
  String requestId,
  WhuTerm term, {
  SchoolAdapter school = SchoolAdapter.whu,
}) =>
    '''
(() => {
  if (location.origin !== ${jsonEncode(school.origin)}) return;
  const requestId = ${jsonEncode(requestId)};
  const send = value => {
    const message = JSON.stringify({requestId, ...value});
    if (window.chrome && window.chrome.webview) window.chrome.webview.postMessage(message);
    else if (window.WeekGlassWhu) window.WeekGlassWhu.postMessage(message);
  };
  const abort = new AbortController();
  const timeout = setTimeout(() => abort.abort(), 24000);
  const requestedYear = ${jsonEncode('${term.year}')};
  const requestedSemester = ${term.semester};
  const diagnostic = {requestedYear, requestedSemester};
  (async () => {
    const documents = [document];
    for (const frame of document.querySelectorAll('iframe')) {
      try { if (frame.contentDocument && frame.contentWindow.location.origin === location.origin) documents.push(frame.contentDocument); } catch (_) {}
    }
    let formDocument = documents.find(doc => doc.querySelector('#xnm')?.options?.length && doc.querySelector('#xqm')?.options?.length);
    if (!formDocument) {
      let indexPath;
      for (const element of document.querySelectorAll('a,[onclick]')) {
        if (!(element.textContent || '').includes('课表')) continue;
        const attributes = (element.getAttribute('href') || '') + ' ' + (element.getAttribute('onclick') || '');
        const match = attributes.match(/\\/kbcx\\/[a-zA-Z0-9_]+\\.html/);
        if (match) { indexPath = ${jsonEncode(school.pathPrefix)} + match[0]; break; }
      }
      if (indexPath) {
        diagnostic.indexPath = indexPath;
        const page = await fetch(indexPath + '?gnmkdm=N2151&layout=default', {credentials:'same-origin',signal:abort.signal});
        if (page.ok && new URL(page.url).origin === location.origin) {
          const doc = new DOMParser().parseFromString(await page.text(), 'text/html');
          if (doc.querySelector('#xnm') && doc.querySelector('#xqm')) formDocument = doc;
        }
      }
    }
    let xnm = requestedYear;
    let xqm = String(requestedSemester);
    let verifiedTerm = false;
    if (formDocument) {
      const yearOptions = Array.from(formDocument.querySelector('#xnm').options || []);
      const semOptions = Array.from(formDocument.querySelector('#xqm').options || []);
      const yearOption = yearOptions.find(o => o.value === requestedYear || (o.textContent || '').trim().startsWith(requestedYear));
      const matchesLabel = text => {
        const label = (text || '').replace(/\\s/g,'');
        if (requestedSemester === 3) return /秋|第一/.test(label) || label === '1' || label === '1学期';
        if (requestedSemester === 12) return /春|第二/.test(label) || label === '2' || label === '2学期';
        return /夏|第三/.test(label) || label === '3' || label === '3学期';
      };
      const semOption = semOptions.find(o => matchesLabel(o.textContent)) || semOptions.find(o => o.value === String(requestedSemester));
      diagnostic.semesterOptions = semOptions.map(o => ({value:o.value,label:o.textContent}));
      diagnostic.schoolYear = formDocument.querySelector('#xnm').value;
      diagnostic.schoolSemester = formDocument.querySelector('#xqm').value;
      if (yearOption && semOption) { xnm=yearOption.value; xqm=semOption.value; verifiedTerm=true; }
      if (documents.includes(formDocument) && verifiedTerm) {
        const button = Array.from(formDocument.querySelectorAll('button,input[type="button"],input[type="submit"],a.btn'))
          .find(e => (e.textContent || e.value || '').trim()==='查询');
        if (button) {
          formDocument.querySelector('#xnm').value=xnm;
          formDocument.querySelector('#xqm').value=xqm;
          formDocument.querySelector('#xnm').dispatchEvent(new Event('change',{bubbles:true}));
          formDocument.querySelector('#xqm').dispatchEvent(new Event('change',{bubbles:true}));
          button.click();
          send({error:'schoolQuery',diagnostic});
          return;
        }
      }
    }
    diagnostic.query = {xnm,xqm};
    diagnostic.verifiedTerm = verifiedTerm;
    const response = await fetch(${jsonEncode('${school.responsePath}?gnmkdm=N2151')}, {
    method:'POST', credentials:'same-origin', signal:abort.signal,
    headers:{'Content-Type':'application/x-www-form-urlencoded;charset=UTF-8','X-Requested-With':'XMLHttpRequest'},
    body:new URLSearchParams({xnm,xqm}).toString()
    });
    diagnostic.status = response.status;
    if (new URL(response.url).origin !== location.origin) {send({error:'login',diagnostic});return;}
    if (!response.ok) {send({error:'request',diagnostic});return;}
    const text = await response.text();
    if (text.length > 4000000) {send({error:'format',diagnostic});return;}
    try {
      const data=JSON.parse(text);
      diagnostic.responseKeys = Object.keys(data);
      diagnostic.courseRows = Array.isArray(data.kbList)?data.kbList.length:null;
      diagnostic.arrayShapes = Object.fromEntries(Object.entries(data).filter(([k,v])=>Array.isArray(v)).map(([k,v])=>[k,{count:v.length,firstKeys:v.length && typeof v[0]==='object' && v[0]!==null?Object.keys(v[0]):[]}]));
      if(!Array.isArray(data.kbList)){send({error:'format',diagnostic});return;}
      if(data.kbList.length===0 && !verifiedTerm) {send({error:'unverifiedEmpty',diagnostic});return;}
      send({data,diagnostic});
    }
    catch (_) {send({error:/authserver|登录|loginForm/.test(text)?'login':'format',diagnostic});}
  })().catch(error => {diagnostic.failure=String(error).slice(0,200);send({error:error.name==='AbortError'?'timeout':'request',diagnostic});}).finally(()=>clearTimeout(timeout));
})();
''';
