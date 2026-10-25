// 世界時鐘（2.0 時鐘：照 macOS 27／iPadOS 27 時鐘 App 的世界時鐘，實拍見 scratchpad/clockref/）：
// 上面一條世界地圖（白天的陸地亮、夜裡暗、晨昏線、每 15° 一條經線、城市橘點＋名字與時間），
// 底下一排城市卡片：類比錶盤（白天白、夜裡黑；秒針連續掃，60 fps）、「城市 時間」「今天 +0 小時」「日出 日落」。
// 第一張是這台 Mac 的時區；卡片比畫面寬時左右捲（滾輪），放手吸到頭或尾。
// 每幀只疊秒針：地圖每分鐘畫一次、卡片每分鐘畫一次（ClockKit.layer），錶盤底與數字也快取。
// 減少動態效果：秒針一秒一跳（0.2 s 交叉淡化）。App 不在畫面上時不要求幀（tick 只有開著才會叫）。

import AppKit

final class WorldClockApp: PetApp {
    let id = "worldclock"
    var title: String { L("app.worldClock", "世界时钟") }
    let icon = AppIcon(color: .black, symbol: "globe", glyph: .white, system: "/System/Applications/Clock.app")
    private var lastSecond = -1

    struct City { let zone: String; let name: () -> String; let lat: Double; let lon: Double }
    static let candidates: [City] = [
        City(zone: "Asia/Taipei", name: { L("city.taipei", "台北") }, lat: 25.03, lon: 121.56),
        City(zone: "America/Los_Angeles", name: { L("city.cupertino", "库比蒂诺") }, lat: 37.32, lon: -122.03),
        City(zone: "America/New_York", name: { L("city.newYork", "纽约") }, lat: 40.71, lon: -74.01),
        City(zone: "Europe/London", name: { L("city.london", "伦敦") }, lat: 51.51, lon: -0.13),
        City(zone: "Asia/Tokyo", name: { L("city.tokyo", "东京") }, lat: 35.68, lon: 139.69),
    ]

    /// 四格：本地＋三個不同時區（本地的城市名用時區 ID 的最後一段，清單裡有就用清單的名字）
    static func cities(local: TimeZone = .current) -> [(TimeZone, String)] {
        let localName = candidates.first { $0.zone == local.identifier }?.name()
            ?? local.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? local.identifier
        var out: [(TimeZone, String)] = [(local, localName)]
        for c in candidates where out.count < 4 {
            guard let tz = TimeZone(identifier: c.zone), tz.identifier != local.identifier,
                  !out.contains(where: { $0.0.secondsFromGMT() == tz.secondsFromGMT() }) else { continue }
            out.append((tz, c.name()))
        }
        return out
    }
    /// 時區 → 經緯度（清單裡的城市才有；本地若不在清單裡就沒有地圖上的點與日出日落）
    static func coordinate(_ tz: TimeZone) -> (lat: Double, lon: Double)? {
        candidates.first { $0.zone == tz.identifier }.map { ($0.lat, $0.lon) }
    }

    // MARK: 狀態

    private var scrollX: CGFloat = 0
    private var snap: Anim?
    private var lastScroll = 0.0
    private var mapLayer: (key: String, img: CGImage)?
    private var cardLayers: [String: CGImage] = [:]
    /// 每分鐘算一次就好的：城市清單、VoiceOver 念的字
    private var citiesMinute = -1
    private var cityCache: [(TimeZone, String)] = []
    private var noteCache: [String: String] = [:]
    /// 減少動態效果：秒針跳到下一秒時從上一秒的位置交叉淡化
    private var jumpAt = 0.0

    func didOpen(now: Double) { scrollX = 0; snap = nil }

