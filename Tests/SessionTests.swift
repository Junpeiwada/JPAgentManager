import XCTest
@testable import JPAgentManager

final class SessionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func text(_ status: SessionStatus, seconds: Double) -> String {
        let s = Session(id: "t", pid: nil, cwd: "/tmp", status: status,
                        statusSince: now.addingTimeInterval(-seconds),
                        title: nil, lastAction: nil, lastPrompt: nil)
        return s.elapsedText(now: now)
    }

    func test経過時間の境界() {
        XCTAssertEqual(text(.idle, seconds: 59.9), "今")
        XCTAssertEqual(text(.idle, seconds: 60), "1分")
        XCTAssertEqual(text(.idle, seconds: 3599), "59分")
        XCTAssertEqual(text(.idle, seconds: 3600), "1時間")
        XCTAssertEqual(text(.idle, seconds: 86399), "23時間")
        XCTAssertEqual(text(.idle, seconds: 86400), "1日")
        XCTAssertEqual(text(.idle, seconds: -10), "今")
    }

    func test実行中は時分表示() {
        XCTAssertEqual(text(.running, seconds: 0), "0:00")
        XCTAssertEqual(text(.running, seconds: 45 * 60), "0:45")
        XCTAssertEqual(text(.running, seconds: 65 * 60), "1:05")
    }

    func test状態の並び順() {
        XCTAssertEqual(SessionStatus.allCases.sorted(), [.waiting, .running, .idle, .empty])
    }

    func testリポジトリの色は安定() {
        XCTAssertEqual(Theme.repoColorIndex(for: "/a/b"), Theme.repoColorIndex(for: "/a/b"))
        let nfc = "/Users/x/プロジェクト".precomposedStringWithCanonicalMapping
        let nfd = "/Users/x/プロジェクト".decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(Array(nfc.utf8), Array(nfd.utf8))
        XCTAssertEqual(Theme.repoColorIndex(for: nfc), Theme.repoColorIndex(for: nfd))
        let index = Theme.repoColorIndex(for: "")
        XCTAssertTrue(Theme.repoPalette.indices.contains(index))
    }
}
