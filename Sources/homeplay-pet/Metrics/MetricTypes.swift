// 2.0 D1：HomePlay 儀表的資料層——共用型別與資料源協定（規格見 HomePlay docs/homeview-platform.md 第四節）。
//
// 兩層資料源：
//   A 層＝公開 API（host_processor_info、sysctl、IOPowerSources、statfs、getifaddrs、IOKit registry），永遠可用；
//   B 層＝不需 root 的私有讀值（IOReport、AppleSMC），讀不到就留 nil，畫面顯示「—」，不用 0 假裝（規格 R11）。
// 做法參考 mactop（MIT，metaspartan/mactop）、macmon（MIT，vladkens/macmon）、Stats（MIT，exelban/stats），程式自寫。
//
// 這個檔只用 Foundation，各資料源檔可以跟它一起單獨用 swiftc 編譯、直接在本機讀值。

import Foundation

/// 一次取樣的結果。每一欄都可缺：讀不到就是 nil。
struct MetricSnapshot: Codable, Equatable {
    var time = Date()

    // 負載（速度表）
    /// 全部核心的平均使用率，0–100（host_processor_info 的 tick 差值）
    var cpuPercent: Double?
    /// 依 hw.perflevelN 分的叢集；這台 M5 是 S（Super）4 核＋E（Efficiency）6 核
    var clusters: [CPUCluster] = []
    /// 每核使用率，0–100，順序同 CPU 編號
    var coreUsage: [Double] = []

    // GPU
    var gpuPercent: Double?
    var gpuMHz: Double?
    var gpuMaxMHz: Double?

    // 電量（必備）
    var battery: BatteryReading?

    // 功率
    var power: PowerReading?

    // 溫度（°C）
    var socTempC: Double?
    var cpuTempC: Double?
    var gpuTempC: Double?

    // 熱壓力（5 級）
    var thermalPressure: ThermalPressure?

    // 記憶體
    var memory: MemoryReading?

    // 磁碟、網路（每秒位元組；第一次取樣沒有差值，留 nil）
    var volumes: [VolumeReading] = []
    var netInBytesPerSec: Double?
    var netOutBytesPerSec: Double?
    var diskReadBytesPerSec: Double?
    var diskWriteBytesPerSec: Double?

    /// 開機到現在的秒數
    var uptime: TimeInterval?

    /// 最忙的幾個程序（CPU 時間增量由大到小）；第一次取樣或讀不到就是 nil。舊的存檔沒有這欄也能解（optional）
    var topProcesses: [ProcessUsage]?
}

struct CPUCluster: Codable, Equatable {
    /// hw.perflevelN.name 原文：「Super」「Efficiency」「Performance」
    var name: String
    /// 標籤縮寫：取 name 的第一個字母（S／E／P）
    var short: String
    var cores: Int
    /// 這個叢集的核心平均使用率（tick 差值），0–100
    var usagePercent: Double?
    /// IOReport 駐留時間算出的忙碌比例（OFF／IDLE／DOWN 以外），0–100
    var activePercent: Double?
    /// 駐留時間加權的平均頻率
    var mhz: Double?
    /// DVFS 表的最高頻率（轉速表刻度上限）
    var maxMHz: Double?
}

struct BatteryReading: Codable, Equatable {
    /// 0–100
    var percent: Double
    var charging: Bool
    /// 接著電源（可能已充飽、沒在充）
    var onAC: Bool
}

/// 功率，單位瓦。正負號約定：batteryW 正＝電池在放電（供電給機器），負＝在充電（功率錶左段「充電」）。
struct PowerReading: Codable, Equatable {
    /// 整機（SMC PSTR）
    var systemW: Double?
    /// 電池（SMC PPBR，照上面的正負號）
    var batteryW: Double?
    /// 電源輸入（SMC PDTR）
    var adapterW: Double?
    /// IOReport Energy Model；macOS 27 可能停更，停更就留 nil
    var cpuW: Double?
    var gpuW: Double?
    var aneW: Double?
    var dramW: Double?
}

/// com.apple.system.thermalpressurelevel 的 5 級（比 ProcessInfo.thermalState 的 4 級細）
enum ThermalPressure: Int, Codable, Comparable {
    case nominal = 0, moderate = 1, heavy = 2, trapping = 3, sleeping = 4
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

struct MemoryReading: Codable, Equatable {
    var totalBytes: UInt64
    /// 跟活動監視器同一種算法：App 記憶體＋固定＋壓縮
    var usedBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var swapUsedBytes: UInt64
    var swapTotalBytes: UInt64
    /// kern.memorystatus_vm_pressure_level：1 正常、2 警示、4 危急
    var pressureLevel: Int
}

struct VolumeReading: Codable, Equatable {
    var name: String
    var totalBytes: UInt64
    /// 0–100
    var usedPercent: Double
    var isInternal: Bool
}

/// 一個資料源只管自己那幾欄。sample 把讀到的寫進 snapshot；讀不到就不寫（保持 nil），不丟錯、不印 log 洗版。
protocol MetricSource: AnyObject {
    var name: String { get }
    /// 準備工作（開 IOReport 訂閱、連 SMC、找鍵）。回 false＝這台機器用不了，取樣器之後不再呼叫 sample。
    func start() -> Bool
    /// interval＝距上一次 sample 的實際秒數；第一次是 nil，差值型讀值這次留 nil。
    func sample(into s: inout MetricSnapshot, interval: TimeInterval?)
}

/// 預設的資料源組合。類別名稱是各檔的約定：都有無參數的 init()。
enum MetricSources {
    static func standard() -> [MetricSource] {
        [CPUTickSource(), MemorySource(), BatterySource(), ThermalSource(), VolumeSource(),
         NetworkSource(), DiskIOSource(), UptimeSource(), TopProcessSource(), SMCSource(), IOReportSource()]
    }
}
