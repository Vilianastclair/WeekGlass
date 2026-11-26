import XCTest

final class RunnerUITests: XCTestCase {
  private func attachScreen(_ name: String, of app: XCUIApplication) {
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
  }

  func testWeekKeepsSavedEventAfterRelaunch() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    let week = app.buttons["整周"]
    XCTAssertTrue(week.waitForExistence(timeout: 30))
    XCTAssertTrue(week.isSelected, "A fresh iPhone should open on its weekly calendar")
    attachScreen("首次打开周历", of: app)

    app.buttons["新建日程"].tap()
    let title = "Studio review " + String(UUID().uuidString.prefix(8))
    let field = app.textFields.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    field.tap()
    field.typeText(title)
    app.buttons["保存日程"].tap()

    let event = app.buttons.matching(NSPredicate(
      format: "label BEGINSWITH %@ AND label CONTAINS %@ AND label CONTAINS %@",
      title, "09:00", "10:00"
    )).firstMatch
    XCTAssertTrue(event.waitForExistence(timeout: 10), "Saved event and time missing from the calendar")
    attachScreen("保存后的周历", of: app)

    app.terminate()
    app.launch()
    XCTAssertTrue(week.waitForExistence(timeout: 30))
    XCTAssertTrue(week.isSelected)
    XCTAssertTrue(event.waitForExistence(timeout: 10), "The event must survive process termination")
    XCTAssertTrue(event.isHittable)
    attachScreen("重新打开后的周历", of: app)

    event.tap()
    XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
    let fullTime = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "09:00 — 10:00")).firstMatch
    XCTAssertTrue(fullTime.exists)
    attachScreen("日程详情", of: app)
  }
}
