import Cocoa
import FlutterMacOS
import UserNotifications

@main
class AppDelegate: FlutterAppDelegate, UNUserNotificationCenterDelegate {
  private var statusItem: NSStatusItem?
  private var desktop: FlutterMethodChannel?
  private var macUpdater: MacUpdater?
  private var remindersReady = false
  private var pendingEvent: String?

  override func applicationWillFinishLaunching(_ notification: Notification) {
    super.applicationWillFinishLaunching(notification)
    UNUserNotificationCenter.current().delegate = self
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController else {
      return
    }
    let messenger = controller.engine.binaryMessenger
    let channel = FlutterMethodChannel(name: "weekglass/desktop", binaryMessenger: messenger)
    desktop = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(FlutterMethodNotImplemented) }
      switch call.method {
      case "notify":
        guard let fields = call.arguments as? [String: String],
              let title = fields["title"], let body = fields["body"] else {
          return result(FlutterError(code: "invalid_notice", message: nil, details: nil))
        }
        self.notify(title: title, body: body, eventID: fields["eventId"] ?? "", result: result)
      case "showPlanner":
        self.showPlanner()
        result(nil)
      case "remindersReady":
        self.remindersReady = true
        if let id = self.pendingEvent {
          self.pendingEvent = nil
          channel.invokeMethod("openEvent", arguments: id)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    TimetableOCR.register(with: messenger)
    macUpdater = MacUpdater(messenger: messenger)
    WGRegisterAccountBroker(messenger)

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "WeekGlass")
    item.button?.toolTip = "WeekGlass 周计划"
    let menu = NSMenu()
    menu.addItem(withTitle: "显示周计划", action: #selector(showPlanner), keyEquivalent: "").target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "退出 WeekGlass", action: #selector(NSApplication.terminate(_:)),
                 keyEquivalent: "").target = NSApp
    item.menu = menu
    statusItem = item
  }

  @objc private func showPlanner() {
    guard let window = mainFlutterWindow else { return }
    if window.isMiniaturized { window.deminiaturize(nil) }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showPlanner()
    return false
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  private func notify(title: String, body: String, eventID: String, result: @escaping FlutterResult) {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { allowed, error in
      guard allowed, error == nil else {
        DispatchQueue.main.async {
          result(FlutterError(code: "notifications_disabled", message: nil, details: nil))
        }
        return
      }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      content.sound = .default
      content.userInfo = ["eventId": eventID]
      center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
        DispatchQueue.main.async { result(error == nil) }
      }
    }
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                              withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
    completion([.banner, .list, .sound])
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                              withCompletionHandler completion: @escaping () -> Void) {
    let id = response.notification.request.content.userInfo["eventId"] as? String
    DispatchQueue.main.async {
      self.showPlanner()
      if let id = id, !id.isEmpty {
        if self.remindersReady {
          self.desktop?.invokeMethod("openEvent", arguments: id)
        } else {
          self.pendingEvent = id
        }
      }
      completion()
    }
  }
}
