import XCTest
@testable import JPAgentManager

final class GitInfoTests: XCTestCase {
    private func makeTempDir() throws -> String {
        // /var と /private/var の違いを避けるため実パスに解決しておく
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "gitinfo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        // resolvingSymlinksInPath は /private/var を /var に戻してしまうため realpath を使う
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func git(_ args: [String], in dir: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // ユーザーのグローバル設定（署名・フック）に左右されないようにする
        p.arguments = ["-C", dir, "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + args
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

    override func tearDown() {
        GitInfo.now = { Date() }
        super.tearDown()
    }

    func test_gitリポジトリでルートとブランチが取れる() throws {
        let dir = try makeTempDir()
        try git(["init", "-b", "feature-x"], in: dir)
        try git(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "--allow-empty", "-m", "init"], in: dir)
        let sub = dir + "/sub"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)

        let info = GitInfo.info(for: sub)
        XCTAssertEqual(info?.root, dir)
        XCTAssertEqual(info?.branch, "feature-x")
    }

    func test_git管理外はnil() throws {
        let dir = try makeTempDir()
        XCTAssertNil(GitInfo.info(for: dir))
    }

    func test_存在しないフォルダでも落ちずnil() {
        XCTAssertNil(GitInfo.info(for: "/nonexistent-\(UUID().uuidString)"))
    }

    func test_detachedHEADではbranchがnil() throws {
        let dir = try makeTempDir()
        try git(["init", "-b", "main"], in: dir)
        try git(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "--allow-empty", "-m", "init"], in: dir)
        try git(["checkout", "--detach"], in: dir)

        let info = GitInfo.info(for: dir)
        XCTAssertEqual(info?.root, dir)
        XCTAssertNil(info?.branch)
    }

    func test_コミットが無くてもブランチ名が取れる() throws {
        let dir = try makeTempDir()
        try git(["init", "-b", "fresh"], in: dir)
        XCTAssertEqual(GitInfo.info(for: dir)?.branch, "fresh")
    }

    func test_30秒以内はキャッシュし_30秒後は取り直す() throws {
        let dir = try makeTempDir()
        try git(["init", "-b", "first"], in: dir)
        let t0 = Date()
        var current = t0
        GitInfo.now = { current }

        let before = GitInfo.queryCount
        XCTAssertEqual(GitInfo.info(for: dir)?.branch, "first")
        XCTAssertEqual(GitInfo.queryCount, before + 1)

        try git(["symbolic-ref", "HEAD", "refs/heads/second"], in: dir)
        current = t0.addingTimeInterval(10)
        XCTAssertEqual(GitInfo.info(for: dir)?.branch, "first")   // キャッシュ
        XCTAssertEqual(GitInfo.queryCount, before + 1)

        current = t0.addingTimeInterval(31)
        XCTAssertEqual(GitInfo.info(for: dir)?.branch, "second")  // 取り直し
        XCTAssertEqual(GitInfo.queryCount, before + 2)
    }
}
