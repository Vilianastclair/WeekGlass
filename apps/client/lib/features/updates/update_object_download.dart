import 'dart:io';

import 'update_protocol.dart';

/// The server no longer has this optional update object.
class UpdateObjectUnavailable implements Exception {
  const UpdateObjectUnavailable();
}

/// Downloads a signed object to its cache path, or moves it straight to
/// [destination] when the object already is the final APK.
Future<File> downloadUpdateObject({
  required Uri uri,
  required File cacheFile,
  required String digest,
  required int size,
  File? destination,
  void Function(int received, int total)? onProgress,
}) async {
  final output = destination ?? cacheFile;
  final part = File('${cacheFile.path}.partial');
  final tagFile = File('${cacheFile.path}.etag');
  Future<bool> matches(File file) async =>
      await file.exists() &&
      await file.length() == size &&
      await fileSha256(file) == digest;

  Future<File> commit(File verified) async {
    if (await tagFile.exists()) await tagFile.delete();
    final file = verified.path == output.path
        ? verified
        : await verified.rename(output.path);
    onProgress?.call(size, size);
    return file;
  }

  if (await matches(cacheFile)) return commit(cacheFile);
  if (await matches(part)) return commit(part);
  if (await part.exists() && await part.length() >= size) {
    await part.delete();
  }

  final http = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    for (var attempt = 0; ; attempt++) {
      final resumeTag = await tagFile.exists()
          ? await tagFile.readAsString()
          : null;
      var offset = _strongEtag(resumeTag) && await part.exists()
          ? await part.length()
          : 0;
      try {
        final req = await http.getUrl(uri);
        req.followRedirects = false;
        req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        if (offset > 0) {
          req.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
          req.headers.set(HttpHeaders.ifRangeHeader, resumeTag!);
        }
        final response = await req.close().timeout(const Duration(seconds: 30));
        final status = response.statusCode;
        if (status == HttpStatus.notFound || status == HttpStatus.gone) {
          throw const UpdateObjectUnavailable();
        }
        if (status == HttpStatus.ok) {
          offset = 0;
        } else if (status == HttpStatus.partialContent) {
          if (offset == 0 ||
              response.headers.value(HttpHeaders.contentRangeHeader) !=
                  'bytes $offset-${size - 1}/$size' ||
              response.headers.value(HttpHeaders.etagHeader) != resumeTag) {
            throw const FormatException('更新续传响应无效');
          }
        } else if (status == HttpStatus.requestedRangeNotSatisfiable &&
            offset > 0) {
          throw const FormatException('更新续传范围无效');
        } else {
          throw const HttpException('更新下载响应无效');
        }
        if (response.headers.value(HttpHeaders.contentEncodingHeader) != null ||
            (response.contentLength >= 0 &&
                response.contentLength != size - offset)) {
          throw const FormatException('更新下载长度或编码不匹配');
        }
        final file = await part.open(
          mode: offset == 0 ? FileMode.write : FileMode.append,
        );
        var received = offset;
        try {
          final etag = response.headers.value(HttpHeaders.etagHeader);
          if (_strongEtag(etag)) {
            await tagFile.writeAsString(etag!);
          } else if (await tagFile.exists()) {
            await tagFile.delete();
          }
          await for (final chunk in response.timeout(
            const Duration(seconds: 30),
          )) {
            received += chunk.length;
            if (received > size) throw const FormatException('下载文件过大');
            await file.writeFrom(chunk);
            onProgress?.call(received, size);
          }
        } finally {
          await file.close();
        }
        if (received != size || await fileSha256(part) != digest) {
          throw const FormatException('下载文件校验失败');
        }
        return await commit(part);
      } on FormatException {
        // Never reuse bytes from a rejected range or a bad digest. A transient
        // transport interruption, by contrast, keeps its partial for next time.
        if (await tagFile.exists()) await tagFile.delete();
        if (await part.exists()) await part.delete();
        if (attempt > 0) rethrow;
        onProgress?.call(0, size);
      }
    }
  } finally {
    http.close(force: true);
  }
}

bool _strongEtag(String? tag) =>
    tag != null && tag.length >= 2 && tag.startsWith('"') && tag.endsWith('"');
