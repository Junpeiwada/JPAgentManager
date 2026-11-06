import Foundation

/// セッションが起動したサブエージェント（Agent ツール）のうち、いま動いているものを数える。
///
/// 会話ログ `<sid>.jsonl` の隣の `<sid>/subagents/` に、1体ごとに `agent-<id>.meta.json` と
/// `agent-<id>.jsonl` が作られる。meta は起動時に `finished` 無しで書かれ、終わると `"finished":true` 付きで
/// 書き直される（公開仕様ではない。実測）。古い版の meta や途中で落ちたものは `finished` 無しのまま残るので、
/// 会話ログが最近更新されているものだけを数える
enum SubagentCounter {
    /// これより長く会話ログが更新されていなければ、動いていないとみなす。
    /// 長い Bash を待っている間は書き込みが無いので、短くしすぎない
    static let staleAfter: TimeInterval = 15 * 60

    static func runningCount(transcriptPath: String, now: Date = Date()) -> Int {
        guard transcriptPath.hasSuffix(".jsonl") else { return 0 }
        let dir = String(transcriptPath.dropLast(".jsonl".count)) + "/subagents"
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return 0 }

        let suffix = ".meta.json"
        var count = 0
        for name in names where name.hasSuffix(suffix) {
            let metaPath = dir + "/" + name
            guard let data = fm.contents(atPath: metaPath),
                  let meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if meta["finished"] as? Bool == true { continue }

            let logPath = dir + "/" + String(name.dropLast(suffix.count)) + ".jsonl"
            guard let attrs = try? fm.attributesOfItem(atPath: logPath),
                  let modified = attrs[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) < staleAfter else { continue }
            count += 1
        }
        return count
    }
}
