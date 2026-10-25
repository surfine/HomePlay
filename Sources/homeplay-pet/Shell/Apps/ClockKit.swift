// 2.0 時鐘三件 App（闹钟、计时器、世界时钟）共用的零件：時間來源、每幀請求、類比錶盤、數字捲動（numericText）、
// 日夜（太陽直射點、晨昏線）、世界地圖。全部是我們自己畫的（Core Graphics）；只有世界地圖的陸地剪影在執行時從
// /System/Applications/Clock.app 的 Assets.car 讀（map_mac，CoreUI），讀不到就只畫經線格——不複製進版本庫。
//
// 對照（2026-10-25 實拍 macOS 27 時鐘 App，scratchpad/clockref/）：
// - 世界時鐘：上面一條世界地圖（海是黑的、白天的陸地 #4A 灰、夜裡的陸地 #19 灰、一條淺灰的晨昏線、每 15° 一條很淡的經線、
//   城市是橘點＋粗體城市名＋小字時間），底下一排卡片：白錶盤（夜裡黑）、12 個粗數字、黑時分針（中心一小段細）、
//   橘色細秒針連續掃（不是一秒一跳）、中心黑點＋橘點；卡片上「城市 時間」「今天 +0 小時」「日出 日落」。
// - 計時器：官方 HomeView timer.png（60 根刻度、過去的暗棕、剩下的橘、大字剩餘時間＋「15 MIN」）。
// 動態照 hv-research/markview.md 的 R5／R6：數字只動有變的那幾位，Spring(0.35, 1.0)，位數之間錯開 33 ms（高位先），
// 倒數時新數字從上面落下（countsDown）；減少動態效果＝0.2 s 交叉淡化、秒針一秒一跳。

import AppKit

// MARK: - Tokens（量自實拍／官方圖，App 裡不寫死數字）

extension HPTokens {
    enum Clock {
        /// 類比錶盤（實拍世界時鐘卡片：R＝120 時數字 cap 高 20、圓心到數字中心 94、分針 106、時針 61、秒針 105＋尾 14、粗針寬 7）
        static let numeralSize: CGFloat = 0.235      // × R
        static let numeralRadius: CGFloat = 0.78
        static let hourLength: CGFloat = 0.51
        static let minuteLength: CGFloat = 0.88
        static let secondLength: CGFloat = 0.90
        static let secondTail: CGFloat = 0.14
        static let stem: CGFloat = 0.14              // 針靠中心那一小段是細的
        static let handWidth: CGFloat = 0.06
        static let stemWidth: CGFloat = 0.026
        static let secondWidth: CGFloat = 0.018
        static let hub: CGFloat = 0.05, hubInner: CGFloat = 0.028
        /// 夜裡的錶盤（黑底白字）與白天的錶盤
        static let dayDial = NSColor.white, nightDial = srgb(0x0B0B0C)
        /// 秒針與城市點：系統橘（深色版，跟計時器同色）
        static var second: NSColor { HPTokens.orange }

        /// 數字捲動：Spring(0.35, 1.0)、位數錯開 33 ms、最多 150 ms（markview R6）；位移＝cap 高 × 0.9
        static let roll = Spring(damping: 1, response: 0.35)
        static let rollStagger = 0.033, rollStaggerMax = 0.15
        static let rollTravel: CGFloat = 0.9
    }

    /// 世界時鐘（1024 畫布）：地圖滿版寬、緯度 78°N～56°S；卡片寬 260、間距 20，第四張從右邊露出一截（可以左右捲）
    enum WorldClock {
        static let mapTop: CGFloat = 196
        static let mapNorth: CGFloat = 78, mapSouth: CGFloat = -56
        static var mapHeight: CGFloat { 1024 * (mapNorth - mapSouth) / 360 }
        static let cardTop: CGFloat = 598
        static let cardW: CGFloat = 260, cardH: CGFloat = 378, cardGap: CGFloat = 20
        static let cardRadius: CGFloat = 44
        static let dialR: CGFloat = 86, dialTop: CGFloat = 26
        static let line1: CGFloat = 248, line2: CGFloat = 292, line3: CGFloat = 334
        /// 地圖顏色（深色＝實拍；淺色是推斷：同一套明暗關係換成淺灰）
        static var ocean: NSColor { dark ? .black : srgb(0xE9E9ED) }
        static var landDay: NSColor { dark ? srgb(0x4A4A4C) : srgb(0xFFFFFF) }
        static var landNight: NSColor { dark ? srgb(0x1B1B1C) : srgb(0xBDBDC3) }
        static var oceanNight: NSColor { dark ? .black : srgb(0xD3D3D9) }
        static var terminator: NSColor { dark ? NSColor(white: 0.78, alpha: 1) : NSColor(white: 0.45, alpha: 1) }
        static var meridian: NSColor { dark ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.05) }
        static var card: NSColor { dark ? srgb(0x2C2C2E) : srgb(0xE5E5EA) }   // 淺色：白錶盤要放在淺灰卡上才看得出圓（推斷）
    }
}

