import XCTest
@testable import JPAgentManager

final class GitStatusReaderTests: XCTestCase {
    private func makeTempDir() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "gitstatus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    private func git(_ args: [String], in dir: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir, "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                       "-c", "user.name=t", "-c", "user.email=t@example.com"] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "git \(args) が失敗")
    }

    func test解釈_差と変更数() {
        let output = """
        # branch.oid abc
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +2 -3
        1 .M N... 100644 100644 100644 aaa bbb a.txt
        2 R. N... 100644 100644 100644 aaa bbb R100 new.txt\told.txt
        ? untracked.txt

        """
        XCTAssertEqual(GitStatusReader.parse(output),
                       GitStatus(upstream: "origin/main", ahead: 2, behind: 3, changedFiles: 3))
    }

    func test解釈_上流なし() {
        let status = GitStatusReader.parse("# branch.oid abc\n# branch.head main\n")
        XCTAssertNil(status.upstream)
        XCTAssertEqual(status.ahead, 0)
        XCTAssertEqual(status.behind, 0)
    }

    func test解釈_形が変わっても落ちない() {
        XCTAssertEqual(GitStatusReader.parse("# branch.ab x y z\n# branch.ab +a -b\n").behind, 0)
    }

    func test説明文() {
        XCTAssertEqual(GitStatus(upstream: "o/m", ahead: 1, behind: 2, changedFiles: 3).helpText,
                       "プルが必要 2 コミット / 未プッシュ 1 コミット / 変更 3 ファイル")
        XCTAssertEqual(GitStatus(upstream: "o/m").helpText, "リモートと同じ")
        XCTAssertEqual(GitStatus(fetchFailed: true).helpText, "上流ブランチなし / リモートを確認できませんでした")
    }

    func test実リポジトリ_fetchで差が分かりFETCH_HEADを書かない() throws {
        let base = try makeTempDir()
        let remote = base + "/remote.git", local = base + "/local", other = base + "/other"
        for dir in [remote, local, other] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        try git(["init", "--bare", "-b", "main"], in: remote)
        try git(["clone", remote, "."], in: local)
        try git(["checkout", "-b", "main"], in: local)
        try git(["commit", "--allow-empty", "-m", "first"], in: local)
        try git(["push", "-u", "origin", "main"], in: local)
        try git(["clone", remote, "."], in: other)
        try git(["commit", "--allow-empty", "-m", "remote"], in: other)
        try git(["push"], in: other)
        try git(["commit", "--allow-empty", "-m", "local"], in: local)
        try "x".write(toFile: local + "/new.txt", atomically: true, encoding: .utf8)

        // fetch 前はリモートの更新が見えない
        XCTAssertEqual(GitStatusReader.status(root: local),
                       GitStatus(upstream: "origin/main", ahead: 1, behind: 0, changedFiles: 1))

        XCTAssertTrue(GitStatusReader.fetch(root: local))
        XCTAssertEqual(GitStatusReader.status(root: local),
                       GitStatus(upstream: "origin/main", ahead: 1, behind: 1, changedFiles: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: local + "/.git/FETCH_HEAD"))
    }

    func test実リポジトリ_変更が多くても詰まらない() throws {
        let dir = try makeTempDir()
        try git(["init", "-b", "main"], in: dir)
        // パイプの容量（64KB）を超える出力にする
        for i in 0..<3000 {
            let name = String(repeating: "f", count: 40) + "\(i).txt"
            FileManager.default.createFile(atPath: dir + "/" + name, contents: nil)
        }
        XCTAssertEqual(GitStatusReader.status(root: dir)?.changedFiles, 3000)
    }

    func testリモートに届かなければfetchは失敗() throws {
        let dir = try makeTempDir()
        try git(["init", "-b", "main"], in: dir)
        try git(["remote", "add", "origin", dir + "/nonexistent.git"], in: dir)
        XCTAssertFalse(GitStatusReader.fetch(root: dir))
    }

    func test管理外はnil() throws {
        XCTAssertNil(GitStatusReader.status(root: try makeTempDir()))
    }
}
