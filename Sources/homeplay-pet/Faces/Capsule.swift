// 膠囊（島身）的材質：依錶面年代自動挑，或在設定 › 外觀固定（稿：docs/design-drafts/faces-v3/artifact）。
// 👀 一律照 Apple Color Emoji 畫（drawEye），只換膠囊：
//   純黑＝2022 Dynamic Island；玻璃＝2025 Liquid Glass；黑透漸層＝2026 iOS 27；1988／2002 年代的島錶面沿用自己的島身。
// Siri（按住 F5）：照 iOS 27 的 Siri 球——深色液態玻璃從島往下長出來、輕輕脈動、裡面一道跟著聲音的彩色波形；
// 放開後縮成小球轉圈（思考中），再彈回原本的膠囊。

import AppKit
import Accelerate

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
            case .modular, .analog, .pocket, .black, .cluster: return .black   // 平面、Dynamic Island 年代的版式；OLED 全黑
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

    /// 玻璃（Liquid Glass）：beta 1 的設計（2026-11-06 使用者：還原晶瑩剔透）——我們自己的玻璃步驟（SystemGlass：折射 −2.4、模糊 9、
    /// 高光 0.55、白填 0.12、內緣暗 0.3），背景是這一刻已經畫好的錶面；位置與分鐘不變就用快取。
    /// 85eff38 曾換成系統 Regular 玻璃（較霧、厚邊框＋裡面一顆淺色內膠囊，看起來像兩層），這裡改回來；錶面數字等其他玻璃不動
    func glassPill(_ g: CGContext, _ r: CGRect) -> Bool {
        guard let backdrop = g.makeImage() else { return false }
        let ri = r.integral, sc = renderPixelScale
        let key = "\(style.rawValue)|\(Int(ri.minX)),\(Int(ri.minY)),\(Int(ri.width)),\(Int(ri.height))|\(Int(sc * 100))|\(Int(Date().timeIntervalSince1970 / 60))"
        let path = CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
        if let hit = Self.pillCache, hit.key == key {
            drawPillImage(g, hit.image, hit.rect, path); return true
        }
        // 橫滑換頁中整頁被平移，backdrop 是整個畫布、玻璃會照沒平移的位置取樣（取到頁縫的黑）＝變暗；而且這張會被快取住、
        // 滑完到下一分鐘前都是暗的。滑動中不算新的、不寫快取：有快取用快取，沒有就讓呼叫端用輕的那版
        if faceTransition != nil, Self.pageDir != 0 { return false }
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

    /// 按住 F5（CarPlay 直播中的 Siri）：膠囊變成水滴——光照體積的身體＋液面＋狀態邊緣光（LiquidOrb）；思考時中間轉圈。
    /// 進出場時跟平常的膠囊交叉淡入淡出，收尾後回到普通膠囊（不再逐幀）
    func drawSiriOrb(_ g: CGContext, _ r: CGRect, listen: CGFloat, think: CGFloat, now: Double) {
        let style = OrbStyle.current
        let p = OrbPresence(listen: listen, think: think, t: now - siriOrb.downAt)
        let show = min(1, p.activity * 2.5)
        if show < 0.999 { drawCapsuleBody(g, r, look: capsuleLook(), animating: true) }
        LiquidOrb.draw(g, r, p, style: style, alpha: show, liquidLevel: 0.6)
        if think > 0.01 {   // 轉圈：十二道短線，亮度依序遞減；減少動態效果＝十二個靜止的點
            g.saveGState(); g.setAlpha(think * show)
            let c = CGPoint(x: r.midX, y: r.midY), rr = r.height * 0.24
            let step = style.reduceMotion ? 0 : Int(now * 12) % 12
            g.setLineCap(.round); g.setLineWidth(max(2, r.height * 0.055))
            for i in 0..<12 {
                let a = Double(i) / 12 * 2 * .pi - .pi / 2
                let k = Double((i - step + 12) % 12) / 12
                let o = CGPoint(x: c.x + CGFloat(cos(a)) * rr, y: c.y + CGFloat(sin(a)) * rr)
                if style.reduceMotion {
                    g.setFillColor(NSColor(white: 1, alpha: 0.7).cgColor)
                    let d = max(2, r.height * 0.055); g.fillEllipse(in: CGRect(x: o.x - d / 2, y: o.y - d / 2, width: d, height: d))
                    continue
                }
                g.setStrokeColor(NSColor(white: 1, alpha: CGFloat(0.25 + 0.75 * (1 - k))).cgColor)
                g.move(to: CGPoint(x: c.x + CGFloat(cos(a)) * rr * 0.55, y: c.y + CGFloat(sin(a)) * rr * 0.55))
                g.addLine(to: o); g.strokePath()
            }
            g.restoreGState()
        }
    }
}

