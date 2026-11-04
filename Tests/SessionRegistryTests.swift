import XCTest
@testable import JPAgentManager

final class SessionRegistryTests: XCTestCase {
    var dir: URL!
    var projects: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("jpam-reg-\(UUID().uuidString)")
        dir = base.appendingPathComponent("sessions")
        projects = base.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    private func registry(alive: @escaping (Int32, Date?) -> Bool = { _, _ in true }) -> SessionRegistry {
        SessionRegistry(directory: dir, projectsDirectory: projects, isAlive: alive)
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json", subdirectory: nil)
            ?? Bundle(for: Self.self).url(forResource: name, withExtension: "json", subdirectory: "sessions"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func json(pid: Int, sid: String, status: String?, waitingFor: String? = nil, updated: Int = 1000, started: Int = 500) -> String {
        var s = "{\"pid\":\(pid),\"sessionId\":\"\(sid)\",\"cwd\":\"/tmp/x\",\"entrypoint\":\"claude-vscode\",\"kind\":\"interactive\",\"startedAt\":\(started),\"statusUpdatedAt\":\(updated)"
        if let status { s += ",\"status\":\"\(status)\"" }
        if let waitingFor { s += ",\"waitingFor\":\"\(waitingFor)\"" }
        return s + "}"
    }

    func testStatusの読み分け() throws {
        try write("1.json", json(pid: 1, sid: "a", status: "busy"))
        try write("2.json", json(pid: 2, sid: "b", status: "idle"))
        try write("3.json", json(pid: 3, sid: "c", status: "waiting", waitingFor: "permission prompt"))
        try write("4.json", json(pid: 4, sid: "d", status: "waiting", waitingFor: "input needed"))
        try write("5.json", json(pid: 5, sid: "e", status: "weird"))
        try write("6.json", json(pid: 6, sid: "f", status: nil))
        let r = registry().read()
        XCTAssertEqual(r.map(\.pid), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(r[0].status, .busy)
        XCTAssertEqual(r[1].status, .idle)
        XCTAssertEqual(r[2].status, .waiting(reason: "permission prompt"))
        XCTAssertEqual(r[3].status, .waiting(reason: "input needed"))
        XCTAssertEqual(r[4].status, .unknown("weird"))
        XCTAssertEqual(r[5].status, .unknown(nil))
        XCTAssertEqual(r[0].entrypoint, "claude-vscode")
        XCTAssertEqual(r[0].statusUpdatedAt, Date(timeIntervalSince1970: 1))
    }

    func test壊れたファイルと必須欠けは飛ばす() throws {
        try write("1.json", "{ not json")
        try write("2.json", "{\"pid\":2,\"cwd\":\"/x\",\"status\":\"idle\"}")
        try write("3.json", "{\"sessionId\":\"s\",\"cwd\":\"/x\"}")
        try write("4.json", "{\"pid\":4,\"sessionId\":\"s\"}")
        try write("7.json", json(pid: 7, sid: "ok", status: "idle"))
        XCTAssertEqual(registry().read().map(\.pid), [7])
    }

    func test合成フィクスチャを読める() throws {
        try write("31427.json", try fixture("sample-idle"))
        let r = registry().read()
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].pid, 31427)
        XCTAssertEqual(r[0].status, .idle)
        XCTAssertEqual(r[0].name, "sample-session")
    }

    func test死んだPIDは返さない() throws {
        try write("1.json", json(pid: 1, sid: "a", status: "idle"))
        try write("2.json", json(pid: 2, sid: "b", status: "idle"))
        XCTAssertEqual(registry(alive: { pid, _ in pid == 2 }).read().map(\.pid), [2])
    }

    func test同じsessionIdは新しいほう() throws {
        try write("1.json", json(pid: 1, sid: "same", status: "busy", updated: 1000))
        try write("2.json", json(pid: 2, sid: "same", status: "idle", updated: 2000))
        let r = registry().read()
        XCTAssertEqual(r.map(\.pid), [2])
    }

    func test再読み込みで変更が反映される() throws {
        try write("1.json", json(pid: 1, sid: "a", status: "busy"))
        let reg = registry()
        XCTAssertEqual(reg.read().first?.status, .busy)
        try write("1.json", json(pid: 1, sid: "a", status: "idle", updated: 5000))
        XCTAssertEqual(reg.read().first?.status, .idle)
    }

    func testTranscript規則どおり() throws {
        let entry = RegistryEntry(pid: 1, sessionID: "sid1", cwd: "/Users/x/Project/_a b", name: nil, kind: nil,
                                  entrypoint: nil, status: .idle, statusUpdatedAt: nil, startedAt: nil)
        let folder = projects.appendingPathComponent("-Users-x-Project--a-b")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("sid1.jsonl")
        try "{}".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(registry().transcriptURL(for: entry)?.resolvingSymlinksInPath().path, file.resolvingSymlinksInPath().path)
    }

    func testTranscript規則と違うフォルダでも探す() throws {
        let entry = RegistryEntry(pid: 1, sessionID: "sid2", cwd: "/Users/x/日本語", name: nil, kind: nil,
                                  entrypoint: nil, status: .idle, statusUpdatedAt: nil, startedAt: nil)
        let folder = projects.appendingPathComponent("odd-folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("sid2.jsonl")
        try "{}".write(to: file, atomically: true, encoding: .utf8)
        let reg = registry()
        XCTAssertEqual(reg.transcriptURL(for: entry)?.resolvingSymlinksInPath().path, file.resolvingSymlinksInPath().path)
        XCTAssertEqual(reg.transcriptURL(for: entry)?.resolvingSymlinksInPath().path, file.resolvingSymlinksInPath().path)  // キャッシュ経由
    }

    func testTranscriptが無ければnil() {
        let entry = RegistryEntry(pid: 1, sessionID: "none", cwd: "/a", name: nil, kind: nil,
                                  entrypoint: nil, status: .idle, statusUpdatedAt: nil, startedAt: nil)
        XCTAssertNil(registry().transcriptURL(for: entry))
    }

    func testProcessIsAlive() {
        XCTAssertTrue(SessionRegistry.processIsAlive(pid: getpid(), procStart: nil))
        XCTAssertFalse(SessionRegistry.processIsAlive(pid: 999_999, procStart: nil))
        XCTAssertFalse(SessionRegistry.processIsAlive(pid: getpid(), procStart: Date(timeIntervalSince1970: 1_000_000)))
        // 自プロセスの実際の起動時刻なら一致する
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        XCTAssertEqual(proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &bsd, size), size)
        let start = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec))
        XCTAssertTrue(SessionRegistry.processIsAlive(pid: getpid(), procStart: start))
    }

    func testStartWatchingでファイル書き込みを検知() throws {
        let reg = registry()
        let exp = expectation(description: "onChange")
        exp.assertForOverFulfill = false
        reg.startWatching { exp.fulfill() }
        try write("9.json", json(pid: 9, sid: "w", status: "idle"))
        wait(for: [exp], timeout: 5)
        reg.stopWatching()
    }

    // MARK: - レビュー指摘の追加分

    /// 置き換えず、同じファイルを開いて中身を上書きする（Claude Code の書き方）
    private func overwriteInPlace(_ name: String, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: dir.appendingPathComponent(name))
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(text.utf8))
    }

    func test置き換えず上書きしても次のreadで反映される() throws {
        try write("1.json", json(pid: 1, sid: "a", status: "busy"))
        let reg = registry()
        XCTAssertEqual(reg.read().first?.status, .busy)
        // 同じサイズで中身が違う上書き（busy -> idle は同じ長さ）
        let same = json(pid: 1, sid: "a", status: "idle")
        XCTAssertEqual(same.utf8.count, json(pid: 1, sid: "a", status: "busy").utf8.count)
        try overwriteInPlace("1.json", same)
        XCTAssertEqual(reg.read().first?.status, .idle)
        // サイズが変わる上書き
        try overwriteInPlace("1.json", json(pid: 1, sid: "a", status: "waiting", waitingFor: "input needed"))
        XCTAssertEqual(reg.read().first?.status, .waiting(reason: "input needed"))
    }

    func test上書き途中の壊れた内容では前回の結果を使う() throws {
        try write("1.json", json(pid: 1, sid: "a", status: "busy"))
        let reg = registry()
        XCTAssertEqual(reg.read().first?.status, .busy)
        try overwriteInPlace("1.json", "")                      // 切り詰め直後
        var snap = reg.readSnapshot()
        XCTAssertEqual(snap.entries.first?.status, .busy)
        XCTAssertEqual(snap.unreadableFiles, 0)
        try overwriteInPlace("1.json", "{\"pid\":1,\"sess")       // 途中まで
        XCTAssertEqual(reg.read().first?.status, .busy)
        try overwriteInPlace("1.json", json(pid: 1, sid: "a", status: "idle"))   // 書き終わり
        snap = reg.readSnapshot()
        XCTAssertEqual(snap.entries.first?.status, .idle)
    }

    func test前回の成功結果が無い壊れたファイルはunreadableに数える() throws {
        try write("1.json", "{ not json")
        try write("2.json", "{\"pid\":2,\"cwd\":\"/x\"}")      // 必須欠け
        try write("3.json", json(pid: 3, sid: "ok", status: "idle"))
        let snap = registry().readSnapshot()
        XCTAssertEqual(snap.entries.map(\.pid), [3])
        XCTAssertEqual(snap.unreadableFiles, 2)
        XCTAssertTrue(snap.directoryReadable)
    }

    func testフォルダが無いとdirectoryReadableがfalse() throws {
        try FileManager.default.removeItem(at: dir)
        let snap = registry().readSnapshot()
        XCTAssertFalse(snap.directoryReadable)
        XCTAssertEqual(snap.entries, [])
        XCTAssertEqual(snap.unreadableFiles, 0)
    }

    func test空のフォルダは0件で読める() {
        let snap = registry().readSnapshot()
        XCTAssertTrue(snap.directoryReadable)
        XCTAssertEqual(snap.unreadableFiles, 0)
        XCTAssertEqual(snap.entries, [])
    }

    func testシンボリックリンクと巨大ファイルは飛ばす() throws {
        let outside = dir.deletingLastPathComponent().appendingPathComponent("outside.json")
        try json(pid: 1, sid: "a", status: "idle").write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("1.json"), withDestinationURL: outside)
        // 64KB 超（JSON としては有効）
        let pad = String(repeating: "x", count: SessionRegistry.maxFileSize + 10)
        try write("2.json", "{\"pid\":2,\"sessionId\":\"b\",\"cwd\":\"/x\",\"pad\":\"\(pad)\"}")
        try write("3.json", json(pid: 3, sid: "c", status: "idle"))
        let snap = registry().readSnapshot()
        XCTAssertEqual(snap.entries.map(\.pid), [3])
        XCTAssertEqual(snap.unreadableFiles, 2)
    }

    func testFIFOは読みにいかない() throws {
        let path = dir.appendingPathComponent("1.json").path
        XCTAssertEqual(mkfifo(path, 0o600), 0)
        let snap = registry().readSnapshot()    // 読みにいけばここで固まる
        XCTAssertEqual(snap.entries, [])
        XCTAssertEqual(snap.unreadableFiles, 1)
    }

    func test不正なsessionIdは飛ばす() throws {
        try write("1.json", json(pid: 1, sid: "../evil", status: "idle"))
        try write("2.json", json(pid: 2, sid: "a/b", status: "idle"))
        try write("3.json", json(pid: 3, sid: "00000000-0000-4000-8000-000000000003", status: "idle"))
        let snap = registry().readSnapshot()
        XCTAssertEqual(snap.entries.map(\.pid), [3])
        XCTAssertEqual(snap.unreadableFiles, 2)
    }

    func testpidの型とファイル名の不一致は飛ばす() throws {
        try write("1.json", "{\"pid\":true,\"sessionId\":\"a\",\"cwd\":\"/x\"}")
        try write("2.json", "{\"pid\":2.5,\"sessionId\":\"b\",\"cwd\":\"/x\"}")
        try write("3.json", "{\"pid\":4,\"sessionId\":\"c\",\"cwd\":\"/x\"}")      // ファイル名と不一致
        try write("5.json", "{\"pid\":5,\"sessionId\":\"d\",\"cwd\":\"/x\"}")
        let snap = registry().readSnapshot()
        XCTAssertEqual(snap.entries.map(\.pid), [5])
        XCTAssertEqual(snap.unreadableFiles, 3)
    }

    func test同じsessionIdで更新時刻が同じならstartedAt次にpid() throws {
        // startedAt が新しいほうが後から列挙される場合と先に列挙される場合の両方
        try write("1.json", json(pid: 1, sid: "same", status: "idle", updated: 1000, started: 600))
        try write("2.json", json(pid: 2, sid: "same", status: "idle", updated: 1000, started: 500))
        XCTAssertEqual(registry().read().map(\.pid), [1])
        try write("1.json", json(pid: 1, sid: "same", status: "idle", updated: 1000, started: 500))
        try write("2.json", json(pid: 2, sid: "same", status: "idle", updated: 1000, started: 600))
        XCTAssertEqual(registry().read().map(\.pid), [2])
        // startedAt も同じなら pid の大きいほう
        try write("1.json", json(pid: 1, sid: "same", status: "idle", updated: 1000, started: 500))
        try write("2.json", json(pid: 2, sid: "same", status: "idle", updated: 1000, started: 500))
        XCTAssertEqual(registry().read().map(\.pid), [2])
    }

    func testprocStartをUTCとして解析する() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let expected30 = cal.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 8, minute: 10, second: 48))!
        let expected3 = cal.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 8, minute: 10, second: 48))!
        try write("1.json", "{\"pid\":1,\"sessionId\":\"a\",\"cwd\":\"/x\",\"procStart\":\"Fri Oct 30 08:10:48 2026\"}")
        try write("2.json", "{\"pid\":2,\"sessionId\":\"b\",\"cwd\":\"/x\",\"procStart\":\"Fri Oct  3 08:10:48 2026\"}")
        var seen: [Int32: Date?] = [:]
        _ = registry(alive: { pid, start in seen[pid] = .some(start); return true }).read()
        XCTAssertEqual(seen[1] ?? nil, expected30)
        XCTAssertEqual(seen[2] ?? nil, expected3)
    }

    func testjson以外の拡張子は飛ばす() throws {
        try write("1.json.bak", json(pid: 1, sid: "a", status: "idle"))
        try write("2.txt", json(pid: 2, sid: "b", status: "idle"))
        try write("3.json", json(pid: 3, sid: "c", status: "idle"))
        let snap = registry().readSnapshot()
        XCTAssertEqual(snap.entries.map(\.pid), [3])
        XCTAssertEqual(snap.unreadableFiles, 0)
    }

    func testファイル削除でキャッシュから消える() throws {
        try write("1.json", json(pid: 1, sid: "a", status: "idle"))
        try write("2.json", json(pid: 2, sid: "b", status: "idle"))
        let reg = registry()
        XCTAssertEqual(reg.read().count, 2)
        XCTAssertEqual(reg.cachedFileCount, 2)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("1.json"))
        XCTAssertEqual(reg.read().map(\.pid), [2])
        XCTAssertEqual(reg.cachedFileCount, 1)
    }

    func testTranscript見つからない結果は30秒覚えて全体探索を飛ばす() throws {
        var clock = Date(timeIntervalSince1970: 10_000)
        let reg = SessionRegistry(directory: dir, projectsDirectory: projects, now: { clock })
        let entry = RegistryEntry(pid: 1, sessionID: "late", cwd: "/a", name: nil, kind: nil,
                                  entrypoint: nil, status: .idle, statusUpdatedAt: nil, startedAt: nil)
        XCTAssertNil(reg.transcriptURL(for: entry))
        // 規則外のフォルダに後から置かれても、30秒以内は全体探索しない
        let folder = projects.appendingPathComponent("odd")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("late.jsonl")
        try "{}".write(to: file, atomically: true, encoding: .utf8)
        clock = clock.addingTimeInterval(10)
        XCTAssertNil(reg.transcriptURL(for: entry))
        clock = clock.addingTimeInterval(21)
        XCTAssertEqual(reg.transcriptURL(for: entry)?.resolvingSymlinksInPath().path, file.resolvingSymlinksInPath().path)
    }

    func testTranscriptの規則どおりの場所は探索の間引き中でも見つかる() throws {
        let reg = registry()
        let entry = RegistryEntry(pid: 1, sessionID: "late2", cwd: "/a", name: nil, kind: nil,
                                  entrypoint: nil, status: .idle, statusUpdatedAt: nil, startedAt: nil)
        XCTAssertNil(reg.transcriptURL(for: entry))
        let folder = projects.appendingPathComponent("-a")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "{}".write(to: folder.appendingPathComponent("late2.jsonl"), atomically: true, encoding: .utf8)
        XCTAssertNotNil(reg.transcriptURL(for: entry))
    }

    func testTranscriptはUTF16単位でフォルダ名にする() throws {
        // 絵文字（サロゲートペア）は2単位 -> "--"
        let entry = RegistryEntry(pid: 1, sessionID: "emoji", cwd: "/a/😀b", name: nil, kind: nil,
                                  entrypoint: nil, status: .idle, statusUpdatedAt: nil, startedAt: nil)
        let folder = projects.appendingPathComponent("-a---b")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("emoji.jsonl")
        try "{}".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(registry().transcriptURL(for: entry)?.resolvingSymlinksInPath().path, file.resolvingSymlinksInPath().path)
    }

    func testTranscriptは不正なsessionIdならnil() {
        let entry = RegistryEntry(pid: 1, sessionID: "../x", cwd: "/a", name: nil, kind: nil,
                                  entrypoint: nil, status: .idle, statusUpdatedAt: nil, startedAt: nil)
        XCTAssertNil(registry().transcriptURL(for: entry))
    }

    func testフォルダが後から現れたらrewatchIfNeededで監視を張り直す() throws {
        try FileManager.default.removeItem(at: dir)
        let reg = registry()
        let exp = expectation(description: "onChange")
        exp.assertForOverFulfill = false
        reg.startWatching { exp.fulfill() }          // フォルダが無いので張れない
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        reg.rewatchIfNeeded()
        try write("9.json", json(pid: 9, sid: "w", status: "idle"))
        wait(for: [exp], timeout: 5)
        reg.stopWatching()
    }

    func test連続した変化はonChangeが間引かれる() throws {
        let reg = registry()
        var count = 0
        let exp = expectation(description: "onChange")
        exp.assertForOverFulfill = false
        reg.startWatching { count += 1; exp.fulfill() }
        for i in 1...5 { try write("\(i).json", json(pid: i, sid: "s\(i)", status: "idle")) }
        wait(for: [exp], timeout: 5)
        // 間引き窓より長く待って、連発していないことを確かめる
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { settle.fulfill() }
        wait(for: [settle], timeout: 3)
        reg.stopWatching()
        XCTAssertLessThanOrEqual(count, 2)
    }

    func test実物のセッション数を表示する() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JPAM_REAL_SESSIONS"] == "1",
                          "JPAM_REAL_SESSIONS=1 のときだけ実行")
        let r = SessionRegistry().read()
        var counts: [String: Int] = [:]
        for e in r { counts["\(e.status)", default: 0] += 1 }
        print("REAL sessions alive=\(r.count) breakdown=\(counts)")
    }
}
