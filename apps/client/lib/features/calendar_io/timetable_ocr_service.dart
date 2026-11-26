import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'timetable_image_parser.dart';

class TimetableOcrService {
  const TimetableOcrService();
  static const maxImageBytes = 25 * 1024 * 1024;
  static const _channel = MethodChannel('weekglass/timetable_ocr');
  bool get supportsImages =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS);

  Future<Uint8List?> clipboardImage() async {
    if (!supportsImages) {
      throw const FormatException('当前设备支持粘贴课表文字。');
    }
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('clipboardImage');
      return bytes == null || bytes.isEmpty ? null : bytes;
    } on PlatformException catch (error) {
      throw FormatException(_error(error.code));
    }
  }

  Future<TimetableOcrPage> recognize(Uint8List bytes) async {
    if (!supportsImages) {
      throw const FormatException('请粘贴或填写课表文字继续导入。');
    }
    if (bytes.isEmpty || bytes.length > maxImageBytes) {
      throw const FormatException('请选择不超过 25 MB 的课表图片。');
    }
    // Windows' optional WebP codec is not assumed to exist. Flutter ships its
    // decoder; normalize just this format in memory before native recognition.
    if (bytes.length >= 12 &&
        String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
        String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      ui.ImageDescriptor? descriptor;
      ui.Codec? codec;
      ui.Image? image;
      try {
        descriptor = await ui.ImageDescriptor.encoded(buffer);
        if (descriptor.width * descriptor.height > 80000000) {
          throw const FormatException('图片像素过大，请使用清晰的课表截图。');
        }
        final scale = math.min(
          1.0,
          2600 / math.max(descriptor.width, descriptor.height),
        );
        codec = await descriptor.instantiateCodec(
          targetWidth: (descriptor.width * scale).round(),
          targetHeight: (descriptor.height * scale).round(),
        );
        image = (await codec.getNextFrame()).image;
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        if (png == null) throw const FormatException('图片无法解码，请换用 PNG 或 JPEG。');
        bytes = png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
      } finally {
        image?.dispose();
        codec?.dispose();
        descriptor?.dispose();
        buffer.dispose();
      }
    }
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'recognize',
        bytes,
      );
      if (result == null) throw const FormatException('没有获得图片识别结果，请重新选择图片。');
      return TimetableOcrPage.fromMap(result);
    } on PlatformException catch (error) {
      throw FormatException(_error(error.code));
    } on MissingPluginException {
      throw const FormatException('此版本未提供图片识别组件，可先粘贴课表文字继续导入。');
    }
  }

  static String _error(String code) => switch (code) {
    'chinese_unavailable' => '此设备未提供中文本地识别能力。可在下方粘贴或填写课表文字；图片没有上传。',
    'image_size' => '请选择不超过 25 MB 的课表图片。',
    'image_dimensions' => '图片像素过大或尺寸无效，请使用清晰的课表截图。',
    'clipboard_busy' => '剪贴板暂时被占用，请稍后再粘贴。',
    'clipboard_unavailable' => '剪贴板图片暂时无法读取，请保存为图片后选择。',
    'busy' => '上一张图片仍在识别，请稍候。',
    _ => '图片本地识别未完成。可尝试清晰的 PNG / JPEG，或直接修改下方课表文字；图片没有上传。',
  };
}
