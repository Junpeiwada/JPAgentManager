import XCTest

final class HookHelperTests: XCTestCase {
    private var dir: URL!

    /// ビルド成果物の置き場所（アプリ .app と同じフォルダ）にあるヘルパー。アプリには同梱しない
    private static let helperURL = Bundle.main.bundleURL
        .deletingLastPathComponent().appendingPathComponent("jpam-hook")

    override func setUpWithError() throws {
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: Self.helperURL.path),
            "jpam-hook が \(Self.helperURL.path) にない（テストターゲットの依存で BUILT_PRODUCTS_DIR にビルドされるはず）"
        )
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hookhelper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir!
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    }

    private struct Result {
        var status: Int32
        var output: Data
        var seconds: Double
    }

    /// ヘルパーを起動し、入力を流して終了を待つ（stdout と stderr はまとめて受け取る）
    private func run(input: Data, eventsFile: URL) throws -> Result {
        let p = Process()
        p.executableURL = Self.helperURL
        p.environment = ["JPAM_EVENTS_FILE": eventsFile.path, "PATH": "/usr/bin:/bin"]
        let stdin = Pipe(), out = Pipe()
        p.standardInput = stdin
        p.standardOutput = out
        p.standardError = out
        // waitUntilExit は実行ループの周期で待つため、時間の測定がずれる。終了通知のセマフォで待つ
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        let start = Date()
        try p.run()
        // 大きな入力でもパイプが詰まらないよう別スレッドで書く
        let writer = stdin.fileHandleForWriting
        DispatchQueue.global().async {
            try? writer.write(contentsOf: input)
            try? writer.close()
        }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        return Result(status: p.terminationStatus, output: output, seconds: Date().timeIntervalSince(start))
    }

    private func run(_ text: String, eventsFile: URL) throws -> Result {
        try run(input: Data(text.utf8), eventsFile: eventsFile)
    }

    private func lines(_ file: URL) throws -> [Data] {
        let data = try Data(contentsOf: file)
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
    }

    func test_正常な入力で許可した項目だけが1行に残る() throws {
        let file = dir.appendingPathComponent("out/events.jsonl")
        let input = """
        {"hook_event_name":"PostToolUse","session_id":"abc","cwd":"/tmp/x","transcript_path":"/tmp/t.jsonl",
         "notification_type":"idle","message":"hello","tool_name":"Bash",
         "tool_input":{"command":"secret"},"tool_response":{"stdout":"secret"},"prompt":"secret"}
        """
        let r = try run(input, eventsFile: file)
        XCTAssertEqual(r.status, 0)
        XCTAssertTrue(r.output.isEmpty)
        let ls = try lines(file)
        XCTAssertEqual(ls.count, 1)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: ls[0]) as? [String: Any])
        XCTAssertNotNil(obj["ts"] as? Double)
        XCTAssertTrue(obj["claude_pid"] is NSNumber || obj["claude_pid"] is NSNull)
        let kept = try XCTUnwrap(obj["input"] as? [String: Any])
        XCTAssertEqual(Set(kept.keys), ["hook_event_name", "session_id", "cwd", "transcript_path", "notification_type", "message", "tool_name"])
        XCTAssertEqual(kept["session_id"] as? String, "abc")
        XCTAssertNil(kept["tool_input"])
        XCTAssertNil(kept["tool_response"])
        XCTAssertFalse(String(decoding: ls[0], as: UTF8.self).contains("secret"))
    }

    func test_messageは500文字で切られる() throws {
        let file = dir.appendingPathComponent("events.jsonl")
        let long = String(repeating: "あ", count: 800)
        _ = try run("{\"hook_event_name\":\"Notification\",\"message\":\"\(long)\"}", eventsFile: file)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: lines(file)[0]) as? [String: Any])
        let message = try XCTUnwrap((obj["input"] as? [String: Any])?["message"] as? String)
        XCTAssertEqual(message.count, 500)
    }

    func test_壊れた入力と空入力と配列ではinputがnullで終了コード0() throws {
        for text in ["{\"a\":", "", "[1,2,3]", "\"str\""] {
            let file = dir.appendingPathComponent("e-\(UUID().uuidString).jsonl")
            let r = try run(text, eventsFile: file)
            XCTAssertEqual(r.status, 0, text)
            XCTAssertTrue(r.output.isEmpty, text)
            let ls = try lines(file)
            XCTAssertEqual(ls.count, 1, text)
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: ls[0]) as? [String: Any])
            XCTAssertTrue(obj["input"] is NSNull, text)
        }
    }

    func test_書き込めない場所でも終了コード0で出力なし() throws {
        let r = try run("{\"hook_event_name\":\"Stop\"}", eventsFile: URL(fileURLWithPath: "/dev/null/x/events.jsonl"))
        XCTAssertEqual(r.status, 0)
        XCTAssertTrue(r.output.isEmpty)
    }

    func test_5MB超のファイルはevents1jsonlに切り替わる() throws {
        let file = dir.appendingPathComponent("events.jsonl")
        let rotated = dir.appendingPathComponent("events.1.jsonl")
        let filler = Data(repeating: UInt8(ascii: "x"), count: 5 * 1024 * 1024 + 10) + Data("\n".utf8)
        try filler.write(to: file)
        let r = try run("{\"hook_event_name\":\"Stop\",\"session_id\":\"new\"}", eventsFile: file)
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(try Data(contentsOf: rotated), filler)
        let ls = try lines(file)
        XCTAssertEqual(ls.count, 1)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: ls[0]) as? [String: Any])
        XCTAssertEqual((obj["input"] as? [String: Any])?["session_id"] as? String, "new")
    }

    func test_同時に30本が各20KBを流しても全行がJSONとして読める() throws {
        let file = dir.appendingPathComponent("events.jsonl")
        let pad = String(repeating: "p", count: 20 * 1024)
        let group = DispatchGroup()
        let lock = NSLock()
        var statuses: [Int32] = []
        for i in 0..<30 {
            group.enter()
            DispatchQueue.global().async {
                // message は 500 文字に切られるので、本文は残らない項目（tool_response）で 20KB にする
                let text = "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"s\(i)\",\"tool_response\":\"\(pad)\"}"
                let r = try? self.run(text, eventsFile: file)
                lock.lock(); statuses.append(r?.status ?? -1); lock.unlock()
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(statuses.count, 30)
        XCTAssertTrue(statuses.allSatisfy { $0 == 0 })
        let ls = try lines(file)
        XCTAssertEqual(ls.count, 30)
        var ids = Set<String>()
        for l in ls {
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: l) as? [String: Any])
            ids.insert(try XCTUnwrap((obj["input"] as? [String: Any])?["session_id"] as? String))
        }
        XCTAssertEqual(ids.count, 30)
    }

    func test_1MBの入力でも1回の実行が50ms未満() throws {
        let file = dir.appendingPathComponent("events.jsonl")
        let body = String(repeating: "x", count: 1024 * 1024)
        let data = Data("{\"hook_event_name\":\"PostToolUse\",\"tool_response\":\"\(body)\"}".utf8)
        _ = try run(input: data, eventsFile: file)   // 初回の起動コスト（キャッシュ読み込みなど）を除く
        var times: [Double] = []
        for _ in 0..<5 { times.append(try run(input: data, eventsFile: file).seconds) }
        times.sort()
        XCTAssertLessThan(times[2], 0.05, "中央値 \(times[2] * 1000) ms 全部 \(times)")
    }
}
