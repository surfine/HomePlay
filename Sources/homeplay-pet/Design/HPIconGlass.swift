// 體驗追趕 P0：圖示玻璃。主畫面外觀是「透明」「著色」時，App 圖示的底走 HPGlass 管線（Clear 玻璃，一頁一次合成、快取），
// 上面的主體（glyph）是 HomeIconVariant 推出的實色版，保證讀得到。
//
// - 深淺兩套參數：跟外觀走（淺色＝玻璃上蓋薄白、深色＝蓋薄黑）；增加對比時兩套都往暗推、主體不透明，主體對比只升不降。
// - 融合：相鄰圖示的外框間距小於 `groupingGap` 的算一組，同一組的底融成一塊（smooth union）；主畫面網格的間距遠大於它，
//   只有擠在一起的排法（例如托盤）才會融。
// - 純函式（selftest 直接驗）：`params`、`groups`、`glyphContrast`。

import AppKit

enum HPIconGlass {
    enum Style: Equatable { case light, dark }

    struct Params: Equatable {
        /// 玻璃面上再蓋的一層（灰階 0…1＋不透明度）：淺色提亮、深色壓暗
        let baseGray: CGFloat
        let baseAlpha: CGFloat
        /// 主體不透明度（HomeIconVariant 清透版的主體）
        let glyphAlpha: CGFloat
    }

    /// 外觀 → 玻璃樣式
    static func style(dark: Bool) -> Style { dark ? .dark : .light }

    static func params(_ s: Style, increaseContrast ic: Bool) -> Params {
        switch (s, ic) {   // 數值在材質表（HPMaterial.IconGlass）
        case (.light, false): return HPMaterial.IconGlass.light
        case (.dark, false):  return HPMaterial.IconGlass.dark
        case (.light, true):  return HPMaterial.IconGlass.lightIncreaseContrast
        case (.dark, true):   return HPMaterial.IconGlass.darkIncreaseContrast
        }
    }

    static var current: Params { params(style(dark: HPTokens.dark), increaseContrast: HPAccessibility.increaseContrast) }

    /// 這個外觀要不要走玻璃圖示（減少透明度時退回原本的平面變體）
    static var enabled: Bool { HomeAppearance.current.glassBase && !HPGlass.reduceTransparency }

    /// 相鄰外框距離小於它就融合（常數門檻，見 HVTruth.IconGlass）
    static var groupingGap: CGFloat { HVTruth.IconGlass.groupingGap }

    /// 融合分組：外框距離 < gap 的兩個連在一起（可傳遞）；回傳每組的索引（照最小索引排序）
    static func groups(_ rects: [CGRect], gap: CGFloat = groupingGap) -> [[Int]] {
        var parent = Array(rects.indices)
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for i in rects.indices {
            for j in rects.indices where j > i {
                let a = rects[i], b = rects[j]
                let dx = max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX)), dy = max(0, max(a.minY, b.minY) - min(a.maxY, b.maxY))
                if hypot(dx, dy) < gap { parent[find(j)] = find(i) }
            }
        }
        var out: [Int: [Int]] = [:]
        for i in rects.indices { out[find(i), default: []].append(i) }
        return out.values.sorted { $0[0] < $1[0] }
    }

    /// 白色主體在玻璃底上的 WCAG 對比（模型）：背後亮度（sRGB 0…1）→ 蓋上 base → 主體以 glyphAlpha 疊上去
    static func glyphContrast(_ p: Params, backdropLuma l: CGFloat) -> Double {
        func lin(_ v: CGFloat) -> Double { let x = Double(max(0, min(1, v))); return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        let a = Double(p.baseAlpha), ga = Double(p.glyphAlpha)
        let under = lin(l) * (1 - a) + lin(p.baseGray) * a
        let glyph = 1 * ga + under * (1 - ga)
        return (glyph + 0.05) / (under + 0.05)
    }

    /// 把一頁的圖示底收進 HPGlass（呼叫端接著 flush）。tint：著色外觀的色（nil＝清玻璃）
    static func addBases(_ icons: [CGRect], tint: NSColor?) {
        for (gi, grp) in groups(icons).enumerated() {
            let union: String? = grp.count > 1 ? "icon.glass.\(gi)" : nil
            for i in grp {
                let r = icons[i]
                HPGlass.add(continuousRoundedRect(r, radius: r.width * 0.2237), tint: tint, interactive: false, union: union) { _ in }
            }
        }
    }

    /// flush 之後：每個底蓋上這一套參數的薄層
    static func shade(_ g: CGContext, _ icons: [CGRect], _ p: Params = current) {
        g.saveGState()
        g.setFillColor(NSColor(white: p.baseGray, alpha: p.baseAlpha).cgColor)
        for r in icons { g.addPath(continuousRoundedRect(r, radius: r.width * 0.2237)) }
        g.fillPath()
        g.restoreGState()
    }
}

enum HPIconGlassSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        let l = HPIconGlass.params(.light, increaseContrast: false), d = HPIconGlass.params(.dark, increaseContrast: false)
        let li = HPIconGlass.params(.light, increaseContrast: true), di = HPIconGlass.params(.dark, increaseContrast: true)
        check(l != d && l != li && d != di, "圖示玻璃：深淺兩套參數不同、增加對比又各不同")   // l10n-ignore
        let lumas: [CGFloat] = stride(from: 0, through: 1, by: 0.05).map { CGFloat($0) }
        check(lumas.allSatisfy { HPIconGlass.glyphContrast(li, backdropLuma: $0) >= HPIconGlass.glyphContrast(l, backdropLuma: $0) - 1e-9 }
              && lumas.allSatisfy { HPIconGlass.glyphContrast(di, backdropLuma: $0) >= HPIconGlass.glyphContrast(d, backdropLuma: $0) - 1e-9 },
              "圖示玻璃：增加對比時主體對比在任何背後亮度都不降")   // l10n-ignore
        // 主畫面桌布平均亮度鉗在 HPTokens.Home.wallpaperMaxLum：在那之下兩套都要過 UI 元件的 3:1
        let maxL = HPTokens.Home.wallpaperMaxLum
        check(HPIconGlass.glyphContrast(l, backdropLuma: maxL) >= 3 && HPIconGlass.glyphContrast(d, backdropLuma: maxL) >= 3,
              "圖示玻璃：主畫面桌布最亮時主體仍 ≥ 3:1")   // l10n-ignore
        let s: CGFloat = 152
        let row = (0..<3).map { CGRect(x: CGFloat($0) * (s + 10), y: 0, width: s, height: s) }   // 間距 10：連成一組（可傳遞）
        let grid = (0..<3).map { CGRect(x: CGFloat($0) * (s + 73), y: 0, width: s, height: s) }  // 主畫面網格間距 73：各自一組
        check(HPIconGlass.groups(row) == [[0, 1, 2]] && HPIconGlass.groups(grid) == [[0], [1], [2]]
              && HPIconGlass.groups([row[0], row[1], grid[2]]) == [[0, 1], [2]] && HPIconGlass.groups([]).isEmpty,
              "圖示玻璃：融合判定照外框間距、可傳遞")   // l10n-ignore
    }
}
