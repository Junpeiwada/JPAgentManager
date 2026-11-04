// P1-6 スパイク: libproc で claude プロセスと作業フォルダを取り、CPU 使用率を測る
// 使い方: ProcScan            … 1回取って表で出す
//         ProcScan --loop 60  … 2秒ごと(--interval で変更可)に60秒取り続け、自分の CPU 使用率を出す
import Darwin
import Foundation

// proc_pidpath のバッファ上限（PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN）
let pathMax = 4 * Int(MAXPATHLEN)

struct Proc {
    var pid: pid_t
    var ppid: pid_t
    var path: String
    var parentPath: String
    var cwd: String
    var start: Date
    var kind: String // "vscode" / "cli"
}

func pidPath(_ pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: pathMax)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    return n > 0 ? String(cString: buf) : nil
}

func allPids() -> [pid_t] {
    // 注意: proc_listallpids は戻り値が「バイト数」ではなく「PID の個数」（proc_listpids とは単位が違う）。
    // nil を渡した戻り値を個数として扱い、増える分の余裕を持たせて確保する
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) + 256)
    let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard got > 0 else { return [] }
    return Array(pids.prefix(Int(got))).filter { $0 > 0 }
}

func classify(_ path: String) -> String? {
    if path.hasSuffix("/native-binary/claude") { return "vscode" }
    if (path as NSString).lastPathComponent == "claude" { return "cli" }
    return nil
}

func scan() -> (procs: [Proc], failures: [String]) {
    var out: [Proc] = []
    var fails: [String] = []
    for pid in allPids() {
        guard let path = pidPath(pid), let kind = classify(path) else { continue }
        var bsd = proc_bsdinfo()
        let r1 = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard r1 == Int32(MemoryLayout<proc_bsdinfo>.size) else {
            fails.append("pid \(pid): TBSDINFO 失敗 (r=\(r1), errno=\(errno))"); continue
        }
        var vn = proc_vnodepathinfo()
        let r2 = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vn, Int32(MemoryLayout<proc_vnodepathinfo>.size))
        var cwd = "?"
        if r2 == Int32(MemoryLayout<proc_vnodepathinfo>.size) {
            cwd = withUnsafePointer(to: &vn.pvi_cdir.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
        } else {
            fails.append("pid \(pid): VNODEPATHINFO 失敗 (r=\(r2), errno=\(errno))")
        }
        let ppid = pid_t(bsd.pbi_ppid)
        out.append(Proc(pid: pid, ppid: ppid, path: path, parentPath: pidPath(ppid) ?? "?", cwd: cwd,
                        start: Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1e6),
                        kind: kind))
    }
    return (out.sorted { $0.pid < $1.pid }, fails)
}

func printTable(_ procs: [Proc]) {
    let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"
    for p in procs {
        let host = p.parentPath.contains("Code Helper (Plugin)") ? "拡張ホスト" : "その他"
        print("pid=\(p.pid) ppid=\(p.ppid)(\(host)) kind=\(p.kind) start=\(f.string(from: p.start))")
        print("   cwd=\(p.cwd)")
        print("   parent=\((p.parentPath as NSString).lastPathComponent)")
    }
}

func cpuSeconds() -> Double {
    var u = rusage(); getrusage(RUSAGE_SELF, &u)
    func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return s(u.ru_utime) + s(u.ru_stime)
}

let args = CommandLine.arguments
func opt(_ name: String) -> Double? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return Double(args[i + 1])
}

if let total = opt("--loop") {
    let interval = opt("--interval") ?? 2
    let wall0 = Date(), cpu0 = cpuSeconds()
    var prev = Set<pid_t>()
    var first = true
    var scans = 0, maxMs = 0.0, sumMs = 0.0
    while Date().timeIntervalSince(wall0) < total {
        let t0 = Date()
        let (procs, fails) = scan()
        let ms = Date().timeIntervalSince(t0) * 1000
        scans += 1; sumMs += ms; maxMs = max(maxMs, ms)
        let cur = Set(procs.map(\.pid))
        if first {
            print("[初回] \(procs.count) 件: \(procs.map { String($0.pid) }.joined(separator: ","))")
            first = false
        } else {
            let added = cur.subtracting(prev), gone = prev.subtracting(cur)
            if !added.isEmpty || !gone.isEmpty {
                print("[\(String(format: "%.0f", Date().timeIntervalSince(wall0)))s] 増: \(added.sorted()) 消: \(gone.sorted())")
                for p in procs where added.contains(p.pid) { print("   新規 pid=\(p.pid) cwd=\(p.cwd)") }
            }
        }
        for f in fails { print("  警告: \(f)") }
        prev = cur
        Thread.sleep(forTimeInterval: interval)
    }
    let wall = Date().timeIntervalSince(wall0), cpu = cpuSeconds() - cpu0
    print(String(format: "経過 %.1fs / CPU %.3fs / CPU使用率 %.3f%% / スキャン %d回 平均 %.2fms 最大 %.2fms",
                 wall, cpu, cpu / wall * 100, scans, sumMs / Double(scans), maxMs))
} else {
    let t0 = Date()
    let (procs, fails) = scan()
    let ms = Date().timeIntervalSince(t0) * 1000
    print("全PID走査込みで \(String(format: "%.2f", ms))ms / claude \(procs.count) 件")
    printTable(procs)
    for f in fails { print("警告: \(f)") }
}
