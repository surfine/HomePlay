// 錶面「儀表」（2.0 D2）：照 CarPlay 儀表的參數系統做的三種版式，讀值接 Metrics/ 資料層。
//   A 細線款（淺色）：中央一個細筆畫的負載圓錶＋兩條極簡線性錶（電量、SoC 溫度）＋底部 dynamic content 卡；
//   B 技術款（深色）：負載與功率兩個大圓錶（指針＋兩組刻度，功率錶內圈第二色細弧＝電量）、中間卡、底下轉速與溫度兩個小錶；
//   C 線性多錶（淺色）：一列一個線性錶，負載與電量最大，底部卡是警示說明＋最忙三個程序。
// 稿：Main／ClusterB／ClusterC.dc.html（1088 見方，錶面本體＝1024² 等比）；規格 R1–R11 見 docs/homeview-platform.md 第四節。
// 元件在 ClusterGauges.swift；警示門檻在 Metrics/MetricRules.swift，這裡不重寫一遍。

import AppKit

/// 儀表的版式：細線（A）、技術（B）、線性多錶（C）
enum ClusterLayout: String, CaseIterable {
    case a, b, c
    static let defaultsKey = "HomePlayClusterLayout"
    var title: String {
        switch self {
        case .a: return L("cluster.layout.a", "细线")
        case .b: return L("cluster.layout.b", "技术")
        case .c: return L("cluster.layout.c", "线性多表")
        }
    }
}

/// 快照用：命令列強行指定版式（不寫 UserDefaults）
nonisolated(unsafe) var clusterLayoutSnapshotOverride: ClusterLayout?
/// 快照用：--cluster-live，不用設計稿的示範值，改取兩次真讀值
nonisolated(unsafe) var clusterSnapshotLive = false

/// 警示狀態（D3，稿 States.dc.html）：快照用 --cluster-state 在示範值上注入
enum ClusterState: String, CaseIterable {
    case normal, memory, thermal, battery, disk, offline
}
nonisolated(unsafe) var clusterStateSnapshotOverride: ClusterState?

/// 取樣超過幾秒沒更新就當成離線
let clusterOfflineAfter: TimeInterval = 5

// MARK: - 取樣器的持有者

/// 儀表錶面用的取樣器：只在錶面是儀表時跑（離開就 stop，省電），最近一次讀值留著，下次一亮先用它畫（R11）。
final class ClusterMetrics {
    nonisolated(unsafe) static let shared = ClusterMetrics()

    private lazy var sampler: MetricsSampler = {
        let s = MetricsSampler()
        s.onUpdate = { [weak self] raw, sm in self?.ingest(raw, sm) }
        return s
    }()
    private(set) var raw: MetricSnapshot?
    private(set) var smoothed: MetricSnapshot?
    /// 每收到一筆就加一，錶面用它判斷要不要重畫
    private(set) var version = 0
    private(set) var running = false
    /// 最後一次收到讀值、與這一輪開始跑的時間：離線＝兩者較晚的那個起算超過 5 秒沒新讀值
    private(set) var lastIngest: Date?
    private var startedAt: Date?
    /// 熱壓力這個等級從什麼時候開始看到的（只知道「我們看到之後」）；高負載開始的時刻；負載走勢
    private var thermalSince: (level: ThermalPressure, at: Date)?
    private var busySince: Date?
    private(set) var history: [Double] = []

    func start() {
        guard !running else { return }
        running = true; startedAt = Date()
        sampler.start()
    }
    func stop() {
        guard running else { return }
        running = false
        sampler.stop()
    }

    /// 取樣器回呼（主執行緒）；快照的 --cluster-live 也走這裡
    func ingest(_ raw: MetricSnapshot, _ sm: MetricSnapshot) {
        self.raw = raw; smoothed = sm; version += 1; lastIngest = Date()
        if let t = raw.thermalPressure { if thermalSince?.level != t { thermalSince = (t, Date()) } } else { thermalSince = nil }
        if let c = sm.cpuPercent {
            history.append(c)
            if history.count > 24 { history.removeFirst(history.count - 24) }
            if c >= 60 { busySince = busySince ?? Date() } else { busySince = nil }
        }
    }

    /// 快照用：同步取兩次樣（第二次才有差值型的讀值），間隔 1 秒
    func sampleBlocking() {
        let s = MetricsSampler()
        _ = s.sampleOnce()
        Thread.sleep(forTimeInterval: 1)
        let r = s.sampleOnce()
        ingest(r, s.latestSmoothed ?? r)
    }

    /// 取樣中斷：跑著卻超過 5 秒沒新讀值（剛啟動的前 5 秒、沒在跑的快照不算）
    var offline: Bool {
        guard running, let ref = [lastIngest, startedAt].compactMap({ $0 }).max() else { return false }
        return Date().timeIntervalSince(ref) > clusterOfflineAfter
    }

    var context: ClusterContext {
        var c = ClusterContext(history: history)
        if let t = thermalSince, t.level >= .moderate { let m = Int(Date().timeIntervalSince(t.at) / 60); c.thermalMinutes = m >= 1 ? m : nil }
        if let b = busySince { let s = Int(Date().timeIntervalSince(b)); c.busySeconds = s >= 30 ? s : nil }
        return c
    }
}

/// 只靠一筆讀值算不出來的脈絡（持續多久、走勢）
struct ClusterContext {
    var thermalMinutes: Int?
    var busySeconds: Int?
    var history: [Double] = []
}

// MARK: - 讀值整理

/// 錶上看到的那一份：每個欄位都是 optional，讀不到就是「—」，不拿 0 假裝（R11）
struct ClusterReadout {
    var cpu: Double?
    /// 最快的叢集（S）與最慢的叢集（E）；只有一個叢集時 slow 是 nil
    var fast: CPUCluster?, slow: CPUCluster?
    var battery: BatteryReading?
    var socTemp: Double?
    var thermal: ThermalPressure?
    var systemW: Double?, batteryW: Double?
    var memory: MemoryReading?
    var volumes: [VolumeReading] = []
    var processes: [ProcessUsage] = []
    var telltales: [Telltale] = []
    var ctx = ClusterContext()
    /// 取樣中斷：所有讀值是 nil（顯示「—」，不寫 0）、沒有警示燈；lastUpdate 是最後一筆的時間
    var offline = false
    var lastUpdate: Date?
    /// 訪客模式（PersonalGate 關門）：程序名與卷宗名換成「需要主人」，百分比與數值照常
    var masked = false

    /// 程序名、卷宗名要給人看時走這裡
    func shown(_ name: String) -> String { masked ? L("guest.needsOwner", "需要主人") : name }

    /// 離線的讀值：整份空的
    static func offlineReadout(lastUpdate: Date?, masked: Bool = false) -> ClusterReadout {
        var r = ClusterReadout(raw: MetricSnapshot(), smoothed: MetricSnapshot(), ctx: ClusterContext())
        r.offline = true; r.lastUpdate = lastUpdate; r.masked = masked
        return r
    }

