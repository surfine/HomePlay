// 2.0 D2：最忙程序（dynamic content 卡、儀表 C 的底部三名）——libproc 的 proc_pidinfo(PROC_PIDTASKINFO)，不需權限。
//
// 兩次取樣之間每個程序的 CPU 時間（user＋system）增量 ÷ 實際間隔＝CPU%（跟活動監視器一樣，多核心的程序可以超過 100）。
// 只讀目前使用者看得到的程序：別人的、系統的 proc_pidinfo 會失敗就略過，不丟錯。第一次取樣沒有差值，留 nil（錶面不顯示那一行）。

import Foundation
import Darwin

/// 一個忙碌程序：名稱照 BSD info 的 pbi_name（最長 32 字元，比 proc_name 的 16 字元完整，例如「Claude Helper (Renderer)」）
struct ProcessUsage: Codable, Equatable {
    var name: String
    var pid: Int32
    /// 活動監視器那種 CPU%，100＝一個核心滿載
    var cpuPercent: Double
}

final class TopProcessSource: MetricSource {
    let name = "top-process"
    /// 留前幾名（C 版式要三名）
    static let keep = 3
    /// 取樣自己的 pid 不算（取樣本身要花一點 CPU）
    private let ownPid = ProcessInfo.processInfo.processIdentifier
    private var last: [Int32: UInt64] = [:]
    private var timebase = mach_timebase_info_data_t(numer: 1, denom: 1)

    init() {}

    func start() -> Bool {
        mach_timebase_info(&timebase)
        return !readCPUTimes().isEmpty
    }

    func sample(into s: inout MetricSnapshot, interval: TimeInterval?) {
        let now = readCPUTimes()
        defer { last = now }
        guard let interval, interval > 0.05, !last.isEmpty else { return }
        // 新出現的程序沒有上一筆，略過；CPU 時間倒退（pid 被重用）也略過
        var deltas: [(pid: Int32, pct: Double)] = []
        for (pid, t) in now where pid != ownPid {
            guard let old = last[pid], t >= old else { continue }
            let pct = Double(t - old) / 1e9 / interval * 100
            if pct >= 0.1 { deltas.append((pid, pct)) }
        }
        deltas.sort { $0.pct > $1.pct }
        let top = deltas.prefix(Self.keep).compactMap { d -> ProcessUsage? in
            guard let n = processName(d.pid) else { return nil }
            return ProcessUsage(name: n, pid: d.pid, cpuPercent: d.pct)
        }
        s.topProcesses = Array(top)
    }

    /// pid → 累計 CPU 時間（奈秒）
    private func readCPUTimes() -> [Int32: UInt64] {
        let bytes = proc_listallpids(nil, 0)
        guard bytes > 0 else { return [:] }
        var pids = [Int32](repeating: 0, count: Int(bytes) / MemoryLayout<Int32>.size + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard got > 0 else { return [:] }
        var out: [Int32: UInt64] = [:]
        out.reserveCapacity(Int(got))
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        for pid in pids.prefix(Int(got)) where pid > 0 {
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }
            let ticks = info.pti_total_user &+ info.pti_total_system   // mach 絕對時間單位（Apple Silicon 上 1 tick ≠ 1 ns）
            out[pid] = ticks &* UInt64(timebase.numer) / UInt64(max(1, timebase.denom))
        }
        return out
    }

    private func processName(_ pid: Int32) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let n = withUnsafePointer(to: &info.pbi_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) * 2) { String(cString: $0) }
        }
        if !n.isEmpty { return n }
        let c = withUnsafePointer(to: &info.pbi_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { String(cString: $0) }
        }
        return c.isEmpty ? nil : c
    }
}
