import AppKit
import Combine
import SwiftUI

/// メニューバーの点（カラー画像）を持ち、クリックでパネルを開閉する
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let panelController: PanelController
    private let model: PanelModel
    private var cancellable: AnyCancellable?
    private var lastCounts: (waiting: Int, running: Int, total: Int, emphasized: Bool)?
    // deinit（非隔離）から止めるため nonisolated(unsafe)。生成と停止以外では触らない
    nonisolated(unsafe) private var emphasisTimer: Timer?
    private var currentRepos: [Repo] = []
    private var appearanceObservation: NSKeyValueObservation?

    init?(model: PanelModel) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return nil }
        panelController = PanelController(model: model, anchor: button)
        self.model = model
        super.init()
        button.target = self
        button.action = #selector(togglePanel)
        // 右クリックでもアクションを受ける
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateImage(repos: model.repos)
        // repos が変わらなくても時間で強調に入るので、30秒ごとに判定し直す
        // メニュー操作などのイベント追跡中も止まらないよう .common モードに登録する
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateImage(repos: self.currentRepos)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        emphasisTimer = timer
        // @Published は変更の直前に流れるので、渡された値で更新する
        cancellable = model.$repos.sink { [weak self] repos in
            self?.updateImage(repos: repos)
        }
        // メニューバーの外観（ライト/ダーク）が変わったらアイコンを作り直す
        appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lastCounts = nil
                self.updateImage(repos: self.currentRepos)
            }
        }
    }

    deinit { emphasisTimer?.invalidate() }

    @objc private func togglePanel() {
        if Self.isMenuClick(NSApp.currentEvent) { showMenu() } else { panelController.toggle() }
    }

    /// 右クリック、または control＋クリックならメニューを出す
    nonisolated static func isMenuClick(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        return event.type == .rightMouseUp || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
    }

    /// パネルを閉じ、版数・更新を確認・終了のメニューを出す
    private func showMenu() {
        panelController.close()
        let menu = NSMenu()
        let version = NSMenuItem(title: "JPAgentManager " + PanelModel.versionLabel(info: Bundle.main.infoDictionary),
                                 action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(.separator())
        let check = NSMenuItem(title: "更新を確認…", action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        menu.addItem(check)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        // menu を設定したままだと左クリックも奪うので、出し終えたら外す
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // メニュー項目のアクションはメニューが閉じてから送られるので、同期で呼んでよい
    @objc private func checkForUpdates() { model.onCheckForUpdates() }
    @objc private func quit() { NSApp.terminate(nil) }

    /// 許可待ちが threshold 秒以上続いているセッションが1つでもあれば true（メニューバーの強調用）
    nonisolated static func needsEmphasis(repos: [Repo], now: Date, threshold: TimeInterval = 300) -> Bool {
        repos.contains { repo in
            repo.sessions.contains { $0.status == .waiting && now.timeIntervalSince($0.statusSince) >= threshold }
        }
    }

    /// 数または強調の有無が変わったときだけ画像を作り直す
    private func updateImage(repos: [Repo]) {
        currentRepos = repos
        let sessions = repos.flatMap(\.sessions)
        let counts = (waiting: sessions.filter { $0.status == .waiting }.count,
                      running: sessions.filter { $0.status == .running }.count,
                      total: sessions.count,
                      emphasized: Self.needsEmphasis(repos: repos, now: Date()))
        if let last = lastCounts, last == counts { return }
        lastCounts = counts
        statusItem.button?.image = Self.makeImage(waiting: counts.waiting, running: counts.running, total: counts.total,
                                                   emphasized: counts.emphasized)
    }

    nonisolated private static var countFont: NSFont { NSFont.systemFont(ofSize: 12, weight: .bold) }
    nonisolated private static var totalFont: NSFont { NSFont.systemFont(ofSize: 11) }
    nonisolated private static let dotSize: CGFloat = 9
    nonisolated private static let dotGap: CGFloat = 3
    nonisolated private static let itemSpace: CGFloat = 7

    nonisolated private static func attrs(_ f: NSFont, white: Bool = false) -> [NSAttributedString.Key: Any] {
        [.font: f, .foregroundColor: white ? NSColor.white : NSColor.labelColor]
    }

    /// 画像の全体幅と、各項目（点+文字）の x 方向の範囲を求める。描画はこの結果に従う。
    /// emphasized のときは許可待ちの項目の左右に pad の余白が付き、後続の項目はその分ずれる
    nonisolated static func layout(waiting: Int, running: Int, total: Int, emphasized: Bool) -> (width: CGFloat, items: [CGRect]) {
        let texts: [(hasDot: Bool, text: String, font: NSFont)] = [
            (true, "\(waiting)", countFont),
            (true, "\(running)", countFont),
            (false, "/ \(total)", totalFont),
        ]
        let pad: CGFloat = emphasized ? 4 : 0  // 下地の左右の余白
        var x = pad
        var rects: [CGRect] = []
        for (index, t) in texts.enumerated() {
            let w = (t.hasDot ? dotSize + dotGap : 0) + (t.text as NSString).size(withAttributes: attrs(t.font)).width
            rects.append(CGRect(x: x, y: 0, width: w, height: 18))
            x += w + (index == 0 ? pad : 0)  // 下地の右の余白（強調時のみ pad が非0）
            if index < texts.count - 1 { x += itemSpace }
        }
        return (x, rects)
    }

    /// 「橙の点+許可待ち数 / 青の点+実行中数 / / タブ数」をカラーで描く。
    /// emphasized のときは橙の点と数字の後ろに橙の角丸の下地を敷き、数字を白にする。
    /// 描画クロージャは表示のたびに呼ばれるので、NSColor.labelColor がメニューバーの外観に追従する
    private static func makeImage(waiting: Int, running: Int, total: Int, emphasized: Bool) -> NSImage {
        // 点の色は Theme.color(for:) と合わせる
        let items: [(NSColor?, String, NSFont)] = [
            (NSColor(Theme.color(for: .waiting)), "\(waiting)", countFont),
            (NSColor(Theme.color(for: .running)), "\(running)", countFont),
            (nil, "/ \(total)", totalFont),
        ]
        let pad: CGFloat = emphasized ? 4 : 0
        let (width, frames) = layout(waiting: waiting, running: running, total: total, emphasized: emphasized)
        let image = NSImage(size: NSSize(width: ceil(width), height: 18), flipped: false) { rect in
            for (index, (color, text, f)) in items.enumerated() {
                var x = frames[index].minX
                let onBadge = emphasized && index == 0  // 許可待ちの項目だけ下地の上に載る
                let str = text as NSString
                let sz = str.size(withAttributes: attrs(f))
                if onBadge {
                    let badge = NSRect(x: 0, y: 1, width: pad * 2 + frames[index].width, height: rect.height - 2)
                    items[0].0!.setFill()
                    NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
                }
                if let color {
                    // 下地が橙なので、点は白で描いて見分けがつくようにする
                    (onBadge ? NSColor.white : color).setFill()
                    NSBezierPath(ovalIn: NSRect(x: x, y: (rect.height - dotSize) / 2, width: dotSize, height: dotSize)).fill()
                    x += dotSize + dotGap
                }
                str.draw(at: NSPoint(x: x, y: (rect.height - sz.height) / 2), withAttributes: attrs(f, white: onBadge))
            }
            return true
        }
        image.isTemplate = false  // カラーのまま描く
        return image
    }
}