    /// raw 管警示燈與文字、smoothed 管指針與數字（R11：平滑在取樣端）
    init(raw: MetricSnapshot, smoothed sm: MetricSnapshot, ctx: ClusterContext) {
        cpu = sm.cpuPercent
        let cl = sm.clusters.filter { $0.mhz != nil || $0.maxMHz != nil }
        fast = cl.max { ($0.maxMHz ?? 0) < ($1.maxMHz ?? 0) }
        slow = cl.count > 1 ? cl.min { ($0.maxMHz ?? 0) < ($1.maxMHz ?? 0) } : nil
        battery = raw.battery
        socTemp = raw.socTempC
        thermal = raw.thermalPressure
        systemW = sm.power?.systemW; batteryW = raw.power?.batteryW
        memory = raw.memory
        volumes = raw.volumes
        processes = raw.topProcesses ?? []
        // 晶片溫度高幾乎都伴著熱壓力高：同一件事不亮兩顆燈（頂緣只有 3 個位置）
        var tt = MetricRules.telltales(raw)
        if tt.contains(where: { $0.kind == .thermal }) { tt.removeAll { $0.kind == .socTemp } }
        telltales = tt
        self.ctx = ctx
    }

    /// 功率錶的指針值：電池在充電就顯示充電瓦數（負值），否則是整機耗電
    var powerW: Double? {
        if let b = batteryW, b < -0.5 { return b }
        return systemW
    }

    /// 與負載配對的「油量」：有電池就是電量，桌機沒電池換成記憶體餘裕（R1）
    struct Reserve {
        var title: String
        var percent: Double?
        var severity: Severity?
        var note: String       // A、C 的一行狀態
        var shortNote: String  // B 的短字
        var isBattery: Bool
    }
    var reserve: Reserve {
        if let b = battery {
            let sev = MetricRules.status(battery: b)
            let note = sev == .critical ? L("cluster.bat.critical", "电量极低") : sev == .warn ? L("cluster.bat.low", "电量偏低")
                : b.charging ? L("cluster.bat.charging", "充电中") : b.onAC ? L("cluster.bat.acIdle", "接电 · 未充电") : L("cluster.bat.onBattery", "使用电池")
            let short = sev == .critical ? L("cluster.bat.criticalShort", "极低") : sev == .warn ? L("cluster.bat.lowShort", "电量低")
                : b.charging ? L("cluster.bat.charging", "充电中") : b.onAC ? L("cluster.bat.ac", "接电") : L("cluster.bat.batteryShort", "电池")
            return Reserve(title: L("cluster.battery", "电量"), percent: b.percent, severity: sev, note: note, shortNote: short, isBattery: true)
        }
        if let m = memory, m.totalBytes > 0 {
            let sev = MetricRules.status(memoryPressure: m.pressureLevel)
            let note = String(format: L("cluster.mem.usedOf", "已用 %@ / %@"), Self.gb(m.usedBytes), Self.gb(m.totalBytes))
            return Reserve(title: L("cluster.memFree", "内存余量"), percent: 100 - Double(m.usedBytes) / Double(m.totalBytes) * 100,
                           severity: sev, note: note, shortNote: L("cluster.mem.free", "可用"), isBattery: false)
        }
        return Reserve(title: L("cluster.battery", "电量"), percent: nil, severity: nil, note: "", shortNote: "", isBattery: true)
    }

    static func gb(_ v: UInt64) -> String { String(format: "%.1f GB", Double(v) / 1e9) }
    static func size(_ bytes: Double) -> String {
        bytes >= 1e12 ? String(format: "%.1f TB", bytes / 1e12) : String(format: "%.0f GB", bytes / 1e9)
    }

    // MARK: 警示燈的字

    func lamp(_ tt: Telltale, _ t: ClusterTheme) -> (icon: ClusterIcon, label: String, color: NSColor) {
        let crit = tt.severity == .critical
        let color = t.toneText(tt.severity) ?? t.accent
        switch tt.kind {
        case .thermal: return (.symbol("thermometer.medium"), crit ? L("cluster.lamp.thermalCrit", "热压力过高") : L("cluster.lamp.thermal", "热压力 高"), color)
        case .battery: return (.battery(level: battery?.percent ?? 0), String(format: L("cluster.lamp.battery", "电量 %d%%"), Int((battery?.percent ?? 0).rounded())), color)
        case .memory: return (.symbol("memorychip"), crit ? L("cluster.lamp.memCrit", "内存告急") : L("cluster.lamp.mem", "内存压力"), color)
        case .disk: return (.symbol("externaldrive"), crit ? L("cluster.lamp.diskCrit", "磁盘已满") : L("cluster.lamp.disk", "磁盘将满"), color)
        case .socTemp: return (.symbol("thermometer.high"), crit ? L("cluster.lamp.tempCrit", "芯片过热") : L("cluster.lamp.temp", "芯片偏热"), color)
        }
    }

    // MARK: dynamic content 卡（R7）：最嚴重的警示說明 → 最忙程序 → 簡短摘要

    struct Card {
        enum Tone { case warn(Severity), accent, muted }
        var tone: Tone
        var symbol: String
        var title: String
        var sub: String?
        /// 負載走勢（只有「最忙程序」卡畫）
        var spark: [Double] = []
    }

    struct Warning {
        var text: String
        var sub: String?
        var severity: Severity
        var symbol: String
    }

    /// 警示的說明（卡片的標題與第二行）。同級時熱壓力讓位給其他警示（熱壓力放進其他警示的第二行，頂緣的燈已經說了）
    var warningLine: Warning? {
        var tts = telltales
        if let f = tts.first, f.kind == .thermal, let i = tts.firstIndex(where: { $0.kind != .thermal && $0.severity == f.severity }) { tts.swapAt(0, i) }
        for tt in tts {
            switch tt.kind {
            case .disk:
                guard let v = volumes.first(where: { $0.name == tt.detail }) else { continue }
                let free = 100 - v.usedPercent
                // 訪客：卷宗名整個拿掉（不是換成「需要主人」夾在句子中間），也不列另一顆碟
                let pct = String(format: "%.1f%%", free)
                let text = masked
                    ? String(format: v.isInternal ? L("cluster.card.diskNoName", "磁盘只剩 %@") : L("cluster.card.diskExtNoName", "外接盘只剩 %@"), pct)
                    : String(format: v.isInternal ? L("cluster.card.disk", "磁盘 %@ 只剩 %@") : L("cluster.card.diskExt", "外接盘 %@ 只剩 %@"), v.name, pct)
                let size = String(format: L("cluster.card.diskAbout", "约 %@"), Self.size(Double(v.totalBytes) * free / 100))
                var parts = [size]
                if !masked, let o = volumes.filter({ $0.name != v.name }).max(by: { $0.usedPercent < $1.usedPercent }) { parts.append("\(shown(o.name)) \(Int(o.usedPercent.rounded()))%") }
                if let t = thermalLine { parts.append(t) }
                return Warning(text: text, sub: parts.joined(separator: " · "), severity: tt.severity, symbol: v.isInternal ? "internaldrive" : "externaldrive")
            case .battery:
                guard let b = battery else { continue }
                let text = String(format: L("cluster.card.batteryOnly", "电量只剩 %d%%"), Int(b.percent.rounded()))
                var parts = [b.onAC ? L("cluster.card.acNotCharging", "已接电源 · 未充电") : L("cluster.card.offAC", "未接电源")]
                if let w = systemW { parts.append(String(format: L("cluster.card.systemW", "整机 %@ W"), String(format: "%.1f", w))) }
                return Warning(text: text, sub: parts.joined(separator: " · "), severity: tt.severity, symbol: "battery.25percent")
            case .memory:
                guard let m = memory else { continue }
                let text = tt.severity == .critical ? L("cluster.card.memCrit", "内存压力：危急") : L("cluster.card.memWarn", "内存压力：警示")
                let sub = String(format: L("cluster.card.memUsed", "已用 %.1f／%.0f GB · 置换 %.1f GB"), Double(m.usedBytes) / 1e9, Double(m.totalBytes) / 1e9, Double(m.swapUsedBytes) / 1e9)
                return Warning(text: text, sub: sub, severity: tt.severity, symbol: "memorychip")
            case .thermal:
                guard let line = thermalLine else { continue }
                var parts: [String] = []
                if let c = socTemp { parts.append(String(format: L("cluster.card.socTemp", "SoC %@ °C"), String(format: "%.1f", c))) }
                if let f = fast, let m = f.mhz { parts.append("\(f.short) \(String(format: "%.1f", m / 1000)) GHz") }
                return Warning(text: line, sub: parts.isEmpty ? nil : parts.joined(separator: " · "), severity: tt.severity, symbol: "thermometer.medium")
            case .socTemp:
                guard let c = socTemp else { continue }
                return Warning(text: String(format: L("cluster.card.temp", "SoC 温度 %d °C，接近热节流点"), Int(c.rounded())), sub: nil, severity: tt.severity, symbol: "thermometer.high")
            }
        }
        return nil
    }

