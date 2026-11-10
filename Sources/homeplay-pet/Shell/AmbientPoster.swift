// Ambient 海報場景（HomeView 對齊，拍板 2026-11-05）：進入 Ambient 就換到「專用海報」——官方海報式，
// 不是在當前錶面上加東西。構成照官方海報的四層 Look token：
//   background＝全幅底、numerals＝大數字、secondary＝日期與卡片文字、accent＝強調。
// 下半是 StandBy 式活動堆疊：頂端膠囊同一份 LiveActivity（計時器/正在播放/天氣…）畫成一排卡片。
// 離開 Ambient（意圖輸入）畫面交回原本的錶面／外殼，原狀恢復。
import AppKit

extension Shell {
    /// 海報要不要接手畫面：在 Ambient 階段（還沒睡）而且外殼收乾淨（face 螢幕、無 overlay）。
    /// 睡著時（displayAsleep）壓暗層蓋在 海報 上＝官方「熄屏」的桌寫照。
    static var ambientPosterActive: Bool {
        (ambientSince != nil || AmbientPoster.demo) && !displayAsleep && DisplaySettings.ambientEnabled
            && nav.screen == .face && nav.overlay == .none && !FaceOverview.active
    }
}

enum AmbientPoster {
    // MARK: 版面（純邏輯，自檢釘住）
    static let timeSize: CGFloat = 300
    static let timeBaseline: CGFloat = 430
    static let dateBaseline: CGFloat = 520
    static let dateSize: CGFloat = 44
    static let cardX: CGFloat = 112, cardW: CGFloat = 800, cardH: CGFloat = 104, cardGap: CGFloat = 24   // 後續 #6：132→104，三張卡收在畫布內（底緣 1000）
    static let cardsTop: CGFloat = 640
    static let maxCards = 3

    /// 第 i 張活動卡的矩形（1024 畫布、左上原點）
    static func cardRect(_ i: Int) -> CGRect {
        CGRect(x: cardX, y: cardsTop + CGFloat(i) * (cardH + cardGap), width: cardW, height: cardH)
    }

    /// 疊不疊 StandBy 卡：時鐘那一張換成別的版式（月格子、complication 槽）時不疊——下半已經是內容；天氣、照片照疊
    static func showsCards(_ style: PosterConfiguration.Style, kind: Kind) -> Bool { kind != .clock || style == .time }

    /// 要上卡片的活動（頂端膠囊同一份，最多 maxCards 張）
    static func cards(_ acts: [LiveActivity]) -> [LiveActivity] { Array(acts.prefix(maxCards)) }

    // MARK: 輪播（HomeView 對齊後續 #6）
    enum Kind: String, CaseIterable { case clock, weather, photos }
    /// 每張停留（秒）與交叉淡化（秒；減少動態效果時直接切）
    static let dwell = 30.0
    static let fade = 0.4
    /// 快照：--ambient-poster weather|photos|clock 強制指定（不輪）
    nonisolated(unsafe) static var forced: Kind?
    /// 快照：--demo-ambient 一開就停在 Ambient 海報期（不被這一刻的靠近／活躍判定拉回）
    nonisolated(unsafe) static var demo = false

    /// 輪得到哪幾張：時鐘永遠在；天氣有資料、照片架有照片才輪入（順序固定：時鐘 → 天氣 → 照片）
    static func available(weather: Bool, photos: Bool) -> [Kind] {
        [.clock] + (weather ? [.weather] : []) + (photos ? [.photos] : [])
    }

