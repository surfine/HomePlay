// 錶面「家庭模組」：照 HomeView 的 Home Modular——紫色底上幾條大的 3D 玻璃緞帶，
// 六塊霜面玻璃磚：左上大溫控、右上指針鐘、場景、燈／對講、門鎖、最後一塊放膠囊（👀）。
// 資料來自「HomePlay Home」幫手（HomeLink）；只顯示，不送任何控制。
// 背景＋緞帶＋玻璃磚＋文字按資料與解析度快取成一張圖；指針每秒重畫（只有指針與膠囊在動）。

import AppKit

nonisolated(unsafe) private var homeModCache: (key: String, image: CGImage)?
nonisolated(unsafe) private var homeModLastSecond = -1
nonisolated(unsafe) private var homeModObservers: [NSObjectProtocol] = []

/// 一次渲染要顯示的內容（從 HomeLink 快照挑出來的字串與圖示）
private struct HomeTiles: Equatable {
    var number = "—"
    var thermoLabel = ""
    var thermoSub = ""
    var hint: String? = nil            // 沒資料時，溫控磚上的小字提示
    var sceneName = ""
    var sceneSub = ""
    var lightSymbol = "waveform"
    var lightLabel = ""
    var lightSub = ""
    var lockSymbol = "lock.fill"
    var lockLabel = ""
    var lockSub = ""
}

extension Face {
    private static let hk: CGFloat = 1024 / 600
    /// 整組磚往內收到外距 40：同心半徑＝螢幕圓角 138 − 40＝98，大小磚都放得下同一個連續圓角；四周也多一圈空氣
    static let tileT: CGAffineTransform = {
        let m: CGFloat = 40, m0: CGFloat = 12 * hk, s = (1024 - 2 * m) / (1024 - 2 * m0)
        return CGAffineTransform(translationX: m - m0 * s, y: m - m0 * s).scaledBy(x: s, y: s)
    }()
    static let tileRadius = Screen.concentric(inset: 40)

    // MARK: 資料

