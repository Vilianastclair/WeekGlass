import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:weekglass/features/updates/update_object_download.dart';
import 'package:weekglass/features/updates/update_protocol.dart';

void main() {
  const content = [2, 3, 5, 7, 11, 13, 17, 19];
  const etag = '"signed-object"';
  final digest = sha256(content);
  late Directory work;
  late HttpServer server;
  late File cached;
  late File part;
  late File tag;
  late List<String?> ranges;
  late List<String?> ifRanges;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('weekglass-object-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    cached = File(p.join(work.path, digest));
    part = File('${cached.path}.partial');
    tag = File('${cached.path}.etag');
    ranges = [];
    ifRanges = [];
  });

  tearDown(() async {
    await server.close(force: true);
    await work.delete(recursive: true);
  });

  void respond(Future<void> Function(HttpResponse response, int index) send) {
    server.listen((request) async {
      ranges.add(request.headers.value(HttpHeaders.rangeHeader));
      ifRanges.add(request.headers.value(HttpHeaders.ifRangeHeader));
      await send(request.response, ranges.length - 1);
    });
  }

  Future<void> reply(
    HttpResponse response, {
    List<int> bytes = content,
    int status = HttpStatus.ok,
    String? range,
    String responseTag = etag,
  }) async {
    response.statusCode = status;
    response.headers.set(HttpHeaders.etagHeader, responseTag);
    if (range != null) {
      response.headers.set(HttpHeaders.contentRangeHeader, range);
    }
    response.contentLength = bytes.length;
    response.add(bytes);
    await response.close();
  }

  Future<void> partial(List<int> prefix) async {
    await part.writeAsBytes(prefix);
    await tag.writeAsString(etag);
  }

  Future<File> download({
    File? destination,
    void Function(int received, int total)? onProgress,
  }) => downloadUpdateObject(
    uri: Uri.parse('http://127.0.0.1:${server.port}/object'),
    cacheFile: cached,
    digest: digest,
    size: content.length,
    destination: destination,
    onProgress: onProgress,
  );

  test(
    'matching 206 appends at the saved offset and verifies the object',
    () async {
      await partial(content.sublist(0, 3));
      respond(
        (response, _) => reply(
          response,
          status: HttpStatus.partialContent,
          range: 'bytes 3-7/8',
          bytes: content.sublist(3),
        ),
      );
      expect(await (await download()).readAsBytes(), content);
      expect(ranges, ['bytes=3-']);
      expect(ifRanges, [etag]);
      expect(await part.exists(), isFalse);
      expect(await tag.exists(), isFalse);
    },
  );

  test(
    'rejected range retries once from byte zero instead of looping',
    () async {
      await partial(content.sublist(0, 3));
      respond(
        (response, index) => index == 0
            ? reply(
                response,
                status: HttpStatus.requestedRangeNotSatisfiable,
                bytes: [],
              )
            : reply(response),
      );
      expect(await (await download()).readAsBytes(), content);
      expect(ranges, ['bytes=3-', null]);
      expect(ifRanges, [etag, null]);
    },
  );

  for (final invalid in ['range', 'etag']) {
    test(
      'mismatched 206 $invalid is discarded before fresh download',
      () async {
        await partial(content.sublist(0, 3));
        respond(
          (response, index) => index == 0
              ? reply(
                  response,
                  status: HttpStatus.partialContent,
                  range: invalid == 'range' ? 'bytes 2-6/8' : 'bytes 3-7/8',
                  responseTag: invalid == 'etag' ? '"other-object"' : etag,
                  bytes: content.sublist(3),
                )
              : reply(response),
        );
        expect(await (await download()).readAsBytes(), content);
        expect(ranges, ['bytes=3-', null]);
      },
    );
  }

  test(
    '200 in place of 206 replaces the partial without another request',
    () async {
      await partial([0, 0, 0]);
      respond((response, _) => reply(response));
      expect(await (await download()).readAsBytes(), content);
      expect(ranges, ['bytes=3-']);
    },
  );

  test(
    'corrupt resumed bytes trigger one clean retry of the same object',
    () async {
      await partial([0, 0, 0]);
      final received = <int>[];
      respond(
        (response, index) => index == 0
            ? reply(
                response,
                status: HttpStatus.partialContent,
                range: 'bytes 3-7/8',
                bytes: content.sublist(3),
              )
            : reply(response),
      );
      expect(
        await (await download(onProgress: (bytes, _) => received.add(bytes)))
            .readAsBytes(),
        content,
      );
      expect(ranges, ['bytes=3-', null]);
      expect(received, contains(0));
      expect(received.last, content.length);
    },
  );

  test(
    'persistent corruption never replaces a cache file or retries a third time',
    () async {
      await cached.writeAsBytes([0]);
      respond(
        (response, _) => reply(response, bytes: List.filled(content.length, 0)),
      );
      await expectLater(download(), throwsFormatException);
      expect(ranges, [null, null]);
      expect(await cached.readAsBytes(), [0]);
      expect(await part.exists(), isFalse);
      expect(await tag.exists(), isFalse);
    },
  );

  test(
    'a dropped response preserves bytes and resumes on the next download',
    () async {
      respond((response, index) async {
        if (index == 0) {
          final socket = await response.detachSocket(writeHeaders: false);
          socket.write(
            'HTTP/1.1 200 OK\r\nContent-Length: 8\r\nETag: $etag\r\n'
            'Connection: close\r\n\r\n',
          );
          socket.add(content.sublist(0, 3));
          await socket.flush();
          await socket.close();
        } else {
          await reply(
            response,
            status: HttpStatus.partialContent,
            range: 'bytes 3-7/8',
            bytes: content.sublist(3),
          );
        }
      });
      await expectLater(download(), throwsA(isA<HttpException>()));
      expect(await part.readAsBytes(), content.sublist(0, 3));
      expect(await tag.readAsString(), etag);
      expect(await (await download()).readAsBytes(), content);
      expect(ranges, [null, 'bytes=3-']);
    },
  );

  for (final status in [HttpStatus.notFound, HttpStatus.gone]) {
    test(
      '$status identifies a missing object without retrying the URL',
      () async {
        respond((response, _) => reply(response, status: status, bytes: []));
        await expectLater(download(), throwsA(isA<UpdateObjectUnavailable>()));
        expect(ranges, [null]);
      },
    );
  }

  test(
    'a verified partial is committed over a bad old cache without HTTP',
    () async {
      await cached.writeAsBytes([0]);
      await partial(content);
      respond((response, _) => reply(response));
      expect(await (await download()).readAsBytes(), content);
      expect(ranges, isEmpty);
      expect(await part.exists(), isFalse);
    },
  );

  for (final fromCache in [false, true]) {
    test('raw APK stages without a second copy (cached: $fromCache)', () async {
      final apks = await Directory(p.join(work.path, 'apks')).create();
      final output = File(p.join(apks.path, '$digest.apk'));
      await output.writeAsBytes([0]);
      if (fromCache) await cached.writeAsBytes(content);
      respond((response, _) => reply(response));
      expect((await download(destination: output)).path, output.path);
      expect(await output.readAsBytes(), content);
      expect(ranges, fromCache ? isEmpty : [null]);
      expect(await cached.exists(), isFalse);
      expect(await part.exists(), isFalse);
    });
  }
}
