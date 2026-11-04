// メニューバー試作: NSStatusItem + NSPanel + SwiftUI(.glassEffect)
// 確かめること: カラーの点 / ガラス背景 / 高さの追従 / 行・外側・Esc で閉じる
import AppKit
import SwiftUI
import Observation

// MARK: - 起動引数

/// --material を付けると .glassEffect の代わりに .regularMaterial を使う
let useMaterial = CommandLine.arguments.contains("--material")

// MARK: - サンプルデータ

enum RowState {
    case waiting, running, idle

    var label: String {
        switch self {
        case .waiting: return "許可待ち"
        case .running: return "実行中"
        case .idle: return "待機"
        }
    }

    var color: Color {
        switch self {
        case .waiting: return Color(nsColor: .systemOrange)
        case .running: return Color(nsColor: .systemBlue)
        case .idle: return Color(nsColor: .systemGray)
        }
    }
}

struct SampleRow: Identifiable {
    let id = UUID()
    let title: String
    let state: RowState
    let detail: String
    let elapsed: String
}

struct SampleFolder: Identifiable {
    let id = UUID()
    let name: String
    let color: Color
    var rows: [SampleRow]
}

@MainActor
@Observable
final class Store {
    var folders: [SampleFolder] = [
        SampleFolder(name: "PhotoSorter", color: Color(nsColor: .systemPurple), rows: [
            SampleRow(title: "写真選別画面にお気に入りフィルタを追加", state: .waiting,
                      detail: "Bash: npm run tauri build", elapsed: "2分"),
            SampleRow(title: "画像補正パラメータの比較実験", state: .running,
                      detail: "Edit: src/filter/config.ts", elapsed: "0:45"),
            SampleRow(title: "README の手順を新UIに合わせて更新", state: .idle,
                      detail: "Read: README.md", elapsed: "25分"),
        ]),
        SampleFolder(name: "JPAgentManager", color: Color(nsColor: .systemTeal), rows: [
            SampleRow(title: "メニューバー試作", state: .running,
                      detail: "Write: main.swift", elapsed: "1:10"),
        ]),
    ]
    private var counter = 0

    /// 先頭フォルダに行を足す
    func addRow() {
        counter += 1
        let states: [RowState] = [.waiting, .running, .idle]
        folders[0].rows.append(SampleRow(
            title: "追加した行 \(counter)", state: states[counter % 3],
            detail: "Bash: echo \(counter)", elapsed: "\(counter)分"))
    }

    /// 先頭フォルダから行を減らす
    func removeRow() {
        if !folders[0].rows.isEmpty { folders[0].rows.removeLast() }
    }
}

// MARK: - SwiftUI の中身

private let panelWidth: CGFloat = 480
private let panelMaxHeight: CGFloat = 560
private let panelCorner: CGFloat = 24

/// 中身の高さを親へ伝える
struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct RowView: View {
    let row: SampleRow
    let onClick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onClick) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(row.title)
                        .font(.system(size: 13, weight: row.state == .idle ? .regular : .semibold))
                        .foregroundStyle(row.state == .idle ? Color.secondary : Color.primary)
                    Spacer(minLength: 8)
                    Text("\(row.state.label) \(row.elapsed)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        // 許可待ちだけ塗りつぶし、他は薄い色
                        .foregroundStyle(row.state == .waiting ? Color.white : row.state.color)
                        .background(Capsule().fill(row.state == .waiting
                                                   ? row.state.color : row.state.color.opacity(0.14)))
                }
                HStack(spacing: 6) {
                    Text("直近").foregroundStyle(.tertiary)
                    Text(row.detail).foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12).fill(
                    row.state == .waiting
                        ? Color(nsColor: .systemOrange).opacity(0.14)
                        : Color.primary.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 書類棚のフォルダ1つ分。耳(タブ)は左上
struct FolderView: View {
    let folder: SampleFolder
    let onClick: (SampleRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(folder.name).font(.system(size: 12, weight: .bold))
                Text("\(folder.rows.count)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(Color.white.opacity(0.28)))
                ForEach(Array(folder.rows.prefix(3))) { row in
                    Circle().fill(row.state == .idle ? Color.white.opacity(0.6) : row.state.color)
                        .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 1))
                        .frame(width: 7, height: 7)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(UnevenRoundedRectangle(topLeadingRadius: 11, topTrailingRadius: 11).fill(folder.color))

            VStack(spacing: 2) {
                if folder.rows.isEmpty {
                    Text("タブなし")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(.secondary))
                } else {
                    ForEach(folder.rows) { row in RowView(row: row) { onClick(row) } }
                }
            }
            .padding(4)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 16,
                                       bottomTrailingRadius: 16, topTrailingRadius: 16)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(alignment: .top) { Rectangle().fill(folder.color).frame(height: 3) }
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 16,
                                                      bottomTrailingRadius: 16, topTrailingRadius: 16)))
        }
    }
}

