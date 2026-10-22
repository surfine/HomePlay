// 島錶面的自由组合：时钟样式 × 背景 × 年代（稿：Compose.dc.html、Era.dc.html）。
// 只影响「島」錶面；年代跟 3D 外观（finish）无关。设置存 UserDefaults。

import AppKit

enum ClockStyle: String, CaseIterable {
    case bold, thin, stacked, compact
    static let defaultsKey = "HomePlayClockStyle"
    var title: String {
        switch self {
        case .bold: return L("island.clock.bold", "圆体粗")
        case .thin: return L("island.clock.thin", "细线")
        case .stacked: return L("island.clock.stacked", "直排")
        case .compact: return L("island.clock.compact", "岛数字")
        }
    }
}

enum IslandBackground: String, CaseIterable {
    case daytime, flow, photo, solid, black
    static let defaultsKey = "HomePlayBackground"
    var title: String {
        switch self {
        case .daytime: return L("island.bg.daytime", "随时段")
        case .flow: return "Flow"
        case .photo: return L("island.bg.photo", "照片")
        case .solid: return L("island.bg.solid", "纯色")
        case .black: return L("island.bg.black", "全黑")
        }
    }
    /// 照片背景没有照片时退回随时段
    func effective(hasPhoto: Bool) -> IslandBackground { self == .photo && !hasPhoto ? .daytime : self }
}

enum Era: String, CaseIterable {
    case y1988, y2002, y2026
    static let defaultsKey = "HomePlayEra"
    var title: String {
        switch self {
        case .y1988: return "1988 · System 6"
        case .y2002: return "2002 · Aqua"
        case .y2026: return "2026 · Liquid Glass"
        }
    }
}

/// 快照专用：命令行强行指定（不写 UserDefaults）
nonisolated(unsafe) var islandSnapshotOverride: (clock: ClockStyle?, bg: IslandBackground?, era: Era?) = (nil, nil, nil)
/// 快照專用：固定屏幕上顯示的日期與時間（官網的夜景才不會顯示早上八點）
nonisolated(unsafe) var snapshotDateOverride: Date?
nonisolated(unsafe) private var islandLastTick = -1.0
nonisolated(unsafe) private var dither1988: CGImage?

extension Face {
    /// 启动时读回三个设置（快照的命令行覆盖优先）
    func restoreIslandOptions() {
        let d = UserDefaults.standard
        clockStyle = islandSnapshotOverride.clock ?? ClockStyle(rawValue: d.string(forKey: ClockStyle.defaultsKey) ?? "") ?? .bold
        background = islandSnapshotOverride.bg ?? IslandBackground(rawValue: d.string(forKey: IslandBackground.defaultsKey) ?? "") ?? .daytime
        era = islandSnapshotOverride.era ?? Era(rawValue: d.string(forKey: Era.defaultsKey) ?? "") ?? .y2026
    }

    /// 直排用：两位小时 / 两位分钟
    static func clockParts(_ d: Date) -> (h: String, m: String) {
        let f = DateFormatter(); f.dateFormat = "HH,mm"
        let p = f.string(from: d).split(separator: ",").map(String.init)
        return (p.first ?? "00", p.last ?? "00")
    }

    /// Flow 背景的光团在漂，限 10fps 重画
    func tickIslandOptions(_ now: Double) -> Bool {
        guard background == .flow, era != .y1988 else { return false }
        let t = floor(now * 10)
        if t == islandLastTick { return false }
        islandLastTick = t
        return true
    }

    // MARK: 渲染

