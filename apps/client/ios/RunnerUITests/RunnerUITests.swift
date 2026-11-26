import Vision
import XCTest

final class RunnerUITests: XCTestCase {
  private func attachScreen(_ name: String, of app: XCUIApplication) {
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
  }

  override func tearDownWithError() throws {
    if let result = testRun, result.failureCount > 0 {
      let tree = XCTAttachment(string: XCUIApplication().debugDescription)
      tree.name = "发生故障时的控件"
      tree.lifetime = .keepAlways
      add(tree)
      let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      screen.name = "发生故障时的屏幕"
      screen.lifetime = .keepAlways
      add(screen)
    }
    try super.tearDownWithError()
  }

  private func checkWeek(_ app: XCUIApplication) {
    let week = app.buttons["整周"]
    XCTAssertTrue(week.waitForExistence(timeout: 30))
    XCTAssertTrue(week.isSelected)
    XCTAssertTrue(app.buttons["新建日程"].exists)
  }

  private func relaunch(_ app: XCUIApplication) {
    app.terminate()
    app.launch()
    checkWeek(app)
  }

  private func card(_ title: String, in app: XCUIApplication) -> XCUIElement {
    return app.buttons.matching(NSPredicate(
      format: "label BEGINSWITH %@ AND label CONTAINS %@ AND label CONTAINS %@",
      title + "，", "09:00", "10:00"
    )).firstMatch
  }

  private func openDetails(_ title: String, on day: String, in app: XCUIApplication) {
    let event = card(title, in: app)
    XCTAssertTrue(event.waitForExistence(timeout: 10))
    XCTAssertTrue(event.isHittable)
    event.tap()
    // Flutter exposes the title, date and time as one accessible reading group.
    let detail = app.descendants(matching: .any).matching(NSPredicate(
      format: "label BEGINSWITH %@ AND label CONTAINS %@ AND label ENDSWITH %@",
      title + "\n", day, "09:00 — 10:00"
    )).firstMatch
    XCTAssertTrue(detail.waitForExistence(timeout: 10), "Details must show the title, day and both times")
  }

  private func control(_ label: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
  }

  private func openFileAction(_ label: String, in app: XCUIApplication) {
    app.buttons["更多快捷操作"].tap()
    let action = control(label, in: app)
    XCTAssertTrue(action.waitForExistence(timeout: 10))
    action.tap()
  }

  // Files is a remote system view. Some simulator/XCTest pairs expose its
  // controls only on screen, outside the tested app's accessibility tree.
  private func filesControl(
    _ text: String, app: XCUIApplication, timeout: TimeInterval = 8,
    isDocument: Bool = false
  ) throws -> XCUICoordinate? {
    let end = Date().addingTimeInterval(timeout)
    var observed: [String] = []
    repeat {
      let predicate = NSPredicate(format: isDocument ? "label BEGINSWITH %@" : "label == %@", text)
      let element = app.descendants(matching: .any).matching(predicate).firstMatch
      if element.exists && element.isHittable {
        return element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      }
      let screen = XCUIScreen.main.screenshot()
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.recognitionLanguages = ["en-US"]
      request.usesLanguageCorrection = false
      try VNImageRequestHandler(data: screen.pngRepresentation, options: [:]).perform([request])
      observed = []
      for item in request.results ?? [] {
        guard let candidate = item.topCandidates(1).first else { continue }
        let line = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
        observed.append(line)
        let word = line.lowercased().filter { $0.isLetter || $0.isNumber }
        let target = text.lowercased().filter { $0.isLetter || $0.isNumber }
        // Files may wrap a basename in grid view or hide its extension.
        let matches = isDocument
          ? (word.hasPrefix(target) || word == String(target.suffix(8)) ||
             (word.hasPrefix("weekglass") && target.hasPrefix(word)))
          : word == target
        if matches {
          let box = item.boundingBox
          return app.coordinate(withNormalizedOffset: CGVector(dx: box.midX, dy: 1 - box.midY))
        }
      }
      Thread.sleep(forTimeInterval: 0.4)
    } while Date() < end
    print("Files could not locate \(text); visible labels: \(observed)")
    return nil
  }

