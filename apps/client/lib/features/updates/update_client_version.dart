/// Release routing hints only: never a device, account or installation ID.
class UpdateClientVersion {
  UpdateClientVersion(this.version, this.build) {
    if (!RegExp(r'^[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}$').hasMatch(version) ||
        build < 1) {
      throw const FormatException('无法读取有效的当前版本');
    }
  }

  final String version;
  final int build;
  Map<String, String> get headers => {
    'X-WeekGlass-Version': version,
    'X-WeekGlass-Build': '$build',
  };
}
