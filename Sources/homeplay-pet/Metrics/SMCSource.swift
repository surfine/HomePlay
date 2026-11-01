// 2.0 D1：AppleSMC 讀值——整機／電池／電源功率與 CPU、GPU 溫度（B 層，不需 root，讀不到留 nil）。
// 做法參考 mactop（MIT，internal/app/smc.c、ioreport.m 的 loadSMCTempKeys／readSocTemperature／readSystemPower）
// 與 Stats（MIT，SMC/smc.swift 的 SMCKeyData 版面），程式自寫。

import Foundation
import IOKit

final class SMCSource: MetricSource {
    let name = "SMC"

    private var smc: SMCClient?
    private var cpuKeys: [SMCClient.Key] = []
    private var gpuKeys: [SMCClient.Key] = []
    private var systemKey: SMCClient.Key?
    private var adapterKey: SMCClient.Key?
    private var batteryCurrentKey: SMCClient.Key?
    private var batteryVoltageKey: SMCClient.Key?
    private var batteryLittleEndian = true

    init() {}

    func start() -> Bool {
        guard smc == nil else { return true }
        guard let c = SMCClient() else { return false }
        smc = c

        // 鍵表只掃一次（這台約兩千多個鍵）；之後每次取樣只讀值，不再查型別
        let count = c.keyCount() ?? 0
        for i in 0..<count {
            guard let name = c.keyName(at: i), name.hasPrefix("T"),
                  let key = c.key(name), key.isTemperatureType else { continue }
            let kind = name.dropFirst().first
            // Tp／Te／Tf＝CPU 叢集的晶粒感測器，Tg＝GPU（mactop 的 SMC 前綴；大寫 TF 是風扇附近，不算）。
            // Ts 不收：mactop 只在 M5 Pro／Max 這類有 S 核心的晶片才把 Ts 當 CPU，這台基本款 M5 的 Ts 是 SSD，
            // 其中 Ts0P／Ts1P 只有 33 °C，混進來會把 CPU 平均拉低好幾度
            if kind == "p" || kind == "e" || kind == "f" { cpuKeys.append(key) }
            else if kind == "g" { gpuKeys.append(key) }
        }

        systemKey = c.key("PSTR")
        adapterKey = c.key("PDTR")
        // 實測這台（2026-10-29）：PSTR(t) 每筆都恰好等於上一筆的 PDTR(t−1)，連振動的雜訊都一樣——
        // PSTR 的暫存器更新比 PDTR 慢一個週期，是 SMC 的行為，讀值順序與程式無關；整機瓦數因此晚約 1 秒

        // 電池功率不用 PPBR：這台接電充飽、電量計電流 0 mA 時 PPBR 仍讀 1.3–1.8 W，它不是電池充放電功率
        // （複查同日：B0AC=0 mA 時 PPBR 恆 1.7 W、完全不隨電池電流動）。
        // 改用電量計的電流 B0AC（mA，負＝放電）× 電壓 B0AV（mV）。這兩個鍵在 M5 上是小端（B0AV 小端解出
        // 12920 mV，跟 AppleSmartBattery 的 Voltage 一致），跟 #KEY 的大端不同，所以用電壓的合理範圍判斷位元序
        if let i = c.key("B0AC"), let v = c.key("B0AV"), i.size == 2, v.size == 2, let raw = c.readBytes(v) {
            let le = Double(UInt16(raw[0]) | UInt16(raw[1]) << 8)
            let be = Double(UInt16(raw[0]) << 8 | UInt16(raw[1]))
            let plausible: (Double) -> Bool = { $0 >= 6000 && $0 <= 20000 }  // 筆電電池 2–4 串鋰電
            if plausible(le) || plausible(be) {
                batteryLittleEndian = plausible(le)
                batteryCurrentKey = i
                batteryVoltageKey = v
            }
        }
        return true
    }

