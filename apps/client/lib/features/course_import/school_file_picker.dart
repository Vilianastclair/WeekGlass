import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;

import 'school_html_format.dart';
import 'school_html_import.dart';
import 'whu_timetable.dart';

Future<WhuTimetable?> pickSchoolTimetableFile(SchoolHtmlFormat format) async {
  final file = await FilePicker.pickFile(
    dialogTitle: '选择本人课表文件',
    type: FileType.custom,
    allowedExtensions: [
      if (format == SchoolHtmlFormat.westlake) 'xls',
      'html',
      'htm',
    ],
    windowsOptions: const WindowsOptions(lockParentWindow: true),
  );
  if (file == null) return null;
  const tooLarge = FormatException('课表文件超过 4 MB，请选择单学期的原始导出文件。');
  if ((await file.length() ?? 0) > SchoolHtmlImport.maxBytes) throw tooLarge;
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in file.readAsByteStream()) {
    if (chunk.length + bytes.length > SchoolHtmlImport.maxBytes) throw tooLarge;
    bytes.add(chunk);
  }
  return compute(SchoolHtmlImport.read, (
    format: format,
    bytes: bytes.takeBytes(),
  ));
}
