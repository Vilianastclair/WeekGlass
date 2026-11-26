import XCTest

final class RunnerTests: XCTestCase {
  func testWeekGlassBundleMetadata() throws {
    let bundle = Bundle.main
    let identifier = try XCTUnwrap(bundle.bundleIdentifier)
    XCTAssertTrue(["com.viliana.weekglass", "com.viliana.weekglass.smoke"].contains(identifier))
    XCTAssertEqual(bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, "WeekGlass")
    XCTAssertEqual(bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String, "12.0")
  }
}
