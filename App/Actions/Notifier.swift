import Foundation
import os
import UserNotifications

private let logger = Logger(subsystem: "com.junpeiwada.JPAgentManager", category: "Notifier")

/// 通知センターの差し替え口（テストでは偽物を渡す）
protocol NotificationCenterProtocol {
    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?)
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
    func getNotificationSettings(completionHandler: @escaping @Sendable (UNNotificationSettings) -> Void)
}

extension UNUserNotificationCenter: NotificationCenterProtocol {}

/// 通知で出す出来事の種類
enum NotifyKind: Equatable {
    case waiting       // 許可待ち
    case inputNeeded   // 入力待ち
    case completed     // 完了（実行中 → 待機）
    case resolved      // 待ちが解けた／セッションが消えた（配信済み通知を消す）
}

/// 通知 1 件分の判定結果
struct NotifyEvent: Equatable {
    var sessionID: String
    var kind: NotifyKind
    var title: String
    var body: String
}

/// 許可待ち・完了の通知を出し、通知のクリックで sessionID を返す（FR-202, FR-203）
@MainActor final class Notifier: NSObject {
    private let center: NotificationCenterProtocol
    /// 通知の許可があるかを返す差し替え口。nil なら center の設定から判定する
    private let authorizedProvider: ((@escaping (Bool) -> Void) -> Void)?
    /// 前回の update 時点の状態。nil は初回（初回は通知しない）
    private var previous: [String: SessionStatus]?

    /// 通知のクリックで sessionID を渡す
    var onActivate: (String) -> Void = { _ in }

    init(center: NotificationCenterProtocol = UNUserNotificationCenter.current(),
         authorized: ((@escaping (Bool) -> Void) -> Void)? = nil) {
        self.center = center
        self.authorizedProvider = authorized
        super.init()
        // delegate は本物の通知センターのときだけ設定する
        if let real = center as? UNUserNotificationCenter { real.delegate = self }
    }

    /// 通知の許可を求める。拒否されても何もしない
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// 前回から状態が変わったセッションを通知する。初回は通知しない。
    /// 起動直後の誤通知は「previous に無いセッションは通知しない」規則で防いでいる
    func update(repos: [Repo]) {
        var snapshot: [String: SessionStatus] = [:]
        for repo in repos {
            for s in repo.sessions { snapshot[s.id] = s.status }
        }
        defer { previous = snapshot }
        guard let previous else { return }

        let notifyCompletion = UserDefaults.standard.bool(forKey: "notifyCompletion")
        let events = Self.events(previous: previous, current: repos, notifyCompletion: notifyCompletion)
        // 実行中に戻ったセッションの完了通知は消す
        for (id, status) in snapshot where status == .running {
            if let old = previous[id], old != .running {
                center.removeDeliveredNotifications(withIdentifiers: [Self.completedIdentifier(id)])
            }
        }
        for event in events {
            switch event.kind {
            case .resolved:
                center.removeDeliveredNotifications(withIdentifiers: [Self.waitingIdentifier(event.sessionID)])
            case .waiting, .inputNeeded:
                post(identifier: Self.waitingIdentifier(event.sessionID), event: event)
            case .completed:
                post(identifier: Self.completedIdentifier(event.sessionID), event: event)
            }
        }
    }

    /// 窓を前に出せなかったときの通知（sessionID なし）
    func notifyFailure(_ message: String) {
        notifyFailure(message, fallback: { _ in })
    }

    /// 通知の許可が無い、または送れなかったときは fallback(message) をメインで呼ぶ
    func notifyFailure(_ message: String, fallback: @escaping @MainActor (String) -> Void) {
        checkAuthorized { [self] ok in
            guard ok else {
                Task { @MainActor in fallback(message) }
                return
            }
            sendFailure(message, fallback: fallback)
        }
    }

    private func checkAuthorized(_ done: @escaping (Bool) -> Void) {
        if let authorizedProvider { authorizedProvider(done); return }
        center.getNotificationSettings { settings in
            let status = settings.authorizationStatus
            done(status == .authorized || status == .provisional)
        }
    }

    private func sendFailure(_ message: String, fallback: @escaping @MainActor (String) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = "前に出せませんでした"
        content.body = message
        let request = UNNotificationRequest(identifier: "failure-\(UUID().uuidString)", content: content, trigger: nil)
        center.add(request) { error in
            guard let error else { return }
            logger.error("失敗通知を送れませんでした: \(error.localizedDescription)")
            Task { @MainActor in fallback(message) }
        }
    }

    private static func waitingIdentifier(_ sessionID: String) -> String { "waiting-\(sessionID)" }
    private static func completedIdentifier(_ sessionID: String) -> String { "completed-\(sessionID)" }

    private func post(identifier: String, event: NotifyEvent) {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.sound = .default
        content.userInfo = ["sessionID": event.sessionID]
        // 同じ identifier なら通知センター上で置き換わり、重ならない
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request) { error in
            if let error { logger.error("通知を送れませんでした: \(error.localizedDescription)") }
        }
    }

    /// 前回と今回の状態を比べて通知すべき出来事を返す。
    /// previous に無いセッション（起動直後・新しいタブ）は通知しない
    nonisolated static func events(previous: [String: SessionStatus], current: [Repo], notifyCompletion: Bool) -> [NotifyEvent] {
        var result: [NotifyEvent] = []
        var seen = Set<String>()
        for repo in current {
            for s in repo.sessions {
                seen.insert(s.id)
                guard let old = previous[s.id], old != s.status else { continue }
                let body = bodyText(s)
                switch (old, s.status) {
                case (_, .waiting):
                    let input = s.waitingFor == "input needed"
                    result.append(NotifyEvent(
                        sessionID: s.id,
                        kind: input ? .inputNeeded : .waiting,
                        title: (input ? "入力待ち: " : "許可待ち: ") + repo.name,
                        body: body))
                case (.waiting, _):
                    result.append(NotifyEvent(sessionID: s.id, kind: .resolved, title: "", body: ""))
                case (.running, .idle):
                    if notifyCompletion {
                        result.append(NotifyEvent(sessionID: s.id, kind: .completed, title: "完了: " + repo.name, body: body))
                    }
                default:
                    break
                }
            }
        }
        // 消えたセッションは、出ていた待ち通知を片づける
        for (id, status) in previous where !seen.contains(id) && status == .waiting {
            result.append(NotifyEvent(sessionID: id, kind: .resolved, title: "", body: ""))
        }
        return result
    }

    private nonisolated static func bodyText(_ s: Session) -> String {
        if let t = s.title, !t.isEmpty { return t }
        if let p = s.lastPrompt, !p.isEmpty { return p }
        return "（タイトル未取得）"
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    /// アプリが前面でも表示する
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// 通知のクリックで sessionID を渡す
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["sessionID"] as? String
        Task { @MainActor in
            if let id { self.onActivate(id) }
            completionHandler()
        }
    }
}
