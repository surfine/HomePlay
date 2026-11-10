// 世界時鐘 App 與「世界」錶面共用的兩樣零件（稿：scratchpad/worldclock，512 設計單位 ×2＝1024 畫布）：
//
// 1. 車站鐘錶盤（盤面忠實照 iOS 6 iPad 世界時鐘：白天白盤黑刻度、晚上黑盤白刻度，沒有數字；錶盤本身不玻璃化）：
//    停走秒針（58.5 秒走完一圈、在 12 點停 1.5 秒，分針整分才跳一格、時針跟著分針）、60 條分刻度＋12 條粗時刻度、
//    方頭微收窄的時分針、實心紅細秒針＋尖端實心紅圓盤＋中心紅圓（白色小孔）；指針一層淡投影，盤面白→淺灰徑向漸層、外緣細灰邊。
//    錶盤的靜態部分照半徑×日夜×倍率快取，每幀只畫三根針。減少動態效果：秒針一秒跳一格（沒有回彈），分針照舊整分跳。
// 2. 1960 年代點陣世界地圖：72 欄×29 列（5° 一格，90°N～55°S），每個陸地格一個圓點；
//    白天、夜裡照「那一格的太陽高度」決定亮暗（太陽直射點含季節赤緯，晨昏線是彎的，−3°～+3° 柔和過渡）。

import AppKit

enum StationClock {
    /// 秒針與珠子的紅
    static let red = srgb(0xD7261E)
    /// 停走秒針：這麼多秒走完一圈，剩下的在 12 點停住
    static let sweep = 58.5

    struct Angles: Equatable { var hour: Double; var minute: Double; var second: Double }   // 度，12 點＝0、順時針

    /// 某時區的當地時、分、秒（秒含小數）：用 secondsFromGMT(for:)，夏令時間照那一刻算
    static func localParts(_ date: Date, _ tz: TimeZone) -> (h: Int, m: Int, s: Double) {
        let t = date.timeIntervalSince1970 + Double(tz.secondsFromGMT(for: date))
        let day = t - floor(t / 86400) * 86400
        return (Int(day / 3600), Int(day.truncatingRemainder(dividingBy: 3600) / 60), day.truncatingRemainder(dividingBy: 60))
    }
    /// 秒針角度：58.5 秒掃完一圈、之後停在 12 點；減少動態效果時一秒一格
    static func secondAngle(_ s: Double, reduceMotion: Bool) -> Double {
        reduceMotion ? floor(s) * 6 : min(s / sweep, 1) * 360
    }
    /// 分針只走整數分；時針＝整點 30° ＋ 分鐘 × 0.5°（分鐘只算一次）
    static func angles(h: Int, m: Int, s: Double, reduceMotion: Bool) -> Angles {
        Angles(hour: Double(h % 12) * 30 + Double(m) * 0.5, minute: Double(m) * 6, second: secondAngle(s, reduceMotion: reduceMotion))
    }
    static func angles(_ date: Date, _ tz: TimeZone, reduceMotion: Bool = HPMotion.reduceMotion) -> Angles {
        let p = localParts(date, tz)
        return angles(h: p.h, m: p.m, s: p.s, reduceMotion: reduceMotion)
    }

    // MARK: 錶盤（比例以錶盤半徑 R 為單位，照 iOS 6 iPad 世界時鐘截圖量的；錶盤本身不玻璃化、不放字）

