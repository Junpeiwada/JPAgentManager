import AppKit
import Foundation

/// Claude Code のフック（~/.claude/settings.json）への登録と解除。
/// 既存のキー・他のツールのフックは消さない。書き換え前に必ず退避を取る。
struct HookInstaller {
    /// 登録するイベント。検証結果で絞るときはここだけ変える。
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd"]
    /// matcher "*" を付けるイベント
    static let matcherEvents: Set<String> = ["PreToolUse", "PostToolUse"]
    /// 自分の登録かどうかを command から判定する目印
    static let scriptName = "jpam-hook"

    /// 退避ファイルを残す数（新しい方から）
    static let backupLimit = 5

    enum InstallError: LocalizedError {
        case unreadableSettings(String)
        case unexpectedStructure(String)
        case modifiedConcurrently
        case bundledHelperMissing

        var errorDescription: String? {
            switch self {
            case .unreadableSettings(let detail): return "settings.json を JSON として読めませんでした（\(detail)）。何も変更していません。"
            case .unexpectedStructure(let detail): return "settings.json の \(detail) の形が想定と違います。何も変更していません。"
            case .modifiedConcurrently: return "settings.json が処理中に別のプロセスから変更されたため、書き込みを中止しました。もう一度お試しください。"
            case .bundledHelperMissing: return "アプリに同梱されたフックの補助プログラムが見つかりません。"
            }
        }
    }

    var settingsURL: URL
    var helperInstallURL: URL
    var bundledHelperURL: URL?

    init(
        settingsURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json"),
        helperInstallURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/JPAgentManager/jpam-hook"),
        bundledHelperURL: URL? = Bundle.main.url(forAuxiliaryExecutable: "jpam-hook")
    ) {
        self.settingsURL = settingsURL
        self.helperInstallURL = helperInstallURL
        self.bundledHelperURL = bundledHelperURL
    }

    // MARK: 判定

    /// 全イベントに自分の登録（command が現在の値と一致）があれば true。読めない・無いときは false。
    func isInstalled() -> Bool {
        guard let loaded = try? loadSettings(),
              let hooks = try? Self.hooksObject(in: loaded.root) else { return false }
        let command = expectedCommand
        return Self.events.allSatisfy { event in
            guard let entries = hooks[event] as? [Any] else { return false }
            return entries.contains { element in
                guard let entry = element as? [String: Any], let inner = entry["hooks"] as? [Any] else { return false }
                return inner.contains { ($0 as? [String: Any])?["command"] as? String == command }
            }
        }
    }

    // MARK: 登録

    func install() throws {
        guard let bundled = bundledHelperURL, FileManager.default.fileExists(atPath: bundled.path) else {
            throw InstallError.bundledHelperMissing
        }
        // settings.json が壊れている・形が想定外なら補助プログラムも置かずに止める
        let loaded = try loadSettings()
        var root = loaded.root
        var hooks = try Self.hooksObject(in: root) ?? [:]

        var changed = false
        for event in Self.events {
            var entries = try Self.eventEntries(hooks, event)
            if entries.contains(where: Self.isOwn) {
                // 自分の登録があれば、command が古いときだけ書き換える
                if refreshOwnCommand(&entries) {
                    hooks[event] = entries
                    changed = true
                }
                continue
            }
            var entry: [String: Any] = [
                "hooks": [["type": "command", "command": expectedCommand]]
            ]
            if Self.matcherEvents.contains(event) { entry["matcher"] = "*" }
            entries.append(entry)
            hooks[event] = entries
            changed = true
        }
        guard changed else { return }
        root["hooks"] = hooks
        try copyHelper(from: bundled)
        try commit(root, loaded: loaded)
    }

    // MARK: 解除

    func uninstall() throws {
        let loaded = try loadSettings()
        var root = loaded.root
        guard var hooks = try Self.hooksObject(in: root) else { return }
        var changed = false
        for event in Array(hooks.keys) {
            // 自分が登録しないイベントの想定外の形は触らずに残す
            guard let entries = hooks[event] as? [Any] else {
                if Self.events.contains(event) { throw InstallError.unexpectedStructure("hooks.\(event)") }
                continue
            }
            var newEntries: [Any] = []
            for element in entries {
                guard var entry = element as? [String: Any], var inner = entry["hooks"] as? [Any] else {
                    newEntries.append(element)
                    continue
                }
                let before = inner.count
                inner.removeAll { ($0 as? [String: Any]).map(Self.isOwnCommand) == true }
                if inner.count == before { newEntries.append(element); continue }
                changed = true
                if inner.isEmpty { continue }   // 空になった要素は消す
                entry["hooks"] = inner
                newEntries.append(entry)
            }
            if newEntries.isEmpty { hooks[event] = nil } else { hooks[event] = newEntries }
        }
        guard changed else { return }
        if hooks.isEmpty { root["hooks"] = nil } else { root["hooks"] = hooks }
        try commit(root, loaded: loaded)
    }

    // MARK: 了承ダイアログ

