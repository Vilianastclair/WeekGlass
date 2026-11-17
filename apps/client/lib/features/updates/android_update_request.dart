/// A local receipt for the one signed update the user requested.
///
/// The first two lines are shared with the Android download receiver and
/// preserve receipts written by older versions. A receipt is not authority to
/// install: the signed metadata, APK and signer are still checked separately.
class AndroidUpdateRequest {
  const AndroidUpdateRequest({
    required this.manifestHash,
    this.objectHash,
    this.build,
    this.apkHash,
    this.handedOff = false,
  });

  static final _hash = RegExp(r'^[a-f0-9]{64}$');

  final String manifestHash;
  final String? objectHash;
  final int? build;
  final String? apkHash;
  final bool handedOff;

  static AndroidUpdateRequest parse(String value) {
    final lines = value.split('\n');
    if ((lines.length != 2 && lines.length != 5) ||
        !_hash.hasMatch(lines[0]) ||
        (lines[1].isNotEmpty && !_hash.hasMatch(lines[1]))) {
      throw const FormatException('更新任务记录无效');
    }
    final objectHash = lines[1].isEmpty ? null : lines[1];
    if (lines.length == 2) {
      return AndroidUpdateRequest(
        manifestHash: lines[0],
        objectHash: objectHash,
      );
    }
    final build = int.tryParse(lines[2]);
    if (build == null ||
        build < 1 ||
        !_hash.hasMatch(lines[3]) ||
        (lines[4] != '0' && lines[4] != '1')) {
      throw const FormatException('更新任务记录无效');
    }
    return AndroidUpdateRequest(
      manifestHash: lines[0],
      objectHash: objectHash,
      build: build,
      apkHash: lines[3],
      handedOff: lines[4] == '1',
    );
  }

  AndroidUpdateRequest forArtifact(int targetBuild, String targetHash) =>
      AndroidUpdateRequest(
        manifestHash: manifestHash,
        objectHash: objectHash,
        build: targetBuild,
        apkHash: targetHash,
        handedOff: handedOff,
      );

  AndroidUpdateRequest copyWith({String? objectHash, bool? handedOff}) =>
      AndroidUpdateRequest(
        manifestHash: manifestHash,
        objectHash: objectHash ?? this.objectHash,
        build: build,
        apkHash: apkHash,
        handedOff: handedOff ?? this.handedOff,
      );

  String encode() =>
      '$manifestHash\n${objectHash ?? ''}\n$build\n$apkHash\n${handedOff ? 1 : 0}';
}
