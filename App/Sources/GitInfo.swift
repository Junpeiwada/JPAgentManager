import Foundation

/// 作業フォルダから git のルートとブランチを取る。同じ cwd の結果は 30 秒キャッシュする
enum GitInfo {
    struct Info: Equatable {
        var root: String
        var branch: String?
    }

    private static let ttl: TimeInterval = 30
    private static let timeout: TimeInterval = 2
    private static let lock = NSLock()
    private static var cache: [String: (at: Date, info: Info?)] = [:]

    /// 現在時刻（テストでキャッシュの期限を試すために差し替えられる）
    static var now: () -> Date = { Date() }
    /// git に問い合わせた回数（テスト用）
    static var queryCount = 0

    /// Command Line Tools が無い Mac では /usr/bin/git の起動でインストールのダイアログが出るため、
    /// 最初に一度だけ xcode-select -p の成否で git が使えるかを判定する
    static let gitAvailable: Bool = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }()

    /// git 管理外・git が無い・タイムアウトのときは nil
    static func info(for cwd: String) -> Info? {
        guard gitAvailable else { return nil }

        lock.lock()
        let current = now()
        // 期限切れのエントリを掃除する
        cache = cache.filter { current.timeIntervalSince($0.value.at) < ttl }
        if let hit = cache[cwd] {
            lock.unlock()
            return hit.info
        }
        queryCount += 1
        lock.unlock()

        // git 実行中はロックを持たない（他の cwd の問い合わせを止めない）
        let (result, cacheable) = query(cwd)

        // タイムアウトしたときはキャッシュしない（次回すぐ取り直す）
        if cacheable {
            lock.lock()
            cache[cwd] = (now(), result)
            lock.unlock()
        }
        return result
    }

    private static func query(_ cwd: String) -> (info: Info?, cacheable: Bool) {
        let rootOut = run(["-C", cwd, "rev-parse", "--show-toplevel"])
        if rootOut.timedOut { return (nil, false) }
        guard let root = rootOut.text, !root.isEmpty else { return (nil, true) }
        // コミットが無くても取れる。detached HEAD では失敗するので nil
        let branchOut = run(["-C", cwd, "symbolic-ref", "--short", "-q", "HEAD"])
        if branchOut.timedOut { return (nil, false) }
        let branch = (branchOut.text?.isEmpty == false) ? branchOut.text : nil
        return (Info(root: root, branch: branch), true)
    }

    /// git を実行して標準出力の先頭行を返す。失敗は text が nil、タイムアウトは timedOut が true
    private static func run(_ args: [String]) -> (text: String?, timedOut: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return (nil, false) }

        // 出力が小さいので、終了待ちの間にパイプが詰まる心配は実質ない
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return (nil, true)
        }
        guard process.terminationStatus == 0 else { return (nil, false) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return (nil, false) }
        return (text.split(separator: "\n").first.map(String.init), false)
    }
}