    func renderIslandOptions(_ g: CGContext, _ now: Double) {
        if era == .y2026 { renderIsland2026(g, now); return }   // 2026：玻璃大數字（Faces/IslandFace.swift）
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let rv = reveal, date = snapshotDateOverride ?? Date(), e1988 = era == .y1988
        let bg = background.effective(hasPhoto: photos.current != nil)
        let ink: NSColor = e1988 ? .black : .white
        func alpha(_ a: CGFloat) -> NSColor { ink.withAlphaComponent(e1988 ? 1 : a) }

        // 排版：每行 (字, 字号, 字重, 基线, 透明度, 字距)
        struct Line { var s: String; var size: CGFloat; var w: NSFont.Weight; var y: CGFloat; var a: CGFloat; var kern: CGFloat }
        func lerp(_ a: NSFont.Weight, _ b: NSFont.Weight) -> NSFont.Weight { NSFont.Weight(rawValue: a.rawValue + (b.rawValue - a.rawValue) * rv) }
        var lines: [Line] = [], dateY: CGFloat = 150
        var islandAt = CGPoint(x: 512, y: 640), islandScale: CGFloat = 1, liveAt = CGPoint(x: 512, y: 700)
        let (hh, mm) = Self.clockParts(date), t = Self.clock(date)
        switch clockStyle {
        case .bold:
            lines = [Line(s: t, size: 300, w: lerp(.regular, .bold), y: 556, a: 0.6 + 0.34 * rv, kern: -6)]
        case .thin:
            lines = [Line(s: t, size: 320, w: lerp(.ultraLight, .thin), y: 560, a: 0.6 + 0.34 * rv, kern: -8)]
        case .stacked:
            lines = [Line(s: hh, size: 270, w: lerp(.semibold, .bold), y: 400, a: 0.7 + 0.28 * rv, kern: -4),
                     Line(s: mm, size: 270, w: lerp(.semibold, .bold), y: 664, a: 0.4 + 0.2 * rv, kern: -4)]
            dateY = 120; islandAt = CGPoint(x: 512, y: 786); islandScale = 0.8; liveAt = CGPoint(x: 512, y: 780)
        case .compact:
            lines = [Line(s: t, size: 132, w: lerp(.semibold, .bold), y: 760, a: 0.7 + 0.28 * rv, kern: -2)]
            islandAt = CGPoint(x: 512, y: 500); islandScale = 1.15; liveAt = CGPoint(x: 512, y: 560)
        }
        if e1988 && clockStyle != .stacked { islandAt.y += 60; liveAt.y += 40 }   // 白框下面留出岛的位置
        func font(_ l: Line) -> NSFont { e1988 ? Self.font1988(l.size) : Self.rounded(l.size, weight: l.w) }
        if e1988 {   // 1-bit 字体宽，收到 700 以内
            for i in lines.indices {
                let wd = (lines[i].s as NSString).size(withAttributes: [.font: Self.font1988(lines[i].size)]).width
                if wd > 700 { lines[i].size *= 700 / wd }
            }
        }
        let tText = CACurrentMediaTime()
        let dl = Self.dateLine(date)
        // 日期 + 時間（含 1988 白框）。抽成一個函式，供快取層與直接繪製兩條路共用。
        func drawText(_ c: CGContext) {
            if e1988 {
                let f = Self.font1988(40), wd = (dl as NSString).size(withAttributes: [.font: f]).width
                box1988(c, CGRect(x: 512 - wd / 2 - 24, y: dateY - 50, width: wd + 48, height: 72))
                drawCentered(c, dl, font: f, kern: 0, y: dateY, color: .black)
            } else {
                drawCentered(c, dl, font: Self.rounded(44, weight: .semibold), kern: 2, y: dateY, color: alpha(0.62 + 0.26 * rv))
            }
            if e1988, let top = lines.first, let bot = lines.last {
                let wd = lines.map { ($0.s as NSString).size(withAttributes: [.font: font($0)]).width }.max() ?? 0
                let y0 = top.y - top.size * 0.8, y1 = bot.y + 12
                box1988(c, CGRect(x: 512 - wd / 2 - 40, y: y0, width: wd + 80, height: y1 - y0 + 8))
            }
            for l in lines {
                drawCentered(c, l.s, font: font(l), kern: e1988 ? 0 : l.kern, y: l.y, color: alpha(l.a))
            }
        }
        // 文字層快取（透明圖，與背景解耦）：流動壁紙每幀在變，但大號時間只每分鐘變一次。
        let rvBucket = Int((rv * 40).rounded())
        let textKey = "islandText|\(Int(date.timeIntervalSince1970 / 60))|\(rvBucket)|\(clockStyle.rawValue)|\(era.rawValue)|\(e1988)|\(Int(renderPixelScale * 100))|\(t)|\(dl)"
        drawIslandBackground(g, bg, now)
        if rv < 0.999 && !e1988 {
            g.setFillColor(NSColor.black.withAlphaComponent(0.24 * (1 - rv)).cgColor)
            g.fill(full)
        }
        if let c = textLayerCache, c.key == textKey {
            drawUpright(g, c.image, in: full)
            Face.cacheHits += 1
        } else {
            let sc = renderPixelScale
            let px = Int((1024 * sc).rounded())
            let img = makeImage(px, px) { c in
                if sc != 1 { c.scaleBy(x: sc, y: sc) }
                drawText(c)
            }
            textLayerCache = (textKey, img)
            drawUpright(g, img, in: full)
            Face.cacheMisses += 1
        }
        Face.textSeconds += CACurrentMediaTime() - tText
        let tIsland = CACurrentMediaTime()
        // 靠近时底部的 CarPlay 状态
        if rv > 0.02 && liveT < 0.5 {
            let chipFont = e1988 ? Self.font1988(30) : Self.rounded(34, weight: .semibold)
            let tw = (status.text as NSString).size(withAttributes: [.font: chipFont]).width
            let chip = CGRect(x: 512 - (tw + 64) / 2, y: 872 + 18 * (1 - rv), width: tw + 64, height: 72)
            g.saveGState(); g.setAlpha(rv * (1 - liveT * 2))
            if e1988 { box1988(g, chip) }
            else if bg == .daytime && era == .y2026 { glass(g, chip, radius: 36, tint: NSColor(white: 1, alpha: 0.10), band: 10) }
            else { plainPill(g, chip, tint: NSColor(white: 1, alpha: 0.14)) }
            drawCentered(g, status.text, font: chipFont, kern: 0, y: chip.midY + 12, color: e1988 ? .black : NSColor.white.withAlphaComponent(0.85))
            g.restoreGState()
        }
        drawIsland(g, at: islandAt, scale: islandScale, liveAt: liveAt, now: now)
        Face.islandSeconds += CACurrentMediaTime() - tIsland
    }

