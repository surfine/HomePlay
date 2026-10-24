// 膠囊（島身）的材質：依錶面年代自動挑，或在設定 › 外觀固定（稿：docs/design-drafts/faces-v3/artifact）。
// 👀 一律照 Apple Color Emoji 畫（drawEye），只換膠囊：
//   純黑＝2022 Dynamic Island；玻璃＝2025 Liquid Glass；黑透漸層＝2026 iOS 27；1988／2002 年代的島錶面沿用自己的島身。
// Siri（按住 F5）：照 iOS 27 的 Siri 球——深色液態玻璃從島往下長出來、輕輕脈動、裡面一道跟著聲音的彩色波形；
// 放開後縮成小球轉圈（思考中），再彈回原本的膠囊。

import AppKit

enum CapsuleMaterial: String, CaseIterable {
    case auto, black, smoke, glass
    static let defaultsKey = "HomePlayCapsule"
    var title: String {
        switch self {
        case .auto: return L("capsule.auto", "自动")
        case .black: return L("capsule.black", "纯黑")
        case .smoke: return L("capsule.smoke", "黑透渐层")
        case .glass: return L("capsule.glass", "玻璃")
        }
    }
}

/// 設定值（設定視窗改了就寫這裡，錶面每幀讀）
nonisolated(unsafe) var capsuleMaterialSetting: CapsuleMaterial =
    CapsuleMaterial(rawValue: UserDefaults.standard.string(forKey: CapsuleMaterial.defaultsKey) ?? "") ?? .auto

/// Siri 球的狀態：F5 按下／放開的時刻（PetView.siriKey 寫，錶面讀）
struct SiriOrbState {
    var downAt: Double = -1, upAt: Double = -1
    static let rise = 0.36, think = 1.6, settle = 0.42
    /// 快照用：固定在 listen／think
    nonisolated(unsafe) static var snapshotPhase: String?
    var listening: Bool { downAt >= 0 && upAt < downAt }
    /// 這一刻要不要畫（含收尾動畫）
    func active(_ now: Double) -> Bool { Self.snapshotPhase != nil || listening || (upAt >= 0 && now - upAt < Self.think + Self.settle) }
}
nonisolated(unsafe) var siriOrb = SiriOrbState()

enum CapsuleLook { case black, smoke, glass, system }

/// 隨包字體（Resources/Fonts）：ChicagoFLF——Robin Casady 重做的 Chicago，作者聲明為公有領域（字檔 license 欄）。
/// 只註冊給這個行程；第一次要用 1988 字體時才做。
let bundledFontsRegistered: Bool = {
    let name = "HomePlay_homeplay-pet.bundle"
    let bundles = [Bundle.main.resourceURL?.appendingPathComponent(name),
                   Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent(name)]
        .compactMap { $0 }.compactMap(Bundle.init(url:))
    var ok = false
    for b in bundles {
        for url in [b.url(forResource: "ChicagoFLF", withExtension: "ttf"), b.url(forResource: "ChicagoFLF", withExtension: "ttf", subdirectory: "Fonts")].compactMap({ $0 }) {
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) { ok = true }
        }
        if ok { break }
    }
    return ok
}()

extension Face {
    /// 這個錶面、這個年代該用哪種膠囊
    func capsuleLook() -> CapsuleLook {
        if style == .island && era != .y2026 { return .system }   // 1988／2002 的島身各有各的樣子（IslandOptions）
        if [.system6, .alarmClock, .about].contains(style) { return .system }   // System 6 系列：1-bit 預設按鈕
        switch capsuleMaterialSetting {
        case .black: return .black
        case .smoke: return .smoke
        case .glass: return .glass
        case .auto:
            switch style {
            case .analog where typographMaterial == .embossed: return .glass   // 浮雕材質：粉色底上的玻璃膠囊
            case .modular, .analog, .pocket, .black: return .black   // 平面、Dynamic Island 年代的版式；OLED 全黑
            case .growth, .calendar: return .smoke                     // 2026 iOS 27
            default: return .glass                                // HomeView 本身是 Liquid Glass 年代
            }
        }
    }

    // MARK: 島身

    /// 畫膠囊本體（不含眼睛）。animating：位置或大小正在變（玻璃那種貴的版本就先用便宜的）
    func drawCapsuleBody(_ g: CGContext, _ rect: CGRect, look: CapsuleLook, animating: Bool) {
        let path = CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
        switch look {
        case .system:
            if !drawOptionIslandBody(g, rect) { glass(g, rect, radius: rect.height / 2, tint: NSColor(white: 0, alpha: 0.74), band: 20) }
        case .black:
            g.addPath(path); g.setFillColor(NSColor.black.cgColor); g.fillPath()
        case .smoke:
            smokePill(g, rect)
        case .glass:
            if animating || !glassPill(g, rect) {
                glass(g, rect, radius: rect.height / 2, tint: NSColor(white: 1, alpha: 0.08), band: max(8, rect.height * 0.14))
            }
        }
    }

