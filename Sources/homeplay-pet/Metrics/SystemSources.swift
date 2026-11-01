// 2.0 D1：A 層資料源——全部走公開 API（host_processor_info、host_statistics64、sysctl、IOPowerSources、notify、sysctl NET_RT_IFLIST2、IOKit registry），不需權限。
//
// 做法參考 mactop（MIT，metaspartan/mactop：internal/app/native_stats.go、metrics.go、sys_info.go）、
// Stats（MIT，exelban/stats：Modules/CPU、RAM、Disk、Net、Battery），程式自寫。
// 每個類別只寫自己那幾欄；讀不到就不寫，讓欄位保持 nil。

import Foundation
import Darwin
import IOKit
import IOKit.ps
import notify

// MARK: - 共用小工具

private func sysctlInt(_ name: String) -> Int? {
    var v: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
    // sysctl 的整數可能是 32 或 64 位元；只讀到 4 位元組時高位是 0，小端序下直接成立
    return size == 4 ? Int(Int32(truncatingIfNeeded: v)) : Int(v)
}

private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    return String(cString: buf)
}

// MARK: - CPU（tick 差值）

/// 每核與叢集使用率。叢集的 activePercent／mhz／maxMHz 留給 IOReportSource 依 name 補。
final class CPUTickSource: MetricSource {
    let name = "cpu-ticks"
    private var last: [(busy: UInt32, total: UInt32)] = []
    /// 依 CPU 編號排好的叢集範圍
    private var layout: [(name: String, range: Range<Int>)] = []

    init() {}

    func start() -> Bool {
        // Apple Silicon 的 CPU 編號從最省電的叢集排起：這台 M5 的 IORegistry cpu0–5 是 cluster-type E、cpu6–9 是 P，
        // 而 hw.perflevel0 是最快的叢集（Super），所以叢集要倒著 perflevel 編號排。mactop 也假設 E 核在前。
        let n = sysctlInt("hw.nperflevels") ?? 0
        var start = 0
        for level in stride(from: n - 1, through: 0, by: -1) {
            guard let count = sysctlInt("hw.perflevel\(level).logicalcpu"), count > 0 else { layout = []; break }
            let name = sysctlString("hw.perflevel\(level).name") ?? "L\(level)"
            layout.append((name, start..<start + count))
            start += count
        }
        return readTicks() != nil
    }

    func sample(into s: inout MetricSnapshot, interval: TimeInterval?) {
        guard let now = readTicks() else { return }
        defer { last = now }
        // 第一次（或 CPU 數變了）沒有差值；叢集條目照樣先建好，讓 IOReportSource 有地方填
        let usage: [Double]? = (last.count == now.count) ? zip(now, last).map { cur, old in
            // tick 是 32 位元會繞回，用溢位減法
            let total = cur.total &- old.total
            return total == 0 ? 0 : min(100, Double(cur.busy &- old.busy) / Double(total) * 100)
        } : nil

        if let usage {
            s.coreUsage = usage
            s.cpuPercent = usage.reduce(0, +) / Double(usage.count)
        }
        if layout.last?.range.upperBound == now.count {
            s.clusters = layout.map { c in
                let avg = usage.map { u in c.range.map { u[$0] }.reduce(0, +) / Double(c.range.count) }
                return CPUCluster(name: c.name, short: String(c.name.prefix(1)), cores: c.range.count, usagePercent: avg)
            }
        }
    }

    private func readTicks() -> [(busy: UInt32, total: UInt32)]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { i in
            let t = { (state: Int32) in UInt32(bitPattern: info[i * stride + Int(state)]) }
            let busy = t(CPU_STATE_USER) &+ t(CPU_STATE_SYSTEM) &+ t(CPU_STATE_NICE)
            return (busy, busy &+ t(CPU_STATE_IDLE))
        }
    }
}

// MARK: - 記憶體

final class MemorySource: MetricSource {
    let name = "memory"
    private var total: UInt64 = 0

    init() {}

    func start() -> Bool {
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &total, &size, nil, 0) == 0, total > 0 else { return false }
        return true
    }

    func sample(into s: inout MetricSnapshot, interval: TimeInterval?) {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }

        let page = UInt64(vm_kernel_page_size)
        // 活動監視器的「已使用」＝App 記憶體（匿名頁扣掉可清除）＋固定＋壓縮。
        // 用 internal_page_count 而不是 total−(free+inactive)：大量匿名頁會停在 inactive 佇列（例如模型權重），那些不能隨手回收。同 mactop。
        let anonymous = UInt64(vm.internal_page_count) * page
        let purgeable = UInt64(vm.purgeable_count) * page
        let wired = UInt64(vm.wire_count) * page
        let compressed = UInt64(vm.compressor_page_count) * page
        let used = min(total, (anonymous > purgeable ? anonymous - purgeable : 0) + wired + compressed)

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let hasSwap = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0

        s.memory = MemoryReading(totalBytes: total, usedBytes: used, wiredBytes: wired, compressedBytes: compressed,
                                 swapUsedBytes: hasSwap ? swap.xsu_used : 0, swapTotalBytes: hasSwap ? swap.xsu_total : 0,
                                 pressureLevel: sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1)
    }
}

