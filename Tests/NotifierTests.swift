import XCTest
import UserNotifications
@testable import JPAgentManager

final class NotifierTests: XCTestCase {
    private func repo(_ status: SessionStatus, id: String = "s1", waitingFor: String? = nil,
                      title: String? = "目標", lastPrompt: String? = nil) -> Repo {
        let s = Session(id: id, pid: nil, cwd: "/x", status: status, statusSince: Date(),
                        title: title, lastAction: nil, lastPrompt: lastPrompt, waitingFor: waitingFor)
        return Repo(id: "/x", name: "proj", branch: nil, sessions: [s])
    }

    func testPreviousに無いセッションは通知しない() {
        let ev = Notifier.events(previous: [:], current: [repo(.waiting)], notifyCompletion: true)
        XCTAssertEqual(ev, [])
    }

    func test実行中から許可待ちで通知() {
        let ev = Notifier.events(previous: ["s1": .running], current: [repo(.waiting, waitingFor: "permission prompt")], notifyCompletion: false)
        XCTAssertEqual(ev, [NotifyEvent(sessionID: "s1", kind: .waiting, title: "許可待ち: proj", body: "目標")])
    }

    func test入力待ちは別の種類() {
        let ev = Notifier.events(previous: ["s1": .running], current: [repo(.waiting, waitingFor: "input needed")], notifyCompletion: false)
        XCTAssertEqual(ev.first?.kind, .inputNeeded)
        XCTAssertEqual(ev.first?.title, "入力待ち: proj")
    }

    func test本文はtitle_lastPrompt_未取得の順() {
        let a = Notifier.events(previous: ["s1": .running], current: [repo(.waiting, title: nil, lastPrompt: "指示")], notifyCompletion: false)
        XCTAssertEqual(a.first?.body, "指示")
        let b = Notifier.events(previous: ["s1": .running], current: [repo(.waiting, title: nil)], notifyCompletion: false)
        XCTAssertEqual(b.first?.body, "（タイトル未取得）")
    }

    func test待ちが解けたらresolved() {
        let ev = Notifier.events(previous: ["s1": .waiting], current: [repo(.running)], notifyCompletion: false)
        XCTAssertEqual(ev.map(\.kind), [.resolved])
    }

    func test完了は設定がtrueのときだけ() {
        let on = Notifier.events(previous: ["s1": .running], current: [repo(.idle)], notifyCompletion: true)
        XCTAssertEqual(on.map(\.kind), [.completed])
        XCTAssertEqual(on.first?.title, "完了: proj")
        let off = Notifier.events(previous: ["s1": .running], current: [repo(.idle)], notifyCompletion: false)
        XCTAssertEqual(off, [])
    }

    func test状態が同じなら何もしない() {
        let ev = Notifier.events(previous: ["s1": .waiting], current: [repo(.waiting)], notifyCompletion: true)
        XCTAssertEqual(ev, [])
    }

    func test消えた待ちセッションはresolved() {
        let ev = Notifier.events(previous: ["s1": .waiting], current: [], notifyCompletion: true)
        XCTAssertEqual(ev, [NotifyEvent(sessionID: "s1", kind: .resolved, title: "", body: "")])
    }

    // MARK: - update（偽の通知センター）

    private final class FakeCenter: NotificationCenterProtocol {
        var added: [UNNotificationRequest] = []
        var removed: [String] = []
        var addError: Error?
        func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: ((Error?) -> Void)?) {
            added.append(request)
            completionHandler?(addError)
        }
        func removeDeliveredNotifications(withIdentifiers identifiers: [String]) { removed += identifiers }
        func getNotificationSettings(completionHandler: @escaping (UNNotificationSettings) -> Void) {}
    }

    @MainActor private func makeNotifier(_ center: FakeCenter, authorized: Bool = true) -> Notifier {
        Notifier(center: center, authorized: { $0(authorized) })
    }

    @MainActor func test初回のupdateは通知しない() {
        let c = FakeCenter()
        makeNotifier(c).update(repos: [repo(.waiting)])
        XCTAssertTrue(c.added.isEmpty)
    }

    @MainActor func test待ちへの変化でaddが1回() {
        let c = FakeCenter()
        let n = makeNotifier(c)
        n.update(repos: [repo(.running)])
        n.update(repos: [repo(.waiting, waitingFor: "permission prompt")])
        XCTAssertEqual(c.added.map(\.identifier), ["waiting-s1"])
    }

    @MainActor func test同じ待ちが続いても重ねない() {
        let c = FakeCenter()
        let n = makeNotifier(c)
        n.update(repos: [repo(.running)])
        n.update(repos: [repo(.waiting)])
        n.update(repos: [repo(.waiting)])
        XCTAssertEqual(c.added.count, 1)
    }

    @MainActor func test待ちが解けたらwaitingを消す() {
        let c = FakeCenter()
        let n = makeNotifier(c)
        n.update(repos: [repo(.waiting)])
        n.update(repos: [repo(.idle)])
        XCTAssertEqual(c.removed, ["waiting-s1"])
    }

    @MainActor func test実行中に戻ったらcompletedも消す() {
        let c = FakeCenter()
        let n = makeNotifier(c)
        n.update(repos: [repo(.idle)])
        n.update(repos: [repo(.running)])
        XCTAssertEqual(c.removed, ["completed-s1"])
    }

    @MainActor func test許可なしならfallbackが呼ばれる() async {
        let c = FakeCenter()
        let n = makeNotifier(c, authorized: false)
        let exp = expectation(description: "fallback")
        var got: String?
        n.notifyFailure("失敗") { got = $0; exp.fulfill() }
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(got, "失敗")
        XCTAssertTrue(c.added.isEmpty)
    }

    @MainActor func test許可ありで送れたらfallbackは呼ばれない() async {
        let c = FakeCenter()
        let n = makeNotifier(c)
        let exp = expectation(description: "fallback")
        exp.isInverted = true
        n.notifyFailure("失敗") { _ in exp.fulfill() }
        await fulfillment(of: [exp], timeout: 0.3)
        XCTAssertEqual(c.added.count, 1)
    }

    @MainActor func test送信エラーならfallbackが呼ばれる() async {
        let c = FakeCenter()
        c.addError = NSError(domain: "test", code: 1)
        let n = makeNotifier(c)
        let exp = expectation(description: "fallback")
        n.notifyFailure("失敗") { _ in exp.fulfill() }
        await fulfillment(of: [exp], timeout: 2)
    }
}
