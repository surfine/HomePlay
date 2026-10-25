// 2.0 第六輪的 --selftest：主畫面照官方（四格＋照片小工具）、ClioTalk「讓模型知道我的名字與城市」、1988 選單能不能用、
// Bit1 文字位置（中文後面接英文不再位移）。全部離線。

import AppKit

enum Round6Selftest {
    static func run(_ check: (Bool, String) -> Void) {
        // 主畫面：左上四格照官方，右上 2×2 是照片小工具
        let items = Shell.homeItems()
        let apps = items.compactMap { if case .app(let id) = $0.1 { return id }; return nil }
        check(Array(apps.prefix(4)) == ["facetime", "home", "music", "messages"] && items.first?.1 == .photos
              && items.first?.0 == Shell.widgetRect(col: 2, row: 0) && apps.allSatisfy { AppRegistry.app($0) != nil },
              "主畫面：FaceTime／家庭／音樂／訊息在左上、照片小工具在右上（\(apps)）")   // l10n-ignore：selftest 訊息

        // ClioTalk：關掉只拿掉城市與名字；本機模型照帶
        var c = ClioContext(now: Date(timeIntervalSince1970: 1_793_000_000), mode: .display, language: "en")
        c.city = "Taipei"; c.person = .owner("Aaron Lau")   // l10n-ignore：測試樣本
        let off = c.sharing(nameAndCity: false).block, on = c.sharing(nameAndCity: true).block
        check(!off.contains("approximate_place") && !off.contains("Aaron") && off.contains("person: the owner\n")
              && on.contains("approximate_place: Taipei") && on.contains("person: the owner, Aaron"),
              "ClioTalk：名字與城市關掉＝不送城市與名字、仍說是主人")   // l10n-ignore：selftest 訊息
        var cfg = ClioConfig(); cfg.shareNameAndCity = false
        cfg.provider = .anthropic; let cloud = cfg.sendsNameAndCity
        cfg.provider = .deepseek; let ds = cfg.sendsNameAndCity
        cfg.provider = .lmStudio; let lm = cfg.sendsNameAndCity
        cfg.provider = .onDevice; let od = cfg.sendsNameAndCity
        check(!cloud && !ds && lm && od && ClioConfig().sendsNameAndCity, "ClioTalk：名字與城市預設開；關掉只限雲端，本機模型不受限")

        // 1988 選單：哪些項目用得了
        typealias M = Clio1988Menu
        var s = ClioSnapshot(); s.phase = .idle; s.question = "q"; s.answer = "a"
        check(M.enabled(.keep, s, provider: .anthropic) && M.enabled(.deeper, s, provider: .anthropic) && M.enabled(.copyAnswer, s, provider: .anthropic)
              && M.enabled(.askAgain, s, provider: .anthropic) && M.enabled(.close, s, provider: .anthropic), "1988 選單：有回答時全都能用")   // l10n-ignore：selftest 訊息
        check(!M.enabled(.deeper, s, provider: .lmStudio), "1988 選單：本機模型沒有「想深一點」")
        var kept = s; kept.kept = true
        check(!M.enabled(.keep, kept, provider: .anthropic), "1988 選單：留下過就不能再留下")
        var busy = s; busy.phase = .thinking; busy.answer = ""
        check(!M.enabled(.keep, busy, provider: .anthropic) && !M.enabled(.askAgain, busy, provider: .anthropic) && !M.enabled(.copyAnswer, busy, provider: .anthropic),
              "1988 選單：在想時不能留下、重新問、拷貝")   // l10n-ignore：selftest 訊息
        check(M.items(0) == [.close] && M.items(1) == [.copyAnswer] && M.items(2) == [.keep, .deeper, .askAgain], "1988 選單：File／Edit／Talk 的項目")
        // 點擊：點標題拉開、點項目做事並收起、點外面收起
        let (savedLive, savedOpen, savedT, savedI) = (M.live, M.open, M.titleRects, M.itemRects)
        M.live = true; M.open = nil
        M.titleRects = [CGRect(x: 0, y: 0, width: 100, height: 76), CGRect(x: 100, y: 0, width: 100, height: 76), CGRect(x: 200, y: 0, width: 100, height: 76)]
        M.itemRects = [(.keep, CGRect(x: 200, y: 76, width: 200, height: 64), true), (.deeper, CGRect(x: 200, y: 140, width: 200, height: 64), false)]
        let a1 = M.press(x: 250, y: 30); let r1 = M.release(x: 250, y: 30); let opened = M.open == 2
        let a2 = M.press(x: 250, y: 100); let r2 = M.release(x: 250, y: 100); let closedAfterItem = M.open == nil
        M.open = 2
        _ = M.press(x: 250, y: 160); let r3 = M.release(x: 250, y: 160)   // 停用的項目   // l10n-ignore：selftest 訊息
        M.open = 2
        let a4 = M.press(x: 800, y: 800); _ = M.release(x: 800, y: 800); let closedOutside = M.open == nil
        let a5 = M.press(x: 800, y: 800)   // 收著時點別處：不歸選單   // l10n-ignore：selftest 訊息
        (M.live, M.open, M.titleRects, M.itemRects) = (savedLive, savedOpen, savedT, savedI)
        check(a1 && r1 == nil && opened && a2 && r2 == .keep && closedAfterItem && r3 == nil && a4 && closedOutside && !a5,
              "1988 選單：點標題拉開、點項目做事並收起、停用的不做、點外面收起")   // l10n-ignore：selftest 訊息

        // Bit1：CTLine（中文）畫完不會讓下一段英文位移
        func ink(_ b: Bit1) -> [UInt8] { let img = b.finish(); guard let d = img.dataProvider?.data, let p = CFDataGetBytePtr(d) else { return [] }; return Array(UnsafeBufferPointer(start: p, count: CFDataGetLength(d))) }
        let f = Sys6Art.chicago(12)
        let mixed = Bit1(128, 32); mixed.fill(0, 0, 128, 32, false); mixed.text("中", 2, 14, f);   // l10n-ignore：測試樣本
        mixed.fill(0, 0, 128, 32, false); mixed.text("AB", 40, 24, f)
        let plain = Bit1(128, 32); plain.fill(0, 0, 128, 32, false); plain.text("AB", 40, 24, f)
        check(ink(mixed) == ink(plain), "Bit1：中文後面接英文，英文畫在原來的位置")
    }
}
