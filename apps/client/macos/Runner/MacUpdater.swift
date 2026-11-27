import Cocoa
import FlutterMacOS
import Sparkle

/// Sparkle owns the download, verification, replacement and relaunch. Flutter
/// owns the editor and commits its pending work before yielding to Sparkle.
@MainActor
final class MacUpdater: NSObject, SPUUpdaterDelegate {
  private let channel: FlutterMethodChannel
  private var engine: SPUUpdater?
  private var presentPreparedUpdate = false
  private var pendingRelaunch: (() -> Void)?
  private var preparing = false
  private var sealed = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "weekglass/macos_updates", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(FlutterMethodNotImplemented) }
      switch call.method {
      case "bundle":
        result(["id": Bundle.main.bundleIdentifier ?? "", "version": self.info("CFBundleShortVersionString"),
                "build": self.info("CFBundleVersion")])
      case "start", "check":
        do {
          if let pending = self.pendingRelaunch {
            if !self.preparing { self.prepareAndRelaunch(pending) }
          } else {
            let updater = try self.updater()
            if call.method == "check" {
              if updater.canCheckForUpdates { updater.checkForUpdates() }
            } else if updater.automaticallyChecksForUpdates && !updater.sessionInProgress {
              updater.checkForUpdatesInBackground()
            }
          }
          result(nil)
        } catch {
          result(FlutterError(code: "mac_update", message: error.localizedDescription, details: nil))
        }
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func info(_ key: String) -> String {
    Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
  }

  private func acceptsURL(_ url: URL) -> Bool {
    guard url.user == nil, url.password == nil, let host = url.host, !host.isEmpty else { return false }
    if url.scheme == "https" { return true }
    // Only the isolated integration application can consume a local test feed.
    return Bundle.main.bundleIdentifier == "com.viliana.weekglass.updatesmoke" &&
      url.scheme == "http" && host == "127.0.0.1" && url.port == 18765
  }

  private func updater() throws -> SPUUpdater {
    if let engine = engine { return engine }
    guard let url = URL(string: info("SUFeedURL")), acceptsURL(url),
          Data(base64Encoded: info("SUPublicEDKey"))?.count == 32 else {
      throw failure("此构建未配置 macOS 更新地址或公钥。")
    }
    let driver = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
    let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
    try updater.start()
    engine = updater
    return updater
  }

  func feedURLString(for updater: SPUUpdater) -> String? { info("SUFeedURL") }

  func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem,
               updateCheck: SPUUpdateCheck) throws {
    func version(_ text: String) -> [UInt64]? {
      let fields = text.split(separator: ".", omittingEmptySubsequences: false)
      let values = fields.compactMap { field -> UInt64? in
        guard !field.isEmpty, field.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return UInt64(field)
      }
      return fields.count == 3 && values.count == 3 ? values : nil
    }
    guard !item.isInformationOnlyUpdate, item.installationType == "application",
          let url = item.fileURL, acceptsURL(url),
          let current = version(info("CFBundleShortVersionString")), let next = version(item.displayVersionString),
          current.lexicographicallyPrecedes(next),
          let oldBuild = UInt64(info("CFBundleVersion")), let newBuild = UInt64(item.versionString),
          newBuild > oldBuild else {
      throw failure("更新包类型、地址、版本或构建号不符合要求。")
    }
  }

  func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
               immediateInstallationBlock install: @escaping () -> Void) -> Bool {
    // Release the automatic driver first. Sparkle keeps the prepared installer
    // and its standard UI can offer Install and Relaunch or Install on Quit.
    // Sparkle already presents critical updates immediately.
    presentPreparedUpdate = !item.isCriticalUpdate
    return false
  }

  func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
               error: Error?) {
    guard presentPreparedUpdate else { return }
    presentPreparedUpdate = false
    if error == nil && updater.canCheckForUpdates { updater.checkForUpdates() }
  }

  func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
               untilInvokingBlock install: @escaping () -> Void) -> Bool {
    prepareAndRelaunch(install)
    return true
  }

  private func prepareAndRelaunch(_ install: @escaping () -> Void) {
    pendingRelaunch = install
    preparing = true
    channel.invokeMethod("prepareRelaunch", arguments: nil) { [weak self] reply in
      guard let self = self else { return }
      self.preparing = false
      guard reply as? Bool == true, self.pendingRelaunch != nil else { return }
      self.pendingRelaunch = nil
      self.sealed = true
      install()
    }
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
    pendingRelaunch = nil
    let resume = sealed
    sealed = false
    channel.invokeMethod("finished", arguments: ["message": error.localizedDescription, "resume": resume])
  }

  private func failure(_ message: String) -> NSError {
    NSError(domain: "com.viliana.weekglass.updates", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