// MARK: - 電池

/// 沒有內建電池的桌機：start 照樣成功，battery 永遠留 nil。
final class BatterySource: MetricSource {
    let name = "battery"

    init() {}

    func start() -> Bool { true }

    func sample(into s: inout MetricSnapshot, interval: TimeInterval?) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  d[kIOPSIsPresentKey] as? Bool ?? true,
                  let cur = d[kIOPSCurrentCapacityKey] as? Double,
                  let max = d[kIOPSMaxCapacityKey] as? Double, max > 0 else { continue }
            s.battery = BatteryReading(percent: min(100, cur / max * 100),
                                       charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                                       onAC: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
            return
        }
    }
}

// MARK: - 熱壓力

/// 讀 5 級的 thermalpressurelevel；notify 不通才退回 ProcessInfo 的 4 級。
final class ThermalSource: MetricSource {
    let name = "thermal"
    private static let invalid: Int32 = -1
    private var token: Int32 = ThermalSource.invalid

    init() {}

    deinit { if token != Self.invalid { notify_cancel(token) } }

    func start() -> Bool {
        if notify_register_check("com.apple.system.thermalpressurelevel", &token) != NOTIFY_STATUS_OK {
            token = Self.invalid
        }
        return true
    }

    func sample(into s: inout MetricSnapshot, interval: TimeInterval?) {
        var state: UInt64 = 0
        if token != Self.invalid, notify_get_state(token, &state) == NOTIFY_STATUS_OK,
           let level = ThermalPressure(rawValue: Int(state)) {
            s.thermalPressure = level
            return
        }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: s.thermalPressure = .nominal
        // 實測 notify=2（heavy）時 thermalState 還是 fair：fair 涵蓋 moderate＋heavy，往上各升一級才不會晚一級亮燈
        case .fair: s.thermalPressure = .moderate
        case .serious: s.thermalPressure = .trapping
        case .critical: s.thermalPressure = .sleeping
        @unknown default: break
        }
    }
}

// MARK: - 磁碟容量

/// 使用者看得到的卷宗：開機碟＋/Volumes 底下的外接碟，略過 Recovery、Preboot、VM 這些系統卷（同 mactop 的排除表）。
final class VolumeSource: MetricSource {
    let name = "volumes"
    private static let excluded: Set<String> = ["Recovery", "Preboot", "VM", "Update", "xarts", "iSCPreboot", "Hardware"]
    /// 先只拿便宜的屬性過濾；容量要 statfs，網路卷（SMB/AFP/NFS）伺服器睡著時會卡住取樣執行緒，所以只對本機卷問
    private let filterKeys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsBrowsableKey]
    private let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                             .volumeIsInternalKey]

    init() {}

    func start() -> Bool { true }

    func sample(into s: inout MetricSnapshot, interval: TimeInterval?) {
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: filterKeys,
                                                               options: [.skipHiddenVolumes]) else { return }
        s.volumes = urls.compactMap { url in
            let path = url.path
            guard path == "/" || (path.hasPrefix("/Volumes/") && !Self.excluded.contains(url.lastPathComponent)),
                  let f = try? url.resourceValues(forKeys: Set(filterKeys)), f.volumeIsLocal == true,
                  f.volumeIsBrowsable ?? true,
                  let v = try? url.resourceValues(forKeys: keys),
                  let total = v.volumeTotalCapacity, total > 0,
                  let avail = v.volumeAvailableCapacity else { return nil }
            // 用 statfs 那種「可用」（不含可清除空間），跟 df、mactop 一致；
            // ForImportantUsage 會把可清除空間算成可用、而且要現算，數字會比 Finder 以外的工具都小
            let used = Double(max(0, total - avail)) / Double(total) * 100
            return VolumeReading(name: v.volumeLocalizedName ?? url.lastPathComponent, totalBytes: UInt64(total),
                                 usedPercent: used, isInternal: v.volumeIsInternal ?? false)
        }
    }
}

// MARK: - 網路

/// 規格：除了 loopback，所有 UP 的介面加總（docs/homeview-platform.md「網路、磁碟速率」）。
/// 但 VPN／TUN 代理的 utun 跟實體介面載的是同一份位元組——這台實測 utun5 2.38 GB 對 en5 2.24 GB——
/// 全部加總會重複計數，所以鏡像介面（見 mirrorPrefixes）不算；mactop 是除了 lo 全加，開 VPN 時它的數字會偏大。
/// 用 NET_RT_IFLIST2 的 64 位元計數：getifaddrs 的 if_data 是 32 位元，取樣暫停期間過 4 GiB 就會繞回少算。
final class NetworkSource: MetricSource {
    let name = "network"
    /// 這些前綴的介面，流量同時也記在實體介面上（utun／ipsec／gif／stf＝隧道與 VPN，bridge＝成員介面的總和，
    /// llw＝awdl 的鏡像，anpi＝內部聚合，ap＝P2P），加總會重複
    private static let mirrorPrefixes = ["utun", "ipsec", "bridge", "llw", "anpi", "gif", "stf", "ap"]
    /// 介面 index → 上次的累計值
    private var last: [UInt16: (rx: UInt64, tx: UInt64)] = [:]

