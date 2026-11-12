import XCTest
@testable import JPAgentManager

/// 分離中のパネルの置き場所（上端を基準点に下へ伸ばし、はみ出す分だけ上へずらす）
final class PanelPlacementTests: XCTestCase {
    /// 可視領域: y 0〜1000
    private let visible = NSRect(x: 0, y: 0, width: 1600, height: 1000)
    private let current = NSRect(x: 300, y: 400, width: 560, height: 200)

    private func frame(height: CGFloat, anchor: CGFloat, current: NSRect? = nil) -> NSRect {
        PanelController.detachedFrame(height: height, anchorTop: anchor, current: current ?? self.current,
                                      visible: visible)
    }

    func test下へ伸びて上端は基準点のまま() {
        let f = frame(height: 300, anchor: 600)
        XCTAssertEqual(f.maxY, 600)
        XCTAssertEqual(f.height, 300)
        XCTAssertEqual(f.minX, 300)
        XCTAssertEqual(f.width, 560)
    }

    func test下端からはみ出す分だけ上へずらす() {
        let f = frame(height: 700, anchor: 600)
        XCTAssertEqual(f.minY, 0)
        XCTAssertEqual(f.maxY, 700)
    }

    func test画面より高ければ可視領域いっぱいにする() {
        let f = frame(height: 1500, anchor: 600)
        XCTAssertEqual(f.minY, 0)
        XCTAssertEqual(f.height, 1000)
    }

    func test減ったら置いた位置へ戻る() {
        // 下端に届いて上へずれた状態から、中身が減ったとき
        let grown = frame(height: 700, anchor: 600)
        XCTAssertEqual(grown.maxY, 700)
        let f = frame(height: 200, anchor: 600, current: grown)
        XCTAssertEqual(f.maxY, 600)
        XCTAssertEqual(f.height, 200)
    }

    func test基準点が画面の上にはみ出していたら可視領域へ戻す() {
        let f = frame(height: 200, anchor: 1050)
        XCTAssertEqual(f.maxY, 1000)
    }

    // MARK: 原点が (0, 0) でない可視領域（下に Dock、左に置いた外部ディスプレイ）

    private let offset = NSRect(x: -1600, y: 80, width: 1600, height: 900)

    func test外部ディスプレイで基準点が上にはみ出したら可視領域の上端へ() {
        let f = PanelController.detachedFrame(height: 300, anchorTop: 1200, current: current, visible: offset)
        XCTAssertEqual(f.maxY, 980)
        XCTAssertEqual(f.height, 300)
    }

    func test外部ディスプレイで基準点が下にはみ出したら下端に揃える() {
        let f = PanelController.detachedFrame(height: 300, anchorTop: 100, current: current, visible: offset)
        XCTAssertEqual(f.minY, 80)
        XCTAssertEqual(f.maxY, 380)
    }

    func test外部ディスプレイで画面より高ければ可視領域いっぱい() {
        let f = PanelController.detachedFrame(height: 2000, anchorTop: 500, current: current, visible: offset)
        XCTAssertEqual(f.minY, 80)
        XCTAssertEqual(f.height, 900)
    }
}