// MARK: - 水滴的光（ClioTalk 聆聽／思考／回答）
//
// 照官方水滴的做法（docs/hv-reference/siri_orb.txt）：
// - 「一、圖標圖層結構」：本體是很小的矢量形，體積靠具名漸層＋光照撐；光暈、投影、暗部各一層，深淺兩個變體只互換這幾層的透明度；
//   液感是兩層相位錯開的波＋焦散，全部加法混合。
// - 「二、運行時」：逐幀程序化繪製；邊緣光的內外半徑隨會話狀態切換。
// - 「三、配方」：本體＋漸變＋光照 → 液感 wave×2＋caustic → 狀態 edge light → 深淺透明度互換。
// 配色保留 ClioTalk 自己的橙、粉、紫、藍；👀 由呼叫的人畫在最上面（不改樣子）。

/// 水滴這一刻的「存在」：聆聽、思考、回答（0…1；過場時可以同時有一點）。全 0＝空閒
struct OrbPresence: Equatable {
    var listen: CGFloat = 0, think: CGFloat = 0, answer: CGFloat = 0
    /// 真實麥克風音量 0…1（ClioTalk 聆聽時有）；nil＝假包絡（音節節奏）
    var level: CGFloat?
    /// 回答：文字出現的節奏 0…1（剛出一段字＝1，隨後衰減）；nil＝假節奏
    var beat: CGFloat?
    /// 動畫時鐘（秒）；減少動態效果時完全不讀
    var t: Double = 0
    var activity: CGFloat { max(listen, think, answer) }
}

/// 外觀條件：深淺、減少動態效果、增加對比（自檢直接給值，不讀系統）
struct OrbStyle: Equatable {
    var dark: Bool, reduceMotion: Bool, increaseContrast: Bool
    static var current: OrbStyle {
        OrbStyle(dark: HPTokens.dark, reduceMotion: HPMotion.reduceMotion, increaseContrast: HPAccessibility.increaseContrast)
    }
}