    /// 1988 的白框黑边
    private func box1988(_ g: CGContext, _ r: CGRect) {
        g.setFillColor(NSColor.white.cgColor); g.fill(r)
        g.setStrokeColor(NSColor.black.cgColor); g.setLineWidth(4); g.stroke(r.insetBy(dx: 2, dy: 2))
    }

    /// Chicago / Geneva / Monaco 哪个有用哪个
    static func font1988(_ size: CGFloat) -> NSFont {
        for n in ["Chicago", "ChicagoFLF", "Chicago_12", "Geneva", "Monaco"] { if let f = NSFont(name: n, size: size) { return f } }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
    }

    // MARK: 背景

    func drawIslandBackground(_ g: CGContext, _ bg: IslandBackground, _ now: Double) {
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        if era == .y1988 {
            switch bg {
            case .black: g.setFillColor(NSColor.black.cgColor); g.fill(full)
            case .solid: g.setFillColor(NSColor.white.cgColor); g.fill(full)
            default:
                if dither1988 == nil {
                    dither1988 = makeImage(1024, 1024) { c in
                        c.setFillColor(NSColor.white.cgColor); c.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
                        c.setFillColor(NSColor.black.cgColor)
                        for j in 0..<171 { for i in 0..<171 where (i + j) % 2 == 0 { c.fill(CGRect(x: i * 6, y: j * 6, width: 6, height: 6)) } }
                    }
                }
                if let d = dither1988 { drawUpright(g, d, in: full) }
            }
            return
        }
        switch bg {
        case .daytime:
            if era == .y2002 { drawBlobs(g, Self.palette(hour: hourNow, aqua: true), arcs: true) }
            else if let wallpaper { drawUpright(g, wallpaper, in: full) }
        case .flow:
            g.setFillColor(NSColor(srgbRed: 0.071, green: 0.047, blue: 0.165, alpha: 1).cgColor); g.fill(full)
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let blobs: [(CGPoint, CGFloat, [CGFloat], CGFloat, CGFloat)] = [
                (CGPoint(x: 224, y: 288), 416, [1.0, 0.36, 0.67], 70, 31), (CGPoint(x: 800, y: 448), 384, [0.36, 0.55, 1.0], 46, 23),
                (CGPoint(x: 544, y: 848), 448, [1.0, 0.73, 0.36], 90, 37), (CGPoint(x: 768, y: 816), 240, [0.47, 0.94, 0.86], 120, 27)]
            for (i, b) in blobs.enumerated() {
                let ph = Double(i) * 1.7
                let c = CGPoint(x: b.0.x + flow.x * b.3 + CGFloat(sin(now * 2 * .pi / b.4 + ph)) * 34,
                                y: b.0.y + flow.y * b.3 * 0.8 + CGFloat(cos(now * 2 * .pi / (b.4 * 1.3) + ph)) * 28)
                guard let gr = CGGradient(colorSpace: cs, colorComponents: b.2 + [0.9] + b.2 + [0], locations: [0, 1], count: 2) else { continue }
                g.drawRadialGradient(gr, startCenter: c, startRadius: 0, endCenter: c, endRadius: b.1 * 0.96, options: [])
            }
        case .photo:
            if let img = photos.current {
                let s = max(1024 / CGFloat(img.width), 1024 / CGFloat(img.height))
                let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
                g.saveGState(); g.clip(to: full)
                drawUpright(g, img, in: CGRect(x: (1024 - w) / 2, y: (1024 - h) / 2, width: w, height: h))
                g.restoreGState()
                // 压一层暗，字才读得清
                g.setFillColor(NSColor(white: 0, alpha: 0.28).cgColor); g.fill(full)
            }
        case .solid: g.setFillColor(srgb(0x4f9a6a).cgColor); g.fill(full)
        case .black: g.setFillColor(NSColor.black.cgColor); g.fill(full)
        }
    }

