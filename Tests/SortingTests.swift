import XCTest
@testable import JPAgentManager

final class SortingTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    /// base から seconds 秒後
    private func at(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

    private func session(_ id: String, _ status: SessionStatus, since: TimeInterval = 0) -> Session {
        Session(id: id, pid: nil, cwd: "/tmp/\(id)", status: status, statusSince: at(since),
                title: nil, lastAction: nil, lastPrompt: nil)
    }

    private func repo(_ name: String, _ sessions: [Session]) -> Repo {
        Repo(id: "/repo/\(name)", name: name, branch: nil, sessions: sessions)
    }

    func test許可待ちを含むリポジトリが先頭で_実行中だけ_待機だけの順() {
        let idleOnly = repo("a-idle", [session("1", .idle)])
        let runningOnly = repo("b-running", [session("2", .running)])
        let mixed = repo("c-mixed", [session("3", .running), session("4", .waiting)])
        let result = Sorting.sorted([idleOnly, runningOnly, mixed])
        XCTAssertEqual(result.map(\.name), ["c-mixed", "b-running", "a-idle"])
    }

    func testリポジトリ内は_status順で_同じstatusならstatusSinceの古い順() {
        let r = repo("r", [
            session("idle", .idle, since: 0),
            session("run-new", .running, since: 50),
            session("wait-new", .waiting, since: 90),
            session("run-old", .running, since: 10),
            session("wait-old", .waiting, since: 5),
        ])
        let result = Sorting.sorted([r])
        XCTAssertEqual(result[0].sessions.map(\.id), ["wait-old", "wait-new", "run-old", "run-new", "idle"])
    }

    func test同じstatusとstatusSinceならidで決まる() {
        let r = repo("r", [session("b", .running), session("a", .running)])
        XCTAssertEqual(Sorting.sorted([r])[0].sessions.map(\.id), ["a", "b"])
    }

    func test同じstatusのリポジトリは_最も古いstatusSinceが先() {
        let older = repo("zzz", [session("1", .waiting, since: 100), session("2", .waiting, since: 20)])
        let newer = repo("aaa", [session("3", .waiting, since: 50)])
        XCTAssertEqual(Sorting.sorted([newer, older]).map(\.name), ["zzz", "aaa"])
    }

    func test代表のstatusは含むセッションの中で一番優先のもの() {
        // waiting は新しいが、running だけのリポジトリより先になる
        let hasWaiting = repo("x", [session("1", .running, since: 0), session("2", .waiting, since: 500)])
        let runningOnly = repo("y", [session("3", .running, since: 0)])
        XCTAssertEqual(Sorting.sorted([runningOnly, hasWaiting]).map(\.name), ["x", "y"])
    }

    func test名前で決着し_大文字小文字を無視する() {
        let b = repo("banana", [session("1", .idle)])
        let a = repo("Apple", [session("2", .idle)])
        let c = repo("cherry", [session("3", .idle)])
        XCTAssertEqual(Sorting.sorted([c, b, a]).map(\.name), ["Apple", "banana", "cherry"])
    }

    func testセッションが空のリポジトリは最後() {
        let none = repo("aaa", [])
        let empty = repo("bbb", [session("1", .empty)])
        let idle = repo("ccc", [session("2", .idle)])
        XCTAssertEqual(Sorting.sorted([none, empty, idle]).map(\.name), ["ccc", "bbb", "aaa"])
    }

    func test空タブだけのリポジトリは待機だけより後() {
        // empty は rawValue が大きいので idle だけのリポジトリより後ろに来る。
        // 画面図では逆に見えるが、待機だけのリポジトリは画面側でグレーのグループにまとめて末尾に出すので問題ない
        let empty = repo("empty-only", [session("1", .empty)])
        let idle = repo("idle-only", [session("2", .idle)])
        XCTAssertEqual(Sorting.sorted([empty, idle]).map(\.name), ["idle-only", "empty-only"])
    }

    func test名前が大文字小文字違いだけならidで決着する() {
        // id は "/repo/<name>" なので "/repo/Apple" < "/repo/apple"
        let lower = repo("apple", [session("1", .idle)])
        let upper = repo("Apple", [session("2", .idle)])
        XCTAssertEqual(Sorting.sorted([lower, upper]).map(\.id), ["/repo/Apple", "/repo/apple"])
    }

    func testセッション0件のリポジトリ同士は名前順() {
        let b = repo("banana", [])
        let a = repo("Apple", [])
        let c = repo("cherry", [])
        XCTAssertEqual(Sorting.sorted([c, b, a]).map(\.name), ["Apple", "banana", "cherry"])
    }

    func testisIdleOnlyの真偽() {
        XCTAssertTrue(Sorting.isIdleOnly(repo("r", [session("1", .idle), session("2", .idle)])))
        XCTAssertFalse(Sorting.isIdleOnly(repo("r", [])))
        XCTAssertFalse(Sorting.isIdleOnly(repo("r", [session("1", .idle), session("2", .empty)])))
        XCTAssertFalse(Sorting.isIdleOnly(repo("r", [session("1", .idle), session("2", .running)])))
        XCTAssertFalse(Sorting.isIdleOnly(repo("r", [session("1", .empty)])))
    }
}
