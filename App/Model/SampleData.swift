import Foundation

/// 画面図（案1-メニューバー）と同じ内容のサンプルデータ
enum SampleData {
    private static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Project").path

    static func repos(now: Date = Date()) -> [Repo] {
        func ago(minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func session(_ key: String, _ repo: String, _ status: SessionStatus, minutes: Double,
                     title: String?, action: String? = nil, prompt: String? = nil,
                     unseen: Bool = false, agents: Int = 0, shell: Bool = false) -> Session {
            Session(id: key, pid: nil, cwd: "\(root)/\(repo)", status: status,
                    statusSince: ago(minutes: minutes), title: title,
                    lastAction: action, lastPrompt: prompt, backgroundShell: shell, completedUnseen: unseen,
                    runningAgents: agents)
        }
        func repo(_ name: String, branch: String?, status: GitStatus? = nil, _ sessions: [Session]) -> Repo {
            Repo(id: "\(root)/\(name)", name: name, branch: branch, sessions: sessions, gitStatus: status)
        }

        return [
            repo("PhotoSorter", branch: "main",
                 status: GitStatus(upstream: "origin/main", ahead: 1, behind: 3, changedFiles: 5), [
                session("sample-photo-1", "PhotoSorter", .waiting, minutes: 2,
                        title: "写真選別画面にお気に入りフィルタを追加",
                        action: "Bash: npm run tauri build",
                        prompt: "フィルタの状態を localStorage に保存して"),
                session("sample-photo-2", "PhotoSorter", .running, minutes: 45,
                        title: "画像補正パラメータの比較実験",
                        action: "Edit: src/filter/config.ts", agents: 3),
                session("sample-photo-3", "PhotoSorter", .idle, minutes: 25,
                        title: "README の手順を新UIに合わせて更新",
                        action: "返答済み（Write: README.md）", unseen: true),
            ]),
            repo("Notebook", branch: "feature/agent-view",
                 status: GitStatus(upstream: "origin/feature/agent-view", ahead: 2), [
                session("sample-notebook-1", "Notebook", .running, minutes: 12,
                        title: "複数Macのエージェント統合ビュー",
                        action: "Bash: npm run build", shell: true),
                session("sample-notebook-2", "Notebook", .idle, minutes: 60,
                        title: "同期スクリプトの dry-run 表示を整理",
                        action: "返答済み"),
            ]),
            repo("SensorDemo", branch: "main", [
                session("sample-sensor-1", "SensorDemo", .empty, minutes: 5, title: nil),
            ]),
            repo("Viewer", branch: "main",
                 status: GitStatus(upstream: "origin/main", behind: 12, changedFiles: 2), [
                session("sample-viewer-1", "Viewer", .idle, minutes: 180, title: nil, action: "返答済み"),
            ]),
            repo("SoundKit", branch: "main",
                 status: GitStatus(upstream: "origin/main", fetchFailed: true), [
                session("sample-sound-1", "SoundKit", .idle, minutes: 1500, title: nil, action: "返答済み"),
            ]),
        ]
    }
}
