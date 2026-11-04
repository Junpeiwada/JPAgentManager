import XCTest
@testable import JPAgentManager

final class PanelModelTests: XCTestCase {
    func test_版数があればvを付ける() {
        XCTAssertEqual(PanelModel.versionLabel(info: ["CFBundleShortVersionString": "0.1.1"]), "v0.1.1")
    }

    func test_キーが無ければダッシュ() {
        XCTAssertEqual(PanelModel.versionLabel(info: ["CFBundleName": "x"]), "—")
    }

    func test_nilならダッシュ() {
        XCTAssertEqual(PanelModel.versionLabel(info: nil), "—")
    }

    func test_空文字ならダッシュ() {
        XCTAssertEqual(PanelModel.versionLabel(info: ["CFBundleShortVersionString": ""]), "—")
    }
}
