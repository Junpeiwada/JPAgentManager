import XCTest
@testable import JPAgentManager

final class FocuserTests: XCTestCase {
    private func session(entrypoint: String? = "claude-vscode", cwd: String = "/work/a") -> Session {
        Session(id: "s", pid: 1, cwd: cwd, status: .idle, statusSince: Date(), title: nil,
                lastAction: nil, lastPrompt: nil, entrypoint: entrypoint)
    }

    /// Result<Void, _> は Equatable でないので、成功／失敗の中身を取り出して比べる
    private func assertSuccess(_ r: Result<Void, FocusError>, line: UInt = #line) {
        if case .failure(let e) = r { XCTFail("成功のはずが失敗: \(e)", line: line) }
    }

    private func assertFailure(_ r: Result<Void, FocusError>, _ expected: FocusError, line: UInt = #line) {
        guard case .failure(let e) = r else { return XCTFail("失敗のはずが成功", line: line) }
        XCTAssertEqual(e, expected, line: line)
    }

    private final class Calls { var list: [(URL, [String])] = [] }

    private func focuser(calls: Calls, existing: Set<String>, exit: Int32 = 0) -> Focuser {
        var f = Focuser()
        f.fileExists = { existing.contains($0) }
        f.directoryExists = { existing.contains($0) }
        f.run = { url, args in calls.list.append((url, args)); return exit }
        return f
    }

    func test正しい引数でcodeを呼ぶ() {
        let calls = Calls()
        let f = focuser(calls: calls, existing: ["/work/a", Focuser().codeCLI.path])
        assertSuccess(f.focus(session()))
        XCTAssertEqual(calls.list.count, 1)
        XCTAssertEqual(calls.list[0].0, f.codeCLI)
        XCTAssertEqual(calls.list[0].1, ["/work/a"])
    }

    func testVSCode以外は呼ばない() {
        let calls = Calls()
        let f = focuser(calls: calls, existing: ["/work/a", Focuser().codeCLI.path])
        assertFailure(f.focus(session(entrypoint: "cli")), .notVSCode("cli"))
        assertFailure(f.focus(session(entrypoint: nil)), .notVSCode(nil))
        XCTAssertTrue(calls.list.isEmpty)
    }

    func testフォルダが無い() {
        let calls = Calls()
        let f = focuser(calls: calls, existing: [Focuser().codeCLI.path])
        assertFailure(f.focus(session()), .folderMissing("/work/a"))
        XCTAssertTrue(calls.list.isEmpty)
    }

    func testCLIが無ければopenで代用する() {
        let calls = Calls()
        let f = focuser(calls: calls, existing: ["/work/a"])
        assertSuccess(f.focus(session()))
        XCTAssertEqual(calls.list[0].0.path, "/usr/bin/open")
        XCTAssertEqual(calls.list[0].1, ["-b", "com.microsoft.VSCode", "/work/a"])
    }

    func testCLIが無くopenも失敗ならvscodeMissing() {
        let f = focuser(calls: Calls(), existing: ["/work/a"], exit: 1)
        assertFailure(f.focus(session()), .vscodeMissing)
    }

    func test終了コードが0以外ならlaunchFailed() {
        let f = focuser(calls: Calls(), existing: ["/work/a", Focuser().codeCLI.path], exit: 3)
        guard case .failure(.launchFailed) = f.focus(session()) else { return XCTFail("launchFailed になるはず") }
    }

    func test起動で例外ならlaunchFailed() {
        var f = Focuser()
        f.fileExists = { _ in true }
        f.directoryExists = { _ in true }
        f.run = { _, _ in throw NSError(domain: "t", code: 1) }
        guard case .failure(.launchFailed) = f.focus(session()) else { return XCTFail("launchFailed になるはず") }
    }

    func test危険なcwdは起動しない() {
        let calls = Calls()
        // "-" 始まり・相対パスは存在していても通さない。ファイル（ディレクトリでない）も通さない
        var f = focuser(calls: calls, existing: ["-n", "rel/dir", Focuser().codeCLI.path])
        assertFailure(f.focus(session(cwd: "-n")), .folderMissing("-n"))
        assertFailure(f.focus(session(cwd: "rel/dir")), .folderMissing("rel/dir"))
        f.directoryExists = { _ in false }
        f.fileExists = { _ in true }
        assertFailure(f.focus(session(cwd: "/work/file.txt")), .folderMissing("/work/file.txt"))
        XCTAssertTrue(calls.list.isEmpty)
    }

    func test起動がタイムアウトしたらnoResponse() {
        XCTAssertThrowsError(try Focuser.runProcess(URL(fileURLWithPath: "/bin/sleep"), ["10"], timeout: 0.3)) {
            XCTAssertEqual($0 as? FocusError, .noResponse)
        }
    }

    func testnoResponseはfocusの失敗として返る() {
        var f = Focuser()
        f.fileExists = { _ in true }
        f.directoryExists = { _ in true }
        f.run = { _, _ in throw FocusError.noResponse }
        assertFailure(f.focus(session()), .noResponse)
    }
}
