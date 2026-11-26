import 'dart:async';

import 'package:flutter/services.dart';

/// Only Sparkle replaces the application. The controller keeps accepting edits
/// until the planner can hand it a fully saved state.
class MacUpdateBridge {
  MacUpdateBridge({
    required this.canRelaunch,
    required this.prepare,
    required this.resume,
    required this.show,
  }) {
    channel.setMethodCallHandler(_handle);
  }

  static const channel = MethodChannel('weekglass/macos_updates');
  final bool Function() canRelaunch;
  final Future<void> Function() prepare;
  final Future<void> Function() resume;
  final void Function(String) show;
  Completer<bool>? _waiting;
  bool sealing = false;

  Future<void> check({required bool startup}) async {
    try {
      if (startup) {
        final bundle = await channel.invokeMapMethod<String, String>('bundle');
        if (bundle != null) show('当前版本 ${bundle['version']}');
      }
      await channel.invokeMethod<void>(startup ? 'start' : 'check');
    } on PlatformException catch (e) {
      show(e.message ?? '无法启动 macOS 更新。');
    }
  }

  Future<Object?> _handle(MethodCall call) async {
    switch (call.method) {
      case 'prepareRelaunch':
        final response = _waiting ??= Completer<bool>();
        if (!canRelaunch()) show('更新已就绪，返回日程后会保存并重启。');
        resumeWhenReady();
        return response.future;
      case 'finished':
        final result = Map<Object?, Object?>.from(call.arguments as Map);
        _waiting?.complete(false);
        _waiting = null;
        if (sealing && result['resume'] == true) await resume();
        sealing = false;
        show(result['message'] as String);
        return null;
      default:
        throw MissingPluginException(call.method);
    }
  }

  void resumeWhenReady() {
    final response = _waiting;
    if (response == null || sealing || !canRelaunch()) return;
    sealing = true;
    show('正在保存日程并重启…');
    unawaited(_seal(response));
  }

  Future<void> _seal(Completer<bool> response) async {
    try {
      await prepare();
      if (response.isCompleted) {
        await resume();
        return;
      }
      _waiting = null;
      response.complete(true);
    } catch (_) {
      _waiting = null;
      try {
        await resume();
      } finally {
        sealing = false;
        if (!response.isCompleted) response.complete(false);
        show('保存日程失败，更新已暂停。可在设置中重试。');
      }
    }
  }
}