    func sample(into s: inout MetricSnapshot, interval: TimeInterval?) {
        guard let c = smc else { return }

        let cpu = Self.average(cpuKeys.compactMap { c.read($0) })
        let gpu = Self.average(gpuKeys.compactMap { c.read($0) })
        if let cpu { s.cpuTempC = cpu }
        if let gpu { s.gpuTempC = gpu }
        // socTempC 跟 mactop 的 soc_temp 同定義：CPU、GPU 平均溫度取較高者
        if let soc = [cpu, gpu].compactMap({ $0 }).max() { s.socTempC = soc }

        var p = s.power ?? PowerReading()
        var wrote = false
        // PSTR 讀 0 代表這台不提供（mactop：Mac Studio 讀 0），不是真的 0 瓦
        if let k = systemKey, let w = c.read(k), w > 0, w < 1000 { p.systemW = w; wrote = true }
        if let k = adapterKey, let w = c.read(k), w >= 0, w < 1000 { p.adapterW = w; wrote = true }
        if let ik = batteryCurrentKey, let vk = batteryVoltageKey,
           let i = c.readBytes(ik), let v = c.readBytes(vk) {
            let mA = Double(Int16(bitPattern: batteryLittleEndian ? UInt16(i[0]) | UInt16(i[1]) << 8 : UInt16(i[0]) << 8 | UInt16(i[1])))
            let mV = Double(batteryLittleEndian ? UInt16(v[0]) | UInt16(v[1]) << 8 : UInt16(v[0]) << 8 | UInt16(v[1]))
            // 介面約定放電為正，電量計是放電為負，所以反號；+ 0 把 -0 變成 0
            p.batteryW = -(mA * mV) / 1_000_000 + 0
            wrote = true
        }
        if wrote { s.power = p }
    }

    /// 晶片通電時不會低於 10 °C：開機初期感測器會短暫回報 2 °C 左右的未初始化值（mactop issue #70 的 silicon floor）
    private static func average(_ values: [Double]) -> Double? {
        let ok = values.filter { $0 > 10 && $0 <= 130 }
        return ok.isEmpty ? nil : ok.reduce(0, +) / Double(ok.count)
    }
}

/// AppleSMC 使用者端：連線在 init 開、deinit 關，中間一直保留（每次重開要多走一趟 IOServiceOpen）。
final class SMCClient {
    struct Key {
        let code: UInt32
        let type: UInt32
        let size: UInt32

        var isTemperatureType: Bool { type == SMCClient.fourCC("flt ") || type == SMCClient.fourCC("sp78") }
    }

    private var conn: io_connect_t = 0

    init?() {
        // 結構版面錯了 IOKit 會回錯或讀到垃圾；寧可整個不用
        guard MemoryLayout<ParamBlock>.size == 80 else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess, conn != 0 else { return nil }
    }

    deinit {
        if conn != 0 { IOServiceClose(conn) }
    }

    func keyCount() -> Int? {
        guard let k = key("#KEY"), let n = read(k) else { return nil }
        return Int(n)
    }

    func keyName(at index: Int) -> String? {
        var input = ParamBlock()
        input.data8 = Command.readIndex
        input.data32 = UInt32(index)
        guard let out = call(&input) else { return nil }
        return Self.string(out.key)
    }

    /// 查鍵的型別與長度；鍵不存在回 nil
    func key(_ name: String) -> Key? {
        guard name.utf8.count == 4 else { return nil }
        let code = Self.fourCC(name)
        var input = ParamBlock()
        input.key = code
        input.data8 = Command.readKeyInfo
        guard let out = call(&input), out.dataSize > 0 else { return nil }
        return Key(code: code, type: out.dataType, size: out.dataSize)
    }

    func read(_ k: Key) -> Double? {
        guard let out = readBlock(k) else { return nil }
        return Self.decode(out.bytes, type: k.type, size: Int(k.size))
    }

