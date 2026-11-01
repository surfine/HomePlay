// 2.0 D1：IOReport 資料源——CPU 叢集與 GPU 的駐留比例、加權頻率，Energy Model 功率（不需 root）。
//
// 做法參考 mactop（MIT，internal/app/ioreport.m）、macmon（MIT，src/sources.rs），程式自寫。
// libIOReport 是私有庫：用 dlopen／dlsym 取函式，少任何一個就 start() 回 false，整個資料源停用。
// 所有私有讀值讀不到都留 nil（規格 R11），不印 log。
// 同窗實測（2026-10-29，抓 delta 逐 state 對照）：叢集頻率、忙碌、GPU 跟 mactop 同一個演算法同一張表，數值一致；
// 對照工具裡偶發的落差是兩邊取樣時間窗錯開——頻率是爆發性指標，ms 級 burst 會讓 1 秒窗差到 30%。

import Foundation
import IOKit
import Darwin

final class IOReportSource: MetricSource {
    let name = "IOReport"

    private var api: IOReportAPI?
    private var subscription: OpaquePointer?
    private var subscribed: CFMutableDictionary?
    private var previous: CFDictionary?
    private var previousTime: UInt64 = 0

    private var tiers: [PerfLevel] = []
    private var dvfs: [Int: [Double]] = [:]          // voltage-statesN-sram 的 N → MHz 表（已去掉 0）
    private var tierTable: [String: [Double]] = [:]  // 叢集名 → 選定的 DVFS 表（第一次看到 channel 時決定）
    private var gpuTable: [Double]?

    // Energy Model 停更偵測：每個領域連續幾次「忙碌時差值剛好 0」
    private var zeroStreak: [EnergyDomain: Int] = [:]
    private var gated: Set<EnergyDomain> = []

    init() {}

    func start() -> Bool {
        guard let api = IOReportAPI() else { return false }
        self.api = api

        // 只訂需要的子群組：整個 "CPU Stats" 有每核心的上百個 channel，取樣成本白付。
        let wanted: [(String, String?)] = [
            ("CPU Stats", "CPU Complex Performance States"),
            ("GPU Stats", "GPU Performance States"),
            ("Energy Model", nil),
        ]
        var merged: CFMutableDictionary?
        for (group, sub) in wanted {
            guard let ch = api.copyChannels(group as CFString, sub as CFString?, 0, 0, 0)?.takeRetainedValue() else { continue }
            if let m = merged { api.merge(m, ch, nil) } else { merged = CFDictionaryCreateMutableCopy(nil, 0, ch) }
        }
        guard let channels = merged else { return false }

        var out: Unmanaged<CFMutableDictionary>?
        // 訂閱物件與 out 參數的所有權沒有公開文件；整個 app 只建一次，刻意不釋放，避免多放一次就閃退。
        guard let sub = api.createSubscription(nil, channels, &out, 0, nil), let subbed = out?.takeUnretainedValue() else { return false }
        subscription = sub
        subscribed = subbed

        tiers = PerfLevel.readAll()
        dvfs = readDVFSTables()
        gpuTable = pickGPUTable()
        return true
    }