    /// 色票渐层 + 四团光（跟 rebuildWallpaper 同一个画法，这里直接画满屏）
    private func drawBlobs(_ g: CGContext, _ pal: Palette, arcs: Bool) {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let grad = CGGradient(colorsSpace: cs, colors: [pal.top.color(), pal.bottom.color()] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: 1024), options: [])
        let spots: [(CGPoint, CGFloat, CGFloat)] = [(CGPoint(x: 780, y: 230), 360, 1.0), (CGPoint(x: 170, y: 840), 420, -0.7),
                                                    (CGPoint(x: 900, y: 930), 300, 0.5), (CGPoint(x: 330, y: 470), 260, -1.2)]
        for (i, s) in spots.enumerated() {
            let (col, a) = pal.blobs[i]
            let c = CGPoint(x: s.0.x + flow.x * 70 * s.2, y: s.0.y + flow.y * 70 * s.2)
            let b = CGGradient(colorsSpace: cs, colors: [col.color(a), col.color(0)] as CFArray, locations: [0, 1])!
            g.drawRadialGradient(b, startCenter: c, startRadius: 0, endCenter: c, endRadius: s.1, options: [])
        }
        if arcs {
            g.setLineCap(.round)
            for (k, w, a) in [(0.0, 90.0, 0.10), (1.0, 46.0, 0.14), (2.0, 20.0, 0.18)] as [(CGFloat, CGFloat, CGFloat)] {
                g.setStrokeColor(NSColor(white: 1, alpha: a).cgColor); g.setLineWidth(w)
                g.strokeEllipse(in: CGRect(x: -380 + k * 60, y: 420 - k * 40, width: 1700, height: 900))
            }
        }
    }

    // MARK: 岛的材质（drawIsland 调用；返回 true＝已画好）

    func drawOptionIslandBody(_ g: CGContext, _ rect: CGRect) -> Bool {
        guard style == .island else { return false }
        let r = rect.height / 2
        let path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        switch era {
        case .y1988:
            g.setFillColor(NSColor.black.cgColor); g.addPath(path); g.fillPath()
            if background == .black {   // 黑底上补一圈白边，岛才看得见
                g.setStrokeColor(NSColor.white.cgColor); g.setLineWidth(4); g.addPath(path); g.strokePath()
            }
            return true
        case .y2002:
            // Aqua 凝胶：蓝渐层 + 上半部高光 + 软阴影
            g.saveGState()
            g.setShadow(offset: CGSize(width: 0, height: 10), blur: 20, color: srgb(0x002878, 0.4).cgColor)
            g.addPath(path); g.setFillColor(srgb(0x1b5fd0).cgColor); g.fillPath()
            g.restoreGState()
            g.saveGState(); g.addPath(path); g.clip()
            let body = CGGradient(colorsSpace: cs, colors: [srgb(0x5aa2ff).cgColor, srgb(0x1b5fd0).cgColor, srgb(0x3b84f0).cgColor] as CFArray,
                                  locations: [0, 0.55, 1])!
            g.drawLinearGradient(body, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
            let hr = CGRect(x: rect.minX + 10, y: rect.minY + 5, width: rect.width - 20, height: rect.height * 0.46)
            let hp = CGPath(roundedRect: hr, cornerWidth: hr.height / 2, cornerHeight: hr.height / 2, transform: nil)
            g.addPath(hp); g.clip()
            let gel = CGGradient(colorsSpace: cs, colors: [NSColor(white: 1, alpha: 0.7).cgColor, NSColor(white: 1, alpha: 0.08).cgColor] as CFArray,
                                 locations: [0, 1])!
            g.drawLinearGradient(gel, start: CGPoint(x: 0, y: hr.minY), end: CGPoint(x: 0, y: hr.maxY), options: [])
            g.restoreGState()
            return true
        case .y2026:
            if background.effective(hasPhoto: photos.current != nil) == .daytime { return false }   // 随时段＝原来的液态玻璃
            plainPill(g, rect, tint: NSColor(white: 0, alpha: 0.78))
            return true
        }
    }

    /// 不透视壁纸的深色玻璃胶囊（背景不是随时段时用）：软阴影、顶部内光、细边
    func plainPill(_ g: CGContext, _ r: CGRect, tint: NSColor) {
        let rad = r.height / 2
        let path = CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: 14), blur: 34, color: NSColor(white: 0, alpha: 0.32).cgColor)
        g.addPath(path); g.setFillColor(tint.withAlphaComponent(max(tint.alphaComponent, 0.5)).cgColor); g.fillPath()
        g.restoreGState()
        g.saveGState(); g.addPath(path); g.clip()
        g.setFillColor(tint.cgColor); g.fill(r)
        let glow = CGGradient(colorsSpace: cs, colors: [NSColor(white: 1, alpha: 0.2).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(glow, start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.minY + r.height * 0.45), options: [])
        g.restoreGState()
        g.saveGState()
        g.addPath(path); g.setLineWidth(4); g.replacePathWithStrokedPath(); g.clip()
        let rim = CGGradient(colorsSpace: cs, colors: [NSColor(white: 1, alpha: 0.7).cgColor, NSColor(white: 1, alpha: 0.1).cgColor,
                                                       NSColor(white: 1, alpha: 0.1).cgColor, NSColor(white: 1, alpha: 0.4).cgColor] as CFArray,
                             locations: [0, 0.35, 0.65, 1])!
        g.drawLinearGradient(rim, start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
        g.restoreGState()
    }
}

