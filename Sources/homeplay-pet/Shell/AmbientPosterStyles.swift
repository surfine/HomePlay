// 錶面體系：Ambient 時鐘海報的版式變體（海報配置的 style；Shell/PosterConfiguration.swift）。
// - month（官方行事曆海報的版式名 🟢，docs/hv-reference/poster_descriptors.json）：頁首日期＋月份＋一整個月的格子；
//   格線用 secondary、今天那格用 numerals 填一塊、日期數字用配置的 typeface 與 numerals（🟡 版面是 HomePlay 自己排的，固件只給版式名）。
// - threeColumnSixItems（官方家庭海報的版式名 🟢）：大時間＋頁首＋三欄兩列 complication 槽。槽的內容照配置的 items[]：
//   activity＝頂端膠囊同一份 Live Activity（照順序一格一則）、widget＝主畫面小工具同一份資料；出廠全是 placeholder＝不畫。
//   官方 items[] 有九格（🟢）、版式名是六格（🟡 推斷九格是編輯器的容量）：這裡畫前六格，多的照存不畫。
//   沒內容的槽（佔位、沒有那麼多活動、小工具沒資料）整格不畫，不留「—」或說明字。
// 版面數字都在 1024 畫布、8 格線上，純函式由 AmbientPosterStylesSelfTest 釘住。
import AppKit

extension AmbientPoster {
    // MARK: 月視圖版面（純邏輯）
    static let monthHeaderBaseline: CGFloat = 152, monthHeaderSize: CGFloat = 56
    static let monthTitleBaseline: CGFloat = 240, monthTitleSize: CGFloat = 40
    static let monthWeekdayBaseline: CGFloat = 312, monthWeekdaySize: CGFloat = 28
    static let monthGridX: CGFloat = 120, monthColW: CGFloat = 112, monthGridTop: CGFloat = 344, monthRowH: CGFloat = 96
    static let monthDaySize: CGFloat = 48

    struct MonthCell: Equatable { var day: Int; var row: Int; var col: Int }
    /// date 所在月份的格子：一號落在照 firstWeekday 排的那一欄；回（格子、列數、今天的索引）
    static func monthCells(_ date: Date, calendar cal: Calendar) -> (cells: [MonthCell], rows: Int, today: Int) {
        let dc = cal.dateComponents([.year, .month, .day], from: date)
        guard let first = cal.date(from: DateComponents(year: dc.year, month: dc.month, day: 1)),
              let days = cal.range(of: .day, in: .month, for: first) else { return ([], 0, -1) }
        let lead = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let cells = days.map { d in MonthCell(day: d, row: (lead + d - 1) / 7, col: (lead + d - 1) % 7) }
        return (cells, (cells.last?.row ?? 0) + 1, (dc.day ?? 1) - 1)
    }
    static func monthCellRect(_ c: MonthCell) -> CGRect {
        CGRect(x: monthGridX + CGFloat(c.col) * monthColW, y: monthGridTop + CGFloat(c.row) * monthRowH, width: monthColW, height: monthRowH)
    }
    /// 星期列（照 firstWeekday 轉；symbols 是週日開頭的七個）
    static func weekdayRow(_ cal: Calendar, symbols: [String]) -> [String] {
        guard symbols.count == 7 else { return symbols }
        return (0..<7).map { symbols[(cal.firstWeekday - 1 + $0) % 7] }
    }

    /// 海報上的字色：材質版 Look（黑數字、白 secondary）用 numerals 的黑，彩色版用 secondary（跟行事曆錶面同一條規則）
    static func posterInk(_ look: HVTruth.Look) -> NSColor { look.numerals == 0x000000 ? look.numerals_color : look.secondary_color }
    /// 填了 numerals 的那一塊上的字：Look 的 background／accent／secondary 裡對比最高的
    static func inkOn(_ fill: NSColor, _ look: HVTruth.Look) -> NSColor {
        [look.background_color, look.accent_color, look.secondary_color]
            .max { HPAccessibility.contrast($0, on: fill) < HPAccessibility.contrast($1, on: fill) } ?? look.accent_color
    }
}

