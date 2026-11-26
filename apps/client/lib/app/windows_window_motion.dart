import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum WindowsWindowMotionMode { system, gentle, liquidGlass }

/// Windows shell appearance is stored locally, separate from planner settings.
final class WindowsWindowMotion {
  WindowsWindowMotion._();

  static final instance = WindowsWindowMotion._();
  static const _channel = MethodChannel('weekglass/desktop');
  static const _preferenceKey = 'windows_window_motion_v1';

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  WindowsWindowMotionMode _mode = WindowsWindowMotionMode.system;
  WindowsWindowMotionMode get mode => _mode;

  Future<void> initialize() async {
    if (!isSupported) return;
    try {
      _mode = switch (await SharedPreferencesAsync().getString(
        _preferenceKey,
      )) {
        'liquidGlass' => WindowsWindowMotionMode.liquidGlass,
        'gentle' => WindowsWindowMotionMode.gentle,
        _ => WindowsWindowMotionMode.system,
      };
      await _apply(_mode);
    } catch (error) {
      // An unavailable preference or shell must not prevent the app opening.
      debugPrint('Could not restore the Windows window motion: $error');
    }
  }

  Future<void> select(WindowsWindowMotionMode mode) async {
    if (!isSupported) return;
    await _apply(mode);
    _mode = mode;
    await SharedPreferencesAsync().setString(_preferenceKey, mode.name);
  }

  Future<void> _apply(WindowsWindowMotionMode mode) =>
      _channel.invokeMethod<void>('setWindowMotion', mode.name);
}