enum ClockKit {
    // MARK: 時間來源

    /// 快照逐格：HOMEPLAY_CLOCK_T=秒 → 時間凍結在「開機那一刻＋t 秒」；有 --time／--demo-official 時從那個時刻起算
    static let frozenT: Double? = ProcessInfo.processInfo.environment["HOMEPLAY_CLOCK_T"].flatMap(Double.init)
    private static let launchWall = Date().timeIntervalSinceReferenceDate
    private static let launchUptime = CACurrentMediaTime()
    /// 牆上時間（計時器的帳用它）。凍結時：開機設定那半秒內（快照旗標加示範計時器）是 t＝0，之後才是 t——
    /// 這樣 --demo-official 的計時器剩 10:56 −t，逐格拍得到倒數
    static var wall: Double {
        guard let t = frozenT else { return Date().timeIntervalSinceReferenceDate }
        return launchWall + (CACurrentMediaTime() - launchUptime > 0.6 ? t : 0)
    }
    /// 錶盤上顯示的時刻（含小數秒）
    static var date: Date {
        if let o = snapshotDateOverride { return o.addingTimeInterval(frozenT ?? 0) }
        return Date(timeIntervalSinceReferenceDate: wall)
    }
    static var reduceMotion: Bool { HPMotion.reduceMotion }

    // MARK: 每幀（主循環的 isAnimating 問這裡：秒針、刻度圈、數字捲動在動時跑 60 fps，停了就讓它降回閒置幀率）

    nonisolated(unsafe) private static var liveUntil = 0.0
    nonisolated(unsafe) private static var sweepUntil = 0.0
    static func keepLive(_ seconds: Double = 0.1) { liveUntil = max(liveUntil, CACurrentMediaTime() + seconds) }
    static func live(_ now: Double) -> Bool { now < liveUntil }
    /// 秒針連續掃：有人在旁邊或剛操作過（Shell.lastActive 8 秒內）跑 60 fps；沒人看時 30 fps——R＝86 的秒針尖每秒走 8 px，30 fps 一步 0.27 px，
    /// 看不出差別，CPU 少一半（實測見回報）。HOMEPLAY_CLOCK_HZ=60／30 強制
    static func keepSweeping(_ now: Double) {
        sweepUntil = max(sweepUntil, now + 0.2)
        if forceHz.map({ $0 >= 60 }) ?? (now - Shell.lastActive < 8) { keepLive(0.2) }
    }
    static let forceHz = ProcessInfo.processInfo.environment["HOMEPLAY_CLOCK_HZ"].flatMap(Int.init)
    /// 主循環的 targetHz 問這裡：秒針在掃但沒有其他動畫時要幾 fps（nil＝不需要）
    static func hz(_ now: Double) -> Int? { now < sweepUntil ? (forceHz ?? 30) : nil }

    // MARK: 圖層快取（靜態的部分畫一次，每幀只疊會動的針）

    /// 在一張跟畫布同座標（左上原點、y 往下）的點陣上畫好，回傳 CGImage
    static func layer(size: CGSize, scale: CGFloat, _ draw: (CGContext) -> Void) -> CGImage? {
        let w = max(1, Int((size.width * scale).rounded())), h = max(1, Int((size.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: scale, y: -scale)
        draw(ctx)
        return ctx.makeImage()
    }
    /// 把 layer() 畫好的圖貼回畫布（畫布是翻過來的座標，貼的時候再翻一次）
    static func blit(_ g: CGContext, _ img: CGImage, in r: CGRect) {
        g.saveGState(); g.translateBy(x: r.minX, y: r.maxY); g.scaleBy(x: 1, y: -1)
        // 快取圖照畫布的像素倍率畫好，貼回去是 1:1：不必高品質重取樣（每幀省幾毫秒）
        let px = pixelScale(g)
        g.interpolationQuality = abs(CGFloat(img.width) - r.width * px) < 1.5 ? .none : .high
        g.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height)); g.restoreGState()
    }
    /// 畫布實際的像素倍率（快取圖照這個解析度畫，貼回去才不糊）
    static func pixelScale(_ g: CGContext) -> CGFloat {
        let t = g.userSpaceToDeviceSpaceTransform
        return max(0.5, min(3, (abs(t.a) + abs(t.d)) / 2))
    }