    func sample(into s: inout MetricSnapshot, interval: TimeInterval?) {
        guard let api, let sub = subscription, let subbed = subscribed,
              let current = api.createSamples(sub, subbed, nil)?.takeRetainedValue() else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        defer { previous = current; previousTime = now }

        // 第一次沒有差值：駐留與能量都要兩次取樣相減，這次只留基準。
        guard let prev = previous,
              let delta = api.createDelta(prev, current, nil)?.takeRetainedValue() else {
            if !hasGPUPH { applyAcceleratorFallback(&s) }
            return
        }
        // 能量換算用兩次取樣的實測間隔（跟計數器同一時刻），取不到才用 interval。
        let measured = Double(now &- previousTime) / 1e9
        let seconds = measured > 0.01 ? measured : (interval ?? 0)

        var cpu: [String: Residency] = [:]
        var gpu = Residency()
        var sawGPUPH = false
        var energy = EnergyTotals()

        forEachChannel(delta) { ch in
            guard let group = api.string(api.getGroup, ch) else { return }
            let channel = api.string(api.getChannelName, ch) ?? ""
            switch group {
            case "CPU Stats":
                guard api.string(api.getSubGroup, ch) == "CPU Complex Performance States",
                      let tier = tierName(forChannel: channel) else { return }
                var r = cpu[tier] ?? Residency()
                accumulate(ch, api: api, into: &r, table: table(forTier: tier, channel: ch, api: api), indexFromV: true)
                cpu[tier] = r
            case "GPU Stats":
                guard channel == "GPUPH", api.string(api.getSubGroup, ch) == "GPU Performance States" else { return }
                sawGPUPH = true
                accumulate(ch, api: api, into: &gpu, table: gpuTable, indexFromV: false)
            case "Energy Model", "Energy Counters":
                // "Energy Counters" 是 macOS 27 的新群組名（mactop 註記），一起收。
                energy.add(channel: channel, unit: api.string(api.getUnitLabel, ch),
                           value: api.simpleInteger(ch, 0))
            default:
                break
            }
        }
        hasGPUPH = sawGPUPH

        // CPU 叢集
        // 照 perflevel 順序（高到低）附加，畫面上的叢集順序才穩定
        for level in tiers {
            guard let r = cpu[level.name], r.total > 0 else { continue }
            let tier = level.name
            let table = tierTable[tier]
            let active = r.active / r.total * 100
            let mhz = r.weightedActive > 0 ? r.weightedMHz / r.weightedActive : nil
            if let i = s.clusters.firstIndex(where: { $0.name == tier }) {
                s.clusters[i].activePercent = active
                s.clusters[i].mhz = mhz
                s.clusters[i].maxMHz = table?.max()
            } else {
                s.clusters.append(CPUCluster(name: tier, short: String(tier.prefix(1)), cores: level.cores,
                                             usagePercent: nil, activePercent: active, mhz: mhz, maxMHz: table?.max()))
            }
        }

        // GPU：GPUPH 的駐留；讀不到（或總駐留為 0）才退回 IOAccelerator 的使用率。
        var gpuActive: Double?
        if sawGPUPH, gpu.total > 0 {
            gpuActive = gpu.active / gpu.total * 100
            s.gpuPercent = gpuActive
            s.gpuMHz = gpu.weightedActive > 0 ? gpu.weightedMHz / gpu.weightedActive : nil
        } else {
            hasGPUPH = false
            applyAcceleratorFallback(&s)
            gpuActive = s.gpuPercent
        }
        if let max = gpuTable?.max() { s.gpuMaxMHz = max }

        // 功率：能量計數是一段一段累加的，窗太短時一段能量除以極短秒數會冒出假尖峰（實測 GPU 0.7 W 變 11.7 W），不算
        guard seconds >= 0.2 else { return }
        let cpuActivity = weightedCPUActivity(cpu) ?? s.cpuPercent
        let cpuW = judge(.cpu, joules: energy.cpu, activity: cpuActivity, seconds: seconds)
        let gpuW = judge(.gpu, joules: energy.gpu, activity: gpuActive ?? cpuActivity, seconds: seconds)
        let dramW = judge(.dram, joules: energy.dram, activity: cpuActivity, seconds: seconds)
        // ANE 閒著時真的是 0，不能拿「忙碌卻是 0」判它；它跟 CPU 計數器同一道閘（mactop 實測），CPU 停更就一起當不可信。
        let aneW = cpuW != nil ? energy.ane.map { $0 / seconds } : nil

        guard cpuW != nil || gpuW != nil || aneW != nil || dramW != nil || s.power != nil else { return }
        var p = s.power ?? PowerReading()
        p.cpuW = cpuW
        p.gpuW = gpuW
        p.aneW = aneW
        p.dramW = dramW
        s.power = p
    }

    // MARK: - 駐留

    private var hasGPUPH = true

    private struct Residency {
        var total = 0.0
        var active = 0.0
        /// 有對到頻率的那部分活躍駐留（加權平均的分母，對不到表的狀態不拉低平均）
        var weightedActive = 0.0
        var weightedMHz = 0.0
    }

    /// 活躍＝OFF／IDLE／DOWN 以外的狀態（mactop、macmon 同一個判法）。
    /// CPU 狀態名是「V3P15」：V 後的數字就是 DVFS 表索引；GPU 是「P1…P15」：用活躍狀態的序號對表。
    private func accumulate(_ ch: CFDictionary, api: IOReportAPI, into r: inout Residency, table: [Double]?, indexFromV: Bool) {
        let count = api.stateCount(ch)
        guard count > 0 else { return }
        var ordinal = 0
        for i in 0..<count {
            let res = Double(max(0, api.stateResidency(ch, i)))
            r.total += res
            let state = api.state(ch, i) ?? ""
            if state == "OFF" || state == "IDLE" || state == "DOWN" { continue }
            r.active += res
            defer { ordinal += 1 }
            guard let table, !table.isEmpty, res > 0 else { continue }
            var idx = ordinal
            if indexFromV, let v = vIndex(state) { idx = v }
            // 狀態比表多（GPU 有 P1–P15、表只有 12 格）：多出來的是頂頻附近的加速態，夾到表尾，不丟掉。
            let mhz = table[min(idx, table.count - 1)]
            r.weightedActive += res
            r.weightedMHz += mhz * res
        }
    }