  private func exportJSON(in app: XCUIApplication) throws {
    openFileAction("导出日程", in: app)
    control("JSON", in: app).tap()
    app.buttons["导出"].tap()
    let save = try XCTUnwrap(try filesControl("Save", app: app, timeout: 20))
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "在文件中保存 JSON"
    shot.lifetime = .keepAlways
    add(shot)
    save.tap()
    checkWeek(app)
  }

  private func importJSON(named base: String, in app: XCUIApplication) throws {
    openFileAction("导入日程", in: app)
    app.buttons["选择文件并导入"].tap()
    var file = try filesControl(base, app: app, isDocument: true)
    if file == nil {
      if let browse = try filesControl("Browse", app: app, timeout: 2) { browse.tap() }
      if let downloads = try filesControl("Downloads", app: app, timeout: 3) {
        downloads.tap()
      } else if let local = try filesControl("On My iPhone", app: app, timeout: 3) {
        local.tap()
        if let downloads = try filesControl("Downloads", app: app) { downloads.tap() }
      }
      file = try filesControl(base, app: app, isDocument: true)
    }
    let document = try XCTUnwrap(file, "The exported JSON must be visible in Files")
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "在文件中选择 JSON"
    shot.lifetime = .keepAlways
    add(shot)
    document.tap()
  }

  func testWeekKeepsChangesAcrossRelaunches() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let today = Date()
    let date = calendar.dateComponents([.month, .day], from: today)
    let mondayOffset = (calendar.component(.weekday, from: today) + 5) % 7
    let monday = calendar.date(byAdding: .day, value: -mondayOffset, to: today)!
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyyMMdd"
    let filename = "WeekGlass-" + formatter.string(from: monday)
    let day = "\(date.month!)月\(date.day!)日"
    let title = "Studio review " + String(UUID().uuidString.prefix(8))
    let editedTitle = title + " AM"

    app.launch()
    checkWeek(app)
    attachScreen("首次打开周历", of: app)
    app.buttons["新建日程"].tap()
    let field = app.textFields.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    field.tap()
    field.typeText(title)
    app.buttons["保存日程"].tap()
    XCTAssertTrue(card(title, in: app).waitForExistence(timeout: 10))
    attachScreen("保存后的周历", of: app)

    relaunch(app)
    openDetails(title, on: day, in: app)
    attachScreen("重开后的原始日程", of: app)
    app.buttons["调整"].tap()
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    XCTAssertEqual(field.value as? String, title)
    // Place the caret beyond the short title, as in normal single-line editing.
    field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    field.typeText(" AM")
    app.buttons["保存日程"].tap()
    XCTAssertTrue(card(editedTitle, in: app).waitForExistence(timeout: 10))

    relaunch(app)
    XCTAssertFalse(card(title, in: app).exists)
    openDetails(editedTitle, on: day, in: app)
    attachScreen("重开后的修改日程", of: app)
    app.buttons["关闭"].tap()
    try exportJSON(in: app)
    openDetails(editedTitle, on: day, in: app)
    app.buttons["删除"].tap()
    app.buttons["确认删除"].tap()
    checkWeek(app)
    XCTAssertFalse(card(editedTitle, in: app).exists)

    relaunch(app)
    XCTAssertFalse(card(title, in: app).exists)
    XCTAssertFalse(card(editedTitle, in: app).exists)
    attachScreen("删除后重新打开周历", of: app)

    try importJSON(named: filename, in: app)
    XCTAssertTrue(card(editedTitle, in: app).waitForExistence(timeout: 15))
    relaunch(app)
    openDetails(editedTitle, on: day, in: app)
    attachScreen("文件导回并重开后的日程", of: app)
  }
}
