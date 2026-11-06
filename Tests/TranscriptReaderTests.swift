import XCTest
@testable import JPAgentManager

final class TranscriptReaderTests: XCTestCase {
    private func fixture(_ name: String) -> String {
        Bundle(for: TranscriptReaderTests.self).url(forResource: name, withExtension: "jsonl")!.path
    }

    private func tempFile() -> String {
        let path = NSTemporaryDirectory() + "transcript-\(UUID().uuidString).jsonl"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    private func append(_ text: String, to path: String) throws {
        if let h = FileHandle(forWritingAtPath: path) {
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: Data(text.utf8))
        } else {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func appendData(_ data: Data, to path: String) throws {
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: data)
    }

    func test_fixtureから要約が取れる() {
        let s = TranscriptReader().summary(transcriptPath: fixture("sample-transcript"), cwd: "/work/proj")
        XCTAssertEqual(s.title, "更新後のタイトル")   // ai-title は後のものが勝つ
        XCTAssertEqual(s.lastPrompt, "合成の最後の指示")
        XCTAssertEqual(s.lastAction, "Edit: src/train/config.ts")
        XCTAssertFalse(s.endedWithText)
    }

    func test_cwd外のパスはそのまま出る() {
        let s = TranscriptReader().summary(transcriptPath: fixture("sample-transcript"), cwd: "/other")
        XCTAssertEqual(s.lastAction, "Edit: /work/proj/src/train/config.ts")
    }

    func test_壊れた行があっても落ちず文章で終わればtrue() {
        let s = TranscriptReader().summary(transcriptPath: fixture("broken-transcript"), cwd: nil)
        XCTAssertEqual(s.title, "壊れた行の前")
        XCTAssertEqual(s.lastAction, "Bash: ls -la")   // コマンドの1行目だけ
        XCTAssertNil(s.lastPrompt)
        XCTAssertTrue(s.endedWithText)
    }

    func test_存在しないファイルは全部nil() {
        let s = TranscriptReader().summary(transcriptPath: "/nonexistent/x.jsonl", cwd: nil)
        XCTAssertEqual(s, TranscriptSummary(title: nil, lastPrompt: nil, lastAction: nil, endedWithText: false))
    }

    func test_追記分だけ読んでも結果が正しい() throws {
        let path = tempFile()
        let reader = TranscriptReader()
        try append("{\"type\":\"ai-title\",\"aiTitle\":\"A\"}\n", to: path)
        XCTAssertEqual(reader.summary(transcriptPath: path, cwd: nil).title, "A")

        // 不完全な行は次回に回る
        try append("{\"type\":\"ai-title\",\"aiTi", to: path)
        XCTAssertEqual(reader.summary(transcriptPath: path, cwd: nil).title, "A")

        try append("tle\":\"B\"}\n{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Grep\",\"input\":{\"pattern\":\"foo\"}}]}}\n", to: path)
        let s = reader.summary(transcriptPath: path, cwd: nil)
        XCTAssertEqual(s.title, "B")
        XCTAssertEqual(s.lastAction, "Grep: foo")
    }

    func test_ファイルが短くなったら読み直す() throws {
        let path = tempFile()
        let reader = TranscriptReader()
        try append("{\"type\":\"ai-title\",\"aiTitle\":\"長い長い長い古いタイトル\"}\n{\"type\":\"last-prompt\",\"lastPrompt\":\"古い\"}\n", to: path)
        XCTAssertEqual(reader.summary(transcriptPath: path, cwd: nil).lastPrompt, "古い")

        try "{\"type\":\"ai-title\",\"aiTitle\":\"新\"}\n".write(toFile: path, atomically: true, encoding: .utf8)
        let s = reader.summary(transcriptPath: path, cwd: nil)
        XCTAssertEqual(s.title, "新")
        XCTAssertNil(s.lastPrompt)
    }

    func test_長い出力は80文字程度で切って省略記号() throws {
        let path = tempFile()
        let long = String(repeating: "x", count: 200)
        try append("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"\(long)\"}}]}}\n", to: path)
        let action = TranscriptReader().summary(transcriptPath: path, cwd: nil).lastAction
        XCTAssertEqual(action?.count, 81)
        XCTAssertTrue(action?.hasSuffix("…") == true)
    }

    func test_AskUserQuestionは1問目の本文を出す() throws {
        let path = tempFile()
        try append("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"AskUserQuestion\",\"input\":{\"questions\":[{\"question\":\"どの案にしますか？\",\"header\":\"案\",\"options\":[{\"label\":\"1: A\"}]}]}}]}}\n", to: path)
        XCTAssertEqual(TranscriptReader().summary(transcriptPath: path, cwd: nil).lastAction, "質問: どの案にしますか？")
    }

    func test_AskUserQuestionが複数問なら残りの数を添える() throws {
        let path = tempFile()
        try append("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"AskUserQuestion\",\"input\":{\"questions\":[{\"question\":\"色は？\"},{\"question\":\"形は？\"},{\"question\":\"大きさは？\"}]}}]}}\n", to: path)
        XCTAssertEqual(TranscriptReader().summary(transcriptPath: path, cwd: nil).lastAction, "質問: 色は？（他2問）")
    }

    func test_AskUserQuestionの形が違えば名前だけ() throws {
        let path = tempFile()
        try append("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"AskUserQuestion\",\"input\":{\"questions\":\"壊れた形\"}}]}}\n", to: path)
        XCTAssertEqual(TranscriptReader().summary(transcriptPath: path, cwd: nil).lastAction, "AskUserQuestion")
    }

    func test_名前だけのツール() throws {
        let path = tempFile()
        try append("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"TodoWrite\",\"input\":{}}]}}\n", to: path)
        XCTAssertEqual(TranscriptReader().summary(transcriptPath: path, cwd: nil).lastAction, "TodoWrite")
    }

    func test_同じパスを元より長い別内容で置き換えたら読み直す() throws {
        let path = tempFile()
        let reader = TranscriptReader()
        try append("{\"type\":\"ai-title\",\"aiTitle\":\"旧\"}\n{\"type\":\"last-prompt\",\"lastPrompt\":\"旧\"}\n", to: path)
        XCTAssertEqual(reader.summary(transcriptPath: path, cwd: nil).title, "旧")

        // atomically で書くと別 inode になる。元より長い内容にする
        try "{\"type\":\"ai-title\",\"aiTitle\":\"新しい長いタイトルです\"}\n{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Grep\",\"input\":{\"pattern\":\"foo\"}}]}}\n".write(toFile: path, atomically: true, encoding: .utf8)
        let s = reader.summary(transcriptPath: path, cwd: nil)
        XCTAssertEqual(s.title, "新しい長いタイトルです")
        XCTAssertNil(s.lastPrompt)
        XCTAssertEqual(s.lastAction, "Grep: foo")
    }

    private let textLine = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"終わりました\"}]}}\n"

    func test_textで終わった後に新しい指示が来たらfalse() throws {
        let path = tempFile()
        let reader = TranscriptReader()
        try append(textLine, to: path)
        XCTAssertTrue(reader.summary(transcriptPath: path, cwd: nil).endedWithText)

        try append("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"次をお願い\"}}\n", to: path)
        XCTAssertFalse(reader.summary(transcriptPath: path, cwd: nil).endedWithText)
    }

    func test_textの後にtool_useならfalse() throws {
        let path = tempFile()
        let reader = TranscriptReader()
        try append(textLine, to: path)
        XCTAssertTrue(reader.summary(transcriptPath: path, cwd: nil).endedWithText)

        try append("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Read\",\"input\":{}}]}}\n", to: path)
        XCTAssertFalse(reader.summary(transcriptPath: path, cwd: nil).endedWithText)
    }

    func test_tool_resultのuser行ではendedWithTextは変わらない() throws {
        let path = tempFile()
        let reader = TranscriptReader()
        try append(textLine + "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"content\":\"x\"}]}}\n", to: path)
        XCTAssertTrue(reader.summary(transcriptPath: path, cwd: nil).endedWithText)
    }

    func test_last_prompt行でendedWithTextがfalseに戻る() throws {
        let path = tempFile()
        let reader = TranscriptReader()
        try append(textLine, to: path)
        XCTAssertTrue(reader.summary(transcriptPath: path, cwd: nil).endedWithText)
        try append("{\"type\":\"last-prompt\",\"lastPrompt\":\"次\"}\n", to: path)
        XCTAssertFalse(reader.summary(transcriptPath: path, cwd: nil).endedWithText)
    }

    func test_日本語のタイトルを文字の途中で分けて追記しても正しく読める() throws {
        let path = tempFile()
        let reader = TranscriptReader()
        let bytes = Array("{\"type\":\"ai-title\",\"aiTitle\":\"日本語\"}\n".utf8)
        // 「日」(3バイト)の2バイト目で切る
        let cut = Array("{\"type\":\"ai-title\",\"aiTitle\":\"".utf8).count + 1
        FileManager.default.createFile(atPath: path, contents: Data(bytes[..<cut]))
        XCTAssertNil(reader.summary(transcriptPath: path, cwd: nil).title)

        try appendData(Data(bytes[cut...]), to: path)
        XCTAssertEqual(reader.summary(transcriptPath: path, cwd: nil).title, "日本語")
    }

    func test_Bashの1行目が空なら空でない最初の行を使う() throws {
        let path = tempFile()
        try append("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"\\n  \\n  ls -la  \\necho\"}}]}}\n", to: path)
        XCTAssertEqual(TranscriptReader().summary(transcriptPath: path, cwd: nil).lastAction, "Bash: ls -la")
    }

    func test_大きなファイルは末尾の窓だけ読み_窓に無ければ広げる() throws {
        let path = tempFile()
        // 先頭に title、その後ろに 5MB 超のダミー行。4MB の窓には title が入らないので広げて読み直す
        let filler = "{\"type\":\"api-request-blob\",\"data\":\"" + String(repeating: "x", count: 1_000_000) + "\"}\n"
        var text = "{\"type\":\"ai-title\",\"aiTitle\":\"先頭のタイトル\"}\n"
        for _ in 0..<5 { text += filler }
        text += "{\"type\":\"last-prompt\",\"lastPrompt\":\"末尾\"}\n"
        try append(text, to: path)
        let s = TranscriptReader().summary(transcriptPath: path, cwd: nil)
        XCTAssertEqual(s.title, "先頭のタイトル")
        XCTAssertEqual(s.lastPrompt, "末尾")
    }

    func test_forgetで状態を捨てる() throws {
        let path = tempFile()
        let reader = TranscriptReader()
        try append("{\"type\":\"ai-title\",\"aiTitle\":\"A\"}\n", to: path)
        XCTAssertEqual(reader.summary(transcriptPath: path, cwd: nil).title, "A")
        reader.forget(transcriptPath: path)
        XCTAssertEqual(reader.summary(transcriptPath: path, cwd: nil).title, "A")   // 読み直しても同じ
    }
}