    enum Ratio {
        /// 刻度：外緣 0.96R，方頭；時刻度長 0.24R、寬 0.075R，分刻度長 0.075R、寬 0.025R
        static let tickOuter: CGFloat = 0.96
        static let hourTick: (len: CGFloat, w: CGFloat) = (0.24, 0.075)
        static let minuteTick: (len: CGFloat, w: CGFloat) = (0.075, 0.025)
        /// 時分針：方頭、往尖端微收窄（w0 根部、w1 尖端），尾巴過中心 0.24R
        static let hour: (tail: CGFloat, tip: CGFloat, w0: CGFloat, w1: CGFloat) = (0.24, 0.62, 0.105, 0.09)
        static let minute: (tail: CGFloat, tip: CGFloat, w0: CGFloat, w1: CGFloat) = (0.24, 0.93, 0.085, 0.07)
        /// 秒針：細桿＋尖端實心紅圓盤＋中心紅圓（中間一個白色小孔）
        static let second: (tail: CGFloat, tip: CGFloat, w: CGFloat) = (0.30, 0.62, 0.018)
        static let disc: (at: CGFloat, r: CGFloat) = (0.65, 0.085)
        static let hub: CGFloat = 0.033, hole: CGFloat = 0.01
        /// 指針的淡投影（往下、黑 28%）
        static let shadow: CGFloat = 0.015
        /// 外緣細灰邊（錶盤外再一圈 0.022R）
        static let edge: CGFloat = 0.022
    }
    static func ink(night: Bool) -> NSColor { night ? srgb(0xF2F2F2) : srgb(0x1B1B1B) }

    // MARK: 靜態錶盤（快取）

    nonisolated(unsafe) private static var cache: [String: CGImage] = [:]
    /// 錶盤的靜態部分（細邊、盤面、刻度）畫成一張圖：邊長 2R(1+edge)，圓心在正中
    static func faceImage(radius R: CGFloat, night: Bool, scale: CGFloat) -> CGImage? {
        let key = "\(Int(R * 10))|\(night)|\(Int(scale * 100))|\(HPAccessibility.increaseContrast)"
        if let c = cache[key] { return c }
        if cache.count > 24 { cache.removeAll() }
        let side = 2 * R * (1 + Ratio.edge)
        let img = ClockKit.layer(size: CGSize(width: side, height: side), scale: scale) { c in
            drawFace(c, center: CGPoint(x: side / 2, y: side / 2), radius: R, night: night)
        }
        cache[key] = img
        return img
    }
    static func faceRect(center o: CGPoint, radius R: CGFloat) -> CGRect {
        let h = R * (1 + Ratio.edge)
        return CGRect(x: o.x - h, y: o.y - h, width: 2 * h, height: 2 * h)
    }

