// 錶面「家庭模組」：照 HomeView 的 Home Modular——硬邊幾何桌布（第四輪，綠／紫／藍／琥珀）上，
// 六塊霜面玻璃磚：左上大溫控、右上指針鐘、場景、燈／對講、門鎖、最後一塊放膠囊（👀）。
// 資料來自「HomePlay Home」幫手（HomeLink）；只顯示，不送任何控制。
// 背景＋緞帶＋玻璃磚＋文字按資料與解析度快取成一張圖；指針每秒重畫（只有指針與膠囊在動）。
// 第三輪：磚的版面與玻璃照官方 face-home-modular-*（3×3 格、外距 24、間距 20、圓角 50；玻璃清、折射後面的圖樣、亮邊細），
// 數字都在 HPTokens.HomeModular。錶面陣容不變（這款仍只是 modular 的舊選項，快照用 --style homeModular --style-raw）。

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
    private static var M: HPTokens.HomeModular.Type { HPTokens.HomeModular.self }

    // MARK: 資料

    /// 快照與示範：固定的示範家庭（不把使用者家裡的配件名放進截圖）
    nonisolated(unsafe) static var demoData = false
    private func homeTiles() -> HomeTiles {
        var t = HomeTiles()
        if OfficialDemo.on {
            // 第三輪：官方圖的那一組（68°F、晚安場景、對講、門鎖）
            t.number = "68"
            t.thermoLabel = L("homemod.thermostat", "温控"); t.thermoSub = L("homemod.demo.livingRoom", "客厅")
            t.sceneName = L("homemod.demo.goodNight", "晚安"); t.sceneSub = L("homemod.scene", "场景")
            t.lightSymbol = "waveform"; t.lightLabel = L("homemod.intercom", "对讲"); t.lightSub = L("homemod.demo.everywhere", "所有房间")
            t.lockSymbol = "lock.fill"; t.lockLabel = L("homemod.lock", "门锁"); t.lockSub = L("homemod.demo.frontDoor", "大门")
            return t
        }
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
        let key = "\(tiles)|\(Int(sc * 100))|\(L10n.language.rawValue)|\(HomeModularWallpaper.current.rawValue)|\(nightRedActive)"   // 2.0 P07：夜間副標改不透明灰階，要進快取 key
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
        drawHomeModularClockHands(g)
        // 最後一塊磚：膠囊（👀），放在其他磚放符號的位置
        let last = Self.M.tile(2, 2)
        let c = CGPoint(x: last.midX, y: last.minY + Self.M.iconCenterFromTop)
        drawIsland(g, at: c, scale: 0.36, liveAt: c, now: now)
    }

    func tickHomeModularFace(_ now: Double) -> Bool {
        let s = secondsVisible ? Calendar.current.component(.second, from: Date()) : -1
        if s != homeModLastSecond { homeModLastSecond = s; return true }
        return false
    }

    /// 第四輪：玻璃磚後面的背景＝程式生成的硬邊幾何桌布（Faces/HomeModularWallpaper.swift；綠、紫、藍、琥珀）
    private func homeBackdrop(_ g: CGContext) {
        HomeModularWallpaper.draw(g, HomeModularWallpaper.current)
    }

    private func homePlatters() -> [GlyphShape] {
        let M = Self.M
        func rr(_ r: CGRect) -> GlyphShape { GlyphShape(path: continuousRoundedRect(r, radius: M.radius)) }
        return [rr(M.tile(0, 0, w: 2, h: 2)), GlyphShape(path: CGPath(ellipseIn: M.tile(2, 0), transform: nil)),
                rr(M.tile(2, 1)), rr(M.tile(0, 2)), rr(M.tile(1, 2)), rr(M.tile(2, 2))]
    }

    private func drawHomeModularStatic(_ g: CGContext, _ t: HomeTiles) {
        let white = NSColor.white, M = Self.M
        // 1. 硬邊幾何桌布（第四輪：取代原本的漸層＋玻璃緞帶）
        homeBackdrop(g)
        // 2. 玻璃磚：背景＝桌布。第三輪照官方：清玻璃（幾乎不霜）、看得出後面圖樣被折射，亮邊細、面色只亮一點
        let px = 1024   // 第三輪：磚裡看得清背景，背景要全解析度
        let tint = HomeModularWallpaper.current
        let behind = makeImage(px, px) { c in
            c.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
            self.homeBackdrop(c)
        }
        let frost = blurredBackdrop(behind, sigma: 1.2, key: "homemod-frost4|\(tint.rawValue)|\(Int(renderPixelScale * 100))")
        // 2.0 faceglass：磚跟著桌布色系染色（官方：桌布什麼色系、磚就偏什麼色）——染五階的中間色（purple 對官方校準 ΔE00 4.7）
        let glassTint = srgb(HomeModularWallpaper.palette(tint)[2]).withAlphaComponent(0.55)
        drawLiquidGlass(g, homePlatters(), key: "homemod-platters|\(tint.rawValue)", clear: frost, frosted: frost, params: .platter, tint: glassTint)

        // 3. 內容（1024 座標，位置量自官方：見 HPTokens.HomeModular）
        let big = M.tile(0, 0, w: 2, h: 2)
        if let hint = t.hint {
            // 沒資料：不畫大數字，中間放一句小字提示
            let f = FaceType.sf(46, .semibold, mono: false)
            let lines = Self.wrap(hint, f, big.width - 120, maxLines: 3)
            let y0 = big.minY + 320 - CGFloat(lines.count - 1) * 30
            let hintC = nightRedActive ? NSColor(white: 0.78, alpha: 1) : white.withAlphaComponent(0.78)   // 2.0 P07：夜間不透明（HIG-WID-185）
            for (i, l) in lines.enumerated() { centeredText(g, l, f, x: big.midX, y: y0 + CGFloat(i) * 60, color: hintC) }
        } else {
            let numShape = GlyphShape(t.number, font: FaceType.sfv(M.numberSize, wght: 500, mono: false), kern: -4)
            let nb = numShape.ink
            // 大數字：基線離磚頂 375、水平置中
            fillShape(g, numShape.moved(big.midX - nb.midX, big.minY + M.numberBaseline - nb.maxY), white)
        }
        for (cx, dir) in [(big.minX + M.chevronInset, "chevron.down"), (big.maxX - M.chevronInset, "chevron.up")] {
            drawSymbol(g, dir, in: CGRect(x: cx - 30, y: big.minY + M.chevronY - 18, width: 60, height: 36), color: white, weight: .semibold)
        }
        label(g, t.thermoLabel, t.thermoSub, in: big)
        // 玻璃鐘的刻度：12 根一樣長
        let clock = M.tile(2, 0), cc = CGPoint(x: clock.midX, y: clock.midY), R = clock.width / 2
        g.setStrokeColor(white.cgColor); g.setLineWidth(R * M.tickWidth); g.setLineCap(.round)
        for i in 0..<12 {
            let a = CGFloat(i) * .pi / 6
            g.move(to: CGPoint(x: cc.x + sin(a) * R * M.tickInner, y: cc.y - cos(a) * R * M.tickInner))
            g.addLine(to: CGPoint(x: cc.x + sin(a) * R * M.tickOuter, y: cc.y - cos(a) * R * M.tickOuter)); g.strokePath()
        }
        // 小磚：符號在上、兩行標籤在下
        func icon(_ r: CGRect, _ sym: String, _ h: CGFloat, weight: NSFont.Weight) {
            drawSymbol(g, sym, in: CGRect(x: r.midX - h / 2, y: r.minY + M.iconCenterFromTop - h / 2, width: h, height: h), color: white, weight: weight)
        }
        let scene = M.tile(2, 1), light = M.tile(0, 2), lock = M.tile(1, 2), mine = M.tile(2, 2)
        icon(scene, "moon.stars.fill", 78, weight: .regular)
        label(g, t.sceneName, t.sceneSub, in: scene)
        icon(light, t.lightSymbol, 92, weight: .regular)
        label(g, t.lightLabel, t.lightSub, in: light)
        icon(lock, t.lockSymbol, 92, weight: .semibold)
        label(g, t.lockLabel, t.lockSub, in: lock)
        // 膠囊那一塊
        label(g, "HomePlay", L("homemod.watching", "看着你"), in: mine)
    }

    private func centeredText(_ g: CGContext, _ s: String, _ f: NSFont, x: CGFloat, y: CGFloat, color: NSColor) {
        let w = Typo.width(s, f)
        drawLeft(g, s, font: f, x: x - w / 2, y: y, color: color)
    }

    /// 磚底部的兩行標籤：名稱 semibold 白、狀態 semibold 白 60%（官方兩行同字級）
    private func label(_ g: CGContext, _ title: String, _ sub: String, in r: CGRect) {
        let M = Self.M, maxW = min(r.width - 40, 560)
        let f = FaceType.sf(M.labelSize, .semibold, mono: false)
        centeredText(g, Self.clipped(title, f, maxW), f, x: r.midX, y: r.maxY - M.titleFromBottom, color: .white)
        // 2.0 P07：夜間（整面轉紅）副標改不透明灰階——半透明的紅會在紅底上糊掉層級（HIG-WID-185）
        let subC = nightRedActive ? NSColor(white: CGFloat(M.subAlpha), alpha: 1) : NSColor.white.withAlphaComponent(M.subAlpha)
        centeredText(g, Self.clipped(sub, f, maxW), f, x: r.midX, y: r.maxY - M.subFromBottom, color: subC)
    }

    // MARK: 指針

    private func drawHomeModularClockHands(_ g: CGContext) {
        let clock = Self.M.tile(2, 0), c = CGPoint(x: clock.midX, y: clock.midY), R = clock.width / 2
        let comp = Calendar.current.dateComponents([.hour, .minute, .second], from: Self.displayDate)
        let s = Double(comp.second ?? 0), m = Double(comp.minute ?? 0) + s / 60, h = Double((comp.hour ?? 0) % 12) + m / 60
        // 長度、粗細是半徑的比例（官方：時針到 0.5 R、分針到 0.82 R、白色圓頭，靠圓心一小段細頸）
        func hand(_ deg: Double, neck: CGFloat, len: CGFloat, w: CGFloat) {
            let a = CGFloat(deg * .pi / 180), ux = sin(a), uy = -cos(a)
            g.setStrokeColor(NSColor.white.cgColor); g.setLineCap(.round)
            g.setLineWidth(0.03 * R); g.move(to: c); g.addLine(to: CGPoint(x: c.x + ux * neck * R, y: c.y + uy * neck * R)); g.strokePath()
            g.setLineWidth(w * R)
            g.move(to: CGPoint(x: c.x + ux * neck * R, y: c.y + uy * neck * R))
            g.addLine(to: CGPoint(x: c.x + ux * len * R, y: c.y + uy * len * R)); g.strokePath()
        }
        hand(h * 30, neck: 0.1, len: 0.52, w: 0.065)
        hand(m * 6, neck: 0.1, len: 0.84, w: 0.055)
        if secondsVisible {   // 沒人在看時收起秒針
            let sa = CGFloat(s * 6 * .pi / 180)
            g.setStrokeColor(NSColor.white.cgColor); g.setLineWidth(0.014 * R); g.setLineCap(.round)
            g.move(to: CGPoint(x: c.x - sin(sa) * 0.12 * R, y: c.y + cos(sa) * 0.12 * R))
            g.addLine(to: CGPoint(x: c.x + sin(sa) * 0.9 * R, y: c.y - cos(sa) * 0.9 * R)); g.strokePath()
            g.setFillColor(NSColor.white.cgColor); g.fillEllipse(in: CGRect(x: c.x - 0.045 * R, y: c.y - 0.045 * R, width: 0.09 * R, height: 0.09 * R))
        }
    }
}
