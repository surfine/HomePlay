// 2.0 depth 的 --selftest：天氣條件名稱照 WMO 代碼分開、時間照系統的 12／24 小時制、長標題換兩行／中間截斷。全部離線。

import AppKit

enum DepthSelftest {
    static func run(_ check: (Bool, String) -> Void) {
        // 天氣：冰雹、凍雨、大雨不再併進「雷雨」「雨」
        let wx: [(Int, String)] = [(96, "weather.cond.hail"), (99, "weather.cond.hail"), (95, "weather.cond.storm"), (66, "weather.cond.freezingRain"),
                                   (67, "weather.cond.freezingRain"), (56, "weather.cond.freezingDrizzle"), (65, "weather.cond.heavyRain"),
                                   (63, "weather.cond.rain"), (75, "weather.cond.heavySnow"), (73, "weather.cond.snow"), (81, "weather.cond.showers")]
        let bad = wx.filter { Face.weatherText($0.0) != L10n.text($0.1, "?") }.map { $0.0 }
        check(bad.isEmpty, "天氣：WMO 代碼對到 iOS 的條件名稱（不對的：\(bad)）")   // l10n-ignore：selftest 訊息

        // 時間：狀態列不帶上午／下午；鬧鐘、逐時預報照系統時制
        let d = Calendar.current.date(bySettingHour: 13, minute: 5, second: 0, of: Date()) ?? Date()
        let tp = Face.timeParts(hour: 13, minute: 5)
        let ok12 = Face.uses12Hour ? (tp.time == "1:05" && tp.period != nil && Face.statusClock(d) == "1:05")
                                   : (tp.time == "13:05" && tp.period == nil && Face.statusClock(d) == "13:05" && Face.hourLabel(15) == "15")
        check(ok12 && Face.shortTime(d).contains("05"), "時間：12／24 小時制照系統（\(Face.uses12Hour ? 12 : 24)：\(tp.time) \(Face.shortTime(d))）")   // l10n-ignore：selftest 訊息

        // 時間（clock24 包）：錶面大時間不再寫死 24 小時；單位數小時兩種時制都不補零；時與分一組置中
        let d9 = Calendar.current.date(bySettingHour: 9, minute: 5, second: 0, of: Date()) ?? Date()
        let d0 = Calendar.current.date(bySettingHour: 0, minute: 0, second: 0, of: Date()) ?? d9
        let hm = Face.hourMinute(d9), hm0 = Face.hourMinute(d0)
        let clockOK = Face.clock(d) == (Face.uses12Hour ? "1:05" : "13:05") && Face.clock(d9) == "9:05"
            && hm.h == "9" && hm.m == "05" && hm0.h == (Face.uses12Hour ? "12" : "0")
        check(clockOK, "時間：錶面大時間照時制（\(Face.clock(d))、\(Face.clock(d9))）")   // l10n-ignore：selftest 訊息
        let f2 = FaceType.sf(300, .bold)
        let one = GlyphShape("2", font: f2).moved(100, 0), two = GlyphShape("49", font: f2).moved(600, 0)   // 12 小時制的 2:49：時窄分寬
        let (c1, c2) = GlyphShape.centeredPair(one, two)
        let mid = c1.ink.union(c2.ink).midX, before = one.ink.union(two.ink).midX
        check(abs(mid - 512) < 0.5 && abs(before - mid) > 10, "錶面：時與分一組置中（\(String(format: "%.0f", before)) → \(String(format: "%.0f", mid))）")   // l10n-ignore：selftest 訊息

        // 長標題：放得下一行原字級；放不下兩行，每行都在可用寬度內；一個長詞就中間截斷、頭尾都留
        let short = HPComponents.titleLines("Home")
        let long = HPComponents.titleLines("[Family] Weekend plans for the cabin trip")   // l10n-ignore：測試樣本
        let word = HPComponents.titleLines("Supercalifragilisticexpialidocious")   // l10n-ignore：測試樣本
        check(short.lines == ["Home"] && short.font.pointSize == HPTokens.titleFont.pointSize
              && long.lines.count == 2 && Typo.width(long.lines[0], long.font) <= long.width + 0.5 && Typo.width(long.lines[1], long.font) <= HPComponents.titleMaxWidth + 0.5
              && long.lines[1].hasSuffix("trip")
              && word.lines.count == 1 && word.lines[0].hasPrefix("Sup") && word.lines[0].hasSuffix("ous") && Typo.width(word.lines[0], word.font) <= word.width + 0.5,
              "長標題：縮到 44、兩行、中間截斷（\(long.lines) \(word.lines)）")   // l10n-ignore：selftest 訊息

        // 計時器存檔接回來：還在跑的與暫停的留著、早就到點的丟掉，新的 id 不跟舊的撞
        let saved = [ShellTimer(id: 3, label: "a", total: 600, end: 1_000), ShellTimer(id: 7, label: "b", total: 600, end: 500, pausedLeft: 120),
                     ShellTimer(id: 9, label: "c", total: 60, end: 100)]
        var book = TimerBook(restoring: saved, now: 900)
        let nid = book.add(seconds: 60, label: "d", now: 900)
        check(book.timers.map(\.id) == [3, 7, 8] && nid == 8 && book.timer(7)?.paused == true, "計時器：重開接回來（\(book.timers.map(\.id))）")   // l10n-ignore：selftest 訊息

        // 訊息送出失敗的「重試」：只有按過「好」的那一句；重試是重新念一次，不是直接送
        var flow = MessagesReplyFlow()
        flow.propose("晚點到"); _ = flow.answer(true); flow.finish(.failed("-1"))   // l10n-ignore：測試樣本
        let again = flow.lastAnswered
        flow.dismiss(); flow.propose(again ?? "")
        check(again == "晚點到", "訊息：失敗後重試拿回同一句")   // l10n-ignore：selftest 訊息
        check(flow.state == .confirming(again ?? "") && flow.answer(false) == nil, "訊息：重試要再確認一次才送")   // l10n-ignore：selftest 訊息
    }
}