    static func drawFace(_ c: CGContext, center o: CGPoint, radius R: CGFloat, night: Bool) {
        let ic = HPAccessibility.increaseContrast
        func circle(_ r: CGFloat) -> CGRect { CGRect(x: o.x - r, y: o.y - r, width: 2 * r, height: 2 * r) }
        // 外緣細灰邊
        let edge = night ? NSColor(white: 1, alpha: ic ? 0.4 : 0.14) : NSColor(white: 0, alpha: ic ? 0.45 : 0.16)
        c.setFillColor(edge.cgColor); c.fillEllipse(in: circle(R * (1 + Ratio.edge)))
        // 盤面：白→淺灰（夜裡深灰→近黑）的徑向漸層，中心偏上
        c.saveGState(); c.addEllipse(in: circle(R)); c.clip()
        let cols = night ? [srgb(0x2A2A2C), srgb(0x0C0C0D)] : [srgb(0xFFFFFF), srgb(0xE6E6E6)]
        if let gr = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: cols.map(\.cgColor) as CFArray, locations: [0, 1]) {
            let p = CGPoint(x: o.x, y: o.y - 0.263 * R)
            c.drawRadialGradient(gr, startCenter: p, startRadius: 0, endCenter: p, endRadius: 1.36 * R, options: [.drawsAfterEndLocation])
        }
        // 2026-11-09：拿掉「上半部水平光弧」——原本照 iOS 6 世界時鐘截圖補的一條 0.35 白線，
        // 在我們的深色盤面上讀起來像一條畫錯的圓弧（使用者截圖指認）。盤面的徑向漸層留著，玻璃感靠它。
        c.restoreGState()
        // 刻度：60 條，每五條一根粗長的時刻度
        c.setFillColor(ink(night: night).cgColor)
        for i in 0..<60 {
            let t = i % 5 == 0 ? Ratio.hourTick : Ratio.minuteTick
            c.saveGState(); c.translateBy(x: o.x, y: o.y); c.rotate(by: CGFloat(i) * .pi / 30)
            c.fill(CGRect(x: -t.w * R / 2, y: -Ratio.tickOuter * R, width: t.w * R, height: t.len * R))
            c.restoreGState()
        }
    }

    /// 三根針（每幀畫）：方頭微收窄的時分針、紅細秒針＋尖端紅圓盤、中心紅圓與白色小孔；整組一層淡投影
    static func drawHands(_ g: CGContext, center o: CGPoint, radius R: CGFloat, angles a: Angles, night: Bool) {
        g.saveGState()
        g.clip(to: CGRect(x: o.x - R, y: o.y - R, width: 2 * R, height: 2 * R).insetBy(dx: -0.1 * R, dy: -0.1 * R))   // 透明層只開錶盤那麼大
        g.setShadow(offset: CGSize(width: 0, height: Ratio.shadow * R), blur: Ratio.shadow * R * 2, color: NSColor(white: 0, alpha: 0.28).cgColor)
        g.beginTransparencyLayer(auxiliaryInfo: nil)
        func taper(_ deg: Double, _ h: (tail: CGFloat, tip: CGFloat, w0: CGFloat, w1: CGFloat), _ color: NSColor) {
            g.saveGState(); g.translateBy(x: o.x, y: o.y); g.rotate(by: CGFloat(deg * .pi / 180))
            let p = CGMutablePath()
            p.move(to: CGPoint(x: -h.w0 * R / 2, y: h.tail * R)); p.addLine(to: CGPoint(x: h.w0 * R / 2, y: h.tail * R))
            p.addLine(to: CGPoint(x: h.w1 * R / 2, y: -h.tip * R)); p.addLine(to: CGPoint(x: -h.w1 * R / 2, y: -h.tip * R)); p.closeSubpath()
            g.addPath(p); g.setFillColor(color.cgColor); g.fillPath()
            g.restoreGState()
        }
        let ink = ink(night: night)
        taper(a.hour, Ratio.hour, ink)
        taper(a.minute, Ratio.minute, ink)
        g.saveGState(); g.translateBy(x: o.x, y: o.y); g.rotate(by: CGFloat(a.second * .pi / 180))
        g.setFillColor(red.cgColor)
        let s = Ratio.second, d = Ratio.disc
        g.fill(CGRect(x: -s.w * R / 2, y: -s.tip * R, width: s.w * R, height: (s.tip + s.tail) * R))
        g.fillEllipse(in: CGRect(x: -d.r * R, y: -d.at * R - d.r * R, width: 2 * d.r * R, height: 2 * d.r * R))
        let hub = Ratio.hub * R
        g.fillEllipse(in: CGRect(x: -hub, y: -hub, width: 2 * hub, height: 2 * hub))
        g.restoreGState()
        g.endTransparencyLayer()
        g.restoreGState()
        let hole = Ratio.hole * R
        g.setFillColor(NSColor(white: 1, alpha: 0.85).cgColor); g.fillEllipse(in: CGRect(x: o.x - hole, y: o.y - hole, width: 2 * hole, height: 2 * hole))
    }
}

// MARK: - 點陣世界地圖

enum DotMap {
    /// 陸地遮罩：每格 5°，第 0 列＝90°N～85°N，第 0 欄＝180°W～175°W
    static let mask: [String] = [
        "........................................................................",
        "...................#####..#####.........................................",
        ".............#...####..#########.......#...............###..............",
        "...........####..####....#######..................#.##########..#.......",
        "#..#################.##..#####.........#################################",
        "...###############...##...##.........###################################",
        "....#....#########..####...........#.##.########################...##...",
        "..........###############.........##.############################..#....",
        "...........############.#..........#############################........",
        "...........###########............########.####################.........",
        "...........##########.............##.#...###################.#..........",
        "............########..............#####.#..#################............",
        ".............####..#.............###########################............",
        "...............##................###############..#########.............",
        "...............###...............##############....##..###..............",
        "..................#..............#############.....#....##..............",
        "....................#####........#############..........................",
        "....................######............#######..........##.##............",
        "....................########..........######............#.#....##.......",
        "....................#########.........######....................##......",
        "....................#########.........######..................#.........",
        ".....................#######..........######.#..............#####.......",
        "......................######...........####..#.............#######......",
        "......................####.............####................########.....",
        "......................####..............##.................########.....",
        ".....................####.......................................##......",
        ".....................##.................................................",
        ".....................##.................................................",
        ".....................#..................................................",
    ]
    static let cols = 72
    static var rows: Int { mask.count }
    private static let land: [[Bool]] = mask.map { $0.map { $0 == "#" } }

