import Darwin
import Foundation

/// ~/.claude/sessions/<PID>.json に書かれた状態
enum RegistryStatus: Equatable {
    case busy
    case shell                      // 返答は済んだが、バックグラウンドの Bash（run_in_background）がまだ動いている
    case idle
    case waiting(reason: String?)   // "permission prompt" / "input needed"
    case unknown(String?)           // 想定外の文字列、または欠け
}

struct RegistryEntry: Equatable, Identifiable {
    var id: String { sessionID }
    var pid: Int32
    var sessionID: String
    var cwd: String
    var name: String?
    var kind: String?           // "interactive" など
    var entrypoint: String?     // "claude-vscode" など（前面化できるのは claude-vscode だけ）
    var status: RegistryStatus
    var statusUpdatedAt: Date?
    var startedAt: Date?
}

/// 1回の読み込み結果。「0件」と「読めない」を区別するために使う
struct RegistrySnapshot: Equatable {
    var entries: [RegistryEntry]     // 生きているセッション（pid 昇順）
    var unreadableFiles: Int         // 読めなかった .json の数（壊れ・必須欠け・不正な sessionId・普通でないファイル・巨大ファイル）
    var directoryReadable: Bool      // sessions フォルダを一覧できたか
}

/// Claude Code 自身が書くセッションファイルを読む（読むだけ。書き込み・削除・ロックはしない）
/// 読み込みのキャッシュは lock で守り、監視まわりはメインスレッドだけで触るので、背景キューに渡してよい
final class SessionRegistry: @unchecked Sendable {
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
    }
    static var defaultProjectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    /// これを超えるセッションファイルは読まない
    static let maxFileSize = 64 * 1024
    /// 会話ログが見つからなかったとき、全体の探索を飛ばす秒数
    static let transcriptSearchBackoff: TimeInterval = 30
    /// onChange の間引き（最後の変化からこの秒数後に1回）
    static let watchDebounce: TimeInterval = 0.3

    private struct Parsed {
        var entry: RegistryEntry
        var procStart: Date?
    }

    private enum ParseResult {
        case ok(Parsed)
        case brokenJSON     // 書き込み途中などで JSON として読めない
        case rejected       // JSON だが必須欠け・不正値
    }

    private struct Stamp: Equatable {
        var sec: Int
        var nsec: Int
        var size: Int
        var inode: UInt64
    }

    private struct CacheItem {
        var stamp: Stamp
        var parsed: Parsed?     // nil は読めなかったファイル。JSON 解析に失敗したときは前回の成功結果が入る
    }

    private let directory: URL
    private let projectsDirectory: URL
    private let isAlive: (Int32, Date?) -> Bool
    private let now: () -> Date

    private let lock = NSLock()
    private var cache: [String: CacheItem] = [:]
    private var transcriptCache: [String: URL] = [:]
    private var transcriptNotFoundAt: [String: Date] = [:]

    // 監視まわりはメインスレッドからだけ触る
    private var source: DispatchSourceFileSystemObject?
    private var changeHandler: (() -> Void)?
    private var pendingNotify: DispatchWorkItem?

    init(directory: URL = SessionRegistry.defaultDirectory,
         projectsDirectory: URL = SessionRegistry.defaultProjectsDirectory,
         isAlive: @escaping (Int32, Date?) -> Bool = SessionRegistry.processIsAlive,
         now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.projectsDirectory = projectsDirectory
        self.isAlive = isAlive
        self.now = now
    }

    deinit {
        // self を捕まえない。cancel だけ行う
        source?.cancel()
        pendingNotify?.cancel()
    }

    /// キャッシュしているセッションファイルの数（テスト用）
    var cachedFileCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    // MARK: - 読み込み

    /// 生きているセッションだけ（pid 昇順）
    func read() -> [RegistryEntry] {
        readSnapshot().entries
    }

    func readSnapshot() -> RegistrySnapshot {
        lock.lock()
        defer { lock.unlock() }

        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return RegistrySnapshot(entries: [], unreadableFiles: 0, directoryReadable: false)
        }

        var newCache: [String: CacheItem] = [:]
        var best: [String: Parsed] = [:]   // sessionID -> 採用候補
        var unreadable = 0

        for name in names where !name.hasPrefix(".") && (name as NSString).pathExtension == "json" {
            let url = directory.appendingPathComponent(name)
            var st = stat()
            // lstat: シンボリックリンクは辿らない
            guard lstat(url.path, &st) == 0 else { continue }   // 列挙後に消えた
            guard (st.st_mode & S_IFMT) == S_IFREG, Int(st.st_size) <= Self.maxFileSize else {
                unreadable += 1
                continue
            }
            let stamp = Stamp(sec: Int(st.st_mtimespec.tv_sec), nsec: Int(st.st_mtimespec.tv_nsec),
                              size: Int(st.st_size), inode: UInt64(st.st_ino))

            let item: CacheItem
            if let old = cache[name], old.stamp == stamp {
                item = old
            } else {
                let stem = (name as NSString).deletingPathExtension
                let result: ParseResult = (try? Data(contentsOf: url)).map { Self.parse($0, fileStem: stem) } ?? .brokenJSON
                switch result {
                case .ok(let p): item = CacheItem(stamp: stamp, parsed: p)
                case .brokenJSON: item = CacheItem(stamp: stamp, parsed: cache[name]?.parsed)   // 前回の成功結果を使う
                case .rejected: item = CacheItem(stamp: stamp, parsed: nil)
                }
            }
            newCache[name] = item

            guard let parsed = item.parsed else {
                unreadable += 1
                continue
            }
            // PID の生死は毎回確かめる（キャッシュしない）
            guard isAlive(parsed.entry.pid, parsed.procStart) else { continue }
            if let current = best[parsed.entry.sessionID], !Self.isNewer(parsed.entry, than: current.entry) { continue }
            best[parsed.entry.sessionID] = parsed
        }
        cache = newCache
        return RegistrySnapshot(entries: best.values.map(\.entry).sorted { $0.pid < $1.pid },
                                unreadableFiles: unreadable, directoryReadable: true)
    }

    /// statusUpdatedAt、同じなら startedAt、それも同じなら pid の大きいほうを新しいとする
    private static func isNewer(_ a: RegistryEntry, than b: RegistryEntry) -> Bool {
        let au = a.statusUpdatedAt ?? .distantPast, bu = b.statusUpdatedAt ?? .distantPast
        if au != bu { return au > bu }
        let asd = a.startedAt ?? .distantPast, bsd = b.startedAt ?? .distantPast
        if asd != bsd { return asd > bsd }
        return a.pid > b.pid
    }

    /// sessionId として受け付けるのは [A-Za-z0-9-] だけ（パスに使うため）
    private static func isValidSessionID(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2D
        }
    }

    private static func parse(_ data: Data, fileStem: String) -> ParseResult {
        guard let any = try? JSONSerialization.jsonObject(with: data) else { return .brokenJSON }
        guard let obj = any as? [String: Any] else { return .rejected }
        guard let pidNum = obj["pid"] as? NSNumber,
              CFGetTypeID(pidNum) != CFBooleanGetTypeID(),
              let pid = Int32(exactly: pidNum.doubleValue), pid > 0,
              String(pid) == fileStem,
              let sessionID = obj["sessionId"] as? String, isValidSessionID(sessionID),
              let cwd = obj["cwd"] as? String, !cwd.isEmpty else { return .rejected }

        func date(_ key: String) -> Date? {
            guard let ms = (obj[key] as? NSNumber)?.doubleValue else { return nil }
            return Date(timeIntervalSince1970: ms / 1000)
        }

        let rawStatus = obj["status"] as? String
        let status: RegistryStatus
        switch rawStatus {
        case "busy": status = .busy
        case "shell": status = .shell
        case "idle": status = .idle
        case "waiting": status = .waiting(reason: obj["waitingFor"] as? String)
        default: status = .unknown(rawStatus)
        }

        let entry = RegistryEntry(
            pid: pid, sessionID: sessionID, cwd: cwd,
            name: obj["name"] as? String,
            kind: obj["kind"] as? String,
            entrypoint: obj["entrypoint"] as? String,
            status: status,
            statusUpdatedAt: date("statusUpdatedAt"),
            startedAt: date("startedAt"))
        return .ok(Parsed(entry: entry, procStart: (obj["procStart"] as? String).flatMap(parseProcStart)))
    }

    /// "Fri Oct 30 08:10:48 2026" / "Fri Oct  3 08:10:48 2026"（UTC）。曜日は読み捨てる
    private static func parseProcStart(_ s: String) -> Date? {
        let parts = s.split(separator: " ")
        guard parts.count == 5 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MMM d HH:mm:ss yyyy"
        return f.date(from: parts.dropFirst().joined(separator: " "))
    }

    // MARK: - 会話ログ

    /// 会話ログの場所。無ければ nil
    func transcriptURL(for entry: RegistryEntry) -> URL? {
        guard Self.isValidSessionID(entry.sessionID) else { return nil }
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        if let cached = transcriptCache[entry.sessionID], fm.fileExists(atPath: cached.path) {
            return cached
        }
        transcriptCache[entry.sessionID] = nil

        let fileName = "\(entry.sessionID).jsonl"
        // Claude Code は UTF-16 単位で英数字以外を "-" にする
        let mapped = String(entry.cwd.utf16.map { unit -> Character in
            let isAlnum = (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
            return isAlnum ? Character(UnicodeScalar(UInt8(unit))) : "-"
        })
        // 規則どおりの場所は毎回確かめる
        let expected = projectsDirectory.appendingPathComponent(mapped).appendingPathComponent(fileName)
        if fm.fileExists(atPath: expected.path) {
            transcriptCache[entry.sessionID] = expected
            transcriptNotFoundAt[entry.sessionID] = nil
            return expected
        }
        // 規則が崩れた場合の全体探索は、見つからなかった後しばらく飛ばす
        let current = now()
        if let missedAt = transcriptNotFoundAt[entry.sessionID],
           current.timeIntervalSince(missedAt) < Self.transcriptSearchBackoff,
           current >= missedAt {
            return nil
        }
        let dirs = (try? fm.contentsOfDirectory(at: projectsDirectory, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let candidate = dir.appendingPathComponent(fileName)
            if fm.fileExists(atPath: candidate.path) {
                transcriptCache[entry.sessionID] = candidate
                transcriptNotFoundAt[entry.sessionID] = nil
                return candidate
            }
        }
        transcriptNotFoundAt[entry.sessionID] = current
        return nil
    }

    // MARK: - 監視

    /// フォルダの変化で onChange を呼ぶ（メインスレッド。最後の変化から 0.3 秒後に1回へ間引く）。
    /// 役割は「セッションの増減を早く拾う」こと。Claude Code は <PID>.json を置き換えずに
    /// 上書きするので、状態の変化ではフォルダの監視は発火しない。状態の変化は呼び出し側の
    /// 定期的な read() で拾うこと。sessions フォルダが無いときは監視を張らない
    /// （~/.claude/ に書かないため作らない）。フォルダが後から現れた場合は、
    /// startWatching の呼び直しか rewatchIfNeeded() で張り直す。メインスレッドから呼ぶ。
    func startWatching(onChange: @escaping () -> Void) {
        stopWatching()
        changeHandler = onChange
        attachSource()
    }

    func stopWatching() {
        source?.cancel()
        source = nil
        pendingNotify?.cancel()
        pendingNotify = nil
        changeHandler = nil
    }

    /// 監視を頼んだのに張れていない（フォルダが無かった・消えた）ときに張り直す。定期的な read と一緒に呼ぶ想定
    func rewatchIfNeeded() {
        guard changeHandler != nil, source == nil else { return }
        attachSource()
    }

    private func attachSource() {
        source?.cancel()
        source = nil
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete, .attrib], queue: .main)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src, self.source === src else { return }
            if !src.data.isDisjoint(with: [.delete, .rename]) {
                // 古い vnode を見続けないよう張り直す（フォルダが無ければ source は nil になる）
                self.attachSource()
            }
            self.scheduleNotify()
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    private func scheduleNotify() {
        pendingNotify?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.changeHandler?()
        }
        pendingNotify = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.watchDebounce, execute: work)
    }

    // MARK: - 生死判定

    /// kill(pid,0) が 0 か EPERM、かつ procStart があれば libproc の起動時刻と ±2秒で一致
    static func processIsAlive(pid: Int32, procStart: Date?) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) != 0 && errno != EPERM { return false }
        guard let procStart else { return true }
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return false }
        let start = TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1e6
        return abs(start - procStart.timeIntervalSince1970) <= 2
    }
}