    // MARK: 近期使用優先（錶面體系：官方輪播照近期使用排序，rushmore／固件類別名見 docs/plans/firmware-alignment.md）
    /// 「用過」＝進海報期之前人在用的那張錶面對應的海報（照片錶面→照片、天氣錶面→天氣、其他→時鐘）；記最後一次的時間
    static let recencyKey = "HomePlayPosterRecency"
    static func kind(for style: FaceStyle) -> Kind { style == .photos ? .photos : style == .weather ? .weather : .clock }
    /// 近期用過的排前面（越近越前），沒用過的照原本順序排在後面；只排輪得到的那幾張
    static func ordered(_ kinds: [Kind], lastUsed: [Kind: Double]) -> [Kind] {
        kinds.enumerated().sorted { a, b in
            switch (lastUsed[a.element], lastUsed[b.element]) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map { $0.element }
    }
    static func loadRecency(_ d: UserDefaults = .standard) -> [Kind: Double] {
        var out: [Kind: Double] = [:]
        for (k, v) in (d.dictionary(forKey: recencyKey) as? [String: Double]) ?? [:] { if let kind = Kind(rawValue: k) { out[kind] = v } }
        return out
    }
    static func recordUse(_ k: Kind, at t: Double, _ d: UserDefaults = .standard) {
        var m = (d.dictionary(forKey: recencyKey) as? [String: Double]) ?? [:]
        m[k.rawValue] = t
        d.set(m, forKey: recencyKey)
    }
    /// 這一次海報期的排序：進場那一刻記一次「用過」、排好就凍住（輪到一半不重排）；快照不寫偏好
    nonisolated(unsafe) static var session: (since: Double, lastUsed: [Kind: Double])?
    static func sessionRecency(since: Double, style: FaceStyle, wall: Double) -> [Kind: Double] {
        if let s = session, s.since == since { return s.lastUsed }
        var m = loadRecency()
        if !demo && !SnapshotPrivacy.active { m[kind(for: style)] = wall; recordUse(kind(for: style), at: wall) }
        session = (since, m)
        return m
    }

    /// 進入 Ambient 第 elapsed 秒：現在這張、交叉淡化中的上一張（nil＝沒在換）、新張的不透明度
    static func slot(_ kinds: [Kind], elapsed: Double, reduceMotion: Bool, forced: Kind? = nil) -> (cur: Kind, prev: Kind?, alpha: CGFloat) {
        if let forced { return (forced, nil, 1) }
        guard kinds.count > 1 else { return (kinds.first ?? .clock, nil, 1) }
        let e = max(0, elapsed), i = Int(e / dwell), into = e - Double(i) * dwell
        let cur = kinds[i % kinds.count]
        guard i > 0, into < fade, !reduceMotion else { return (cur, nil, 1) }
        return (cur, kinds[(i - 1) % kinds.count], CGFloat(into / fade))
    }

    /// 下一次要重畫的距離（秒）：淡化中＝每幀（0），否則到下一張的換點
    static func untilNextChange(_ kinds: [Kind], elapsed: Double, reduceMotion: Bool) -> Double {
        guard forced == nil, kinds.count > 1 else { return .infinity }
        let e = max(0, elapsed), into = e.truncatingRemainder(dividingBy: dwell)
        if e >= dwell, into < fade, !reduceMotion { return 0 }
        return dwell - into
    }

    /// 海報大時間的字體與實際數字系統：SF＋arabic＝原本的 SF Pro（像素不變）；其他走系統錶面數字字體（一般字寬），
    /// 字體沒有那一套數字就退回 arabic
    static func timeFont(_ cfg: PosterConfiguration, size: CGFloat) -> (NSFont, PosterConfiguration.Numerals) {
        let n = cfg.resolvedNumerals
        let f = cfg.typeface == .sf && n == .arabic ? FaceType.sf(size, .medium) : cfg.typeface.previewFont(size, weight: 0.5)
        return (f, FaceType.numerals(n, in: f))
    }

    static func parseSnapshotArgs(_ a: [String]) {
        if let i = a.firstIndex(of: "--ambient-poster"), i + 1 < a.count { forced = Kind(rawValue: a[i + 1]) }
        demo = a.contains("--demo-ambient")
        // 快照的天氣海報：只在給了 HOMEPLAY_WEATHER_JSON 時啟動資料源（直接吃那份 JSON，不連網、不問定位）
        if forced == .weather, ProcessInfo.processInfo.environment[WeatherSource.envKey] != nil { WeatherSource.shared.activate {} }
    }
}

// MARK: - 畫

extension Face {
    /// 現在輪得到的海報（天氣有資料、照片架有照片），近期用過的排前面（這一次海報期內順序固定）
    var ambientPosterKinds: [AmbientPoster.Kind] {
        let kinds = AmbientPoster.available(weather: WeatherSource.shared.data != nil, photos: photos.current != nil)
        guard let since = Shell.ambientSince else { return kinds }
        return AmbientPoster.ordered(kinds, lastUsed: AmbientPoster.sessionRecency(since: since, style: style, wall: ClockKit.wall))
    }

