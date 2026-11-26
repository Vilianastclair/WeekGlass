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

  private func exportJSON(in app: XCUIApplication) {
    openFileAction("导出日程", in: app)
    control("JSON", in: app).tap()
    app.buttons["导出"].tap()
    let save = app.buttons["Save"]
    XCTAssertTrue(save.waitForExistence(timeout: 20), "The system Files save sheet must open")
    if !save.isEnabled {
      control("On My iPhone", in: app).tap()
    }
    XCTAssertTrue(save.isEnabled)
    attachScreen("在文件中保存 JSON", of: app)
    save.tap()
    checkWeek(app)
  }

  private func importJSON(named base: String, in app: XCUIApplication) {
    openFileAction("导入日程", in: app)
    app.buttons["选择文件并导入"].tap()
    let file = app.descendants(matching: .any).matching(
      NSPredicate(format: "label BEGINSWITH %@", base)
    ).firstMatch
    if !file.waitForExistence(timeout: 5) {
      // A fresh picker may start in Recents. Browse the on-device location
      // where the save sheet wrote the file instead of using app storage.
      let browse = control("Browse", in: app)
      if browse.exists { browse.tap() }
      let phone = control("On My iPhone", in: app)
      if phone.waitForExistence(timeout: 3) { phone.tap() }
    }
    XCTAssertTrue(file.waitForExistence(timeout: 10), "The document saved by Files must be selectable")
    attachScreen("在文件中选择 JSON", of: app)
    file.tap()
  }

  func testWeekKeepsChangesAcrossRelaunches() {
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
    exportJSON(in: app)
    openDetails(editedTitle, on: day, in: app)
    app.buttons["删除"].tap()
    app.buttons["确认删除"].tap()
    checkWeek(app)
    XCTAssertFalse(card(editedTitle, in: app).exists)

    relaunch(app)
    XCTAssertFalse(card(title, in: app).exists)
    XCTAssertFalse(card(editedTitle, in: app).exists)
    attachScreen("删除后重新打开周历", of: app)

    importJSON(named: filename, in: app)
    XCTAssertTrue(card(editedTitle, in: app).waitForExistence(timeout: 15))
    relaunch(app)
    openDetails(editedTitle, on: day, in: app)
    attachScreen("文件导回并重开后的日程", of: app)
  }
}
