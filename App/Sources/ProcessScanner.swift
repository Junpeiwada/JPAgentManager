import Darwin
import Foundation

/// VSCode の Claude タブとして動いている claude プロセス
/// 同じプロセスかどうかは id（pid と startTime）で見る。== は全項目の比較なので cwd などの変化も検出できる
struct ClaudeProcess: Hashable, Identifiable {
    var pid: Int32
    var startTime: Date         // 起動時刻（PID 再利用の見分けに使う）
    var cwd: String?
    var parentPID: Int32        // 拡張ホスト（VSCode の窓1つに1つ）

    var id: String { "\(pid)-\(startTime.timeIntervalSince1970)" }
}

/// libproc で claude プロセスを数える（Spike/ProcScan/RESULT.md 参照）
enum ProcessScanner {
    /// proc_pidpath のバッファ上限（PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN）
    private static let pathMax = 4 * Int(MAXPATHLEN)

    /// VSCode の Claude タブの claude プロセスだけ（pid 昇順）
    static func scan() -> [ClaudeProcess] {
        var result: [ClaudeProcess] = []
        for pid in allPIDs() {
            guard let path = pidPath(pid), path.hasSuffix(claudeSuffix) else { continue }

            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { continue }

            // SDK 経由で動く claude は親が拡張ホストではないので除く
            let ppid = pid_t(bsd.pbi_ppid)
            guard isVSCodeTab(path: path, parentPath: pidPath(ppid)) else { continue }

            // パス確認から bsdinfo 取得までの間に PID が再利用されていないか確かめる
            guard pidPath(pid) == path else { continue }

            let start = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1e6)
            result.append(ClaudeProcess(pid: pid, startTime: start, cwd: cwd(of: pid), parentPID: ppid))
        }
        return result.sorted { $0.pid < $1.pid }
    }

    private static let claudeSuffix = "/native-binary/claude"

    /// VSCode の Claude タブの claude か。パスが native-binary/claude で、親が拡張ホスト（Code Helper (Plugin)）のもの
    static func isVSCodeTab(path: String, parentPath: String?) -> Bool {
        guard path.hasSuffix(claudeSuffix), let parentPath else { return false }
        return parentPath.contains("Code Helper (Plugin)")
    }

    private static func allPIDs() -> [pid_t] {
        // proc_listallpids の戻り値はバイト数ではなく PID の個数。増える分の余裕を持たせて確保する
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 256)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [] }
        return pids.prefix(Int(got)).filter { $0 > 0 }
    }

    private static func pidPath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: pathMax)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    private static func cwd(of pid: pid_t) -> String? {
        var vn = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vn, size) == size else { return nil }
        let path = withUnsafePointer(to: &vn.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }
}