    /// 「熱壓力：高 · 已 6 分鐘」；Moderate 以上才有
    var thermalLine: String? {
        guard let t = thermal, t >= .moderate else { return nil }
        let level: String
        switch t {
        case .moderate: level = L("cluster.thermal.moderate", "中")
        case .heavy: level = L("cluster.thermal.heavy", "高")
        case .trapping: level = L("cluster.thermal.trapping", "降速中")
        default: level = L("cluster.thermal.sleeping", "极高")
        }
        if let m = ctx.thermalMinutes { return String(format: L("cluster.card.thermalSince", "热压力：%@ · 已 %d 分钟"), level, m) }
        return String(format: L("cluster.card.thermal", "热压力：%@"), level)
    }

    static func isBuild(_ name: String) -> Bool {
        ["swift-frontend", "swiftc", "swift-driver", "swift-build", "clang", "clang++", "cc1", "ld", "ibtool", "actool", "XCBBuildService"].contains(name)
    }

    var card: Card {
        if offline {
            let time = lastUpdate.map { Self.hhmm.string(from: $0) }
            return Card(tone: .muted, symbol: "wifi.slash", title: L("cluster.card.offline", "收不到取样数据"),
                        sub: time.map { String(format: L("cluster.card.lastUpdate", "最后更新 %@"), $0) } ?? L("cluster.card.noData", "还没有数据"))
        }
        if let w = warningLine {
            return Card(tone: .warn(w.severity), symbol: w.symbol, title: w.text,
                        sub: w.sub ?? thermalLine ?? processes.first.map { String(format: L("cluster.card.busyLine", "最忙进程 · %@ %.1f%%"), shown($0.name), $0.cpuPercent) })
        }
        if let p = processes.first {
            let build = Self.isBuild(p.name)
            if build {
                let sub = ctx.busySeconds.map { String(format: L("cluster.card.buildSince", "%@ 最忙 · 已 %d:%02d"), shown(p.name), $0 / 60, $0 % 60) }
                    ?? String(format: L("cluster.card.busyLine", "最忙进程 · %@ %.1f%%"), shown(p.name), p.cpuPercent)
                return Card(tone: .accent, symbol: "wrench", title: L("cluster.card.building", "Xcode 正在构建"), sub: sub, spark: ctx.history)
            }
            let others = processes.dropFirst().prefix(2).map { String(format: "%@ %.1f%%", shown($0.name), $0.cpuPercent) }
            return Card(tone: .accent, symbol: "cpu", title: String(format: L("cluster.card.busyTitle", "最忙 · %@ %.1f%%"), shown(p.name), p.cpuPercent),
                        sub: others.isEmpty ? nil : others.joined(separator: " · "), spark: ctx.history)
        }
        let s = String(format: L("cluster.card.okLine", "负载 %@%% · 内存压力正常"), MetricFormat.percent(cpu))
        return Card(tone: .accent, symbol: "checkmark.circle", title: L("cluster.card.ok", "一切正常"), sub: thermalLine ?? s)
    }

    static let hhmm: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
}

// MARK: - 設計稿的示範值（--snapshot／--screen-png 自動用；--cluster-live 改用真讀值）

enum ClusterDemo {
    /// 設計稿 States 板的狀態：先換成「一切在門檻內」的底，再把該狀態的數字注入（數字照稿）
    static func readout(_ layout: ClusterLayout, state: ClusterState) -> ClusterReadout {
        var s = MetricSnapshot()
        var ctx = ClusterContext()
        let ext = VolumeReading(name: "MU-PE2T0K", totalBytes: 2_000_000_000_000, usedPercent: 80, isInternal: false)
        let hd = VolumeReading(name: "Mac HD", totalBytes: 500_000_000_000, usedPercent: 85, isInternal: true)
        s.cpuPercent = layout == .b ? 92 : 19
        s.clusters = layout == .b
            ? [CPUCluster(name: "Efficiency", short: "E", cores: 6, usagePercent: nil, activePercent: nil, mhz: 2900, maxMHz: 3050),
               CPUCluster(name: "Super", short: "S", cores: 4, usagePercent: nil, activePercent: nil, mhz: 4330, maxMHz: 4460)]
            : [CPUCluster(name: "Efficiency", short: "E", cores: 6, usagePercent: nil, activePercent: nil, mhz: 1890, maxMHz: 3050),
               CPUCluster(name: "Super", short: "S", cores: 4, usagePercent: nil, activePercent: nil, mhz: 2720, maxMHz: 4460)]
        s.battery = BatteryReading(percent: 100, charging: false, onAC: true)
        s.socTempC = 61.9; s.thermalPressure = .nominal
        s.power = PowerReading(systemW: 16.9, batteryW: 0)
        s.memory = MemoryReading(totalBytes: 24_000_000_000, usedBytes: 18_500_000_000, wiredBytes: 3_000_000_000, compressedBytes: 5_500_000_000,
                                 swapUsedBytes: 4_700_000_000, swapTotalBytes: 5_000_000_000, pressureLevel: 1)
        s.volumes = [hd, ext]
        s.topProcesses = [ProcessUsage(name: "Claude Helper (Renderer)", pid: 1, cpuPercent: 17.6),
                          ProcessUsage(name: "claude", pid: 2, cpuPercent: 16.0),
                          ProcessUsage(name: "ZCode Helper", pid: 3, cpuPercent: 14.5)]
        ctx.history = [12, 20, 16, 24, 19, 22, 18, 17, 21, 19]
        switch state {
        case .normal: break
        case .memory: s.memory?.pressureLevel = 2
        case .thermal: s.thermalPressure = .heavy; ctx.thermalMinutes = 6
        case .battery: s.battery = BatteryReading(percent: 8, charging: false, onAC: false)
        case .disk: s.volumes = [hd, VolumeReading(name: "MU-PE2T0K", totalBytes: 2_000_000_000_000, usedPercent: 95.4, isInternal: false)]
        case .offline:   // 03:24 之後就沒有讀值了
            var c = Calendar.current.dateComponents([.year, .month, .day], from: Date()); c.hour = 3; c.minute = 24
            return ClusterReadout.offlineReadout(lastUpdate: Calendar.current.date(from: c))
        }
        return ClusterReadout(raw: s, smoothed: s, ctx: ctx)
    }

