import XCTest
@testable import JPAgentManager

final class SubagentCounterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    /// <tmp>/<sid>.jsonl と <tmp>/<sid>/subagents/ を作り、会話ログのパスを返す
    private func makeSession() throws -> (transcript: String, subagents: String) {
        let root = NSTemporaryDirectory() + "subagents-\(UUID().uuidString)"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        let sub = root + "/sid/subagents"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        let transcript = root + "/sid.jsonl"
        FileManager.default.createFile(atPath: transcript, contents: Data())
        return (transcript, sub)
    }

    private func agent(_ id: String, in dir: String, meta: String, logModified: Date?) throws {
        try meta.write(toFile: "\(dir)/agent-\(id).meta.json", atomically: true, encoding: .utf8)
        guard let logModified else { return }
        let log = "\(dir)/agent-\(id).jsonl"
        FileManager.default.createFile(atPath: log, contents: Data("{}\n".utf8))
        try FileManager.default.setAttributes([.modificationDate: logModified], ofItemAtPath: log)
    }

    func test_finished無しで最近書かれたものだけ数える() throws {
        let s = try makeSession()
        try agent("a", in: s.subagents, meta: #"{"agentType":"implementer"}"#, logModified: now.addingTimeInterval(-60))
        try agent("b", in: s.subagents, meta: #"{"agentType":"implementer"}"#, logModified: now.addingTimeInterval(-120))
        try agent("done", in: s.subagents, meta: #"{"agentType":"x","finished":true}"#, logModified: now)
        try agent("stale", in: s.subagents, meta: #"{"agentType":"x"}"#, logModified: now.addingTimeInterval(-3600))
        try agent("nolog", in: s.subagents, meta: #"{"agentType":"x"}"#, logModified: nil)
        XCTAssertEqual(SubagentCounter.runningCount(transcriptPath: s.transcript, now: now), 2)
    }

    func test_finishedがfalseなら数える() throws {
        let s = try makeSession()
        try agent("a", in: s.subagents, meta: #"{"finished":false}"#, logModified: now)
        XCTAssertEqual(SubagentCounter.runningCount(transcriptPath: s.transcript, now: now), 1)
    }

    func test_壊れたmetaは数えず落ちない() throws {
        let s = try makeSession()
        try agent("a", in: s.subagents, meta: "{壊れた", logModified: now)
        try agent("b", in: s.subagents, meta: "[]", logModified: now)
        XCTAssertEqual(SubagentCounter.runningCount(transcriptPath: s.transcript, now: now), 0)
    }

    func test_フォルダが無ければ0() {
        XCTAssertEqual(SubagentCounter.runningCount(transcriptPath: "/nonexistent/sid.jsonl", now: now), 0)
        XCTAssertEqual(SubagentCounter.runningCount(transcriptPath: "/nonexistent/sid.txt", now: now), 0)
    }
}
