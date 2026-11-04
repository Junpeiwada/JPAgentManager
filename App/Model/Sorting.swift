import Foundation

/// 並び順の規則（FR-106・FR-107）
enum Sorting {
    /// リポジトリ内のセッションを並べ、リポジトリも並べた結果を返す
    static func sorted(_ repos: [Repo]) -> [Repo] {
        let arranged = repos.map { repo -> Repo in
            var copy = repo
            copy.sessions = sortedSessions(repo.sessions)
            return copy
        }
        return arranged.sorted(by: repoPrecedes)
    }

    /// 待機だけのリポジトリ（セッションが1件以上あり、全部 idle）なら true。FR-107 の折りたたみ対象
    static func isIdleOnly(_ repo: Repo) -> Bool {
        !repo.sessions.isEmpty && repo.sessions.allSatisfy { $0.status == .idle }
    }

    // MARK: - 内部

    /// status 昇順 → statusSince の古い順 → id
    private static func sortedSessions(_ sessions: [Session]) -> [Session] {
        sessions.sorted { a, b in
            if a.status != b.status { return a.status < b.status }
            if a.statusSince != b.statusSince { return a.statusSince < b.statusSince }
            return a.id < b.id
        }
    }

    /// 並べ済みのセッションの先頭（＝一番優先の status で一番古いもの）をリポジトリの代表とする
    private static func repoPrecedes(_ a: Repo, _ b: Repo) -> Bool {
        // セッションが空のリポジトリは最後
        guard let ka = a.sessions.first else {
            guard b.sessions.first != nil else { return tieBreak(a, b) }
            return false
        }
        guard let kb = b.sessions.first else { return true }
        if ka.status != kb.status { return ka.status < kb.status }
        if ka.statusSince != kb.statusSince { return ka.statusSince < kb.statusSince }
        return tieBreak(a, b)
    }

    /// 名前（大文字小文字を無視）→ id
    private static func tieBreak(_ a: Repo, _ b: Repo) -> Bool {
        let order = a.name.caseInsensitiveCompare(b.name)
        if order != .orderedSame { return order == .orderedAscending }
        return a.id < b.id
    }
}
