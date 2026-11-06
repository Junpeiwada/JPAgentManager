import Foundation

/// 会話ログ（jsonl）から読み取った要約。読めない項目は nil（画面側で「—」を出す）
struct TranscriptSummary: Equatable {
    var title: String?        // 最後の aiTitle
    var lastPrompt: String?   // 最後の lastPrompt
    var lastAction: String?   // 最後の tool_use を整形したもの（例 "Edit: src/train/config.ts"）
    var endedWithText: Bool   // 最後の assistant の出力が tool_use ではなく文章（＝返答済み）なら true
}

/// 会話ログの追記分だけを読み、要約を返す（NFR-02）。状態は lock で守るので、背景キューに渡してよい
final class TranscriptReader: @unchecked Sendable {
    /// ファイルごとの読み取り状態
    private struct State {
        var fileID: FileID?       // デバイス番号と inode。変わったら作り直されたとみなす
        var offset: UInt64 = 0
        var title: String?
        var lastPrompt: String?
        var toolName: String?
        var toolArg: String?      // パス・コマンド・パターンの生の値
        var endedWithText = false
    }

    private struct FileID: Equatable {
        var device: UInt64
        var inode: UInt64
    }

    private var states: [String: State] = [:]
    private let lock = NSLock()

    /// 初回に末尾から読む窓の大きさと、広げる上限
    private static let initialWindow: UInt64 = 4 * 1024 * 1024
    private static let maxWindow: UInt64 = 32 * 1024 * 1024
    /// 1回の read の大きさ
    private static let chunkSize = 1024 * 1024

    func summary(transcriptPath: String, cwd: String?) -> TranscriptSummary {
        lock.lock()
        defer { lock.unlock() }

        var state = states[transcriptPath] ?? State()
        update(&state, path: transcriptPath)
        states[transcriptPath] = state

        return TranscriptSummary(
            title: state.title,
            lastPrompt: state.lastPrompt,
            lastAction: state.toolName.map { Self.format(name: $0, arg: state.toolArg, cwd: cwd) },
            endedWithText: state.endedWithText
        )
    }

    /// 使わなくなったファイルの状態を捨てる
    func forget(transcriptPath: String) {
        lock.lock()
        defer { lock.unlock() }
        states.removeValue(forKey: transcriptPath)
    }

    // MARK: - 読み取り

