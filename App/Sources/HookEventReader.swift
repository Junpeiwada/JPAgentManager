import Foundation

/// フックが events.jsonl に書いた1行を解釈したもの
struct HookEvent: Equatable {
    var ts: Date
    var claudePID: Int32?
    var name: String            // hook_event_name（無ければその行は捨てる）
    var sessionID: String?
    var cwd: String?
    var transcriptPath: String?
    var notificationType: String?
    var message: String?
    var toolName: String?       // PreToolUse/PostToolUse の tool_name（あれば）
}

/// events.jsonl の末尾（追記分）だけを読み、変化を監視する（NFR-02）
/// readNew は呼び出し側が1つのキューから呼ぶ前提で、内部ロックは持たない
final class HookEventReader {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/JPAgentManager/events.jsonl")
    }

    private let fileURL: URL
    private var offset: UInt64 = 0
    private var inode: UInt64?

    // 監視用（メインスレッドでだけ触る）
    private var fileSource: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?
    private var watchedInode: UInt64?
    private var onChange: (() -> Void)?

    init(fileURL: URL = HookEventReader.defaultURL) {
        self.fileURL = fileURL
    }

    // 別スレッドでの解放でも安全なよう self を触らず cancel だけ呼ぶ（fd は cancel handler で閉じる）
    deinit {
        fileSource?.cancel()
        dirSource?.cancel()
    }

    // MARK: - 読み取り

    /// 前回の続きから、完全な行だけを読む
    /// 初回（offset 0）は既存の全行を読む。起動時に今の状態を組み立てるための意図した動作
    func readNew() -> [HookEvent] {
        guard let handle = FileHandle(forReadingAtPath: fileURL.path) else { return [] }
        defer { try? handle.close() }

        var st = stat()
        guard fstat(handle.fileDescriptor, &st) == 0 else { return [] }
        let currentInode = UInt64(st.st_ino)
        let size = UInt64(st.st_size)

        var events: [HookEvent] = []

        // ローテーションされた（inode が変わった）ら、改名後の旧ファイルに残った分を先に読む
        if let inode, inode != currentInode {
            events += readRotatedTail(previousInode: inode)
            offset = 0
        }
        if size < offset { offset = 0 }
        inode = currentInode
        guard size > offset else { return events }

        events += readLines(handle: handle)
        return events
    }

    /// 同じフォルダの events.1.jsonl が前回のファイルなら、前回の offset 以降の完全な行を読む。
    /// 2世代以上進んで一致しないときは諦める
    private func readRotatedTail(previousInode: UInt64) -> [HookEvent] {
        // フック（Hooks/jpam-hook.sh の ${file%.jsonl}.1.jsonl）と同じ名前の作り方にする
        let name = fileURL.lastPathComponent
        let rotatedName = name.hasSuffix(".jsonl")
            ? String(name.dropLast(".jsonl".count)) + ".1.jsonl"
            : name + ".1.jsonl"
        let rotatedURL = fileURL.deletingLastPathComponent().appendingPathComponent(rotatedName)
        guard let handle = FileHandle(forReadingAtPath: rotatedURL.path) else { return [] }
        defer { try? handle.close() }

        var st = stat()
        guard fstat(handle.fileDescriptor, &st) == 0,
              UInt64(st.st_ino) == previousInode,
              UInt64(st.st_size) > offset else { return [] }
        return readLines(handle: handle)
    }

    /// handle の offset から末尾までの完全な行を読み、offset を進める
    private func readLines(handle: FileHandle) -> [HookEvent] {
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return [] }

        // 最後の改行までが完全な行。残りは次回に回す
        guard let lastNL = data.lastIndex(of: 0x0A) else { return [] }
        let complete = data[data.startIndex...lastNL]
        offset += UInt64(complete.count)

        var events: [HookEvent] = []
        for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let event = Self.parse(Data(line)) { events.append(event) }
        }
        return events
    }

    private static func parse(_ line: Data) -> HookEvent? {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let input = obj["input"] as? [String: Any],
              let name = input["hook_event_name"] as? String, !name.isEmpty else { return nil }
        // ts が無い・数値でない行は読んだ時刻で埋める
        let date = (obj["ts"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date()
        let pid = (obj["claude_pid"] as? NSNumber).map { Int32(truncatingIfNeeded: $0.intValue) }
        return HookEvent(
            ts: date,
            claudePID: pid,
            name: name,
            sessionID: input["session_id"] as? String,
            cwd: input["cwd"] as? String,
            transcriptPath: input["transcript_path"] as? String,
            notificationType: input["notification_type"] as? String,
            message: input["message"] as? String,
            toolName: input["tool_name"] as? String
        )
    }

    // MARK: - 監視

    /// ファイルの変化で onChange をメインスレッドで呼ぶ。ファイルがまだ無い・作り直された場合も追う
    func startWatching(onChange: @escaping () -> Void) {
        let setup = { [self] in
            stopWatchingOnMain()
            self.onChange = onChange
            watchDirectory()
            watchFile()
        }
        if Thread.isMainThread { setup() } else { DispatchQueue.main.async(execute: setup) }
    }

    func stopWatching() {
        if Thread.isMainThread { stopWatchingOnMain() } else { DispatchQueue.main.async { [self] in stopWatchingOnMain() } }
    }

    private func stopWatchingOnMain() {
        fileSource?.cancel(); fileSource = nil
        dirSource?.cancel(); dirSource = nil
        watchedInode = nil
        onChange = nil
    }

    private func watchDirectory() {
        let dirURL = fileURL.deletingLastPathComponent()
        // フォルダが無いと監視が張れないので先に作る（アプリ自身の Application Support 内）
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let fd = open(dirURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in self?.handleChange() }
        source.setCancelHandler { close(fd) }
        source.resume()
        dirSource = source
    }

    private func watchFile() {
        fileSource?.cancel(); fileSource = nil
        watchedInode = nil
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        var st = stat()
        if fstat(fd, &st) == 0 { watchedInode = UInt64(st.st_ino) }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in self?.handleChange() }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
    }

    private func handleChange() {
        // 作り直し・削除・新規作成のとき、ファイル側の監視を張り直す
        var st = stat()
        let currentInode: UInt64? = stat(fileURL.path, &st) == 0 ? UInt64(st.st_ino) : nil
        if currentInode != watchedInode { watchFile() }
        onChange?()
    }
}
