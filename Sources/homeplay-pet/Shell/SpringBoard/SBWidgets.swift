// 2.0 SpringBoard：每種小工具的名字、說明、選項（Edit Widget）與各大小的畫法。
//
// - 字級各大小一樣（iOS 小工具的字不隨大小變），以官方 small（392 px ＝ iOS 158 pt）的比例 K 換算；圖庫預覽用縮放畫布畫同一份。
// - 渲染模式照 HomeAppearance（Shell/HomeAppearance.swift）：淺色／深色＝全彩；清透／染色＝拿掉背景（底下是主畫面的玻璃）、字用 WidgetInk。
// - 資料：快照（SnapshotPrivacy）一律示範資料；平常用 HomePlay 已有的來源（行事曆、提醒事項、家庭、正在播放、計時器、鬧鐘、尋找、這台 Mac 的電池），
//   沒授權或沒資料就照 HIG 畫空狀態，不拿示範資料冒充。行事曆、提醒事項、尋找是個人內容：訪客、認不出的人看到「需要主人」（PersonalGate）。
// - 照片 small、天氣 small 沿用 P02 的畫法（Shell/PhotosWidget.swift、Shell/HomeWidgets.swift），其他大小在這裡。

import AppKit
import IOKit.ps

extension SBWidgetKind {
    var title: String {
        switch self {
        case .photos: return L("shell.photos.title", "照片")
        case .weather: return L("shell.weather.title", "天气")
        case .calendar: return L("sb.widget.calendar", "日历")
        case .reminders: return L("sb.widget.reminders", "提醒事项")
        case .music: return L("sb.widget.music", "音乐")
        case .podcasts: return L("sb.widget.podcasts", "播客")
        case .home: return L("sb.widget.home", "家庭")
        case .worldClock: return L("app.worldClock", "世界时钟")
        case .timers: return L("sb.widget.timers", "计时器")
        case .alarms: return L("sb.widget.alarms", "闹钟")
        case .findMy: return L("sb.widget.findMy", "查找")
        case .batteries: return L("sb.widget.batteries", "电池")
        case .webApp: return L("webapp.widget.title", "Web App")
        }
    }
    /// 圖庫裡的一句說明（HIG：動詞開頭）
    var blurb: String {
        switch self {
        case .photos: return L("home.gallery.photos.blurb", "查看精选照片与回忆。")
        case .weather: return L("home.gallery.weather.blurb", "查看所在地的天气与高低温。")
        case .calendar: return L("sb.blurb.calendar", "查看接下来的日程。")
        case .reminders: return L("sb.blurb.reminders", "查看今天要做的事。")
        case .music: return L("sb.blurb.music", "查看并控制正在播放的音乐。")
        case .podcasts: return L("sb.blurb.podcasts", "继续收听播客。")
        case .home: return L("sb.blurb.home", "查看家里的配件状态。")
        case .worldClock: return L("home.gallery.worldClock.blurb", "查看另一个城市现在几点。")
        case .timers: return L("sb.blurb.timers", "查看正在进行的计时器。")
        case .alarms: return L("sb.blurb.alarms", "查看下一个闹钟。")
        case .findMy: return L("sb.blurb.findMy", "查看家人与设备在哪里。")
        case .batteries: return L("sb.blurb.batteries", "查看设备的电量。")
        case .webApp: return L("webapp.widget.blurb", "来自 Web App 的小组件。")
        }
    }
    /// 圖庫清單上的 App 圖示（沒有 App 的用符號）
    var iconApp: String? {
        switch self {
        case .photos: return nil
        case .batteries: return nil
        default: return appID
        }
    }
    var symbol: String {
        switch self {
        case .photos: return "photo.on.rectangle"
        case .batteries: return "battery.75percent"
        case .webApp: return "globe"
        case .weather: return "cloud.sun.fill"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .music: return "music.note"
        case .podcasts: return "mic.fill"
        case .home: return "house.fill"
        case .worldClock: return "globe"
        case .timers: return "timer"
        case .alarms: return "alarm.fill"
        case .findMy: return "location.fill"
        }
    }
}

/// Edit Widget 的一個選項
struct SBOption {
    var key: String
    var title: String
    var choices: [(id: String, title: String)]
    var def: String
}

enum SBWidgetData {
    /// 快照、示範：一律示範資料（SnapshotPrivacy）
    static var demo: Bool { SnapshotPrivacy.active }

    /// 這個小工具有哪些選項（家庭的房間、提醒事項的列表照真的資料列）；沒有選項＝右鍵選單不出「編輯小工具」（跟 iOS 一樣）
    static func options(_ k: SBWidgetKind) -> [SBOption] {
        switch k {
        case .worldClock:
            let cs = WorldClockApp.candidates.map { (id: $0.zone, title: $0.name()) }
            return [SBOption(key: "city", title: L("sb.opt.city", "城市"), choices: cs, def: defaultClockZone)]
        case .calendar:
            return [SBOption(key: "show", title: L("sb.opt.show", "显示"), choices: [("next", L("sb.opt.upNext", "下一个日程")), ("list", L("sb.opt.list", "日程列表"))], def: "next")]
        case .reminders:
            var cs: [(id: String, title: String)] = [("today", L("sb.opt.today", "今天")), ("all", L("sb.opt.all", "全部"))]
            if !demo, ReminderSource.shared.authorized { cs += ReminderSource.shared.lists.map { (id: $0.id, title: $0.title) } }
            return [SBOption(key: "list", title: L("sb.opt.list.reminders", "列表"), choices: cs, def: "today")]
        case .home:
            var cs: [(id: String, title: String)] = [("all", L("sb.opt.allRooms", "所有房间"))]
            cs += homeGroups().filter { !$0.id.isEmpty }.map { (id: $0.id, title: $0.name) }
            return [SBOption(key: "room", title: L("sb.opt.room", "房间"), choices: cs, def: "all")]
        case .findMy:
            return [SBOption(key: "show", title: L("sb.opt.show", "显示"), choices: [("people", L("sb.opt.people", "联系人")), ("devices", L("sb.opt.devices", "设备"))], def: "people")]
        default: return []
        }
    }
    static func value(_ w: SBWidget, _ key: String) -> String {
        w.config[key] ?? options(w.kind).first { $0.key == key }?.def ?? ""
    }
    static var defaultClockZone: String {
        let cs = WorldClockApp.cities()
        return (cs.count > 1 ? cs[1] : cs[0]).0.identifier
    }

    // MARK: 資料

