import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

const updateOrigin = 'https://cloud.viliana.cn/updates/v1/';
// Build-time override is only used by the isolated installer smoke harness.
// Runtime cloud settings never select this key or the update origin.
const updatePublicKey = String.fromEnvironment(
  'WEEKGLASS_UPDATE_PUBLIC_KEY',
  defaultValue: 'vukSlMLxWC+lZjX2higLCnPrgI1u9+Y5DIa6cS7PDLE=',
);
const maximumUpdateFile = 256 * 1024 * 1024;
final _sha = RegExp(r'^[a-f0-9]{64}$');

typedef _AllocNative = Pointer<Void> Function(IntPtr, IntPtr);
typedef _AllocDart = Pointer<Void> Function(int, int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);
typedef _AttrsNative = Uint32 Function(Pointer<Uint16>);
typedef _AttrsDart = int Function(Pointer<Uint16>);

bool isUpdateLink(String path) {
  if (!Platform.isWindows) return FileSystemEntity.isLinkSync(path);
  final runtime = DynamicLibrary.open('msvcrt.dll');
  final alloc = runtime.lookupFunction<_AllocNative, _AllocDart>('calloc');
  final free = runtime.lookupFunction<_FreeNative, _FreeDart>('free');
  final attrs = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<_AttrsNative, _AttrsDart>('GetFileAttributesW');
  final units = p.absolute(path).codeUnits;
  final buffer = alloc(units.length + 1, 2).cast<Uint16>();
  if (buffer.address == 0) throw const FileSystemException('无法检查更新路径');
  try {
    buffer.asTypedList(units.length + 1).setRange(0, units.length, units);
    final attributes = attrs(buffer);
    return attributes != 0xffffffff && attributes & 0x400 != 0;
  } finally {
    free(buffer.cast());
  }
}

String sha256(List<int> bytes) => hash.sha256.convert(bytes).toString();
Future<String> fileSha256(File file) async =>
    (await hash.sha256.bind(file.openRead()).first).toString();

String safeUpdatePath(String value) {
  final reserved = RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
    caseSensitive: false,
  );
  if (value.isEmpty ||
      value.length > 240 ||
      value.contains(RegExp(r'[\\:<>"|?*\x00-\x1f]')) ||
      value
          .split('/')
          .any(
            (s) =>
                s.isEmpty ||
                s == '.' ||
                s == '..' ||
                s.endsWith('.') ||
                s.endsWith(' ') ||
                reserved.hasMatch(s),
          )) {
    throw const FormatException('更新文件路径无效');
  }
  return value;
}

Future<File> updateChild(Directory root, String relative) async {
  safeUpdatePath(relative);
  var path = root.absolute.path;
  if (isUpdateLink(path)) {
    throw const FormatException('更新目录不能是链接');
  }
  for (final segment in relative.split('/')) {
    path = p.join(path, segment);
    if (isUpdateLink(path)) {
      throw const FormatException('更新文件不能经过链接');
    }
  }
  if (!p.isWithin(root.absolute.path, p.absolute(path))) {
    throw const FormatException('更新路径越界');
  }
  return File(path);
}

Future<Map<String, dynamic>> verifyUpdateEnvelope(
  List<int> bytes, {
  required bool channel,
  required int floor,
  String platform = 'windows-x64',
  DateTime? clock,
}) async {
  if (bytes.length > (channel ? 16384 : 4194304)) {
    throw const FormatException('更新清单过大');
  }
  final outer = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  final public = base64Decode(updatePublicKey);
  if (outer['format'] != 1 || outer['key_id'] != sha256(public)) {
    throw const FormatException('更新签名来源不可信');
  }
  final raw = base64Decode(outer['signed'] as String);
  final signature = Signature(
    base64Decode(outer['signature'] as String),
    publicKey: SimplePublicKey(public, type: KeyPairType.ed25519),
  );
  if (!await Ed25519().verify(raw, signature: signature)) {
    throw const FormatException('更新签名校验失败');
  }
  final data = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
  validateUpdatePayload(
    data,
    channel: channel,
    floor: floor,
    platform: platform,
    clock: clock,
  );
  return data;
}

