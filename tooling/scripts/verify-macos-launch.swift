import AppKit
import CoreGraphics
import Darwin

private struct LaunchFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

@main
struct VerifyMacOSLaunch {
  @MainActor
  static func main() async {
    do {
      try await verify()
    } catch {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }

  @MainActor
  private static func verify() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard (1...2).contains(arguments.count) else {
      throw LaunchFailure(message: "Usage: verify-launch /path/to/WeekGlass.app [/path/to/screenshot.png]")
    }
    let url = URL(fileURLWithPath: arguments[0]).resolvingSymlinksInPath().standardizedFileURL
    guard let identifier = Bundle(url: url)?.bundleIdentifier else {
      throw LaunchFailure(message: "The candidate bundle has no identifier.")
    }
    guard NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty else {
      throw LaunchFailure(message: "WeekGlass is running. Use a clean macOS login with WeekGlass closed.")
    }

    let options = NSWorkspace.OpenConfiguration()
    options.createsNewApplicationInstance = true
    let app = try await NSWorkspace.shared.openApplication(at: url, configuration: options)
    defer {
      if !app.isTerminated { _ = app.forceTerminate() }
    }
    guard app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == url.path else {
      throw LaunchFailure(message: "LaunchServices opened a different bundle: \(app.bundleURL?.path ?? "unknown").")
    }

    var window: (id: CGWindowID, bounds: CGRect)?
    let deadline = ProcessInfo.processInfo.systemUptime + 30
    while !app.isTerminated && ProcessInfo.processInfo.systemUptime < deadline {
      if app.isFinishedLaunching { window = visibleWindow(pid: app.processIdentifier) }
      if window != nil { break }
      try await Task.sleep(nanoseconds: 250_000_000)
    }
    guard let window, !app.isTerminated else {
      throw LaunchFailure(message: app.isTerminated ?
        "The candidate quit before showing a window." :
        "The candidate did not show an on-screen window of at least 800 × 560 within 30 seconds.")
    }
    print("LaunchServices opened WeekGlass with a native window (\(Int(window.bounds.width)) × \(Int(window.bounds.height))): \(url.path)")

    if arguments.count == 2 {
      // The AppKit window exists before its Flutter content has painted.
      try await Task.sleep(nanoseconds: 3_000_000_000)
      guard !app.isTerminated, let currentWindow = visibleWindow(pid: app.processIdentifier) else {
        throw LaunchFailure(message: "The candidate window disappeared before capture.")
      }
      let output = URL(fileURLWithPath: arguments[1])
      let capture = Process()
      capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      capture.arguments = ["-x", "-o", "-l", String(currentWindow.id), output.path]
      try capture.run()
      capture.waitUntilExit()
      let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
      guard capture.terminationStatus == 0,
            let bytes = try? Data(contentsOf: output), bytes.count > pngSignature.count,
            bytes.starts(with: pngSignature) else {
        throw LaunchFailure(message: "Capturing the visible WeekGlass window failed.")
      }
      print("Saved the native window screenshot: \(output.path)")
    }

    _ = app.terminate()
    let quitDeadline = ProcessInfo.processInfo.systemUptime + 5
    while !app.isTerminated && ProcessInfo.processInfo.systemUptime < quitDeadline {
      try await Task.sleep(nanoseconds: 250_000_000)
    }
  }

  private static func visibleWindow(pid: pid_t) -> (id: CGWindowID, bounds: CGRect)? {
    let windows = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] ?? []
    return windows.lazy.compactMap { info -> (id: CGWindowID, bounds: CGRect)? in
      guard info[kCGWindowOwnerPID as String] as? Int32 == pid,
            info[kCGWindowLayer as String] as? Int == 0,
            let id = info[kCGWindowNumber as String] as? UInt32,
            let bounds = info[kCGWindowBounds as String] as? NSDictionary,
            let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
            rect.width >= 800, rect.height >= 560 else { return nil }
      return (id, rect)
    }.first
  }
}
