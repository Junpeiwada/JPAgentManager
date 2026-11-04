import XCTest

final class SmokeTests: XCTestCase {
    func testテストバンドルの識別子が取れる() {
        XCTAssertNotNil(Bundle(for: SmokeTests.self).bundleIdentifier)
    }
}
