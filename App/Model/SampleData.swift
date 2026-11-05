import Foundation

/// 画面図（案1-メニューバー）と同じ内容のサンプルデータ
enum SampleData {
    private static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Project").path

    static func repos(now: Date = Date()) -> [Repo] {
        func ago(minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func session(_ key: String, _ repo: String, _ status: SessionStatus, minutes: Double,
                     title: String?, action: String? = nil, prompt: String? = nil,
                     unseen: Bool = false) -> Session {
            Session(id: key, pid: nil, cwd: "\(root)/\(repo)", status: status,
                    statusSince: ago(minutes: minutes), title: title,
                    lastAction: action, lastPrompt: prompt, completedUnseen: unseen)
        }
        func repo(_ name: String, branch: String?, _ sessions: [Session]) -> Repo {
            Repo(id: "\(root)/\(name)", name: name, branch: branch, sessions: sessions)
        }

        return [
            repo("PhotoSorter", branch: "main", [
                session("sample-photo-1", "PhotoSorter", .waiting, minutes: 2,
                        title: "写真選別画面にお気に入りフィルタを追加",
                        action: "Bash: npm run tauri build",
                        prompt: "フィルタの状態を localStorage に保存して"),
                session("sample-photo-2", "PhotoSorter", .running, minutes: 45,
                        title: "画像補正パラメータの比較実験",
                        action: "Edit: src/filter/config.ts"),
                session("sample-photo-3", "PhotoSorter", .idle, minutes: 25,
                        title: "README の手順を新UIに合わせて更新",
                        action: "返答済み（Write: README.md）", unseen: true),
            ]),
            repo("Notebook", branch: "main", [
                session("sample-notebook-1", "Notebook", .running, minutes: 12,
                        title: "複数Macのエージェント統合ビュー",
                        action: "Write: 図/案1-メニューバー.svg"),
                session("sample-notebook-2", "Notebook", .idle, minutes: 60,
                        title: "同期スクリプトの dry-run 表示を整理",
                        action: "返答済み"),
            ]),
            repo("SensorDemo", branch: "main", [
                session("sample-sensor-1", "SensorDemo", .empty, minutes: 5, title: nil),
            ]),
            repo("Viewer", branch: "main", [
                session("sample-viewer-1", "Viewer", .idle, minutes: 180, title: nil, action: "返答済み"),
            ]),
            repo("SoundKit", branch: "main", [
                session("sample-sound-1", "SoundKit", .idle, minutes: 1500, title: nil, action: "返答済み"),
            ]),
        ]
    }
}