    func tick(_ now: Double) -> Bool {
        var dirty = HPComponents.needsFrame(now)
        if let s = snap { scrollX = s.value(now); if s.done(now) { scrollX = s.to; snap = nil }; dirty = true }
        else if lastScroll > 0, now - lastScroll > 0.14 {   // 捲完：吸到最近的頭或尾（Apple 的投射＋臨界阻尼）
            lastScroll = 0
            let stop: CGFloat = scrollX > maxScroll / 2 ? maxScroll : 0
            if abs(stop - scrollX) > 0.5 { var a = Anim(scrollX, spring: AppMotion.appleSmooth); a.retarget(stop, now: now); snap = a; dirty = true }
        }
        if ClockKit.reduceMotion {
            let s = Int(ClockKit.date.timeIntervalSince1970)
            if s != lastSecond { lastSecond = s; jumpAt = now; dirty = true }
            if now - jumpAt < HPMotion.reduceFade + 0.02 { dirty = true }
        } else {
            ClockKit.keepSweeping(now)   // 秒針連續掃：剛操作過 60 fps、之後 30 fps（開著才要，關了就停）
            dirty = true
        }
        return dirty
    }

    // MARK: 版面

    typealias W = HPTokens.WorldClock
    private var mapRect: CGRect { CGRect(x: 0, y: W.mapTop, width: 1024, height: W.mapHeight) }
    private func cardRect(_ i: Int) -> CGRect {
        CGRect(x: AppUI.margin + CGFloat(i) * (W.cardW + W.cardGap) - scrollX, y: W.cardTop, width: W.cardW, height: W.cardH)
    }
    private var maxScroll: CGFloat {
        let n = CGFloat(Self.cities().count)
        return max(0, n * W.cardW + (n - 1) * W.cardGap - AppUI.contentW)
    }

    func handleScroll(_ dy: CGFloat, now: Double) -> Bool {
        guard maxScroll > 0 else { return false }
        snap = nil
        let n = min(maxScroll, max(0, scrollX - dy))
        defer { scrollX = n; lastScroll = now }
        return n != scrollX
    }

    // MARK: 文字

    private func timeText(_ d: Date, _ tz: TimeZone) -> String {
        Face.shortTime(d, timeZone: tz)   // 2.0 depth：時制照系統；不再改共用 formatter 的時區
    }
    /// 「今天 +0 小時」：跟這裡差幾小時、是這裡的昨天／今天／明天
    private func offsetText(_ d: Date, _ tz: TimeZone) -> String {
        let local = TimeZone.current
        let diffH = Double(tz.secondsFromGMT(for: d) - local.secondsFromGMT(for: d)) / 3600
        let n = diffH.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%+d", Int(diffH)) : String(format: "%+.1f", diffH)
        var lc = Calendar(identifier: .gregorian); lc.timeZone = local
        var rc = lc; rc.timeZone = tz
        let a = lc.dateComponents([.year, .month, .day], from: d), b = rc.dateComponents([.year, .month, .day], from: d)
        let la = lc.date(from: a) ?? d, lb = lc.date(from: b) ?? d
        let day: String
        switch lb.compare(la) {
        case .orderedAscending: day = L("worldclock.yesterday", "昨天")
        case .orderedDescending: day = L("worldclock.tomorrow", "明天")
        case .orderedSame: day = L("worldclock.today", "今天")
        }
        return "\(day) \(String(format: L("worldclock.offset", "%@ 小时"), n))"
    }

    // MARK: 畫

