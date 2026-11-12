import XCTest
@testable import JPAgentManager

/// 分離中のパネルの置き場所（下端を基準点に上へ伸ばす）
final class PanelPlacementTests: XCTestCase {
    /// 可視領域: y 0〜1000
    private let visible = NSRect(x: 0, y: 0, width: 1600, height: 1000)
    private let current = NSRect(x: 300, y: 400, width: 560, height: 200)

    private func frame(height: CGFloat, anchor: CGFloat) -> NSRect {
        PanelController.detachedFrame(height: height, anchorBottom: anchor, current: current, visible: visible)
    }

    func test上へ伸びて下端は基準点のまま() {
        let f = frame(height: 300, anchor: 400)
        XCTAssertEqual(f.minY, 400)
        XCTAssertEqual(f.height, 300)
        XCTAssertEqual(f.minX, 300)
        XCTAssertEqual(f.width, 560)
    }

    func test上端に届いたら下へ伸びる() {
        let f = frame(height: 700, anchor: 400)
        XCTAssertEqual(f.maxY, 1000)
        XCTAssertEqual(f.minY, 300)
    }

    func test画面より高ければ可視領域いっぱいにする() {
        let f = frame(height: 1500, anchor: 400)
        XCTAssertEqual(f.minY, 0)
        XCTAssertEqual(f.height, 1000)
    }

    func test減ったら基準点へ戻る() {
        // 上端に届いて下へ伸びた状態から、中身が減ったとき
        let grown = frame(height: 700, anchor: 400)
        XCTAssertEqual(grown.minY, 300)
        let f = PanelController.detachedFrame(height: 200, anchorBottom: 400, current: grown, visible: visible)
        XCTAssertEqual(f.minY, 400)
        XCTAssertEqual(f.height, 200)
    }

    func test基準点が画面の下にはみ出していたら可視領域へ戻す() {
        let f = frame(height: 200, anchor: -50)
        XCTAssertEqual(f.minY, 0)
    }

    // MARK: 原点が (0, 0) でない可視領域（下に Dock、左に置いた外部ディスプレイ）

    private let offset = NSRect(x: -1600, y: 80, width: 1600, height: 900)

    func test外部ディスプレイで基準点が下にはみ出したら可視領域の下端へ() {
        let f = PanelController.detachedFrame(height: 300, anchorBottom: 20, current: current, visible: offset)
        XCTAssertEqual(f.minY, 80)
        XCTAssertEqual(f.height, 300)
    }

    func test外部ディスプレイで基準点が上にはみ出したら上端に揃える() {
        let f = PanelController.detachedFrame(height: 300, anchorBottom: 1200, current: current, visible: offset)
        XCTAssertEqual(f.maxY, 980)
        XCTAssertEqual(f.minY, 680)
    }

    func test外部ディスプレイで画面より高ければ可視領域いっぱい() {
        let f = PanelController.detachedFrame(height: 2000, anchorBottom: 500, current: current, visible: offset)
        XCTAssertEqual(f.minY, 80)
        XCTAssertEqual(f.height, 900)
    }
}