    /// 快照與示範：固定的示範家庭（不把使用者家裡的配件名放進截圖）
    nonisolated(unsafe) static var demoData = false
    private func homeTiles() -> HomeTiles {
        var t = HomeTiles()
        if Face.demoData {
            t.number = Locale.current.measurementSystem == .us ? "72" : "22"
            t.thermoLabel = L("homemod.thermostat", "温控"); t.thermoSub = L("homemod.demo.livingRoom", "客厅")
            t.sceneName = L("homemod.demo.goodNight", "晚安"); t.sceneSub = L("homemod.scene", "场景")
            t.lightSymbol = "lamp.floor.fill"; t.lightLabel = L("homemod.demo.floorLamp", "落地灯"); t.lightSub = L("homemod.demo.livingRoom", "客厅")
            t.lockSymbol = "lock.fill"; t.lockLabel = L("homemod.lock", "门锁"); t.lockSub = L("homemod.demo.frontDoor", "大门")
            return t
        }
        let link = HomeLink.shared
        let s = link.snapshot
        let has = link.connected && s.ready && !s.accessories.isEmpty
        let fm = FileManager.default
        let installed = [NSHomeDirectory() + "/Applications", "/Applications"].contains { fm.fileExists(atPath: $0 + "/HomePlay Home.app") }
        t.thermoLabel = L("homemod.thermostat", "温控")
        t.thermoSub = "—"
        t.sceneName = "—"; t.sceneSub = L("homemod.scene", "场景")
        t.lightLabel = L("homemod.intercom", "对讲"); t.lightSub = "—"
        t.lockLabel = L("homemod.lock", "门锁"); t.lockSub = "—"
        guard has else {
            t.hint = installed ? L("homemod.connecting", "正在连接家庭…") : L("homemod.install", "安装 HomePlay Home 以显示家庭")
            return t
        }
        let rooms = Dictionary(s.rooms.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let room: (HomeAccessory) -> String = { a in a.room.map { rooms[$0] ?? ($0.contains("-") && $0.count > 20 ? "—" : $0) } ?? "—" }
        let cat: (HomeAccessory) -> String = { ($0.categoryName ?? "").lowercased() }

        // 溫控：恆溫器／冷暖氣機優先，其次任何有目標溫度的，最後任何有目前溫度的（感測器）
        let thermo = s.accessories.first { a in ["thermostat", "heater", "air conditioner", "cooler"].contains { cat(a).contains($0) } && (a.characteristic("targetTemp") != nil || a.characteristic("currentTemp") != nil) }
            ?? s.accessories.first { $0.characteristic("targetTemp") != nil }
            ?? s.accessories.first { $0.characteristic("currentTemp") != nil }
        if let a = thermo {
            let c = a.characteristic("targetTemp") ?? a.characteristic("currentTemp")
            if var v = c?.value?.number {
                if Locale.current.measurementSystem == .us { v = v * 9 / 5 + 32 }
                t.number = String(Int(v.rounded()))
            }
            t.thermoLabel = a.name; t.thermoSub = room(a)
        }
        // 找「晚安」場景：比對的是使用者家裡的場景名稱（資料，不是介面字串）
        let goodNight = ["\u{665A}\u{5B89}", "good night", "goodnight"]
        if let sc = s.scenes.first(where: { sc in sc.type.lowercased().contains("sleep") || goodNight.contains { sc.name.lowercased().contains($0) } }) ?? s.scenes.first {
            t.sceneName = sc.name
        }
        if let a = s.accessories.first(where: { cat($0).contains("light") && $0.characteristic("power") != nil }) {
            let on = a.characteristic("power")?.value?.isOn ?? false
            t.lightSymbol = on ? "lightbulb.fill" : "lightbulb"
            t.lightLabel = a.name; t.lightSub = room(a)
        }
        if let a = s.accessories.first(where: { $0.characteristic("lockCurrent") != nil }) {
            let secured = a.characteristic("lockCurrent")?.value?.number == 1
            t.lockSymbol = secured ? "lock.fill" : "lock.open.fill"
            t.lockLabel = a.name; t.lockSub = room(a)
        }
        return t
    }

    /// 臉被畫出來時才啟動 HomeLink，並在資料變動時要求重畫
    private func startHomeLinkIfNeeded() {
        guard homeModObservers.isEmpty else { return }
        HomeLink.shared.start()
        let nc = NotificationCenter.default
        for n in [Notification.Name.homeLinkSnapshot, .homeLinkChanged, .homeLinkConnection] {
            homeModObservers.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.forceDirty = true })
        }
    }

    // MARK: 繪製

    func renderHomeModularFace(_ g: CGContext, _ now: Double) {
        startHomeLinkIfNeeded()
        let tiles = homeTiles()
        let sc = renderPixelScale, px = Int((1024 * sc).rounded())
        let key = "\(tiles)|\(Int(sc * 100))|\(L10n.language.rawValue)"
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        if let c = homeModCache, c.key == key {
            drawUpright(g, c.image, in: full); Face.cacheHits += 1
        } else {
            let img = makeImage(px, px) { c in
                if sc != 1 { c.scaleBy(x: sc, y: sc) }
                self.drawHomeModularStatic(c, tiles)
            }
            homeModCache = (key, img)
            drawUpright(g, img, in: full); Face.cacheMisses += 1
        }
        g.saveGState(); g.concatenate(Self.tileT); drawHomeModularClockHands(g); g.restoreGState()
        // 最後一塊磚：膠囊（👀）
        let k = Self.hk
        let c = CGPoint(x: 494 * k, y: 452 * k).applying(Self.tileT)
        drawIsland(g, at: c, scale: 222 / 588 * Self.tileT.a, liveAt: c, now: now)
    }

    func tickHomeModularFace(_ now: Double) -> Bool {
        let s = secondsVisible ? Calendar.current.component(.second, from: Date()) : -1
        if s != homeModLastSecond { homeModLastSecond = s; return true }
        return false
    }

    private func homeGradient(_ g: CGContext) {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        // 底：偏飽和的靛紫，邊緣深一點；再疊幾團明暗讓玻璃有東西可折射
        let base = CGGradient(colorsSpace: cs, colors: [srgb(0x4a40d6).cgColor, srgb(0x3228b8).cgColor, srgb(0x231b94).cgColor] as CFArray, locations: [0, 0.55, 1])!
        g.drawLinearGradient(base, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1024, y: 1024), options: [])
        let blobs: [(CGFloat, CGFloat, CGFloat, UInt32, CGFloat)] = [
            (300, 260, 420, 0x9a8dff, 0.55), (860, 700, 380, 0x8d7dff, 0.45), (120, 900, 320, 0x1f1888, 0.7),
            (900, 120, 300, 0x1f1888, 0.55), (560, 560, 300, 0xb5a8ff, 0.30)]
        for (x, y, r, hex, a) in blobs {
            let rg = CGGradient(colorsSpace: cs, colors: [srgb(hex, a).cgColor, srgb(hex, 0).cgColor] as CFArray, locations: [0, 1])!
            g.drawRadialGradient(rg, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
        }
    }

    /// 底＋緞帶落在底上的柔影（玻璃透出來的背景，也是玻璃磚後面的背景）
    private func homeBackdrop(_ g: CGContext) {
        homeGradient(g)
        g.saveGState()
        let rp = CGMutablePath()
        for r in homeRibbons() { rp.addPath(r.path) }
        g.addRect(CGRect(x: -400, y: -400, width: 1824, height: 1824)); g.addPath(rp); g.clip(using: .evenOdd)
        g.setShadow(offset: CGSize(width: 14, height: -26), blur: 46, color: srgb(0x0e0850, 0.8).cgColor)
        g.addPath(rp); g.setFillColor(srgb(0x0e0850).cgColor); g.fillPath()
        g.restoreGState()
    }

    /// 兩個方向的緞帶各一片玻璃：-38° 的偏亮，52° 的偏深，才看得出轉折的立體感
    private func drawHomeRibbonGlass(_ g: CGContext, _ ribbons: [GlyphShape], base: CGImage) {
        var a = SystemGlassParams.portrait
        a.refractionAmount = -5.5; a.blurRadius = 5; a.fill = 0.34; a.white = 0.9; a.saturation = 1.25; a.rim = 0.7
        a.tint = srgb(0xc4bcff, 0.40).cgColor
        var b = a
        b.fill = 0.12; b.tint = srgb(0x7a6cff, 0.30).cgColor; b.rim = 0.5
        drawLiquidGlass(g, Array(ribbons[0..<3]), key: "homemod-ribbons-a", clear: base, frosted: base, system: a)
        drawLiquidGlass(g, Array(ribbons[3...]), key: "homemod-ribbons-b", clear: base, frosted: base, system: b)
    }

    private func homeRibbons() -> [GlyphShape] {
        let k = Self.hk
        func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ rot: CGFloat) -> GlyphShape {
            var t = CGAffineTransform(translationX: 300, y: 300).rotated(by: rot * .pi / 180).translatedBy(x: -300, y: -300)
            let p = CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: min(w, h) / 2, cornerHeight: min(w, h) / 2, transform: &t)
            var s = CGAffineTransform(scaleX: k, y: k)
            return GlyphShape(path: p.copy(using: &s) ?? p)
        }
        return [bar(-120, 40, 900, 120, -38), bar(-60, 250, 820, 150, -38), bar(-200, 470, 900, 110, -38),
                bar(80, -120, 110, 420, 52), bar(380, 320, 120, 420, 52)]
    }

    private func homePlatters() -> [GlyphShape] {
        let k = Self.hk
        func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> GlyphShape {
            GlyphShape(path: continuousRoundedRect(CGRect(x: x * k, y: y * k, width: w * k, height: h * k).applying(Self.tileT), radius: Self.tileRadius))
        }
        return [rr(12, 12, 374, 374, 34),
                GlyphShape(path: CGPath(ellipseIn: CGRect(x: (487 - 88) * k, y: (99 - 88) * k, width: 176 * k, height: 176 * k).applying(Self.tileT), transform: nil)),
                rr(398, 200, 190, 186, 30), rr(12, 398, 182, 190, 30), rr(206, 398, 182, 190, 30), rr(400, 398, 188, 190, 30)]
    }

    private func drawHomeModularStatic(_ g: CGContext, _ t: HomeTiles) {
        let k = Self.hk, white = NSColor.white
        let base = snapshotBackdrop { self.homeBackdrop($0) }
        // 1. 底＋大緞帶（玻璃）
        homeBackdrop(g)
        let ribbons = homeRibbons()
        drawHomeRibbonGlass(g, ribbons, base: base)
        // 2. 玻璃磚（霜面、低折射）：背景＝底＋緞帶
        let sc = renderPixelScale, px = 512
        let behind = makeImage(px, px) { c in
            c.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
            self.homeBackdrop(c)
            self.drawHomeRibbonGlass(c, ribbons, base: base)
        }
        _ = sc
        let frost = blurredBackdrop(behind, sigma: 4, key: "homemod-frost|\(Int(renderPixelScale * 100))")
        var plat = SystemGlassParams.portrait
        plat.refractionAmount = -1.0; plat.blurRadius = 8; plat.fill = 0.06; plat.white = 0.92; plat.black = 0.1
        plat.highlight = 0.3; plat.rim = 0.32; plat.ringShadow = 0.14; plat.saturation = 1.1   // 官方磚的亮邊很細
        plat.tint = srgb(0xd8d4ff, 0.06).cgColor
        drawLiquidGlass(g, homePlatters(), key: "homemod-platters", clear: frost, frosted: frost, system: plat)

        // 3. 內容（跟磚一起往內收）
        g.saveGState(); g.concatenate(Self.tileT); defer { g.restoreGState() }
        if let hint = t.hint {
            // 沒資料：不畫大數字，中間放一句小字提示
            let f = FaceType.sf(46, .semibold, mono: false)
            let lines = Self.wrap(hint, f, 480, maxLines: 3)
            let y0 = 190 * k - CGFloat(lines.count - 1) * 30
            for (i, l) in lines.enumerated() { centeredText(g, l, f, x: 199 * k, y: y0 + CGFloat(i) * 60, color: white.withAlphaComponent(0.78)) }
        } else {
            let numShape = GlyphShape(t.number, font: FaceType.sfv(293, wght: 520, mono: false), kern: -6)   // 官方溫控大數字約 Medium
            let nb = numShape.ink
            // 大數字：底邊（基線）在 y=228，水平置中於 x=199
            fillShape(g, numShape.moved(199 * k - nb.midX, 228 * k - nb.maxY), white)
        }
        for (cx, dir) in [(64.0, "chevron.down"), (334.0, "chevron.up")] {
            drawSymbol(g, dir, in: CGRect(x: cx * k - 30, y: 333 * k - 18, width: 60, height: 36), color: white, weight: .semibold)
        }
        label(g, t.thermoLabel, t.thermoSub, cx: 199, y1: 325, y2: 350, maxW: 560)
        // 鐘面刻度
        let cc = CGPoint(x: 487 * k, y: 99 * k)
        for i in 0..<12 {
            let a = CGFloat(i) * .pi / 6
            g.setStrokeColor(white.cgColor); g.setLineWidth(4.5 * k); g.setLineCap(.round)
            g.move(to: CGPoint(x: cc.x + sin(a) * 60 * k, y: cc.y - cos(a) * 60 * k))
            g.addLine(to: CGPoint(x: cc.x + sin(a) * 74 * k, y: cc.y - cos(a) * 74 * k)); g.strokePath()
        }
        // 場景
        drawSymbol(g, "moon.stars.fill", in: CGRect(x: 493 * k - 46, y: 257 * k - 46, width: 92, height: 92), color: white, weight: .regular)
        label(g, t.sceneName, t.sceneSub, cx: 493, y1: 330, y2: 355, maxW: 290)
        // 燈／對講
        drawSymbol(g, t.lightSymbol, in: CGRect(x: 103 * k - 48, y: 459 * k - 48, width: 96, height: 96), color: white, weight: .regular)
        label(g, t.lightLabel, t.lightSub, cx: 103, y1: 528, y2: 553, maxW: 290)
        // 門鎖
        drawSymbol(g, t.lockSymbol, in: CGRect(x: 297 * k - 44, y: 459 * k - 44, width: 88, height: 88), color: white, weight: .semibold)
        label(g, t.lockLabel, t.lockSub, cx: 297, y1: 528, y2: 553, maxW: 290)
        // 膠囊那一塊
        label(g, "HomePlay", L("homemod.watching", "看着你"), cx: 494, y1: 528, y2: 553, maxW: 300)
    }

    private func centeredText(_ g: CGContext, _ s: String, _ f: NSFont, x: CGFloat, y: CGFloat, color: NSColor) {
        let w = Typo.width(s, f)
        drawLeft(g, s, font: f, x: x - w / 2, y: y, color: color)
    }

    private func label(_ g: CGContext, _ title: String, _ sub: String, cx: CGFloat, y1: CGFloat, y2: CGFloat, maxW: CGFloat) {
        let k = Self.hk
        let tf = FaceType.sf(21 * k, .bold, mono: false), sf = FaceType.sf(19 * k, .semibold, mono: false)
        centeredText(g, Self.clipped(title, tf, maxW), tf, x: cx * k, y: y1 * k, color: .white)
        centeredText(g, Self.clipped(sub, sf, maxW), sf, x: cx * k, y: y2 * k, color: NSColor.white.withAlphaComponent(0.62))
    }

    // MARK: 指針

    private func drawHomeModularClockHands(_ g: CGContext) {
        let k = Self.hk, c = CGPoint(x: 487 * k, y: 99 * k)
        let comp = Calendar.current.dateComponents([.hour, .minute, .second], from: Self.displayDate)
        let s = Double(comp.second ?? 0), m = Double(comp.minute ?? 0) + s / 60, h = Double((comp.hour ?? 0) % 12) + m / 60
        func hand(_ deg: Double, neck: CGFloat, len: CGFloat, w: CGFloat) {
            let a = CGFloat(deg * .pi / 180), ux = sin(a), uy = -cos(a)
            g.setStrokeColor(NSColor.white.cgColor); g.setLineCap(.round)
            g.setLineWidth(3 * k); g.move(to: c); g.addLine(to: CGPoint(x: c.x + ux * neck * k, y: c.y + uy * neck * k)); g.strokePath()
            g.setLineWidth(w * k)
            g.move(to: CGPoint(x: c.x + ux * neck * k, y: c.y + uy * neck * k))
            g.addLine(to: CGPoint(x: c.x + ux * (neck + len) * k, y: c.y + uy * (neck + len) * k)); g.strokePath()
        }
        hand(h * 30, neck: 10, len: 38, w: 7)
        hand(m * 6, neck: 10, len: 62, w: 6)
        if secondsVisible {   // 沒人在看時收起秒針
            let sa = CGFloat(s * 6 * .pi / 180)
            g.setStrokeColor(NSColor.white.cgColor); g.setLineWidth(1.4 * k); g.setLineCap(.round)
            g.move(to: CGPoint(x: c.x - sin(sa) * 12 * k, y: c.y + cos(sa) * 12 * k))
            g.addLine(to: CGPoint(x: c.x + sin(sa) * 70 * k, y: c.y - cos(sa) * 70 * k)); g.strokePath()
            g.setFillColor(NSColor.white.cgColor); g.fillEllipse(in: CGRect(x: c.x - 4.5 * k, y: c.y - 4.5 * k, width: 9 * k, height: 9 * k))
        }
    }
}
