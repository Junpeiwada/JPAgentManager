import XCTest
@testable import JPAgentManager

final class HookEventReaderTests: XCTestCase {
    private var dir: URL!
    private var file: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("HookEventReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("events.jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func line(_ name: String?, session: String = "s1", extra: String = "", pid: String = "123") -> String {
        let nameField = name.map { "\"hook_event_name\":\"\($0)\"," } ?? ""
        return "{\"ts\":1700000000.5,\"claude_pid\":\(pid),\"input\":{\(nameField)\"session_id\":\"\(session)\",\"cwd\":\"/tmp/x\",\"transcript_path\":\"/tmp/t.jsonl\"\(extra)}}\n"
    }

    private func write(_ text: String) throws {
        try text.write(to: file, atomically: false, encoding: .utf8)
    }

    private func append(_ text: String) throws {
        let h = try FileHandle(forWritingTo: file)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
    }

    func test行を書いて読む() throws {
        try write(line("SessionStart") + line("Stop", session: "s2"))
        let events = HookEventReader(fileURL: file).readNew()
        XCTAssertEqual(events.map(\.name), ["SessionStart", "Stop"])
        XCTAssertEqual(events[0].sessionID, "s1")
        XCTAssertEqual(events[0].claudePID, 123)
        XCTAssertEqual(events[0].cwd, "/tmp/x")
        XCTAssertEqual(events[0].transcriptPath, "/tmp/t.jsonl")
        XCTAssertEqual(events[0].ts, Date(timeIntervalSince1970: 1700000000.5))
        XCTAssertEqual(events[1].sessionID, "s2")
    }

    func testファイルが無ければ空() {
        XCTAssertEqual(HookEventReader(fileURL: file).readNew(), [])
    }

    func test追記分だけ読む() throws {
        try write(line("SessionStart"))
        let reader = HookEventReader(fileURL: file)
        XCTAssertEqual(reader.readNew().count, 1)
        XCTAssertEqual(reader.readNew().count, 0)
        try append(line("Stop"))
        XCTAssertEqual(reader.readNew().map(\.name), ["Stop"])
    }

    func test途中で切れた行は次回() throws {
        let full = line("Stop")
        let cut = full.index(full.startIndex, offsetBy: 30)
        try write(line("SessionStart") + String(full[..<cut]))
        let reader = HookEventReader(fileURL: file)
        XCTAssertEqual(reader.readNew().map(\.name), ["SessionStart"])
        try append(String(full[cut...]))
        XCTAssertEqual(reader.readNew().map(\.name), ["Stop"])
    }

    func test壊れた行とフック名の無い行は捨てる() throws {
        try write("これはJSONではない\n" + line(nil) + "{\"ts\":1,\"claude_pid\":null,\"input\":null}\n" + line("Stop", pid: "null"))
        let events = HookEventReader(fileURL: file).readNew()
        XCTAssertEqual(events.map(\.name), ["Stop"])
        XCTAssertNil(events[0].claudePID)
    }

    func testファイルを消して作り直したら頭から読む() throws {
        try write(line("SessionStart") + line("UserPromptSubmit"))
        let reader = HookEventReader(fileURL: file)
        XCTAssertEqual(reader.readNew().count, 2)
        try FileManager.default.removeItem(at: file)
        try write(line("Stop"))
        XCTAssertEqual(reader.readNew().map(\.name), ["Stop"])
    }

    func testNotificationとPreToolUseの項目が取れる() throws {
        try write(
            line("Notification", extra: ",\"message\":\"許可が必要です\",\"notification_type\":\"permission_prompt\"")
            + line("PreToolUse", extra: ",\"tool_name\":\"Bash\"")
        )
        let events = HookEventReader(fileURL: file).readNew()
        XCTAssertEqual(events[0].message, "許可が必要です")
        XCTAssertEqual(events[0].notificationType, "permission_prompt")
        XCTAssertEqual(events[1].toolName, "Bash")
    }

    func testローテーション前に旧ファイルへ追記された行も読む() throws {
        try write(line("SessionStart"))
        let reader = HookEventReader(fileURL: file)
        XCTAssertEqual(reader.readNew().map(\.name), ["SessionStart"])
        try append(line("Stop"))
        let rotated = dir.appendingPathComponent("events.1.jsonl")
        try FileManager.default.moveItem(at: file, to: rotated)
        try write(line("UserPromptSubmit"))
        XCTAssertEqual(reader.readNew().map(\.name), ["Stop", "UserPromptSubmit"])
    }

    func testローテーション後に新ファイルが無い間は空で_作られたら旧の残りと新を読む() throws {
        try write(line("SessionStart"))
        let reader = HookEventReader(fileURL: file)
        XCTAssertEqual(reader.readNew().map(\.name), ["SessionStart"])
        try append(line("Stop"))
        try FileManager.default.moveItem(at: file, to: dir.appendingPathComponent("events.1.jsonl"))
        XCTAssertEqual(reader.readNew(), [])
        try write(line("UserPromptSubmit"))
        XCTAssertEqual(reader.readNew().map(\.name), ["Stop", "UserPromptSubmit"])
    }

    func test旧ファイルを改名せず削除して作り直したら新ファイルだけ読む() throws {
        try write(line("SessionStart"))
        let reader = HookEventReader(fileURL: file)
        XCTAssertEqual(reader.readNew().map(\.name), ["SessionStart"])
        try append(line("Stop"))
        try FileManager.default.removeItem(at: file)
        try write(line("UserPromptSubmit"))
        XCTAssertEqual(reader.readNew().map(\.name), ["UserPromptSubmit"])
    }

    func test監視_まだ無いサブフォルダでも書けばonChangeが呼ばれる() throws {
        let sub = dir.appendingPathComponent("sub")
        let subFile = sub.appendingPathComponent("events.jsonl")
        let reader = HookEventReader(fileURL: subFile)
        let exp = expectation(description: "onChange")
        exp.assertForOverFulfill = false
        reader.startWatching { exp.fulfill() }
        try Data(line("Stop").utf8).write(to: subFile)
        wait(for: [exp], timeout: 5)
        reader.stopWatching()
    }

    func testtsが無い行は読んだ時刻で埋める() throws {
        try write("{\"input\":{\"hook_event_name\":\"Stop\"}}\n")
        let before = Date()
        let events = HookEventReader(fileURL: file).readNew()
        XCTAssertEqual(events.count, 1)
        XCTAssertGreaterThanOrEqual(events[0].ts, before)
    }

    func test監視_追記でonChangeが呼ばれる() throws {
        try write(line("SessionStart"))
        let reader = HookEventReader(fileURL: file)
        let exp = expectation(description: "onChange")
        exp.assertForOverFulfill = false
        reader.startWatching { exp.fulfill() }
        try append(line("Stop"))
        wait(for: [exp], timeout: 5)
        reader.stopWatching()
    }

    func test監視_改名して作り直した後の追記でもonChangeが呼ばれる() throws {
        try write(line("SessionStart"))
        let reader = HookEventReader(fileURL: file)
        var count = 0
        let first = expectation(description: "改名で呼ばれる")
        first.assertForOverFulfill = false
        reader.startWatching { count += 1; first.fulfill() }
        try FileManager.default.moveItem(at: file, to: dir.appendingPathComponent("events.1.jsonl"))
        try write(line("UserPromptSubmit"))
        wait(for: [first], timeout: 5)

        // 新しいファイルへの追記で呼ばれるか見る
        let base = count
        try append(line("Stop"))
        let poll = expectation(description: "増えた")
        poll.assertForOverFulfill = false
        func check() { if count > base { poll.fulfill() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: check) } }
        check()
        wait(for: [poll], timeout: 5)
        reader.stopWatching()
    }
}
