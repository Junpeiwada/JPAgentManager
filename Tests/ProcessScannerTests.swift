import XCTest
@testable import JPAgentManager

final class ProcessScannerTests: XCTestCase {
    func testScanは落ちずに配列を返す() {
        // 実機に claude があるかは環境次第なので件数は検証しない
        let procs = ProcessScanner.scan()
        for p in procs {
            XCTAssertGreaterThan(p.pid, 0)
            XCTAssertGreaterThan(p.parentPID, 0)
        }
    }

    func testVSCodeタブの判定() {
        let claude = "/Users/x/.vscode/extensions/anthropic.claude-code/resources/native-binary/claude"
        let plugin = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
        XCTAssertTrue(ProcessScanner.isVSCodeTab(path: claude, parentPath: plugin))
        XCTAssertFalse(ProcessScanner.isVSCodeTab(path: claude, parentPath: "/usr/local/bin/node"))
        XCTAssertFalse(ProcessScanner.isVSCodeTab(path: "/usr/local/bin/claude", parentPath: plugin))
        XCTAssertFalse(ProcessScanner.isVSCodeTab(path: claude, parentPath: nil))
    }
}
