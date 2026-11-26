import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'calendar_codec.dart';

Future<({String name, String text, CalendarFileFormat format})?>
pickCalendarFile() async {
  final file = await FilePicker.pickFile(
    dialogTitle: '选择日历文件',
    type: FileType.custom,
    allowedExtensions: ['ics', 'csv', 'json'],
    windowsOptions: const WindowsOptions(lockParentWindow: true),
  );
  if (file == null) return null;
  final format = switch (file.extension?.toLowerCase()) {
    'ics' => CalendarFileFormat.ics,
    'json' => CalendarFileFormat.json,
    'csv' => CalendarFileFormat.csv,
    _ => throw const FormatException('请选择 ICS、CSV 或 JSON 文件。'),
  };
  if ((await file.length() ?? 0) > CalendarCodec.maxBytes) {
    throw const FormatException('文件超过 10 MB，请先拆分日历。');
  }
  // The picker reads the selected document; on iOS it provides a sandbox
  // copy. Do not interpret provider URLs as operating system paths.
  final bytes = BytesBuilder(copy: false);
  await for (final part in file.readAsByteStream()) {
    bytes.add(part);
    if (bytes.length > CalendarCodec.maxBytes) {
      throw const FormatException('文件超过 10 MB，请先拆分日历。');
    }
  }
  return (
    name: file.name,
    text: CalendarCodec.decodeText(bytes.takeBytes()),
    format: format,
  );
}

/// The platform picker writes the selected destination, including the system
/// document browser on iOS. Treat its resulting path or URI as a receipt;
/// the app never reopens it or needs storage permission to finish the export.
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