    func drawAmbientPoster(_ g: CGContext, now: Double) {
        let look = HPLook.current
        if photos.current == nil { _ = photos.tick(now) }   // 照片架還沒掃過（錶面不是照片錶面）：掃一次（tick 自己 30 秒才重掃）
        // 1–3) 海報本體：輪播的這一張；換張時上一張墊底、新的交叉淡化蓋上（0.4 s；減少動態效果直接切）
        let s = AmbientPoster.slot(ambientPosterKinds, elapsed: now - (Shell.ambientSince ?? now),
                                   reduceMotion: Motion.reduceMotion, forced: AmbientPoster.forced)
        if let prev = s.prev {
            drawAmbientPosterLayer(g, prev, look, now: now)
            g.saveGState(); g.setAlpha(s.alpha); g.beginTransparencyLayer(auxiliaryInfo: nil)
            drawAmbientPosterLayer(g, s.cur, look, now: now)
            g.endTransparencyLayer(); g.restoreGState()
        } else {
            drawAmbientPosterLayer(g, s.cur, look, now: now)
        }
        // 4) StandBy 式活動堆疊：每張海報都照常疊上；卡片底＝numerals 半透明，字用 secondary／accent
        let acts = AmbientPoster.showsCards(PosterConfiguration.active.style, kind: s.cur) ? AmbientPoster.cards(shellActivities(now)) : []
        for (i, a) in acts.enumerated() {
            let r = AmbientPoster.cardRect(i)
            let card = CGPath(roundedRect: r, cornerWidth: 40, cornerHeight: 40, transform: nil)
            g.addPath(card)
            g.setFillColor(look.numerals_color.withAlphaComponent(0.10).cgColor)
            g.fillPath()
            g.addPath(card)
            g.setStrokeColor(look.secondary_color.withAlphaComponent(0.35).cgColor)
            g.setLineWidth(2); g.strokePath()
            let sf = AppUI.font(34, .semibold), df = AppUI.font(30)
            let sym = a.symbol ?? (a.kind == .music ? "music.note" : "circle.fill")
            drawSymbol(g, sym, in: CGRect(x: r.minX + 30, y: r.midY - 26, width: 52, height: 52), color: a.accent, weight: .semibold)
            drawLeft(g, Face.clipped(a.title, sf, 430), font: sf, x: r.minX + 108, y: r.midY + 12, color: look.secondary_color)
            AppUI.right(self, g, Face.clipped(a.detail, df, 300), df, rightX: r.maxX - 34, y: r.midY + 10, look.numerals_color)
            HPAX.note(g, r, .button, "\(a.title) \(a.detail)", shape: .rounded(40))
            if let p = a.progress {   // 計時器進度：accent 色細條（貼卡底）
                let bar = CGRect(x: r.minX + 24, y: r.maxY - 14, width: (r.width - 48) * CGFloat(max(0, min(1, p))), height: 6)
                g.addPath(CGPath(roundedRect: CGRect(x: r.minX + 24, y: r.maxY - 14, width: r.width - 48, height: 6), cornerWidth: 3, cornerHeight: 3, transform: nil))
                g.setFillColor(look.secondary_color.withAlphaComponent(0.25).cgColor); g.fillPath()
                if bar.width > 6 {
                    g.addPath(CGPath(roundedRect: bar, cornerWidth: 3, cornerHeight: 3, transform: nil))
                    g.setFillColor(a.accent.cgColor); g.fillPath()
                }
            }
        }
    }
}

extension Face {
    /// 一張海報的底與主文字（不含活動卡）
    func drawAmbientPosterLayer(_ g: CGContext, _ kind: AmbientPoster.Kind, _ look: HVTruth.Look, now: Double = CACurrentMediaTime()) {
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let date = Date(timeIntervalSinceReferenceDate: ClockKit.wall)
        let (h, m) = Self.hourMinute(date)
        // 內容剛好沒了（天氣過期、照片被搬走）：這一張退回時鐘，不畫空海報
        let weather = WeatherSource.shared.data, photo = photos.current
        let kind = kind == .weather && weather == nil || kind == .photos && photo == nil ? .clock : kind
        switch kind {
        case .weather:
            guard let d = weather else { return }
            // 天色底：天氣 App 動態天空同一份場景的三段漸層（Shell/Apps/WeatherSkyScenes.swift）
            let sky = WeatherApp.shared.scene(for: d, date: date).look
            func ns(_ c: SkyRGB) -> CGColor { NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1).cgColor }
            if let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [ns(sky.top), ns(sky.middle), ns(sky.bottom)] as CFArray,
                                     locations: [0, CGFloat(sky.middleAt), 1]) {
                g.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: 1024), options: [])
            }
            func temp(_ v: Double) -> Int { Int((Self.weatherImperial ? v * 9 / 5 + 32 : v).rounded()) }
            let big = "\(temp(d.temp))°"
            drawCentered(g, big, font: FaceType.sf(AmbientPoster.timeSize, .medium), y: AmbientPoster.timeBaseline, color: HPTokens.onMedia)
            let line = Self.weatherText(d.code) + "  ·  " + String(format: L("weather.hiLo", "高 %d° 低 %d°"), temp(d.hi), temp(d.lo))
            let lf = FaceType.sf(AmbientPoster.dateSize, .semibold)
            drawCentered(g, Self.clipped(line, lf, 800), font: lf, y: AmbientPoster.dateBaseline, color: HPTokens.onMedia.withAlphaComponent(0.8))
            HPAX.note(g, CGRect(x: 212, y: AmbientPoster.timeBaseline - 260, width: 600, height: 300), .text, "\(big) \(line)", shape: .rounded(40))
        case .photos:
            guard let img = photo else { return }
            MessagesScreen.drawAspectFill(g, img, in: full, fit: false)
            g.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor); g.fill(full)   // 壓暗：海報上的字與卡片要讀得到
            let cf = FaceType.sf(AmbientPoster.dateSize, .semibold)
            drawCentered(g, "\(h):\(m)", font: FaceType.sf(AmbientPoster.timeSize, .medium), y: AmbientPoster.timeBaseline, color: HPTokens.onMedia)
            if let cap = photos.caption { drawCentered(g, Self.clipped(cap, cf, 800), font: cf, y: AmbientPoster.dateBaseline, color: look.secondary_color) }
            HPAX.note(g, CGRect(x: 212, y: AmbientPoster.timeBaseline - 260, width: 600, height: 300), .text, "\(h):\(m) \(photos.caption ?? "")", shape: .rounded(40))
        case .clock:
            // 錶面體系：版式照海報配置（month＝月視圖，Shell/AmbientPosterStyles.swift）
            let cfg = PosterConfiguration.active
            if cfg.style == .month { drawMonthPoster(g, look, cfg, date); break }
            if cfg.style == .threeColumnSixItems { drawFamilyPoster(g, look, cfg, date, now: now); break }
            // 底：Look 的 background token
            g.setFillColor(look.background_color.cgColor); g.fill(full)
            // 大數字：numerals token（Look 聯動後 ClockLook 色票就是這個色；畫在同一個 token 上，兩邊永遠一致）
            // 錶面體系：字體照海報配置的 typeface、數字照 numerals（預設 SF＋arabic＝原本的樣子）
            let (tf, nums) = AmbientPoster.timeFont(cfg, size: AmbientPoster.timeSize)
            drawCentered(g, FaceType.digits("\(h):\(m)", nums), font: tf, y: AmbientPoster.timeBaseline,
                         color: look.numerals_color)
            // 日期：secondary token
            // 錶面體系：日期行＝海報配置的頁首日期格式（預設「日期」＝原本的月日星期）
            let header = cfg.headerText(date)
            drawCentered(g, header, font: FaceType.sf(AmbientPoster.dateSize, .semibold), y: AmbientPoster.dateBaseline,
                         color: look.secondary_color)
            HPAX.note(g, CGRect(x: 212, y: AmbientPoster.timeBaseline - 260, width: 600, height: 300), .text,
                      "\(h):\(m) \(header)", shape: .rounded(40))
        }
    }
}

