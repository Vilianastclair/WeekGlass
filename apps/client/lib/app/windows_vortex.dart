import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

/// Samples only the planner subtree, never the desktop or a login WebView.
class WindowsVortex extends NavigatorObserver {
  static final instance = WindowsVortex();
  static const _channel = MethodChannel('weekglass/vortex');
  final frameKey = GlobalKey(debugLabel: 'Windows planner surface');
  bool _allowed = false;
  bool _reading = false;
  int _revision = 0;
  bool _attached = false;

  void attach() {
    _attached = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'captureFrame') return captureFrame();
      throw MissingPluginException();
    });
  }

  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    // Only the home route owns the drawable planner surface. A route
    // replacement must not inherit permission merely because it is first.
    final allowed = topRoute.isFirst && topRoute.settings.name == '/';
    if (_allowed == allowed) return;
    _allowed = allowed;
    _revision++;
    if (_attached) unawaited(_notify(allowed));
  }

  Future<void> _notify(bool allowed) async {
    try {
      await _channel.invokeMethod<void>('setCaptureAllowed', allowed);
    } on MissingPluginException {
      // A Flutter-only host still uses the native window-manager controls.
    }
  }

  Future<Map<String, Object>?> captureFrame() async {
    if (!_allowed || _reading) return null;
    final context = frameKey.currentContext;
    final surface = context?.findRenderObject();
    if (context == null ||
        surface is! RenderRepaintBoundary ||
        !surface.attached ||
        !surface.hasSize ||
        surface.size.isEmpty) {
      return null;
    }
    final revision = _revision;
    final nativeRatio = View.of(context).devicePixelRatio;
    final longest = surface.size.longestSide;
    // OffsetLayer.toImage rounds up. Dividing an exact 1600 by a logical
    // size and multiplying back can yield 1600.0000000000002, which the
    // runner correctly rejects as a 1601px snapshot. Aim within the last
    // pixel when scaling down; Flutter will still produce all 1600 pixels.
    const limit = 1600;
    final ratio = longest * nativeRatio > limit
        ? (limit - 0.5) / longest
        : nativeRatio;
    _reading = true;
    ui.Image? image;
    try {
      image = await surface.toImage(pixelRatio: ratio);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (revision != _revision || bytes == null) return null;
      return {
        'width': image.width,
        'height': image.height,
        'rgba': bytes.buffer.asUint8List(
          bytes.offsetInBytes,
          bytes.lengthInBytes,
        ),
      };
    } finally {
      image?.dispose();
      _reading = false;
    }
  }

  static Future<void> minimize() async {
    try {
      await _channel.invokeMethod<void>('minimize');
    } on MissingPluginException {
      await windowManager.minimize();
    }
  }
}
