import Foundation

/// セッションの状態。rawValue が小さいほど優先度が高い（並び順に使う）
enum SessionStatus: Int, CaseIterable, Comparable, Codable {
    case waiting = 0   // 許可待ち・入力待ち
    case running = 1   // 実行中
    case idle = 2      // 待機（返答済み）
    case empty = 3     // 空（タブはあるがまだ指示なし）

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .waiting: return "許可待ち"
        case .running: return "実行中"
        case .idle: return "待機"
        case .empty: return "空"
        }
    }
}

struct Session: Identifiable, Hashable {
    var id: String            // session_id。まだ対応づかないプロセスは "pid-<pid>"
    var pid: Int32?
    var cwd: String
    var status: SessionStatus
    var statusSince: Date     // 今の状態になった時刻
    var title: String?        // 目標（ai-title）
    var lastAction: String?   // 直近の作業（例 "Edit: src/train/config.ts"）
    var lastPrompt: String?   // 最後に送った指示（許可待ちの行だけ表示）
    var waitingFor: String? = nil  // 待ちの理由（"permission prompt" / "input needed"）。waiting のときだけ
    var entrypoint: String? = nil  // 起動元（"claude-vscode" など）。前面化できるのは claude-vscode だけ
    var completedUnseen: Bool = false  // 実行中→待機に変わり、まだ行をクリックしていない（FR-111）

    /// 経過時間の表示。実行中だけ「H:MM」（例 0:45、1:05）。
    /// それ以外は 60秒未満「今」、60分未満「N分」、24時間未満「N時間」、それ以上「N日」。負の値は「今」
    func elapsedText(now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(statusSince)
        if status == .running {
            let totalMinutes = max(0, Int(seconds / 60))
            return String(format: "%d:%02d", totalMinutes / 60, totalMinutes % 60)
        }
        if seconds < 60 { return "今" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)分" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)時間" }
        return "\(hours / 24)日"
    }
}

struct Repo: Identifiable, Hashable {
    var id: String            // git のルートパス（取れなければ cwd）
    var name: String          // フォルダ名
    var branch: String?
    var sessions: [Session]
}
