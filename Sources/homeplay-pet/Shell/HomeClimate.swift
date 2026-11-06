// 家庭 App 的溫控頁（純邏輯，--selftest 直接驗）：模式（關／暖／冷／自動）有哪些、現在選哪個、切換要寫哪些特性；
// 旋鈕的幾何（角度 ↔ 溫度，0.5 度一格或照配件的步進）。
// 溫控（Thermostat）的目標模式：0 關、1 暖、2 冷、3 自動；冷暖氣（HeaterCooler）是「開關（Active）＋目標狀態（0 自動、1 暖、2 冷）」。
// 配件只支援其中幾種：幫手有送有效值（valid）就照它，否則照 min…max；都沒有就用 HomeKit 的完整範圍。

import Foundation

enum HomeClimateMode: Int, CaseIterable, Equatable { case off, heat, cool, auto }

struct HomeClimateModes: Equatable {
    var options: [HomeClimateMode]      // 照「關、暖、冷、自動」的順序
    var selected: HomeClimateMode?
}

enum HomeClimate {
    /// 配件允許的原始值：有效值 → min…max → 預設範圍
    static func allowed(_ c: HomeCharacteristic, default range: ClosedRange<Int>) -> Set<Int> {
        if let v = c.valid, !v.isEmpty { return Set(v.map { Int($0.rounded()) }) }
        let lo = c.min.map { Int($0.rounded()) } ?? range.lowerBound, hi = c.max.map { Int($0.rounded()) } ?? range.upperBound
        return lo <= hi ? Set(lo...hi) : Set(range)
    }

    /// 冷暖氣的目標狀態 ↔ 模式
    private static let hcRaw: [HomeClimateMode: Int] = [.auto: 0, .heat: 1, .cool: 2]

    static func modes(_ a: HomeAccessory) -> HomeClimateModes {
        if let tm = a.characteristic("targetMode"), tm.writable {
            let ok = allowed(tm, default: 0...3)
            let opts = HomeClimateMode.allCases.filter { ok.contains($0.rawValue) }
            let sel = tm.value?.number.flatMap { HomeClimateMode(rawValue: Int($0.rounded())) }
            return HomeClimateModes(options: opts.count >= 2 ? opts : [], selected: sel)
        }
        let act = a.characteristic("active"), hc = a.characteristic("targetHCState")
        guard act?.writable == true || hc?.writable == true else { return HomeClimateModes(options: [], selected: nil) }
        var opts: [HomeClimateMode] = act?.writable == true ? [.off] : []
        if let hc, hc.writable {
            let ok = allowed(hc, default: 0...2)
            opts += [HomeClimateMode.heat, .cool, .auto].filter { ok.contains(hcRaw[$0]!) }
        }
        let on = act?.value?.isOn ?? true
        let raw = hc?.value?.number.map { Int($0.rounded()) }
        let sel: HomeClimateMode? = !on ? .off : raw.flatMap { r in hcRaw.first { $0.value == r }?.key }
        return HomeClimateModes(options: opts.count >= 2 ? opts : [], selected: sel)
    }

    /// 切到 m 要寫哪些特性（照順序寫）
    static func writes(_ a: HomeAccessory, _ m: HomeClimateMode) -> [(id: String, value: HomeValue, type: String)] {
        if let tm = a.characteristic("targetMode"), tm.writable {
            return [(tm.id, HomeValue(number: Double(m.rawValue)), "targetMode")]
        }
        var out: [(id: String, value: HomeValue, type: String)] = []
        let act = a.characteristic("active")
        if m == .off {
            if let act, act.writable, act.value?.isOn ?? true { out.append((act.id, HomeValue(number: 0), "active")) }
            return out
        }
        if let act, act.writable, !(act.value?.isOn ?? false) { out.append((act.id, HomeValue(number: 1), "active")) }
        if let hc = a.characteristic("targetHCState"), hc.writable, let r = hcRaw[m] { out.append((hc.id, HomeValue(number: Double(r)), "targetHCState")) }
        return out
    }

    // MARK: 旋鈕（1024 畫布）

    /// 旋鈕：圓心、半徑；弧從左下 135° 順時針掃 270° 到右下（螢幕座標，y 往下，0° 在右邊）
    static let center = CGPoint(x: 512, y: 480)
    static let radius: CGFloat = 248
    static let startDeg: CGFloat = 135, sweepDeg: CGFloat = 270

    /// 溫度 → 0…1 的位置
    static func fraction(_ v: Double, min lo: Double, max hi: Double) -> CGFloat {
        guard hi > lo else { return 0 }
        return CGFloat(Swift.max(0, Swift.min(1, (v - lo) / (hi - lo))))
    }
    /// 0…1 → 弧上的點
    static func point(_ f: CGFloat, r: CGFloat = radius) -> CGPoint {
        let a = (startDeg + sweepDeg * f) * .pi / 180
        return CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
    }
    /// 點在弧上（離弧 ±56 以內、不在底下的缺口）→ 該處的溫度（照步進對齊）；不在弧上回 nil
    static func value(at p: CGPoint, min lo: Double, max hi: Double, step: Double) -> Double? {
        let dx = p.x - center.x, dy = p.y - center.y
        guard abs(hypot(dx, dy) - radius) <= 56 else { return nil }
        var deg = atan2(dy, dx) * 180 / .pi           // -180…180
        if deg < 0 { deg += 360 }                     // 0…360
        var rel = deg - startDeg
        if rel < 0 { rel += 360 }
        guard rel <= sweepDeg + 8 else { return nil }  // 缺口（容許弧的兩端多 8°）
        let f = Double(Swift.min(sweepDeg, rel) / sweepDeg)
        let st = Swift.max(0.5, step)
        let v = lo + f * (hi - lo)
        return Swift.max(lo, Swift.min(hi, (v / st).rounded() * st))
    }
}