    static func homeGroups() -> [HomeRoomGroup] {
        HomeAppModel.groups(demo || HomeApp.demo ? HomeAppModel.demoSnapshot() : HomeLink.shared.snapshot)
    }
    static func events(now: Date) -> [AgendaEvent]? {
        if demo { return AgendaSource.demoEvents(now: now) }
        let src = AgendaSource.shared
        guard src.authorized else { return nil }
        let start = Calendar.current.startOfDay(for: now)
        src.ensure(from: start, to: Calendar.current.date(byAdding: .day, value: 7, to: start) ?? now)
        return src.events.filter { $0.end > now }.sorted { $0.start < $1.start }
    }
    static func reminders(list: String, now: Date) -> (title: String, color: NSColor, items: [ReminderItem])? {
        let src = ReminderSource.shared
        var items: [ReminderItem], lists: [ReminderList]
        if demo { (items, lists) = ReminderSource.demoData(now: now) } else {
            guard src.authorized else { return nil }
            src.refreshIfNeeded(); items = src.items; lists = src.lists
        }
        items = items.filter { !$0.completed }
        switch list {
        case "today":
            let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) ?? now
            return (L("sb.opt.today", "今天"), srgb(0x0A84FF), items.filter { ($0.due ?? .distantFuture) < end })
        case "all": return (L("sb.opt.all", "全部"), srgb(0x8E8E93), items)
        default:
            let l = lists.first { $0.id == list }
            return (l?.title ?? L("sb.widget.reminders", "提醒事项"), l.map { srgb($0.color) } ?? srgb(0xFF9500), items.filter { $0.listID == list })
        }
    }
    static func findMy(_ show: String) -> [FindMyItem] {
        if FindMyModel.demo { return show == "devices" ? FindMyModel.demoDevices() : FindMyModel.demoPeople() }
        return show == "devices" ? [FindMyModel.thisMac()] : []
    }
    struct Battery { var name: String; var symbol: String; var level: Double?; var charging: Bool }
    /// 這台 Mac 的電池（IOKit 的電源資訊；桌機沒有電池＝接電源）；示範多給 iPhone、AirPods
    static func batteries() -> [Battery] {
        if demo {
            return [Battery(name: L("findmy.demo.macbook", "MacBook Air"), symbol: "laptopcomputer", level: 0.82, charging: true),
                    Battery(name: L("findmy.demo.iphone", "iPhone"), symbol: "iphone", level: 0.64, charging: false),
                    Battery(name: L("findmy.demo.airpods", "AirPods Pro"), symbol: "airpodspro", level: 0.45, charging: false),
                    Battery(name: L("sb.battery.watch", "Apple Watch"), symbol: "applewatch", level: 0.91, charging: false)]
        }
        let name = Host.current().localizedName ?? L("findmy.thisMac", "这台 Mac")
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return [Battery(name: name, symbol: "desktopcomputer", level: nil, charging: true)]
        }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return [Battery(name: name, symbol: "laptopcomputer", level: Double(cur) / Double(max), charging: (d[kIOPSIsChargingKey] as? Bool) ?? false)]
        }
        return [Battery(name: name, symbol: "desktopcomputer", level: nil, charging: true)]
    }
    static func nowPlaying(_ face: Face, now: Double) -> NowPlayingInfo? {
        if demo { return NowPlayingInfo(title: "Blue Hour", artist: "Nova Sato", duration: 214, position: 81, playing: true, stamp: now, fixed: true) }   // l10n-ignore：示範曲名
        return face.musicActive(now) ? (face.nowPlaying.info ?? face.nowPlaying.shown) : nil
    }
    static func timers() -> [(label: String, left: Double, frac: Double)] {
        let wall = TimersApp.wallNow
        if demo, Shell.timers.isEmpty {
            return [(L("shell.demo.pasta", "意大利面"), 272, 0.45), (L("shell.demo.sauce", "酱汁"), 665, 0.74)]
        }
        return Shell.timers.sorted.map { ($0.label, $0.left(wall), $0.fraction(wall)) }
    }
    static func alarms() -> [AlarmItem] {
        if demo {
            return [AlarmItem(id: 1, hour: 6, minute: 30, label: L("sb.alarm.wake", "起床"), days: [2, 3, 4, 5, 6], enabled: true),
                    AlarmItem(id: 2, hour: 8, minute: 0, label: L("sb.alarm.weekend", "周末"), days: [1, 7], enabled: false),
                    AlarmItem(id: 3, hour: 22, minute: 15, label: L("sb.alarm.bed", "该睡了"), days: [], enabled: true)]
        }
        return AlarmCenter.shared.alarms
    }
}

/// 小工具的換算：iOS small 158 pt ＝ 這裡 392 px
enum SBK {
    static let K: CGFloat = 392 / 158
    static let pad: CGFloat = 16 * K
}

extension Face {
    /// 畫一個小工具（主畫面上、或 preview＝圖庫與設定卡的預覽：底下沒有玻璃）
    func drawSBWidget(_ g: CGContext, _ w: SBWidget, _ r: CGRect, now: Double, preview: Bool = false) {
        let a = HomeAppearance.current
        // 快照也照門：訪客的快照看到的是「需要主人」
        if w.kind.personal, !preview, !PersonalGate.allowed { drawSBLocked(g, w, r, a); return }
        switch (w.kind, w.size) {
        case (.photos, .small): drawPhotosWidget(g, r); return
        case (.weather, .small): drawWeatherWidget(g, r, appearance: a, preview: preview); return
        default: break
        }
        g.saveGState(); defer { g.restoreGState() }
        g.addPath(continuousRoundedRect(r, radius: Shell.widgetRadius)); g.clip()
        switch w.kind {
        case .photos: drawSBPhotos(g, w, r, a, preview)
        case .weather: drawSBWeather(g, w, r, a, preview)
        case .calendar: drawSBCalendar(g, w, r, a, preview, now)
        case .reminders: drawSBReminders(g, w, r, a, preview)
        case .music: drawSBMusic(g, w, r, a, preview, now)
        case .podcasts: drawSBPodcasts(g, w, r, a, preview)
        case .home: drawSBHome(g, w, r, a, preview)
        case .worldClock: drawSBWorldClock(g, w, r, a, preview)
        case .timers: drawSBTimers(g, w, r, a, preview)
        case .alarms: drawSBAlarms(g, w, r, a, preview)
        case .findMy: drawSBFindMy(g, w, r, a, preview)
        case .batteries: drawSBBatteries(g, w, r, a, preview)
        case .webApp: drawWebAppWidget(g, w, r, a, preview, now)   // 2.0 Web App（Shell/WebApps/AdaptiveCards.swift）
        }
    }

    // MARK: 共用