    func render(into g: CGContext, face: Face, rect: CGRect, now: Double) {
        let date = ClockKit.date
        let scale = ClockKit.pixelScale(g)
        g.setFillColor(AppUI.bg.cgColor); g.fill(rect)
        let minute = Int(date.timeIntervalSince1970 / 60)
        if citiesMinute != minute { citiesMinute = minute; cityCache = Self.cities(); noteCache = [:] }
        let list = cityCache
        // 地圖（每分鐘一次）
        let mkey = "\(minute)|\(HPTokens.dark)|\(L10n.language.locale.identifier)|\(Int(scale * 100))"
        if mapLayer?.key != mkey {
            let r = mapRect
            mapLayer = ClockKit.layer(size: CGSize(width: r.width, height: r.height), scale: scale) { c in
                let local = CGRect(origin: .zero, size: r.size)
                ClockKit.drawMap(c, in: local, north: Double(W.mapNorth), south: Double(W.mapSouth), date: date)
                drawPins(c, face, list, date: date, in: local)
            }.map { (mkey, $0) }
        }
        if let m = mapLayer { ClockKit.blit(g, m.img, in: mapRect) }
        AppUI.title(g, face, title)
        // 卡片：靜態的部分每分鐘一張，每幀只疊針
        g.saveGState()
        g.clip(to: CGRect(x: 0, y: W.cardTop - 20, width: 1024, height: W.cardH + 40))
        if cardLayers.count > 16 { cardLayers.removeAll() }
        for (i, (tz, name)) in list.enumerated() {
            let r = cardRect(i)
            guard r.maxX > 0, r.minX < 1024 else { continue }
            var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
            let sod = date.timeIntervalSince(cal.startOfDay(for: date))
            let night = isNight(tz, date, secondsOfDay: sod)
            let key = "\(tz.identifier)|\(minute)|\(night)|\(HPTokens.dark)|\(L10n.language.locale.identifier)|\(Int(scale * 100))"
            if cardLayers[key] == nil {
                cardLayers[key] = ClockKit.layer(size: r.size, scale: scale) { c in
                    drawCard(c, face, CGRect(origin: .zero, size: r.size), tz: tz, name: name, date: date, night: night)
                }
            }
            if let img = cardLayers[key] { ClockKit.blit(g, img, in: r) }
            let center = CGPoint(x: r.midX, y: r.minY + W.dialTop + W.dialR)
            drawSecondHands(g, center: center, secondsOfDay: sod, night: night, now: now)
            let note = noteCache[tz.identifier] ?? "\(name)，\(timeText(date, tz))，\(offsetText(date, tz))"
            noteCache[tz.identifier] = note
            HPAX.note(g, r, .text, note, shape: .rounded(W.cardRadius))   // 2.0 P05
        }
        g.restoreGState()
    }

    /// 這個城市現在是不是夜裡（有經緯度就看太陽高度，沒有就 6:00–18:00 算白天）
    private func isNight(_ tz: TimeZone, _ date: Date, secondsOfDay: Double) -> Bool {
        if let c = Self.coordinate(tz) { return ClockKit.altitude(lat: c.lat, lon: c.lon, sun: ClockKit.subsolar(date)) < -0.833 }
        let h = Int(secondsOfDay / 3600)
        return h < 6 || h >= 18
    }

    private func drawSecondHands(_ g: CGContext, center: CGPoint, secondsOfDay t: Double, night: Bool, now: Double) {
        guard ClockKit.reduceMotion else {
            ClockKit.drawHands(g, center: center, radius: W.dialR, secondsOfDay: t, night: night); return
        }
        // 一秒一跳：上一秒淡出、這一秒淡入
        let p = CGFloat(min(1, (now - jumpAt) / HPMotion.reduceFade))
        if p < 1 {
            g.saveGState(); g.setAlpha(1 - p); ClockKit.drawHands(g, center: center, radius: W.dialR, secondsOfDay: floor(t) - 1, night: night); g.restoreGState()
        }
        g.saveGState(); g.setAlpha(p); ClockKit.drawHands(g, center: center, radius: W.dialR, secondsOfDay: floor(t), night: night); g.restoreGState()
    }