    static func isLand(row: Int, col: Int) -> Bool {
        guard row >= 0, row < land.count else { return false }
        return land[row][((col % cols) + cols) % cols]
    }
    /// 經緯度落在哪一格
    static func cell(lat: Double, lon: Double) -> (row: Int, col: Int) {
        (Int(floor((90 - lat) / 5)), ((Int(floor((lon + 180) / 5)) % cols) + cols) % cols)
    }
    /// 那一格或旁邊一圈有陸地（城市點落在海岸附近也算）
    static func nearLand(lat: Double, lon: Double) -> Bool {
        let c = cell(lat: lat, lon: lon)
        return (-1...1).contains { dr in (-1...1).contains { dc in isLand(row: c.row + dr, col: c.col + dc) } }
    }
    /// 經緯度 → 畫布上的點；origin＝第 0 列第 0 欄那一格的左上角，step＝一格的邊長
    static func point(lat: Double, lon: Double, origin: CGPoint, step: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + CGFloat((lon + 180) / 5) * step, y: origin.y + CGFloat((90 - lat) / 5) * step)
    }
    /// 白天的比例（0 夜、1 白天）：太陽高度 −3°～+3° 之間柔和過渡
    static func daylight(lat: Double, lon: Double, sun: ClockKit.Sun) -> CGFloat {
        CGFloat(max(0, min(1, (ClockKit.altitude(lat: lat, lon: lon, sun: sun) + 3) / 6)))
    }
    /// 每個陸地格畫一個圓點，白天用 day 色、夜裡用 night 色
    static func draw(_ g: CGContext, origin: CGPoint, step: CGFloat, radius r: CGFloat, date: Date, day: NSColor, night: NSColor) {
        let sun = ClockKit.subsolar(date)
        let a = day.usingColorSpace(.sRGB) ?? day, b = night.usingColorSpace(.sRGB) ?? night
        for row in 0..<rows {
            let lat = 90 - (Double(row) + 0.5) * 5
            for col in 0..<cols where land[row][col] {
                let k = daylight(lat: lat, lon: -180 + (Double(col) + 0.5) * 5, sun: sun)
                func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { y + (x - y) * k }
                g.setFillColor(CGColor(srgbRed: mix(a.redComponent, b.redComponent), green: mix(a.greenComponent, b.greenComponent),
                                       blue: mix(a.blueComponent, b.blueComponent), alpha: mix(a.alphaComponent, b.alphaComponent)))
                let x = origin.x + (CGFloat(col) + 0.5) * step, y = origin.y + (CGFloat(row) + 0.5) * step
                g.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
            }
        }
    }
    /// 城市點：橘色光暈＋白邊橘點
    static func pin(_ g: CGContext, _ p: CGPoint, halo: CGFloat, dot: CGFloat, ring: CGFloat, haloAlpha: CGFloat) {
        let orange = srgb(0xFF8D28)
        g.setFillColor(orange.withAlphaComponent(haloAlpha).cgColor)
        g.fillEllipse(in: CGRect(x: p.x - halo, y: p.y - halo, width: 2 * halo, height: 2 * halo))
        let r = CGRect(x: p.x - dot, y: p.y - dot, width: 2 * dot, height: 2 * dot)
        g.setFillColor(orange.cgColor); g.fillEllipse(in: r)
        g.setStrokeColor(NSColor.white.cgColor); g.setLineWidth(ring); g.strokeEllipse(in: r)
    }
}

// MARK: - 自檢