    private func vIndex(_ state: String) -> Int? {
        guard state.first == "V" else { return nil }
        let digits = state.dropFirst().prefix { $0.isNumber }
        return Int(digits)
    }

    private func weightedCPUActivity(_ cpu: [String: Residency]) -> Double? {
        var sum = 0.0, weight = 0.0
        for (tier, r) in cpu where r.total > 0 {
            let w = Double(max(1, tiers.first { $0.name == tier }?.cores ?? 1))
            sum += r.active / r.total * 100 * w
            weight += w
        }
        return weight > 0 ? sum / weight : nil
    }

    // MARK: - 叢集對應

    /// IOReport channel 名 → hw.perflevelN.name。
    /// ECPU＝Efficiency；MCPU（M5 Pro/Max 的中間層）＝Performance；SCPU＝Super；
    /// PCPU 一律是 perflevel0（最高層）：M1–M4 是 Performance，M5 是 Super——mactop 在 M5 上 p_cluster＝PCPU＝Super，本機實測吻合。
    /// 只收「前綴＋可有可無的數字」：ECPM、PCPM_IDLE 這些電源管理 channel 不算。
    private func tierName(forChannel channel: String) -> String? {
        let prefix = String(channel.prefix(4))
        guard ["ECPU", "PCPU", "MCPU", "SCPU"].contains(prefix),
              channel.dropFirst(4).allSatisfy({ $0.isNumber }) else { return nil }
        func named(_ n: String) -> String? { tiers.first { $0.name == n }?.name }
        switch prefix {
        case "ECPU": return named("Efficiency") ?? tiers.last?.name
        case "MCPU": return named("Performance") ?? (tiers.count >= 3 ? tiers[1].name : nil)
        case "SCPU": return named("Super") ?? tiers.first?.name
        default:     return tiers.first?.name
        }
    }

    /// 叢集的 DVFS 表。依序試：
    /// 1. 已知鍵號且長度＝這個 channel 的 V 狀態數（E：1，舊說法 9；perflevel0：5；M：22、23）；
    /// 2. 任何還沒被別的叢集或 GPU 用掉、長度相符的表（鍵號小的先）；
    /// 3. 已知鍵號但長度不符（索引會夾到表尾）。
    /// 長度相符是關鍵檢查：mactop 對 M5 的 E 叢集寫了 9 號表，這台的 9 號其實是 GPU（13 格，含 OFF 的 0），長度一比就不會選錯。
    private func table(forTier tier: String, channel ch: CFDictionary, api: IOReportAPI) -> [Double]? {
        if let t = tierTable[tier] { return t }
        let vStates = (0..<api.stateCount(ch)).filter { vIndex(api.state(ch, $0) ?? "") != nil }.count
        guard vStates > 0 else { return nil }
        let preferred: [Int]
        if tier == "Efficiency" || tier == tiers.last?.name && tiers.count > 1 { preferred = [1, 9] }
        else if tier == tiers.first?.name { preferred = [5] }
        else { preferred = [22, 23, 3] }

        let used = Set(tierTable.values).union(gpuTable.map { [$0] } ?? [])
        var pick: [Double]?
        pick = preferred.lazy.compactMap { self.dvfs[$0] }.first { $0.count == vStates }
        if pick == nil {
            pick = dvfs.keys.sorted().lazy.compactMap { self.dvfs[$0] }.first { $0.count == vStates && !used.contains($0) }
        }
        if pick == nil { pick = preferred.lazy.compactMap { self.dvfs[$0] }.first }
        if let pick { tierTable[tier] = pick }
        return pick
    }

    /// GPU 表：先找 9 號（mactop 對各代晶片都先找它；本機 13 格、第一格 0＝OFF、最高 1578 MHz）；沒有的話照 mactop，挑「第一格是 0」且頂頻最低的表。
    private func pickGPUTable() -> [Double]? {
        if let t = dvfs[9] { return t }
        return rawFirstZero.compactMap { dvfs[$0] }.min { ($0.max() ?? 0) < ($1.max() ?? 0) }
    }

    private var rawFirstZero: [Int] = []

