// HPDS 的自檢：token 之間的關係、舊名轉發到新名之後數值不變、字級表與中英混排的小工具。
import AppKit

enum HPSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        // 圓角：同心＝螢幕半徑 − 內縮；螢幕圓角對角線內縮約 40（官方圖量到 40）
        check(abs(HPTokens.Radius.concentric(inset: 14) - (Screen.cornerRadius - 14)) < 1e-9, "HPDS：同心圓角＝螢幕半徑 − 內縮")
        check(abs(HPTokens.Radius.screenDiagonalInset - 40) < 2, "HPDS：螢幕圓角對角線內縮約 40")
        check(HPTokens.Radius.concentric(parent: 50, padding: 44) == 12, "HPDS：同心圓角不小於 minimum")
        check(HPTokens.Radius.capsule(CGRect(x: 0, y: 0, width: 300, height: 88)) == 44, "HPDS：膠囊半徑＝高 ÷ 2")
        // 頂列：返回圓鈕 90、圓心 (105, 105)（第三輪照官方 recipe-overview）；整顆在螢幕圓角裡面
        let b = HPTokens.backButton
        let inside = Screen.path().contains(CGPoint(x: b.minX + b.width * 0.15, y: b.minY + b.height * 0.15))
        check(b.width == HPTokens.Size.backButton && b.midX == HPTokens.cornerControlCenter && b.midY == HPTokens.cornerControlCenter && inside, "HPDS：返回圓鈕在官方的位置、沒被螢幕圓角切到")
        check(HPTokens.Size.action >= HPTokens.Size.tap && HPTokens.Size.backButton >= HPTokens.Size.tap, "HPDS：可點的元件 ≥ 88")
        // 舊名轉發（Theme／AppMotion）數值不變
        check(Theme.backButton == HPTokens.backButton && AppUI.margin == HPTokens.Space.margin && RealUI.contentTop == HPTokens.contentTop, "HPDS：舊名轉發到 HPTokens")
        let am = AppMotion.appleSmooth == Spring.smooth && AppMotion.interactive == Spring.interactive && AppMotion.critical(settle: 0.17) == Spring.settling(0.17)
        check(am, "HPDS：AppMotion 轉發到 HPMotion")
        check(abs(AppMotion.project(1000) - HPMotion.project(1000)) < 1e-9 && abs(AppMotion.rubberBand(100, 300) - HPMotion.rubberBand(100, 300)) < 1e-9, "HPDS：投射與 rubber band 兩邊一樣")
        // 染色玻璃：色進參數、不是實色（不透明度有上限）
        let p = HPGlass.params(.tinted(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)), darkGlass: false)
        check(p.tint.map { $0.alpha <= 0.82 + 1e-6 } == true && p.black >= 0.25, "HPDS：染色玻璃的色有上限")
        // 字級表：遠看 ≥ 100、內文 56–60、列表 40–44、次要 ≥ 28
        let s = HPType.Size.self
        check(s.display >= 100 && (56...60).contains(s.body) && (40...44).contains(s.list) && s.caption >= 28, "HPDS：字級表在規則範圍內")
        check(HPType.hasCJK("奶油南瓜濃湯") && !HPType.hasCJK("Butternut Squash Soup") && HPType.hasCJK("15 分鐘"), "HPDS：認得中日韓字")
        check(HPType.lineHeight(56, for: "Here are") == 67 && HPType.lineHeight(56, for: "這週") == 73, "HPDS：行高英文 1.2、中文 1.3")
        // P12：中間刪節號——塞得下就不動；太長保留頭尾（電話號碼、單集名稱，HIG-LIST-23）
        let mf = HPType.sf(40, .regular)
        let num = "+1 415 555 0134"
        let midNum = Face.clippedMiddle(num, mf, 220)
        check(midNum != num && midNum.contains("…") && midNum.first == num.first && midNum.last == num.last && Typo.width(midNum, mf) <= 220, "P12：中間刪節號保留頭尾")
        check(Face.clippedMiddle("短標題", mf, 800) == "短標題" && Face.clippedMiddle(num, mf, 2000) == num, "P12：塞得下就不刪節")
        check({ let m = Face.clippedMiddle("這是一個非常長的中文單集名稱測試標題", mf, 160); return m.contains("…") && m.hasPrefix("這") && m.hasSuffix("題") }(), "P12：中文也保留頭尾")
        // 第三輪：重點詞 **粗體** 拆段、折行不拆英文詞；膠囊列拆「標題 · 時間」；家庭模組 3×3 格剛好鋪滿
        let rw = HPType.richWrap("invented in **1842** by **Sir John Herschel**.", size: 59, width: 2000, maxLines: 9)
        check(rw.count == 1 && rw[0].map(\.bold) == [false, true, false, true, false] && rw[0][1].text == "1842", "HPDS：重點詞拆成粗體段")
        let narrow = HPType.richWrap("cyanotype process was invented", size: 59, width: 420, maxLines: 9)
        let trimmed = narrow.allSatisfy { l in l.allSatisfy { !$0.text.hasPrefix(" ") && !$0.text.hasSuffix(" ") } }
        let rejoined = narrow.flatMap { $0 }.map(\.text).joined(separator: " ") == "cyanotype process was invented"
        check(narrow.count >= 2 && trimmed && rejoined, "HPDS：折行在詞與詞之間、行首行尾不留空白")
        let row = Face.splitRow("Birthday celebration for Nick, Juan, and Vicki · Apr 17, 3:00–4:00 PM")
        check(row.title == "Birthday celebration for Nick, Juan, and Vicki" && row.trailing == "Apr 17, 3:00–4:00 PM" && Face.splitRow("Maiko").trailing == nil, "HPDS：膠囊列拆標題與時間")
        let hm = HPTokens.HomeModular.self
        check(abs(hm.tile(2, 2).maxX - (1024 - hm.margin)) < 1e-9 && abs(hm.tile(0, 0, w: 2, h: 2).maxX + hm.gap - hm.tile(2, 0).minX) < 1e-9, "HPDS：家庭模組 3×3 格鋪滿、間距一致")
        let ours = HPIcons.kind(forSymbol: "alarm.fill") == .alarms && HPIcons.kind(forSymbol: "timer") == .timers && HPIcons.kind(forSymbol: "globe") == .worldClock
        check(ours && HPIcons.kind(forSymbol: "music.note") == .music && HPIcons.kind(forSymbol: "no.such.symbol") == nil, "HPDS：自畫圖示照 SF Symbol 對上")
        // 第四輪：內建 App 每一個都有自畫圖示（不讀系統 App 圖示）；FaceTime、對講照 App id
        let missing = AppRegistry.visible.filter { HPIcons.kind(forID: $0.id) == nil && HPIcons.kind(forSymbol: $0.icon.symbol) == nil }.map(\.id)
        check(missing.isEmpty, "HPDS：每個內建 App 都有 HPIcons 圖示（缺：\(missing)）")
        // 第四輪：夜間紅色只看房間亮度或手動開關，鏡頭關著（不知道房間光）不自己進夜間
        check(!Shell.nightFrom(room: nil, manual: false) && Shell.nightFrom(room: 0.3, manual: false) && !Shell.nightFrom(room: 0.9, manual: false) && Shell.nightFrom(room: nil, manual: true) && Shell.nightFrom(room: 1.2, manual: true), "夜間：只看房間亮度＋手動「夜間」，不看時段")
        check(HPAvatar.presets.count >= 12 && Set(HPAvatar.presets).count == HPAvatar.presets.count, "頭像：至少 12 種不重複的 👀 人物組合")
        let pa = Person(id: "a", name: "A", colorIndex: 0, isOwner: true), pb = Person(id: "b", name: "B", colorIndex: 1, isOwner: false)
        check(HPAvatar.style(for: pa) != HPAvatar.style(for: pb), "頭像：每個家人預設不一樣")
        if let d = try? JSONEncoder().encode([pb]), let back = try? JSONDecoder().decode([Person].self, from: d) { check(back == [pb], "頭像：名冊存讀不變") }
        let old = #"[{"id":"x","name":"X","colorIndex":2,"isOwner":true}]"#.data(using: .utf8)!
        check((try? JSONDecoder().decode([Person].self, from: old))?.first?.avatar == nil, "頭像：舊名冊（沒有頭像欄位）照樣讀得到")
        check(HPIcons.kind(forID: "facetime") == .facetime && HPIcons.kind(forID: "intercom") == .intercom, "HPDS：FaceTime、對講的圖示照 App id")
        // 第五輪 B：頭像來源——自動＝帳號頭像 → 聯絡人「我」→ 縮寫；👀 只有選了才用；不是主人沒選就縮寫
        typealias R = AvatarResolver
        let auto = R.resolve(isOwner: true, source: .automatic, hasAccount: true, hasMeCard: true) == .account
            && R.resolve(isOwner: true, source: .automatic, hasAccount: false, hasMeCard: true) == .meCard
            && R.resolve(isOwner: true, source: .automatic, hasAccount: false, hasMeCard: false) == .monogram
        check(auto, "頭像：自動＝帳號頭像 → 聯絡人「我」→ 縮寫")
        let others = R.resolve(isOwner: true, source: .contact, hasAccount: true, hasMeCard: true) == .meCard
            && R.resolve(isOwner: true, source: .contact, hasAccount: true, hasMeCard: false) == .account
            && R.resolve(isOwner: false, source: .automatic, hasAccount: true, hasMeCard: true) == .monogram
            && R.resolve(isOwner: false, source: .eyes, hasAccount: true, hasMeCard: true) == .eyes
        check(others, "頭像：聯絡人照片讀不到照自動往下；家人沒選就縮寫、選了 👀 才是 👀")
        let defaults = Person(id: "a", name: "A", colorIndex: 0, isOwner: true).effectiveAvatarSource == .automatic
            && Person(id: "a", name: "A", colorIndex: 0, isOwner: true, useContactPhoto: true).effectiveAvatarSource == .contact
        check(defaults, "頭像：沒選過＝自動（👀 不再是預設）；第四輪的聯絡人照片照舊")
        check(R.initials("Erica Lee") == "EL" && R.initials("erica") == "E" && R.initials("  ") == "?", "頭像：縮寫取名＋姓的頭一個字母")   // l10n-ignore：測試資料
        // 第五輪 C：行事曆圖示跟著 displayDate；午夜換日主畫面重畫
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        if let d1 = cal.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 23, minute: 59, second: 30)) {
            let d2 = d1.addingTimeInterval(60), d0 = d1.addingTimeInterval(-3600)
            let f1 = HPIcons.calendarFace(d1), f2 = HPIcons.calendarFace(d2)
            check(f1.day == "25" && f2.day == "26" && f1.weekday != f2.weekday, "行事曆圖示：日期與星期跟著 displayDate")
            let midnight = Shell.homeDayKey(d0) == Shell.homeDayKey(d1) && Shell.homeDayKey(d1) != Shell.homeDayKey(d2)
                && !Shell.dayChanged(drawn: Shell.homeDayKey(d0), now: d1) && Shell.dayChanged(drawn: Shell.homeDayKey(d1), now: d2)
            check(midnight, "主畫面：午夜換日要重畫（同一天不重畫）")
            func px(_ d: Date) -> [UInt8] {
                let img = makeImage(48, 48) { g in HPIcons.draw(.calendar, g, in: CGRect(x: 0, y: 0, width: 48, height: 48), date: d) }
                guard let data = img.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return [] }
                return Array(UnsafeBufferPointer(start: p, count: CFDataGetLength(data)))
            }
            check(px(d1) != px(d2) && px(d0) == px(d1), "行事曆圖示：換日畫出來的不一樣、同一天一樣")
        }
        // 第五輪 A：主畫面網格照官方（左右對稱、小工具是正方形、置中在兩欄上）
        let first = Shell.iconRect(in: Shell.cell(0, 0)), last = Shell.iconRect(in: Shell.cell(3, 0)), w = Shell.widgetRect(col: 2, row: 0)
        let grid = abs(first.minX - (1024 - last.maxX)) < 0.5 && abs(w.width - w.height) < 0.5 && abs(w.midX - (Shell.iconRect(in: Shell.cell(2, 0)).minX + last.maxX) / 2) < 0.5
        check(grid, "主畫面：網格左右對稱、小工具是置中的正方形")
        // 2.0 P04：並排按鈕共用一個尺寸 token（Music 的「打開音樂」＋「資料庫」），都 ≥ 88
        let pairedSize = HPTokens.Size.pairedButton
        check(NowPlayingPage.open.size == pairedSize && NowPlayingPage.idleLibrary.size == pairedSize && pairedSize.height >= HPTokens.Size.tap, "HPDS：並排的 Music 兩顆按鈕同一個尺寸 token")
        // 2.0 P06：選單列倒數 mm:ss（無條件進位，一小時以上才帶小時）
        check(MenuBarClock.text(272) == "04:32" && MenuBarClock.text(0.2) == "00:01" && MenuBarClock.text(0) == "00:00" && MenuBarClock.text(3723) == "1:02:03", "menu bar countdown: 04:32, 00:01, 1:02:03")
        // 2.0 P07：夜間紅的層級與對比——主要、次要都對黑底 ≥ 4.5（HIG-WID-179/186、HIG-A11Y-43），主要比次要亮
        let np = HPTokens.Night.primary, ns = HPTokens.Night.secondary
        check(HPAccessibility.contrast(np, on: .black) >= 4.5 && HPAccessibility.contrast(ns, on: .black) >= 4.5, "夜間紅：主要、次要對黑底 ≥ 4.5")
        check(HPAccessibility.luminance(np) > HPAccessibility.luminance(ns), "夜間紅：主要比次要亮（層級跟 vibrant 一致）")
        // 2.0 P07：Modular 白天照官方量值、夜間黑底
        check(ModularPalette.day.bg == HPTokens.Modular.bg && ModularPalette.night.bg == .black && ModularPalette.night.ink == np && ModularPalette.night.soft == ns, "Modular：白天官方色票、夜間黑底亮紅")
        // 2.0 P07：True Tone 增益——暖升紅降藍、冷相反、0 不動、對稱有界
        let g1 = TrueTone.gain(1), g0 = TrueTone.gain(0), gm = TrueTone.gain(-0.5), gp = TrueTone.gain(0.5)
        let ttOK = g1.r > 1 && g1.b < 1 && g0 == (1, 1) && abs(gm.r - gp.b) < 1e-9 && abs(gm.b - gp.r) < 1e-9 && TrueTone.gain(2) == g1 && TrueTone.gain(-2) == TrueTone.gain(-1)
        check(ttOK, "True Tone：暖紅冷藍、0 不動、對稱有界")
    }
}
