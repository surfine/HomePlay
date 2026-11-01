// 世界時鐘（2.0 時鐘：照 macOS 27／iPadOS 27 時鐘 App 的世界時鐘，實拍見 scratchpad/clockref/）：
// 上面一條世界地圖（白天的陸地亮、夜裡暗、晨昏線、每 15° 一條經線、城市橘點＋名字與時間），
// 底下一排城市卡片：類比錶盤（白天白、夜裡黑；秒針連續掃，60 fps）、「城市 時間」「今天 +0 小時」「日出 日落」。
// 第一張是這台 Mac 的時區；卡片比畫面寬時左右捲（滾輪），放手吸到頭或尾。
// 每幀只疊秒針：地圖每分鐘畫一次、卡片每分鐘畫一次（ClockKit.layer），錶盤底與數字也快取。
// 減少動態效果：秒針一秒一跳（0.2 s 交叉淡化）。App 不在畫面上時不要求幀（tick 只有開著才會叫）。
// 城市清單可增刪排序（語音優先，HomeView 沒有鍵盤）：清單尾端的「＋ 加入城市」卡→聽寫城市名→最多三張候選卡點一個加入；
// 長按城市卡出小選單「移到最前面」「移除」（本地卡固定第一個、沒有選單）。清單存 UserDefaults（worldclock.cities），快照／示範不讀不寫。

import AppKit

final class WorldClockApp: PetApp {
    let id = "worldclock"
    var title: String { L("app.worldClock", "世界时钟") }
    let icon = AppIcon(color: .black, symbol: "globe", glyph: .white, system: "/System/Applications/Clock.app")
    private var lastSecond = -1

    /// also：同一個時區的別名（洛杉磯、舊金山都落在庫比蒂諾的太平洋時間）——只用來比對，卡上顯示 name
    struct City { let zone: String; let name: () -> String; let lat: Double; let lon: Double; var also: [() -> String] = [] }
    /// 前五個是原本的預設（預設清單照這個順序挑）；後面是常用城市，可以用說的加進清單
    static let candidates: [City] = [
        City(zone: "Asia/Taipei", name: { L("city.taipei", "台北") }, lat: 25.03, lon: 121.56),
        City(zone: "America/Los_Angeles", name: { L("city.cupertino", "库比蒂诺") }, lat: 37.32, lon: -122.03,
             also: [{ L("city.losAngeles", "洛杉矶") }, { L("city.sanFrancisco", "旧金山") }]),
        City(zone: "America/New_York", name: { L("city.newYork", "纽约") }, lat: 40.71, lon: -74.01),
        City(zone: "Europe/London", name: { L("city.london", "伦敦") }, lat: 51.51, lon: -0.13),
        City(zone: "Asia/Tokyo", name: { L("city.tokyo", "东京") }, lat: 35.68, lon: 139.69),
        City(zone: "Asia/Hong_Kong", name: { L("city.hongKong", "香港") }, lat: 22.32, lon: 114.17),
        City(zone: "Asia/Shanghai", name: { L("city.shanghai", "上海") }, lat: 31.23, lon: 121.47),
        City(zone: "Asia/Singapore", name: { L("city.singapore", "新加坡") }, lat: 1.35, lon: 103.82),
        City(zone: "Asia/Seoul", name: { L("city.seoul", "首尔") }, lat: 37.57, lon: 126.98),
        City(zone: "Asia/Bangkok", name: { L("city.bangkok", "曼谷") }, lat: 13.76, lon: 100.50),
        City(zone: "Asia/Dubai", name: { L("city.dubai", "迪拜") }, lat: 25.20, lon: 55.27),
        City(zone: "Australia/Sydney", name: { L("city.sydney", "悉尼") }, lat: -33.87, lon: 151.21),
        City(zone: "Europe/Paris", name: { L("city.paris", "巴黎") }, lat: 48.86, lon: 2.35),
        City(zone: "Europe/Berlin", name: { L("city.berlin", "柏林") }, lat: 52.52, lon: 13.40),
        City(zone: "Europe/Moscow", name: { L("city.moscow", "莫斯科") }, lat: 55.76, lon: 37.62),
        City(zone: "America/Vancouver", name: { L("city.vancouver", "温哥华") }, lat: 49.28, lon: -123.12),
        City(zone: "America/Chicago", name: { L("city.chicago", "芝加哥") }, lat: 41.88, lon: -87.63),
        City(zone: "America/Toronto", name: { L("city.toronto", "多伦多") }, lat: 43.65, lon: -79.38),
    ]