/// Validates the payload only. Call [verifyUpdateEnvelope] for untrusted bytes.
void validateUpdatePayload(
  Map<String, dynamic> data, {
  required bool channel,
  required int floor,
  String platform = 'windows-x64',
  DateTime? clock,
}) {
  final now = (clock ?? DateTime.now()).toUtc();
  final generated = DateTime.parse(data['generated_at'] as String).toUtc();
  final expires = DateTime.parse(data['expires_at'] as String).toUtc();
  if (data['schema'] != 1 ||
      data['product'] != 'weekglass' ||
      !const ['windows-x64', 'android-arm64'].contains(platform) ||
      data['platform'] != platform ||
      data['channel'] != 'stable' ||
      data['version'] is! String ||
      (data['version'] as String).isEmpty ||
      data['build'] is! int ||
      (data['build'] as int) < floor ||
      (data['build'] as int) < 1 ||
      generated.isAfter(now.add(const Duration(minutes: 5))) ||
      !expires.isAfter(now) ||
      expires.isAfter(generated.add(Duration(days: channel ? 7 : 31)))) {
    throw const FormatException('更新信息已过期、版本回退或平台不匹配');
  }
  if (channel) {
    final descriptor = data['manifest'] as Map<String, dynamic>;
    if (data['kind'] != 'weekglass-channel' ||
        !_sha.hasMatch(descriptor['sha256'] as String) ||
        descriptor['size'] is! int ||
        (descriptor['size'] as int) < 1 ||
        (descriptor['size'] as int) > 4194304 ||
        descriptor['path'] !=
            'manifests/$platform/stable/${data['build']}/${descriptor['sha256']}.json') {
      throw const FormatException('更新清单引用无效');
    }
  } else {
    if (data['min_updater'] != 1) throw const FormatException('需要更新安装器');
    final entries = (data['files'] as List).cast<Map<String, dynamic>>();
    if (entries.isEmpty || entries.length > 5000) {
      throw const FormatException('更新文件数量无效');
    }
    final names = <String>{};
    var total = 0;
    for (final entry in entries) {
      final name = safeUpdatePath(entry['path'] as String).toLowerCase();
      if (names.any(
        (s) => s == name || s.startsWith('$name/') || name.startsWith('$s/'),
      )) {
        throw const FormatException('更新路径冲突');
      }
      names.add(name);
      checkSizeHash(entry);
      total += entry['size'] as int;
      final full = entry['full'] as Map<String, dynamic>;
      checkSizeHash(full);
      if (!['raw', 'zlib'].contains(full['encoding'])) {
        throw const FormatException('未知更新格式');
      }
      final patches = (entry['patches'] as List).cast<Map<String, dynamic>>();
      if (patches.length > 3) throw const FormatException('差分来源过多');
      for (final patch in patches) {
        checkSizeHash(patch);
        if (patch['encoding'] != 'bsdiff4' ||
            !_sha.hasMatch(patch['base_sha256'] as String) ||
            patch['base_size'] is! int ||
            (patch['base_size'] as int) < 0 ||
            (patch['base_size'] as int) > maximumUpdateFile) {
          throw const FormatException('差分来源无效');
        }
      }
    }
    if (platform == 'android-arm64') {
      final apk = entries.singleOrNull;
      final full = apk?['full'] as Map<String, dynamic>?;
      if (apk == null ||
          apk['path'] != 'weekglass.apk' ||
          apk['size'] == 0 ||
          full!['encoding'] != 'raw' ||
          full['size'] != apk['size'] ||
          full['sha256'] != apk['sha256']) {
        throw const FormatException('Android 更新必须是完整可验证的 APK');
      }
    } else if (total > 2147483648 ||
        !names.contains('weekglass.exe') ||
        !names.contains('weekglass_updater.exe')) {
      throw const FormatException('更新内容不完整或过大');
    }
  }
}

/// Selects a patch only when its exact installed base matches and it saves bytes.
Map<String, dynamic> smallestUpdateObject(
  Map<String, dynamic> entry, {
  String? baseSha256,
  int? baseSize,
}) {
  var selected = entry['full'] as Map<String, dynamic>;
  for (final patch in (entry['patches'] as List).cast<Map<String, dynamic>>()) {
    if (patch['base_sha256'] == baseSha256 &&
        patch['base_size'] == baseSize &&
        (patch['size'] as int) < (selected['size'] as int)) {
      selected = patch;
    }
  }
  return selected;
}

