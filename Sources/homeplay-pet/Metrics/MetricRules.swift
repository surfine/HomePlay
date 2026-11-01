// 2.0 D1：儀表的警示規則與讀值格式——純函數，不碰 UI 字串（規格 docs/homeview-platform.md 四之三「警示門檻」、R2、R8、R11）。
//
// 錶面和警示燈都從這裡拿顏色等級，所以「電量 18% 的錶是橘的」和「亮電量燈」永遠一致。

import Foundation

/// 警示燈的種類。順序就是同等級時的排列優先序。
enum TelltaleKind: Int, Codable, CaseIterable {
    case thermal, battery, memory, disk, socTemp
}

/// 正常不算一級：沒事就是 nil，錶面用主題主色。
enum Severity: Int, Codable, Comparable {
    case warn = 1, critical = 2
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

struct Telltale: Equatable {
    var kind: TelltaleKind
    var severity: Severity
    /// 補充資料，給 dynamic content 卡用（磁碟＝卷宗名稱）；燈本身只寫通用狀態
    var detail: String?
}

enum MetricRules {
    /// 規格 R8：頂緣同時最多亮 3 顆
    static let maxTelltales = 3

    static func telltales(_ s: MetricSnapshot) -> [Telltale] {
        var out: [Telltale] = []
        if let v = status(thermal: s.thermalPressure) { out.append(Telltale(kind: .thermal, severity: v)) }
        // 接電而且在充就不亮燈：電量正在回來，亮燈只是噪音。錶面照規格仍依電量上色。
        // 接著電卻沒在充（變壓器功率不夠、最佳化充電暫停）照亮，因為電量不會自己回來。
        if !(s.battery?.onAC == true && s.battery?.charging == true), let v = status(battery: s.battery) {
            out.append(Telltale(kind: .battery, severity: v))
        }
        if let v = status(memoryPressure: s.memory?.pressureLevel) { out.append(Telltale(kind: .memory, severity: v)) }
        // 磁碟只亮一顆，說明最滿的那一個卷宗
        if let worst = s.volumes.max(by: { $0.usedPercent < $1.usedPercent }), let v = status(volumeUsedPercent: worst.usedPercent) {
            out.append(Telltale(kind: .disk, severity: v, detail: worst.name))
        }
        if let v = status(tempC: s.socTempC) { out.append(Telltale(kind: .socTemp, severity: v)) }
        out.sort { $0.severity != $1.severity ? $0.severity > $1.severity : $0.kind.rawValue < $1.kind.rawValue }
        return Array(out.prefix(maxTelltales))
    }

    // 下面每個 status 給錶面上色用；nil＝正常。

    /// 電量 ≤20 橘、≤10 紅（只看電量；充電中不亮燈的例外在 telltales()）
    static func status(battery b: BatteryReading?) -> Severity? {
        guard let b else { return nil }
        if b.percent <= 10 { return .critical }
        if b.percent <= 20 { return .warn }
        return nil
    }

    /// kern.memorystatus_vm_pressure_level：1 正常、2 警示、4 危急
    static func status(memoryPressure level: Int?) -> Severity? {
        guard let level else { return nil }
        if level >= 4 { return .critical }
        if level >= 2 { return .warn }
        return nil
    }

    /// Moderate 只改字色（錶面自己看 ThermalPressure），不亮燈；Heavy 橘；Trapping 起紅
    static func status(thermal t: ThermalPressure?) -> Severity? {
        guard let t else { return nil }
        if t >= .trapping { return .critical }
        if t == .heavy { return .warn }
        return nil
    }

    /// SoC 溫度 ≥90 °C 橘、≥100 °C 紅（溫度錶的紅色限制線也畫在 100）
    static func status(tempC c: Double?) -> Severity? {
        guard let c else { return nil }
        if c >= 100 { return .critical }
        if c >= 90 { return .warn }
        return nil
    }

    /// 卷宗 ≥90% 橘、≥97% 紅
    static func status(volumeUsedPercent p: Double?) -> Severity? {
        guard let p else { return nil }
        if p >= 97 { return .critical }
        if p >= 90 { return .warn }
        return nil
    }
}

/// 錶上的數字字串。只有數字與單位，不需要在地化；讀不到一律「—」（規格 R11）。
enum MetricFormat {
    static let missing = "—"

    /// 19.4 → "19"
    static func percent(_ v: Double?) -> String {
        guard let v, v.isFinite else { return missing }
        return String(Int(v.rounded()))
    }

    /// 10 W 以下留一位小數，指針附近的小數字才不會整數跳動
    static func watts(_ v: Double?) -> String {
        guard let v, v.isFinite else { return missing }
        return abs(v) < 10 ? String(format: "%.1f", v) : String(Int(v.rounded()))
    }

    /// 2720 MHz → "2.7"
    static func ghz(fromMHz v: Double?) -> String {
        guard let v, v.isFinite else { return missing }
        return String(format: "%.1f", v / 1000)
    }

    static func celsius(_ v: Double?) -> String {
        guard let v, v.isFinite else { return missing }
        return String(Int(v.rounded()))
    }

    /// 1 位小數的 GB（1e9，跟 Finder、活動監視器一樣用十進位）
    static func gigabytes(_ v: UInt64?) -> String {
        guard let v else { return missing }
        return String(format: "%.1f GB", Double(v) / 1e9)
    }

    /// 速率自動挑單位（十進位，跟活動監視器一致）；小於 1 KB/s 算 0
    static func bytesPerSec(_ v: Double?) -> String {
        guard let v, v.isFinite else { return missing }
        let a = max(0, v)
        if a >= 1e9 { return String(format: "%.1f GB/s", a / 1e9) }
        if a >= 1e6 { return String(format: "%.1f MB/s", a / 1e6) }
        return String(format: "%.0f KB/s", a / 1e3)
    }
}