    /// 一張城市卡（不含針）：圓角卡、錶盤、「城市 時間」、「今天 +0 小時」、日出日落
    private func drawCard(_ c: CGContext, _ face: Face, _ r: CGRect, tz: TimeZone, name: String, date: Date, night: Bool) {
        c.addPath(continuousRoundedRect(r, radius: W.cardRadius)); c.setFillColor(W.card.cgColor); c.fillPath()
        let ctr = CGPoint(x: r.midX, y: r.minY + W.dialTop + W.dialR)
        if let img = ClockKit.dialFace(face, radius: W.dialR, night: night, scale: ClockKit.pixelScale(c)) {
            ClockKit.blit(c, img, in: CGRect(x: ctr.x - W.dialR, y: ctr.y - W.dialR, width: 2 * W.dialR, height: 2 * W.dialR))
        }
        let maxW = r.width - 28
        let l1 = "\(name) \(timeText(date, tz))"
        let f1 = AppUI.fitted(l1, size: 32, weight: .semibold, maxWidth: maxW, minScale: 0.6)
        AppUI.center(face, c, Face.clipped(l1, f1, maxW), f1, cx: r.midX, y: r.minY + W.line1, AppUI.label)
        let l2 = offsetText(date, tz), f2 = AppUI.fitted(l2, size: 28, weight: .regular, maxWidth: maxW)
        AppUI.center(face, c, Face.clipped(l2, f2, maxW), f2, cx: r.midX, y: r.minY + W.line2, AppUI.secondary)
        // 日出、日落（符號＋時間）
        guard let co = Self.coordinate(tz), let st = ClockKit.sunTimes(lat: co.lat, lon: co.lon, day: date, tz: tz) else { return }
        let rise = timeText(st.rise, tz), set = timeText(st.set, tz)
        var f3 = AppUI.font(28)
        let sym: CGFloat = 30, gap: CGFloat = 6, mid: CGFloat = 18
        var total = 2 * (sym + gap) + mid + Typo.width(rise, f3) + Typo.width(set, f3)
        if total > maxW { f3 = AppUI.font(max(21, 28 * (maxW - 2 * (sym + gap) - mid) / (total - 2 * (sym + gap) - mid))); total = 2 * (sym + gap) + mid + Typo.width(rise, f3) + Typo.width(set, f3) }
        var x = r.midX - total / 2
        let y = r.minY + W.line3
        for (s, t) in [("sunrise.fill", rise), ("sunset.fill", set)] {
            face.drawSymbol(c, s, in: CGRect(x: x, y: y - sym * 0.82, width: sym, height: sym), color: AppUI.secondary, weight: .regular)
            x += sym + gap
            AppUI.left(face, c, t, f3, x: x, y: y, AppUI.secondary)
            x += Typo.width(t, f3) + mid
        }
    }

    /// 地圖上的城市：橘點＋粗體城市名＋小字時間（字放在點的右邊，放不下就放左邊）
    private func drawPins(_ c: CGContext, _ face: Face, _ list: [(TimeZone, String)], date: Date, in r: CGRect) {
        let nf = AppUI.font(30, .bold), tf = AppUI.font(26, .medium)
        let ink: NSColor = HPTokens.dark ? .white : .black
        var placed: [CGRect] = []
        for (tz, name) in list {
            guard let co = Self.coordinate(tz) else { continue }
            let p = ClockKit.mapPoint(lat: co.lat, lon: co.lon, in: r, north: Double(W.mapNorth), south: Double(W.mapSouth))
            let dot: CGFloat = 16
            c.setFillColor(HPTokens.Clock.second.cgColor)
            c.fillEllipse(in: CGRect(x: p.x - dot / 2, y: p.y - dot / 2, width: dot, height: dot))
            let t = timeText(date, tz)
            let w = max(Typo.width(name, nf), Typo.width(t, tf))
            var box = CGRect(x: p.x + dot / 2 + 8, y: p.y - 22, width: w, height: 62)
            if box.maxX > r.maxX - 12 { box.origin.x = p.x - dot / 2 - 8 - w }
            // 跟前一個字重疊：往下挪一格
            while placed.contains(where: { $0.intersects(box) }) && box.maxY < r.maxY - 70 { box.origin.y += 64 }
            placed.append(box)
            c.saveGState()
            c.setShadow(offset: CGSize(width: 0, height: -1), blur: 6, color: (HPTokens.dark ? NSColor.black : NSColor.white).withAlphaComponent(0.8).cgColor)
            face.drawLeft(c, name, font: nf, x: box.minX, y: box.minY + 22, color: ink)
            face.drawLeft(c, t, font: tf, x: box.minX, y: box.minY + 54, color: ink)
            c.restoreGState()
        }
    }
}