    /// 清單裡的城市（本地在第一個）：存過就照使用者存的，沒存過是預設四個（見 WorldClockList）
    static func cities(local: TimeZone = .current) -> [(TimeZone, String)] {
        WorldClockList.ids(local: local).compactMap { id in TimeZone(identifier: id).map { ($0, name(for: $0)) } }
    }
    /// 城市名：清單裡有就用清單的名字（走 L()），沒有（例如本地在清單外）用時區 ID 的最後一段
    static func name(for tz: TimeZone) -> String {
        candidates.first { $0.zone == tz.identifier }?.name()
            ?? tz.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? tz.identifier
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
    /// 現在在哪一層：清單、聽寫、候選、說明（找不到／聽寫失敗）、長按選單（城市卡的序號）
    private enum Mode: Equatable {
        case browse, listening
        case candidates(String, [WorldClockMatch.Hit])
        case message(String)
        case menu(Int)
    }
    private var mode = Mode.browse
    /// 要用到才建（快照與自檢不碰麥克風）
    private var dictationStore: MessagesDictation?
    private var dictation: MessagesDictation {
        if let d = dictationStore { return d }
        let d = MessagesDictation()
        d.onDone = { [weak self] t in self?.heard(t) }
        d.onFail = { [weak self] why in self?.mode = .message(why) }
        dictationStore = d
        return d
    }
    /// 減少動態效果：秒針跳到下一秒時從上一秒的位置交叉淡化
    private var jumpAt = 0.0

    func didOpen(now: Double) {
        scrollX = 0; snap = nil; mode = .browse; reload()
        // 快照旗標：--worldclock-add 直接在「說出城市名稱」；--worldclock-heard <文字> 直接當成聽到這句；--worldclock-menu <序號> 開長按選單
        if let t = AppUI.flagValue("--worldclock-heard") { heard(t) }
        else if AppUI.flag("--worldclock-add") { mode = .listening }
        else if let i = AppUI.flagValue("--worldclock-menu").flatMap(Int.init), i > 0, i < cityCache.count { mode = .menu(i) }   // 長按選單（快照用）
        if let x = AppUI.scrollFlag("--demo-worldclock-scroll") { scrollX = min(x, maxScroll) }
    }
    func didClose() { dictationStore?.cancel(); mode = .browse }
    var showsCloseButton: Bool { mode == .browse }
    func handleBack(now: Double) -> Bool {
        guard mode != .browse else { return false }
        dismiss(); return true
    }

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
    /// 城市卡之後再加一張「加入城市」卡（滿八個就不放）
    private var canAdd: Bool { cityCache.count < WorldClockList.maxCount }
    private var cardCount: Int { cityCache.count + (canAdd ? 1 : 0) }
    private var maxScroll: CGFloat {
        let n = CGFloat(cardCount)
        return max(0, n * W.cardW + (n - 1) * W.cardGap - AppUI.contentW)
    }

    func handleScroll(_ dy: CGFloat, now: Double) -> Bool {
        guard mode == .browse else { return true }   // 浮層開著：吃掉，不讓底下的清單動
        guard maxScroll > 0 else { return false }
        snap = nil
        let n = min(maxScroll, max(0, scrollX - dy))
        defer { scrollX = n; lastScroll = now }
        return n != scrollX
    }

    // MARK: 浮層版面（聽寫、候選、說明共用一塊面板：標題列、三列內容、兩顆按鈕）

    private enum Panel {
        static let pad = HPTokens.Space.l, gap = HPTokens.Space.m, inner = HPTokens.Space.s, rowGap = HPGrid.Rhythm.rowGap
        static let row = HPTokens.Size.row, cta = HPTokens.Size.cta
        static let rows = 3
        static var height: CGFloat { pad * 2 + row + inner + CGFloat(rows) * row + CGFloat(rows - 1) * rowGap + gap + cta }
        static var rect: CGRect { CGRect(x: AppUI.margin, y: HPTokens.contentTop, width: AppUI.contentW, height: height) }
        static var header: CGRect { CGRect(x: rect.minX + pad, y: rect.minY + pad, width: rect.width - 2 * pad, height: row) }
        static func body(_ i: Int) -> CGRect {
            CGRect(x: rect.minX + pad, y: header.maxY + inner + CGFloat(i) * (row + rowGap), width: rect.width - 2 * pad, height: row)
        }
        static func button(_ i: Int) -> CGRect {   // 0＝左（取消）、1＝右（主要）
            let w = (rect.width - 2 * pad - gap) / 2
            return CGRect(x: rect.minX + pad + CGFloat(i) * (w + gap), y: rect.maxY - pad - cta, width: w, height: cta)
        }
    }
    /// 長按選單的列：本地後面第一張已經是最前面，不放「移到最前面」
    private func menuRows(_ i: Int) -> [(title: String, symbol: String, destructive: Bool)] {
        var rows: [(String, String, Bool)] = []
        if i > 1 { rows.append((L("worldclock.moveFirst", "移到最前面"), "arrow.up.to.line", false)) }
        rows.append((L("worldclock.remove", "移除"), "trash", true))
        return rows
    }
    private func menuPanel(_ i: Int) -> CGRect { SBUI.menuPanel(anchor: cardRect(i), rows: menuRows(i).count, sizes: false) }
    private func menuRowRect(_ i: Int, _ k: Int) -> CGRect {
        let p = menuPanel(i)
        return CGRect(x: p.minX + SBUI.menuInset, y: p.minY + SBUI.menuInset + CGFloat(k) * (SBUI.menuRow + SBUI.menuRowGap),
                      width: p.width - 2 * SBUI.menuInset, height: SBUI.menuRow)
    }

    // MARK: 動作

    /// 重讀清單（增刪排序之後、打開時）：城市快取、VoiceOver 字、地圖上的點都作廢
    private func reload() {
        cityCache = Self.cities(); noteCache = [:]; mapLayer = nil
        citiesMinute = Int(ClockKit.date.timeIntervalSince1970 / 60)
        scrollX = min(scrollX, maxScroll)
    }
    private func dismiss() { dictationStore?.cancel(); mode = .browse }

    private func startListening() {
        mode = .listening
        if !WorldClockList.isDemo { dictation.start() }   // 快照與示範：只畫「在聽」，不開麥克風
    }
    /// 聽完：比城市；沒聽到字或比不到就說明＋「再說一次」
    private func heard(_ t: String) {
        let text = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { mode = .message(L("msg.dictation.empty", "没有听到内容")); return }
        let hits = WorldClockMatch.find(text)
        mode = hits.isEmpty ? .message(String(format: L("worldclock.notFound", "找不到“%@”"), text)) : .candidates(text, hits)
    }
    private func add(_ zone: String) {
        let ids = WorldClockList.ids()
        if let next = WorldClockList.adding(zone, to: ids) { WorldClockList.save(next) }
        mode = .browse; reload()
        var a = Anim(scrollX, spring: AppMotion.appleSmooth); a.retarget(maxScroll, now: CACurrentMediaTime()); snap = a   // 捲到新的那張
    }

    func handleLongPress(_ p: CGPoint, face: Face, now: Double) -> Bool {
        guard mode == .browse else { return false }
        for i in 1..<max(1, cityCache.count) where cardRect(i).contains(p) {   // 本地卡（第 0 張）沒有選單
            mode = .menu(i); return true
        }
        return false
    }

    func handleTap(_ p: CGPoint, face: Face, now: Double) -> Bool {
        switch mode {
        case .browse:
            guard p.y >= W.cardTop, p.y <= W.cardTop + W.cardH, canAdd, cardRect(cityCache.count).contains(p) else { return false }
            startListening(); return true
        case .listening:
            if AppUI.hit(Panel.button(0), p) { dismiss() }
            else if AppUI.hit(Panel.button(1), p) { if dictationStore?.active == true { dictation.finish() } else { dismiss() } }
            return true
        case .candidates(_, let hits):
            let have = Set(WorldClockList.ids())
            for (i, h) in hits.enumerated() where AppUI.hit(Panel.body(i), p, pad: 0) && !have.contains(h.zone) { add(h.zone); return true }
            if AppUI.hit(Panel.button(0), p) { dismiss() } else if AppUI.hit(Panel.button(1), p) { startListening() }
            return true
        case .message:
            if AppUI.hit(Panel.button(0), p) { dismiss() } else if AppUI.hit(Panel.button(1), p) { startListening() }
            return true
        case .menu(let i):
            let rows = menuRows(i)
            if let k = rows.indices.first(where: { menuRowRect(i, $0).contains(p) }) {
                let ids = WorldClockList.ids()
                if rows[k].destructive { WorldClockList.save(WorldClockList.removing(at: i, from: ids)) }
                else { WorldClockList.save(WorldClockList.movingToFront(at: i, in: ids)) }
                reload()
            }
            mode = .browse; return true
        }
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
        if citiesMinute != minute { reload(); citiesMinute = minute }
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
        for (i, (tz, name)) in list.enumerated() { drawCityCard(g, face, i, tz, name, date: date, minute: minute, scale: scale, now: now, note: mode == .browse) }
        if canAdd { drawAddCard(g, face, cardRect(list.count)) }
        g.restoreGState()
        switch mode {
        case .browse: break
        case .menu(let i): drawMenu(g, face, i, date: date, minute: minute, scale: scale, now: now)
        default: drawOverlay(g, face, now: now, date: date)
        }
    }

    /// 一張城市卡：靜態的部分（每分鐘一張快取）＋每幀的針＋VoiceOver 的字
    private func drawCityCard(_ g: CGContext, _ face: Face, _ i: Int, _ tz: TimeZone, _ name: String, date: Date, minute: Int, scale: CGFloat, now: Double, note: Bool) {
        let r = cardRect(i)
        guard r.maxX > 0, r.minX < 1024 else { return }
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
        guard note else { return }
        let text = noteCache[tz.identifier] ?? "\(name)，\(timeText(date, tz))，\(offsetText(date, tz))"
        noteCache[tz.identifier] = text
        HPAX.note(g, r, .text, text, shape: .rounded(W.cardRadius))   // 2.0 P05
    }

    /// 清單最後一張：「＋ 加入城市」。淡填色（不疊玻璃）、跟城市卡同尺寸；圓的位置跟錶盤一樣
    private func drawAddCard(_ g: CGContext, _ face: Face, _ r: CGRect) {
        guard r.maxX > 0, r.minX < 1024 else { return }
        AppUI.fillRound(g, r, radius: W.cardRadius, color: HPTokens.fill)
        let c = CGPoint(x: r.midX, y: r.minY + W.dialTop + W.dialR)
        g.setFillColor(HPTokens.orange.withAlphaComponent(0.18).cgColor)
        g.fillEllipse(in: CGRect(x: c.x - W.dialR, y: c.y - W.dialR, width: 2 * W.dialR, height: 2 * W.dialR))
        let sym = W.dialR
        face.drawSymbol(g, "plus", in: CGRect(x: c.x - sym / 2, y: c.y - sym / 2, width: sym, height: sym), color: HPTokens.orange, weight: .semibold)
        let label = L("worldclock.add", "加入城市"), maxW = r.width - 28
        let f = AppUI.fitted(label, size: 32, weight: .semibold, maxWidth: maxW, minScale: 0.6)
        AppUI.center(face, g, Face.clipped(label, f, maxW), f, cx: r.midX, y: r.minY + W.line1, AppUI.label)
        HPAX.note(g, r, mode == .browse ? .button : .text, label, shape: .rounded(W.cardRadius))   // 「＋」卡是按鈕
    }

    // MARK: 浮層

    /// 聽寫、候選、說明：壓暗＋一塊不透明的卡（卡上的按鈕才是玻璃，跟訊息的確認卡一樣）
    private func drawOverlay(_ g: CGContext, _ face: Face, now: Double, date: Date) {
        let panel = Panel.rect
        g.setFillColor(NSColor.black.withAlphaComponent(HPTokens.dark ? 0.55 : 0.28).cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: 10), blur: 40, color: NSColor(white: 0, alpha: 0.25).cgColor)
        g.addPath(continuousRoundedRect(panel, radius: Screen.concentric(inset: panel.minX))); g.setFillColor(HPComponents.grouped.cgColor); g.fillPath()
        g.restoreGState()
        let hf = HPType.sf(34, .semibold), tf = HPType.sf(46, .regular)
        let h = Panel.header
        var title = "", value: String?
        let cancel = L("clio.chip.cancel", "取消")
        var main = L("msg.dictation.done", "完成")
        switch mode {
        case .listening:
            switch dictationStore?.state ?? .listening {
            case .preparing(let p?): title = String(format: L("msg.dictation.downloading", "正在下载语音模型… %d%%"), Int(p * 100))
            case .preparing: title = L("msg.dictation.preparing", "正在准备…")
            case .finishing: title = L("msg.dictation.finishing", "好了，正在整理…")
            default: title = L("worldclock.listen", "说出城市名称")
            }
            // 紅點＋往外擴的兩圈波紋（訊息聽寫的脈動點縮小版）；減少動態效果：不動
            let dot = CGRect(x: h.minX + 24, y: h.midY - 15, width: 30, height: 30)
            if !HPMotion.reduceMotion {
                for k in 0..<2 {
                    let ph = (now * 0.8 + Double(k) * 0.5).truncatingRemainder(dividingBy: 1)
                    let grow = CGFloat(ph) * 24
                    g.setStrokeColor(HPTokens.orange.withAlphaComponent(0.5 * (1 - ph)).cgColor); g.setLineWidth(3)
                    g.strokeEllipse(in: dot.insetBy(dx: -grow, dy: -grow))
                }
            }
            let pulse = HPMotion.reduceMotion ? 1 : 0.55 + 0.45 * abs(sin(now * 3))
            g.setFillColor(HPTokens.orange.withAlphaComponent(pulse).cgColor); g.fillEllipse(in: dot)
            face.drawLeft(g, Face.clipped(title, hf, h.width - 60), font: hf, x: dot.maxX + Panel.gap, y: h.midY + hf.capHeight / 2, color: HPComponents.secondary)
            let said = (dictationStore.map { $0.final + $0.volatile } ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = said.isEmpty ? [L("msg.dictation.hint", "说完会自动停")] : MessagesScreen.wrap(said, tf, Panel.body(0).width, maxLines: Panel.rows)
            for (k, l) in lines.enumerated() {
                let b = Panel.body(k)
                face.drawLeft(g, Face.clipped(l, tf, b.width), font: tf, x: b.minX, y: b.midY + tf.capHeight / 2, color: said.isEmpty ? HPComponents.tertiary : HPComponents.label)
            }
            value = said.isEmpty ? lines.first : said
        case .candidates(_, let hits):
            title = L("worldclock.pick", "选一个城市"); main = L("worldclock.again", "再说一次")
            face.drawLeft(g, Face.clipped(title, hf, h.width), font: hf, x: h.minX, y: h.midY + hf.capHeight / 2, color: HPComponents.secondary)
            let have = Set(WorldClockList.ids())
            let nf = HPType.sf(38, .semibold), of = HPType.sf(30, .regular)
            for (k, hit) in hits.enumerated() {
                let b = Panel.body(k), added = have.contains(hit.zone)
                AppUI.fillRound(g, b, radius: b.height / 2, color: HPComponents.grouped2)
                face.drawLeft(g, Face.clipped(hit.name, nf, b.width * 0.5), font: nf, x: b.minX + Panel.pad, y: b.midY + nf.capHeight / 2, color: added ? HPComponents.tertiary : HPComponents.label)
                var right = b.maxX - Panel.pad
                let tz = TimeZone(identifier: hit.zone) ?? .current
                if added {   // 已經在清單裡：打勾，點了沒反應
                    face.drawSymbol(g, "checkmark", in: CGRect(x: right - 36, y: b.midY - 18, width: 36, height: 36), color: HPComponents.tertiary, weight: .semibold)
                } else {
                    face.drawSymbol(g, "plus.circle.fill", in: CGRect(x: right - 44, y: b.midY - 22, width: 44, height: 44), color: HPTokens.orange, weight: .regular)
                    right -= 44 + Panel.inner
                    let off = Face.clipped(offsetText(date, tz), of, b.width * 0.4)
                    face.drawLeft(g, off, font: of, x: right - Typo.width(off, of), y: b.midY + of.capHeight / 2, color: HPComponents.secondary)
                }
                HPAX.note(g, b, added ? .text : .button, "\(hit.name)，\(offsetText(date, tz))")
            }
        case .message(let text):
            title = text; main = L("worldclock.again", "再说一次")
            let b = Panel.body(0)
            let lines = MessagesScreen.wrap(text, tf, b.width, maxLines: 2)
            for (k, l) in lines.enumerated() {
                let r = Panel.body(k)
                face.drawLeft(g, Face.clipped(l, tf, r.width), font: tf, x: r.minX, y: r.midY + tf.capHeight / 2, color: HPComponents.label)
            }
            value = nil
        default: return
        }
        if case .candidates = mode {} else { HPAX.note(g, h, .text, title, value: value, shape: .rounded(16)) }   // VoiceOver：狀態＋聽到的字
        HPComponents.glassButton(g, face, Panel.button(0), cancel, size: 38)
        HPComponents.filledButton(g, face, Panel.button(1), main, tint: HPComponents.blue, size: 38)
    }

    /// 長按選單：壓暗、被按的那張卡浮在上面、旁邊一塊玻璃小選單（列高、邊線、行距都用長按選單的 token）
    private func drawMenu(_ g: CGContext, _ face: Face, _ i: Int, date: Date, minute: Int, scale: CGFloat, now: Double) {
        guard i < cityCache.count else { return }
        g.setFillColor(NSColor.black.withAlphaComponent(HPTokens.dark ? 0.55 : 0.28).cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        g.saveGState()
        g.clip(to: CGRect(x: 0, y: W.cardTop - 20, width: 1024, height: W.cardH + 40))
        drawCityCard(g, face, i, cityCache[i].0, cityCache[i].1, date: date, minute: minute, scale: scale, now: now, note: false)
        g.restoreGState()
        let panel = menuPanel(i)
        let f = HPType.sf(40, .regular)
        HPComponents.glass(g, continuousRoundedRect(panel, radius: 64)) { c in
            for (k, row) in self.menuRows(i).enumerated() {
                let r = self.menuRowRect(i, k)
                let col = row.destructive ? HPComponents.red : HPComponents.label
                face.drawSymbol(c, row.symbol, in: CGRect(x: r.minX + 28, y: r.midY - 22, width: 44, height: 44), color: col)
                face.drawLeft(c, Face.clipped(row.title, f, r.width - 120), font: f, x: r.minX + 100, y: r.midY + f.capHeight / 2, color: col)
            }
        }
        for (k, row) in menuRows(i).enumerated() { HPAX.note(g, menuRowRect(i, k), .button, row.title) }
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

// MARK: - 清單（儲存與排序，純邏輯）

/// 世界時鐘的城市清單：時區 ID 陣列存在 UserDefaults（worldclock.cities），最多 8 個，本地永遠第一個、不能刪。
/// 沒存過＝預設四個（本地＋原本清單裡前三個不同 UTC 偏移的）。快照與示範一律用預設、不讀不寫真的設定。
enum WorldClockList {
    static let maxCount = 8
    static let key = "worldclock.cities"
    static let defaultZones = ["Asia/Taipei", "America/Los_Angeles", "America/New_York", "Europe/London", "Asia/Tokyo"]
    /// 示範模式在記憶體裡的清單（讓快照也能看到增刪的結果，但不碰設定）
    nonisolated(unsafe) private static var demo: [String]?
    static var isDemo: Bool { Face.demoData || SnapshotPrivacy.active }

    /// 預設：本地＋不同偏移的三個
    static func defaults(local: TimeZone) -> [String] {
        var out = [local.identifier]
        for id in defaultZones where out.count < 4 {
            guard let tz = TimeZone(identifier: id), tz.identifier != local.identifier,
                  !out.contains(where: { TimeZone(identifier: $0)?.secondsFromGMT() == tz.secondsFromGMT() }) else { continue }
            out.append(id)
        }
        return out
    }
    /// 本地放第一個、去掉重複與認不得的 ID、最多 maxCount 個
    static func normalize(_ ids: [String], local: String) -> [String] {
        var out = [local]
        for id in ids where id != local && !out.contains(id) && TimeZone(identifier: id) != nil { out.append(id) }
        return Array(out.prefix(maxCount))
    }
    static func ids(local: TimeZone = .current, store: UserDefaults = .standard) -> [String] {
        if isDemo { return normalize(demo ?? defaults(local: local), local: local.identifier) }
        guard let saved = store.stringArray(forKey: key) else { return defaults(local: local) }
        return normalize(saved, local: local.identifier)
    }
    static func save(_ ids: [String], store: UserDefaults = .standard) {
        if isDemo { demo = ids } else { store.set(ids, forKey: key) }
    }
    /// 加一個到最後；滿了或已經有就 nil
    static func adding(_ zone: String, to ids: [String]) -> [String]? {
        guard ids.count < maxCount, !ids.contains(zone), TimeZone(identifier: zone) != nil else { return nil }
        return ids + [zone]
    }
    /// 移除第 i 個；本地（第 0 個）不能移除
    static func removing(at i: Int, from ids: [String]) -> [String] {
        guard i > 0, i < ids.count else { return ids }
        var out = ids; out.remove(at: i); return out
    }
    /// 移到本地後面第一個
    static func movingToFront(at i: Int, in ids: [String]) -> [String] {
        guard i > 1, i < ids.count else { return ids }
        var out = ids; out.insert(out.remove(at: i), at: 1); return out
    }
}

// MARK: - 聽到的城市名 → 候選

enum WorldClockMatch {
    struct Hit: Equatable { let zone: String; let name: String }

    /// 比對用的正規化：簡體轉繁體、小寫、只留字母與數字（空白、底線、標點都去掉）
    static func norm(_ s: String) -> String {
        let t = s.applyingTransform(StringTransform(rawValue: "Hans-Hant"), reverse: false) ?? s
        return t.lowercased().filter { $0.isLetter || $0.isNumber }
    }
    private static func last(_ id: String) -> String { String(id.split(separator: "/").last ?? "") }

    /// 先比 App 內建的城市（名稱、別名、時區 ID 最後一段），一個都沒有再比全部時區的最後一段與本地化名稱；最多 limit 個
    static func find(_ query: String, locale: Locale = L10n.language.locale, limit: Int = 3) -> [Hit] {
        let q = norm(query)
        guard q.count >= 2 else { return [] }
        var scored: [(score: Int, hit: Hit)] = []
        var seen = Set<String>()
        func add(_ score: Int, _ zone: String, _ name: String) {
            if seen.insert(zone).inserted { scored.append((score, Hit(zone: zone, name: name))) }
        }
        for c in WorldClockApp.candidates {
            var best = 0
            for n in ([c.name] + c.also).map({ norm($0()) } ) + [norm(last(c.zone))] where n.count >= 2 {
                if n == q { best = max(best, 4) } else if q.contains(n) || n.contains(q) { best = max(best, 3) }
            }
            if best > 0 { add(best, c.zone, c.name()) }
        }
        if scored.isEmpty {
            let locales = [locale, Locale(identifier: "zh_TW"), Locale(identifier: "en_US")]
            for id in TimeZone.knownTimeZoneIdentifiers where id.contains("/") && !id.hasPrefix("Etc/") {
                guard let tz = TimeZone(identifier: id) else { continue }
                let n = norm(last(id))
                if n == q { add(3, id, WorldClockApp.name(for: tz)) }
                else if n.count >= 3, q.count >= 3, n.contains(q) || q.contains(n) { add(2, id, WorldClockApp.name(for: tz)) }
                else if locales.contains(where: { tz.localizedName(for: .generic, locale: $0).map { norm($0).contains(q) } ?? false }) { add(1, id, WorldClockApp.name(for: tz)) }
            }
        }
        // 分數高的在前；同分照出現順序
        let order = scored.enumerated().sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
        return order.prefix(limit).map(\.element.hit)
    }
}

enum WorldClockSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        check(WorldClockMatch.find("台北").first?.zone == "Asia/Taipei", "世界時鐘：聽到「台北」比得到 Asia/Taipei")   // l10n-ignore：selftest 訊息
        let ids = ["Asia/Taipei", "America/New_York", "Europe/London"]
        check(WorldClockList.removing(at: 0, from: ids) == ids && WorldClockList.removing(at: 1, from: ids) == ["Asia/Taipei", "Europe/London"]
              && WorldClockList.movingToFront(at: 0, in: ids) == ids, "世界時鐘：本地不能移除、不能移動，其他的可以")   // l10n-ignore
        let full = ["Asia/Taipei", "Asia/Tokyo", "Asia/Seoul", "Asia/Dubai", "Europe/Paris", "Europe/Berlin", "Europe/London", "Asia/Bangkok"]
        let tooMany = Array(full + ["Asia/Shanghai", "Asia/Singapore"])
        check(full.count == WorldClockList.maxCount && WorldClockList.adding("Asia/Shanghai", to: full) == nil
              && WorldClockList.normalize(tooMany, local: "Asia/Taipei").count == WorldClockList.maxCount
              && WorldClockList.adding("Asia/Shanghai", to: Array(full.prefix(7)))?.count == 8, "世界時鐘：最多 8 個，滿了就加不進去")   // l10n-ignore
    }
}

// MARK: - 2.0 home-3：遠看（Shell/FarGlance.swift）
extension WorldClockApp {
    /// 跟本地時差最大的那座城市（最可能是你想看的家人那邊）：當地時間大字＋時差
    func farGlance(face: Face, now: Double) -> FarGlance? {
        let local = TimeZone.current, wall = Date()
        let zones = WorldClockList.ids(local: local).compactMap(TimeZone.init(identifier:)).filter { $0.identifier != local.identifier }
        guard let tz = zones.max(by: { abs($0.secondsFromGMT(for: wall) - local.secondsFromGMT(for: wall)) < abs($1.secondsFromGMT(for: wall) - local.secondsFromGMT(for: wall)) }) else { return nil }
        let name = Self.candidates.first { $0.zone == tz.identifier }?.name()
            ?? tz.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? tz.identifier
        let diff = Double(tz.secondsFromGMT(for: wall) - local.secondsFromGMT(for: wall)) / 3600
        let diffText = String(format: L("worldclock.far.offset", "%@ 小时"), (diff >= 0 ? "+" : "") + (diff == diff.rounded() ? String(Int(diff)) : String(format: "%.1f", diff)))
        return FarGlance(title: name, headline: Face.shortTime(wall, timeZone: tz), details: [diffText], numeric: true)
    }
}
