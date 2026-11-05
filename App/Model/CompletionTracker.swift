import Foundation

/// 実行中 → 待機に変わったセッションを「未確認の完了」として覚える（FR-111）。
/// 行のクリックで確認済みにする。実行中・許可待ちに戻ったとき、タブが消えたときも外す
struct CompletionTracker {
    /// 未確認の完了の sessionID
    private(set) var unseen: Set<String> = []
    /// 前回の update 時点の状態。nil は初回（初回は印を付けない。起動前に終わったものは対象外）
    private var previous: [String: SessionStatus]?

    mutating func update(repos: [Repo]) {
        var snapshot: [String: SessionStatus] = [:]
        for repo in repos {
            for s in repo.sessions { snapshot[s.id] = s.status }
        }
        defer { previous = snapshot }
        // 待機のままのものだけ残す（消えた・実行中や許可待ちに戻ったものは外す）
        unseen = unseen.filter { snapshot[$0] == .idle }
        guard let previous else { return }
        for (id, status) in snapshot where status == .idle && previous[id] == .running {
            unseen.insert(id)
        }
    }

    mutating func markSeen(_ id: String) {
        unseen.remove(id)
    }

    /// repos の各セッションの completedUnseen を unseen に合わせる
    static func apply(_ unseen: Set<String>, to repos: [Repo]) -> [Repo] {
        repos.map { repo in
            var repo = repo
            repo.sessions = repo.sessions.map { session in
                var session = session
                session.completedUnseen = unseen.contains(session.id)
                return session
            }
            return repo
        }
    }
}
