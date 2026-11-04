import XCTest
@testable import JPAgentManager

final class StatusItemControllerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func repo(_ sessions: [(SessionStatus, TimeInterval)]) -> Repo {
        Repo(id: "r", name: "r", branch: nil, sessions: sessions.enumerated().map { i, s in
            Session(id: "s\(i)", pid: nil, cwd: "/r", status: s.0,
                    statusSince: now.addingTimeInterval(-s.1), title: nil, lastAction: nil, lastPrompt: nil)
        })
    }

    func test_5分未満の待ちは強調しない() {
        XCTAssertFalse(StatusItemController.needsEmphasis(repos: [repo([(.waiting, 299)])], now: now))
    }

    func test_5分以上の待ちは強調する() {
        XCTAssertTrue(StatusItemController.needsEmphasis(repos: [repo([(.waiting, 300)])], now: now))
        XCTAssertTrue(StatusItemController.needsEmphasis(repos: [repo([(.running, 0), (.waiting, 900)])], now: now))
    }

    func test_待ちが無ければ強調しない() {
        XCTAssertFalse(StatusItemController.needsEmphasis(repos: [repo([(.running, 900), (.idle, 900)])], now: now))
        XCTAssertFalse(StatusItemController.needsEmphasis(repos: [], now: now))
    }

    func test_画像の全項目が全体幅に収まる() {
        for emphasized in [false, true] {
            let l = StatusItemController.layout(waiting: 12, running: 3, total: 15, emphasized: emphasized)
            XCTAssertEqual(l.items.count, 3)
            XCTAssertLessThanOrEqual(l.items.last!.maxX, l.width)
            // 項目同士が重ならない
            for (a, b) in zip(l.items, l.items.dropFirst()) {
                XCTAssertLessThanOrEqual(a.maxX, b.minX)
            }
        }
    }

    func test_強調すると下地の余白の分だけ幅が増える() {
        let normal = StatusItemController.layout(waiting: 1, running: 1, total: 2, emphasized: false)
        let emphasized = StatusItemController.layout(waiting: 1, running: 1, total: 2, emphasized: true)
        XCTAssertEqual(emphasized.width - normal.width, 8, accuracy: 0.001)
    }
}