    /// 原始位元組（只取 k.size 個），給位元序不照慣例的鍵自己解
    func readBytes(_ k: Key) -> [UInt8]? {
        guard let out = readBlock(k) else { return nil }
        return withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(min(k.size, 32)))) }
    }

    private func readBlock(_ k: Key) -> ParamBlock? {
        var input = ParamBlock()
        input.key = k.code
        input.dataSize = k.size
        input.data8 = Command.readBytes
        return call(&input)
    }

    private func call(_ input: inout ParamBlock) -> ParamBlock? {
        var output = ParamBlock()
        var outSize = MemoryLayout<ParamBlock>.stride
        let r = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<ParamBlock>.stride, &output, &outSize)
        // result 非 0 是 SMC 自己的錯誤碼（例如 0x84＝鍵不存在）
        guard r == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    // MARK: 解碼

    private static func decode(_ raw: Bytes32, type: UInt32, size: Int) -> Double? {
        var b = raw
        return withUnsafeBytes(of: &b) { p -> Double? in
            let u = p.bindMemory(to: UInt8.self)
            func be16() -> UInt16 { UInt16(u[0]) << 8 | UInt16(u[1]) }
            switch type {
            case fourCC("flt "):
                // Apple Silicon 的 flt 是本機位元序（小端），其他型別都是大端
                guard size >= 4 else { return nil }
                let v = Double(p.loadUnaligned(as: Float.self))
                return v.isFinite ? v : nil
            case fourCC("ui8 "): return size >= 1 ? Double(u[0]) : nil
            case fourCC("ui16"): return size >= 2 ? Double(be16()) : nil
            case fourCC("ui32"):
                guard size >= 4 else { return nil }
                return Double(UInt32(u[0]) << 24 | UInt32(u[1]) << 16 | UInt32(u[2]) << 8 | UInt32(u[3]))
            case fourCC("si8 "): return size >= 1 ? Double(Int8(bitPattern: u[0])) : nil
            case fourCC("si16"): return size >= 2 ? Double(Int16(bitPattern: be16())) : nil
            default:
                // fpXY／spXY：16 位元大端定點數，最後一碼（十六進位）是小數位數，例如 sp78＝÷256、fpe2＝÷4
                let c = withUnsafeBytes(of: type.bigEndian) { Array($0) }
                guard size >= 2, c[1] == UInt8(ascii: "p"), c[0] == UInt8(ascii: "f") || c[0] == UInt8(ascii: "s"),
                      let frac = Int(String(UnicodeScalar(c[3])), radix: 16) else { return nil }
                let raw = be16()
                let v = c[0] == UInt8(ascii: "s") ? Double(Int16(bitPattern: raw)) : Double(raw)
                return v / Double(1 << frac)
            }
        }
    }

    static func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func string(_ code: UInt32) -> String {
        String(decoding: withUnsafeBytes(of: code.bigEndian) { Array($0) }, as: UTF8.self)
    }

    // MARK: 核心介面的結構

    private enum Command {
        static let readBytes: UInt8 = 5
        static let readIndex: UInt8 = 8
        static let readKeyInfo: UInt8 = 9
    }

    typealias Bytes32 = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                         UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                         UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                         UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    /// C 的 SMCKeyData_t（80 位元組）攤平寫：巢狀 struct 在 Swift 不補尾端對齊，攤平才保證每欄偏移跟 C 一樣
    private struct ParamBlock {
        var key: UInt32 = 0                                         // 0
        var vers: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)  // 4（major、minor、build、reserved、release）
        var pLimit: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)  // 12
        var dataSize: UInt32 = 0                                    // 28 keyInfo.dataSize
        var dataType: UInt32 = 0                                    // 32 keyInfo.dataType
        var dataAttributes: UInt8 = 0                               // 36 keyInfo.dataAttributes
        var pad: (UInt8, UInt8, UInt8) = (0, 0, 0)                  // 37 keyInfo 尾端補齊
        var result: UInt8 = 0                                       // 40
        var status: UInt8 = 0                                       // 41
        var data8: UInt8 = 0                                        // 42
        var data32: UInt32 = 0                                      // 44
        var bytes: Bytes32 = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                              0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)  // 48
    }
}