    static func readout(_ layout: ClusterLayout) -> ClusterReadout {
        if let st = clusterStateSnapshotOverride { return readout(layout, state: st) }
        var s = MetricSnapshot()
        var ctx = ClusterContext()
        let ext = VolumeReading(name: "MU-PE2T0K", totalBytes: 2_000_000_000_000, usedPercent: 95.4, isInternal: false)
        let hd = VolumeReading(name: "Mac HD", totalBytes: 500_000_000_000, usedPercent: 85, isInternal: true)
        let mem = MemoryReading(totalBytes: 24_000_000_000, usedBytes: 18_500_000_000, wiredBytes: 3_000_000_000, compressedBytes: 5_500_000_000,
                                swapUsedBytes: 4_700_000_000, swapTotalBytes: 5_000_000_000, pressureLevel: 1)
        func clusters(s mhz: Double, sMax: Double, e: Double, eMax: Double) -> [CPUCluster] {
            [CPUCluster(name: "Efficiency", short: "E", cores: 6, usagePercent: nil, activePercent: nil, mhz: e, maxMHz: eMax),
             CPUCluster(name: "Super", short: "S", cores: 4, usagePercent: nil, activePercent: nil, mhz: mhz, maxMHz: sMax)]
        }
        switch layout {
        case .a, .c:   // 03:24 實測
            s.cpuPercent = 19
            s.clusters = clusters(s: 2720, sMax: 4460, e: 1890, eMax: 3050)
            s.battery = BatteryReading(percent: 100, charging: false, onAC: true)
            s.socTempC = 61.9; s.thermalPressure = .heavy
            s.power = PowerReading(systemW: 16.9, batteryW: 0)
            s.memory = mem; s.volumes = [hd, ext]
            ctx.thermalMinutes = 6
            if layout == .c {
                s.topProcesses = [ProcessUsage(name: "Claude Helper (Renderer)", pid: 1, cpuPercent: 17.6),
                                  ProcessUsage(name: "claude", pid: 2, cpuPercent: 16.0),
                                  ProcessUsage(name: "ZCode Helper", pid: 3, cpuPercent: 14.5)]
            }
        case .b:       // 編譯中
            s.cpuPercent = 92
            s.clusters = clusters(s: 4330, sMax: 4460, e: 2900, eMax: 3050)
            s.battery = BatteryReading(percent: 100, charging: false, onAC: true)
            s.socTempC = 96; s.thermalPressure = .heavy
            s.power = PowerReading(systemW: 31, batteryW: 0)
            s.memory = mem; s.volumes = [hd]
            s.topProcesses = [ProcessUsage(name: "swift-frontend", pid: 1, cpuPercent: 312)]
            ctx.thermalMinutes = 6; ctx.busySeconds = 134
            ctx.history = [12, 20, 16, 54, 90, 82, 100, 94, 100, 96, 100, 96, 100]
        }
        return ClusterReadout(raw: s, smoothed: s, ctx: ctx)
    }
}

// MARK: - 錶面

nonisolated(unsafe) private var clusterRendered = (version: -1, minute: -1, offline: false, masked: false)

extension Face {
    func renderClusterFace(_ g: CGContext, _ now: Double) {
        let layout = clusterLayout
        let ro = clusterReadout(layout)
        let theme: ClusterTheme = nightOwnPalette ? .night : layout == .b ? .dark : .light
        g.setFillColor(theme.bg.cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))

        let k: CGFloat = 1024 / 1088   // 設計稿 1088 → 畫布 1024
        g.saveGState(); g.scaleBy(x: k, y: k)
        let p = ClusterPainter(g: g, t: theme)
        switch layout {
        case .a: drawClusterA(p, ro)
        case .b: drawClusterB(p, ro)
        case .c: drawClusterC(p, ro, clock: Self.clock(Self.displayDate))
        }
        g.restoreGState()