    /// pmgr 節點的 voltage-statesN-sram：每格 8 bytes，前 4 bytes 小端序是頻率；≥1e8 是 Hz（M1–M4），否則是 kHz（M5）。
    private func readDVFSTables() -> [Int: [Double]] {
        var result: [Int: [Double]] = [:]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator) == KERN_SUCCESS else { return result }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var nameBuf = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(entry, &nameBuf) == KERN_SUCCESS, String(cString: nameBuf) == "pmgr" else { continue }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any] else { continue }
            for (key, value) in dict where key.hasPrefix("voltage-states") && key.hasSuffix("-sram") {
                guard let data = value as? Data,
                      let n = Int(key.dropFirst("voltage-states".count).dropLast("-sram".count)) else { continue }
                var raw: [UInt32] = []
                var off = 0
                while off + 8 <= data.count {
                    raw.append(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }.littleEndian)
                    off += 8
                }
                let mhz = raw.map { $0 >= 100_000_000 ? Double($0) / 1e6 : Double($0) / 1e3 }.filter { $0 > 0 }
                guard !mhz.isEmpty else { continue }
                if raw.first == 0 { rawFirstZero.append(n) }
                result[n] = mhz
            }
            break
        }
        return result
    }

    // MARK: - GPU 退路

    /// IOAccelerator 的 PerformanceStatistics「Device Utilization %」：公開的 registry 讀值，沒有頻率。
    private func applyAcceleratorFallback(_ s: inout MetricSnapshot) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let util = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { continue }
            s.gpuPercent = min(100, max(0, util))
            return
        }
    }

    // MARK: - 能量

    /// macOS 27 對沒有 entitlement 的行程停更 Energy Model（macmon README；本機實測 CPU／ANE／DRAM 恆為 0，只有 nJ 的 GPU Energy 會動）。
    /// 忙碌（>5%）時差值剛好 0 就不可信：當次留 nil；連續 3 次就鎖成停更，直到再看到非 0。
    private func judge(_ d: EnergyDomain, joules: Double?, activity: Double?, seconds: Double) -> Double? {
        guard let joules else { return nil }
        let busy = (activity ?? 0) > 5
        if joules > 0 {
            zeroStreak[d] = 0
            gated.remove(d)
            return joules / seconds
        }
        if busy {
            let n = (zeroStreak[d] ?? 0) + 1
            zeroStreak[d] = n
            if n >= 3 { gated.insert(d) }
            return nil
        }
        return gated.contains(d) ? nil : 0
    }

    private func forEachChannel(_ samples: CFDictionary, _ body: (CFDictionary) -> Void) {
        guard let raw = CFDictionaryGetValue(samples, Unmanaged.passUnretained("IOReportChannels" as CFString).toOpaque()) else { return }
        let array = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue()
        for i in 0..<CFArrayGetCount(array) {
            guard let item = CFArrayGetValueAtIndex(array, i) else { continue }
            body(Unmanaged<CFDictionary>.fromOpaque(item).takeUnretainedValue())
        }
    }
}

// MARK: - Energy Model 分類

private enum EnergyDomain: Hashable { case cpu, gpu, dram }

/// 照 mactop 的優先序挑 channel，避免同一份能量算兩次：
/// CPU 用「CPU Energy」總和，沒有才加叢集級（ECPU／PCPU／MCPU／SCPU，或帶 Energy 後綴的舊名）；
/// GPU 用「GPU Energy」，沒有才用「GPU」；ANE、DRAM 以分塊（ANE0_0、DRAM0…，或 M5 的單名「ANE」「DRAM」）為準，沒有才用「… Energy」總名。
private struct EnergyTotals {
    private var cpuTotal: Double?, cpuTyped: Double?
    private var gpuNamed: Double?, gpuAlias: Double?
    private var aneBlock: Double?, aneNamed: Double?
    private var dramBlock: Double?, dramNamed: Double?

    var cpu: Double? { cpuTotal ?? cpuTyped }
    var gpu: Double? { gpuNamed ?? gpuAlias }
    var ane: Double? { aneBlock ?? aneNamed }
    var dram: Double? { dramBlock ?? dramNamed }

    mutating func add(channel: String, unit: String?, value: Int64) {
        // 單位不認得就不猜，免得差三個數量級
        let scale: Double
        switch unit?.trimmingCharacters(in: .whitespaces) {
        case "mJ": scale = 1e-3
        case "uJ", "µJ": scale = 1e-6
        case "nJ": scale = 1e-9
        default: return
        }
        // IOReport 對無效計數會回 Int64.min；差值為負也是計數器重置，都不採用
        guard value >= 0 else { return }
        let j = Double(value) * scale
        func plus(_ x: inout Double?) { x = (x ?? 0) + j }

        let clusterPrefixes = ["ECPU", "PCPU", "MCPU", "SCPU"]
        if channel == "CPU Energy" || (channel.hasSuffix("CPU Energy") && !clusterPrefixes.contains { channel.hasPrefix($0) }) {
            plus(&cpuTotal)
        } else if clusterPrefixes.contains(channel) || ["ECPU Energy", "PCPU Energy", "MCPU Energy", "SCPU Energy",
                                                         "eCPUs Energy", "pCPUs Energy", "mCPUs Energy"].contains(channel) {
            plus(&cpuTyped)
        } else if channel == "GPU Energy" {
            plus(&gpuNamed)
        } else if channel == "GPU" {
            plus(&gpuAlias)
        } else if channel.hasPrefix("ANE") {
            if channel.contains("Energy") { plus(&aneNamed) } else { plus(&aneBlock) }
        } else if channel.hasPrefix("DRAM") {
            if channel.contains("Energy") { plus(&dramNamed) } else { plus(&dramBlock) }
        }
    }
}

