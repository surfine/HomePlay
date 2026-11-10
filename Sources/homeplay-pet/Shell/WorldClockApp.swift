// 世界時鐘（稿 scratchpad/worldclock：iOS 6 iPad 時鐘的骨架 × Liquid Glass；512 設計單位 ×2＝1024 畫布）：
// 上排一頁四個類比鐘（錶盤忠實照 iOS 6 iPad 世界時鐘：白天白盤、晚上黑盤；停走秒針，見 Shell/Apps/StationClock.swift），底下城市名與跟本地的時差；
// Liquid Glass 只用在錶盤以外（地圖卡、按鈕、浮層）；
// 城市超過四個就分頁，左右滑（觸控板橫滑、滾輪、點頁點）換一組。下面一張地圖卡（內縮 48、圓角與機身同心）：
// 1960 年代點陣世界地圖，陸地點白天亮、夜裡暗（照現在的太陽直射點與季節赤緯），城市是橘點＋「城市 氣溫」小標籤
// （只有本地那座城市拿得到天氣——WeatherSource 只抓這台 Mac 所在地——其他城市標時間，不造假資料）。
// 點任一個鐘＝全螢幕大鐘（同一款錶盤放大、置中偏下）：左上城市＋當地日期、右上溫度、最底頁點，字都不壓在錶盤上；左右滑換城市，點一下回去。
// 每幀只畫指針：背景＋地圖卡每分鐘一張、每個鐘的錶盤＋字每分鐘一張（日夜、深淺色、對比、透明度、語言、倍率各一張）。
// 減少動態效果：秒針一秒一格、換頁不滑（直接到位）。減少透明度：地圖卡換實色。增加對比：錶圈、次要字、夜裡的點都加深。
// 城市清單可增刪排序（語音優先，HomeView 沒有鍵盤）：最後一格「＋ 加入城市」→聽寫城市名→最多三張候選卡點一個加入；
// 長按城市的鐘出小選單「移到最前面」「移除」（本地固定第一個、沒有選單）。清單存 UserDefaults（worldclock.cities，沿用舊的鍵與格式），快照／示範不讀不寫。

import AppKit

final class WorldClockApp: PetApp {
    let id = "worldclock"
    var title: String { L("app.worldClock", "世界时钟") }
    let icon = AppIcon(color: .black, symbol: "globe", glyph: .white, system: "/System/Applications/Clock.app")

    /// also：同一個時區的別名（洛杉磯、舊金山都落在庫比蒂諾的太平洋時間）——只用來比對，畫面上顯示 name
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
    /// 城市名：內建城市走 L()（三語），其他時區用 ID 的最後一段（系統沒有公開的「時區 → 城市名」在地化）
    static func name(for tz: TimeZone) -> String {
        candidates.first { $0.zone == tz.identifier }?.name()
            ?? tz.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? tz.identifier
    }
    /// 時區 → 經緯度（內建城市才有；其他的沒有地圖上的點，日夜用當地 6:00–18:00）
    static func coordinate(_ tz: TimeZone) -> (lat: Double, lon: Double)? {
        candidates.first { $0.zone == tz.identifier }.map { ($0.lat, $0.lon) }
    }

    /// 這個城市現在是不是晚上：有經緯度看太陽高度（太陽中心 −0.833°＝日出日落），沒有就當地 18:00–5:59
    static func isNight(_ tz: TimeZone, _ date: Date) -> Bool {
        if let c = coordinate(tz) { return ClockKit.altitude(lat: c.lat, lon: c.lon, sun: ClockKit.subsolar(date)) < -0.833 }
        let h = StationClock.localParts(date, tz).h
        return h < 6 || h >= 18
    }
    static func dayWord(night: Bool) -> String { night ? L("worldclock.night", "晚上") : L("worldclock.day", "白天") }
    /// 跟本地差幾小時：「本地」「+1 小时」「-5.5 小时」
    static func offsetText(_ d: Date, _ tz: TimeZone, local: TimeZone = .current) -> String {
        let diffH = Double(tz.secondsFromGMT(for: d) - local.secondsFromGMT(for: d)) / 3600
        if diffH == 0 { return L("worldclock.here", "本地") }
        let n = diffH.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%+d", Int(diffH)) : String(format: "%+.1f", diffH)
        return String(format: L("worldclock.offset", "%@ 小时"), n)
    }
    /// 天氣：只有本地那座城市拿得到（WeatherSource 只抓這台 Mac 所在地）；拿不到回 nil——畫面只顯示時間，不造資料
    static func weather(_ tz: TimeZone) -> (temp: String, line: String)? {
        guard tz.identifier == TimeZone.current.identifier, let d = WeatherSource.shared.data else { return nil }
        let t = Int((Face.weatherImperial ? d.temp * 9 / 5 + 32 : d.temp).rounded())
        return ("\(t)°", "\(Face.weatherText(d.code)) \(t)°")
    }
    /// VoiceOver 念的：「城市 時間 白天／晚上」
    static func axLabel(_ name: String, _ time: String, night: Bool) -> String { "\(name) \(time) \(dayWord(night: night))" }

