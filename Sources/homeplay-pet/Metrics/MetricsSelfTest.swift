// 2.0 D1：儀表資料層的自測——注入假讀值，驗警示門檻的每個邊、排序與上限、「—」、平滑與取樣器（MetricRules.swift、MetricsSampler.swift）。

import Foundation

enum MetricsSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        func snap(_ edit: (inout MetricSnapshot) -> Void) -> MetricSnapshot { var s = MetricSnapshot(); edit(&s); return s }
        func bat(_ p: Double, charging: Bool = false, ac: Bool = false) -> BatteryReading { BatteryReading(percent: p, charging: charging, onAC: ac) }
        func mem(_ level: Int) -> MemoryReading {
            MemoryReading(totalBytes: 24_000_000_000, usedBytes: 18_000_000_000, wiredBytes: 0, compressedBytes: 0, swapUsedBytes: 0, swapTotalBytes: 0, pressureLevel: level)
        }
        func vol(_ name: String, _ p: Double) -> VolumeReading { VolumeReading(name: name, totalBytes: 2_000_000_000_000, usedPercent: p, isInternal: false) }

        // 電量：≤20 橘、≤10 紅；接電又在充不亮
        check(MetricRules.status(battery: bat(21)) == nil, "儀表：電量 21% 正常")
        check(MetricRules.status(battery: bat(20)) == .warn && MetricRules.status(battery: bat(19)) == .warn, "儀表：電量 20%、19% 橘")
        check(MetricRules.status(battery: bat(11)) == .warn && MetricRules.status(battery: bat(10)) == .critical, "儀表：電量 11% 橘、10% 紅")
        check(MetricRules.status(battery: bat(8, charging: true, ac: true)) == .critical, "儀表：充電中的錶面仍依電量上色")
        check(MetricRules.status(battery: bat(8, ac: true)) == .critical, "儀表：接電但沒在充仍警示")
        check(MetricRules.status(battery: nil) == nil, "儀表：沒電池不警示")
        check(MetricRules.telltales(snap { $0.battery = bat(15, charging: true, ac: true) }).isEmpty, "儀表：接電充電中不亮電量燈")

        // 記憶體壓力 1／2／4
        check(MetricRules.status(memoryPressure: 1) == nil && MetricRules.status(memoryPressure: 2) == .warn && MetricRules.status(memoryPressure: 4) == .critical, "儀表：記憶體壓力 1 正常、2 橘、4 紅")

        // 熱壓力：Moderate 不亮燈、Heavy 橘、Trapping 起紅
        check(MetricRules.status(thermal: .nominal) == nil && MetricRules.status(thermal: .moderate) == nil, "儀表：熱壓力 Moderate 不亮燈")
        check(MetricRules.status(thermal: .heavy) == .warn, "儀表：熱壓力 Heavy 橘")
        check(MetricRules.status(thermal: .trapping) == .critical && MetricRules.status(thermal: .sleeping) == .critical, "儀表：熱壓力 Trapping、Sleeping 紅")

        // SoC 溫度 89.9／90／100
        check(MetricRules.status(tempC: 89.9) == nil && MetricRules.status(tempC: 90) == .warn && MetricRules.status(tempC: 99.9) == .warn && MetricRules.status(tempC: 100) == .critical, "儀表：溫度 89.9 正常、90 橘、100 紅")

        // 卷宗 89／90／97，燈只亮最滿的那顆
        check(MetricRules.status(volumeUsedPercent: 89) == nil && MetricRules.status(volumeUsedPercent: 90) == .warn && MetricRules.status(volumeUsedPercent: 97) == .critical, "儀表：卷宗 89 正常、90 橘、97 紅")
        let disks = MetricRules.telltales(snap { $0.volumes = [vol("Mac HD", 85), vol("MU-PE2T0K", 95.4), vol("Backup", 92)] })
        check(disks == [Telltale(kind: .disk, severity: .warn, detail: "MU-PE2T0K")], "儀表：磁碟燈只亮一顆、說明最滿的卷宗")

        // 排序：紅在前，同級照 熱壓力、電量、記憶體、磁碟、溫度；最多 3 顆
        let all = MetricRules.telltales(snap {
            $0.thermalPressure = .heavy; $0.battery = bat(18); $0.memory = mem(4); $0.volumes = [vol("X", 98)]; $0.socTempC = 95
        })
        check(all.map(\.kind) == [.memory, .disk, .thermal] && all.map(\.severity) == [.critical, .critical, .warn], "儀表：紅燈優先、最多 3 顆")
        let warns = MetricRules.telltales(snap { $0.socTempC = 91; $0.volumes = [vol("X", 91)]; $0.memory = mem(2); $0.battery = bat(20); $0.thermalPressure = .heavy })
        check(warns.map(\.kind) == [.thermal, .battery, .memory], "儀表：同級照固定順序")
        check(MetricRules.telltales(MetricSnapshot()).isEmpty, "儀表：全部讀不到就不亮燈")

        // D3：六種狀態（States 板）。每種狀態亮的燈、離線不出 0、訪客遮名
        func kinds(_ st: ClusterState) -> [TelltaleKind] { ClusterDemo.readout(.a, state: st).telltales.map(\.kind) }
        check(kinds(.normal).isEmpty && kinds(.memory) == [.memory] && kinds(.thermal) == [.thermal] && kinds(.battery) == [.battery] && kinds(.disk) == [.disk], "儀表狀態：正常沒燈，其餘各亮對應那一顆")
        check(ClusterDemo.readout(.a, state: .battery).telltales.first?.severity == .critical && ClusterDemo.readout(.a, state: .disk).telltales.first?.severity == .warn, "儀表狀態：電量 8% 紅、磁碟 95.4% 橘")
        let off = ClusterDemo.readout(.a, state: .offline)
        check(off.offline && off.telltales.isEmpty && off.cpu == nil && off.battery == nil && off.socTemp == nil && off.powerW == nil && MetricFormat.percent(off.cpu) == "—", "儀表狀態：離線沒有燈、讀值全是 nil（顯示「—」不是 0）")
        check(off.card.title != "" && off.card.sub?.contains("03:24") == true, "儀表狀態：離線的卡寫最後更新時間")
        var guest = ClusterDemo.readout(.c, state: .disk)
        check(guest.card.title.contains("MU-PE2T0K") && guest.shown("claude") == "claude", "儀表訪客：主人看得到卷宗名")
        guest.masked = true
        check(!guest.card.title.contains("MU-PE2T0K") && guest.card.title.contains("4.6%") && guest.shown("claude") != "claude", "儀表訪客：卷宗名、程序名遮掉，百分比照常")
        let many = MetricRules.telltales(snap { $0.thermalPressure = .heavy; $0.battery = bat(8); $0.memory = mem(2); $0.volumes = [vol("X", 92)] })
        check(many.count == MetricRules.maxTelltales && many.first?.kind == .battery, "儀表狀態：多燈最多 3 顆、紅的在最前")

        // 格式：nil 一律「—」
        check([MetricFormat.percent(nil), MetricFormat.watts(nil), MetricFormat.ghz(fromMHz: nil), MetricFormat.celsius(nil), MetricFormat.bytesPerSec(nil), MetricFormat.gigabytes(nil)].allSatisfy { $0 == "—" }, "儀表：讀不到顯示「—」")
        check(MetricFormat.percent(.nan) == "—", "儀表：NaN 也顯示「—」")
        check(MetricFormat.percent(19.4) == "19" && MetricFormat.ghz(fromMHz: 2720) == "2.7" && MetricFormat.celsius(61.9) == "62", "儀表：百分比、GHz、°C")
        check(MetricFormat.watts(1.84) == "1.8" && MetricFormat.watts(16.9) == "17" && MetricFormat.watts(-4.2) == "-4.2", "儀表：瓦數（充電為負）")
        check(MetricFormat.bytesPerSec(300_000) == "300 KB/s" && MetricFormat.bytesPerSec(4_300_000) == "4.3 MB/s", "儀表：速率自動換單位")

        // 平滑：nil 原樣傳、會收斂、nil 之後從新值重新起步
        var sm = MetricSmoother(alpha: 0.5)
        var out = sm.apply(snap { $0.cpuPercent = 0 }, interval: 1)
        check(out.cpuPercent == 0, "平滑：第一筆就是原值")
        out = sm.apply(snap { $0.cpuPercent = 100 }, interval: 1)
        check(abs((out.cpuPercent ?? -1) - 50) < 1e-9, "平滑：α=0.5 走一半")
        for _ in 0..<30 { out = sm.apply(snap { $0.cpuPercent = 100 }, interval: 1) }
        check(abs((out.cpuPercent ?? 0) - 100) < 1e-6, "平滑：會收斂到原值")
        out = sm.apply(snap { $0.cpuPercent = nil; $0.gpuPercent = nil }, interval: 1)
        check(out.cpuPercent == nil && out.gpuPercent == nil && out.power == nil, "平滑：讀不到就傳 nil，不拿舊值")
        out = sm.apply(snap { $0.cpuPercent = 20 }, interval: 1)
        check(out.cpuPercent == 20, "平滑：讀值回來從新值起步")
        var sm2 = MetricSmoother(alpha: 0.5)
        _ = sm2.apply(snap { $0.cpuPercent = 0 }, interval: 1)
        out = sm2.apply(snap { $0.cpuPercent = 100 }, interval: 2)
        check(abs((out.cpuPercent ?? -1) - 75) < 1e-9, "平滑：2 秒間隔換算成等效係數")
        let cl = CPUCluster(name: "Super", short: "S", cores: 4, usagePercent: 30, activePercent: nil, mhz: 1000, maxMHz: 4460)
        var sm3 = MetricSmoother(alpha: 0.5)
        _ = sm3.apply(snap { $0.clusters = [cl]; $0.power = PowerReading(systemW: 10) }, interval: 1)
        var cl2 = cl; cl2.mhz = 3000
        out = sm3.apply(snap { $0.clusters = [cl2]; $0.power = PowerReading(systemW: 20, batteryW: -3) }, interval: 1)
        check(out.clusters.first?.mhz == 2000 && out.clusters.first?.usagePercent == 30 && out.power?.systemW == 15 && out.power?.batteryW == -3, "平滑：叢集頻率與整機功率；其他欄位原樣")

        check(MetricsSampler.period(base: 1, after: snap { $0.battery = bat(20) }) == 2 && MetricsSampler.period(base: 1, after: snap { $0.battery = bat(21) }) == 1, "取樣器：用電池、電量 ≤20% 降到 0.5 Hz")
        check(MetricsSampler.period(base: 1, after: snap { $0.battery = bat(15, ac: true) }) == 1 && MetricsSampler.period(base: 1, after: MetricSnapshot()) == 1, "取樣器：接電或沒電池維持 1 Hz")

        // 取樣器：start() 回 false 的資料源剔除；第一次沒有間隔、第二次有
        final class FakeSource: MetricSource {
            let name: String; let ok: Bool; var intervals: [TimeInterval?] = []
            init(_ name: String, ok: Bool) { self.name = name; self.ok = ok }
            func start() -> Bool { ok }
            func sample(into s: inout MetricSnapshot, interval: TimeInterval?) {
                intervals.append(interval)
                s.cpuPercent = 42
                s.battery = BatteryReading(percent: 15, charging: false, onAC: false)
            }
        }
        let good = FakeSource("good", ok: true), bad = FakeSource("bad", ok: false)
        let sampler = MetricsSampler(sources: [good, bad], interval: 1)
        let first = sampler.sampleOnce()
        _ = sampler.sampleOnce()
        check(sampler.activeSourceNames == ["good"] && bad.intervals.isEmpty, "取樣器：start() 失敗的資料源不再取樣")
        check(good.intervals.count == 2 && good.intervals[0] == nil && (good.intervals[1] ?? -1) >= 0, "取樣器：第一次沒有間隔，之後是實測間隔")
        check(first.cpuPercent == 42 && sampler.latest?.cpuPercent == 42 && sampler.latestSmoothed?.cpuPercent == 42, "取樣器：保留最近一次讀值")
    }
}
