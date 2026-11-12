import AppKit
import SwiftUI

/// パネルへ渡すデータ。次の波で SessionStore の repos をここへ流し込む
@MainActor
final class PanelModel: ObservableObject {
    @Published var repos: [Repo]
    /// セッション情報を読めないときの短い注意文。無ければ nil
    @Published var lastError: String? = nil
    var onSelect: (Session) -> Void = { _ in }
    /// 「更新を確認…」が押されたときの処理。AppDelegate が Sparkle へ結ぶ
    var onCheckForUpdates: () -> Void = {}
    /// 未確認の完了（FR-111）
    private var completionTracker = CompletionTracker()

    init(repos: [Repo]) {
        self.repos = repos
    }

    /// SessionStore の結果を受け取り、未確認の完了の印を付けて表示へ流す
    func update(repos newRepos: [Repo]) {
        completionTracker.update(repos: newRepos)
        repos = CompletionTracker.apply(completionTracker.unseen, to: newRepos)
    }

    /// そのセッションの完了を確認済みにする（行や通知のクリック）
    func markSeen(_ sessionID: String) {
        completionTracker.markSeen(sessionID)
        guard repos.contains(where: { $0.sessions.contains { $0.id == sessionID && $0.completedUnseen } }) else { return }
        repos = repos.map { repo in
            var repo = repo
            repo.sessions = repo.sessions.map { s in
                var s = s
                if s.id == sessionID { s.completedUnseen = false }
                return s
            }
            return repo
        }
    }

    /// Info.plist から「v0.1.1」の形の版数を作る。取れなければ「—」
    nonisolated static func versionLabel(info: [String: Any]?) -> String {
        if let v = info?["CFBundleShortVersionString"] as? String, !v.isEmpty { return "v" + v }
        return "—"
    }
}

/// パネルの高さの上限と、分離の状態。高さの上限は開くたびに画面の可視領域から更新する
@MainActor
private final class PanelLayout: ObservableObject {
    @Published var maxHeight: CGFloat = 600
    /// グリップを掴んで剥がした状態か。閉じると false に戻る
    @Published var isDetached = false
    /// 分離したウィンドウを常に手前に出すか。UserDefaults に覚える
    @Published var alwaysOnTop = true
}

/// 掴んで動かすとウィンドウを動かす NSView。動かし始めた瞬間に onDragStart、離したら onDragEnd を呼ぶ
private final class DragHandleView: NSView {
    var onDragStart: () -> Void = {}
    var onDragEnd: () -> Void = {}
    private var downEvent: NSEvent?
    /// これ以上動かしたらドラッグとみなす距離（クリックの手ぶれと区別する）
    private static let threshold: CGFloat = 4

    // パネルがキーでなくても最初のクリックで掴めるようにする
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) { downEvent = event }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard hypot(dx, dy) >= Self.threshold else { return }
        downEvent = nil
        onDragStart()
        // 以降の追従はウィンドウサーバーに任せる（マウスを離すまで戻らない）
        window?.performDrag(with: down)
        onDragEnd()
    }

    override func mouseUp(with event: NSEvent) { downEvent = nil }
}

private struct WindowDragHandle: NSViewRepresentable {
    let onDragStart: () -> Void
    let onDragEnd: () -> Void
    func makeNSView(context: Context) -> DragHandleView {
        let view = DragHandleView()
        view.onDragStart = onDragStart
        view.onDragEnd = onDragEnd
        return view
    }
    func updateNSView(_ view: DragHandleView, context: Context) {
        view.onDragStart = onDragStart
        view.onDragEnd = onDragEnd
    }
}