extension AmbientPoster {
    // MARK: 家庭版式（純邏輯）
    static let familyTimeBaseline: CGFloat = 304, familyTimeSize: CGFloat = 232
    static let familyHeaderBaseline: CGFloat = 400, familyHeaderSize: CGFloat = 44
    static let slotW: CGFloat = 256, slotH: CGFloat = 184, slotGap: CGFloat = 16, slotsTop: CGFloat = 472
    static let slotColumns = 3, slotCapacity = 6

    /// 第 i 格（三欄、由左到右再往下）
    static func slotRect(_ i: Int) -> CGRect {
        CGRect(x: cardX + CGFloat(i % slotColumns) * (slotW + slotGap), y: slotsTop + CGFloat(i / slotColumns) * (slotH + slotGap), width: slotW, height: slotH)
    }

    enum SlotSource: Equatable { case activity(Int), widget(SBWidgetKind) }
    /// 槽 → 內容來源：佔位＝nil；activity 照順序吃 Live Activity（吃完＝nil）；小工具沒資料＝nil。只回前 slotCapacity 格
    static func resolveSlots(_ items: [PosterConfiguration.Item], activities: Int, hasWidget: (SBWidgetKind) -> Bool) -> [SlotSource?] {
        var next = 0
        return items.prefix(slotCapacity).map { it in
            switch it.kind {
            case .placeholder: return nil
            case .activity:
                guard next < activities else { return nil }
                next += 1; return .activity(next - 1)
            case .widget(let k): return hasWidget(k) ? .widget(k) : nil
            }
        }
    }
}

/// 一格 complication 要畫的東西
struct PosterTile: Equatable {
    var symbol: String
    var title: String
    var value: String
    var accent: NSColor?
    var progress: Double?
}

