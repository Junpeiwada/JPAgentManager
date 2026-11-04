import XCTest
@testable import JPAgentManager

final class HookInstallerTests: XCTestCase {
    private var dir: URL!
    private var installer: HookInstaller!

    /// アプリ（テストホスト）に同梱されたヘルパー
    private static let helperURL = Bundle.main.url(forAuxiliaryExecutable: "jpam-hook")!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hookinstaller-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir!
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        installer = HookInstaller(
            settingsURL: dir.appendingPathComponent("claude/settings.json"),
            helperInstallURL: dir.appendingPathComponent("support/jpam-hook"),
            bundledHelperURL: Self.helperURL
        )
        try FileManager.default.createDirectory(at: installer.settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private func readSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: installer.settingsURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func writeSettings(_ text: String) throws {
        try text.write(to: installer.settingsURL, atomically: true, encoding: .utf8)
    }

    private func backups() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: installer.settingsURL.deletingLastPathComponent().path)
            .filter { $0.hasPrefix("settings.json.jpam-backup-") }
    }

    private let otherHooks = """
    {
      "permissions": {"allow": ["Bash(ls:*)"]},
      "hooks": {
        "Stop": [{"hooks": [{"type": "command", "command": "/usr/local/bin/other-tool"}]}],
        "Custom": [{"hooks": [{"type": "command", "command": "x"}]}]
      }
    }
    """

    func test_設定が無い状態からinstallすると全イベントが登録される() throws {
        XCTAssertFalse(installer.isInstalled())
        try installer.install()
        XCTAssertTrue(installer.isInstalled())
        let hooks = try XCTUnwrap(readSettings()["hooks"] as? [String: Any])
        for event in HookInstaller.events {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]])
            XCTAssertEqual(entries.count, 1)
            let cmd = try XCTUnwrap((entries[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String)
            XCTAssertEqual(cmd, "'\(installer.helperInstallURL.path)'")
            XCTAssertEqual(entries[0]["matcher"] as? String, ["PreToolUse", "PostToolUse"].contains(event) ? "*" : nil)
        }
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installer.helperInstallURL.path))
    }

    func test_既存のキーと他ツールのフックが残る() throws {
        try writeSettings(otherHooks)
        try installer.install()
        let root = try readSettings()
        XCTAssertNotNil(root["permissions"])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["Custom"])
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2)
        XCTAssertTrue(stop.contains { ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String == "/usr/local/bin/other-tool" })
    }

    func test_2回installしても重複しない() throws {
        try installer.install()
        let first = try readSettings() as NSDictionary
        try installer.install()
        XCTAssertEqual(try readSettings() as NSDictionary, first)
    }

    func test_uninstallで自分の分だけ消え空の配列とhooksも消える() throws {
        try writeSettings(otherHooks)
        try installer.install()
        try installer.uninstall()
        XCTAssertFalse(installer.isInstalled())
        let root = try readSettings()
        XCTAssertNotNil(root["permissions"])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), ["Stop", "Custom"])
        XCTAssertEqual((hooks["Stop"] as? [[String: Any]])?.count, 1)

        // 自分の分しか無ければ hooks ごと消える
        try? FileManager.default.removeItem(at: installer.settingsURL)
        try installer.install()
        try installer.uninstall()
        XCTAssertNil(try readSettings()["hooks"])
    }

    func test_壊れたJSONならthrowしファイルは変わらない() throws {
        let broken = "{ \"hooks\": "
        try writeSettings(broken)
        XCTAssertThrowsError(try installer.install())
        XCTAssertThrowsError(try installer.uninstall())
        XCTAssertEqual(try String(contentsOf: installer.settingsURL, encoding: .utf8), broken)
        XCTAssertEqual(try backups().count, 0)
    }

    func test_退避ファイルができる() throws {
        try writeSettings(otherHooks)
        try installer.install()
        let list = try backups()
        XCTAssertEqual(list.count, 1)
        let url = installer.settingsURL.deletingLastPathComponent().appendingPathComponent(list[0])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), otherHooks)
    }

    func test_2回目のinstallで退避が増えない() throws {
        try writeSettings(otherHooks)
        try installer.install()
        XCTAssertEqual(try backups().count, 1)
        try installer.install()
        XCTAssertEqual(try backups().count, 1)
    }

    func test_未登録のuninstallはファイルを書かず退避も作らない() throws {
        try writeSettings(otherHooks)
        try installer.uninstall()
        XCTAssertEqual(try String(contentsOf: installer.settingsURL, encoding: .utf8), otherHooks)
        XCTAssertEqual(try backups().count, 0)

        try FileManager.default.removeItem(at: installer.settingsURL)
        try installer.uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.settingsURL.path))
    }

    func test_hooksがnullならthrowしファイルは変わらない() throws {
        let text = "{\"hooks\": null, \"a\": 1}"
        try writeSettings(text)
        XCTAssertThrowsError(try installer.install())
        XCTAssertThrowsError(try installer.uninstall())
        XCTAssertEqual(try String(contentsOf: installer.settingsURL, encoding: .utf8), text)
        XCTAssertEqual(try backups().count, 0)
    }

    func test_イベントの値が配列でなければthrowしファイルは変わらない() throws {
        let text = "{\"hooks\": {\"Stop\": \"x\"}}"
        try writeSettings(text)
        XCTAssertThrowsError(try installer.install())
        XCTAssertEqual(try String(contentsOf: installer.settingsURL, encoding: .utf8), text)
        XCTAssertEqual(try backups().count, 0)
    }

    func test_イベントの配列に辞書以外が混ざっても残る() throws {
        try writeSettings("{\"hooks\": {\"Stop\": [\"str\", {\"hooks\": [{\"type\": \"command\", \"command\": \"x\"}]}]}}")
        try installer.install()
        func stop() throws -> [Any] {
            let hooks = try XCTUnwrap(readSettings()["hooks"] as? [String: Any])
            return try XCTUnwrap(hooks["Stop"] as? [Any])
        }
        XCTAssertEqual(try stop().count, 3)
        XCTAssertTrue(try stop().contains { ($0 as? String) == "str" })
        try installer.uninstall()
        XCTAssertEqual(try stop().count, 2)
        XCTAssertTrue(try stop().contains { ($0 as? String) == "str" })
    }

    func test_シンボリックリンクはリンクのままリンク先が更新される() throws {
        let realDir = dir.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let real = realDir.appendingPathComponent("settings.json")
        try otherHooks.write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
        try FileManager.default.createSymbolicLink(at: installer.settingsURL, withDestinationURL: real)

        try installer.install()

        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: installer.settingsURL.path))
        let hooks = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: real)) as? [String: Any]
        )["hooks"] as? [String: Any]
        XCTAssertNotNil(hooks?["PreToolUse"])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? Int, 0o600)
        let realBackups = try FileManager.default.contentsOfDirectory(atPath: realDir.path)
            .filter { $0.hasPrefix("settings.json.jpam-backup-") }
        XCTAssertEqual(realBackups.count, 1)
        XCTAssertTrue(installer.isInstalled())
    }

    func test_古いパスの登録は書き換わる() throws {
        try writeSettings("{\"hooks\": {\"Stop\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"/old/place/jpam-hook.sh\"}]}]}}")
        XCTAssertFalse(installer.isInstalled())
        try installer.install()
        XCTAssertTrue(installer.isInstalled())
        let hooks = try XCTUnwrap(readSettings()["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 1)
        let cmd = (stop[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String
        XCTAssertEqual(cmd, "'\(installer.helperInstallURL.path)'")
    }

    func test_パスにシングルクォートがあっても壊れない() throws {
        let quoted = HookInstaller(
            settingsURL: installer.settingsURL,
            helperInstallURL: dir.appendingPathComponent("it's $x/jpam-hook"),
            bundledHelperURL: Self.helperURL
        )
        try quoted.install()
        let hooks = try XCTUnwrap(readSettings()["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let cmd = try XCTUnwrap((stop[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        XCTAssertTrue(cmd.hasPrefix("'") && cmd.hasSuffix("'"))
        XCTAssertTrue(cmd.contains("it'\\''s $x"))
        XCTAssertTrue(quoted.isInstalled())
    }

    func test_退避は5個まで() throws {
        for _ in 0..<5 {
            try installer.install()
            try installer.uninstall()
        }
        XCTAssertEqual(try backups().count, HookInstaller.backupLimit)
    }

    func test_設定の書き出しはキー順が固定される() throws {
        try writeSettings("{\"zeta\": 1, \"alpha\": 2, \"mid\": {\"b\": 1, \"a\": 2}}")
        try installer.install()
        let text = try String(contentsOf: installer.settingsURL, encoding: .utf8)
        let positions = ["\"alpha\"", "\"hooks\"", "\"mid\"", "\"zeta\""].map { text.range(of: $0)!.lowerBound }
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertLessThan(text.range(of: "\"a\"")!.lowerBound, text.range(of: "\"b\"")!.lowerBound)
    }

    func test_ヘルパーが配置され実行できる() throws {
        try installer.install()
        let p = Process()
        p.executableURL = installer.helperInstallURL
        p.environment = ["JPAM_EVENTS_FILE": dir.appendingPathComponent("events.jsonl").path]
        let stdin = Pipe()
        p.standardInput = stdin
        try p.run()
        try stdin.fileHandleForWriting.close()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }
}
