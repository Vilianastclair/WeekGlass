import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Native save-as on Windows; Android's document creator returns a content URI.
/// The picker writes only the file explicitly chosen by the user and needs no
/// broad storage permission. A cancellation leaves no app-managed export copy.
Future<String?> saveCalendarFile({
  required Uint8List bytes,
  required String suggestedName,
  required String extension,
  required String mimeType,
}) async {
  final name = suggestedName.toLowerCase().endsWith('.$extension')
      ? suggestedName
      : '$suggestedName.$extension';
  final uri = await FilePicker.saveFile(
    fileName: name,
    bytes: bytes,
    mimeType: mimeType,
    dialogTitle: '保存日历',
    windowsOptions: const WindowsOptions(lockParentWindow: true),
  );
  return uri == null
      ? null
      : uri.scheme == 'file'
      ? uri.toFilePath()
      : uri.toString();
}
