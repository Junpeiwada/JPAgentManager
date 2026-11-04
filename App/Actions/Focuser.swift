import Foundation

/// 前面化できなかった理由
enum FocusError: Error, Equatable {
    case notVSCode(String?)
    case folderMissing(String)
    case vscodeMissing
    case launchFailed(String)
    case noResponse

    var message: String {
        switch self {
        case .notVSCode: return "VSCode 以外（CLI など）のセッションは前に出せません"
        case .folderMissing(let path): return "作業フォルダが見つかりません: \(path)"
        case .vscodeMissing: return "VSCode が見つかりません"
        case .launchFailed(let detail): return "VSCode を開けませんでした: \(detail)"
        case .noResponse: return "VSCode の応答がありません（開いている可能性があります）"
        }
    }
}

/// セッションの作業フォルダを開いている VSCode の窓を前に出す。
/// 重いので、メインスレッドを止めないよう背景のキューから呼ぶこと
struct Focuser {
    var codeCLI: URL = URL(fileURLWithPath: "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code")
    var fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    /// 作業フォルダがディレクトリとして存在するか
    var directoryExists: (String) -> Bool = {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
    }
    var run: (URL, [String]) throws -> Int32 = { try Focuser.runProcess($0, $1, timeout: 5) }

    func focus(_ session: Session) -> Result<Void, FocusError> {
        guard session.entrypoint == "claude-vscode" else { return .failure(.notVSCode(session.entrypoint)) }
        // "-" 始まりの値がオプションとして解釈されないよう、絶対パスだけを通す
        let cwd = (session.cwd as NSString).standardizingPath
        guard cwd.hasPrefix("/"), directoryExists(cwd) else { return .failure(.folderMissing(cwd)) }

        // code コマンドは PATH に無いのでフルパスで呼ぶ。無ければ open で代用する
        let url: URL
        let args: [String]
        if fileExists(codeCLI.path) {
            url = codeCLI
            args = [cwd]
        } else {
            url = URL(fileURLWithPath: "/usr/bin/open")
            args = ["-b", "com.microsoft.VSCode", cwd]
        }
        do {
            let code = try run(url, args)
            if code == 0 { return .success(()) }
            // open も失敗した（VSCode 自体が無い）場合
            if url.path == "/usr/bin/open" { return .failure(.vscodeMissing) }
            return .failure(.launchFailed("終了コード \(code)"))
        } catch let error as FocusError {
            return .failure(error)
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }
    }

    /// Process で起動して終了を待つ。タイムアウトしたら terminate して .noResponse を投げる
    static func runProcess(_ url: URL, _ args: [String], timeout: TimeInterval) throws -> Int32 {
        let process = Process()
        process.executableURL = url
        process.arguments = args
        // VSCode の統合ターミナルから起動されても、その端末の窓へ要求が飛ばないようにする
        process.environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("VSCODE_") && $0.key != "ELECTRON_RUN_AS_NODE"
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw FocusError.noResponse
        }
        return process.terminationStatus
    }
}
