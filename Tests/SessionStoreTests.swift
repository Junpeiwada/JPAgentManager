import XCTest
@testable import JPAgentManager

final class SessionStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func entry(_ id: String, cwd: String = "/work/a", status: RegistryStatus = .idle,
                       updated: Date? = nil, started: Date? = nil) -> RegistryEntry {
        RegistryEntry(pid: 100, sessionID: id, cwd: cwd, name: nil, kind: nil, entrypoint: nil,
                      status: status, statusUpdatedAt: updated, startedAt: started)
    }

    private func summary(title: String? = "目標", prompt: String? = "指示", action: String? = nil,
                         text: Bool = false) -> TranscriptSummary {
        TranscriptSummary(title: title, lastPrompt: prompt, lastAction: action, endedWithText: text)
    }

    private func firstSession(_ e: RegistryEntry, _ s: TranscriptSummary?) -> Session {
        let sums = s.map { [e.sessionID: $0] } ?? [:]
        return SessionStore.build(entries: [e], summaries: sums, git: [:], now: now)[0].sessions[0]
    }

    func testEntrypointがSessionに入る() {
        let e = RegistryEntry(pid: 100, sessionID: "s", cwd: "/work/a", name: nil, kind: nil, entrypoint: "claude-vscode",
                              status: .idle, statusUpdatedAt: nil, startedAt: nil)
        XCTAssertEqual(firstSession(e, summary()).entrypoint, "claude-vscode")
        XCTAssertNil(firstSession(entry("s"), summary()).entrypoint)
    }

    func test状態の対応() {
        XCTAssertEqual(firstSession(entry("s", status: .busy), summary()).status, .running)
        XCTAssertEqual(firstSession(entry("s", status: .waiting(reason: "permission prompt")), summary()).status, .waiting)
        XCTAssertEqual(firstSession(entry("s", status: .idle), summary()).status, .idle)
        XCTAssertEqual(firstSession(entry("s", status: .unknown("x")), nil).status, .idle)
    }

    func testIdleで会話ログ無しまたは指示無しは空() {
        XCTAssertEqual(firstSession(entry("s"), nil).status, .empty)
        XCTAssertEqual(firstSession(entry("s"), summary(title: nil, prompt: nil, action: "Read: a")).status, .empty)
        XCTAssertEqual(firstSession(entry("s"), summary(title: nil, prompt: "指示")).status, .idle)
    }

    func test返答済みの文言() {
        XCTAssertEqual(firstSession(entry("s"), summary(action: "Edit: a.ts", text: true)).lastAction, "返答済み（Edit: a.ts）")
        XCTAssertEqual(firstSession(entry("s"), summary(action: nil, text: true)).lastAction, "返答済み")
        XCTAssertEqual(firstSession(entry("s"), summary(action: "Edit: a.ts", text: false)).lastAction, "Edit: a.ts")
        XCTAssertEqual(firstSession(entry("s", status: .busy), summary(action: "Edit: a.ts", text: true)).lastAction, "Edit: a.ts")
    }

    func test同じgitルートは1つのRepoにまとまる() {
        let root = GitInfo.Info(root: "/work/a", branch: "main")
        let repos = SessionStore.build(
            entries: [entry("1", cwd: "/work/a"), entry("2", cwd: "/work/a/sub")],
            summaries: [:], git: ["/work/a": root, "/work/a/sub": root], now: now)
        XCTAssertEqual(repos.count, 1)
        XCTAssertEqual(repos[0].id, "/work/a")
        XCTAssertEqual(repos[0].name, "a")
        XCTAssertEqual(repos[0].branch, "main")
        XCTAssertEqual(repos[0].sessions.count, 2)
    }

    func testGitが無ければcwdごと() {
        let repos = SessionStore.build(
            entries: [entry("1", cwd: "/work/a"), entry("2", cwd: "/work/b")],
            summaries: [:], git: [:], now: now)
        XCTAssertEqual(Set(repos.map(\.id)), ["/work/a", "/work/b"])
        XCTAssertTrue(repos.allSatisfy { $0.branch == nil })
    }

    func test許可待ちを含むリポジトリが先頭() {
        let repos = SessionStore.build(
            entries: [entry("1", cwd: "/work/a", status: .busy),
                      entry("2", cwd: "/work/b", status: .waiting(reason: nil))],
            summaries: [:], git: [:], now: now)
        XCTAssertEqual(repos.map(\.id), ["/work/b", "/work/a"])
    }

    func testStatusSinceの決め方() {
        let updated = Date(timeIntervalSince1970: 500)
        let started = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(firstSession(entry("s", updated: updated, started: started), nil).statusSince, updated)
        XCTAssertEqual(firstSession(entry("s", started: started), nil).statusSince, started)
        // どちらも無ければ now
        XCTAssertEqual(firstSession(entry("s"), nil).statusSince, now)
    }

    func testStatusSinceは同じ状態なら前回を引き継ぐ() {
        let e = entry("s", status: .busy)
        let first = SessionStore.build(entries: [e], summaries: [:], git: [:], now: now)[0].sessions[0]
        let later = now.addingTimeInterval(10)
        let prev = [first.id: first]
        // 同じ状態: 前回の値のまま
        let same = SessionStore.build(entries: [e], summaries: [:], git: [:], previous: prev, now: later)[0].sessions[0]
        XCTAssertEqual(same.statusSince, now)
        // 状態が変わったら新しい時刻
        let changed = SessionStore.build(entries: [entry("s", status: .waiting(reason: nil))], summaries: [:], git: [:],
                                         previous: prev, now: later)[0].sessions[0]
        XCTAssertEqual(changed.statusSince, later)
        // statusUpdatedAt があれば優先
        let updated = Date(timeIntervalSince1970: 500)
        let withFile = SessionStore.build(entries: [entry("s", status: .busy, updated: updated)], summaries: [:], git: [:],
                                          previous: prev, now: later)[0].sessions[0]
        XCTAssertEqual(withFile.statusSince, updated)
    }

    func testStatusSinceは時刻なしで状態が変わったらnow() {
        // 何時間も前に始めたセッションでも、状態が変わった時刻は開始時刻にしない
        let started = Date(timeIntervalSince1970: 100)
        let first = SessionStore.build(entries: [entry("s", status: .busy, started: started)],
                                       summaries: [:], git: [:], now: now)[0].sessions[0]
        let later = now.addingTimeInterval(10)
        let changed = SessionStore.build(entries: [entry("s", status: .waiting(reason: nil), started: started)],
                                         summaries: [:], git: [:], previous: [first.id: first], now: later)[0].sessions[0]
        XCTAssertEqual(changed.statusSince, later)
    }

    func testStatusSinceは初見で時刻なしなら開始時刻() {
        let started = Date(timeIntervalSince1970: 100)
        let s = SessionStore.build(entries: [entry("s", status: .waiting(reason: nil), started: started)],
                                   summaries: [:], git: [:], previous: [:], now: now)[0].sessions[0]
        XCTAssertEqual(s.statusSince, started)
    }

    func test待ちの理由が入る() {
        XCTAssertEqual(firstSession(entry("s", status: .waiting(reason: "input needed")), nil).waitingFor, "input needed")
        XCTAssertEqual(firstSession(entry("s", status: .waiting(reason: "permission prompt")), nil).waitingFor, "permission prompt")
        XCTAssertNil(firstSession(entry("s", status: .busy), nil).waitingFor)
    }

    // MARK: - refresh（一時フォルダの SessionRegistry を使う）

    private func makeSessionsDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SessionStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = "{\"pid\": \(getpid()), \"sessionId\": \"11111111-1111-1111-1111-111111111111\", \"cwd\": \"/work/a\", \"status\": \"busy\"}"
        try json.write(to: dir.appendingPathComponent("\(getpid()).json"), atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    @MainActor
    func testGitが遅くてもreposがすぐ更新される() throws {
        let dir = try makeSessionsDir()
        let registry = SessionRegistry(directory: dir, projectsDirectory: dir)
        let store = SessionStore(registry: registry, sessionsDirectory: dir,
                                 gitInfo: { _ in Thread.sleep(forTimeInterval: 3); return nil })
        store.refresh()
        let exp = expectation(description: "repos が入る")
        let c = store.$repos.sink { if !$0.isEmpty { exp.fulfill() } }
        wait(for: [exp], timeout: 1)
        c.cancel()
        XCTAssertEqual(store.repos.first?.sessions.first?.status, .running)
    }

    @MainActor
    func testrefreshが重なっても同じcwdのgit問い合わせは重ならない() throws {
        let dir = try makeSessionsDir()
        let registry = SessionRegistry(directory: dir, projectsDirectory: dir)
        let calls = Counter()
        let store = SessionStore(registry: registry, sessionsDirectory: dir,
                                 gitInfo: { _ in calls.increment(); Thread.sleep(forTimeInterval: 0.5); return nil })
        for _ in 0..<5 { store.refresh() }
        let exp = expectation(description: "反映")
        let c = store.$repos.sink { if !$0.isEmpty { exp.fulfill() } }
        wait(for: [exp], timeout: 2)
        c.cancel()
        // 問い合わせ完了後の再 refresh を待っても、30秒以内は再問い合わせしない
        Thread.sleep(forTimeInterval: 1.0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(calls.value, 1)
    }

    // MARK: - git の状態と fetch

    func testGitStatusがルートのRepoに入る() {
        let status = GitStatus(upstream: "origin/main", ahead: 1, behind: 2, changedFiles: 3)
        let repos = SessionStore.build(entries: [entry("s", cwd: "/work/a/sub")], summaries: [:],
                                       git: ["/work/a/sub": GitInfo.Info(root: "/work/a", branch: "main")],
                                       gitStatuses: ["/work/a": status], now: now)
        XCTAssertEqual(repos[0].gitStatus, status)
    }

    /// 状態が落ち着くまでメインのランループを回す
    @MainActor
    private func settle(_ store: SessionStore) {
        for _ in 0..<4 {
            store.refresh()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
    }

    @MainActor
    private func makeGitStore(status: GitStatus?, fetchSucceeds: Bool, clock: Clock, fetches: Counter) throws -> SessionStore {
        let dir = try makeSessionsDir()
        return SessionStore(registry: SessionRegistry(directory: dir, projectsDirectory: dir),
                            sessionsDirectory: dir,
                            gitInfo: { _ in GitInfo.Info(root: "/work/a", branch: "main") },
                            gitStatus: { _ in status },
                            gitFetch: { _ in fetches.increment(); return fetchSucceeds },
                            now: { clock.value })
    }

    @MainActor
    func testFetchは5分ごと() throws {
        let clock = Clock(), fetches = Counter()
        let store = try makeGitStore(status: GitStatus(upstream: "origin/main", behind: 2),
                                     fetchSucceeds: true, clock: clock, fetches: fetches)
        settle(store)
        XCTAssertEqual(fetches.value, 1)
        XCTAssertEqual(store.repos.first?.gitStatus?.behind, 2)
        XCTAssertEqual(store.repos.first?.gitStatus?.fetchFailed, false)

        clock.advance(299)
        settle(store)
        XCTAssertEqual(fetches.value, 1)

        clock.advance(2)
        settle(store)
        XCTAssertEqual(fetches.value, 2)
    }

    @MainActor
    func testFetchの失敗は表示して15分後に再試行() throws {
        let clock = Clock(), fetches = Counter()
        let store = try makeGitStore(status: GitStatus(upstream: "origin/main"),
                                     fetchSucceeds: false, clock: clock, fetches: fetches)
        settle(store)
        XCTAssertEqual(fetches.value, 1)
        XCTAssertEqual(store.repos.first?.gitStatus?.fetchFailed, true)

        clock.advance(301)
        settle(store)
        XCTAssertEqual(fetches.value, 1)

        clock.advance(600)
        settle(store)
        XCTAssertEqual(fetches.value, 2)
    }

    @MainActor
    func test上流が無ければFetchしない() throws {
        let clock = Clock(), fetches = Counter()
        let store = try makeGitStore(status: GitStatus(changedFiles: 1),
                                     fetchSucceeds: true, clock: clock, fetches: fetches)
        settle(store)
        XCTAssertEqual(fetches.value, 0)
        XCTAssertEqual(store.repos.first?.gitStatus?.changedFiles, 1)
    }

    @MainActor
    func testフォルダが無ければエラーにしない() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SessionStoreTests-none-\(UUID().uuidString)")
        let registry = SessionRegistry(directory: dir, projectsDirectory: dir)
        let store = SessionStore(registry: registry, sessionsDirectory: dir, gitInfo: { _ in nil })
        store.refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNil(store.lastError)
        XCTAssertTrue(store.repos.isEmpty)
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ seconds: TimeInterval) { lock.lock(); current += seconds; lock.unlock() }
    var value: Date { lock.lock(); defer { lock.unlock() }; return current }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
