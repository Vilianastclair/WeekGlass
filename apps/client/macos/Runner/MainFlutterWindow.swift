import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    var launchFrame = frame
    contentViewController = flutterViewController
    contentMinSize = NSSize(width: 800, height: 560)
    if let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame {
      launchFrame.size.width = min(launchFrame.width, visibleFrame.width)
      launchFrame.size.height = min(launchFrame.height, visibleFrame.height)
    }
    setFrame(launchFrame, display: true)
    center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
