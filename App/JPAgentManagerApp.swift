import SwiftUI
import AppKit
import Combine

@main
struct JPAgentManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 窓を出さないための空の Scene
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelModel: PanelModel?
    private var statusItemController: StatusItemController?
    private var sessionStore: SessionStore?
    private var cancellable: AnyCancellable?
    private var errorCancellable: AnyCancellable?
    private var notifierCancellable: AnyCancellable?
    private var notifier: Notifier?
    private var updater: UpdaterController?
    private let focusQueue = DispatchQueue(label: "Focuser", qos: .userInitiated)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // テストターゲットは TEST_HOST でアプリを起動するので、XCTest 中は何も作らない
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }

        // Dock に出さないメニューバー常駐にする
        NSApp.setActivationPolicy(.accessory)

        // --sample のときだけサンプルデータを表示する（見た目の確認用）。SessionStore は作らない
        let useSample = CommandLine.arguments.contains("--sample")
        let model = PanelModel(repos: useSample ? SampleData.repos() : [])
        let notifier = Notifier()
        self.notifier = notifier
        // 前面化は背景のキューで行い、失敗したらメインで理由を通知する。
        // 通知が出せないときはパネルの注意書きに出し、音も鳴らす
        let focus: (Session) -> Void = { [weak self, weak notifier, weak model] session in
            // どのセッションの失敗かが分かるよう、リポジトリ名とタイトルを添える
            let repoName = model?.repos.first(where: { $0.sessions.contains { $0.id == session.id } })?.name
            let label = [repoName, session.title].compactMap { $0 }.joined(separator: " / ")
            self?.focusQueue.async {
                if case .failure(let error) = Focuser().focus(session) {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            let message = label.isEmpty ? error.message : "\(label): \(error.message)"
                            NSSound.beep()
                            notifier?.notifyFailure(message, fallback: { model?.lastError = $0 })
                        }
                    }
                }
            }
        }
        model.onSelect = focus
        notifier.onActivate = { [weak model, weak notifier] sessionID in
            // 完了通知のクリックも確認とみなす
            model?.markSeen(sessionID)
            guard let session = model?.repos.flatMap(\.sessions).first(where: { $0.id == sessionID }) else {
                notifier?.notifyFailure("セッションが見つかりません（閉じられた可能性があります）",
                                        fallback: { model?.lastError = $0 })
                return
            }
            focus(session)
        }
        notifier.requestAuthorization()
        // アプリ内更新（Sparkle）。--sample でも作る。所有は AppDelegate が持ち、model のクロージャからは weak で参照する
        let updater = UpdaterController()
        self.updater = updater
        model.onCheckForUpdates = { [weak updater] in updater?.checkForUpdates() }
        panelModel = model
        statusItemController = StatusItemController(model: model)

        if !useSample {
            let store = SessionStore()
            sessionStore = store
            // SessionStore の repos をパネルへ流し込む
            cancellable = store.$repos
                .receive(on: DispatchQueue.main)
                .sink { [weak model] repos in model?.update(repos: repos) }
            errorCancellable = store.$lastError
                .receive(on: DispatchQueue.main)
                .sink { [weak model] message in model?.lastError = message }
            // 状態の変化から通知を出す
            notifierCancellable = store.$repos
                .receive(on: DispatchQueue.main)
                .sink { [weak notifier] repos in notifier?.update(repos: repos) }
            store.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessionStore?.stop()
    }
}