enum HomeClimateSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        func ch(_ id: String, _ type: String, _ v: Double?, w: Bool = true, min: Double? = nil, max: Double? = nil, valid: [Double]? = nil) -> HomeCharacteristic {
            var c = HomeCharacteristic(id: id, type: type, value: v.map { HomeValue(number: $0) }, writable: w, units: nil, min: min, max: max, step: nil)
            c.valid = valid; return c
        }
        func acc(_ cs: [HomeCharacteristic]) -> HomeAccessory {
            HomeAccessory(id: "a", name: "a", home: "h", room: "r", category: "c", categoryName: "Thermostat", reachable: true, characteristics: cs, camera: nil)
        }
        let thermo = acc([ch("t", "targetTemp", 22), ch("m", "targetMode", 1, min: 0, max: 3)])
        let m = HomeClimate.modes(thermo)
        check(m.options == [.off, .heat, .cool, .auto] && m.selected == .heat, "溫控：四種模式、目前暖")
        check(HomeClimate.writes(thermo, .auto).map(\.id) == ["m"] && HomeClimate.writes(thermo, .auto)[0].value.number == 3, "溫控：切自動寫目標模式 3")
        let heatOnly = acc([ch("m", "targetMode", 0, valid: [0, 1])])
        check(HomeClimate.modes(heatOnly).options == [.off, .heat], "溫控：照有效值只給關與暖")
        check(HomeClimate.modes(acc([ch("m", "targetMode", 1, w: false)])).options.isEmpty, "溫控：模式不能寫就不給選")
        let hc = acc([ch("a", "active", 0), ch("s", "targetHCState", 2, min: 0, max: 2), ch("ct", "coolingThreshold", 25)])
        let hm = HomeClimate.modes(hc)
        check(hm.options == [.off, .heat, .cool, .auto] && hm.selected == .off, "冷暖氣：關著＝選「關」")
        let w = HomeClimate.writes(hc, .heat)
        check(w.map(\.id) == ["a", "s"] && w[0].value.number == 1 && w[1].value.number == 1, "冷暖氣：關著切暖＝先開再設暖")
        check(HomeClimate.writes(hc, .off).isEmpty, "冷暖氣：已經關著再按關不寫")
        var on = hc; on.characteristics[0].value = HomeValue(number: 1)
        check(HomeClimate.modes(on).selected == .cool && HomeClimate.writes(on, .off).map(\.id) == ["a"] && HomeClimate.writes(on, .auto).map(\.id) == ["s"], "冷暖氣：開著製冷、關＝只寫開關、自動＝只寫目標狀態")
        check(HomeClimate.modes(acc([ch("a", "active", 1), ch("s", "targetHCState", 2, valid: [2])])).options == [.off, .cool], "冷暖氣：只能製冷的冷氣＝關與冷")
        // 旋鈕：弧的兩端與中點、缺口、0.5 一格
        let top = CGPoint(x: HomeClimate.center.x, y: HomeClimate.center.y - HomeClimate.radius)
        check(HomeClimate.value(at: top, min: 10, max: 30, step: 0.5) == 20, "溫控旋鈕：正上方＝中間的溫度")
        check(HomeClimate.value(at: HomeClimate.point(0), min: 10, max: 30, step: 0.5) == 10 && HomeClimate.value(at: HomeClimate.point(1), min: 10, max: 30, step: 0.5) == 30, "溫控旋鈕：弧的兩端＝最低、最高")
        check(HomeClimate.value(at: CGPoint(x: HomeClimate.center.x, y: HomeClimate.center.y + HomeClimate.radius), min: 10, max: 30, step: 0.5) == nil, "溫控旋鈕：底下的缺口不算")
        check(HomeClimate.value(at: HomeClimate.center, min: 10, max: 30, step: 0.5) == nil, "溫控旋鈕：點中間的數字不改溫度")
        let v = HomeClimate.value(at: HomeClimate.point(0.33), min: 16, max: 30, step: 0.5)!
        check(v.truncatingRemainder(dividingBy: 0.5) == 0 && abs(v - (16 + 0.33 * 14)) <= 0.25, "溫控旋鈕：對齊 0.5 度")
        check(HomeClimate.value(at: HomeClimate.point(0.5), min: 16, max: 30, step: 1)! == 23, "溫控旋鈕：配件步進 1 度就照 1 度")
        check(abs(HomeClimate.fraction(24, min: 16, max: 32) - 0.5) < 1e-9 && HomeClimate.fraction(40, min: 16, max: 32) == 1, "溫控旋鈕：溫度 → 位置")
    }
}