// MARK: - 叢集（sysctl hw.perflevelN）

private struct PerfLevel {
    var name: String
    var cores: Int

    static func readAll() -> [PerfLevel] {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.nperflevels", &count, &size, nil, 0) == 0, count > 0 else { return [] }
        return (0..<Int(count)).compactMap { i in
            guard let name = sysctlString("hw.perflevel\(i).name") else { return nil }
            var cores: Int32 = 0
            var sz = MemoryLayout<Int32>.size
            if sysctlbyname("hw.perflevel\(i).logicalcpu", &cores, &sz, nil, 0) != 0 { cores = 0 }
            return PerfLevel(name: name, cores: Int(cores))
        }
    }

    private static func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}

// MARK: - libIOReport 綁定

/// IOReport 函式。命名照 CF 慣例：Copy／Create 回傳 +1（takeRetainedValue），Get 是借用（takeUnretainedValue）。
private struct IOReportAPI {
    typealias CopyChannels = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    typealias Merge = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Void
    typealias CreateSubscription = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> OpaquePointer?
    typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias CreateDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias GetString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    typealias StateCount = @convention(c) (CFDictionary) -> Int32
    typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    typealias GetInt64 = @convention(c) (CFDictionary, Int32) -> Int64

    let copyChannels: CopyChannels
    let merge: Merge
    let createSubscription: CreateSubscription
    let createSamples: CreateSamples
    let createDelta: CreateDelta
    let getGroup: GetString
    let getSubGroup: GetString
    let getChannelName: GetString
    let getUnitLabel: GetString
    private let stateGetCount: StateCount
    private let stateName: StateName
    private let stateGetResidency: GetInt64
    private let simpleGetInteger: GetInt64

    init?() {
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func sym<T>(_ n: String, _: T.Type) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: T.self) } }
        guard let a = sym("IOReportCopyChannelsInGroup", CopyChannels.self),
              let b = sym("IOReportMergeChannels", Merge.self),
              let c = sym("IOReportCreateSubscription", CreateSubscription.self),
              let d = sym("IOReportCreateSamples", CreateSamples.self),
              let e = sym("IOReportCreateSamplesDelta", CreateDelta.self),
              let f = sym("IOReportChannelGetGroup", GetString.self),
              let g = sym("IOReportChannelGetSubGroup", GetString.self),
              let i = sym("IOReportChannelGetChannelName", GetString.self),
              let j = sym("IOReportChannelGetUnitLabel", GetString.self),
              let k = sym("IOReportStateGetCount", StateCount.self),
              let l = sym("IOReportStateGetNameForIndex", StateName.self),
              let m = sym("IOReportStateGetResidency", GetInt64.self),
              let n = sym("IOReportSimpleGetIntegerValue", GetInt64.self) else { return nil }
        (copyChannels, merge, createSubscription, createSamples, createDelta) = (a, b, c, d, e)
        (getGroup, getSubGroup, getChannelName, getUnitLabel) = (f, g, i, j)
        (stateGetCount, stateName, stateGetResidency, simpleGetInteger) = (k, l, m, n)
    }

    func string(_ getter: GetString, _ ch: CFDictionary) -> String? {
        getter(ch)?.takeUnretainedValue() as String?
    }

    func state(_ ch: CFDictionary, _ i: Int32) -> String? {
        stateName(ch, i)?.takeUnretainedValue() as String?
    }

    /// 非狀態型 channel 呼叫 StateGetCount 會回負數，一律當 0
    func stateCount(_ ch: CFDictionary) -> Int32 { max(0, stateGetCount(ch)) }
    func stateResidency(_ ch: CFDictionary, _ i: Int32) -> Int64 { stateGetResidency(ch, i) }
    func simpleInteger(_ ch: CFDictionary, _ i: Int32) -> Int64 { simpleGetInteger(ch, i) }
}