    /// 黑透漸層（iOS 27）：背後霜化並壓暗，中間實黑、兩端透；頂部一道內光、細邊
    func smokePill(_ g: CGContext, _ r: CGRect, darkness: CGFloat = 1) {
        let rad = r.height / 2, path = CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: r.height * 0.08), blur: r.height * 0.22, color: NSColor(white: 0, alpha: 0.28).cgColor)
        g.addPath(path); g.setFillColor(NSColor(white: 0, alpha: 0.35).cgColor); g.fillPath()
        g.restoreGState()
        g.saveGState(); g.addPath(path); g.clip()
        if let frosted { lens(g, frosted, around: CGPoint(x: r.midX, y: r.midY), 1.04) }
        g.setFillColor(NSColor(white: 0, alpha: 0.38 * darkness).cgColor); g.fill(r)
        let a = 0.86 * darkness, e = 0.10 * darkness
        let side = CGGradient(colorsSpace: cs, colors: [NSColor(white: 0, alpha: e).cgColor, NSColor(white: 0, alpha: a).cgColor,
                                                        NSColor(white: 0, alpha: a).cgColor, NSColor(white: 0, alpha: e).cgColor] as CFArray,
                              locations: [0, 0.26, 0.74, 1])!
        g.drawLinearGradient(side, start: CGPoint(x: r.minX, y: 0), end: CGPoint(x: r.maxX, y: 0), options: [])
        let glow = CGGradient(colorsSpace: cs, colors: [NSColor(white: 1, alpha: 0.12).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(glow, start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.minY + r.height * 0.4), options: [])
        g.restoreGState()
        g.saveGState()
        g.addPath(path); g.setLineWidth(max(2, r.height * 0.025)); g.replacePathWithStrokedPath(); g.clip()
        let rim = CGGradient(colorsSpace: cs, colors: [NSColor(white: 1, alpha: 0.42).cgColor, NSColor(white: 1, alpha: 0.04).cgColor,
                                                       NSColor(white: 1, alpha: 0.04).cgColor, NSColor(white: 1, alpha: 0.22).cgColor] as CFArray,
                             locations: [0, 0.35, 0.65, 1])!
        g.drawLinearGradient(rim, start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
        g.restoreGState()
    }

    /// 玻璃（Liquid Glass）：系統的玻璃零件，背景是這一刻已經畫好的錶面；位置與分鐘不變就用快取
    func glassPill(_ g: CGContext, _ r: CGRect) -> Bool {
        guard let backdrop = g.makeImage() else { return false }
        let ri = r.integral, sc = renderPixelScale
        let key = "\(style.rawValue)|\(Int(ri.minX)),\(Int(ri.minY)),\(Int(ri.width)),\(Int(ri.height))|\(Int(sc * 100))|\(Int(Date().timeIntervalSince1970 / 60))"
        let path = CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
        if let hit = Self.pillCache, hit.key == key {
            drawPillImage(g, hit.image, hit.rect, path); return true
        }
        var p = SystemGlassParams.portrait
        p.refractionAmount = -2.4; p.blurRadius = 9; p.highlight = 0.55; p.fill = 0.12; p.ringShadow = 0.3
        guard let out = SystemGlass.shared.render(path: path, key: "pill|\(key)", scale: sc, backdrop: backdrop, params: p) else { return false }
        Self.pillCache = (key, out.image, out.rect)
        drawPillImage(g, out.image, out.rect, path)
        return true
    }
    private func drawPillImage(_ g: CGContext, _ img: CGImage, _ rect: CGRect, _ path: CGPath) {
        g.saveGState()   // 外面一圈柔和接觸陰影：玻璃浮在錶面上
        g.addRect(CGRect(x: -100, y: -100, width: 1224, height: 1224)); g.addPath(path); g.clip(using: .evenOdd)
        let h = path.boundingBoxOfPath.height
        g.setShadow(offset: CGSize(width: 0, height: h * 0.06), blur: h * 0.16, color: NSColor(white: 0, alpha: 0.22).cgColor)
        g.addPath(path); g.setFillColor(NSColor(white: 0, alpha: 0.4).cgColor); g.fillPath()
        g.restoreGState()
        g.saveGState(); g.addPath(path); g.clip(); drawUpright(g, img, in: rect); g.restoreGState()
    }
    nonisolated(unsafe) private static var pillCache: (key: String, image: CGImage, rect: CGRect)?

    // MARK: Siri 球

    /// Siri 球的外形：回傳要畫的矩形與這一刻的階段參數。base 是平常的膠囊。
    func siriOrbGeometry(_ base: CGRect, now: Double) -> (rect: CGRect, listen: CGFloat, think: CGFloat, spin: Double)? {
        let s = siriOrb
        guard s.active(now) else { return nil }
        func spring(_ t: Double, _ d: Double) -> CGFloat {   // 臨界阻尼彈簧的近似（無回彈）
            let x = max(0, min(1, t / d)); return CGFloat(1 - pow(1 - x, 3))
        }
        var listen: CGFloat = 0, think: CGFloat = 0
        if let ph = SiriOrbState.snapshotPhase { if ph == "think" { think = 1 } else { listen = 1 } }
        else if s.listening { listen = spring(now - s.downAt, SiriOrbState.rise) }
        else {
            let t = now - s.upAt
            if t < SiriOrbState.think { listen = 1 - spring(t, 0.22); think = spring(t, 0.28) }
            else { think = 1 - spring(t - SiriOrbState.think, SiriOrbState.settle) }
        }
        let pulse = s.listening ? CGFloat(1 + 0.025 * sin((now - s.downAt) * 2 * .pi * 1.3)) : 1
        // 聆聽：往下長 0.28h、變寬 12%、變高 20%；思考：縮成直徑 0.9h 的球
        var w = base.width * (1 + 0.12 * listen), h = base.height * (1 + 0.46 * listen)
        w += (base.height * 0.9 - w) * think; h += (base.height * 0.9 - h) * think
        w *= pulse; h *= pulse
        let c = CGPoint(x: base.midX, y: base.midY + base.height * 0.28 * listen)
        return (CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h), listen, think, now - s.upAt)
    }

    /// 深色液態玻璃球身 + 聆聽時的彩色波形 + 思考時的轉圈
    func drawSiriOrb(_ g: CGContext, _ r: CGRect, listen: CGFloat, think: CGFloat, now: Double) {
        smokePill(g, r, darkness: 1.08)
        let path = CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
        if listen > 0.01 {
            g.saveGState(); g.addPath(path); g.clip()
            g.setAlpha(listen); g.setBlendMode(.plusLighter)
            // 四道彩帶：橙、粉、紫、藍，振幅跟著一段假的「語音包絡」走（接收器還沒回傳麥克風音量）
            let colors: [NSColor] = [srgb(0xff9b3d), srgb(0xff4fa6), srgb(0x9b5cff), srgb(0x3d9bff)]
            let t = now - siriOrb.downAt
            let env = 0.45 + 0.35 * abs(sin(t * 3.1)) * (0.6 + 0.4 * sin(t * 7.3 + 1))
            let midY = r.midY + r.height * 0.27, amp = r.height * 0.10 * CGFloat(env)
            for (i, col) in colors.enumerated() {
                let ph = Double(i) * 1.7, fq = 1.6 + Double(i) * 0.35
                let wave = CGMutablePath()
                let x0 = r.minX + r.height * 0.3, x1 = r.maxX - r.height * 0.3
                var x = x0
                while x <= x1 {
                    let u = Double((x - x0) / (x1 - x0))
                    let taper = CGFloat(sin(u * .pi))   // 兩端收細
                    let y = midY + amp * taper * CGFloat(sin(u * .pi * 2 * fq + t * 4.2 + ph))
                    if x == x0 { wave.move(to: CGPoint(x: x, y: y)) } else { wave.addLine(to: CGPoint(x: x, y: y)) }
                    x += 3
                }
                g.setShadow(offset: .zero, blur: r.height * 0.12, color: col.withAlphaComponent(0.9).cgColor)
                g.setStrokeColor(col.withAlphaComponent(0.85).cgColor); g.setLineWidth(max(2, r.height * 0.045)); g.setLineCap(.round)
                g.addPath(wave); g.strokePath()
            }
            g.restoreGState()
        }
        if think > 0.01 {   // 轉圈：十二道短線，亮度依序遞減
            g.saveGState(); g.setAlpha(think)
            let c = CGPoint(x: r.midX, y: r.midY), rr = r.height * 0.24
            let step = Int(now * 12) % 12
            g.setLineCap(.round); g.setLineWidth(max(2, r.height * 0.055))
            for i in 0..<12 {
                let a = Double(i) / 12 * 2 * .pi - .pi / 2
                let k = Double((i - step + 12) % 12) / 12
                g.setStrokeColor(NSColor(white: 1, alpha: CGFloat(0.25 + 0.75 * (1 - k))).cgColor)
                g.move(to: CGPoint(x: c.x + CGFloat(cos(a)) * rr * 0.55, y: c.y + CGFloat(sin(a)) * rr * 0.55))
                g.addLine(to: CGPoint(x: c.x + CGFloat(cos(a)) * rr, y: c.y + CGFloat(sin(a)) * rr)); g.strokePath()
            }
            g.restoreGState()
        }
    }
}
