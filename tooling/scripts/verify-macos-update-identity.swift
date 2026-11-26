import Darwin
import Foundation
import Security

#if PROBE_V1
let build = "1"
#elseif PROBE_V2
let build = "2"
#else
#error("Set a probe build number")
#endif

func report(_ message: String) {
  FileHandle.standardOutput.write(Data("\(message)\n".utf8))
}

func describe(_ status: OSStatus) -> String {
  let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
  return "\(status) (\(message))"
}

let args = CommandLine.arguments
guard args.count == 3, let identifier = Bundle.main.bundleIdentifier,
      identifier == args[2], identifier.hasPrefix("com.viliana.weekglass.identity-test."),
      Bundle.main.infoDictionary?["CFBundleVersion"] as? String == build else {
  report("Unexpected test bundle identity or version")
  exit(2)
}
let mode = args[1]
report("Started bundle \(build) in \(mode) mode")

let manager = FileManager.default
let home = manager.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
guard home.path.hasSuffix("/Library/Containers/\(identifier)/Data") else {
  report("Sandbox home: unexpected path \(home.path)")
  exit(2)
}
report("Sandbox home: present")

let fixture = home.appendingPathComponent("Library/Application Support/UpgradeProbe")
let marker = fixture.appendingPathComponent("schedule.json")
let schedule = Data(#"{"day":3,"period":5,"title":"Synthetic test schedule"}"#.utf8)
let preferences = UserDefaults.standard
let preferenceKey = "UpgradeProbeTheme"
let theme = "light"
let password = Data("synthetic-test-session".utf8)
let query: [String: Any] = [
  kSecClass as String: kSecClassGenericPassword,
  kSecAttrService as String: identifier,
  kSecAttrAccount as String: "synthetic-session",
  kSecAttrSynchronizable as String: false,
  kSecUseDataProtectionKeychain as String: false,
]

// Process-local control: report when Keychain would need interaction instead
// of displaying an alert in CI. The fixture retains the normal item ACL.
let uiStatus = SecKeychainSetUserInteractionAllowed(false)
guard uiStatus == errSecSuccess else {
  report("Keychain interaction mode: \(describe(uiStatus))")
  exit(2)
}

var fileOK = false
var prefsOK = false
var keychainOK = false
switch mode {
case "write":
  do {
    try manager.createDirectory(at: fixture, withIntermediateDirectories: true)
    try schedule.write(to: marker, options: .atomic)
    fileOK = true
    report("Application Support: wrote schedule")
  } catch {
    report("Application Support write: \(error)")
  }
  preferences.set(theme, forKey: preferenceKey)
  prefsOK = preferences.synchronize()
  report("Preferences write: \(prefsOK ? "saved" : "failed")")
  var item = query
  item[kSecValueData as String] = password
  item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
  let status = SecItemAdd(item as CFDictionary, nil)
  keychainOK = status == errSecSuccess
  report("File based Keychain write: \(describe(status))")
case "read":
  do {
    fileOK = try Data(contentsOf: marker) == schedule
    report("Application Support read: \(fileOK ? "matched" : "value mismatch")")
  } catch {
    report("Application Support read: \(error)")
  }
  prefsOK = preferences.string(forKey: preferenceKey) == theme
  report("Preferences read: \(prefsOK ? "matched" : "missing or different value")")
  var item = query
  item[kSecReturnData as String] = true
  item[kSecMatchLimit as String] = kSecMatchLimitOne
  var result: CFTypeRef?
  let status = SecItemCopyMatching(item as CFDictionary, &result)
  keychainOK = status == errSecSuccess && (result as? Data) == password
  let outcome = status == errSecSuccess ? (keychainOK ? "matched" : "value mismatch") : describe(status)
  report("File based Keychain read: \(outcome)")
case "cleanup":
  do {
    if manager.fileExists(atPath: fixture.path) { try manager.removeItem(at: fixture) }
    fileOK = true
  } catch {
    report("Application Support cleanup: \(error)")
  }
  preferences.removeObject(forKey: preferenceKey)
  prefsOK = preferences.synchronize()
  let status = SecItemDelete(query as CFDictionary)
  keychainOK = status == errSecSuccess || status == errSecItemNotFound
  report("File based Keychain cleanup: \(describe(status))")
default:
  report("Unknown test mode")
  exit(2)
}
exit(fileOK && prefsOK && keychainOK ? 0 : 1)