enum LiquidOrb {
    /// 性冷淡單色（拍板 2026-11-07：撤彩虹跑馬燈）——冷灰階，形態照官方 system-dark/light 的玻璃水滴；
    /// 本體色團、液面、邊緣光全部從這一組派生，白 rim／光照體積的層次不動
    static let palette: [UInt32] = [0x48484e, 0x7a7d85, 0xa3a8b3, 0xd8dce4]
    private static let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    /// 具名漸層（橫向四色）：液面、邊緣光共用
    static let band = CGGradient(colorsSpace: cs, colors: palette.map { srgb($0).cgColor } as CFArray, locations: [0, 0.36, 0.66, 1])!
    /// 本體底的四團色（徑向，往外透明）
    private static let blobs: [CGGradient] = palette.map {
        CGGradient(colorsSpace: cs, colors: [srgb($0).cgColor, srgb($0, 0).cgColor] as CFArray, locations: [0, 1])!
    }
    private static let whiteFade = CGGradient(colorsSpace: cs, colors: [NSColor(white: 1, alpha: 1).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
    private static let blackRise = CGGradient(colorsSpace: cs, colors: [NSColor(white: 0, alpha: 0).cgColor, NSColor(white: 0, alpha: 1).cgColor] as CFArray, locations: [0.35, 1])!
    private static let rimGrad = CGGradient(colorsSpace: cs, colors: [NSColor(white: 1, alpha: 0.6).cgColor, NSColor(white: 1, alpha: 0.05).cgColor,
                                                                      NSColor(white: 1, alpha: 0.05).cgColor, NSColor(white: 1, alpha: 0.2).cgColor] as CFArray,
                                            locations: [0, 0.4, 0.62, 1])!

    // MARK: 深淺：只換層的透明度

    struct Layers: Equatable { var halo, shadow, shade, caustic, wave: CGFloat }
    static func layers(dark: Bool) -> Layers {
        let L = HVTruth.OrbLayers.self
        return dark ? Layers(halo: L.halo.dark, shadow: L.shadow.dark, shade: L.shade.dark, caustic: L.caustic.dark, wave: L.wave)
                    : Layers(halo: L.halo.light, shadow: L.shadow.light, shade: L.shade.light, caustic: L.caustic.light, wave: L.wave)
    }

    // MARK: 狀態邊緣光

    /// 邊緣光環：內外半徑（以水滴半徑＝1 計；inner < 1 < outer）與強度
    struct EdgeLight: Equatable {
        var inner: CGFloat, outer: CGFloat, intensity: CGFloat
        var width: CGFloat { outer - inner }
    }
    /// 各狀態的環：聆聽寬而柔、思考窄而亮、回答居中（跟著字明滅）、空閒幾乎看不見
    static let idleRing = EdgeLight(inner: 0.95, outer: 1.02, intensity: 0.05)
    static let listenRing = EdgeLight(inner: 0.55, outer: 1.30, intensity: 0.55)
    static let thinkRing = EdgeLight(inner: 0.84, outer: 1.08, intensity: 0.95)
    static let answerRing = EdgeLight(inner: 0.70, outer: 1.16, intensity: 0.30)   // ＋0.6 × 節奏

    static func edgeLight(_ p: OrbPresence, reduceMotion: Bool) -> EdgeLight {
        let wi = max(0, 1 - p.activity), sum = max(0.0001, p.listen + p.think + p.answer + wi)
        func mix(_ k: KeyPath<EdgeLight, CGFloat>) -> CGFloat {
            (idleRing[keyPath: k] * wi + listenRing[keyPath: k] * p.listen + thinkRing[keyPath: k] * p.think + answerRing[keyPath: k] * p.answer) / sum
        }
        let beat = reduceMotion ? 0.5 : (p.beat ?? syllable(p.t * 0.9 + 0.3))
        let pulse: CGFloat = reduceMotion ? 1 : 0.82 + 0.18 * CGFloat(sin(p.t * 2 * .pi * 1.4))   // 思考：微脈動
        var e = EdgeLight(inner: mix(\.inner), outer: mix(\.outer), intensity: 0)
        e.intensity = (idleRing.intensity * wi + listenRing.intensity * p.listen + thinkRing.intensity * pulse * p.think
                       + (answerRing.intensity + 0.6 * beat) * p.answer) / sum
        return e
    }

    /// 空閒不逐幀：只有聆聽／思考／回答時要 60fps
    static func needsFrames(_ p: OrbPresence) -> Bool { p.activity > 0.01 }

    /// 假包絡：音節節奏（每秒約 4.3 拍、快起慢落、偶爾停一拍），不是慢正弦
    static func syllable(_ t: Double) -> CGFloat {
        let x = t * 4.3, i = floor(x), u = x - i
        func h(_ n: Double) -> Double { let s = sin(n * 12.9898 + 78.233) * 43758.5453; return s - floor(s) }
        let a = h(i) < 0.18 ? 0.08 : 0.35 + 0.65 * h(i + 0.5)
        let shape = u < 0.2 ? u / 0.2 : pow(1 - (u - 0.2) / 0.8, 1.6)
        return CGFloat(a * shape)
    }

    // MARK: 畫

    /// r：水滴外框；shape：形狀（nil＝膠囊）；liquidLevel：液面在外框裡的高度（由上往下 0…1）；
    /// stable：形狀只跟大小有關（膠囊、圓）——軟的層（光暈、投影、色團、暗部、邊緣光）可以照大小快取，只有液面每幀重畫
    static func draw(_ g: CGContext, _ r: CGRect, shape: CGPath? = nil, _ p: OrbPresence, style s: OrbStyle,
                     alpha: CGFloat = 1, liquidLevel: CGFloat = 0.62, stable: Bool = true) {
        guard alpha > 0.003, r.width > 2, r.height > 2 else { return }
        let path = shape ?? CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
        let R = min(r.width, r.height) / 2
        let L = layers(dark: s.dark), act = p.activity
        // 快取鍵：大小量到 4 單位（呼吸、脈動時不必每幀重畫軟層；圖照實際外框縮放）
        let qs = stable ? [Int((r.width / 4).rounded()), Int((r.height / 4).rounded()), shape == nil ? 0 : 1] : nil
        let ds = deviceScale(g)
        g.saveGState()
        let layered = alpha < 0.999
        if layered {
            g.clip(to: r.insetBy(dx: -R * 1.6, dy: -R * 1.6))
            g.setAlpha(alpha); g.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        // 1. 光暈與投影：整體各一層，畫在一切之下（深色光暈、淺色投影，透明度互換）；大模糊在 1/8 大的離屏畫布上做
        let base = s.dark ? srgb(0x0A090E) : srgb(0x121117)
        if L.halo > 0.001 && !s.increaseContrast {
            let area = r.insetBy(dx: -R * 1.0, dy: -R * 1.0)
            if let img = SoftCanvas.halo.render(area, scale: 0.125, blur: R * 0.8, key: qs, device: ds, { c in
                c.addPath(path); c.setFillColor(srgb(0xA3A8B3).cgColor); c.fillPath()   // 冷灰（拍板 2026-11-08）：與 palette 同族，不再留紫
            }) {
                g.saveGState(); g.setAlpha(0.5 * L.halo * (0.35 + 0.65 * act)); drawUprightImage(g, img, in: area); g.restoreGState()
            }
        }
        if L.shadow > 0.001 {
            let area = r.insetBy(dx: -R * 0.6, dy: -R * 0.6)
            if let img = SoftCanvas.shadow.render(area, scale: 0.125, blur: R * 0.45, key: qs, device: ds, { c in
                c.addPath(path); c.setFillColor(NSColor.black.cgColor); c.fillPath()
            }) {
                g.saveGState(); g.setAlpha(L.shadow); drawUprightImage(g, img, in: area.offsetBy(dx: 0, dy: R * 0.15)); g.restoreGState()
            }
        }
        g.addPath(path); g.setFillColor(base.cgColor); g.fillPath()

        g.saveGState(); g.addPath(path); g.clip()
        // 2. 冷灰漸層底：四團同族灰加法混在一起（拍板 2026-11-08 撤彩虹）；色團是軟的，1/4 大畫好放大
        if let img = SoftCanvas.blobs.render(r, scale: 0.25, blur: 0, key: qs.map { $0 + [Int(r.width / r.height * 8)] }, device: ds, { c in
            c.setBlendMode(.plusLighter)
            let spots: [(CGFloat, CGFloat)] = [(0.16, 0.95), (0.45, 1.05), (0.78, 0.88), (0.96, 0.35)]
            let br = max(r.width, r.height) * 0.55
            for (i, sp) in spots.enumerated() {
                let o = CGPoint(x: r.minX + r.width * sp.0, y: r.minY + r.height * sp.1)
                c.drawRadialGradient(blobs[i], startCenter: o, startRadius: 0, endCenter: o, endRadius: br, options: [])
            }
        }) {
            g.setBlendMode(.plusLighter); g.setAlpha(0.16 + 0.22 * act); drawUprightImage(g, img, in: r)
        }
        // 3. 液面：主波＋次波（相位錯開、頻率略異、較淡），波與波之間填漸層；再加焦散
        g.setBlendMode(.plusLighter)
        let waveAmt = max(p.listen, 0.6 * p.answer, 0.35 * p.think)
        if waveAmt > 0.01 { drawLiquid(g, r, R, p, s, L, amount: waveAmt, level: liquidLevel) }
        g.setBlendMode(.normal); g.setAlpha(1)
        // 4. 暗部（右下）與主光（左上）：單一光向撐出體積（軟的，1/4 大快取）
        if let img = SoftCanvas.light.render(r, scale: 0.25, blur: 0, key: qs.map { $0 + [s.dark ? 1 : 0] }, device: ds, { c in
            c.setAlpha(0.5 * L.shade)
            c.drawLinearGradient(blackRise, start: CGPoint(x: r.minX + r.width * 0.25, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
            let hl = CGPoint(x: r.minX + r.width * 0.3, y: r.minY + r.height * 0.2)
            c.setAlpha(0.2)
            c.drawRadialGradient(whiteFade, startCenter: hl, startRadius: 0, endCenter: hl, endRadius: R * 1.1, options: [])
        }) {
            drawUprightImage(g, img, in: r)
        }
        // 5. 邊緣 rim light：左上亮、右下一點回光（細線，照實際形狀畫）
        g.addPath(path); g.setLineWidth(max(1.5, R * 0.09)); g.replacePathWithStrokedPath(); g.clip()
        g.drawLinearGradient(rimGrad, start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
        g.restoreGState()
        // 6. 狀態邊緣光（環的內外半徑跟著狀態走）
        drawEdgeLight(g, path, R: R, edgeLight(p, reduceMotion: s.reduceMotion), style: s, active: act, key: qs)
        if layered { g.endTransparencyLayer() }
        g.restoreGState()
    }

    /// 邊緣光：環從 inner 到 outer（半徑倍數），靠形狀邊最亮、往內外淡掉；增加對比＝一條實線
    static func drawEdgeLight(_ g: CGContext, _ path: CGPath, R: CGFloat, _ e: EdgeLight, style s: OrbStyle, active: CGFloat, key: [Int]? = nil) {
        let box = path.boundingBoxOfPath
        if s.increaseContrast {
            guard active > 0.01 else { return }
            g.saveGState()
            g.addPath(path); g.setLineWidth(max(2, R * 0.07)); g.replacePathWithStrokedPath(); g.clip()
            g.drawLinearGradient(band, start: CGPoint(x: box.minX, y: 0), end: CGPoint(x: box.maxX, y: 0), options: [])
            g.restoreGState()
            return
        }
        let din = (1 - e.inner) * R, dout = (e.outer - 1) * R
        guard e.intensity > 0.004, din + dout > 0.5 else { return }
        // 小畫布上畫一圈硬邊的核心環（內側 din、外側 dout 的一半寬），模糊之後就是往內外自然淡掉的光
        let area = box.insetBy(dx: -dout * 1.6 - 4, dy: -dout * 1.6 - 4)
        let soft = (din + dout) * 0.3
        guard let img = SoftCanvas.edge.render(area, scale: 0.25, blur: soft, key: key.map { $0 + [Int(e.inner * 100), Int(e.outer * 100)] }, device: deviceScale(g), { c in
            for (depth, inside) in [(din, true), (dout, false)] where depth > 0.5 {
                c.saveGState()
                if inside { c.addPath(path); c.clip() } else { c.addRect(area); c.addPath(path); c.clip(using: .evenOdd) }
                c.addPath(path); c.setLineWidth(depth * 1.1); c.replacePathWithStrokedPath(); c.clip()
                c.setAlpha(inside ? 1 : 0.7)
                c.drawLinearGradient(band, start: CGPoint(x: area.minX, y: 0), end: CGPoint(x: area.maxX, y: 0), options: [])
                c.restoreGState()
            }
        }) else { return }
        g.saveGState()
        g.setBlendMode(s.dark ? .plusLighter : .normal); g.setAlpha(min(1, e.intensity * 1.3))
        drawUprightImage(g, img, in: area)
        g.restoreGState()
    }

    /// 一條波（u 0…1 橫跨外框，兩端收平）
    private static func waveY(_ u: Double, y0: CGFloat, amp: CGFloat, f: Double, phase: Double) -> CGFloat {
        y0 - amp * CGFloat(sin(u * .pi)) * CGFloat(sin(u * .pi * 2 * f + phase))
    }

    private static func drawLiquid(_ g: CGContext, _ r: CGRect, _ R: CGFloat, _ p: OrbPresence, _ s: OrbStyle, _ L: Layers,
                                   amount: CGFloat, level: CGFloat) {
        let y0 = r.minY + r.height * level
        let bottom = r.maxY + 2
        let bandStart = CGPoint(x: r.minX, y: 0), bandEnd = CGPoint(x: r.maxX, y: 0)
        if s.reduceMotion {   // 減少動態效果：液面＝靜態漸層（沒有波、不讀時鐘）
            g.saveGState(); g.clip(to: CGRect(x: r.minX, y: y0, width: r.width, height: bottom - y0))
            g.setAlpha(0.5 * L.wave * amount)
            g.drawLinearGradient(band, start: bandStart, end: bandEnd, options: [])
            g.restoreGState()
            return
        }
        let env = 0.25 + 0.75 * (p.level ?? syllable(p.t))
        let beat = p.beat ?? syllable(p.t * 0.9 + 0.3)
        let amp = R * (0.34 * p.listen * env + 0.08 * p.think + 0.18 * p.answer * (0.4 + 0.6 * beat))
        let ph = p.t * (3.6 * Double(max(p.listen, p.answer)) + 1.4 * Double(p.think))
        let f1 = 1.15, f2 = 1.15 * 1.17
        let ph2 = ph * 0.83 + HVTruth.OrbLayers.secondWavePhase
        let step = max(2, r.width / 48)
        var main: [CGPoint] = [], second: [CGPoint] = []
        var x = r.minX
        while x <= r.maxX + 0.01 {
            let u = Double((x - r.minX) / r.width)
            main.append(CGPoint(x: x, y: waveY(u, y0: y0, amp: amp, f: f1, phase: ph)))
            second.append(CGPoint(x: x, y: waveY(u, y0: y0 + R * 0.06, amp: amp * 0.7, f: f2, phase: ph2)))
            x += step
        }
        func below(_ pts: [CGPoint]) -> CGPath {
            let m = CGMutablePath(); m.addLines(between: pts)
            m.addLine(to: CGPoint(x: r.maxX, y: bottom)); m.addLine(to: CGPoint(x: r.minX, y: bottom)); m.closeSubpath(); return m
        }
        func fill(_ shape: CGPath, _ a: CGFloat) {
            g.saveGState(); g.addPath(shape); g.clip(); g.setAlpha(a)
            g.drawLinearGradient(band, start: bandStart, end: bandEnd, options: [])
            g.restoreGState()
        }
        fill(below(second), HVTruth.OrbLayers.secondWave * 0.5 * L.wave * amount)   // 次波：較淡
        fill(below(main), 0.42 * L.wave * amount)                                    // 主波
        let between = CGMutablePath(); between.addLines(between: main + second.reversed()); between.closeSubpath()
        fill(between, 0.5 * L.wave * amount)                                         // 兩波之間：最亮的一帶
        // 液面的一道高光
        g.saveGState()
        let line = CGMutablePath(); line.addLines(between: main)
        g.addPath(line); g.setLineWidth(max(1, R * 0.035)); g.setLineCap(.round)
        g.setStrokeColor(NSColor(white: 1, alpha: 0.45 * amount).cgColor); g.strokePath()
        g.restoreGState()
        // 焦散：離屏小畫布畫兩道波 → 模糊 → 加法疊回
        if !s.increaseContrast && L.caustic > 0.001, let img = SoftCanvas.caustic.render(r, scale: 1.0 / 6, blur: R * 0.5, { c in
            let band = CGMutablePath(); band.addLines(between: main + second.reversed()); band.closeSubpath()
            c.addPath(band)
            let lines = CGMutablePath(); lines.addLines(between: main); lines.move(to: second[0]); lines.addLines(between: second)
            c.addPath(lines.copy(strokingWithWidth: R * 0.12, lineCap: .round, lineJoin: .round, miterLimit: 1))
            c.clip()
            c.drawLinearGradient(Self.band, start: CGPoint(x: r.minX, y: 0), end: CGPoint(x: r.maxX, y: 0), options: [])
        }) {
            g.saveGState(); g.setAlpha(L.caustic * amount)
            g.translateBy(x: 0, y: -R * 0.1)   // 光往上折一點
            drawUprightImage(g, img, in: r)
            g.restoreGState()
        }
    }

    /// 畫布的裝置倍率（1 個畫布單位是幾個像素）
    static func deviceScale(_ g: CGContext) -> CGFloat { let t = g.ctm; return max(0.1, (t.a * t.a + t.b * t.b).squareRoot()) }

    /// 在 y 往下的畫布上把圖正著畫（跟 Face.drawUpright 同一個做法）
    /// 原寸（圖的像素 ≈ 外框 × 裝置倍率）時不取樣，直接 1:1 疊
    static func drawUprightImage(_ g: CGContext, _ img: CGImage, in r: CGRect) {
        g.saveGState()
        let ds = deviceScale(g)
        if abs(CGFloat(img.width) - r.width * ds) <= max(2, r.width * ds * 0.03) { g.interpolationQuality = .none }
        g.translateBy(x: r.minX, y: r.maxY); g.scaleBy(x: 1, y: -1)
        g.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height)); g.restoreGState()
    }

}

/// 離屏小畫布（焦散、邊緣光共用的做法）：在外框的 scale 倍大小上畫 → 模糊（兩次 tent ≈ 高斯）→ 回傳圖；尺寸不變就重用畫布與暫存
final class SoftCanvas {
    nonisolated(unsafe) static var caustic = SoftCanvas(), edge = SoftCanvas(), screen = SoftCanvas(), halo = SoftCanvas(), shadow = SoftCanvas(),
        blobs = SoftCanvas(), light = SoftCanvas()
    private var ctx: CGContext?, tmp: UnsafeMutableRawPointer?, size = (0, 0)
    private var last: (key: [Int], image: CGImage)?
    /// body 用外框的畫布座標畫（y 往下）；blur 是畫布座標裡的模糊半徑（0＝不模糊）。
    /// key 一樣就直接回上一張（nil＝每次重畫）；有 key 時順便放大成 device 倍的原寸圖，之後每幀 1:1 疊、不必重新取樣
    func render(_ r: CGRect, scale: CGFloat, blur: CGFloat, key: [Int]? = nil, device: CGFloat = 0, _ body: (CGContext) -> Void) -> CGImage? {
        let fullKey = key.map { $0 + [Int(scale * 1000), Int(blur), Int(device * 100)] }
        if let fullKey, let last, last.key == fullKey { return last.image }
        let w = max(8, Int((r.width * scale).rounded(.up))), h = max(8, Int((r.height * scale).rounded(.up)))
        if size != (w, h) || ctx == nil {
            tmp?.deallocate(); tmp = nil; ctx = nil
            guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
            ctx = c; size = (w, h); tmp = UnsafeMutableRawPointer.allocate(byteCount: c.bytesPerRow * h, alignment: 16)
        }
        guard let c = ctx, let tmp, let data = c.data else { return nil }
        c.clear(CGRect(x: 0, y: 0, width: w, height: h))
        c.saveGState()
        c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: CGFloat(w) / r.width, y: -CGFloat(h) / r.height); c.translateBy(x: -r.minX, y: -r.minY)
        body(c)
        c.restoreGState()
        var src = vImage_Buffer(data: data, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: c.bytesPerRow)
        var dst = vImage_Buffer(data: tmp, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: c.bytesPerRow)
        if blur > 0 {
            let k = UInt32(max(3, Int(blur * scale)) | 1)   // 奇數核
            _ = vImageTentConvolve_ARGB8888(&src, &dst, nil, 0, 0, k, k, nil, vImage_Flags(kvImageEdgeExtend))
            _ = vImageTentConvolve_ARGB8888(&dst, &src, nil, 0, 0, k, k, nil, vImage_Flags(kvImageEdgeExtend))
        }
        guard var img = c.makeImage() else { return nil }
        if let fullKey {
            let fw = Int((r.width * device).rounded(.up)), fh = Int((r.height * device).rounded(.up))
            if device > 0, fw > 0, fh > 0, fw * fh < 4_000_000,
               let f = CGContext(data: nil, width: fw, height: fh, bitsPerComponent: 8, bytesPerRow: fw * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                f.interpolationQuality = .medium
                f.draw(img, in: CGRect(x: 0, y: 0, width: fw, height: fh))
                if let up = f.makeImage() { img = up }
            }
            last = (fullKey, img)
        } else { last = nil }
        return img
    }
}

// MARK: - 自檢（--selftest，掛在 ShellSelfTest.run）

enum LiquidOrbSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        // 深淺：只互換光暈／投影／暗部的透明度（深色有光暈沒投影，淺色反過來）
        let d = LiquidOrb.layers(dark: true), l = LiquidOrb.layers(dark: false)
        check(d.halo == 1 && l.halo == 0 && d.shadow == 0 && l.shadow == 0.225 && d.shade == 0.8 && l.shade == 0.95 && d.wave == l.wave,
              "水滴：深淺互換光暈、投影、暗部三層透明度（siri_orb.txt 圖層表）")   // l10n-ignore：selftest 訊息
        // 邊緣光：寬度 聆聽 > 回答 > 思考 > 空閒；內半徑反過來；強度 思考 > 聆聽 > 空閒；每個環都跨在邊上
        func ring(_ p: OrbPresence) -> LiquidOrb.EdgeLight { LiquidOrb.edgeLight(p, reduceMotion: true) }
        let idle = ring(OrbPresence()), lis = ring(OrbPresence(listen: 1)), thk = ring(OrbPresence(think: 1)), ans = ring(OrbPresence(answer: 1))
        check(lis.width > ans.width && ans.width > thk.width && thk.width > idle.width
              && lis.inner < ans.inner && ans.inner < thk.inner && thk.inner < idle.inner
              && [idle, lis, thk, ans].allSatisfy { $0.inner < 1 && $0.outer > 1 },
              "水滴：邊緣光內外半徑——聆聽最寬、思考收窄、空閒最窄，都跨在邊上")   // l10n-ignore：selftest 訊息
        check(thk.intensity > lis.intensity && lis.intensity > idle.intensity && idle.intensity < 0.1,
              "水滴：邊緣光思考最亮、空閒幾乎看不見")   // l10n-ignore：selftest 訊息
        // 過場：聆聽 → 思考的中間值落在兩者之間（單調）
        let mid = ring(OrbPresence(listen: 0.5, think: 0.5))
        check(mid.inner > lis.inner && mid.inner < thk.inner && mid.outer < lis.outer && mid.outer > thk.outer, "水滴：狀態過場的邊緣光單調")   // l10n-ignore：selftest 訊息
        // 空閒不逐幀；聆聽／思考／回答才要
        check(!LiquidOrb.needsFrames(OrbPresence()) && LiquidOrb.needsFrames(OrbPresence(listen: 1))
              && LiquidOrb.needsFrames(OrbPresence(answer: 1)) && !SiriOrbState().active(100),
              "水滴：空閒不要求逐幀，回普通膠囊")   // l10n-ignore：selftest 訊息
        // 假包絡是音節節奏：一秒內有好幾次起落（不是慢正弦）
        var peaks = 0, prev: CGFloat = 0, rising = false
        for i in 0..<120 { let v = LiquidOrb.syllable(Double(i) / 120); if v < prev && rising { peaks += 1 }; rising = v > prev; prev = v }
        check(peaks >= 3, "水滴：假包絡每秒起落三次以上（音節節奏）")   // l10n-ignore：selftest 訊息
        // 減少動態效果：畫面跟時間無關；平常會動
        func shot(_ t: Double, reduce: Bool, contrast: Bool = false) -> Data? {
            guard let c = CGContext(data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 96 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            for st in [OrbPresence(listen: 1, t: t), OrbPresence(think: 1, t: t), OrbPresence(answer: 1, t: t)] {
                LiquidOrb.draw(c, CGRect(x: 16, y: 16, width: 64, height: 32), st, style: OrbStyle(dark: true, reduceMotion: reduce, increaseContrast: contrast))
            }
            return c.data.map { Data(bytes: $0, count: 96 * 64 * 4) }
        }
        check(shot(0.3, reduce: true) == shot(2.9, reduce: true) && shot(0.3, reduce: true, contrast: true) == shot(2.9, reduce: true, contrast: true),
              "水滴：減少動態效果時跟時間無關（波形→靜態漸層、邊緣光常亮）")   // l10n-ignore：selftest 訊息
        check(shot(0.3, reduce: false) != shot(2.9, reduce: false), "水滴：平常的液面會動")   // l10n-ignore：selftest 訊息
    }
}
