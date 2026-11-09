import Combine
import Foundation

/// セッションファイル・プロセス・会話ログ・git を突き合わせて、リポジトリごとの一覧を作る
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var repos: [Repo] = []
    /// sessions フォルダが読めない等。無ければ nil
    @Published private(set) var lastError: String? = nil

    private let registry: SessionRegistry
    private let sessionsDirectory: URL
    private let transcripts: TranscriptReader
    private let gitInfo: @Sendable (String) -> GitInfo.Info?
    private let gitStatus: @Sendable (String) -> GitStatus?
    private let gitFetch: @Sendable (String) -> Bool
    private let now: @Sendable () -> Date

    /// セッション・会話ログの読み込み用。git が遅くても状態の反映を止めないため、git とは別のキューにする
    private let worker = DispatchQueue(label: "SessionStore.refresh", qos: .userInitiated)
    private let gitWorker = DispatchQueue(label: "SessionStore.git", qos: .utility, attributes: .concurrent)
    /// deinit から止めるため nonisolated(unsafe)。触るのはメインスレッドと deinit だけ
    private nonisolated(unsafe) var timer: Timer?
    private var isRefreshing = false
    private var needsRefresh = false
    /// 前回の会話ログのパス（消えたパスだけ forget するため）
    private var knownTranscriptPaths: Set<String> = []
    /// 前回の結果（statusSince の引き継ぎ用）
    private var previousSessions: [String: Session] = [:]
    /// cwd -> 前回の git 結果と取得時刻。nil（git 管理外・タイムアウト）も覚えて再試行を抑える
    private var gitCache: [String: (info: GitInfo.Info?, at: Date)] = [:]
    /// 問い合わせ中の cwd（重ねて問い合わせない）
    private var gitPending: Set<String> = []
    private static let gitTTL: TimeInterval = 30

    /// git ルート -> 前回の status と取得時刻
    private var statusCache: [String: (status: GitStatus?, at: Date)] = [:]
    private var statusPending: Set<String> = []
    /// git ルート -> 次に fetch してよい時刻
    private var nextFetchAt: [String: Date] = [:]
    private var fetchPending: Set<String> = []
    private var fetchFailedRoots: Set<String> = []
    /// fetch は通信するので 1 件ずつ行う
    private let fetchWorker = DispatchQueue(label: "SessionStore.fetch", qos: .utility)
    private static let statusTTL: TimeInterval = 30
    private static let fetchInterval: TimeInterval = 5 * 60
    /// 失敗は認証のダイアログが原因のこともあるので、繰り返し出さないよう間隔を空ける
    private static let fetchRetryInterval: TimeInterval = 15 * 60

    init(registry: SessionRegistry = SessionRegistry(),
         sessionsDirectory: URL = SessionRegistry.defaultDirectory,
         transcripts: TranscriptReader = TranscriptReader(),
         gitInfo: @escaping @Sendable (String) -> GitInfo.Info? = { GitInfo.info(for: $0) },
         gitStatus: @escaping @Sendable (String) -> GitStatus? = { GitStatusReader.status(root: $0) },
         gitFetch: @escaping @Sendable (String) -> Bool = { GitStatusReader.fetch(root: $0) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.registry = registry
        self.sessionsDirectory = sessionsDirectory
        self.transcripts = transcripts
        self.gitInfo = gitInfo
        self.gitStatus = gitStatus
        self.gitFetch = gitFetch
        self.now = now
    }

    deinit {
        timer?.invalidate()
    }

    func start() {
        registry.startWatching { [weak self] in
            // 監視はメインキューで呼ばれる
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.invalidate()
        // 監視は「セッションの増減」しか拾わない（状態の変化はファイルの上書きなので発火しない）。
        // FR-201（2秒以内）のため 1 秒ごとに読み直す
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    func stop() {
        registry.stopWatching()
        timer?.invalidate()
        timer = nil
    }

    /// 重い処理はバックグラウンドで行い、結果だけメインで反映する。重なったら終了後に1回だけ再実行する
    func refresh() {
        // sessions フォルダが後から現れても監視を張り直す（メインスレッドから呼ぶ）
        registry.rewatchIfNeeded()
        if isRefreshing {
            needsRefresh = true
            return
        }
        isRefreshing = true
        // 意図: SessionRegistry・TranscriptReader は内部でロックを持つので、worker（背景）から使ってよい
        let registry = self.registry
        let transcripts = self.transcripts
        let now = self.now
        let sessionsDirectory = self.sessionsDirectory
        let previousPaths = knownTranscriptPaths
        let previousSessions = self.previousSessions
        // git は前回の結果をそのまま使う（遅い問い合わせを待たない）
        var git: [String: GitInfo.Info] = [:]
        for (cwd, cached) in gitCache { if let info = cached.info { git[cwd] = info } }
        var gitStatuses: [String: GitStatus] = [:]
        for (root, cached) in statusCache {
            guard var status = cached.status else { continue }
            status.fetchFailed = fetchFailedRoots.contains(root)
            gitStatuses[root] = status
        }

        worker.async { [weak self] in
            let snapshot = registry.readSnapshot()
            let entries = snapshot.entries
            var error: String? = nil
            if !snapshot.directoryReadable {
                // フォルダが無いだけならエラーにしない（空の一覧）
                if FileManager.default.fileExists(atPath: sessionsDirectory.path) {
                    error = "sessions フォルダを読めません（\(sessionsDirectory.path)）"
                }
            } else if snapshot.unreadableFiles > 0 {
                error = "セッション情報を \(snapshot.unreadableFiles) 件読めませんでした"
            }

            var summaries: [String: TranscriptSummary] = [:]
            var subagents: [String: Int] = [:]
            var paths: Set<String> = []
            let current = now()
            for entry in entries {
                guard let url = registry.transcriptURL(for: entry) else { continue }
                paths.insert(url.path)
                summaries[entry.sessionID] = transcripts.summary(transcriptPath: url.path, cwd: entry.cwd)
                subagents[entry.sessionID] = SubagentCounter.runningCount(transcriptPath: url.path, now: current)
            }
            // 前回あって今回無い会話ログのパスを忘れる
            for path in previousPaths.subtracting(paths) {
                transcripts.forget(transcriptPath: path)
            }
            let built = SessionStore.build(entries: entries, summaries: summaries, git: git,
                                           gitStatuses: gitStatuses,
                                           subagents: subagents,
                                           previous: previousSessions, now: current)
            let cwds = Set(entries.map(\.cwd))

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.knownTranscriptPaths = paths
                    self.previousSessions = Dictionary(
                        built.flatMap(\.sessions).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    if self.repos != built { self.repos = built }
                    if self.lastError != error { self.lastError = error }
                    self.requestGitInfo(for: cwds)
                    self.requestGitStatus()
                    self.isRefreshing = false
                    if self.needsRefresh {
                        self.needsRefresh = false
                        self.refresh()
                    }
                }
            }
        }
    }

    /// 未取得・期限切れ（30秒）の cwd だけ、別キューで非同期に問い合わせる。終わったらキャッシュに入れて refresh する
    private func requestGitInfo(for cwds: Set<String>) {
        let current = now()
        // 無くなった cwd のキャッシュは捨てる
        for cwd in gitCache.keys where !cwds.contains(cwd) { gitCache[cwd] = nil }
        let gitInfo = self.gitInfo
        for cwd in cwds where !gitPending.contains(cwd) {
            if let cached = gitCache[cwd], current.timeIntervalSince(cached.at) < Self.gitTTL { continue }
            gitPending.insert(cwd)
            gitWorker.async { [weak self] in
                let info = gitInfo(cwd)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.gitPending.remove(cwd)
                        let changed = self.gitCache[cwd]?.info != info
                        self.gitCache[cwd] = (info, self.now())
                        // 変わらなければ再描画は不要
                        if changed { self.refresh() }
                    }
                }
            }
        }
    }

    /// 開いているリポジトリの status と fetch を、期限が来たものだけ別キューで行う。
    /// 対象のルートは git の問い合わせ結果から決める（無くなった cwd は requestGitInfo が捨て済み）
    private func requestGitStatus() {
        let current = now()
        let roots = Set(gitCache.values.compactMap { $0.info?.root })
        for root in statusCache.keys where !roots.contains(root) { statusCache[root] = nil }
        for root in nextFetchAt.keys where !roots.contains(root) { nextFetchAt[root] = nil }
        fetchFailedRoots.formIntersection(roots)

        let gitStatus = self.gitStatus
        for root in roots where !statusPending.contains(root) {
            if let cached = statusCache[root], current.timeIntervalSince(cached.at) < Self.statusTTL { continue }
            statusPending.insert(root)
            gitWorker.async { [weak self] in
                let status = gitStatus(root)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.statusPending.remove(root)
                        let changed = self.statusCache[root]?.status != status
                        self.statusCache[root] = (status, self.now())
                        if changed { self.refresh() }
                    }
                }
            }
        }

        let gitFetch = self.gitFetch
        for root in roots where !fetchPending.contains(root) {
            // 上流が無ければコミット差を出せないので通信しない
            guard statusCache[root]?.status?.upstream != nil else { continue }
            if let next = nextFetchAt[root], current < next { continue }
            fetchPending.insert(root)
            fetchWorker.async { [weak self] in
                let succeeded = gitFetch(root)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.fetchPending.remove(root)
                        let wait = succeeded ? Self.fetchInterval : Self.fetchRetryInterval
                        self.nextFetchAt[root] = self.now().addingTimeInterval(wait)
                        if succeeded {
                            self.fetchFailedRoots.remove(root)
                        } else {
                            self.fetchFailedRoots.insert(root)
                        }
                        // コミット差が変わるので、次の refresh ですぐ status を取り直す
                        self.statusCache[root]?.at = .distantPast
                        self.refresh()
                    }
                }
            }
        }
    }

    // MARK: - 組み立て（純粋関数）

    nonisolated static func build(entries: [RegistryEntry],
                                  summaries: [String: TranscriptSummary],
                                  git: [String: GitInfo.Info],
                                  gitStatuses: [String: GitStatus] = [:],
                                  subagents: [String: Int] = [:],
                                  previous: [String: Session] = [:],
                                  now: Date) -> [Repo] {
        var groups: [String: Repo] = [:]
        var order: [String] = []

        for entry in entries {
            let summary = summaries[entry.sessionID]
            let status = status(of: entry, summary: summary)

            var lastAction = summary?.lastAction
            if status == .idle, summary?.endedWithText == true {
                lastAction = lastAction.map { "返答済み（\($0)）" } ?? "返答済み"
            }

            var waitingFor: String? = nil
            if case .waiting(let reason) = entry.status { waitingFor = reason }

            // 状態が変わった時刻。ファイルに無ければ、同じ状態の前回の値を引き継ぐ（毎回 now にしない）。
            // 前回から状態が変わっていれば now、初見のセッションだけ開始時刻を使う
            let since: Date
            if let updated = entry.statusUpdatedAt {
                since = updated
            } else if let prev = previous[entry.sessionID] {
                since = prev.status == status ? prev.statusSince : now
            } else {
                since = entry.startedAt ?? now
            }

            let session = Session(
                id: entry.sessionID,
                pid: entry.pid,
                cwd: entry.cwd,
                status: status,
                statusSince: since,
                title: summary?.title,
                lastAction: lastAction,
                lastPrompt: summary?.lastPrompt,
                waitingFor: waitingFor,
                entrypoint: entry.entrypoint,
                backgroundShell: entry.status == .shell,
                runningAgents: subagents[entry.sessionID] ?? 0)

            let info = git[entry.cwd]
            let id = info?.root ?? entry.cwd
            if groups[id] == nil {
                let name = (id as NSString).lastPathComponent
                groups[id] = Repo(id: id, name: name.isEmpty ? id : name, branch: info?.branch, sessions: [],
                                  gitStatus: gitStatuses[id])
                order.append(id)
            }
            groups[id]?.sessions.append(session)
        }
        return Sorting.sorted(order.compactMap { groups[$0] })
    }

    private nonisolated static func status(of entry: RegistryEntry, summary: TranscriptSummary?) -> SessionStatus {
        switch entry.status {
        case .busy, .shell: return .running
        case .waiting: return .waiting
        case .unknown: return .idle
        case .idle:
            if let summary, summary.title != nil || summary.lastPrompt != nil { return .idle }
            return .empty
        }
    }
}
