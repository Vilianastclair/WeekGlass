import XCTest

final class RunnerUITests: XCTestCase {
  private func attachScreen(_ name: String, of app: XCUIApplication) {
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
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
    XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
    let dateAndTime = app.staticTexts.matching(NSPredicate(
      format: "label CONTAINS %@ AND label CONTAINS %@", day, "09:00 — 10:00"
    )).firstMatch
    XCTAssertTrue(dateAndTime.exists, "Details must show the selected day and both times")
  }

  func testWeekKeepsChangesAcrossRelaunches() {
    continueAfterFailure = false
    let app = XCUIApplication()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let date = calendar.dateComponents([.month, .day], from: Date())
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
    app.buttons["删除"].tap()
    app.buttons["确认删除"].tap()
    checkWeek(app)
    XCTAssertFalse(card(editedTitle, in: app).exists)

    relaunch(app)
    XCTAssertFalse(card(title, in: app).exists)
    XCTAssertFalse(card(editedTitle, in: app).exists)
    attachScreen("删除后重新打开周历", of: app)
  }
}