// MARK: - 右键菜单「島錶面」

extension PetView {
    func islandOptionsMenu() -> NSMenu {
        let m = NSMenu()
        func section(_ title: String) {
            if !m.items.isEmpty { m.addItem(.separator()) }
            let h = NSMenuItem(title: title, action: nil, keyEquivalent: ""); h.isEnabled = false; m.addItem(h)
        }
        func add(_ title: String, _ sel: Selector, _ raw: String, _ on: Bool) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self; i.representedObject = raw; i.state = on ? .on : .off; m.addItem(i)
        }
        section(L("island.clock", "时钟样式"))
        for c in ClockStyle.allCases { add(c.title, #selector(menuIslandClock(_:)), c.rawValue, face.clockStyle == c) }
        section(L("island.bg", "背景"))
        for b in IslandBackground.allCases {
            add(b == .photo && face.photos.current == nil ? String(format: L("island.bg.photoMissing", "%@（没有照片，暂用随时段）"), b.title) : b.title,
                #selector(menuIslandBackground(_:)), b.rawValue, face.background == b)
        }
        section(L("island.era", "年代"))
        for e in Era.allCases { add(e.title, #selector(menuIslandEra(_:)), e.rawValue, face.era == e) }
        return m
    }

    /// 改了选项就切回島錶面，马上看得到
    private func islandOptionChanged(_ what: String) {
        if face.style != .island { setFaceStyle(.island) }
        log("island \(what)")
    }
    @objc func menuIslandClock(_ s: NSMenuItem) {
        guard let raw = s.representedObject as? String, let v = ClockStyle(rawValue: raw) else { return }
        face.clockStyle = v; UserDefaults.standard.set(raw, forKey: ClockStyle.defaultsKey); islandOptionChanged("clock \(raw)")
    }
    @objc func menuIslandBackground(_ s: NSMenuItem) {
        guard let raw = s.representedObject as? String, let v = IslandBackground(rawValue: raw) else { return }
        face.background = v; UserDefaults.standard.set(raw, forKey: IslandBackground.defaultsKey); islandOptionChanged("background \(raw)")
    }
    @objc func menuIslandEra(_ s: NSMenuItem) {
        guard let raw = s.representedObject as? String, let v = Era(rawValue: raw) else { return }
        face.era = v; UserDefaults.standard.set(raw, forKey: Era.defaultsKey); islandOptionChanged("era \(raw)")
    }
}