void checkSizeHash(Map<String, dynamic> item) {
  if (item['size'] is! int ||
      (item['size'] as int) < 0 ||
      (item['size'] as int) > maximumUpdateFile ||
      item['sha256'] is! String ||
      !_sha.hasMatch(item['sha256'] as String)) {
    throw const FormatException('更新文件长度或校验值无效');
  }
}

int _signed64(List<int> bytes, int offset) {
  var value = bytes[offset + 7] & 127;
  for (var i = 6; i >= 0; i--) {
    value = value * 256 + bytes[offset + i];
  }
  return bytes[offset + 7] & 128 != 0 ? -value : value;
}

Uint8List applyBsdiff(List<int> source, List<int> patch, int expectedSize) {
  if (patch.length < 32 ||
      ascii.decode(patch.sublist(0, 8), allowInvalid: true) != 'BSDIFF40') {
    throw const FormatException('差分头无效');
  }
  final controlSize = _signed64(patch, 8),
      diffSize = _signed64(patch, 16),
      targetSize = _signed64(patch, 24);
  if (controlSize < 0 ||
      diffSize < 0 ||
      targetSize != expectedSize ||
      expectedSize > maximumUpdateFile ||
      32 + controlSize + diffSize > patch.length) {
    throw const FormatException('差分长度无效');
  }
  final control = BZip2Decoder().decodeBytes(
    patch.sublist(32, 32 + controlSize),
    verify: true,
    maxOutputSize: (expectedSize + 1) * 24 < 8388608
        ? (expectedSize + 1) * 24
        : 8388608,
  );
  final diff = BZip2Decoder().decodeBytes(
    patch.sublist(32 + controlSize, 32 + controlSize + diffSize),
    verify: true,
    maxOutputSize: expectedSize,
  );
  final extra = BZip2Decoder().decodeBytes(
    patch.sublist(32 + controlSize + diffSize),
    verify: true,
    maxOutputSize: expectedSize,
  );
  if (control.length % 24 != 0) throw const FormatException('差分控制段无效');
  var old = 0, next = 0, d = 0, e = 0;
  final output = Uint8List(expectedSize);
  for (var i = 0; i < control.length; i += 24) {
    final x = _signed64(control, i),
        y = _signed64(control, i + 8),
        z = _signed64(control, i + 16);
    if (x < 0 ||
        y < 0 ||
        next + x + y > expectedSize ||
        d + x > diff.length ||
        e + y > extra.length) {
      throw const FormatException('差分数据越界');
    }
    for (var j = 0; j < x; j++) {
      output[next + j] =
          (diff[d + j] +
              (old + j >= 0 && old + j < source.length ? source[old + j] : 0)) &
          255;
    }
    next += x;
    old += x;
    d += x;
    output.setRange(next, next + y, extra, e);
    next += y;
    e += y;
    old += z;
  }
  if (next != expectedSize || d != diff.length || e != extra.length) {
    throw const FormatException('差分输出不完整');
  }
  return output;
}

List<int> decodeUpdateObject(
  List<int> bytes,
  String encoding,
  int expected, [
  List<int>? source,
]) {
  final List<int> output;
  if (encoding == 'raw') {
    output = bytes;
  } else if (encoding == 'zlib') {
    output = ZLibDecoder().decodeBytes(
      bytes,
      verify: true,
      maxOutputSize: expected,
    );
  } else if (encoding == 'bsdiff4' && source != null) {
    output = applyBsdiff(source, bytes, expected);
  } else {
    throw const FormatException('不支持的更新格式');
  }
  if (output.length != expected) throw const FormatException('更新展开长度不匹配');
  return output;
}

Future<void> verifyStagedUpdate(
  Directory directory,
  Map<String, dynamic> manifest,
) async {
  final expected = <String>{};
  for (final entry
      in (manifest['files'] as List).cast<Map<String, dynamic>>()) {
    final file = await updateChild(directory, entry['path'] as String);
    expected.add(p.normalize(file.absolute.path).toLowerCase());
    if (!await file.exists() ||
        await file.length() != entry['size'] ||
        await fileSha256(file) != entry['sha256']) {
      throw const FormatException('安装前文件校验失败');
    }
  }
  await for (final entity in directory.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is Link ||
        isUpdateLink(entity.path) ||
        (entity is File &&
            !expected.contains(
              p.normalize(entity.absolute.path).toLowerCase(),
            ))) {
      throw const FormatException('安装目录包含未签名内容');
    }
  }
}