    // MARK: 狀態

    /// 現在在哪一層：清單、全螢幕大鐘（城市序號）、聽寫、候選、說明（找不到／聽寫失敗）、長按選單（城市序號）
    private enum Mode: Equatable {
        case browse, listening
        case big(Int)
        case candidates(String, [WorldClockMatch.Hit])
        case message(String)
        case menu(Int)
    }
    private var mode = Mode.browse
    private var page = 0
    private var pageAnim = Anim(0, spring: AppMotion.appleSmooth)
    private var scrollAcc: CGFloat = 0, lastScrollAt = 0.0, lastFlip = 0.0
    private var lastSecond = -1
    private var bgLayer: (key: String, img: CGImage)?
    private var cellLayers: [String: CGImage] = [:]
    /// 每分鐘重讀一次城市清單（增刪排序後也重讀）
    private var citiesMinute = -1
    private var cityCache: [(TimeZone, String)] = []
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

    func didOpen(now: Double) {
        mode = .browse; page = 0; pageAnim.set(0, now: now); reload()
        // 快照旗標：--worldclock-add 直接在「說出城市名稱」；--worldclock-heard <文字> 直接當成聽到這句；--worldclock-menu <序號> 開長按選單；
        // --demo-worldclock big[:序號] 直接開那座城市的大鐘；--demo-worldclock-page <n> 停在第 n 頁
        if let t = AppUI.flagValue("--worldclock-heard") { heard(t) }
        else if AppUI.flag("--worldclock-add") { mode = .listening }
        else if let i = AppUI.flagValue("--worldclock-menu").flatMap(Int.init), i > 0, i < cityCache.count { mode = .menu(i) }
        else if let v = AppUI.flagValue("--demo-worldclock"), v.hasPrefix("big") {
            let i = Int(v.split(separator: ":").last ?? "") ?? 0
            mode = .big(max(0, min(cityCache.count - 1, i)))
        }
        if let p = AppUI.flagValue("--demo-worldclock-page").flatMap(Int.init) { page = max(0, min(pageCount - 1, p)); pageAnim.set(CGFloat(page), now: now) }
    }
    func didClose() { dictationStore?.cancel(); mode = .browse }
    /// 大鐘：左上是城市、右上是溫度（稿 Big），不畫關閉鈕與右上小時間——點一下或 Esc 回清單
    var showsCloseButton: Bool { mode == .browse }
    var showsClock: Bool { if case .big = mode { return false }; return true }
    func handleBack(now: Double) -> Bool {
        guard mode != .browse else { return false }
        if case .big(let i) = mode { closeBig(i, now: now); return true }
        dismiss(); return true
    }

    func tick(_ now: Double) -> Bool {
        var dirty = HPComponents.needsFrame(now)
        if !pageAnim.done(now) { dirty = true; ClockKit.keepLive() }
        if ClockKit.reduceMotion {
            let s = Int(ClockKit.date.timeIntervalSince1970)   // 一秒一格：秒數變了才重畫
            if s != lastSecond { lastSecond = s; dirty = true }
        } else {
            ClockKit.keepSweeping(now)   // 停走秒針逐幀：剛操作過 60 fps、之後 30 fps（開著才要，關了就停）
            dirty = true
        }
        return dirty
    }

    // MARK: 版面

