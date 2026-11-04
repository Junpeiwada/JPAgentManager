import Darwin
import Foundation

// Claude Code のフック入力から状態の判定に要る項目だけを取り出し、
// 時刻と claude の PID を足して events.jsonl に 1 行追記する補助プログラム。
// どんなエラーでも終了コード 0、stdout / stderr には何も出さない（Claude Code の動作を妨げないため）。

/// input に残す項目（tool_input / tool_response / prompt などの本文は残さない）
let keptKeys = ["hook_event_name", "session_id", "cwd", "transcript_path", "notification_type", "message", "tool_name"]
let messageLimit = 500
let rotateSize: off_t = 5 * 1024 * 1024
let readTimeoutMs: Int = 1000

// MARK: stdin

/// stdin を全部読む。1 秒で終わらなければ nil
func readStdin() -> Data? {
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 256 * 1024)
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(readTimeoutMs) * 1_000_000
    while true {
        let now = DispatchTime.now().uptimeNanoseconds
        if now >= deadline { return nil }
        let remaining = Int32((deadline - now) / 1_000_000) + 1
        var pfd = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
        let r = poll(&pfd, 1, remaining)
        if r < 0 { if errno == EINTR { continue }; return nil }
        if r == 0 { return nil }
        let n = buf.withUnsafeMutableBytes { read(0, $0.baseAddress, $0.count) }
        if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; return nil }
        if n == 0 { return data }
        data.append(buf, count: n)
    }
}

// MARK: input の絞り込み

/// 許可した項目だけの JSON（1 行）。最上位がオブジェクトでなければ "null"
func filteredInputJSON(_ data: Data) -> Data {
    let null = Data("null".utf8)
    guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return null }
    var kept: [String: Any] = [:]
    for key in keptKeys {
        guard let value = obj[key] as? String else { continue }
        kept[key] = key == "message" ? String(value.prefix(messageLimit)) : value
    }
    return (try? JSONSerialization.data(withJSONObject: kept, options: [.withoutEscapingSlashes, .sortedKeys])) ?? null
}

// MARK: claude の PID

func pidPath(_ pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    return n > 0 ? String(cString: buf) : nil
}

func parentPID(_ pid: pid_t) -> pid_t? {
    var bsd = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
    return pid_t(bsd.pbi_ppid)
}

/// 親をたどって claude の PID を探す（最大 16 段）。見つからなければ nil
func findClaudePID() -> pid_t? {
    var pid = getppid()
    for _ in 0..<16 {
        guard pid > 1 else { return nil }
        if let path = pidPath(pid) {
            let base = path.split(separator: "/").last.map(String.init) ?? path
            if path.hasSuffix("/native-binary/claude") || base == "claude" { return pid }
        }
        guard let next = parentPID(pid) else { return nil }
        pid = next
    }
    return nil
}

// MARK: 追記

func eventsFilePath() -> String {
    if let path = ProcessInfo.processInfo.environment["JPAM_EVENTS_FILE"], !path.isEmpty { return path }
    return NSHomeDirectory() + "/Library/Application Support/JPAgentManager/events.jsonl"
}

func rotatedPath(_ path: String) -> String {
    path.hasSuffix(".jsonl") ? String(path.dropLast(".jsonl".count)) + ".1.jsonl" : path + ".1.jsonl"
}

func ensureDirectory(of path: String) {
    let dir = (path as NSString).deletingLastPathComponent
    guard !dir.isEmpty else { return }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
}

/// ロックを取って 1 行を書く。ロック待ちの間に他のプロセスがローテーションした場合は開き直す
func append(_ line: Data, to path: String) {
    var rotated = false
    for _ in 0..<8 {
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        if fd < 0 { return }
        defer { close(fd) }
        if flock(fd, LOCK_EX) != 0 { return }

        // 開いたファイルがまだパスの指す実体か（待っている間に rename されていないか）
        var byFD = stat(), byPath = stat()
        guard fstat(fd, &byFD) == 0 else { return }
        if stat(path, &byPath) != 0 || byPath.st_ino != byFD.st_ino || byPath.st_dev != byFD.st_dev { continue }

        if !rotated && byFD.st_size > rotateSize {
            rotated = true
            _ = rename(path, rotatedPath(path))
            continue    // 開き直して、新しい fd でもロックを取る
        }
        writeAll(fd, line)
        return
    }
}

func writeAll(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if n < 0 { if errno == EINTR { continue }; return }
            offset += n
        }
    }
}

// MARK: 本体

func run() {
    guard let data = readStdin() else { return }
    let ts = Date().timeIntervalSince1970
    let input = filteredInputJSON(data)
    let pid = findClaudePID().map { String($0) } ?? "null"

    var line = Data("{\"ts\":\(String(format: "%.3f", ts)),\"claude_pid\":\(pid),\"input\":".utf8)
    line.append(input)
    line.append(Data("}\n".utf8))

    let path = eventsFilePath()
    ensureDirectory(of: path)
    append(line, to: path)
}

signal(SIGPIPE, SIG_IGN)
run()
exit(0)