struct PanelContent: View {
    let store: Store
    let onClick: (SampleRow) -> Void
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        // 中身の実寸を測り、上限までは中身に合わせ、超えたらスクロールにする
        let shown = min(max(contentHeight, 1), panelMaxHeight)
        ScrollView(.vertical, showsIndicators: contentHeight > panelMaxHeight) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Claude").font(.system(size: 17, weight: .bold))
                    Spacer()
                    Button("行を足す") { store.addRow() }
                    Button("行を減らす") { store.removeRow() }
                }
                ForEach(store.folders) { folder in
                    FolderView(folder: folder, onClick: onClick)
                }
            }
            .padding(14)
            .background(GeometryReader { geo in
                Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
            })
        }
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .frame(width: panelWidth, height: shown)
        .background { glassBackground }
        .clipShape(RoundedRectangle(cornerRadius: panelCorner))
    }

    @ViewBuilder private var glassBackground: some View {
        if useMaterial {
            RoundedRectangle(cornerRadius: panelCorner).fill(.regularMaterial)
        } else {
            Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: panelCorner))
        }
    }
}

// MARK: - パネル

/// キー入力(Esc)を受けるため canBecomeKey を true にする。nonactivatingPanel なのでアプリは前面化しない
final class SpikePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController: NSObject {
    private let panel: SpikePanel
    private let hosting: NSHostingView<PanelContent>
    private weak var anchor: NSStatusBarButton?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var frameObserver: NSObjectProtocol?

    var isVisible: Bool { panel.isVisible }

    init(store: Store, anchor: NSStatusBarButton, onClick: @escaping (SampleRow) -> Void) {
        self.anchor = anchor
        panel = SpikePanel(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 200),
                           styleMask: [.nonactivatingPanel, .borderless],
                           backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        hosting = NSHostingView(rootView: PanelContent(store: store, onClick: onClick))
        // 中身の intrinsicContentSize に合わせてウィンドウを伸縮させる
        hosting.sizingOptions = [.intrinsicContentSize]
        super.init()
        panel.contentView = hosting
        // 中身の高さが変わったら、上端を固定したままパネルを伸縮する
        hosting.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: hosting, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.fitToContent() } }
    }

    /// 上端を固定して、中身の高さにウィンドウを合わせる
    private func fitToContent() {
        guard panel.isVisible else { return }
        let size = hosting.fittingSize
        guard size.height > 1, abs(size.height - panel.frame.height) > 0.5 else { return }
        var f = panel.frame
        f.origin.y += f.height - size.height
        f.size = size
        panel.setFrame(f, display: true)
    }

    func toggle() { isVisible ? close() : open() }

    func open() {
        guard let button = anchor, let window = button.window else { return }
        let size = hosting.fittingSize
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        var x = rect.midX - size.width / 2
        if let screen = window.screen {
            x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        }
        let y = rect.minY - 6 - size.height
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)

        // パネル外のクリック(他アプリ・デスクトップ)で閉じる
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in Task { @MainActor in self?.close() } }
        // Esc で閉じる(keyCode 53)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.close(); return nil }
            return event
        }
    }

    func close() {
        panel.orderOut(nil)
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }
}

// MARK: - ステータスアイテム

/// 「橙の点+1 / 青の点+2 / 8」をカラーで描く。描画クロージャは表示のたびに呼ばれるので、
/// NSColor.labelColor などの動的色がメニューバーの外観(ライト/ダーク)に追従する
func makeStatusImage(waiting: Int, running: Int, total: Int) -> NSImage {
    let font = NSFont.systemFont(ofSize: 12, weight: .bold)
    let small = NSFont.systemFont(ofSize: 11)
    let items: [(NSColor?, String, NSFont)] = [
        (.systemOrange, "\(waiting)", font),
        (.systemBlue, "\(running)", font),
        (nil, "/ \(total)", small),
    ]
    let dot: CGFloat = 9, gap: CGFloat = 3, space: CGFloat = 7
    func attrs(_ f: NSFont) -> [NSAttributedString.Key: Any] {
        [.font: f, .foregroundColor: NSColor.labelColor]
    }
    var width: CGFloat = 0
    for (c, s, f) in items {
        width += (c != nil ? dot + gap : 0) + (s as NSString).size(withAttributes: attrs(f)).width + space
    }
    width -= space
    let image = NSImage(size: NSSize(width: ceil(width), height: 18), flipped: false) { rect in
        var x: CGFloat = 0
        for (color, text, f) in items {
            if let color {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: (rect.height - dot) / 2, width: dot, height: dot)).fill()
                x += dot + gap
            }
            let str = text as NSString
            let sz = str.size(withAttributes: attrs(f))
            str.draw(at: NSPoint(x: x, y: (rect.height - sz.height) / 2), withAttributes: attrs(f))
            x += sz.width + space
        }
        return true
    }
    image.isTemplate = false  // カラーのまま描く
    return image
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panelController: PanelController!
    private let store = Store()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.image = makeStatusImage(waiting: 1, running: 2, total: 8)
        button.target = self
        button.action = #selector(togglePanel)
        panelController = PanelController(store: store, anchor: button) { [weak self] row in
            print("clicked: \(row.title)")
            fflush(stdout)
            self?.panelController.close()
        }
        print("起動: material=\(useMaterial)")
        fflush(stdout)
    }

    @objc private func togglePanel() { panelController.toggle() }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)  // Dock に出さない
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
