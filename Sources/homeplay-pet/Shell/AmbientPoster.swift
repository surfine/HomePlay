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

    static func parseSnapshotArgs(_ a: [String]) {
        if let i = a.firstIndex(of: "--ambient-poster"), i + 1 < a.count { forced = Kind(rawValue: a[i + 1]) }
        demo = a.contains("--demo-ambient")
        // 快照的天氣海報：只在給了 HOMEPLAY_WEATHER_JSON 時啟動資料源（直接吃那份 JSON，不連網、不問定位）
        if forced == .weather, ProcessInfo.processInfo.environment[WeatherSource.envKey] != nil { WeatherSource.shared.activate {} }
    }
}

// MARK: - 畫

extension Face {
    /// 現在輪得到的海報（天氣有資料、照片架有照片）
    var ambientPosterKinds: [AmbientPoster.Kind] {
        AmbientPoster.available(weather: WeatherSource.shared.data != nil, photos: photos.current != nil)
    }

    func drawAmbientPoster(_ g: CGContext, now: Double) {
        let look = HPLook.current
        if photos.current == nil { _ = photos.tick(now) }   // 照片架還沒掃過（錶面不是照片錶面）：掃一次（tick 自己 30 秒才重掃）
        // 1–3) 海報本體：輪播的這一張；換張時上一張墊底、新的交叉淡化蓋上（0.4 s；減少動態效果直接切）
        let s = AmbientPoster.slot(ambientPosterKinds, elapsed: now - (Shell.ambientSince ?? now),
                                   reduceMotion: Motion.reduceMotion, forced: AmbientPoster.forced)
        if let prev = s.prev {
            drawAmbientPosterLayer(g, prev, look)
            g.saveGState(); g.setAlpha(s.alpha); g.beginTransparencyLayer(auxiliaryInfo: nil)
            drawAmbientPosterLayer(g, s.cur, look)
            g.endTransparencyLayer(); g.restoreGState()
        } else {
            drawAmbientPosterLayer(g, s.cur, look)
        }
        // 4) StandBy 式活動堆疊：每張海報都照常疊上；卡片底＝numerals 半透明，字用 secondary／accent
        let acts = AmbientPoster.cards(shellActivities(now))
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
    func drawAmbientPosterLayer(_ g: CGContext, _ kind: AmbientPoster.Kind, _ look: HVTruth.Look) {
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
            // 底：Look 的 background token
            g.setFillColor(look.background_color.cgColor); g.fill(full)
            // 大數字：numerals token（Look 聯動後 ClockLook 色票就是這個色；畫在同一個 token 上，兩邊永遠一致）
            drawCentered(g, "\(h):\(m)", font: FaceType.sf(AmbientPoster.timeSize, .medium), y: AmbientPoster.timeBaseline,
                         color: look.numerals_color)
            // 日期：secondary token
            drawCentered(g, Self.dateLine(date), font: FaceType.sf(AmbientPoster.dateSize, .semibold), y: AmbientPoster.dateBaseline,
                         color: look.secondary_color)
            HPAX.note(g, CGRect(x: 212, y: AmbientPoster.timeBaseline - 260, width: 600, height: 300), .text,
                      "\(h):\(m) \(Self.dateLine(date))", shape: .rounded(40))
        }
    }
}

// MARK: - 自檢

enum AmbientPosterSelfTest {
    private static let demoAct = LiveActivity(kind: .timer, title: "", detail: "", accent: .black, progress: nil, appID: "timers")

    static func run(_ check: (Bool, String) -> Void) {
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
        check(P.untilNextChange([.clock], elapsed: 10, reduceMotion: false) == .infinity && abs(P.untilNextChange(all, elapsed: 10, reduceMotion: false) - 20) < 1e-9
              && P.untilNextChange(all, elapsed: 30.1, reduceMotion: false) == 0 && P.untilNextChange(all, elapsed: 30.1, reduceMotion: true) > 29,
              "海報輪播：重畫排在換點、淡化中每幀")   // l10n-ignore
    }

}