    private func update(_ state: inout State, path: String) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }

        var st = stat()
        guard fstat(handle.fileDescriptor, &st) == 0 else { return }
        let id = FileID(device: UInt64(bitPattern: Int64(st.st_dev)), inode: UInt64(st.st_ino))
        let size = UInt64(st.st_size)

        // 別のファイルに置き換わった、または短くなった（作り直された）ら最初から読み直す
        if let old = state.fileID, old != id || size < state.offset { state = State() }

        if state.fileID == nil {
            state.fileID = id
            readInitial(&state, handle: handle, size: size)
            return
        }
        guard size > state.offset else { return }
        state.offset = consume(handle, from: state.offset, to: size, dropFirstLine: false, into: &state)
    }

    /// 初回はファイル末尾の窓だけ読む。title か lastPrompt が窓に無ければ窓を倍々に広げる
    private func readInitial(_ state: inout State, handle: FileHandle, size: UInt64) {
        var window = Self.initialWindow
        while true {
            let start = size > window ? size - window : 0
            var fresh = State()
            fresh.fileID = state.fileID
            // 窓の先頭の不完全な1行は捨てる（直前の1バイトから読み、最初の改行までを捨てる）
            fresh.offset = start == 0
                ? consume(handle, from: 0, to: size, dropFirstLine: false, into: &fresh)
                : consume(handle, from: start - 1, to: size, dropFirstLine: true, into: &fresh)
            state = fresh
            if start == 0 || (state.title != nil && state.lastPrompt != nil) || window >= Self.maxWindow { return }
            window *= 2
        }
    }

    /// from から to までを分割して読み、改行まで届いた行だけ処理する。処理し終えた位置（絶対オフセット）を返す
    private func consume(_ handle: FileHandle, from: UInt64, to: UInt64, dropFirstLine: Bool, into state: inout State) -> UInt64 {
        guard (try? handle.seek(toOffset: from)) != nil else { return from }
        var pos = from
        var done = from
        var dropping = dropFirstLine
        var buffer = Data()
        while pos < to {
            let want = Int(min(UInt64(Self.chunkSize), to - pos))
            guard let chunk = try? handle.read(upToCount: want), !chunk.isEmpty else { break }
            pos += UInt64(chunk.count)
            buffer.append(chunk)

            // 改行で終わっていない最後の行は、行と改行が一度に書かれる前提で次回に回す
            var lineStart = buffer.startIndex
            while let nl = buffer[lineStart...].firstIndex(of: 0x0A) {
                if dropping {
                    dropping = false
                } else {
                    process(line: buffer[lineStart..<nl], into: &state)
                }
                done += UInt64(nl + 1 - lineStart)
                lineStart = nl + 1
            }
            buffer = Data(buffer[lineStart...])
        }
        return done
    }

    private func process(line: Data, into state: inout State) {
        // 巨大な行（api-request-blob など）を無駄に JSON 解析しないよう、先に type の印で絞る
        guard Self.marks.contains(where: { line.range(of: $0) != nil }) else { return }
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "ai-title":
            if let t = obj["aiTitle"] as? String, !t.isEmpty { state.title = t }
        case "last-prompt":
            if let p = obj["lastPrompt"] as? String, !p.isEmpty { state.lastPrompt = p }
            state.endedWithText = false
        case "user":
            if Self.isRealInstruction(obj) { state.endedWithText = false }
        case "assistant":
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            for block in content {
                switch block["type"] as? String {
                case "tool_use":
                    guard let name = block["name"] as? String else { continue }
                    state.toolName = name
                    state.toolArg = Self.argument(name: name, input: block["input"] as? [String: Any])
                    state.endedWithText = false
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty { state.endedWithText = true }
                default:
                    break   // thinking など
                }
            }
        default:
            break
        }
    }

    /// 本物の指示（content が文字列、または tool_result 以外のブロックを含む）か
    private static func isRealInstruction(_ obj: [String: Any]) -> Bool {
        guard let message = obj["message"] as? [String: Any] else { return false }
        if message["content"] is String { return true }
        guard let blocks = message["content"] as? [[String: Any]] else { return false }
        return blocks.contains { ($0["type"] as? String) != "tool_result" }
    }

    // 実物のログでは "type":"…" と空白なしで書かれている
    private static let marks: [Data] = ["ai-title", "last-prompt", "user", "assistant"]
        .map { Data("\"type\":\"\($0)\"".utf8) }

    // MARK: - 整形

    private static func argument(name: String, input: [String: Any]?) -> String? {
        guard let input else { return nil }
        switch name {
        case "Edit", "Write", "Read", "NotebookEdit":
            return (input["file_path"] as? String) ?? (input["notebook_path"] as? String)
        case "Bash":
            return input["command"] as? String
        case "Grep", "Glob":
            return input["pattern"] as? String
        case "AskUserQuestion":
            // 1問目の本文だけ出す。2問以上あれば残りの数を添える
            guard let questions = input["questions"] as? [[String: Any]],
                  let first = questions.first?["question"] as? String, !first.isEmpty else { return nil }
            return questions.count > 1 ? "\(first)（他\(questions.count - 1)問）" : first
        default:
            return nil
        }
    }

    private static func format(name: String, arg: String?, cwd: String?) -> String {
        var text = name
        if var value = arg, !value.isEmpty {
            switch name {
            case "Edit", "Write", "Read", "NotebookEdit":
                if let cwd, !cwd.isEmpty {
                    let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
                    if value.hasPrefix(base) { value = String(value.dropFirst(base.count)) }
                }
            case "Bash":
                // 空でない最初の行を、前後の空白を落として使う
                value = value.split(separator: "\n").lazy
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty } ?? ""
            default:
                break
            }
            if !value.isEmpty {
                let label = name == "AskUserQuestion" ? "質問" : name
                text = "\(label): \(value)"
            }
        }
        let limit = 80
        if text.count > limit { text = String(text.prefix(limit)) + "…" }
        return text
    }
}