        // 膠囊住頂端中央（👀 照其他錶面的畫法，只換膠囊）；設計稿 176×68、中心 (544, 66)
        let cw: CGFloat = 176 * k, at = CGPoint(x: 512, y: 66 * k)
        if theme.dark {   // 深色底上的黑膠囊要一圈細邊才分得出來
            let r = CGRect(x: at.x - cw / 2 - 1, y: at.y - 68 * k / 2 - 1, width: cw + 2, height: 68 * k + 2)
            g.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil))
            g.setFillColor(theme.track.cgColor); g.fillPath()
        }
        drawIsland(g, at: at, scale: cw / 588, liveAt: at, now: now)
    }

    /// 這一刻要畫的讀值：示範值、快照的真讀值、或取樣器最近一筆（還沒有就全是「—」）
    private func clusterReadout(_ layout: ClusterLayout) -> ClusterReadout {
        let m = ClusterMetrics.shared
        let masked = !PersonalGate.allowed   // 訪客：程序名、卷宗名換成「需要主人」
        if Face.demoData && !clusterSnapshotLive { var r = ClusterDemo.readout(layout); r.masked = masked; return r }
        if clusterSnapshotLive && m.raw == nil { m.sampleBlocking() }
        // 取樣中斷：超過 5 秒沒新讀值，整面「—」（不拿舊值假裝還活著）
        if m.offline { return .offlineReadout(lastUpdate: m.lastIngest, masked: masked) }
        guard let raw = m.raw else { var r = ClusterReadout(raw: MetricSnapshot(), smoothed: MetricSnapshot(), ctx: m.context); r.masked = masked; return r }
        var r = ClusterReadout(raw: raw, smoothed: m.smoothed ?? raw, ctx: m.context)
        r.masked = masked
        return r
    }

    /// 取樣器只在這個錶面上才跑；有新讀值或換分鐘（C 的時間）才重畫
    func tickClusterFace(_ now: Double) -> Bool {
        let m = ClusterMetrics.shared
        if !Face.demoData { m.start() }
        let minute = Int(Self.displayDate.timeIntervalSince1970 / 60)
        let offline = m.offline, masked = !PersonalGate.allowed
        defer { clusterRendered = (m.version, minute, offline, masked) }
        return m.version != clusterRendered.version || (clusterLayout == .c && minute != clusterRendered.minute)
            || offline != clusterRendered.offline || masked != clusterRendered.masked
    }

    // MARK: 共用小件

    private func clusterLamps(_ p: ClusterPainter, _ ro: ClusterReadout, y: CGFloat, size: CGFloat, padRight: CGFloat) {
        var x: CGFloat = 56
        var right = false
        for tt in ro.telltales {
            let l = ro.lamp(tt, p.t)
            let bold = p.t.night && tt.severity == .critical   // 夜間只剩一個紅：危急靠加粗
            let w = p.lampWidth(label: l.label, fontSize: size, padRight: padRight, bold: bold)
            if !right, x + w > 440 { right = true; x = 656 }   // 左邊放不下的移到膠囊右邊（頂端中央留給膠囊）
            p.lamp(x: x, y: y, icon: l.icon, label: l.label, color: l.color, fontSize: size, padRight: padRight, bold: bold)
            x += w + 12
        }
    }

    private func pct(_ v: Double?) -> String { MetricFormat.percent(v) }

    /// 「S 2.7 GHz · E 1.9 GHz」；讀不到的那段是「—」
    private func clusterFreqLine(_ ro: ClusterReadout, digitsFast: Int = 1, digitsSlow: Int = 1) -> String {
        func g(_ c: CPUCluster?, _ d: Int) -> String { c?.mhz.map { String(format: "%.\(d)f", $0 / 1000) } ?? "—" }
        let s = "\(ro.fast?.short ?? "S") \(g(ro.fast, digitsFast)) GHz"
        guard let slow = ro.slow else { return ro.offline ? s + " · E — GHz" : s }
        return s + " · \(slow.short) \(g(slow, digitsSlow)) GHz"
    }

    // MARK: A 細線款

    /// A：一個主數值（負載，細進度弧＋大數字），底下最多三個大字指標（電量或記憶體餘量、溫度、功率）。
    /// 晶片名、頻率、刻度數字、熱節流線、外接碟名都不上錶面；警示只有一個位置（環的缺口）、一種顏色，只說最嚴重的那一件。
    private func drawClusterA(_ p: ClusterPainter, _ ro: ClusterReadout) {
        let t = p.t
        let ic = HPAccessibility.increaseContrast
        let second = ic && !t.night ? t.label.withAlphaComponent(0.8) : t.secondary

        // 主數值：負載
        var r = ClusterRound(center: CGPoint(x: 544, y: 452), radius: 300, lo: 0, hi: 100, stroke: 12, roundCap: true, track: t.track)
        r.dashed = ro.cpu == nil
        if let c = ro.cpu, c > 0 { r.fill = (0, c, t.accent) }
        p.round(r)
        let lab = p.font(36, 500, mono: false)
        p.text(L("cluster.cpu", "负载"), lab, x: 544, base: 300, color: second, align: .center)
        let big = p.font(250, 400), unit = p.font(84, 400)
        let num = pct(ro.cpu)
        let nk: CGFloat = -250 * 0.02
        let wn = p.width(num, big, kern: nk), wu = ro.cpu == nil ? 0 : p.width("%", unit)
        let bx = 544 - (wn + (wu > 0 ? 6 + wu : 0)) / 2, bb: CGFloat = 548
        p.text(num, big, x: bx, base: bb, color: t.label, kern: nk)
        if wu > 0 { p.text("%", unit, x: bx + wn + 6, base: bb, color: second) }

        // 警示：環的缺口裡一顆膠囊，一種顏色（深淺底各用可讀的橘），只說最嚴重的一件
        let worst = ro.telltales.max { ($0.severity == .critical ? 1 : 0) < ($1.severity == .critical ? 1 : 0) }
        if ro.offline || worst != nil {
            let text: String, icon: String, col: NSColor
            if ro.offline { text = L("cluster.noReading", "暂时读不到"); icon = "wifi.slash"; col = second }
            else {
                let l = ro.lamp(worst!, t)
                text = l.label; col = t.night ? t.label : t.warnText
                if case .symbol(let n) = l.icon { icon = n } else { icon = "battery.25percent" }
            }
            let f = p.font(34, 600, mono: false)
            let tw = p.width(text, f), h: CGFloat = 72, w = tw + 44 + 16 + 56
            let pill = CGRect(x: 544 - w / 2, y: 650, width: w, height: h)
            p.fillRounded(pill, radius: h / 2, col.withAlphaComponent(t.dark ? 0.2 : 0.12))
            p.symbol(icon, in: CGRect(x: pill.minX + 28, y: pill.midY - 22, width: 44, height: 44), color: col)
            p.text(text, f, x: pill.minX + 28 + 44 + 16, base: p.base(mid: pill.midY, f), color: col)
        }

        // 三個大字指標
        let res = ro.reserve
        let cols: [(String, String, String)] = [
            (res.title, pct(res.percent), res.percent == nil ? "" : "%"),
            (L("cluster.tempShort", "温度"), ro.socTemp.map { String(format: "%.0f", $0) } ?? "—", ro.socTemp == nil ? "" : "°C"),
            (L("cluster.power", "功率"), ro.powerW.map { String(format: "%.0f", abs($0)) } ?? "—", ro.powerW == nil ? "" : "W"),
        ]
        let vf = p.font(84, 500), uf = p.font(38, 500), lf = p.font(36, 500, mono: false)
        for (i, c) in cols.enumerated() {
            let cx = 544 + CGFloat(i - 1) * 340
            let wv = p.width(c.1, vf), wu = c.2.isEmpty ? 0 : p.width(c.2, uf) + 4
            let x0 = cx - (wv + wu) / 2
            p.text(c.1, vf, x: x0, base: 900, color: t.label)
            if !c.2.isEmpty { p.text(c.2, uf, x: x0 + wv + 4, base: 900, color: second) }
            p.text(Face.clipped(c.0, lf, 300), lf, x: cx, base: 960, color: second, align: .center)
        }
    }

    private func cardColor(_ c: ClusterReadout.Card, _ t: ClusterTheme) -> NSColor {
        switch c.tone {
        case .warn(let s): return t.tone(s)
        case .muted: return t.secondary
        case .accent: return t.accent
        }
    }
    private func cardSolid(_ c: ClusterReadout.Card) -> Bool {
        if case .accent = c.tone { return true }
        return false
    }
    /// 夜間紅只有一個紅：危急的卡標題靠加粗（圖示本來就不同）
    private func cardBold(_ c: ClusterReadout.Card, _ t: ClusterTheme) -> Bool {
        if t.night, case .warn(.critical) = c.tone { return true }
        return false
    }

    // MARK: B 技術款

    private func drawClusterB(_ p: ClusterPainter, _ ro: ClusterReadout) {
        let t = p.t
        clusterLamps(p, ro, y: 40, size: 22, padRight: 20)
        let nf: (CGFloat, CGFloat) -> NSFont = { p.font($0, $1, narrow: true) }

        // 左：負載（指針＋兩組刻度＋數字 0–100）
        var sp = ClusterRound(center: CGPoint(x: 300, y: 388), radius: 208, lo: 0, hi: 100, stroke: 6, roundCap: false, track: t.track)
        sp.dashed = ro.cpu == nil
        if let c = ro.cpu { sp.fill = (0, c, t.accent); sp.needle = (c, 174, 204, 6, t.accent) }
        sp.minor = ClusterTicks(values: stride(from: 2.0, through: 98, by: 2).filter { Int($0) % 10 != 0 }, r1: 190, r2: 200, width: 1.5, color: t.minorTick)
        sp.major = ClusterTicks(values: stride(from: 0.0, through: 100, by: 10).map { $0 }, r1: 178, r2: 200, width: 3, color: t.majorTick)
        sp.numbers = (stride(from: 0.0, through: 100, by: 20).map { $0 }, ["0", "20", "40", "60", "80", "100"], 158, nf(22, 510), t.secondary)
        p.round(sp)
        let lab = p.font(22, 510, mono: false)
        p.text(L("cluster.cpu", "负载"), lab, x: 300, base: p.base(top: 272, lineHeight: 26, lab), color: t.secondary, align: .center)
        let big = nf(128, 510), unit = nf(44, 510)
        let num = pct(ro.cpu), wn = p.width(num, big), wu = ro.cpu == nil ? 0 : p.width("%", unit)
        let bx = 300 - (wn + (wu > 0 ? 4 + wu : 0)) / 2, bb = p.base(top: 304, lineHeight: 128, big)
        p.text(num, big, x: bx, base: bb, color: t.label)
        if wu > 0 { p.text("%", unit, x: bx + wn + 4, base: bb, color: t.secondary) }
        let alt = nf(20, 510)
        p.text(clusterFreqLine(ro, digitsFast: 2, digitsSlow: 1).replacingOccurrences(of: " GHz · ", with: " · "), alt, x: 300, base: p.base(top: 446, lineHeight: 24, alt), color: t.secondary, align: .center)

        // 右：功率（−20…0…+40 W 雙向，0 W 一條零點線）；內圈第二色細弧＝電量（R1 配對）
        let pw = ro.powerW
        let pwColor = (pw ?? 0) < 0 ? t.soc : t.accent
        var pr = ClusterRound(center: CGPoint(x: 788, y: 388), radius: 208, lo: -20, hi: 40, stroke: 6, roundCap: false, track: t.track)
        pr.dashed = pw == nil
        pr.bands = [(-20, 0, t.soc.withAlphaComponent(0.45))]
        if let w = pw { pr.fill = (0, w, pwColor); pr.needle = (w, 174, 204, 6, pwColor) }
        pr.minor = ClusterTicks(values: stride(from: -18.0, through: 38, by: 2).filter { Int($0) % 10 != 0 }, r1: 190, r2: 200, width: 1.5, color: t.minorTick)
        pr.major = ClusterTicks(values: [-20, -10, 10, 20, 30, 40], r1: 178, r2: 200, width: 3, color: t.majorTick)
        pr.limits = [(0, 176, 218, 4, t.majorTick)]
        pr.numbers = ([-20, 0, 20, 40], ["\u{2212}20", "0", "20", "40"], 158, nf(22, 510), t.secondary)
        let res = ro.reserve
        let resColor = res.percent == nil ? t.secondary : t.tone(res.severity, normal: t.soc)   // 離線：電池圖示不留綠色
        p.round(pr, beforeNeedle: {
            let c = CGPoint(x: 788, y: 388)
            p.arc(center: c, r: 126, from: 135, to: 405, width: 5, color: t.track, round: true, dash: res.percent == nil ? [3, 10] : nil)
            if let v = res.percent, v > 0 { p.arc(center: c, r: 126, from: 135, to: 135 + 270 * CGFloat(min(v, 100) / 100), width: 5, color: resColor, round: true) }
        })
        let pl = p.font(22, 510, mono: false)
        p.text(L("cluster.power", "功率"), pl, x: 788, base: p.base(top: 302, lineHeight: 26, pl), color: t.secondary, align: .center)
        let pbig = nf(96, 510), punit = nf(36, 510)
        let pnum = pw.map { MetricFormat.watts($0).replacingOccurrences(of: "-", with: "\u{2212}") } ?? "—"
        let pwn = p.width(pnum, pbig), pwu = pw == nil ? 0 : p.width("W", punit)
        let pbx = 788 - (pwn + (pwu > 0 ? 4 + pwu : 0)) / 2, pbb = p.base(top: 334, lineHeight: 96, pbig)
        p.text(pnum, pbig, x: pbx, base: pbb, color: t.label)
        if pwu > 0 { p.text("W", punit, x: pbx + pwn + 4, base: pbb, color: t.secondary) }
        if let w = pw {
            let word = nf(20, 510)
            p.text(w < 0 ? L("cluster.powerCharge", "充电") : L("cluster.powerDraw", "耗电"), word, x: 788, base: p.base(top: 438, lineHeight: 24, word), color: t.secondary, align: .center)
        }
        // 電量一行：電池圖示＋百分比＋狀態字
        let bf = nf(22, 590), nf2 = p.font(20, 400, mono: false)
        let pctText = res.percent.map { MetricFormat.percent($0) + "%" } ?? "—"
        let w1 = p.width(pctText, bf), w2 = res.shortNote.isEmpty ? 0 : p.width(res.shortNote, nf2)
        let total = (res.isBattery ? 28 + 6 : 0) + w1 + (w2 > 0 ? 6 + w2 : 0)
        var rx = 788 - total / 2
        if res.isBattery { p.battery(x: rx, y: 487 + 13 - 8, level: res.percent ?? 0, color: resColor); rx += 34 }
        p.text(pctText, bf, x: rx, base: p.base(mid: 500, bf), color: res.percent == nil ? t.secondary : resColor)
        if w2 > 0 { p.text(res.shortNote, nf2, x: rx + w1 + 6, base: p.base(mid: 500, nf2), color: t.secondary) }

        drawClusterCardB(p, ro)

        // 底列兩個小錶：S 叢集轉速（最後一段紅區）、SoC 溫度（100 °C 紅線）
        let hiG = ((ro.fast?.maxMHz ?? 4460) / 1000)
        let redFrom = hiG.rounded(.down)
        var sr = ClusterRound(center: CGPoint(x: 300, y: 868), radius: 104, lo: 0, hi: hiG, stroke: 4, roundCap: false, track: t.track)
        sr.dashed = ro.fast?.mhz == nil
        sr.bands = [(redFrom, hiG, t.critical)]
        let ticksG = stride(from: 0.25, to: hiG, by: 0.25).filter { abs($0.truncatingRemainder(dividingBy: 1)) > 0.001 }
        sr.minor = ClusterTicks(values: ticksG, r1: 94, r2: 100, width: 1.5, color: t.minorTick)
        let ints = stride(from: 0.0, through: redFrom, by: 1).map { $0 }
        sr.major = ClusterTicks(values: ints, r1: 88, r2: 100, width: 2.5, color: t.majorTick)
        sr.numbers = (ints, ints.map { String(Int($0)) }, 74, nf(20, 510), t.secondary)
        if let m = ro.fast?.mhz { sr.needle = (m / 1000, 80, 102, 4, t.accent) }
        p.round(sr)
        let tc = ro.socTemp.map { t.tone(MetricRules.status(tempC: $0)) } ?? t.accent
        var tr = ClusterRound(center: CGPoint(x: 788, y: 868), radius: 104, lo: 30, hi: 110, stroke: 4, roundCap: false, track: t.track)
        tr.dashed = ro.socTemp == nil
        tr.bands = [(100, 110, t.critical)]
        tr.minor = ClusterTicks(values: stride(from: 35.0, through: 105, by: 5).filter { Int($0 - 30) % 20 != 0 }, r1: 94, r2: 100, width: 1.5, color: t.minorTick)
        tr.major = ClusterTicks(values: stride(from: 30.0, through: 110, by: 20).map { $0 }, r1: 88, r2: 100, width: 2.5, color: t.majorTick)
        tr.limits = [(100, 84, 112, 4, t.critical)]
        tr.numbers = ([30, 70, 110], ["30", "70", "110"], 74, nf(20, 510), t.secondary)
        if let c = ro.socTemp { tr.needle = (c, 80, 102, 4, tc) }
        p.round(tr)

        let vf = nf(40, 510), uf = p.font(20, 400, mono: false)
        let sv = ro.fast?.mhz.map { String(format: "%.2f", $0 / 1000) } ?? "—"
        p.text(sv, vf, x: 300, base: p.base(top: 838, lineHeight: 40, vf), color: t.label, align: .center)
        p.text("GHz", uf, x: 300, base: p.base(top: 882, lineHeight: 24, uf), color: t.secondary, align: .center)
        let tv = MetricFormat.celsius(ro.socTemp)
        p.text(tv, vf, x: 788, base: p.base(top: 838, lineHeight: 40, vf), color: (ro.socTemp ?? 0) >= 90 ? tc : t.label, align: .center)
        p.text("°C", uf, x: 788, base: p.base(top: 882, lineHeight: 24, uf), color: t.secondary, align: .center)
        let nl = p.font(22, 510, mono: false)
        p.text(String(format: L("cluster.freqTitle", "%@ 集群频率"), ro.fast?.short ?? "S"), nl, x: 300, base: p.base(top: 952, lineHeight: 28, nl), color: t.label, align: .center)
        p.text(L("cluster.temp", "SoC 温度"), nl, x: 788, base: p.base(top: 952, lineHeight: 28, nl), color: t.label, align: .center)
        let sub = nf(20, 510)
        p.text(ro.fast?.maxMHz.map { String(format: L("cluster.limitGHz", "上限 %@ GHz"), String(format: "%.2f", $0 / 1000)) } ?? "—", sub, x: 300,
               base: p.base(top: 982, lineHeight: 24, sub), color: t.secondary, align: .center)
        // 溫度的狀態字：圖示＋偏高／過熱／正常＋「· 100 °C 節流」
        let sev = MetricRules.status(tempC: ro.socTemp)
        let word = ro.socTemp == nil ? "" : sev == .critical ? L("cluster.temp.hot", "过热") : sev == .warn ? L("cluster.temp.high", "偏高") : L("cluster.temp.ok", "正常")
        let wf = p.font(20, 590, mono: false), rf = p.font(20, 400, mono: false)
        let rest = word.isEmpty ? String(format: L("cluster.throttleOnly", "%d °C 节流"), 100)   // 離線沒有狀態字：不留開頭的「·」
                                : String(format: L("cluster.throttleShort", "· %d °C 节流"), 100)
        let ww = word.isEmpty ? 0 : p.width(word, wf), wr = p.width(rest, rf)
        let tot = (word.isEmpty ? 0 : 20 + 4 + ww + 4) + wr
        var tx = 788 - tot / 2
        let by = p.base(mid: 994, rf)
        if !word.isEmpty {
            p.symbol("thermometer.medium", in: CGRect(x: tx, y: 984, width: 20, height: 20), color: tc)
            tx += 24
            p.text(word, wf, x: tx, base: by, color: tc); tx += ww + 4
        }
        p.text(rest, rf, x: tx, base: by, color: t.secondary)
    }

    private func drawClusterCardB(_ p: ClusterPainter, _ ro: ClusterReadout) {
        let t = p.t, c = ro.card
        let r = CGRect(x: 224, y: 584, width: 640, height: 128)
        p.cardBackground(r, radius: 32)
        p.iconTile(CGRect(x: 248, y: 608, width: 80, height: 80), radius: 18, symbol: c.symbol, color: cardColor(c, t), solid: cardSolid(c), glyph: 44)
        let tx: CGFloat = 348
        let sparkW: CGFloat = c.spark.count >= 2 ? 120 : 0
        let avail = r.maxX - 28 - tx - (sparkW > 0 ? sparkW + 20 : 0)
        var tf = p.font(30, cardBold(c, t) ? 720 : 590, mono: false)
        let sf = p.font(22, 400, mono: false)
        var lines = [c.title]
        if p.width(c.title, tf) > avail {   // 警示說明比較長：先縮到一行放得下（「約 92 GB」不拆開），還放不下才小一號、最多兩行
            if let fit = [26, 24, 22].lazy.map({ p.font(CGFloat($0), 590, mono: false) }).first(where: { p.width(c.title, $0) <= avail }) {
                tf = fit
            } else {
                tf = p.font(26, 590, mono: false)
                lines = Face.wrap(c.title, tf, avail, maxLines: 2)
            }
        }
        let sub = lines.count > 1 ? nil : c.sub
        let lh: CGFloat = lines.count > 1 ? 32 : 36
        let h = lh * CGFloat(lines.count) + (sub == nil ? 0 : 6 + 28)
        var y = r.midY - h / 2
        for l in lines { p.text(l, tf, x: tx, base: p.base(top: y, lineHeight: lh, tf), color: t.label); y += lh }
        if let s = sub { p.text(Face.clipped(s, sf, avail), sf, x: tx, base: p.base(top: y + 6, lineHeight: 28, sf), color: t.secondary) }
        if sparkW > 0 { p.sparkline(c.spark, in: CGRect(x: r.maxX - 28 - sparkW, y: r.midY - 28, width: sparkW, height: 56), color: t.accent, lineWidth: 4) }
    }

    // MARK: C 線性多錶

    private func drawClusterC(_ p: ClusterPainter, _ ro: ClusterReadout, clock: String) {
        let t = p.t
        clusterLamps(p, ro, y: 40, size: 24, padRight: 18)
        let tf = p.font(24, 510)
        p.text(clock, tf, x: 1032, base: p.base(mid: 66, tf), color: t.secondary, align: .right)

        let lab = p.font(26, 510, mono: false)
        // 負載：大讀值＋長條＋替代單位
        p.text(L("cluster.cpu", "负载"), lab, x: 56, base: p.base(top: 120, lineHeight: 32, lab), color: t.secondary)
        let big = p.font(144, 300), unit = p.font(56, 300)
        let bb = p.base(top: 156, lineHeight: 144, big)
        let num = pct(ro.cpu)
        let wn = p.text(num, big, x: 56, base: bb, color: t.label, kern: -144 * 0.02)
        if ro.cpu != nil { p.text("%", unit, x: 56 + wn + 6, base: bb, color: t.secondary) }
        let alt = p.font(26, 510)
        p.text(clusterFreqLine(ro), alt, x: 1032, base: bb, color: t.secondary, align: .right)
        var lb = ClusterBar(rect: CGRect(x: 56, y: 316, width: 976, height: 20), track: t.track)
        lb.dashed = ro.offline
        if let c = ro.cpu { lb.fills = [(0, CGFloat(min(max(c, 0), 100) / 100), t.accent, true, true)] }
        p.bar(lb)

        // 電量：同樣大
        let res = ro.reserve
        let resColor = res.percent == nil ? t.secondary : t.tone(res.severity, normal: t.soc)   // 離線：電池圖示不留綠色
        p.text(res.title, lab, x: 56, base: p.base(top: 372, lineHeight: 32, lab), color: t.secondary)
        let big2 = p.font(96, t.night && res.severity == .critical ? 600 : 300), unit2 = p.font(40, 300)
        let bb2 = p.base(top: 408, lineHeight: 96, big2)
        let rn = pct(res.percent)
        let wn2 = p.text(rn, big2, x: 56, base: bb2, color: t.toneText(res.severity) ?? t.label, kern: -96 * 0.02)
        if res.percent != nil { p.text("%", unit2, x: 56 + wn2 + 4, base: bb2, color: t.secondary) }
        let nf2 = p.font(26, res.severity != nil ? 590 : 510, mono: false)
        p.text(res.note, nf2, x: 1032, base: bb2, color: t.toneText(res.severity) ?? t.secondary, align: .right)
        var bar2 = ClusterBar(rect: CGRect(x: 56, y: 520, width: 976, height: 16), track: t.track)
        bar2.dashed = ro.offline
        if let v = res.percent { bar2.fills = [(0, CGFloat(min(max(v, 0), 100) / 100), resColor, true, true)] }
        p.bar(bar2)

        p.line(CGPoint(x: 56, y: 556.5), CGPoint(x: 1032, y: 556.5), width: 1, color: t.hairline)

        // 一列一個線性錶：標籤 140 寬、錶 520 寬（x=216）、讀值右對齊到 1032
        let rl = p.font(24, 510, mono: false), vb = p.font(24, 590), vr = p.font(24, 400)
        func row(_ top: CGFloat, _ title: String, _ bar: ClusterBar?, _ parts: [(String, NSFont, NSColor)]) {
            p.text(title, rl, x: 56, base: p.base(top: top, lineHeight: 50, rl), color: t.secondary)
            if var b = bar { b.rect = CGRect(x: 216, y: top + 20, width: 520, height: 10); p.bar(b) }
            p.runs(parts, x: 1032, base: p.base(top: top, lineHeight: 50, vr), align: .right)
        }
        func frac(_ v: Double, _ lo: Double, _ hi: Double) -> CGFloat { CGFloat(min(max((v - lo) / (hi - lo), 0), 1)) }
        let dash: [(String, NSFont, NSColor)] = [("—", vb, t.label)]
        func freqRow(_ top: CGFloat, _ c: CPUCluster?, name: String) {
            guard c != nil || ro.offline else { return }   // 離線：兩列照樣在，值是「—」
            var b = ClusterBar(rect: .zero, track: t.track)
            b.dashed = ro.offline
            let hi = ((c?.maxMHz) ?? 0) / 1000
            if let m = c?.mhz, hi > 0 { b.fills = [(0, frac(m / 1000, 0, hi), t.accent, true, true)] }
            let parts: [(String, NSFont, NSColor)] = c?.mhz == nil ? dash
                : [(String(format: "%.2f", c!.mhz! / 1000), vb, t.label)] + (hi > 0 ? [(String(format: " / %.2f GHz", hi), vr, t.secondary)] : [(" GHz", vr, t.secondary)])
            row(top, String(format: L("cluster.clusterName", "%@ 集群"), c?.short ?? name), b, parts)
        }
        freqRow(576, ro.fast, name: "S")
        freqRow(626, ro.slow, name: "E")

        // 功率：雙向，零點在 −20…40 W 的三分之一處
        var pb = ClusterBar(rect: .zero, track: t.track)
        pb.dashed = ro.offline
        var pparts = dash
        if let w = ro.powerW {
            let z = frac(0, -20, 40), v = frac(w, -20, 40)
            if w < 0 { pb.fills = [(0, z, t.soc.withAlphaComponent(0.16), true, false), (v, z, t.soc, false, false)] }
            else { pb.fills = [(0, z, t.soc.withAlphaComponent(0.16), true, false), (z, v, t.accent, false, true)] }
            pparts = [(w < 0 ? L("cluster.powerCharge", "充电") + " " : L("cluster.powerDraw", "耗电") + " ", vr, t.secondary),
                      (String(format: "%.1f", abs(w)), vb, t.label), (" W", vr, t.secondary)]
        }
        pb.marks = [(frac(0, -20, 40), t.label, 2, 9, 9)]
        row(676, L("cluster.power", "功率"), pb, pparts)

        // SoC 溫度：30–110，紅區與限制線在 100
        var tb = ClusterBar(rect: .zero, track: t.track)
        tb.dashed = ro.offline
        tb.bands = [(70 / 80, 1, t.critical.withAlphaComponent(0.24))]
        tb.marks = [(70 / 80, t.critical, 3, 9, 9)]
        var tparts = dash
        if let c = ro.socTemp {
            tb.fills = [(0, frac(c, 30, 110), t.tone(MetricRules.status(tempC: c)), true, true)]
            tparts = [(String(format: "%.1f", c), vb, t.label), (" / 100 °C", vr, t.secondary)]
        }
        row(726, L("cluster.temp", "SoC 温度"), tb, tparts)

        // 記憶體：已用／總量＋壓力三段＋置換、壓縮
        var mb = ClusterBar(rect: .zero, track: t.track)
        mb.dashed = ro.offline
        var mparts = dash
        if let m = ro.memory, m.totalBytes > 0 {
            mb.fills = [(0, CGFloat(min(Double(m.usedBytes) / Double(m.totalBytes), 1)), t.accent, true, true)]
            mparts = [(String(format: "%.1f", Double(m.usedBytes) / 1e9), vb, t.label), (String(format: " / %.0f GB", Double(m.totalBytes) / 1e9), vr, t.secondary)]
        }
        row(776, L("cluster.memory", "内存"), mb, mparts)
        if let m = ro.memory {
            let sev = MetricRules.status(memoryPressure: m.pressureLevel)
            let segs = m.pressureLevel >= 4 ? 3 : m.pressureLevel >= 2 ? 2 : 1
            for i in 0..<3 { p.fillRounded(CGRect(x: 216 + CGFloat(i) * 32, y: 828 + 8 + 4, width: 28, height: 8), radius: 4, i < segs ? t.tone(sev) : t.track) }
            let sf = p.font(20, 400)
            let word = sev == .critical ? L("cluster.mem.pressureCrit", "压力告急") : sev == .warn ? L("cluster.mem.pressureWarn", "压力偏高") : L("cluster.mem.pressureOk", "压力正常")
            let ww = p.text(word, sf, x: 216 + 92 + 10, base: p.base(mid: 840, sf), color: t.secondary)
            let swap = String(format: L("cluster.mem.swap", "置换 %@ / %@ GB · 压缩 %@ GB"), String(format: "%.1f", Double(m.swapUsedBytes) / 1e9),
                              String(format: "%.1f", Double(m.swapTotalBytes) / 1e9), String(format: "%.1f", Double(m.compressedBytes) / 1e9))
            p.text(swap, sf, x: 216 + 92 + 10 + ww + 10 + 14, base: p.base(mid: 840, sf), color: t.secondary)
        }

        drawClusterCardC(p, ro)
    }

    private func drawClusterCardC(_ p: ClusterPainter, _ ro: ClusterReadout) {
        let t = p.t
        let r = CGRect(x: 56, y: 882, width: 976, height: 150)
        p.cardBackground(r, radius: 32)
        let sm = p.font(20, 600), lb = p.font(20, 510, mono: false)
        let procs = Array(ro.processes.prefix(3))
        let warn = ro.warningLine
        if procs.isEmpty {   // 沒有程序資料：退回一般的卡
            let c = ro.card
            p.iconTile(CGRect(x: 88, y: r.midY - 38, width: 76, height: 76), radius: 20, symbol: c.symbol, color: cardColor(c, t), solid: cardSolid(c), glyph: 44)
            let tf = p.font(30, 510, mono: false), sf = p.font(24, 400, mono: false)
            let avail = r.maxX - 32 - 188
            let h: CGFloat = 36 + 8 + (c.sub == nil ? 0 : 28.8), top = r.midY - h / 2
            p.text(Face.clipped(c.title, tf, avail), tf, x: 188, base: p.base(top: top, lineHeight: 36, tf), color: t.label)
            if let s = c.sub { p.text(Face.clipped(s, sf, avail), sf, x: 188, base: p.base(top: top + 44, lineHeight: 28.8, sf), color: t.secondary) }
            return
        }
        var y: CGFloat = r.minY + (r.height - ((warn == nil ? 0 : 32) + 24 + 8 + 68)) / 2
        if let w = warn {
            p.text(Face.clipped(w.sub.map { w.text + " · " + $0 } ?? w.text, sm, r.width - 64), sm, x: 88, base: p.base(top: y, lineHeight: 24, sm), color: t.toneText(w.severity) ?? t.label)
            y += 32
        }
        p.text(L("cluster.busiest", "最忙进程 · CPU"), lb, x: 88, base: p.base(top: y, lineHeight: 24, lb), color: t.secondary)
        y += 32
        let colW: CGFloat = (976 - 64 - 48) / 3
        let pf = p.font(34, 590), nf = p.font(20, 400, mono: false)
        for (i, pr) in procs.enumerated() {
            let x = 88 + CGFloat(i) * (colW + 24)
            p.text(String(format: "%.1f%%", pr.cpuPercent), pf, x: x, base: p.base(top: y, lineHeight: 40, pf), color: t.label)
            p.text(Face.clipped(ro.shown(pr.name), nf, colW), nf, x: x, base: p.base(top: y + 44, lineHeight: 24, nf), color: t.secondary)
        }
    }
}