/// パネルの中身。書類棚をスクロール可能に包み、下にフッターを置く
private struct PanelContent: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var layout: PanelLayout
    let onSelect: (Session) -> Void
    /// 「更新を確認…」用。パネルを閉じてから呼ぶ
    let onCheckForUpdates: () -> Void
    /// 測った中身の高さが変わったことをコントローラーへ直接伝える
    let onContentHeightChange: () -> Void
    /// グリップを掴んで動かし始めたとき（分離する）
    let onGripDrag: () -> Void
    /// グリップを離したとき（置いた位置を基準点にする）
    let onGripDragEnd: () -> Void
    /// 分離中の × が押されたとき
    let onCloseDetached: () -> Void
    /// 分離中のピン（常に手前）が押されたとき
    let onToggleAlwaysOnTop: () -> Void
    @State private var contentHeight: CGFloat = 0
    /// 注意文（余白込み）の実寸。出ていないときは使わない
    @State private var errorHeight: CGFloat = 0

    private static let headerHeight: CGFloat = 22
    private static let footerHeight: CGFloat = 40

    var body: some View {
        // 棚の実寸を測り、上限までは中身に合わせ、超えたらスクロールにする
        // 注意文が出ている間はその分も引き、パネル全体が上限に収まるようにする
        let errorShown = model.lastError == nil ? 0 : errorHeight
        let limit = max(layout.maxHeight - Self.headerHeight - Self.footerHeight - errorShown, 1)
        let shown = min(max(contentHeight, 1), limit)
        VStack(spacing: 0) {
            header
            if let message = model.lastError {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.attentionTextColor)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        errorHeight = height
                        onContentHeightChange()
                    }
            }
            ScrollView(.vertical, showsIndicators: contentHeight > limit) {
                // 経過時間が止まらないよう、1秒ごとに now を更新する
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    ShelfView(repos: model.repos, now: ctx.date, onSelect: onSelect)
                }
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    contentHeight = height
                    onContentHeightChange()
                }
            }
            .frame(width: Theme.panelContentWidth, height: shown)

            footer
        }
        .frame(width: Theme.panelContentWidth)
        .background {
            Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: PanelController.cornerRadius))
        }
        .clipShape(RoundedRectangle(cornerRadius: PanelController.cornerRadius))
    }

    /// 上端の帯。タイトルバーのように帯全体（ボタンを除く）を掴んで動かすと分離する。
    /// 分離中だけ左にピン、右に × を出す
    private var header: some View {
        ZStack {
            // 帯の幅いっぱいに掴む場所を敷く。ボタンはこの上に重ね、隙間のクリックはここへ届く
            WindowDragHandle(onDragStart: onGripDrag, onDragEnd: onGripDragEnd)
                .help(layout.isDetached ? "掴んで移動" : "掴んで動かすと切り離せます")
            Capsule()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 64, height: 5)
                .padding(.top, 4)
                .allowsHitTesting(false)
            if layout.isDetached {
                HStack(spacing: 0) {
                    Button { onToggleAlwaysOnTop() } label: {
                        Image(systemName: layout.alwaysOnTop ? "pin.fill" : "pin")
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .help(layout.alwaysOnTop ? "常に手前に表示：オン" : "常に手前に表示：オフ")
                    Spacer(minLength: 0)
                    Button { onCloseDetached() } label: {
                        Image(systemName: "xmark")
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .help("閉じる")
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 4)
            }
        }
        .frame(width: Theme.panelContentWidth, height: Self.headerHeight)
    }

    private var footer: some View {
        HStack {
            // 設定画面はまだ無いので無効表示
            Button("設定…") {}
                .disabled(true)
            Spacer()
            Text(PanelModel.versionLabel(info: Bundle.main.infoDictionary))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("更新を確認…") { onCheckForUpdates() }
            Spacer()
            Button("終了") { NSApp.terminate(nil) }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .padding(.horizontal, 18)
        .frame(height: Self.footerHeight)
    }
}

/// キー入力（Esc）を受けるため canBecomeKey を true にする。nonactivatingPanel なのでアプリは前面化しない
private final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController: NSObject {
    static let cornerRadius: CGFloat = 24

    private let panel: ShelfPanel
    private let hosting: NSHostingView<PanelContent>
    private let layout = PanelLayout()
    private weak var anchor: NSStatusBarButton?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var frameObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    /// 分離中の基準点（ユーザーが置いた位置の下端）。分離していなければ nil。
    /// 上端を固定すると、増えたときに下へ伸びて画面の外へ出てしまう。それを避けるため下端を基準にして上へ伸ばす
    private var detachedBottom: CGFloat?
    /// グリップでウィンドウを動かしている最中か。動かしている間は高さを合わせない
    private var isDragging = false
    /// 最後に閉じた時刻。キー喪失で閉じた直後のステータスアイテムのクリックを無視するため
    private var lastClosedAt: Date = .distantPast

    var isVisible: Bool { panel.isVisible }
    /// グリップを掴んで剥がした状態か
    var isDetached: Bool { layout.isDetached }

    private static let alwaysOnTopKey = "DetachedPanelAlwaysOnTop"

    init(model: PanelModel, anchor: NSStatusBarButton) {
        self.anchor = anchor
        panel = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: Theme.panelContentWidth, height: 200),
                           styleMask: [.nonactivatingPanel, .borderless],
                           backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        // 分離中に他のアプリへ移っても消えないようにする
        panel.hidesOnDeactivate = false

        // 行のクリック・更新の確認のあとに閉じる（分離中は閉じない）。self を後から結ぶため一度クロージャ越しにする
        var closeIfAttached: () -> Void = {}
        var contentHeightChanged: () -> Void = {}
        var detach: () -> Void = {}
        var dragEnded: () -> Void = {}
        var closeDetached: () -> Void = {}
        var toggleAlwaysOnTop: () -> Void = {}
        let layout = self.layout
        layout.alwaysOnTop = UserDefaults.standard.object(forKey: Self.alwaysOnTopKey) as? Bool ?? true
        hosting = NSHostingView(rootView: PanelContent(model: model, layout: layout, onSelect: { session in
            model.markSeen(session.id)
            model.onSelect(session)
            closeIfAttached()
        }, onCheckForUpdates: {
            // パネルを閉じる処理の後に回すため、次のランループで呼ぶ（確認ダイアログとパネルが重ならないように）
            closeIfAttached()
            DispatchQueue.main.async { model.onCheckForUpdates() }
        }, onContentHeightChange: { contentHeightChanged() },
           onGripDrag: { detach() },
           onGripDragEnd: { dragEnded() },
           onCloseDetached: { closeDetached() },
           onToggleAlwaysOnTop: { toggleAlwaysOnTop() }))
        // 中身の intrinsicContentSize に合わせてウィンドウを伸縮させる
        hosting.sizingOptions = [.intrinsicContentSize]
        super.init()
        closeIfAttached = { [weak self] in
            guard let self, !self.isDetached else { return }
            self.close()
        }
        detach = { [weak self] in self?.dragStarted() }
        dragEnded = { [weak self] in self?.dragEnded() }
        closeDetached = { [weak self] in self?.close() }
        toggleAlwaysOnTop = { [weak self] in self?.toggleAlwaysOnTop() }
        // 状態の反映を待ってから、1サイクル遅らせて高さを合わせる
        contentHeightChanged = { [weak self] in
            DispatchQueue.main.async { self?.fitToContent() }
        }
        panel.contentView = hosting
        // 中身の高さが変わったらパネルを伸縮する（どちらの端を固定するかは fitToContent）
        hosting.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: hosting, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.fitToContent() } }
        // ⌘Tab などでキーでなくなったら閉じる（分離中は閉じない）
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isDetached else { return }
                self.close()
            }
        }
    }

    deinit {
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
    }

    /// 中身の高さにウィンドウを合わせる。メニューの状態では上端を固定して下へ伸ばす。
    /// 分離中は基準点（置いた位置の下端）から上へ伸ばす（detachedFrame）
    private func fitToContent() {
        guard panel.isVisible, !isDragging else { return }
        let size = hosting.fittingSize
        guard size.height > 1 else { return }
        var f = panel.frame
        if layout.isDetached, let bottom = detachedBottom,
           let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            // 解像度の変更・Dock の切り替えなどで可視領域が変わったら、中身の上限も合わせる（変わると測り直して再びここへ来る）
            if abs(layout.maxHeight - visible.height) > 0.5 { layout.maxHeight = visible.height }
            f = Self.detachedFrame(height: size.height, anchorBottom: bottom, current: f, visible: visible)
        } else {
            f.origin.y += f.height - size.height
            f.size = size
        }
        guard abs(f.minY - panel.frame.minY) > 0.5 || abs(f.height - panel.frame.height) > 0.5 else { return }
        panel.setFrame(f, display: true)
    }

    /// 分離中の置き場所。下端を基準点に置いて上へ伸ばし、画面の上端に届いたら下へ伸ばす。
    /// 高さは画面の可視領域に収める（収まらない分は中身がスクロールする）。左右の位置と幅は変えない
    nonisolated static func detachedFrame(height: CGFloat, anchorBottom: CGFloat,
                                          current: NSRect, visible: NSRect) -> NSRect {
        let h = min(height, visible.height)
        var bottom = max(anchorBottom, visible.minY)
        if bottom + h > visible.maxY { bottom = visible.maxY - h }
        bottom = max(bottom, visible.minY)
        return NSRect(x: current.minX, y: bottom, width: current.width, height: h)
    }

    func toggle() {
        // 分離中はアイコンのクリックで最前面に出すだけにする（閉じるのは × で）
        if isVisible && isDetached { bringToFront(); return }
        if isVisible { close(); return }
        // キー喪失で閉じた直後（0.2秒以内）のクリックは、閉じてすぐ開き直す二重動作になるので無視する
        if Date().timeIntervalSince(lastClosedAt) < 0.2 { return }
        open()
    }

    func open() {
        guard let button = anchor, let window = button.window else { return }
        let screen = window.screen ?? NSScreen.main
        // 高さの上限は画面の可視領域の 80%
        if let screen { layout.maxHeight = screen.visibleFrame.height * 0.8 }
        // 位置と幅を先に決める。高さは前回の値で仮置きし、1サイクル後に測り直して確定する
        let size = NSSize(width: Theme.panelContentWidth, height: max(panel.frame.height, 1))
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        var x = rect.midX - size.width / 2
        if let screen {
            x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        }
        let y = rect.minY - 6 - size.height
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hosting.layoutSubtreeIfNeeded()
            self.fitToContent()
        }

        removeMonitors()
        // パネル外のクリック（他アプリ・デスクトップ）で閉じる。
        // ステータスアイテム上のクリックは、ボタンの action 側が開閉を決めるので無視する
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isDetached else { return }
                if let button = self.anchor, let window = button.window {
                    let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
                    if rect.contains(NSEvent.mouseLocation) { return }
                }
                self.close()
            }
        }
        // Esc で閉じる（keyCode 53）
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.close(); return nil }
            return event
        }
    }

    /// 閉じる。分離していたらメニューの状態に戻す（次に開くとアイコンの下に出る）
    func close() {
        guard panel.isVisible else { return }
        lastClosedAt = Date()
        panel.orderOut(nil)
        removeMonitors()
        layout.isDetached = false
        detachedBottom = nil
        isDragging = false
        panel.level = .statusBar
    }

    /// グリップを掴んで動かし始めたら分離する。外のクリックや Esc で閉じる監視を外し、重なり順を切り替える
    private func detach() {
        guard !layout.isDetached else { return }
        layout.isDetached = true
        removeMonitors()
        applyDetachedLevel()
    }

    /// グリップで動かし始めたとき。分離していなければ分離する
    private func dragStarted() {
        isDragging = true
        detach()
    }

    /// グリップを離したとき。置いた位置の下端を新しい基準点にし、高さの上限を画面の上端までに広げる
    private func dragEnded() {
        isDragging = false
        guard layout.isDetached else { return }
        detachedBottom = panel.frame.minY
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            layout.maxHeight = visible.height
        }
        // 上限の変更が中身に反映されてから合わせる
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hosting.layoutSubtreeIfNeeded()
            self.fitToContent()
        }
    }

    private func toggleAlwaysOnTop() {
        layout.alwaysOnTop.toggle()
        UserDefaults.standard.set(layout.alwaysOnTop, forKey: Self.alwaysOnTopKey)
        applyDetachedLevel()
    }

    /// 常に手前なら .floating、そうでなければ普通の窓と同じ .normal にする
    private func applyDetachedLevel() {
        guard layout.isDetached else { return }
        panel.level = layout.alwaysOnTop ? .floating : .normal
    }

    /// 分離中のウィンドウを最前面に出す。アプリは前面化しない
    func bringToFront() {
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func removeMonitors() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }
}