    typealias W = HPTokens.WorldClock
    private enum Slot: Equatable { case city(Int), add }
    /// 城市之後再放一格「加入城市」（滿了就不放）
    private var canAdd: Bool { cityCache.count < WorldClockList.maxCount }
    private var slots: [Slot] { cityCache.indices.map { .city($0) } + (canAdd ? [.add] : []) }
    private var pageCount: Int { max(1, (slots.count + W.perPage - 1) / W.perPage) }
    /// 第 k 格的框（含錶盤、城市名、時差）；pageX＝畫面上現在停在第幾頁（換頁滑動中是小數）
    private func cellRect(_ k: Int, pageX: CGFloat) -> CGRect {
        let p = k / W.perPage, col = k % W.perPage
        return CGRect(x: W.side + CGFloat(col) * (W.colW + W.colGap) + (CGFloat(p) - pageX) * 1024, y: W.rowTop,
                      width: W.colW, height: W.relY + 14 - W.rowTop)
    }
    private func dialCenter(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.minY + W.dialTop) }
    private func dotRect(_ k: Int, count n: Int, y: CGFloat) -> CGRect {
        let total = CGFloat(n) * W.pageDot + CGFloat(n - 1) * W.pageDotGap
        return CGRect(x: 512 - total / 2 + CGFloat(k) * (W.pageDot + W.pageDotGap), y: y - W.pageDot / 2, width: W.pageDot, height: W.pageDot)
    }
    /// 點頁點：點到哪一顆（左右外擴半個間距、上下外擴到 44 高）
    private func dotHit(_ p: CGPoint, count n: Int, y: CGFloat) -> Int? {
        guard n > 1, abs(p.y - y) < 22 else { return nil }
        return (0..<n).first { dotRect($0, count: n, y: y).insetBy(dx: -W.pageDotGap / 2, dy: 0).contains(CGPoint(x: p.x, y: y)) }
    }

    // MARK: 換頁

    private func goPage(_ to: Int, now: Double) {
        let to = max(0, min(pageCount - 1, to))
        guard to != page else { return }
        page = to
        if ClockKit.reduceMotion { pageAnim.set(CGFloat(to), now: now) } else { pageAnim.retarget(CGFloat(to), now: now) }
    }
    /// 滾輪與觸控板（直、橫都收）：累積到一格才翻，翻完 0.6 秒內不再翻（觸控板放手後還會送慣性）
    private func swipe(_ d: CGFloat, now: Double) -> Bool {
        let paging: Bool
        switch mode {
        case .browse: paging = pageCount > 1
        case .big: paging = cityCache.count > 1
        default: return true   // 浮層開著：吃掉，不讓底下動
        }
        guard paging else { return false }
        if now - lastScrollAt > 0.3 { scrollAcc = 0 }
        lastScrollAt = now; scrollAcc += d
        guard abs(scrollAcc) > 40, now - lastFlip > 0.6 else { return true }
        let dir = scrollAcc < 0 ? 1 : -1
        scrollAcc = 0; lastFlip = now
        if case .big(let i) = mode { mode = .big(max(0, min(cityCache.count - 1, i + dir))) } else { goPage(page + dir, now: now) }
        return true
    }
    func handleScroll(_ dy: CGFloat, now: Double) -> Bool { swipe(dy, now: now) }
    func handleScrollX(_ dx: CGFloat, now: Double) -> Bool { swipe(dx, now: now) }

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
    /// 長按選單的列：本地後面第一個已經是最前面，不放「移到最前面」
    private func menuRows(_ i: Int) -> [(title: String, symbol: String, destructive: Bool)] {
        var rows: [(String, String, Bool)] = []
        if i > 1 { rows.append((L("worldclock.moveFirst", "移到最前面"), "arrow.up.to.line", false)) }
        rows.append((L("worldclock.remove", "移除"), "trash", true))
        return rows
    }
    private func menuPanel(_ i: Int) -> CGRect { SBUI.menuPanel(anchor: cellRect(i, pageX: CGFloat(page)), rows: menuRows(i).count, sizes: false) }
    private func menuRowRect(_ i: Int, _ k: Int) -> CGRect {
        let p = menuPanel(i)
        return CGRect(x: p.minX + SBUI.menuInset, y: p.minY + SBUI.menuInset + CGFloat(k) * (SBUI.menuRow + SBUI.menuRowGap),
                      width: p.width - 2 * SBUI.menuInset, height: SBUI.menuRow)
    }

    // MARK: 動作

    /// 重讀清單（增刪排序之後、打開時、每分鐘）：城市快取與地圖作廢；頁數變少時退回最後一頁
    private func reload() {
        cityCache = Self.cities(); bgLayer = nil
        citiesMinute = Int(ClockKit.date.timeIntervalSince1970 / 60)
        if page > pageCount - 1 { page = pageCount - 1; pageAnim.set(CGFloat(page), now: CACurrentMediaTime()) }
        if case .big(let i) = mode, i >= cityCache.count { mode = .browse }
    }
    private func dismiss() { dictationStore?.cancel(); mode = .browse }
    private func closeBig(_ i: Int, now: Double) {
        mode = .browse
        goPage(i / W.perPage, now: now)   // 大鐘裡換過城市：回到那座城市所在的那一頁
    }

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
        goPage(pageCount - 1, now: CACurrentMediaTime())   // 翻到新的那個所在的最後一頁
    }

    func handleLongPress(_ p: CGPoint, face: Face, now: Double) -> Bool {
        guard mode == .browse else { return false }
        for (k, s) in slots.enumerated() {
            guard case .city(let i) = s, i > 0, cellRect(k, pageX: CGFloat(page)).contains(p) else { continue }   // 本地（第 0 個）沒有選單
            mode = .menu(i); return true
        }
        return false
    }

    func handleTap(_ p: CGPoint, face: Face, now: Double) -> Bool {
        switch mode {
        case .browse:
            if let k = dotHit(p, count: pageCount, y: W.dotsY) { goPage(k, now: now); return true }
            for (k, s) in slots.enumerated() where cellRect(k, pageX: CGFloat(page)).contains(p) {
                switch s {
                case .city(let i): mode = .big(i)
                case .add: startListening()
                }
                return true
            }
            return false
        case .big(let i):
            let n = cityCache.count
            if n > 1, abs(p.y - W.bigDotsY) < 22, let k = (0..<n).first(where: { bigDotRect($0, count: n).insetBy(dx: -W.bigDotGap / 2, dy: 0).minX <= p.x && p.x <= bigDotRect($0, count: n).insetBy(dx: -W.bigDotGap / 2, dy: 0).maxX }) {
                mode = .big(k); return true
            }
            closeBig(i, now: now); return true   // 點一下回去
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

    // MARK: 顏色（稿 Main：深色＝夜藍漸層＋白字；淺色沿用大鐘白天的漸層＋墨色字）

    private static var ink: NSColor { HPTokens.dark ? .white : srgb(0x14161F) }
    private static var ink2: NSColor { ink.withAlphaComponent(HPAccessibility.increaseContrast ? 0.9 : 0.72) }
    /// CSS linear-gradient(170deg …) 鋪滿整個畫面
    static func fillGradient(_ g: CGContext, _ hex: [UInt32], _ locs: [CGFloat], in r: CGRect = CGRect(x: 0, y: 0, width: 1024, height: 1024)) {
        guard let gr = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: hex.map { srgb($0).cgColor } as CFArray, locations: locs) else { return }
        let a = 170 * CGFloat.pi / 180, dir = CGPoint(x: sin(a), y: -cos(a))
        let half = (abs(r.width * sin(a)) + abs(r.height * cos(a))) / 2
        g.saveGState(); g.clip(to: r)
        g.drawLinearGradient(gr, start: CGPoint(x: r.midX - dir.x * half, y: r.midY - dir.y * half), end: CGPoint(x: r.midX + dir.x * half, y: r.midY + dir.y * half),
                             options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        g.restoreGState()
    }
    private static func mainBackground(_ g: CGContext) {
        if HPTokens.dark { fillGradient(g, [0x18213A, 0x262C4A, 0x3A3350], [0, 0.55, 1]) }
        else { fillGradient(g, [0xC9D6EE, 0xE7EBF4, 0xD8D2E4], [0, 0.6, 1]) }
    }

    // MARK: 畫

    func render(into g: CGContext, face: Face, rect: CGRect, now: Double) {
        let date = ClockKit.date
        let scale = ClockKit.pixelScale(g)
        let minute = Int(date.timeIntervalSince1970 / 60)
        if citiesMinute != minute { reload() }
        WeatherSource.shared.activate { [weak face] in face?.forceDirty = true }
        if case .big(let i) = mode, i < cityCache.count { renderBig(g, face, i, date: date, minute: minute, scale: scale); return }

        // 背景＋地圖卡（每分鐘一張）
        let src = WeatherSource.shared
        let key = "\(minute)|\(HPTokens.dark)|\(HPAccessibility.increaseContrast)|\(HPAccessibility.reduceTransparency)|\(L10n.language.rawValue)|\(Int(scale * 100))|\(src.version)|\(cityCache.map(\.0.identifier).joined(separator: ","))"
        if bgLayer?.key != key {
            let list = cityCache
            bgLayer = ClockKit.layer(size: CGSize(width: 1024, height: 1024), scale: scale) { c in
                Self.mainBackground(c)
                self.drawMapCard(c, face, list, date: date)
            }.map { (key, $0) }
        }
        if let b = bgLayer { ClockKit.blit(g, b.img, in: rect) }

        // 上排的鐘：換頁滑動中畫兩頁
        let pageX = pageAnim.value(now)
        g.saveGState(); g.clip(to: CGRect(x: 0, y: W.rowTop - 20, width: 1024, height: W.relY + 40 - W.rowTop))
        if cellLayers.count > 32 { cellLayers.removeAll() }
        for (k, s) in slots.enumerated() {
            let r = cellRect(k, pageX: pageX)
            guard r.maxX > 0, r.minX < 1024 else { continue }
            switch s {
            case .city(let i): drawCell(g, face, r, cityCache[i].0, cityCache[i].1, date: date, minute: minute, scale: scale, note: mode == .browse)
            case .add: drawAddCell(g, face, r)
            }
        }
        g.restoreGState()
        // 頁點
        let n = pageCount
        if n > 1 {
            for k in 0..<n {
                let d = dotRect(k, count: n, y: W.dotsY)
                let on = max(0, 1 - abs(CGFloat(k) - pageX))
                g.setFillColor(Self.ink.withAlphaComponent(0.28 + 0.72 * on).cgColor); g.fillEllipse(in: d)
                if mode == .browse { HPAX.note(g, d.insetBy(dx: -W.pageDotGap / 2, dy: -15), .button, String(format: L("worldclock.ax.page", "第 %1$d 页，共 %2$d 页"), k + 1, n)) }
            }
        }

        switch mode {
        case .browse, .big: break
        case .menu(let i): drawMenu(g, face, i, date: date, minute: minute, scale: scale)
        default: drawOverlay(g, face, now: now, date: date)
        }
    }

    /// 一個鐘：靜態的部分（錶盤＋城市名＋時差，每分鐘一張）＋每幀的針＋VoiceOver 的字
    private func drawCell(_ g: CGContext, _ face: Face, _ r: CGRect, _ tz: TimeZone, _ name: String, date: Date, minute: Int, scale: CGFloat, note: Bool) {
        let night = Self.isNight(tz, date)
        let key = "\(tz.identifier)|\(minute)|\(night)|\(HPTokens.dark)|\(HPAccessibility.increaseContrast)|\(HPAccessibility.reduceTransparency)|\(L10n.language.rawValue)|\(Int(scale * 100))"
        if cellLayers[key] == nil {
            cellLayers[key] = ClockKit.layer(size: r.size, scale: scale) { c in
                let local = CGRect(origin: .zero, size: r.size)
                if let img = StationClock.faceImage(radius: W.dialR, night: night, scale: scale) {
                    ClockKit.blit(c, img, in: StationClock.faceRect(center: CGPoint(x: local.midX, y: W.dialTop), radius: W.dialR))
                }
                let maxW = r.width - 8
                let f1 = AppUI.fitted(name, size: 30, weight: .semibold, maxWidth: maxW, minScale: 0.6)
                AppUI.center(face, c, Face.clipped(name, f1, maxW), f1, cx: local.midX, y: W.nameY - W.rowTop, Self.ink)
                let rel = Self.offsetText(date, tz), f2 = AppUI.fitted(rel, size: 26, weight: .regular, maxWidth: maxW)
                AppUI.center(face, c, Face.clipped(rel, f2, maxW), f2, cx: local.midX, y: W.relY - W.rowTop, Self.ink2)
            }
        }
        if let img = cellLayers[key] { ClockKit.blit(g, img, in: r) }
        StationClock.drawHands(g, center: dialCenter(r), radius: W.dialR, angles: StationClock.angles(date, tz), night: night)
        guard note else { return }
        HPAX.note(g, r, .button, Self.axLabel(name, Face.shortTime(date, timeZone: tz), night: night), shape: .rounded(24))
    }

    /// 最後一格：「＋ 加入城市」——錶盤大小的淡橘圓＋橘色加號（不疊玻璃，看得出不是鐘）
    private func drawAddCell(_ g: CGContext, _ face: Face, _ r: CGRect) {
        let c = dialCenter(r), R = W.dialR
        g.setFillColor(HPTokens.orange.withAlphaComponent(HPAccessibility.increaseContrast ? 0.3 : 0.18).cgColor)
        g.fillEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
        let sym = R * 0.8
        face.drawSymbol(g, "plus", in: CGRect(x: c.x - sym / 2, y: c.y - sym / 2, width: sym, height: sym), color: HPTokens.orange, weight: .semibold)
        let label = L("worldclock.add", "加入城市"), maxW = r.width - 8
        let f = AppUI.fitted(label, size: 30, weight: .semibold, maxWidth: maxW, minScale: 0.6)
        AppUI.center(face, g, Face.clipped(label, f, maxW), f, cx: r.midX, y: W.nameY, Self.ink)
        HPAX.note(g, r, mode == .browse ? .button : .text, label, shape: .rounded(24))
    }

    /// 地圖卡：內縮 48、圓角同心；點陣陸地（白天亮、夜裡暗）、城市橘點＋「城市 氣溫」（沒有天氣就「城市 時間」）
    private func drawMapCard(_ c: CGContext, _ face: Face, _ list: [(TimeZone, String)], date: Date) {
        let card = W.mapCard, path = continuousRoundedRect(card, radius: W.mapRadius)
        let dark = HPTokens.dark, rt = HPAccessibility.reduceTransparency, ic = HPAccessibility.increaseContrast
        let fill: NSColor = dark ? (rt ? srgb(0x1A1F35) : NSColor(srgbRed: 8 / 255, green: 10 / 255, blue: 24 / 255, alpha: 0.42))
                                 : (rt ? srgb(0xF4F6FA) : NSColor(white: 1, alpha: 0.45))
        c.addPath(path); c.setFillColor(fill.cgColor); c.fillPath()
        c.addPath(path); c.setStrokeColor((dark ? NSColor(white: 1, alpha: ic ? 0.45 : 0.12) : NSColor(white: 0, alpha: ic ? 0.4 : 0.08)).cgColor)
        c.setLineWidth(2); c.strokePath()
        c.saveGState(); c.addPath(path); c.clip()
        let origin = CGPoint(x: card.minX + W.mapInset, y: card.minY + W.mapInset)
        let base: NSColor = dark ? .white : srgb(0x14161F)
        DotMap.draw(c, origin: origin, step: W.mapStep, radius: W.mapDot, date: date,
                    day: base.withAlphaComponent(dark ? 0.78 : 0.7), night: base.withAlphaComponent(ic ? 0.34 : (dark ? 0.22 : 0.16)))
        // 城市：先畫點，再畫標籤（標籤不被別的點蓋住）
        var pins: [(CGPoint, String)] = []
        for (tz, name) in list {
            guard let co = Self.coordinate(tz) else { continue }
            let p = DotMap.point(lat: co.lat, lon: co.lon, origin: origin, step: W.mapStep)
            DotMap.pin(c, p, halo: 14, dot: 6.4, ring: 2.4, haloAlpha: 0.22)
            pins.append((p, "\(name) \(Self.weather(tz)?.temp ?? Face.shortTime(date, timeZone: tz))"))
        }
        let f = HPType.sf(22, .semibold)
        // 標籤位置：右上（稿）→ 右下 → 左上 → 左下，挑第一個不壓到別的標籤、也不蓋住別的城市點的
        var placed: [CGRect] = []
        let dots = pins.map { CGRect(x: $0.0.x - 14, y: $0.0.y - 14, width: 28, height: 28) }
        for (k, (p, tag)) in pins.enumerated() {
            let w = Typo.width(tag, f) + 28, h: CGFloat = 34
            func fit(_ r: CGRect) -> CGRect {
                CGRect(x: max(card.minX + 24, min(card.maxX - 24 - w, r.minX)), y: max(card.minY + 12, min(card.maxY - 12 - h, r.minY)), width: w, height: h)
            }
            let options = [CGRect(x: p.x + 16, y: p.y - 44, width: w, height: h), CGRect(x: p.x + 16, y: p.y + 10, width: w, height: h),
                           CGRect(x: p.x - 16 - w, y: p.y - 44, width: w, height: h), CGRect(x: p.x - 16 - w, y: p.y + 10, width: w, height: h)].map(fit)
            let box = options.first { b in !placed.contains { $0.intersects(b) } && !dots.enumerated().contains { $0.offset != k && $0.element.intersects(b) } } ?? options[0]
            placed.append(box)
            AppUI.fillPill(c, box, color: NSColor(white: 0, alpha: ic ? 0.6 : 0.35))
            face.drawLeft(c, tag, font: f, x: box.minX + 14, y: box.midY + f.capHeight / 2, color: .white)
        }
        c.restoreGState()
    }

    // MARK: 全螢幕大鐘

    private func renderBig(_ g: CGContext, _ face: Face, _ i: Int, date: Date, minute: Int, scale: CGFloat) {
        let (tz, name) = cityCache[i]
        let night = Self.isNight(tz, date)
        // 背景跟著那座城市的日夜（稿 Big）
        if night { Self.fillGradient(g, [0x141A30, 0x1E2340, 0x2C2944], [0, 0.6, 1]) }
        else { Self.fillGradient(g, [0xE9EAEE, 0xD9DBE0], [0, 1]) }
        let o = W.bigCenter, R = W.bigR
        let dial = CGRect(x: o.x - R, y: o.y - R, width: 2 * R, height: 2 * R)
        if let img = StationClock.faceImage(radius: R, night: night, scale: scale) { ClockKit.blit(g, img, in: StationClock.faceRect(center: o, radius: R)) }
        StationClock.drawHands(g, center: o, radius: R, angles: StationClock.angles(date, tz), night: night)
        let ink = night ? srgb(0xF2F2F2) : srgb(0x1B1B1B), ic = HPAccessibility.increaseContrast
        // 左上：城市＋當地日期（中間留給 👀）；右上：溫度細字大號（拿不到天氣就不放）
        let leftW: CGFloat = 512 - 230 - W.bigTextX
        let f1 = AppUI.fitted(name, size: 44, weight: .semibold, maxWidth: leftW, minScale: 0.6)
        face.drawLeft(g, Face.clipped(name, f1, leftW), font: f1, x: W.bigTextX, y: W.bigNameY, color: ink)
        let dateText = Face.formatter("MMMMdEEEE", timeZone: tz).string(from: date)
        let f2 = AppUI.fitted(dateText, size: 26, weight: .regular, maxWidth: leftW, minScale: 0.7)
        face.drawLeft(g, Face.clipped(dateText, f2, leftW), font: f2, x: W.bigTextX, y: W.bigDateY, color: ink.withAlphaComponent(ic ? 0.85 : 0.6))
        let wx = Self.weather(tz)
        if let w = wx {
            let tf = HPType.sf(80, .ultraLight)
            face.drawLeft(g, w.temp, font: tf, x: 1024 - W.bigTextX - Typo.width(w.temp, tf), y: W.bigTempY, color: ink)
        }
        // 頁點：錶盤下方、最底一顆玻璃膠囊
        let n = cityCache.count
        if n > 1 {
            let total = CGFloat(n) * W.bigDot + CGFloat(n - 1) * W.bigDotGap
            let chip = CGRect(x: 512 - total / 2 - 20, y: W.bigDotsY - W.bigDot / 2 - 12, width: total + 40, height: W.bigDot + 24)
            let rt = HPAccessibility.reduceTransparency
            AppUI.fillPill(g, chip, color: night ? (rt ? srgb(0x2A2F45) : NSColor(white: 1, alpha: 0.1)) : (rt ? srgb(0xF4F5F7) : NSColor(white: 1, alpha: 0.45)))
            for k in 0..<n {
                g.setFillColor((k == i ? ink : ink.withAlphaComponent(night ? 0.3 : 0.28)).cgColor)
                g.fillEllipse(in: bigDotRect(k, count: n))
            }
        }
        HPAX.note(g, dial.insetBy(dx: 20, dy: 20), .button, Self.axLabel(name, Face.shortTime(date, timeZone: tz), night: night), value: wx?.line, shape: .circle)
    }
    private func bigDotRect(_ k: Int, count n: Int) -> CGRect {
        let total = CGFloat(n) * W.bigDot + CGFloat(n - 1) * W.bigDotGap
        return CGRect(x: 512 - total / 2 + CGFloat(k) * (W.bigDot + W.bigDotGap), y: W.bigDotsY - W.bigDot / 2, width: W.bigDot, height: W.bigDot)
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
                    let off = Face.clipped(Self.offsetText(date, tz), of, b.width * 0.4)
                    face.drawLeft(g, off, font: of, x: right - Typo.width(off, of), y: b.midY + of.capHeight / 2, color: HPComponents.secondary)
                }
                HPAX.note(g, b, added ? .text : .button, "\(hit.name)，\(Self.offsetText(date, tz))")
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

    /// 長按選單：壓暗、被按的那個鐘浮在上面、旁邊一塊玻璃小選單（列高、邊線、行距都用長按選單的 token）
    private func drawMenu(_ g: CGContext, _ face: Face, _ i: Int, date: Date, minute: Int, scale: CGFloat) {
        guard i < cityCache.count, let k = slots.firstIndex(of: .city(i)) else { return }
        g.setFillColor(NSColor.black.withAlphaComponent(HPTokens.dark ? 0.55 : 0.28).cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        drawCell(g, face, cellRect(k, pageX: CGFloat(page)), cityCache[i].0, cityCache[i].1, date: date, minute: minute, scale: scale, note: false)
        let panel = menuPanel(i)
        let f = HPType.sf(40, .regular)
        HPComponents.glass(g, continuousRoundedRect(panel, radius: HPTokens.Radius.concentric(rect: panel))) { c in
            for (k, row) in self.menuRows(i).enumerated() {
                let r = self.menuRowRect(i, k)
                let col = row.destructive ? HPComponents.red : HPComponents.label
                face.drawSymbol(c, row.symbol, in: CGRect(x: r.minX + 28, y: r.midY - 22, width: 44, height: 44), color: col)
                face.drawLeft(c, Face.clipped(row.title, f, r.width - 120), font: f, x: r.minX + 100, y: r.midY + f.capHeight / 2, color: col)
            }
        }
        for (k, row) in menuRows(i).enumerated() { HPAX.note(g, menuRowRect(i, k), .button, row.title) }
    }
}

// MARK: - 清單（儲存與排序，純邏輯）

/// 世界時鐘的城市清單：時區 ID 陣列存在 UserDefaults（worldclock.cities），最多 24 個（上排一頁四個、分六頁），本地永遠第一個、不能刪。
/// 車站鐘版沿用同一個鍵與格式：舊版存的（最多 8 個）原樣讀進來，一個都不丟。
/// 沒存過＝預設四個（本地＋原本清單裡前三個不同 UTC 偏移的）。快照與示範一律用預設、不讀不寫真的設定。
enum WorldClockList {
    static let maxCount = 24
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
        // 上限 24：滿了加不進去、超過的截掉
        let pool = TimeZone.knownTimeZoneIdentifiers.filter { $0.contains("/") && !$0.hasPrefix("Etc/") }
        let full = Array(pool.prefix(WorldClockList.maxCount)), extra = pool[WorldClockList.maxCount]
        check(WorldClockList.maxCount == 24 && WorldClockList.adding(extra, to: full) == nil
              && WorldClockList.normalize(Array(pool.prefix(30)), local: full[0]).count == WorldClockList.maxCount
              && WorldClockList.adding(extra, to: Array(full.prefix(23)))?.count == 24, "世界時鐘：最多 24 個，滿了就加不進去")   // l10n-ignore
        // 既有資料遷移：舊版存的 8 個（舊上限）與 10 個（舊版會截到 8）照原順序全部讀回來，本地不在清單裡就補在最前面
        let suite = "homeplay.selftest.worldclock"
        if let store = UserDefaults(suiteName: suite), !WorldClockList.isDemo {
            let taipei = TimeZone(identifier: "Asia/Taipei")!
            let old8 = ["Asia/Taipei", "Asia/Tokyo", "Asia/Seoul", "Asia/Dubai", "Europe/Paris", "Europe/Berlin", "Europe/London", "Asia/Bangkok"]
            store.set(old8, forKey: WorldClockList.key)
            let a = WorldClockList.ids(local: taipei, store: store)
            store.set(Array(old8.dropFirst()) + ["Asia/Shanghai", "Asia/Singapore"], forKey: WorldClockList.key)
            let b = WorldClockList.ids(local: taipei, store: store)
            store.removePersistentDomain(forName: suite)
            check(a == old8 && b == old8 + ["Asia/Shanghai", "Asia/Singapore"] && WorldClockList.ids(local: taipei, store: store) == WorldClockList.defaults(local: taipei),
                  "世界時鐘：舊清單照鍵 worldclock.cities 原樣讀回（8 個不丟、超過 8 個也留著），沒存過才用預設")   // l10n-ignore
        }
        check(WorldClockApp.offsetText(Date(), TimeZone(identifier: "Asia/Taipei")!, local: TimeZone(identifier: "Asia/Taipei")!) == L("worldclock.here", "本地")
              && WorldClockApp.axLabel("A", "1:00", night: true).hasSuffix(L("worldclock.night", "晚上")), "世界時鐘：本地寫「本地」、VoiceOver 念城市＋時間＋白天／晚上")   // l10n-ignore
        StationClockSelfTest.run(check)   // 停走秒針、時分針公式、夏令時間、晝夜、點陣網格（Shell/Apps/StationClock.swift）
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
