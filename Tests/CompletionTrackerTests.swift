import XCTest
@testable import JPAgentManager

final class CompletionTrackerTests: XCTestCase {
    private func repos(_ statuses: [String: SessionStatus]) -> [Repo] {
        let sessions = statuses.sorted { $0.key < $1.key }.map { id, status in
            Session(id: id, pid: nil, cwd: "/tmp/r", status: status, statusSince: Date(),
                    title: nil, lastAction: nil, lastPrompt: nil)
        }
        return [Repo(id: "/tmp/r", name: "r", branch: nil, sessions: sessions)]
    }

    func test_初回は印を付けない() {
        var t = CompletionTracker()
        t.update(repos: repos(["a": .idle]))
        XCTAssertEqual(t.unseen, [])
    }

    func test_実行中から待機に変わったら印を付ける() {
        var t = CompletionTracker()
        t.update(repos: repos(["a": .running, "b": .idle]))
        t.update(repos: repos(["a": .idle, "b": .idle]))
        XCTAssertEqual(t.unseen, ["a"])
    }

    func test_許可待ちから待機では印を付けない() {
        var t = CompletionTracker()
        t.update(repos: repos(["a": .waiting]))
        t.update(repos: repos(["a": .idle]))
        XCTAssertEqual(t.unseen, [])
    }

    func test_待機のままなら印が残る() {
        var t = CompletionTracker()
        t.update(repos: repos(["a": .running]))
        t.update(repos: repos(["a": .idle]))
        t.update(repos: repos(["a": .idle]))
        XCTAssertEqual(t.unseen, ["a"])
    }

    func test_実行中に戻ったら外す() {
        var t = CompletionTracker()
        t.update(repos: repos(["a": .running]))
        t.update(repos: repos(["a": .idle]))
        t.update(repos: repos(["a": .running]))
        XCTAssertEqual(t.unseen, [])
    }

    func test_タブが消えたら外す() {
        var t = CompletionTracker()
        t.update(repos: repos(["a": .running]))
        t.update(repos: repos(["a": .idle]))
        t.update(repos: repos([:]))
        XCTAssertEqual(t.unseen, [])
    }

    func test_確認済みにすると外れる() {
        var t = CompletionTracker()
        t.update(repos: repos(["a": .running]))
        t.update(repos: repos(["a": .idle]))
        t.markSeen("a")
        XCTAssertEqual(t.unseen, [])
        t.update(repos: repos(["a": .idle]))
        XCTAssertEqual(t.unseen, [])
    }

    func test_applyで印の有無を行に反映する() {
        let applied = CompletionTracker.apply(["a"], to: repos(["a": .idle, "b": .idle]))
        let flags = Dictionary(uniqueKeysWithValues: applied[0].sessions.map { ($0.id, $0.completedUnseen) })
        XCTAssertEqual(flags, ["a": true, "b": false])
    }
}
