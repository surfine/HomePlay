// 第四輪（使用者決定 #12）：Home Modular 的桌布——程式生成的硬邊幾何花紋（自己畫，不用官方桌布）。
// 兩種語彙疊在一起：左下角放射出來的「扇形」一圈圈色塊，加上斜著折起來的「稜柱帶」（一條帶子沿長邊折成亮面＋暗面，交叉處有落影三角）。
// 全部是平塗、硬邊，玻璃磚折射時直線會在磚的斜邊上彎，看得出來是玻璃。四種顏色：綠、紫、藍、琥珀。
// 選色：UserDefaults「homeModular.color」（green／purple／blue／amber，預設紫）；快照 --homemod-color <名字>。

import AppKit

enum HomeModularWallpaper {
    enum Tint: String, CaseIterable { case green, purple, blue, amber }

    /// 五階：最深、深、中、亮、最亮（同一個色相，硬邊平塗用）
    static func palette(_ t: Tint) -> [UInt32] {
        switch t {
        case .purple: return [0x231A8A, 0x3428B8, 0x4D41DA, 0x7A6EF2, 0xAEA6FF]
        case .blue: return [0x0B2470, 0x16379C, 0x2558CC, 0x4F86EE, 0x93BBFF]
        case .green: return [0x07402E, 0x0F6243, 0x1A8A5C, 0x3DB583, 0x92DDB8]
        case .amber: return [0x5E2804, 0x8C420A, 0xBE680E, 0xEB982C, 0xFFCF78]
        }
    }

    static var current: Tint {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--homemod-color"), i + 1 < a.count, let t = Tint(rawValue: a[i + 1]) { return t }
        return UserDefaults.standard.string(forKey: "homeModular.color").flatMap(Tint.init(rawValue:)) ?? .purple
    }

    /// 畫滿 1024² 畫布（左上原點）
    static func draw(_ g: CGContext, _ t: Tint) {
        let pal = palette(t).map { srgb($0) }
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        g.saveGState()
        g.setFillColor(pal[1].cgColor); g.fill(full)

        // 1. 扇形：圓心在左下角外面，一圈圈的環再切成角度不同的扇塊，深淺交錯
        let fc = CGPoint(x: -140, y: 1180)
        let rings: [CGFloat] = [1620, 1330, 1080, 840, 600, 380]
        for (ri, outer) in rings.enumerated() {
            let inner = ri + 1 < rings.count ? rings[ri + 1] : 0
            // 每圈的切角稍微錯開，看起來像疊起來的扇子
            let cuts: [CGFloat] = [-1.62, -1.18 + CGFloat(ri) * 0.07, -0.74 + CGFloat(ri) * 0.05, -0.36 - CGFloat(ri) * 0.04, 0.05]
            for k in 0..<(cuts.count - 1) {
                let p = CGMutablePath()
                p.addArc(center: fc, radius: outer, startAngle: cuts[k], endAngle: cuts[k + 1], clockwise: false)
                p.addArc(center: fc, radius: inner, startAngle: cuts[k + 1], endAngle: cuts[k], clockwise: true)
                p.closeSubpath()
                let shade = [1, 2, 0, 2, 3, 1, 2, 4][(ri * 3 + k) % 8]
                g.addPath(p); g.setFillColor(pal[shade].cgColor); g.fillPath()
            }
        }

        // 2. 稜柱帶：沿長邊折成兩個面（亮面在上、暗面在下），先畫 52° 的、再畫 -38° 的壓在上面
        func band(_ c: CGPoint, angle: CGFloat, length: CGFloat, width: CGFloat, light: Int, dark: Int) {
            let ux = cos(angle), uy = sin(angle), nx = -uy, ny = ux
            func pt(_ a: CGFloat, _ b: CGFloat) -> CGPoint { CGPoint(x: c.x + ux * a + nx * b, y: c.y + uy * a + ny * b) }
            let h = length / 2, w = width / 2
            // 兩端斜切（硬邊的三角收尾）
            let top = CGMutablePath()
            top.move(to: pt(-h, 0)); top.addLine(to: pt(-h + w, -w)); top.addLine(to: pt(h, -w)); top.addLine(to: pt(h - w, 0)); top.closeSubpath()
            let bottom = CGMutablePath()
            bottom.move(to: pt(-h, 0)); bottom.addLine(to: pt(h - w, 0)); bottom.addLine(to: pt(h - w * 2, w)); bottom.addLine(to: pt(-h + w * 0.2, w)); bottom.closeSubpath()
            // 落影：帶子往右下錯開一點的深色（硬邊，不模糊）
            let shadow = CGMutablePath(); shadow.addPath(top); shadow.addPath(bottom)
            var off = CGAffineTransform(translationX: 18, y: 26)
            g.addPath(shadow.copy(using: &off) ?? shadow); g.setFillColor(pal[0].withAlphaComponent(0.85).cgColor); g.fillPath()
            g.addPath(top); g.setFillColor(pal[light].cgColor); g.fillPath()
            g.addPath(bottom); g.setFillColor(pal[dark].cgColor); g.fillPath()
        }
        let a1 = 52 * CGFloat.pi / 180, a2 = -38 * CGFloat.pi / 180
        band(CGPoint(x: 250, y: 300), angle: a1, length: 1100, width: 170, light: 3, dark: 2)
        band(CGPoint(x: 820, y: 560), angle: a1, length: 1000, width: 150, light: 2, dark: 1)
        band(CGPoint(x: 420, y: 520), angle: a2, length: 1500, width: 210, light: 4, dark: 2)
        band(CGPoint(x: 700, y: 140), angle: a2, length: 1100, width: 130, light: 3, dark: 1)
        band(CGPoint(x: 560, y: 930), angle: a2, length: 1300, width: 160, light: 3, dark: 2)

        // 3. 幾片大三角（最亮、最深各一）：讓磚邊的折射在大面積上也看得到
        func tri(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ i: Int, _ alpha: CGFloat = 1) {
            g.move(to: a); g.addLine(to: b); g.addLine(to: c); g.closePath()
            g.setFillColor(pal[i].withAlphaComponent(alpha).cgColor); g.fillPath()
        }
        tri(CGPoint(x: 1024, y: 0), CGPoint(x: 1024, y: 360), CGPoint(x: 760, y: 0), 4, 0.9)
        tri(CGPoint(x: 0, y: 0), CGPoint(x: 330, y: 0), CGPoint(x: 0, y: 250), 0)
        tri(CGPoint(x: 1024, y: 1024), CGPoint(x: 700, y: 1024), CGPoint(x: 1024, y: 760), 0, 0.9)
        g.restoreGState()
    }
}
