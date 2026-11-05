import Foundation

/// リポジトリの状態。ローカルの変更数と、上流ブランチとのコミット差
struct GitStatus: Hashable {
    var upstream: String? = nil    // 上流ブランチ（例 origin/main）。無ければ nil
    var ahead: Int = 0             // 未プッシュのコミット数
    var behind: Int = 0            // プルが必要なコミット数
    var changedFiles: Int = 0      // 変更ファイル数（未追跡を含む）
    var fetchFailed: Bool = false  // 直近の fetch が失敗した（コミット差が古いかもしれない）

    /// マウスを乗せたときの説明
    var helpText: String {
        var parts: [String] = []
        if upstream == nil {
            parts.append("上流ブランチなし")
        } else {
            if behind > 0 { parts.append("プルが必要 \(behind) コミット") }
            if ahead > 0 { parts.append("未プッシュ \(ahead) コミット") }
            if behind == 0 && ahead == 0 { parts.append("リモートと同じ") }
        }
        if changedFiles > 0 { parts.append("変更 \(changedFiles) ファイル") }
        if fetchFailed { parts.append("リモートを確認できませんでした") }
        return parts.joined(separator: " / ")
    }
}

/// git status と git fetch を実行する。認証の入力は求めず、できなければ失敗として返す
enum GitStatusReader {
    private static let statusTimeout: TimeInterval = 5
    private static let fetchTimeout: TimeInterval = 60

    /// git 管理外・git が無い・タイムアウトのときは nil
    static func status(root: String) -> GitStatus? {
        guard GitInfo.gitAvailable else { return nil }
        let result = run(["-C", root, "--no-optional-locks", "status", "--porcelain=v2", "--branch"],
                         timeout: statusTimeout, capturesOutput: true)
        guard result.succeeded, let output = result.output else { return nil }
        return parse(output)
    }

    /// リモート追跡ブランチを更新する。成功なら true
    /// FETCH_HEAD は書かない（Claude Code が同時に実行する git pull の結果を上書きしないため）
    static func fetch(root: String) -> Bool {
        guard GitInfo.gitAvailable else { return false }
        return run(["-C", root, "fetch", "--quiet", "--no-write-fetch-head",
                    "--no-auto-maintenance", "--no-recurse-submodules"],
                   timeout: fetchTimeout, capturesOutput: false).succeeded
    }

    /// `git status --porcelain=v2 --branch` の出力を解釈する
    static func parse(_ output: String) -> GitStatus {
        var status = GitStatus()
        for line in output.split(separator: "\n") {
            if line.hasPrefix("# branch.upstream ") {
                status.upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                // 形式: # branch.ab +<ahead> -<behind>
                let fields = line.split(separator: " ")
                if fields.count == 4 {
                    status.ahead = Int(fields[2].dropFirst()) ?? 0
                    status.behind = Int(fields[3].dropFirst()) ?? 0
                }
            } else if !line.hasPrefix("#") {
                status.changedFiles += 1
            }
        }
        return status
    }

    private final class OutputBox: @unchecked Sendable {
        var data = Data()
    }

    private static func run(_ args: [String], timeout: TimeInterval,
                            capturesOutput: Bool) -> (succeeded: Bool, output: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        // アプリの裏で認証の入力を求めない
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = "/usr/bin/true"
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        environment["GCM_INTERACTIVE"] = "never"
        process.environment = environment
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let pipe = capturesOutput ? Pipe() : nil
        process.standardOutput = pipe ?? FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return (false, nil) }

        // 変更が多いと出力がパイプの容量を超えるので、終了を待つ間も読み続ける
        let box = OutputBox()
        let readFinished = DispatchSemaphore(value: 0)
        if let pipe {
            DispatchQueue.global(qos: .utility).async {
                box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                readFinished.signal()
            }
        } else {
            readFinished.signal()
        }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return (false, nil)
        }
        guard process.terminationStatus == 0 else { return (false, nil) }
        guard readFinished.wait(timeout: .now() + 1) == .success else { return (false, nil) }
        return (true, capturesOutput ? String(data: box.data, encoding: .utf8) : nil)
    }
}