enum StationClockSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        let s = { (x: Double) in StationClock.secondAngle(x, reduceMotion: false) }
        check(s(0) == 0 && abs(s(29.25) - 180) < 1e-9 && s(58.5) == 360 && s(59.9) == 360,
              "車站鐘：停走秒針 0 s＝0°、29.25 s＝180°、58.5 s 到頂、59.9 s 停在 360°")   // l10n-ignore
        check(StationClock.secondAngle(59.9, reduceMotion: true) == 354 && StationClock.secondAngle(12.7, reduceMotion: true) == 72,
              "車站鐘：減少動態效果時秒針一秒一格")   // l10n-ignore
        let a = StationClock.angles(h: 10, m: 9, s: 59.9, reduceMotion: false), b = StationClock.angles(h: 10, m: 10, s: 0, reduceMotion: false)
        check(a.minute == 54 && b.minute == 60 && b.minute - a.minute == 6, "車站鐘：分針整分才跳一格（10:09:59.9 還在 54°）")   // l10n-ignore
        check(a.hour == 304.5 && StationClock.angles(h: 15, m: 30, s: 0, reduceMotion: false).hour == 105
              && StationClock.angles(h: 0, m: 0, s: 0, reduceMotion: false).hour == 0, "車站鐘：時針＝整點×30°＋分×0.5°（分鐘不算兩次）")   // l10n-ignore
        // 夏令時間：紐約 7 月 UTC−4、1 月 UTC−5；同一個 UTC 16:00 在紐約是 12 點與 11 點
        func utc(_ m: Int, _ d: Int, _ h: Int) -> Date {
            var c = DateComponents(); c.year = 2026; c.month = m; c.day = d; c.hour = h; c.timeZone = TimeZone(identifier: "UTC")
            return Calendar(identifier: .gregorian).date(from: c)!
        }
        let ny = TimeZone(identifier: "America/New_York")!
        check(StationClock.localParts(utc(7, 1, 16), ny).h == 12 && StationClock.localParts(utc(1, 15, 16), ny).h == 11
              && StationClock.localParts(utc(1, 15, 16), TimeZone(identifier: "Asia/Taipei")!).h == 0,
              "車站鐘：夏令時間（紐約夏天 UTC−4、冬天 UTC−5；台北跨日到 0 點）")   // l10n-ignore
        // 晝夜：夏至 12:00 UTC 直射點經度約 0°（跟稿的簡化式 (12−UTC 時)×15 差在均時差以內），那裡白天、對蹠點夜裡
        let noon = utc(6, 21, 12), sun = ClockKit.subsolar(noon)
        check(abs(sun.lon - (12 - 12) * 15) < 4 && DotMap.daylight(lat: 23, lon: sun.lon, sun: sun) == 1
              && DotMap.daylight(lat: -23, lon: sun.lon + 180, sun: sun) == 0 && DotMap.daylight(lat: 80, lon: sun.lon + 180, sun: sun) == 1,
              "點陣地圖：晝夜照太陽直射經度與赤緯（夏至北極圈內午夜也是白天）")   // l10n-ignore
        let sun2 = ClockKit.subsolar(utc(1, 15, 4))
        check(abs(sun2.lon - (12 - 4) * 15) < 5, "點陣地圖：UTC 04:00 直射經度約 120°E")   // l10n-ignore
        // 點陣網格對位：遮罩 72×29、台北、倫敦、紐約（還有東京、雪梨）落在陸地點附近；點的座標跟格子中心一致
        check(DotMap.mask.count == 29 && DotMap.mask.allSatisfy { $0.count == DotMap.cols }, "點陣地圖：遮罩 72 欄 × 29 列")   // l10n-ignore
        check([(25.03, 121.56), (51.51, -0.13), (40.71, -74.01), (35.68, 139.69), (-33.87, 151.21)].allSatisfy { DotMap.nearLand(lat: $0.0, lon: $0.1) }
              && !DotMap.nearLand(lat: -40, lon: -140), "點陣地圖：台北、倫敦、紐約、東京、雪梨落在陸地點附近，南太平洋沒有")   // l10n-ignore
        let p = DotMap.point(lat: 90 - 2.5, lon: -180 + 2.5, origin: CGPoint(x: 16, y: 16), step: 6)
        check(p == CGPoint(x: 19, y: 19), "點陣地圖：城市點與格子中心同一套座標（稿 ox 16、step 6 → 第一格中心 19,19）")   // l10n-ignore
    }
}