    // MARK: - 類比錶盤

    /// 錶盤的靜態部分（底＋12 個數字），每個半徑×日夜×倍率快取一張
    nonisolated(unsafe) private static var dialCache: [String: CGImage] = [:]
    static func dialFace(_ face: Face, radius R: CGFloat, night: Bool, scale: CGFloat) -> CGImage? {
        let key = "\(Int(R * 10))|\(night)|\(Int(scale * 100))|\(HPTokens.dark)"
        if let c = dialCache[key] { return c }
        typealias T = HPTokens.Clock
        let img = layer(size: CGSize(width: 2 * R, height: 2 * R), scale: scale) { c in
            let ctr = CGPoint(x: R, y: R)
            c.setFillColor((night ? T.nightDial : T.dayDial).cgColor)
            c.fillEllipse(in: CGRect(x: 0, y: 0, width: 2 * R, height: 2 * R))
            if night {   // 黑錶盤在深灰卡片上：一圈很淡的緣，免得跟卡片糊在一起
                c.setStrokeColor(NSColor(white: 1, alpha: 0.12).cgColor); c.setLineWidth(1.5)
                c.strokeEllipse(in: CGRect(x: 0.75, y: 0.75, width: 2 * R - 1.5, height: 2 * R - 1.5))
            }
            let ink = night ? NSColor.white : NSColor.black
            let nf = FaceType.sf(R * T.numeralSize, .semibold, mono: false)
            for n in 1...12 {
                let a = CGFloat(n) / 12 * 2 * .pi, rr = R * T.numeralRadius
                let s = String(n)
                face.drawLeft(c, s, font: nf, x: ctr.x + sin(a) * rr - Typo.width(s, nf) / 2, y: ctr.y - cos(a) * rr + nf.capHeight / 2, color: ink)
            }
        }
        if dialCache.count > 24 { dialCache.removeAll() }
        dialCache[key] = img
        return img
    }