    /// 了承を得てから install する。キャンセル・失敗なら false。
    @MainActor
    static func confirmAndInstall() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Claude Code のフックを登録しますか？"
        alert.informativeText = """
        ~/.claude/settings.json に、セッションの状態を記録するフックを追記します。
        既存の設定やほかのフックは消しません。書き換える前に同じフォルダへ退避ファイルを作ります。
        """
        alert.addButton(withTitle: "登録する")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        do {
            try HookInstaller().install()
            return true
        } catch {
            let failure = NSAlert(error: error)
            failure.runModal()
            return false
        }
    }

    // MARK: 内部

    private struct Loaded {
        var root: [String: Any]
        /// 読み込んだ生のデータ。ファイルが無ければ nil
        var data: Data?
    }

    /// シンボリックリンクを解決した実体（読み込み・退避・書き込みはすべてこちらを使う）
    private var realSettingsURL: URL { settingsURL.resolvingSymlinksInPath() }

    /// フックとして書く command。パスはシングルクォートで囲む。
    private var expectedCommand: String {
        "'" + helperInstallURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isOwnCommand(_ hook: [String: Any]) -> Bool {
        (hook["command"] as? String)?.contains(scriptName) == true
    }

    private static func isOwn(_ element: Any) -> Bool {
        guard let entry = element as? [String: Any], let inner = entry["hooks"] as? [Any] else { return false }
        return inner.contains { ($0 as? [String: Any]).map(isOwnCommand) == true }
    }

    /// "hooks" が無ければ nil、オブジェクトでなければ throw
    private static func hooksObject(in root: [String: Any]) throws -> [String: Any]? {
        guard let value = root["hooks"] else { return nil }
        guard let hooks = value as? [String: Any] else { throw InstallError.unexpectedStructure("hooks") }
        return hooks
    }

    /// イベントのキーが無ければ空、配列でなければ throw。要素の型は問わず保つ。
    private static func eventEntries(_ hooks: [String: Any], _ event: String) throws -> [Any] {
        guard let value = hooks[event] else { return [] }
        guard let entries = value as? [Any] else { throw InstallError.unexpectedStructure("hooks.\(event)") }
        return entries
    }

    /// 自分の登録の command が現在の値と違えば書き換える。変えたら true。
    private func refreshOwnCommand(_ entries: inout [Any]) -> Bool {
        var changed = false
        for i in entries.indices {
            guard var entry = entries[i] as? [String: Any], var inner = entry["hooks"] as? [Any] else { continue }
            var entryChanged = false
            for j in inner.indices {
                guard var hook = inner[j] as? [String: Any], Self.isOwnCommand(hook),
                      hook["command"] as? String != expectedCommand else { continue }
                hook["command"] = expectedCommand
                inner[j] = hook
                entryChanged = true
            }
            if entryChanged {
                entry["hooks"] = inner
                entries[i] = entry
                changed = true
            }
        }
        return changed
    }

    /// 無ければ空、読めなければ throw
    private func loadSettings() throws -> Loaded {
        let url = realSettingsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return Loaded(root: [:], data: nil) }
        do {
            let data = try Data(contentsOf: url)
            if data.allSatisfy({ [0x20, 0x0A, 0x0D, 0x09].contains($0) }) { return Loaded(root: [:], data: data) }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallError.unreadableSettings("最上位がオブジェクトではありません")
            }
            return Loaded(root: obj, data: data)
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.unreadableSettings(error.localizedDescription)
        }
    }

    /// 競合を確かめ、退避を取ってから書き込む
    private func commit(_ root: [String: Any], loaded: Loaded) throws {
        let fm = FileManager.default
        let url = realSettingsURL
        let newData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])

        // 読み込み後に他のプロセスが変更していたら中止する
        let current: Data? = fm.fileExists(atPath: url.path) ? try? Data(contentsOf: url) : nil
        guard current == loaded.data else { throw InstallError.modifiedConcurrently }

        let permissions = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions]
        if let original = loaded.data { try backup(original, of: url) }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try newData.write(to: url, options: .atomic)
        if let permissions { try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
    }

    /// 読み込んだ内容をそのまま別ファイルに書き、古い退避を消す
    private func backup(_ data: Data, of url: URL) throws {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        let prefix = "\(url.lastPathComponent).jpam-backup-"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        var target = folder.appendingPathComponent(prefix + stamp)
        // 同じ秒に複数回呼ばれても上書きしない
        var n = 1
        while fm.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(prefix)\(stamp)-\(n)")
            n += 1
        }
        try data.write(to: target, options: .withoutOverwriting)

        // 新しい方から backupLimit 個だけ残す（名前の時刻、同じ秒なら連番で並べる）
        let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(prefix) }
        func key(_ name: String) -> (String, Int) {
            let rest = String(name.dropFirst(prefix.count))
            return (String(rest.prefix(15)), Int(rest.dropFirst(16)) ?? 0)
        }
        let sorted = names.sorted { key($0) > key($1) }
        for old in sorted.dropFirst(Self.backupLimit) {
            try? fm.removeItem(at: folder.appendingPathComponent(old))
        }
    }

    /// 同じフォルダの一時ファイルに書いて 0755 にしてから rename で置き換える
    private func copyHelper(from bundled: URL) throws {
        let fm = FileManager.default
        let folder = helperInstallURL.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try Data(contentsOf: bundled)
        let temp = folder.appendingPathComponent(".\(helperInstallURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
            guard rename(temp.path, helperInstallURL.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }
}