    init() {}

    func start() -> Bool { readCounters() != nil }

    func sample(into s: inout MetricSnapshot, interval: TimeInterval?) {
        guard let now = readCounters() else { return }
        defer { last = now }
        guard let interval, interval > 0, !last.isEmpty else { return }
        var rx: UInt64 = 0, tx: UInt64 = 0
        for (idx, cur) in now {
            // 鏡像介面除外；名字查不到（介面剛好消失）就照規格算進去
            if let n = Self.ifName(idx), Self.mirrorPrefixes.contains(where: n.hasPrefix) { continue }
            // 新出現的介面沒有基準；介面重建、計數歸零時這次不算
            guard let old = last[idx], cur.rx >= old.rx, cur.tx >= old.tx else { continue }
            rx += cur.rx - old.rx
            tx += cur.tx - old.tx
        }
        s.netInBytesPerSec = Double(rx) / interval
        s.netOutBytesPerSec = Double(tx) / interval
    }

    private func readCounters() -> [UInt16: (rx: UInt64, tx: UInt64)]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return nil }

        var out: [UInt16: (rx: UInt64, tx: UInt64)] = [:]
        buf.withUnsafeBytes { raw in
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                guard hdr.ifm_msglen > 0 else { break }
                defer { off += Int(hdr.ifm_msglen) }
                guard Int32(hdr.ifm_type) == RTM_IFINFO2,
                      off + MemoryLayout<if_msghdr2>.size <= len else { continue }
                let m = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                guard Int32(m.ifm_flags) & IFF_UP != 0, Int32(m.ifm_flags) & IFF_LOOPBACK == 0 else { continue }
                out[m.ifm_index] = (m.ifm_data.ifi_ibytes, m.ifm_data.ifi_obytes)
            }
        }
        return out
    }

    /// IFLIST2 的訊息只有介面 index 沒有名字，用 if_indextoname 補
    private static func ifName(_ index: UInt16) -> String? {
        var buf = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        guard if_indextoname(UInt32(index), &buf) != nil else { return nil }
        return String(cString: buf)
    }
}

// MARK: - 磁碟讀寫

/// IOBlockStorageDriver 的 Statistics 累計值差分。只算實體碟：映像檔（模擬器 runtime、cryptex）的介面是
/// Virtual Interface，它們的讀寫最後也落在實體碟上，算進來會重複。
/// mactop 改讀 AppleAPFSVolume 的「Bytes read from block device」（只有 APFS 卷、各卷分開），兩邊會有小差。
final class DiskIOSource: MetricSource {
    let name = "disk-io"
    /// registry entry ID → 上次的累計值
    private var last: [UInt64: (r: UInt64, w: UInt64)] = [:]

    init() {}

    func start() -> Bool { readCounters() != nil }

    func sample(into s: inout MetricSnapshot, interval: TimeInterval?) {
        guard let now = readCounters() else { return }
        defer { last = now }
        guard let interval, interval > 0, !last.isEmpty else { return }
        var r: UInt64 = 0, w: UInt64 = 0
        for (id, cur) in now {
            // 碟拔掉又插回會換 ID；計數歸零時（cur < old）這次不算
            guard let old = last[id], cur.r >= old.r, cur.w >= old.w else { continue }
            r += cur.r - old.r
            w += cur.w - old.w
        }
        s.diskReadBytesPerSec = Double(r) / interval
        s.diskWriteBytesPerSec = Double(w) / interval
    }

    private func readCounters() -> [UInt64: (r: UInt64, w: UInt64)]? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iter) }

        var out: [UInt64: (r: UInt64, w: UInt64)] = [:]
        while case let entry = IOIteratorNext(iter), entry != 0 {
            defer { IOObjectRelease(entry) }
            let proto = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, "Protocol Characteristics" as CFString,
                                                        kCFAllocatorDefault,
                                                        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            if (proto as? [String: Any])?["Physical Interconnect"] as? String == "Virtual Interface" { continue }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { continue }
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(entry, &id)
            out[id] = ((stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0,
                       (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0)
        }
        return out
    }
}

// MARK: - 開機時間

final class UptimeSource: MetricSource {
    let name = "uptime"

    init() {}

    func start() -> Bool { Self.bootTime() != nil }

    func sample(into s: inout MetricSnapshot, interval: TimeInterval?) {
        // 每次重讀：牆上時鐘被調（手動改時間、NTP 大幅校正）時核心會改寫 kern.boottime，快取的值會讓開機時間跟著跳
        if let boot = Self.bootTime() { s.uptime = Date().timeIntervalSince(boot) }
    }

    private static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }
}