    /// 一個類比錶盤：secondsOfDay＝那個時區當天的秒數（含小數；減少動態效果時取整數＝一秒一跳）
    static func analogDial(_ g: CGContext, _ face: Face, center c: CGPoint, radius R: CGFloat, secondsOfDay t0: Double, night: Bool) {
        typealias T = HPTokens.Clock
        let t = reduceMotion ? floor(t0) : t0
        if let img = dialFace(face, radius: R, night: night, scale: pixelScale(g)) {
            blit(g, img, in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
        }
        drawHands(g, center: c, radius: R, secondsOfDay: t, night: night)
    }

    static func drawHands(_ g: CGContext, center c: CGPoint, radius R: CGFloat, secondsOfDay t: Double, night: Bool) {
        typealias T = HPTokens.Clock
        let ink = (night ? NSColor.white : NSColor.black).cgColor
        let s = t.truncatingRemainder(dividingBy: 60), m = (t / 60).truncatingRemainder(dividingBy: 60), h = (t / 3600).truncatingRemainder(dividingBy: 12)
        g.saveGState()
        g.setLineCap(.round)
        func line(_ a: CGFloat, from r0: CGFloat, to r1: CGFloat, width: CGFloat, color: CGColor) {
            g.setStrokeColor(color); g.setLineWidth(width)
            g.move(to: CGPoint(x: c.x + sin(a) * r0, y: c.y - cos(a) * r0))
            g.addLine(to: CGPoint(x: c.x + sin(a) * r1, y: c.y - cos(a) * r1)); g.strokePath()
        }
        for (frac, len) in [(h / 12, T.hourLength), (m / 60, T.minuteLength)] {
            let a = CGFloat(frac) * 2 * .pi
            line(a, from: 0, to: R * T.stem, width: R * T.stemWidth, color: ink)
            line(a, from: R * T.stem, to: R * len, width: R * T.handWidth, color: ink)
        }
        g.setFillColor(ink); g.fillEllipse(in: CGRect(x: c.x - R * T.hub, y: c.y - R * T.hub, width: 2 * R * T.hub, height: 2 * R * T.hub))
        let sa = CGFloat(s / 60) * 2 * .pi
        line(sa, from: -R * T.secondTail, to: R * T.secondLength, width: max(1.6, R * T.secondWidth), color: T.second.cgColor)
        g.setFillColor(T.second.cgColor)
        g.fillEllipse(in: CGRect(x: c.x - R * T.hubInner, y: c.y - R * T.hubInner, width: 2 * R * T.hubInner, height: 2 * R * T.hubInner))
        g.restoreGState()
    }

    // MARK: - 數字捲動（SwiftUI 的 .contentTransition(.numericText)）

    /// 一串字（通常是時間）：字變了，只有變的那幾個字元捲動——舊的往外滑出、淡出、帶一點垂直模糊，新的從另一邊滑進；
    /// 沒變的字元跟著新的字寬滑到新位置（比例數字「1」比較窄）。靠右對齊時從右邊配對字元（秒數跳動時右緣不動）
    enum Align { case left, right, center }
    private struct Roll {
        var shown: String
        var old: String = ""
        var start: Double = -100
        var down = true
    }
    nonisolated(unsafe) private static var rolls: [String: Roll] = [:]
    static func forget(_ key: String) { rolls[key] = nil }

    /// x＝對齊點；down＝倒數（新數字從上面落下）。prior：快照凍結（HOMEPLAY_ANIM=roll:t）時當作「t 秒前從 prior 換過來」
    static func roll(_ g: CGContext, _ face: Face, key: String, text: String, font: NSFont, x: CGFloat, baseline y: CGFloat,
                     align: Align, color: NSColor, down: Bool = true, prior: String? = nil, now: Double = CACurrentMediaTime()) {
        var st = rolls[key] ?? Roll(shown: text)
        if let t = HPMotion.frozen("roll"), let prior, prior != text {
            st = Roll(shown: text, old: prior, start: now - t, down: down)
        } else if st.shown != text {
            st.old = st.shown; st.shown = text; st.start = now; st.down = down
        }
        rolls[key] = st
        let newC = text.map(String.init), oldC = st.old.map(String.init)
        func advances(_ cs: [String]) -> [CGFloat] { cs.map { Typo.width($0, font) } }
        let newW = advances(newC), oldW = advances(oldC)
        func origin(_ total: CGFloat) -> CGFloat {
            switch align { case .left: return x; case .right: return x - total; case .center: return x - total / 2 }
        }
        func positions(_ w: [CGFloat]) -> [CGFloat] {
            var out: [CGFloat] = [], cx = origin(w.reduce(0, +))
            for a in w { out.append(cx); cx += a }
            return out
        }
        let newX = positions(newW), oldX = positions(oldW)
        let elapsed = now - st.start
        let animating = elapsed < 1.2 && !oldC.isEmpty
        guard animating else {
            face.drawLeft(g, text, font: font, x: origin(newW.reduce(0, +)), y: y, color: color)
            return
        }
        typealias T = HPTokens.Clock
        // 從對齊的那一邊配對字元（靠右：最右邊的對最右邊的）
        let n = max(newC.count, oldC.count)
        func idx(_ k: Int, _ count: Int) -> Int? {   // k：從配對那一側數過來第 k 個
            let i = align == .left ? k : count - 1 - k
            return i >= 0 && i < count ? i : nil
        }
        // 有變的位置，由高位（左邊）往低位排，錯開 33 ms
        var changed: [Int] = []
        for k in 0..<n {
            let a = idx(k, newC.count).map { newC[$0] }, b = idx(k, oldC.count).map { oldC[$0] }
            if a != b { changed.append(k) }
        }
        let order = changed.sorted { align == .left ? $0 < $1 : $0 > $1 }   // 高位先
        let step = order.count > 1 ? min(T.rollStagger, T.rollStaggerMax / Double(order.count - 1)) : 0
        let travel = font.capHeight * T.rollTravel
        let dir: CGFloat = st.down ? 1 : -1      // 倒數：舊的往下掉、新的從上面落下
        var still = false
        // 沒變的字元：位置跟著整串的總寬滑過去
        let moveP = progress(elapsed)
        if moveP < 0.999 { still = true }
        for k in 0..<n {
            guard let i = idx(k, newC.count) else { continue }
            if changed.contains(k) { continue }
            let ox = idx(k, oldC.count).map { oldX[$0] } ?? newX[i]
            face.drawLeft(g, newC[i], font: font, x: ox + (newX[i] - ox) * moveP, y: y, color: color)
        }
        for k in changed {
            let delay = Double(order.firstIndex(of: k) ?? 0) * step
            let p = progress(elapsed - delay)
            if p < 0.999 { still = true }
            if reduceMotion {
                if let j = idx(k, oldC.count), p < 1 { face.drawLeft(g, oldC[j], font: font, x: oldX[j], y: y, color: color.withAlphaComponent(color.alphaComponent * (1 - p))) }
                if let i = idx(k, newC.count) { face.drawLeft(g, newC[i], font: font, x: newX[i], y: y, color: color.withAlphaComponent(color.alphaComponent * p)) }
                continue
            }
            let blur = sin(.pi * min(1, max(0, p))) * font.pointSize * 0.018   // 只在移動中有一點垂直模糊（markview P9）
            func ghosted(_ s: String, _ gx: CGFloat, _ gy: CGFloat, _ alpha: CGFloat) {
                guard alpha > 0.01 else { return }
                let c = color.withAlphaComponent(color.alphaComponent * alpha)
                if blur > 0.5 {
                    let gc = color.withAlphaComponent(color.alphaComponent * alpha * 0.35)
                    face.drawLeft(g, s, font: font, x: gx, y: gy - blur, color: gc)
                    face.drawLeft(g, s, font: font, x: gx, y: gy + blur, color: gc)
                    face.drawLeft(g, s, font: font, x: gx, y: gy, color: c.withAlphaComponent(c.alphaComponent * 0.75))
                } else {
                    face.drawLeft(g, s, font: font, x: gx, y: gy, color: c)
                }
            }
            if let j = idx(k, oldC.count) { ghosted(oldC[j], oldX[j], y + dir * travel * p, (1 - p) * (1 - p)) }
            if let i = idx(k, newC.count) { ghosted(newC[i], newX[i], y - dir * travel * (1 - p), min(1, p * 1.25)) }
        }
        if still, HPMotion.frozen("roll") == nil { keepLive(0.05); Anim.keepAlive(0.05) }
    }
    private static func progress(_ t: Double) -> CGFloat {
        guard t > 0 else { return 0 }
        if reduceMotion { return CGFloat(min(1, t / HPMotion.reduceFade)) }
        return min(1, max(0, HPTokens.Clock.roll.value(from: 0, to: 1, velocity: 0, t: CGFloat(t)).x))
    }

    // MARK: - 太陽（NOAA 的近似式，精度約 0.01°，畫晨昏線、決定日出日落與錶盤日夜綽綽有餘）

    struct Sun { var lat: Double; var lon: Double }
    /// 太陽直射點（度）
    static func subsolar(_ date: Date) -> Sun {
        let d = date.timeIntervalSince1970 / 86400 - 10957.5          // 距 J2000.0 的日數
        let rad = Double.pi / 180
        let g = (357.529 + 0.98560028 * d) * rad
        let q = 280.459 + 0.98564736 * d
        let L = (q + 1.915 * sin(g) + 0.020 * sin(2 * g)) * rad
        let e = (23.439 - 0.00000036 * d) * rad
        let decl = asin(sin(e) * sin(L))
        let ra = atan2(cos(e) * sin(L), cos(L)) / rad
        let gmst = 280.46061837 + 360.98564736629 * d
        var lon = (ra - gmst).truncatingRemainder(dividingBy: 360)
        if lon > 180 { lon -= 360 }; if lon < -180 { lon += 360 }
        return Sun(lat: decl / rad, lon: lon)
    }
    /// 某地的太陽高度角（度）
    static func altitude(lat: Double, lon: Double, sun: Sun) -> Double {
        let r = Double.pi / 180
        let h = (lon - sun.lon) * r
        return asin(sin(lat * r) * sin(sun.lat * r) + cos(lat * r) * cos(sun.lat * r) * cos(h)) / r
    }
    /// 晨昏線：每個經度上太陽高度＝0 的緯度
    static func terminatorLat(lon: Double, sun: Sun) -> Double {
        let r = Double.pi / 180
        let decl = abs(sun.lat) < 0.01 ? 0.01 : sun.lat
        return atan(-cos((lon - sun.lon) * r) / tan(decl * r)) / r
    }
    /// 當地當天的日出、日落（太陽中心 −0.833°）；極晝／極夜回 nil
    static func sunTimes(lat: Double, lon: Double, day: Date, tz: TimeZone) -> (rise: Date, set: Date)? {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let noonLocal = cal.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
        var times: [Date] = []
        for sign in [-1.0, 1.0] {
            // 迭代兩次：先用當地正午的太陽位置算時角，再用算出的時刻重算
            var t = noonLocal
            for _ in 0..<3 {
                let sun = subsolar(t), r = Double.pi / 180
                let cosH = (sin(-0.833 * r) - sin(lat * r) * sin(sun.lat * r)) / (cos(lat * r) * cos(sun.lat * r))
                guard abs(cosH) <= 1 else { return nil }
                let H = acos(cosH) / r                                       // 度
                // 太陽過中天的時刻：直射點經度＝當地經度
                var dl = (sun.lon - lon).truncatingRemainder(dividingBy: 360)
                if dl > 180 { dl -= 360 }; if dl < -180 { dl += 360 }
                let transitShift = dl / 15 * 3600                            // 直射點還要多久走到這裡（太陽往西走 15°/h）
                let transit = t.addingTimeInterval(transitShift)
                t = transit.addingTimeInterval(sign * H / 15 * 3600)
            }
            times.append(t)
        }
        return (times[0], times[1])
    }

    // MARK: - 世界地圖（系統時鐘 App 的陸地剪影，執行時讀；4208×1928，等距圓柱、180°W～180°E、約 84°N～80.9°S）

    static let mapNorth: Double = 84, mapSouth: Double = -80.9
    nonisolated(unsafe) private static var mapTried = false
    nonisolated(unsafe) private static var mapImage: CGImage?
    /// 自檢用：強制走自繪的退路（當作系統地圖讀不到）
    nonisolated(unsafe) static var forceFallback = false
    static var worldMap: CGImage? {
        if forceFallback { return nil }
        if !mapTried { mapTried = true; mapImage = loadSystemMap() }
        return mapImage
    }
    /// 系統地圖有沒有讀到（報告與自檢用）
    static var usingSystemMap: Bool { worldMap != nil }
    /// CoreUI 的 CUICatalog 讀 Clock.app 的 Assets.car（map_mac 是 mac idiom＝7 的 PDF 向量圖，CoreUI 會轉成點陣）。
    /// 私有類別：找不到類別或方法就回 nil（畫面照樣有晨昏線與經線，只是沒有陸地）
    private static func loadSystemMap() -> CGImage? {
        if ProcessInfo.processInfo.environment["HOMEPLAY_NO_SYSTEM_MAP"] == "1" { return nil }
        let car = "/System/Applications/Clock.app/Contents/Resources/Assets.car"
        guard FileManager.default.fileExists(atPath: car),
              dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_NOW) != nil,
              let cls = NSClassFromString("CUICatalog") as? NSObject.Type else { return nil }
        let initSel = NSSelectorFromString("initWithURL:error:"), imgSel = NSSelectorFromString("imageWithName:scaleFactor:deviceIdiom:")
        guard cls.instancesRespond(to: initSel), cls.instancesRespond(to: imgSel),
              let raw = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject else { return nil }
        typealias InitF = @convention(c) (AnyObject, Selector, NSURL, UnsafeMutablePointer<NSError?>?) -> AnyObject?
        guard let cat = unsafeBitCast(raw.method(for: initSel), to: InitF.self)(raw, initSel, NSURL(fileURLWithPath: car), nil) as? NSObject else { return nil }
        typealias ImgF = @convention(c) (AnyObject, Selector, NSString, CGFloat, Int) -> AnyObject?
        guard let named = unsafeBitCast(cat.method(for: imgSel), to: ImgF.self)(cat, imgSel, "map_mac", 2, 7) as? NSObject else { return nil }
        let cgSel = NSSelectorFromString("image")
        guard named.responds(to: cgSel) else { return nil }
        typealias CGF = @convention(c) (AnyObject, Selector) -> Unmanaged<CGImage>?
        guard let img = unsafeBitCast(named.method(for: cgSel), to: CGF.self)(named, cgSel)?.takeUnretainedValue(), img.width > 1000 else { return nil }
        // 只要陸地的形狀（alpha）：縮成 1600 寬、取出 alpha 當灰階遮罩（白＝陸地），之後每分鐘重畫地圖才便宜
        let w = 1600, h = Int((CGFloat(w) * CGFloat(img.height) / CGFloat(img.width)).rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = ctx.data else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let src = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var alpha = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) { alpha[i] = src[i * 4 + 3] }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: 0), provider: CGDataProvider(data: Data(alpha) as CFData)!, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    /// 畫一條世界地圖（等距圓柱）到 rect：海、陸地（白天亮、夜裡暗，晨昏線上 0.6° 的柔邊）、每 15° 一條經線、晨昏線。
    /// north／south＝rect 上下緣的緯度
    static func drawMap(_ g: CGContext, in r: CGRect, north: Double, south: Double, date: Date) {
        typealias W = HPTokens.WorldClock
        let sun = subsolar(date)
        func xOf(_ lon: Double) -> CGFloat { r.minX + CGFloat((lon + 180) / 360) * r.width }
        func yOf(_ lat: Double) -> CGFloat { r.minY + CGFloat((north - lat) / (north - south)) * r.height }
        g.saveGState()
        g.clip(to: r)
        // 夜的遮罩：低解析的格子算太陽高度（柔邊＝民用晨昏前的 0.6°），放大時線性內插
        let gw = 360, gh = max(2, Int(Double(gw) * (north - south) / 360))
        var px = [UInt8](repeating: 0, count: gw * gh)
        for j in 0..<gh {
            let lat = north - (Double(j) + 0.5) / Double(gh) * (north - south)
            for i in 0..<gw {
                let lon = -180 + (Double(i) + 0.5) / Double(gw) * 360
                let alt = altitude(lat: lat, lon: lon, sun: sun)
                let k = max(0, min(1, (0.3 - alt) / 0.6))       // 1＝夜
                px[j * gw + i] = UInt8(k * 255)
            }
        }
        let night = CGImage(width: gw, height: gh, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: gw, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGBitmapInfo(rawValue: 0), provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil,
                            shouldInterpolate: true, intent: .defaultIntent)
        // 海
        g.setFillColor(W.ocean.cgColor); g.fill(r)
        if let night, W.oceanNight != W.ocean {
            g.saveGState(); clipMask(g, night, r); g.setFillColor(W.oceanNight.cgColor); g.fill(r); g.restoreGState()
        }
        // 陸地：系統圖的緯度範圍換到這個 rect
        if let land = worldMap {
            let full = CGRect(x: r.minX, y: yOf(mapNorth), width: r.width, height: yOf(mapSouth) - yOf(mapNorth))
            g.saveGState(); clipMask(g, land, full)
            g.setFillColor(W.landDay.cgColor); g.fill(r)
            if let night { clipMask(g, night, r); g.setFillColor(W.landNight.cgColor); g.fill(r) }
            g.restoreGState()
        }
        // 經線（時區格）：每 15°
        g.setFillColor(W.meridian.cgColor)
        for k in 1..<24 { g.fill(CGRect(x: (xOf(-180 + Double(k) * 15)).rounded() - 0.75, y: r.minY, width: 1.5, height: r.height)) }
        // 晨昏線
        let path = CGMutablePath()
        for i in 0...360 {
            let lon = -180 + Double(i)
            let p = CGPoint(x: xOf(lon), y: yOf(terminatorLat(lon: lon, sun: sun)))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        g.addPath(path); g.setStrokeColor(W.terminator.cgColor); g.setLineWidth(2.5); g.setLineJoin(.round); g.strokePath()
        g.restoreGState()
    }
    /// 畫布是翻過來的：遮罩圖的第 0 列要在 rect 的上緣
    private static func clipMask(_ g: CGContext, _ mask: CGImage, _ r: CGRect) {
        g.translateBy(x: 0, y: r.minY + r.maxY); g.scaleBy(x: 1, y: -1)
        g.clip(to: r, mask: mask)
        g.scaleBy(x: 1, y: -1); g.translateBy(x: 0, y: -(r.minY + r.maxY))
    }
    /// 經緯度 → 地圖上的點
    static func mapPoint(lat: Double, lon: Double, in r: CGRect, north: Double, south: Double) -> CGPoint {
        CGPoint(x: r.minX + CGFloat((lon + 180) / 360) * r.width, y: r.minY + CGFloat((north - lat) / (north - south)) * r.height)
    }
}

// MARK: - 自檢

enum ClockKitSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        // 2026-06-21 12:00 UTC：夏至前後，直射點約 23.4°N、經度約 0°（均時差 −1.7 分鐘）
        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 21; c.hour = 12; c.timeZone = TimeZone(identifier: "UTC")
        let d = Calendar(identifier: .gregorian).date(from: c)!
        let s = ClockKit.subsolar(d)
        check(abs(s.lat - 23.43) < 0.1 && abs(s.lon) < 1.5, "時鐘：夏至正午直射點在北回歸線、本初子午線附近（\(String(format: "%.2f, %.2f", s.lat, s.lon))）")
        check(ClockKit.altitude(lat: s.lat, lon: s.lon, sun: s) > 89.9, "時鐘：直射點的太陽高度 90°")
        let tl = ClockKit.terminatorLat(lon: s.lon + 90, sun: s)
        check(abs(ClockKit.altitude(lat: tl, lon: s.lon + 90, sun: s)) < 0.01, "時鐘：晨昏線上太陽高度 0")
        // 台北夏至日出約 5:05、日落約 18:47
        if let tz = TimeZone(identifier: "Asia/Taipei"), let st = ClockKit.sunTimes(lat: 25.03, lon: 121.56, day: d, tz: tz) {
            var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
            let r = cal.dateComponents([.hour, .minute], from: st.rise), e = cal.dateComponents([.hour, .minute], from: st.set)
            let rm = (r.hour ?? 0) * 60 + (r.minute ?? 0), em = (e.hour ?? 0) * 60 + (e.minute ?? 0)
            check(abs(rm - (5 * 60 + 5)) <= 4 && abs(em - (18 * 60 + 47)) <= 4, "時鐘：台北夏至日出 \(r.hour ?? 0):\(r.minute ?? 0)、日落 \(e.hour ?? 0):\(e.minute ?? 0)")
        } else { check(false, "時鐘：台北日出日落算得出來") }
        check(ClockKit.sunTimes(lat: 80, lon: 0, day: d, tz: TimeZone(identifier: "UTC")!) == nil, "時鐘：北極圈內夏至沒有日落（極晝）")
        // 計時器暫停：停住剩下的秒數、不會到點、繼續後從剩下的接著倒數；暫停的不當 primary
        var b = TimerBook()
        let a = b.add(seconds: 60, label: "a", now: 1000), z = b.add(seconds: 120, label: "z", now: 1000)
        b.pause(a, now: 1010)
        check(b.timer(a)?.left(5000) == 50 && b.expire(now: 1100).map(\.id) == [] && b.timer(a) != nil, "計時器：暫停的不會到點，剩 50 秒停住")
        check(b.primary?.id == z && b.sorted.map(\.id) == [z, a], "計時器：暫停的不鏡射到錶面、排在在跑的後面")
        b.resume(a, now: 2000)
        check(abs((b.timer(a)?.left(2010) ?? 0) - 40) < 1e-9 && b.expire(now: 2050).map(\.id) == [z, a], "計時器：繼續後從剩下的接著倒數、到點")
        // 系統地圖讀不到：自動退回自繪（海＋晨昏線照畫，畫面不是空的）；讀得到時陸地跟退路不一樣
        func shot() -> [UInt8] {
            guard let img = ClockKit.layer(size: CGSize(width: 180, height: 67), scale: 1, { c in
                ClockKit.drawMap(c, in: CGRect(x: 0, y: 0, width: 180, height: 67), north: 78, south: -56, date: d)
            }), let data = img.dataProvider?.data as Data? else { return [] }
            return [UInt8](data)
        }
        ClockKit.forceFallback = true
        let fb = shot()
        ClockKit.forceFallback = false
        check(!fb.isEmpty && Set(stride(from: 0, to: fb.count, by: 4).map { fb[$0] }).count > 1, "時鐘：強制退路時地圖照樣畫得出來（晨昏線、經線）")
        if ClockKit.usingSystemMap {
            check(shot() != fb, "時鐘：讀到系統地圖時畫出陸地（跟退路不同）")
        }
    }
}