    private struct Ink { var primary: NSColor; var secondary: NSColor; var accent: NSColor }
    /// 底：全彩照這個小工具的色；清透／染色拿掉（主畫面上底下是玻璃）。回這一格的字色
    private func sbFrame(_ g: CGContext, _ r: CGRect, _ a: HomeAppearance, _ preview: Bool, top: NSColor, bottom: NSColor? = nil,
                         primary: NSColor, secondary: NSColor? = nil, accent: NSColor) -> Ink {
        let mode = a.renderMode(night: false)
        HPComponents.widgetFrame(g, r, top: top.cgColor, bottom: (bottom ?? top).cgColor, mode: mode, appearance: a, standalone: preview, radius: Shell.widgetRadius)
        if mode == .accented { let i = WidgetInk.of(a); return Ink(primary: i.primary, secondary: i.secondary, accent: i.accent) }
        return Ink(primary: primary, secondary: secondary ?? primary.withAlphaComponent(0.6), accent: accent)
    }
    /// 系統小工具的白／深底（淺色白、深色外觀 #1C1C1E）
    private func sbPlain(_ g: CGContext, _ r: CGRect, _ a: HomeAppearance, _ preview: Bool, accent: NSColor) -> Ink {
        let dark = a.widgetDark
        return sbFrame(g, r, a, preview, top: dark ? srgb(0x1C1C1E) : .white, primary: dark ? .white : .black,
                       secondary: (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.55), accent: accent)
    }
    private func t(_ g: CGContext, _ s: String, _ size: CGFloat, _ w: NSFont.Weight, _ x: CGFloat, _ y: CGFloat, _ c: NSColor, max: CGFloat) {
        let f = HPType.sf(size * SBK.K, w)
        drawLeft(g, Face.clipped(s, f, max), font: f, x: x, y: y, color: c)
    }
    private func tRight(_ g: CGContext, _ s: String, _ size: CGFloat, _ w: NSFont.Weight, _ right: CGFloat, _ y: CGFloat, _ c: NSColor) {
        let f = HPType.sf(size * SBK.K, w)
        drawLeft(g, s, font: f, x: right - Typo.width(s, f), y: y, color: c)
    }
    private func sym(_ g: CGContext, _ name: String, _ x: CGFloat, _ y: CGFloat, _ side: CGFloat, _ c: NSColor) {
        drawSymbol(g, name, in: CGRect(x: x, y: y, width: side * SBK.K, height: side * SBK.K), color: c)
    }
    /// 空狀態：符號＋一句話（HIG：說清楚為什麼是空的）
    private func sbEmpty(_ g: CGContext, _ r: CGRect, _ ink: Ink, symbol: String, _ msg: String) {
        let K = SBK.K, p = SBK.pad
        sym(g, symbol, r.minX + p, r.minY + p, 18, ink.accent)
        let f = HPType.sf(13 * K, .semibold)
        var y = r.minY + p + 22 * K + f.ascender
        for line in Face.photosWrap(msg, f, r.width - 2 * p, maxLines: r.height > 200 ? 3 : 1) {
            drawLeft(g, Face.clipped(line, f, r.width - 2 * p), font: f, x: r.minX + p, y: y, color: ink.secondary); y += f.ascender - f.descender + 2
        }
    }
    private func drawSBLocked(_ g: CGContext, _ w: SBWidget, _ r: CGRect, _ a: HomeAppearance) {
        g.saveGState(); defer { g.restoreGState() }
        g.addPath(continuousRoundedRect(r, radius: Shell.widgetRadius)); g.clip()
        let ink = sbPlain(g, r, a, false, accent: srgb(0x8E8E93))
        sbEmpty(g, r, ink, symbol: "lock.fill", String(format: L("sb.locked", "%@ · 需要主人"), w.kind.title))
    }
    private func timeText(_ d: Date) -> String {
        Face.shortTime(d)   // 2.0 depth：時制照系統
    }
    private func mmss(_ s: Double) -> String {
        let n = Int(s.rounded(.up)); return n >= 3600 ? String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60) : String(format: "%d:%02d", n / 60, n % 60)
    }

    // MARK: 照片（small 以外）

    private func drawSBPhotos(_ g: CGContext, _ w: SBWidget, _ r: CGRect, _ a: HomeAppearance, _ preview: Bool) {
        let src = PhotosWidgetSource.shared
        let px = Int((max(r.width, r.height) * renderPixelScale).rounded())
        if !preview { src.activate(px: px) { [weak self] in self?.forceDirty = true } }
        if preview || src.card == .photo {
            let img = (preview || OfficialDemo.on || src.image == nil) ? PhotosDemoArt.image(px: max(64, px)) : src.image!
            let im = WidgetImageTreatment.accented(img, appearance: a)
            let iw = CGFloat(im.width), ih = CGFloat(im.height), k = max(r.width / iw, r.height / ih)
            g.setAlpha(WidgetImageTreatment.alpha(a))
            drawUpright(g, im, in: CGRect(x: r.midX - iw * k / 2, y: r.midY - ih * k / 2, width: iw * k, height: ih * k))
            g.setAlpha(1)
            // 中、大：左下一行「精選照片」（iOS 照片小工具的回憶標題位置）
            if r.height > 300 {
                let f = HPType.sf(15 * SBK.K, .semibold)
                g.setShadow(offset: .zero, blur: 12, color: NSColor(white: 0, alpha: 0.5).cgColor)
                drawLeft(g, L("shell.photos.ask.title", "精选照片"), font: f, x: r.minX + SBK.pad, y: r.maxY - SBK.pad, color: .white)
                g.setShadow(offset: .zero, blur: 0, color: nil)
            }
            return
        }
        let ink = sbPlain(g, r, a, preview, accent: srgb(0xFF9500))
        let msg: String
        switch src.card {
        case .request: msg = L("shell.photos.ask.body", "允许读取「照片」，只在这台 Mac 上显示。")
        case .denied: msg = L("shell.photos.denied.body", "到系统设置的「隐私与安全性 › 照片」打开。")
        case .hidden: msg = L("guest.needsOwner", "需要主人")
        case .empty: msg = L("shell.photos.empty.body", "「照片」里有照片时，精选照片会显示在这里。")
        default: msg = L("shell.photos.ask.title", "精选照片")
        }
        sbEmpty(g, r, ink, symbol: "photo.on.rectangle", msg)
    }

    // MARK: 天氣（small 以外）

    private func drawSBWeather(_ g: CGContext, _ w: SBWidget, _ r: CGRect, _ a: HomeAppearance, _ preview: Bool) {
        let src = WeatherSource.shared
        var d: WeatherData?
        if preview || SBWidgetData.demo {
            d = WeatherData(temp: 22, hi: 25, lo: 19, code: 2, wind: 11, humidity: 76, aqi: nil, sunset: "18:42", city: L("city.cupertino", "库比蒂诺"), night: false,
                            hourly: (0..<6).map { WeatherHour(label: "\(10 + $0)", temp: 22 + Double($0 % 3), code: [2, 1, 0, 0, 1, 2][$0], night: false) },
                            daily: (0..<5).map { WeatherDay(date: "2026-10-\(25 + $0)", hi: 25 - Double($0), lo: 18 - Double($0 % 2), code: [2, 0, 61, 3, 1][$0]) })
        } else {
            src.activate { [weak self] in self?.forceDirty = true }
            d = src.data ?? Self.demoWeather
        }
        let night = d?.night == true, code = d?.code ?? 2
        let sky: (NSColor, NSColor) = night ? (srgb(0x0D1738), srgb(0x26335E))
            : [0, 1].contains(code) ? (srgb(0x408CE6), srgb(0x2B6BC9)) : [2, 3, 45, 48].contains(code) ? (srgb(0x6387B3), srgb(0x456691)) : (srgb(0x54667D), srgb(0x334259))
        let ink = sbFrame(g, r, a, preview, top: sky.0, bottom: sky.1, primary: .white, secondary: NSColor.white.withAlphaComponent(0.8), accent: .white)
        let K = SBK.K, p = SBK.pad
        guard let d else { sbEmpty(g, r, ink, symbol: "location.fill", L("sb.weather.loading", "正在获取天气…")); return }
        let imperial = Locale.current.measurementSystem == .us
        func temp(_ v: Double) -> String { "\(Int((imperial ? v * 9 / 5 + 32 : v).rounded()))°" }
        let symName: (Int, Bool) -> String = { c, n in let s = WeatherSky.of(code: c).symbol; return n ? s.night : s.day }
        let city = d.city ?? L("shell.weather.title", "天气")
        let hilo = String(format: L("weather.hiLo", "高 %d° 低 %d°"), Int((imperial ? d.hi * 9 / 5 + 32 : d.hi).rounded()), Int((imperial ? d.lo * 9 / 5 + 32 : d.lo).rounded()))
        if w.size == .wide {
            // 寬（2×1，高只有 61 pt）：左邊城市＋溫度，右邊符號＋狀況、高低溫
            let q = 11 * K
            t(g, city, 12, .semibold, r.minX + q, r.minY + q + 10 * K, ink.primary, max: r.width / 2 - q)
            t(g, temp(d.temp), 28, .regular, r.minX + q - 1 * K, r.maxY - q, ink.primary, max: r.width / 2)
            let cond = Face.weatherText(code), cf = HPType.sf(12 * SBK.K, .semibold)
            tRight(g, cond, 12, .semibold, r.maxX - q, r.minY + q + 10 * K, ink.primary)
            sym(g, symName(code, night), r.maxX - q - Typo.width(cond, cf) - 18 * K, r.minY + q, 13, ink.accent)
            tRight(g, hilo, 12, .medium, r.maxX - q, r.maxY - q, ink.secondary)
            return
        }
        // 中、大：上排城市＋溫度（左）、符號＋狀況＋高低（右）；下面逐時（中）＋五天（大）
        t(g, city, 15, .semibold, r.minX + p, r.minY + p + 14 * K, ink.primary, max: r.width / 2)
        t(g, temp(d.temp), 42, .regular, r.minX + p - 1.5 * K, r.minY + p + 56 * K, ink.primary, max: r.width / 2)
        sym(g, symName(code, night), r.maxX - p - 16 * K, r.minY + p, 16, ink.accent)
        tRight(g, Face.weatherText(code), 13, .semibold, r.maxX - p, r.minY + p + 36 * K, ink.primary)
        tRight(g, hilo, 13, .semibold, r.maxX - p, r.minY + p + 53 * K, ink.secondary)
        let hours = Array((d.hourly ?? []).prefix(6))
        let rowY = r.minY + p + 80 * K
        if !hours.isEmpty {
            let colW = (r.width - 2 * p) / CGFloat(hours.count)
            for (i, h) in hours.enumerated() {
                let cx = r.minX + p + colW * (CGFloat(i) + 0.5)
                let f = HPType.sf(12 * K, .medium), lab = i == 0 ? L("weather.now", "现在") : h.label
                drawLeft(g, lab, font: f, x: cx - Typo.width(lab, f) / 2, y: rowY + 12 * K, color: ink.secondary)
                drawSymbol(g, symName(h.code, h.night), in: CGRect(x: cx - 9 * K, y: rowY + 18 * K, width: 18 * K, height: 18 * K), color: ink.accent)
                let tt = temp(h.temp), tf = HPType.sf(13 * K, .semibold)
                drawLeft(g, tt, font: tf, x: cx - Typo.width(tt, tf) / 2 + 2 * K, y: rowY + 52 * K, color: ink.primary)
            }
        } else {
            let det = String(format: L("sb.weather.details", "风速 %d km/h · 湿度 %d%%"), Int(d.wind.rounded()), Int(d.humidity.rounded()))
            t(g, det, 13, .medium, r.minX + p, rowY + 30 * K, ink.secondary, max: r.width - 2 * p)
        }
        guard w.size == .large, let days = d.daily, !days.isEmpty else { return }
        let lo = days.map(\.lo).min() ?? 0, hi = days.map(\.hi).max() ?? 1
        var y = rowY + 78 * K
        let inF = DateFormatter(); inF.dateFormat = "yyyy-MM-dd"
        let outF = DateFormatter(); outF.locale = L10n.language.locale; outF.setLocalizedDateFormatFromTemplate("EEE")
        for (i, day) in days.prefix(5).enumerated() {
            g.setFillColor(ink.primary.withAlphaComponent(0.18).cgColor); g.fill(CGRect(x: r.minX + p, y: y - 17 * K, width: r.width - 2 * p, height: 1))
            let name = i == 0 ? L("weather.today", "今天") : inF.date(from: day.date).map { outF.string(from: $0) } ?? day.date
            t(g, name, 13, .semibold, r.minX + p, y, ink.primary, max: 60 * K)
            drawSymbol(g, symName(day.code, false), in: CGRect(x: r.minX + p + 64 * K, y: y - 13 * K, width: 16 * K, height: 16 * K), color: ink.accent)
            t(g, temp(day.lo), 13, .semibold, r.minX + p + 100 * K, y, ink.secondary, max: 40 * K)
            let bx = r.minX + p + 140 * K, bw = r.maxX - p - 40 * K - bx
            let bar = CGRect(x: bx, y: y - 8 * K, width: bw, height: 4 * K)
            g.addPath(HPComponents.capsulePath(bar)); g.setFillColor(ink.primary.withAlphaComponent(0.2).cgColor); g.fillPath()
            let x0 = bx + bw * CGFloat((day.lo - lo) / max(1, hi - lo)), x1 = bx + bw * CGFloat((day.hi - lo) / max(1, hi - lo))
            g.addPath(HPComponents.capsulePath(CGRect(x: x0, y: bar.minY, width: max(bar.height, x1 - x0), height: bar.height)))
            g.setFillColor((a.renderMode(night: false) == .accented ? ink.accent : srgb(0xFFC93D)).cgColor); g.fillPath()
            tRight(g, temp(day.hi), 13, .semibold, r.maxX - p, y, ink.primary)
            y += 36 * K
            if y > r.maxY - 8 { break }
        }
    }

    // MARK: 行事曆

    private func drawSBCalendar(_ g: CGContext, _ w: SBWidget, _ r: CGRect, _ a: HomeAppearance, _ preview: Bool, _ now: Double) {
        let ink = sbPlain(g, r, a, preview, accent: srgb(0xFF3B30))
        let K = SBK.K, p = SBK.pad
        let date = Face.displayDate
        let wd = DateFormatter(); wd.locale = L10n.language.locale; wd.setLocalizedDateFormatFromTemplate("EEEE")
        let day = "\(Calendar.current.component(.day, from: date))"
        let events = preview ? AgendaSource.demoEvents(now: date) : SBWidgetData.events(now: date)
        // 左欄：星期（紅）＋大日期
        let leftW: CGFloat = w.size == .small ? r.width - 2 * p : 120 * K
        t(g, wd.string(from: date).uppercased(), 11, .semibold, r.minX + p, r.minY + p + 10 * K, ink.accent, max: leftW)
        t(g, day, 32, .regular, r.minX + p - 1 * K, r.minY + p + 46 * K, ink.primary, max: leftW)
        guard let events else {
            let msg = L("sb.calendar.allow", "允许访问日历后，这里会显示接下来的日程。")
            if w.size == .small || w.size == .wide { t(g, msg, 12, .regular, r.minX + (w.size == .wide ? leftW : p), r.maxY - p, ink.secondary, max: r.width - leftW - p) }
            else { sbList(g, CGRect(x: r.minX + leftW, y: r.minY, width: r.width - leftW, height: r.height), [], ink, empty: msg) }
            return
        }
        let show = SBWidgetData.value(w, "show")
        func row(_ e: AgendaEvent, _ x: CGFloat, _ y: CGFloat, _ maxW: CGFloat) {
            g.addPath(HPComponents.capsulePath(CGRect(x: x, y: y - 28 * K, width: 4 * K, height: 31 * K))); g.setFillColor(srgb(e.color).cgColor); g.fillPath()
            t(g, e.title, 13, .semibold, x + 9 * K, y - 15 * K, ink.primary, max: maxW - 9 * K)
            let when = e.allDay ? L("calendar.allDay", "全天") : "\(timeText(e.start)) – \(timeText(e.end))"
            t(g, when, 12, .regular, x + 9 * K, y, ink.secondary, max: maxW - 9 * K)
        }
        switch w.size {
        case .small:
            if let e = events.first { row(e, r.minX + p, r.maxY - p, r.width - 2 * p) }
            else { t(g, L("sb.calendar.none", "今天没有日程"), 13, .regular, r.minX + p, r.maxY - p, ink.secondary, max: r.width - 2 * p) }
        case .wide:
            if let e = events.first { row(e, r.minX + leftW, r.minY + p + 46 * K, r.width - leftW - p) }
            else { t(g, L("sb.calendar.none", "今天没有日程"), 13, .regular, r.minX + leftW, r.minY + p + 46 * K, ink.secondary, max: r.width - leftW - p) }
        case .medium, .large:
            let n = w.size == .medium ? 3 : (show == "list" ? 7 : 6)
            let x = r.minX + p + leftW, maxW = r.maxX - p - x
            if events.isEmpty { t(g, L("sb.calendar.none", "今天没有日程"), 13, .regular, x, r.minY + p + 30 * K, ink.secondary, max: maxW); return }
            var y = r.minY + p + 31 * K
            for e in events.prefix(n) { row(e, x, y, maxW); y += 44 * K; if y > r.maxY - 6 { break } }
        }
    }

    /// 清單型小工具的空狀態
    private func sbList(_ g: CGContext, _ r: CGRect, _ rows: [String], _ ink: Ink, empty: String) {
        let K = SBK.K, p = SBK.pad
        let f = HPType.sf(13 * K, .regular)
        var y = r.minY + p + 30 * K
        for line in Face.photosWrap(empty, f, r.width - 2 * p, maxLines: 3) {
            drawLeft(g, Face.clipped(line, f, r.width - 2 * p), font: f, x: r.minX + p, y: y, color: ink.secondary); y += 20 * K
        }
    }

    // MARK: 提醒事項

    private func drawSBReminders(_ g: CGContext, _ w: SBWidget, _ r: CGRect, _ a: HomeAppearance, _ preview: Bool) {
        let K = SBK.K, p = SBK.pad
        let data = preview ? { () -> (String, NSColor, [ReminderItem])? in
            let d = ReminderSource.demoData(now: Face.displayDate); return (L("sb.opt.today", "今天"), srgb(0x0A84FF), d.0.filter { !$0.completed })
        }() : SBWidgetData.reminders(list: SBWidgetData.value(w, "list"), now: Face.displayDate)
        let ink = sbPlain(g, r, a, preview, accent: data?.1 ?? srgb(0x0A84FF))
        guard let (title, _, items) = data else { sbEmpty(g, r, ink, symbol: "checklist", L("sb.reminders.allow", "允许访问提醒事项后，这里会显示要做的事。")); return }
        t(g, title, 15, .bold, r.minX + p, r.minY + p + 14 * K, ink.accent, max: r.width - 2 * p - 40 * K)
        tRight(g, "\(items.count)", 22, .bold, r.maxX - p, r.minY + p + 18 * K, ink.primary)
        if items.isEmpty { t(g, L("sb.reminders.none", "没有提醒事项"), 13, .regular, r.minX + p, r.minY + p + 50 * K, ink.secondary, max: r.width - 2 * p); return }
        let n = w.size == .small ? 3 : (w.size == .medium ? 4 : 10)
        let cols = w.size == .small ? 1 : (w.size == .medium ? 2 : 1)
        let colW = (r.width - 2 * p) / CGFloat(cols)
        for (i, it) in items.prefix(n * cols).enumerated() {
            let c = cols == 1 ? 0 : i / n, rr = cols == 1 ? i : i % n
            let x = r.minX + p + CGFloat(c) * colW, y = r.minY + p + (w.size == .small ? 46 : 50) * K + CGFloat(rr) * 26 * K
            guard y < r.maxY - 4 * K else { break }
            g.setStrokeColor(ink.secondary.cgColor); g.setLineWidth(1.4 * K); g.strokeEllipse(in: CGRect(x: x, y: y - 11 * K, width: 13 * K, height: 13 * K))
            t(g, it.title, 13, .regular, x + 20 * K, y, ink.primary, max: colW - 24 * K)
        }
    }

    // MARK: 音樂、Podcast

    private func sbArt(_ g: CGContext, _ r: CGRect, colors: (NSColor, NSColor), symbol: String) {
        let path = continuousRoundedRect(r, radius: r.width * 0.12)
        g.saveGState(); g.addPath(path); g.clip()
        let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [colors.0.cgColor, colors.1.cgColor] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(grad, start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
        g.restoreGState()
        drawSymbol(g, symbol, in: r.insetBy(dx: r.width * 0.32, dy: r.height * 0.32), color: NSColor.white.withAlphaComponent(0.85))
    }

    private func drawSBMusic(_ g: CGContext, _ w: SBWidget, _ r: CGRect, _ a: HomeAppearance, _ preview: Bool, _ now: Double) {
        let K = SBK.K, p = SBK.pad
        let info = preview ? NowPlayingInfo(title: "Blue Hour", artist: "Nova Sato", duration: 214, position: 81, playing: true, stamp: now, fixed: true)   // l10n-ignore：示範曲名
            : SBWidgetData.nowPlaying(self, now: now)
        let ink = sbFrame(g, r, a, preview, top: srgb(0x3A1C2E), bottom: srgb(0x1B0F18), primary: .white, secondary: NSColor.white.withAlphaComponent(0.62), accent: srgb(0xFA2D48))
        let artColors = (srgb(0xFF5E7A), srgb(0x8C1D40))
        guard let info else {
            let side = min(r.height - 2 * p, 64 * K)
            sbArt(g, CGRect(x: r.minX + p, y: r.minY + p, width: side, height: side), colors: (srgb(0x5A5A60), srgb(0x2C2C30)), symbol: "music.note")
            t(g, L("cc.notPlaying", "未在播放"), 13, .semibold, r.minX + p, r.maxY - p, ink.secondary, max: r.width - 2 * p)
            return
        }
        let play = info.playing ? "pause.fill" : "play.fill"
        switch w.size {
        case .small:
            sbArt(g, CGRect(x: r.minX + p, y: r.minY + p, width: 72 * K, height: 72 * K), colors: artColors, symbol: "music.note")
            t(g, info.title, 13, .semibold, r.minX + p, r.maxY - p - 17 * K, ink.primary, max: r.width - 2 * p)
            t(g, info.artist, 13, .regular, r.minX + p, r.maxY - p, ink.secondary, max: r.width - 2 * p)
        case .wide:
            let side = r.height - 2 * p * 0.6
            sbArt(g, CGRect(x: r.minX + p * 0.6, y: r.minY + p * 0.6, width: side, height: side), colors: artColors, symbol: "music.note")
            let x = r.minX + p * 0.6 + side + 12 * K
            t(g, info.title, 14, .semibold, x, r.midY - 3 * K, ink.primary, max: r.maxX - x - 40 * K)
            t(g, info.artist, 13, .regular, x, r.midY + 15 * K, ink.secondary, max: r.maxX - x - 40 * K)
            sym(g, play, r.maxX - p - 18 * K, r.midY - 9 * K, 18, ink.primary)
        case .medium, .large:
            let side = w.size == .medium ? r.height - 2 * p : r.width * 0.5
            let art = CGRect(x: r.minX + p, y: r.minY + p, width: side, height: side)
            sbArt(g, art, colors: artColors, symbol: "music.note")
            let x = w.size == .medium ? art.maxX + 16 * K : r.minX + p
            let top = w.size == .medium ? r.minY + p : art.maxY + 14 * K
            let maxW = r.maxX - p - x
            t(g, L("sb.music.nowPlaying", "正在播放"), 12, .semibold, x, top + 12 * K, ink.accent, max: maxW)
            t(g, info.title, 17, .semibold, x, top + 36 * K, ink.primary, max: maxW)
            t(g, info.artist, 14, .regular, x, top + 56 * K, ink.secondary, max: maxW)
            if let pr = NowPlayingLogic.progress(info, now: now) {
                let bar = CGRect(x: x, y: top + 72 * K, width: maxW, height: 4 * K)
                g.addPath(HPComponents.capsulePath(bar)); g.setFillColor(ink.primary.withAlphaComponent(0.25).cgColor); g.fillPath()
                g.addPath(HPComponents.capsulePath(CGRect(x: bar.minX, y: bar.minY, width: max(bar.height, bar.width * CGFloat(pr)), height: bar.height)))
                g.setFillColor(ink.primary.cgColor); g.fillPath()
            }
            let cy = (w.size == .medium ? r.maxY - p : top + 120 * K) - 20 * K
            for (i, s) in ["backward.fill", play, "forward.fill"].enumerated() {
                sym(g, s, x + CGFloat(i) * 52 * K, cy, 22, ink.primary)
            }
        }
    }

    private func drawSBPodcasts(_ g: CGContext, _ w: SBWidget, _ r: CGRect, _ a: HomeAppearance, _ preview: Bool) {
        let K = SBK.K, p = SBK.pad
        let ink = sbFrame(g, r, a, preview, top: srgb(0x8E3FD1), bottom: srgb(0x52168F), primary: .white, secondary: NSColor.white.withAlphaComponent(0.7), accent: .white)
        let demo = preview || SBWidgetData.demo
        let side = w.size == .wide ? r.height - 1.2 * p : 64 * K
        let art = CGRect(x: r.minX + (w.size == .wide ? 0.6 * p : p), y: r.minY + (w.size == .wide ? 0.6 * p : p), width: side, height: side)
        sbArt(g, art, colors: (srgb(0xF2A3FF), srgb(0x7A2BC4)), symbol: "mic.fill")
        let title = demo ? L("sb.podcasts.demoShow", "安静的科学") : L("sb.widget.podcasts", "播客")
        let ep = demo ? L("sb.podcasts.demoEpisode", "为什么我们喜欢听雨声") : L("sb.podcasts.open", "打开「播客」继续收听")
        let x = w.size == .wide ? art.maxX + 12 * K : r.minX + p
        let maxW = r.maxX - p - x
        if w.size == .wide {
            t(g, title, 12, .semibold, x, r.midY - 8 * K, ink.secondary, max: maxW)
            t(g, ep, 14, .semibold, x, r.midY + 10 * K, ink.primary, max: maxW)
            return
        }
        t(g, L("sb.podcasts.upNext", "接着听"), 12, .semibold, x, r.maxY - p - 34 * K, ink.secondary, max: maxW)
        t(g, ep, 14, .semibold, x, r.maxY - p - 16 * K, ink.primary, max: maxW)
        t(g, title, 12, .regular, x, r.maxY - p, ink.secondary, max: maxW)
        if w.size == .medium {
            let rx = r.minX + r.width / 2 + 8 * K
            for (i, s) in [L("sb.podcasts.demo2", "城市的声音"), L("sb.podcasts.demo3", "一分钟历史")].enumerated() where demo {
                sbArt(g, CGRect(x: rx, y: r.minY + p + CGFloat(i) * 70 * K, width: 56 * K, height: 56 * K), colors: i == 0 ? (srgb(0xFFB35C), srgb(0xD9480F)) : (srgb(0x5CC8FF), srgb(0x1C6DD0)), symbol: "waveform")
                t(g, s, 13, .semibold, rx + 66 * K, r.minY + p + CGFloat(i) * 70 * K + 33 * K, ink.primary, max: r.maxX - p - rx - 66 * K)
            }
        }
    }

    // MARK: 家庭

    private func drawSBHome(_ g: CGContext, _ w: SBWidget, _ r: CGRect, _ a: HomeAppearance, _ preview: Bool) {
        let K = SBK.K, p = SBK.pad * 0.6
        let ink = sbFrame(g, r, a, preview, top: srgb(0xF29A38), bottom: srgb(0xE0702B), primary: .white, secondary: NSColor.white.withAlphaComponent(0.75), accent: .white)
        let room = SBWidgetData.value(w, "room")
        let groups = preview ? HomeAppModel.groups(HomeAppModel.demoSnapshot()) : SBWidgetData.homeGroups()
        let tiles = groups.filter { room == "all" || $0.id == room }.flatMap(\.tiles)
        if tiles.isEmpty { sbEmpty(g, r, ink, symbol: "house.fill", L("sb.home.none", "打开「家庭」添加配件后，这里会显示它们。")); return }
        let (cols, rows): (Int, Int) = { switch w.size { case .small: return (2, 2); case .wide: return (2, 1); case .medium: return (4, 2); case .large: return (4, 3) } }()
        let gap = 8 * K
        let tw = (r.width - 2 * p - CGFloat(cols - 1) * gap) / CGFloat(cols), th = (r.height - 2 * p - CGFloat(rows - 1) * gap) / CGFloat(rows)
        let mode = a.renderMode(night: false)
        for (i, tile) in tiles.prefix(cols * rows).enumerated() {
            let tr = CGRect(x: r.minX + p + CGFloat(i % cols) * (tw + gap), y: r.minY + p + CGFloat(i / cols) * (th + gap), width: tw, height: th)
            let on = tile.on || tile.locked == true
            let fill = mode == .accented ? ink.primary.withAlphaComponent(on ? 0.3 : 0.12) : (on ? NSColor.white : NSColor.white.withAlphaComponent(0.22))
            g.addPath(continuousRoundedRect(tr, radius: min(tw, th) * 0.22)); g.setFillColor(fill.cgColor); g.fillPath()
            let fg: NSColor = mode == .accented ? ink.primary : (on ? .black : .white)
            let s = min(tw, th)
            drawSymbol(g, tile.symbol, in: CGRect(x: tr.minX + s * 0.14, y: tr.minY + s * 0.14, width: s * 0.3, height: s * 0.3),
                       color: mode == .accented ? ink.accent : (on ? srgb(0xF29A38) : .white))
            let nf = HPType.sf(min(13 * K, s * 0.17), .semibold), sf = HPType.sf(min(12 * K, s * 0.15), .regular)
            drawLeft(g, Face.clipped(tile.name, nf, tw - s * 0.28), font: nf, x: tr.minX + s * 0.14, y: tr.maxY - s * 0.14 - sf.pointSize - 2, color: fg)
            drawLeft(g, Face.clipped(tile.status, sf, tw - s * 0.28), font: sf, x: tr.minX + s * 0.14, y: tr.maxY - s * 0.14, color: fg.withAlphaComponent(0.6))
        }
    }

    // MARK: 世界時鐘

    private func sbClockFace(_ g: CGContext, _ cr: CGRect, tz: TimeZone, ink: Ink, dark: Bool) {
        let center = CGPoint(x: cr.midX, y: cr.midY), K = cr.width / 100
        for i in 0..<12 {
            let ang = CGFloat(i) / 12 * .pi * 2
            let r0 = cr.width / 2 - (i % 3 == 0 ? 9 : 6) * K, r1 = cr.width / 2 - 2 * K
            g.move(to: CGPoint(x: center.x + sin(ang) * r0, y: center.y - cos(ang) * r0))
            g.addLine(to: CGPoint(x: center.x + sin(ang) * r1, y: center.y - cos(ang) * r1))
        }
        g.setStrokeColor(ink.secondary.cgColor); g.setLineWidth(1.6 * K); g.setLineCap(.round); g.strokePath()
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let comp = cal.dateComponents([.hour, .minute], from: Face.displayDate)
        let h = CGFloat((comp.hour ?? 10) % 12), m = CGFloat(comp.minute ?? 9)
        func hand(_ frac: CGFloat, _ len: CGFloat, _ wd: CGFloat, _ col: NSColor) {
            let ang = frac * .pi * 2
            g.move(to: center); g.addLine(to: CGPoint(x: center.x + sin(ang) * len, y: center.y - cos(ang) * len))
            g.setStrokeColor(col.cgColor); g.setLineWidth(wd); g.setLineCap(.round); g.strokePath()
        }
        hand((h + m / 60) / 12, 26 * K, 4 * K, ink.primary)
        hand(m / 60, 38 * K, 3 * K, ink.primary)
        g.setFillColor(ink.accent.cgColor); g.fillEllipse(in: CGRect(x: center.x - 3 * K, y: center.y - 3 * K, width: 6 * K, height: 6 * K))
    }

    private func drawSBWorldClock(_ g: CGContext, _ w: SBWidget, _ r: CGRect, _ a: HomeAppearance, _ preview: Bool) {
        let K = SBK.K
        let ink = sbPlain(g, r, a, preview, accent: srgb(0xFF9500))
        let chosen = SBWidgetData.value(w, "city")
        var zones: [(TimeZone, String)] = WorldClockApp.cities()
        if let c = WorldClockApp.candidates.first(where: { $0.zone == chosen }), let tz = TimeZone(identifier: c.zone) {
            zones.removeAll { $0.0.identifier == tz.identifier }; zones.insert((tz, c.name()), at: 0)
        }
        func offset(_ tz: TimeZone) -> String {
            String(format: L("home.worldClock.offset", "%+d 小时"), (tz.secondsFromGMT(for: Face.displayDate) - TimeZone.current.secondsFromGMT(for: Face.displayDate)) / 3600)
        }
        let n: Int = { switch w.size { case .small: return 1; case .wide: return 2; case .medium: return 4; case .large: return 6 } }()
        if w.size == .large {
            // 大：一列一個城市（名字、時差、數字時間）
            let p = SBK.pad
            let tf = DateFormatter(); tf.locale = L10n.language.locale; Face.setTimeFormat(tf)
            var y = r.minY + p + 40 * K
            for (tz, name) in zones.prefix(n) {
                tf.timeZone = tz
                t(g, name, 17, .semibold, r.minX + p, y - 14 * K, ink.primary, max: r.width / 2)
                t(g, offset(tz), 13, .regular, r.minX + p, y + 4 * K, ink.secondary, max: r.width / 2)
                tRight(g, tf.string(from: Face.displayDate), 30, .light, r.maxX - p, y + 4 * K, ink.primary)
                y += 52 * K
                if y > r.maxY { break }
            }
            return
        }
        let cellW = r.width / CGFloat(n)
        for (i, (tz, name)) in zones.prefix(n).enumerated() {
            let cx = r.minX + cellW * (CGFloat(i) + 0.5)
            let d = w.size == .wide ? min(r.height * 0.6, 100 * K) : min(cellW - 20 * K, 100 * K)
            let cr = CGRect(x: cx - d / 2, y: r.minY + (w.size == .wide ? 10 * K : 12 * K), width: d, height: d)
            sbClockFace(g, cr, tz: tz, ink: ink, dark: a.widgetDark)
            let nf = HPType.sf(13 * K, .semibold), sf = HPType.sf(11 * K, .regular)
            let nm = Face.clipped(name, nf, cellW - 12 * K), off = offset(tz)
            let base = w.size == .wide ? r.maxY - 8 * K : r.maxY - 24 * K
            drawLeft(g, nm, font: nf, x: cx - Typo.width(nm, nf) / 2, y: base - (w.size == .wide ? 0 : 0), color: ink.primary)
            if w.size != .wide { drawLeft(g, off, font: sf, x: cx - Typo.width(off, sf) / 2, y: r.maxY - 10 * K, color: ink.secondary) }
        }
    }

    // MARK: 計時器、鬧鐘

    private func drawSBTimers(_ g: CGContext, _ w: SBWidget, _ r: CGRect, _ a: HomeAppearance, _ preview: Bool) {
        let K = SBK.K, p = SBK.pad
        let ink = sbFrame(g, r, a, preview, top: srgb(0x1C1C1E), bottom: srgb(0x0E0E10), primary: .white, secondary: NSColor.white.withAlphaComponent(0.55), accent: srgb(0xFF9F0A))
        let ts = preview ? [(L("shell.demo.pasta", "意大利面"), 272.0, 0.45)] : SBWidgetData.timers()
        if ts.isEmpty { sbEmpty(g, r, ink, symbol: "timer", L("sb.timers.none", "没有正在进行的计时器")); return }
        func ring(_ c: CGPoint, _ rad: CGFloat, _ frac: Double) {
            g.setLineWidth(5 * K); g.setLineCap(.round)
            g.setStrokeColor(ink.accent.withAlphaComponent(0.25).cgColor); g.strokeEllipse(in: CGRect(x: c.x - rad, y: c.y - rad, width: 2 * rad, height: 2 * rad))
            g.addArc(center: c, radius: rad, startAngle: -.pi / 2, endAngle: -.pi / 2 + .pi * 2 * CGFloat(frac), clockwise: false)
            g.setStrokeColor(ink.accent.cgColor); g.strokePath()
        }
        switch w.size {
        case .small:
            let x = ts[0]
            ring(CGPoint(x: r.minX + p + 26 * K, y: r.minY + p + 26 * K), 24 * K, x.frac)
            sym(g, "timer", r.minX + p + 18 * K, r.minY + p + 18 * K, 16, ink.accent)
            t(g, mmss(x.left), 30, .medium, r.minX + p, r.maxY - p - 18 * K, ink.accent, max: r.width - 2 * p)
            t(g, x.label, 13, .semibold, r.minX + p, r.maxY - p, ink.primary, max: r.width - 2 * p)
        case .wide, .medium, .large:
            let n = w.size == .wide ? 1 : 3
            let colW = r.width - 2 * p
            for (i, x) in ts.prefix(n).enumerated() {
                let ox = r.minX + p + (w.size == .wide ? CGFloat(i) * colW : 0)
                let oy = w.size == .wide ? r.midY : r.minY + p + 40 * K + CGFloat(i) * 52 * K
                ring(CGPoint(x: ox + 18 * K, y: oy), 16 * K, x.frac)
                t(g, mmss(x.left), 22, .medium, ox + 42 * K, oy + 2 * K, ink.accent, max: colW - 46 * K)
                t(g, x.label, 12, .semibold, ox + 42 * K, oy + 18 * K, ink.secondary, max: colW - 46 * K)
            }
        }
    }

    private func drawSBAlarms(_ g: CGContext, _ w: SBWidget, _ r: CGRect, _ a: HomeAppearance, _ preview: Bool) {
        let K = SBK.K, p = SBK.pad
        let ink = sbFrame(g, r, a, preview, top: srgb(0x1C1C1E), bottom: srgb(0x0E0E10), primary: .white, secondary: NSColor.white.withAlphaComponent(0.55), accent: srgb(0xFF9F0A))
        let al = preview ? [AlarmItem(id: 1, hour: 6, minute: 30, label: L("sb.alarm.wake", "起床"), days: [2, 3, 4, 5, 6], enabled: true)] : SBWidgetData.alarms()
        let now = Face.displayDate
        func hm(_ x: AlarmItem) -> String {
            var dc = DateComponents(); dc.hour = x.hour; dc.minute = x.minute
            return timeText(Calendar.current.date(from: dc) ?? now)
        }
        guard let next = AlarmLogic.soonest(al, after: now) else {
            sbEmpty(g, r, ink, symbol: "alarm", al.isEmpty ? L("sb.alarms.none", "没有闹钟") : L("sb.alarms.off", "闹钟都关着")); return
        }
        sym(g, "alarm.fill", r.minX + (w.size == .wide ? 11 * K : p), r.minY + (w.size == .wide ? 11 * K : p), w.size == .wide ? 13 : 16, ink.accent)
        let rel = DateComponentsFormatter(); rel.allowedUnits = [.hour, .minute]; rel.unitsStyle = .abbreviated
        let inText = rel.string(from: now, to: next.1) ?? ""
        if w.size == .small {
            t(g, hm(next.0), 30, .medium, r.minX + p, r.maxY - p - 36 * K, ink.primary, max: r.width - 2 * p)
            t(g, next.0.label, 13, .semibold, r.minX + p, r.maxY - p - 17 * K, ink.primary, max: r.width - 2 * p)
            t(g, inText, 12, .regular, r.minX + p, r.maxY - p, ink.secondary, max: r.width - 2 * p)
            return
        }
        if w.size == .wide {
            // 寬：左上符號＋名稱、右上還有多久；下面一整行時間
            let q = 11 * K
            t(g, next.0.label, 12, .semibold, r.minX + q + 18 * K, r.minY + q + 10 * K, ink.primary, max: r.width * 0.45)
            tRight(g, inText, 12, .regular, r.maxX - q, r.minY + q + 10 * K, ink.secondary)
            t(g, hm(next.0), 26, .medium, r.minX + q, r.maxY - q, ink.primary, max: r.width - 2 * q)
            return
        }
        var y = r.minY + p + 52 * K
        for x in al.prefix(3) {
            t(g, hm(x), 24, .medium, r.minX + p, y, x.enabled ? ink.primary : ink.secondary, max: r.width / 2)
            t(g, x.label, 13, .regular, r.minX + p + r.width * 0.42, y - 2 * K, ink.secondary, max: r.width * 0.35)
            let sw = CGRect(x: r.maxX - p - 40 * K, y: y - 20 * K, width: 40 * K, height: 22 * K)
            g.addPath(HPComponents.capsulePath(sw)); g.setFillColor((x.enabled ? srgb(0x30D158) : NSColor.white.withAlphaComponent(0.25)).cgColor); g.fillPath()
            g.setFillColor(NSColor.white.cgColor); g.fillEllipse(in: CGRect(x: x.enabled ? sw.maxX - 20 * K : sw.minX + 2 * K, y: sw.minY + 2 * K, width: 18 * K, height: 18 * K))
            y += 40 * K
        }
    }

    // MARK: 尋找、電池

    private func drawSBFindMy(_ g: CGContext, _ w: SBWidget, _ r: CGRect, _ a: HomeAppearance, _ preview: Bool) {
        let K = SBK.K, p = SBK.pad
        let show = SBWidgetData.value(w, "show")
        let items = preview ? FindMyModel.demoPeople() : SBWidgetData.findMy(show)
        // 地圖：淺綠底＋幾條路（示意，不是真地圖）；清透／染色時拿掉
        let ink = sbFrame(g, r, a, preview, top: srgb(0xE3EAD8), bottom: srgb(0xD3E0C4), primary: .black, secondary: NSColor.black.withAlphaComponent(0.55), accent: srgb(0x34C759))
        let mapR = w.size == .medium ? CGRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height) : (w.size == .large ? CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.55) : r)
        if a.renderMode(night: false) == .fullColor {
            g.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor); g.setLineWidth(9 * K)
            g.move(to: CGPoint(x: mapR.minX, y: mapR.minY + mapR.height * 0.62)); g.addLine(to: CGPoint(x: mapR.maxX, y: mapR.minY + mapR.height * 0.38)); g.strokePath()
            g.setLineWidth(6 * K)
            g.move(to: CGPoint(x: mapR.minX + mapR.width * 0.35, y: mapR.minY)); g.addLine(to: CGPoint(x: mapR.minX + mapR.width * 0.55, y: mapR.maxY)); g.strokePath()
        }
        if items.isEmpty { sbEmpty(g, r, ink, symbol: "person.2.fill", L("sb.findMy.none", "在「查找」里共享位置的人会显示在这里。")); return }
        for it in items {
            let c = CGPoint(x: mapR.minX + mapR.width * it.spot.x, y: mapR.minY + mapR.height * it.spot.y)
            let d = 30 * K
            g.setFillColor(NSColor.white.cgColor); g.fillEllipse(in: CGRect(x: c.x - d / 2 - 2 * K, y: c.y - d / 2 - 2 * K, width: d + 4 * K, height: d + 4 * K))
            g.setFillColor(srgb(it.tint).cgColor); g.fillEllipse(in: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))
            if it.kind == .device { drawSymbol(g, it.symbol, in: CGRect(x: c.x - d * 0.3, y: c.y - d * 0.3, width: d * 0.6, height: d * 0.6), color: .white) }
            else {
                let s = String(it.name.prefix(1)), f = HPType.sf(14 * K, .bold)
                drawLeft(g, s, font: f, x: c.x - Typo.width(s, f) / 2, y: c.y + f.capHeight / 2, color: .white)
            }
        }
        let first = items[0]
        switch w.size {
        case .small, .wide:
            t(g, first.name, 13, .semibold, r.minX + p, r.maxY - p - 16 * K, ink.primary, max: r.width - 2 * p)
            t(g, "\(first.place) · \(first.time)", 12, .regular, r.minX + p, r.maxY - p, ink.secondary, max: r.width - 2 * p)
        case .medium, .large:
            let x = w.size == .medium ? mapR.maxX + p : r.minX + p
            var y = w.size == .medium ? r.minY + p + 22 * K : mapR.maxY + 28 * K
            for it in items.prefix(w.size == .medium ? 3 : 4) {
                t(g, it.name, 14, .semibold, x, y, ink.primary, max: r.maxX - p - x)
                t(g, "\(it.place) · \(it.time)", 12, .regular, x, y + 17 * K, ink.secondary, max: r.maxX - p - x)
                y += 44 * K
            }
        }
    }

    private func drawSBBatteries(_ g: CGContext, _ w: SBWidget, _ r: CGRect, _ a: HomeAppearance, _ preview: Bool) {
        let K = SBK.K, p = SBK.pad
        let ink = sbPlain(g, r, a, preview, accent: srgb(0x30D158))
        let bs = preview ? Array(SBWidgetData.batteries().prefix(1)) + [SBWidgetData.Battery(name: "iPhone", symbol: "iphone", level: 0.64, charging: false)]   // l10n-ignore：裝置名
            : SBWidgetData.batteries()
        func ring(_ b: SBWidgetData.Battery, _ c: CGPoint, _ rad: CGFloat) {
            let col = (b.level ?? 1) < 0.2 ? srgb(0xFF3B30) : ink.accent
            g.setLineWidth(6 * K); g.setLineCap(.round)
            g.setStrokeColor(ink.primary.withAlphaComponent(0.12).cgColor); g.strokeEllipse(in: CGRect(x: c.x - rad, y: c.y - rad, width: 2 * rad, height: 2 * rad))
            if let lv = b.level {
                g.addArc(center: c, radius: rad, startAngle: -.pi / 2, endAngle: -.pi / 2 + .pi * 2 * CGFloat(lv), clockwise: false)
                g.setStrokeColor(col.cgColor); g.strokePath()
            }
            drawSymbol(g, b.symbol, in: CGRect(x: c.x - rad * 0.5, y: c.y - rad * 0.5, width: rad, height: rad), color: ink.primary)
            if b.charging { drawSymbol(g, "bolt.fill", in: CGRect(x: c.x + rad * 0.45, y: c.y - rad * 1.05, width: rad * 0.45, height: rad * 0.45), color: col) }
        }
        func pct(_ b: SBWidgetData.Battery) -> String { b.level.map { "\(Int(($0 * 100).rounded()))%" } ?? L("sb.battery.power", "电源") }
        switch w.size {
        case .small:
            for (i, b) in bs.prefix(4).enumerated() {
                let c = CGPoint(x: r.minX + r.width * (i % 2 == 0 ? 0.28 : 0.72), y: r.minY + r.height * (i / 2 == 0 ? 0.28 : 0.72))
                ring(b, c, 30 * K)
            }
        case .wide, .medium:
            let n = max(1, min(4, bs.count)), cw = (r.width - 2 * p) / 4
            for (i, b) in bs.prefix(n).enumerated() {
                let cx = r.minX + p + cw * (CGFloat(i) + 0.5)
                let rad = (w.size == .wide ? 24 : 32) * K
                ring(b, CGPoint(x: cx, y: r.minY + (w.size == .wide ? r.height / 2 : p + rad + 8 * K)), rad)
                if w.size == .medium {
                    let s = pct(b), f = HPType.sf(15 * K, .semibold)
                    drawLeft(g, s, font: f, x: cx - Typo.width(s, f) / 2, y: r.maxY - p, color: ink.primary)
                }
            }
        case .large:
            var y = r.minY + p + 30 * K
            for b in bs.prefix(6) {
                drawSymbol(g, b.symbol, in: CGRect(x: r.minX + p, y: y - 20 * K, width: 22 * K, height: 22 * K), color: ink.primary)
                t(g, b.name, 15, .semibold, r.minX + p + 32 * K, y - 4 * K, ink.primary, max: r.width * 0.5)
                tRight(g, pct(b), 15, .semibold, r.maxX - p, y - 4 * K, ink.primary)
                let bar = CGRect(x: r.minX + p + 32 * K, y: y + 6 * K, width: r.width - 2 * p - 32 * K, height: 6 * K)
                g.addPath(HPComponents.capsulePath(bar)); g.setFillColor(ink.primary.withAlphaComponent(0.12).cgColor); g.fillPath()
                if let lv = b.level {
                    g.addPath(HPComponents.capsulePath(CGRect(x: bar.minX, y: bar.minY, width: max(bar.height, bar.width * CGFloat(lv)), height: bar.height)))
                    g.setFillColor(ink.accent.cgColor); g.fillPath()
                }
                y += 50 * K
            }
        }
    }
}