// MARK: - 自檢

enum AmbientPosterSelfTest {
    private static let demoAct = LiveActivity(kind: .timer, title: "", detail: "", accent: .black, progress: nil, appID: "timers")

    static func run(_ check: (Bool, String) -> Void) {
        let sc: [Bool] = [AmbientPoster.showsCards(.time, kind: .clock), AmbientPoster.showsCards(.month, kind: .clock), AmbientPoster.showsCards(.month, kind: .weather)]
        check(sc == [true, false, true],
              "海報：月視圖／家庭版式的時鐘海報不疊活動卡，天氣照片照疊")   // l10n-ignore
        check(AmbientPoster.cards([]).isEmpty && AmbientPoster.cards(Array(repeating: demoAct, count: 4)).count == AmbientPoster.maxCards,
              "海報：活動最多三張卡")   // l10n-ignore
        let last = AmbientPoster.cardRect(AmbientPoster.maxCards - 1)
        check(last.maxY <= 1024 - AmbientPoster.cardGap && AmbientPoster.cardRect(0).minY > AmbientPoster.dateBaseline,
              "海報：三張卡都在畫布內、日期下方")   // l10n-ignore
        check(AmbientPoster.timeSize >= 220 && AmbientPoster.cardW == 800 && AmbientPoster.cardX == 112,
              "海報：版面常數照 8-pt 網格（112/800）")   // l10n-ignore
        // 卡片與大數字不重疊
        check(AmbientPoster.cardsTop - AmbientPoster.dateBaseline >= 60, "海報：日期與卡片之間留白 ≥ 60")   // l10n-ignore
        // 輪播（後續 #6）
        typealias P = AmbientPoster
        check(P.available(weather: false, photos: false) == [.clock] && P.available(weather: true, photos: true) == [.clock, .weather, .photos]
              && P.available(weather: false, photos: true) == [.clock, .photos], "海報輪播：時鐘永遠在、天氣與照片有內容才輪入")   // l10n-ignore
        let all = P.available(weather: true, photos: true)
        check(P.slot(all, elapsed: 0, reduceMotion: false).cur == .clock && P.slot(all, elapsed: 31, reduceMotion: false).cur == .weather
              && P.slot(all, elapsed: 61, reduceMotion: false).cur == .photos && P.slot(all, elapsed: 91, reduceMotion: false).cur == .clock,
              "海報輪播：每張 30 秒、照順序循環")   // l10n-ignore
        let mid = P.slot(all, elapsed: 30.2, reduceMotion: false)
        check(mid.cur == .weather && mid.prev == .clock && abs(mid.alpha - 0.5) < 1e-6 && P.slot(all, elapsed: 30.2, reduceMotion: true).prev == nil
              && P.slot(all, elapsed: 0.1, reduceMotion: false).prev == nil, "海報輪播：換張 0.4 s 交叉淡化；減少動態效果直接切；第一張不淡入")   // l10n-ignore
        check(P.slot([.clock], elapsed: 45, reduceMotion: false).cur == .clock && P.slot(all, elapsed: 45, reduceMotion: false, forced: .photos).cur == .photos,
              "海報輪播：只有時鐘不輪；快照旗標強制指定")   // l10n-ignore
        // 近期使用優先（錶面體系）
        let o1: [P.Kind] = P.ordered(all, lastUsed: [:])
        let o2: [P.Kind] = P.ordered(all, lastUsed: [P.Kind.photos: 100.0])
        let o3: [P.Kind] = P.ordered(all, lastUsed: [P.Kind.clock: 50.0, P.Kind.weather: 90.0])
        let o4: [P.Kind] = P.ordered([P.Kind.clock, P.Kind.weather], lastUsed: [P.Kind.photos: 999.0])
        let w2: [P.Kind] = [.photos, .clock, .weather], w3: [P.Kind] = [.weather, .clock, .photos], w4: [P.Kind] = [.clock, .weather]
        check(o1 == all && o2 == w2 && o3 == w3 && o4 == w4, "海報輪播：近期用過的排前面，沒用過的照原順序；輪不到的不出現")   // l10n-ignore
        let kf: [P.Kind] = [P.kind(for: .photos), P.kind(for: .weather), P.kind(for: .island), P.kind(for: .calendar)]
        check(kf == [.photos, .weather, .clock, .clock],
              "海報輪播：用過＝進海報前的錶面對應的那張")   // l10n-ignore
        let suite = "homeplay.selftest.posterRecency"
        let ud = UserDefaults(suiteName: suite)!
        ud.removePersistentDomain(forName: suite)
        P.recordUse(.weather, at: 10, ud); P.recordUse(.photos, at: 20, ud); P.recordUse(.weather, at: 30, ud)
        let rec: [P.Kind: Double] = P.loadRecency(ud), wantRec: [P.Kind: Double] = [.weather: 30, .photos: 20]
        let o5: [P.Kind] = P.ordered(all, lastUsed: rec), w5: [P.Kind] = [.weather, .photos, .clock]
        check(rec == wantRec && o5 == w5,
              "海報輪播：最後使用時間存得回來")   // l10n-ignore
        ud.removePersistentDomain(forName: suite)
        check(P.untilNextChange([.clock], elapsed: 10, reduceMotion: false) == .infinity && abs(P.untilNextChange(all, elapsed: 10, reduceMotion: false) - 20) < 1e-9
              && P.untilNextChange(all, elapsed: 30.1, reduceMotion: false) == 0 && P.untilNextChange(all, elapsed: 30.1, reduceMotion: true) > 29,
              "海報輪播：重畫排在換點、淡化中每幀")   // l10n-ignore
    }

}