extension Face {
    /// 小工具同一份資料 → 一格（沒資料＝nil，那格不畫）
    func posterTile(_ k: SBWidgetKind, now: Double) -> PosterTile? {
        switch k {
        case .weather:
            guard let d = WeatherSource.shared.data else { return nil }
            let t = Int((Self.weatherImperial ? d.temp * 9 / 5 + 32 : d.temp).rounded())
            return PosterTile(symbol: Self.posterWeatherSymbol(d.code), title: Self.weatherText(d.code), value: "\(t)°")
        case .calendar:
            guard let e = SBWidgetData.events(now: Date(timeIntervalSinceReferenceDate: ClockKit.wall))?.first else { return nil }
            return PosterTile(symbol: "calendar", title: e.title, value: e.allDay ? L("calendar.allDay", "全天") : Self.shortTime(e.start), accent: srgb(e.color))
        case .timers:
            guard let t = SBWidgetData.timers().first else { return nil }
            let s = max(0, Int(t.left.rounded(.up)))
            return PosterTile(symbol: "timer", title: t.label.isEmpty ? L("sb.widget.timers", "计时器") : t.label,
                              value: s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60),
                              accent: HPTokens.orange, progress: t.frac)
        case .alarms:
            guard let a = SBWidgetData.alarms().first(where: { $0.enabled }),
                  let d = Calendar.current.date(bySettingHour: a.hour, minute: a.minute, second: 0, of: Date()) else { return nil }
            return PosterTile(symbol: "alarm.fill", title: a.label.isEmpty ? L("sb.widget.alarms", "闹钟") : a.label, value: Self.shortTime(d), accent: HPTokens.orange)
        case .music:
            guard let n = SBWidgetData.nowPlaying(self, now: now) else { return nil }
            return PosterTile(symbol: "music.note", title: n.artist, value: n.title)
        case .batteries:
            guard let b = SBWidgetData.batteries().first, let l = b.level else { return nil }
            return PosterTile(symbol: b.symbol, title: b.name, value: "\(Int((l * 100).rounded()))%", progress: l)
        default: return nil
        }
    }
    /// 沒給符號的活動照種類補一個（膠囊上同種活動的意思）
    static func posterActivitySymbol(_ k: LiveActivity.Kind) -> String {
        switch k {
        case .timer: return "timer"
        case .music: return "music.note"
        case .alarm: return "alarm.fill"
        case .weather: return "cloud.rain.fill"
        case .message: return "message.fill"
        case .call: return "video.fill"
        case .iphone: return "iphone"
        case .assistant: return "waveform"
        }
    }
    /// 天氣代碼 → SF Symbol（跟天氣條件名稱同一套分段）
    static func posterWeatherSymbol(_ code: Int) -> String {
        switch code {
        case 0, 1: return "sun.max.fill"
        case 2: return "cloud.sun.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    /// threeColumnSixItems 版式：大時間（typeface／numerals）＋頁首＋六格 complication；沒內容的格子不畫
    func drawFamilyPoster(_ g: CGContext, _ look: HVTruth.Look, _ cfg: PosterConfiguration, _ date: Date, now: Double) {
        typealias P = AmbientPoster
        g.setFillColor(look.background_color.cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let ink = P.posterInk(look), ic = HPAccessibility.increaseContrast
        let (h, m) = Self.hourMinute(date)
        let (tf, nums) = P.timeFont(cfg, size: P.familyTimeSize)
        let time = FaceType.digits("\(h):\(m)", nums)
        drawCentered(g, time, font: tf, y: P.familyTimeBaseline, color: look.numerals_color)
        let hf = FaceType.sf(P.familyHeaderSize, .semibold, mono: false)
        let header = Self.clipped(cfg.headerText(date), hf, 800)
        drawCentered(g, header, font: hf, y: P.familyHeaderBaseline, color: ink)
        HPAX.note(g, CGRect(x: 112, y: 64, width: 800, height: 360), .text, "\(time) \(header)", shape: .rounded(40))
        let acts = shellActivities(now)
        var tiles: [SBWidgetKind: PosterTile] = [:]
        let slots = P.resolveSlots(cfg.items, activities: acts.count) { k in
            if tiles[k] == nil, let t = posterTile(k, now: now) { tiles[k] = t }
            return tiles[k] != nil
        }
        let sf = FaceType.sf(28, .semibold, mono: false), vf = FaceType.sf(40, .semibold)
        for (i, src) in slots.enumerated() {
            let tile: PosterTile
            switch src {
            case nil: continue   // 佔位／沒內容：整格不畫
            case .activity(let n)?:
                let a = acts[n]
                tile = PosterTile(symbol: a.symbol ?? Self.posterActivitySymbol(a.kind), title: a.title, value: a.detail, accent: a.accent, progress: a.progress)
            case .widget(let k)?:
                guard let t = tiles[k] else { continue }
                tile = t
            }
            let r = P.slotRect(i), card = continuousRoundedRect(r, radius: HPTokens.Radius.concentric(rect: r))
            g.addPath(card); g.setFillColor(look.numerals_color.withAlphaComponent(0.10).cgColor); g.fillPath()
            g.addPath(card); g.setStrokeColor(look.secondary_color.withAlphaComponent(ic ? 0.7 : 0.35).cgColor); g.setLineWidth(2); g.strokePath()
            drawSymbol(g, tile.symbol, in: CGRect(x: r.minX + 24, y: r.minY + 24, width: 48, height: 48), color: tile.accent ?? look.secondary_color)
            drawLeft(g, Self.clipped(tile.title, sf, r.width - 48), font: sf, x: r.minX + 24, y: r.minY + 112, color: ink.withAlphaComponent(ic ? 1 : 0.75))
            drawLeft(g, Self.clipped(FaceType.digits(tile.value, cfg.resolvedNumerals), vf, r.width - 48), font: vf, x: r.minX + 24, y: r.minY + 160, color: ink)
            if let p = tile.progress {
                let track = CGRect(x: r.minX + 24, y: r.maxY - 16, width: r.width - 48, height: 6)
                g.addPath(CGPath(roundedRect: track, cornerWidth: 3, cornerHeight: 3, transform: nil))
                g.setFillColor(look.secondary_color.withAlphaComponent(0.25).cgColor); g.fillPath()
                let w = track.width * CGFloat(max(0, min(1, p)))
                if w > 6 {
                    g.addPath(CGPath(roundedRect: CGRect(x: track.minX, y: track.minY, width: w, height: 6), cornerWidth: 3, cornerHeight: 3, transform: nil))
                    g.setFillColor((tile.accent ?? look.secondary_color).cgColor); g.fillPath()
                }
            }
            HPAX.note(g, r, .text, "\(tile.title) \(tile.value)", shape: .rounded(40))
        }
    }

    /// month 版式：頁首（配置的日期格式）＋月份＋星期列＋日期格子
    func drawMonthPoster(_ g: CGContext, _ look: HVTruth.Look, _ cfg: PosterConfiguration, _ date: Date) {
        typealias P = AmbientPoster
        g.setFillColor(look.background_color.cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let ink = P.posterInk(look), ic = HPAccessibility.increaseContrast
        let hf = FaceType.sf(P.monthHeaderSize, .semibold, mono: false)
        let header = Self.clipped(cfg.headerText(date), hf, 800)
        drawCentered(g, header, font: hf, y: P.monthHeaderBaseline, color: ink)
        let tf = FaceType.sf(P.monthTitleSize, .semibold, mono: false)
        let title = FaceType.digits(Self.formatter("LLLL").string(from: date), cfg.resolvedNumerals)
        drawCentered(g, title, font: tf, y: P.monthTitleBaseline, color: ink.withAlphaComponent(ic ? 1 : 0.75))
        let cal = Calendar.current
        let wf = FaceType.sf(P.monthWeekdaySize, .semibold, mono: false)
        for (i, s) in P.weekdayRow(cal, symbols: Self.formatter("E").veryShortStandaloneWeekdaySymbols).enumerated() {
            let cx = P.monthGridX + (CGFloat(i) + 0.5) * P.monthColW
            drawLeft(g, s, font: wf, x: cx - Typo.width(s, wf) / 2, y: P.monthWeekdayBaseline, color: ink.withAlphaComponent(ic ? 0.9 : 0.6))
        }
        let m = P.monthCells(date, calendar: cal)
        // 格線：每列上緣一條、最後一列下緣一條（secondary）
        g.setStrokeColor(look.secondary_color.withAlphaComponent(ic ? 0.6 : 0.25).cgColor); g.setLineWidth(2)
        for r in 0...m.rows {
            let y = P.monthGridTop + CGFloat(r) * P.monthRowH
            g.move(to: CGPoint(x: P.monthGridX, y: y)); g.addLine(to: CGPoint(x: P.monthGridX + 7 * P.monthColW, y: y))
        }
        g.strokePath()
        let df = cfg.typeface.previewFont(P.monthDaySize, weight: 0.55)
        let nums = FaceType.numerals(cfg.resolvedNumerals, in: df)
        for (i, c) in m.cells.enumerated() {
            let r = P.monthCellRect(c), s = FaceType.digits(String(c.day), nums)
            var color = ink
            if i == m.today {   // 今天：numerals 填一塊，字取對比最高的 token
                g.addPath(continuousRoundedRect(r.insetBy(dx: 8, dy: 8), radius: HPTokens.Radius.concentric(parent: HPTokens.Radius.drawn(HPTokens.Radius.concentric(rect: r), in: r), padding: 8))); g.setFillColor(look.numerals_color.cgColor); g.fillPath()
                color = P.inkOn(look.numerals_color, look)
            }
            drawLeft(g, s, font: df, x: r.midX - Typo.width(s, df) / 2, y: r.midY + df.capHeight / 2, color: color)
        }
        HPAX.note(g, CGRect(x: 112, y: 80, width: 800, height: 180), .text, "\(header) \(title)", shape: .rounded(40))
    }
}

// MARK: - 自檢

enum AmbientPosterStylesSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        typealias P = AmbientPoster
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 1
        let nov7 = cal.date(from: DateComponents(year: 2026, month: 11, day: 7))!   // 2026-11-01 是週日
        let a = P.monthCells(nov7, calendar: cal)
        let a0: P.MonthCell = P.MonthCell(day: 1, row: 0, col: 0), a6: P.MonthCell = P.MonthCell(day: 7, row: 0, col: 6)
        let aOK: Bool = a.cells.count == 30 && a.cells[0] == a0 && a.cells[6] == a6
        check(aOK && a.rows == 5 && a.today == 6,
              "月視圖：2026 年 11 月週日開頭、30 天、五列、今天 7 號")   // l10n-ignore
        cal.firstWeekday = 2
        let b = P.monthCells(nov7, calendar: cal)
        let b0: P.MonthCell = P.MonthCell(day: 1, row: 0, col: 6)
        check(b.cells[0] == b0 && b.rows == 6, "月視圖：週一開頭時一號在最後一欄、要六列")   // l10n-ignore
        let wr: [String] = P.weekdayRow(cal, symbols: ["S", "M", "T", "W", "T", "F", "S"])
        check(wr == ["M", "T", "W", "T", "F", "S", "S"], "月視圖：星期列照 firstWeekday 轉")   // l10n-ignore
        let last: CGRect = P.monthCellRect(P.MonthCell(day: 31, row: 5, col: 6))
        let grid: [CGFloat] = [P.monthGridX, P.monthColW, P.monthGridTop, P.monthRowH, P.monthHeaderBaseline, P.monthTitleBaseline, P.monthWeekdayBaseline]
        let on8: Bool = grid.allSatisfy { (v: CGFloat) -> Bool in v.truncatingRemainder(dividingBy: 8) == 0 }
        let inside: Bool = last.maxY <= 960 && last.maxX <= 912 && P.monthGridX + 7 * P.monthColW == 904 && P.monthGridTop > P.monthWeekdayBaseline
        check(inside && on8,
              "月視圖：六列也在畫布內、版面照 8 格線")   // l10n-ignore
        let bo = HVTruth.look("Blue-Orange")!, slate = HVTruth.look("Slate")!
        let inkOK: Bool = P.posterInk(bo) == bo.secondary_color && P.posterInk(slate) == slate.numerals_color
        let onC: Double = HPAccessibility.contrast(P.inkOn(slate.numerals_color, slate), on: slate.numerals_color)
        check(inkOK && onC >= 4.5,
              "月視圖：彩色版字用 secondary、材質版用黑；今天那塊上的字挑對比最高的 token")   // l10n-ignore

        // 家庭版式
        typealias I = PosterConfiguration.Item
        let factory = PosterConfiguration.preset("default-installer-color-0")!.items
        let fs: [P.SlotSource?] = P.resolveSlots(factory, activities: 3, hasWidget: { _ in true })
        check(factory.count == 9 && fs.count == 6 && fs.allSatisfy { $0 == nil },
              "家庭版式：出廠九格佔位、畫前六格、全部不畫")   // l10n-ignore
        let mix = [I(identifier: "a", kind: .activity), I(identifier: "b", kind: .widget(.weather)), I(identifier: "c", kind: .activity),
                   I(identifier: "d", kind: .activity), I(identifier: "e", kind: .widget(.calendar)), I(identifier: "f", kind: .placeholder), I(identifier: "g", kind: .activity)]
        let ms: [P.SlotSource?] = P.resolveSlots(mix, activities: 2, hasWidget: { (k: SBWidgetKind) -> Bool in k == .weather })
        let want: [P.SlotSource?] = [.activity(0), .widget(.weather), .activity(1), nil, nil, nil]
        check(ms == want,
              "家庭版式：活動照順序一格一則、吃完不畫；小工具沒資料不畫；只到第六格")   // l10n-ignore
        let s5: CGRect = P.slotRect(5), s0: CGRect = P.slotRect(0), s3: CGRect = P.slotRect(3)
        let fam: [CGFloat] = [P.slotW, P.slotH, P.slotGap, P.slotsTop, P.familyTimeBaseline, P.familyHeaderBaseline]
        let fam8: Bool = fam.allSatisfy { (v: CGFloat) -> Bool in v.truncatingRemainder(dividingBy: 8) == 0 }
        let famIn: Bool = s0.minX == P.cardX && s5.maxX == P.cardX + P.cardW && s5.maxY <= 960 && s3.minY > s0.maxY && P.slotsTop > P.familyHeaderBaseline
        check(famIn && fam8,
              "家庭版式：三欄兩列剛好 800 寬、在畫布內、在頁首下方、照 8 格線")   // l10n-ignore
        let ws: [String] = [Face.posterWeatherSymbol(0), Face.posterWeatherSymbol(63), Face.posterWeatherSymbol(3)]
        check(ws == ["sun.max.fill", "cloud.rain.fill", "cloud.fill"],
              "家庭版式：天氣格的符號照條件分段")   // l10n-ignore
    }
}
