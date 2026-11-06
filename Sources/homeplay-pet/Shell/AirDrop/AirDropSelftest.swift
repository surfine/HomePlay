// AirDrop 整合的自檢（--selftest）：全部用暫存資料夾、假的分享動作、記憶體版的可被發現設定——不碰真的「下載項目」與系統設定。

import AppKit

enum AirDropSelftest {
    static func run(_ check: (Bool, String) -> Void) {
        // 認 AirDrop：quarantine 第三欄是 sharingd
        check(AirDropRules.isAirDrop(quarantine: "0081;6aecd829;sharingd;0A1B2C3D-0000-4000-8000-000000000001"), "AirDrop：quarantine 第三欄 sharingd 才算")
        check(!AirDropRules.isAirDrop(quarantine: "0083;6adf20bc;com.apple.Safari.SandboxBroker.xpc;D6538312") && !AirDropRules.isAirDrop(quarantine: "0081;6aecd829") && !AirDropRules.isAirDrop(quarantine: nil),
              "AirDrop：瀏覽器下載、欄位不全、沒有屬性都不算")   // l10n-ignore：selftest 訊息
        check(AirDropRules.isTemporary("a.crdownload") && AirDropRules.isTemporary(".DS_Store") && !AirDropRules.isTemporary("IMG_1.heic"), "AirDrop：暫存檔與隱藏檔不處理")

        // 連結
        let plist = Data(#"<?xml version="1.0"?><plist version="1.0"><dict><key>URL</key><string>https://example.com/a?b=1</string></dict></plist>"#.utf8)
        check(AirDropRules.linkURL(webloc: plist)?.host == "example.com", "AirDrop：.webloc 讀出網址")
        check(AirDropRules.linkURL(internetShortcut: "[InternetShortcut]\r\nURL=https://example.com/x\r\n")?.path == "/x", "AirDrop：.url 讀出網址")
        check(AirDropRules.linkURL(plain: " https://example.com/r \n") != nil && AirDropRules.linkURL(plain: "see https://example.com") == nil
              && AirDropRules.linkURL(plain: "file:///etc/passwd") == nil && AirDropRules.linkURL(plain: "javascript:alert(1)") == nil, "AirDrop：純文字只收單一 http(s) 網址")   // l10n-ignore：selftest 訊息
        var reads = 0
        let pdf = AirDropRules.classify(name: "a.PDF") { reads += 1; return nil }
        let jpg = AirDropRules.classify(name: "IMG.HEIC") { reads += 1; return nil }
        let wl = AirDropRules.classify(name: "x.webloc") { plist }
        let txt = AirDropRules.classify(name: "note.txt") { Data("https://example.com/t".utf8) }
        let txt2 = AirDropRules.classify(name: "note.txt") { Data("hello".utf8) }
        check(pdf.0 == .other && jpg.0 == .photo && reads == 0 && wl.0 == .link && txt.0 == .link && txt2.0 == .other, "AirDrop：分類（照片、連結、其他；其他與照片不讀檔）")

        // 寫完才處理
        check(!AirDropRules.settled(prev: nil, sig: "1", now: 5) && !AirDropRules.settled(prev: ("1", 4.5), sig: "1", now: 5) && !AirDropRules.settled(prev: ("1", 3), sig: "2", now: 5)
              && AirDropRules.settled(prev: ("1", 3), sig: "1", now: 5), "AirDrop：大小與時間不變隔 1 秒才算寫完")   // l10n-ignore：selftest 訊息
        check(AirDropRules.uniqueName("a.jpg") { _ in false } == "a.jpg" && AirDropRules.uniqueName("a.jpg") { $0 == "a.jpg" || $0 == "a 2.jpg" } == "a 3.jpg", "AirDrop：同名加序號")

        // 收件：暫存資料夾走完整流程
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("hp-airdrop-test-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        func put(_ name: String, _ body: String, quarantine q: String?) -> URL {
            let u = dir.appendingPathComponent(name)
            try? Data(body.utf8).write(to: u)
            if let q { _ = setxattr(u.path, "com.apple.quarantine", q, q.utf8.count, 0, 0) }
            return u
        }
        let t0 = 0x6aecd829   // quarantine 第二欄：寫入時間（十六進位秒）
        func q(_ t: Int, _ agent: String = "sharingd") -> String { "0081;\(String(t, radix: 16));\(agent);U\(t)" }
        check(AirDropRules.quarantineTime(q(t0)) == Double(t0) && AirDropRules.isRecent(quarantine: q(t0), now: Double(t0 + 60))
              && !AirDropRules.isRecent(quarantine: q(t0), now: Double(t0 + 3600)) && !AirDropRules.isRecent(quarantine: "0081;zz;sharingd;U", now: 0),
              "AirDrop：quarantine 寫入時間只認最近幾分鐘")   // l10n-ignore：selftest 訊息
        _ = put("old.jpg", "x", quarantine: q(t0))   // 啟動前就在：舊檔
        let inbox = AirDropInbox(folder: dir)
        var got: [AirDropItem] = []
        var wall = Double(t0 + 30)
        inbox.wallNow = { wall }
        inbox.onReceive = { got.append($0) }
        check(inbox.start() && inbox.running, "AirDrop：開始監看資料夾")
        let new = put("IMG_9.jpg", "abc", quarantine: q(t0))
        _ = put("browser.png", "abc", quarantine: q(t0, "Google Chrome"))
        _ = put("Card.webloc", String(data: plist, encoding: .utf8) ?? "", quarantine: q(t0))
        inbox.scan(now: 0); inbox.scan(now: 0.5)
        check(got.isEmpty, "AirDrop：剛出現、還沒穩定不處理")
        inbox.scan(now: 1.6)
        let names = got.map(\.name).sorted()
        check(names == ["Card.webloc", "IMG_9.jpg"] && got.first { $0.name == "IMG_9.jpg" }?.kind == .photo && got.first { $0.name == "Card.webloc" }?.link?.host == "example.com",
              "AirDrop：只收 sharingd 來的新檔（舊檔、瀏覽器下載不算）：\(names)")   // l10n-ignore：selftest 訊息
        inbox.scan(now: 5)
        check(got.count == 2, "AirDrop：同一個檔不重複通知")
        // 還在長的檔案：大小一變就重新等
        let grow = put("big.zip", "1", quarantine: q(t0))
        inbox.scan(now: 10); inbox.scan(now: 10.6)
        try? Data("12345678".utf8).write(to: grow)
        inbox.scan(now: 11.2)
        check(got.count == 2, "AirDrop：檔案還在長就不處理")
        inbox.scan(now: 12.5)
        check(got.count == 3 && got.last?.kind == .other, "AirDrop：長完之後才處理")
        // 一小時後在「下載項目」裡改名、⌘D 複製以前收到的檔案：屬性跟著帶過去，但寫入時間是舊的，不彈
        wall = Double(t0 + 3600)
        try? fm.moveItem(at: grow, to: dir.appendingPathComponent("Archive.zip"))
        let dup = dir.appendingPathComponent("IMG_9 copy.jpg")
        try? fm.copyItem(at: new, to: dup)
        _ = setxattr(dup.path, "com.apple.quarantine", q(t0), q(t0).utf8.count, 0, 0)
        inbox.scan(now: 20); inbox.scan(now: 21.5)
        check(got.count == 3, "AirDrop：改名、複製以前收到的檔案不彈卡片")   // l10n-ignore：selftest 訊息
        // 收過的刪掉、再收一個同名的：照樣認得
        try? fm.removeItem(at: dir.appendingPathComponent("Card.webloc"))
        inbox.scan(now: 22)
        _ = put("Card.webloc", String(data: plist, encoding: .utf8) ?? "", quarantine: q(t0 + 3590))
        inbox.scan(now: 23); inbox.scan(now: 24.5)
        check(got.count == 4 && got.last?.name == "Card.webloc", "AirDrop：收過的刪掉再收同名的照樣彈")   // l10n-ignore：selftest 訊息
        inbox.stop()
        check(!inbox.running, "AirDrop：停止監看")
        _ = new

        // 卡片：動作、訪客、複製
        typealias C = AirDropCard
        let photo = AirDropItem(url: dir.appendingPathComponent("IMG_9.jpg"), kind: .photo, link: nil)
        let link = AirDropItem(url: dir.appendingPathComponent("Card.webloc"), kind: .link, link: URL(string: "https://example.com/r"))
        let other = AirDropItem(url: dir.appendingPathComponent("big.zip"), kind: .other, link: nil)
        check(C.actions(.photo, redacted: false) == [.addPhoto] && C.actions(.link, redacted: false) == [.openLink] && C.actions(.other, redacted: false) == [.preview, .reveal],
              "AirDrop 卡片：照片、連結、其他各給對的按鈕")   // l10n-ignore：selftest 訊息
        check(C.actions(.photo, redacted: true).isEmpty && C.actions(.other, redacted: true).isEmpty, "AirDrop 卡片：訪客不給按鈕")
        let shown = [C.title(photo, redacted: true), C.subtitle(photo, redacted: true), C.title(link, redacted: true), C.subtitle(link, redacted: true)].joined(separator: "|")
        check(!shown.contains("IMG_9") && !shown.contains("example.com") && C.title(photo, redacted: true) == L("airdrop.guest.title", "收到一个文件"), "AirDrop 卡片：訪客只看到「收到一个文件」，不露檔名與網址")
        check(C.title(link, redacted: false) == "example.com" && C.title(photo, redacted: false) == "IMG_9.jpg", "AirDrop 卡片：主人看到檔名／網域")
        let shelf = dir.appendingPathComponent("shelf", isDirectory: true)
        let c1 = C.addToPhotoFace(photo.url, folder: shelf), c2 = C.addToPhotoFace(photo.url, folder: shelf)
        check(c1?.lastPathComponent == "IMG_9.jpg" && c2?.lastPathComponent == "IMG_9 2.jpg" && fm.fileExists(atPath: photo.url.path), "AirDrop 卡片：複製進照片錶面資料夾（自動建、同名加序號、原檔不動）")
        check(C.addToPhotoFace(dir.appendingPathComponent("missing.jpg"), folder: shelf) == nil, "AirDrop 卡片：來源不見了回失敗")

        // 卡片的生命週期：進來、逾時收起、換下一張
        C.clear(); C.redactedOverride = nil
        C.receive(photo, now: 100); C.receive(other, now: 100)
        check(C.shown && C.current == photo && C.queue.count == 2, "AirDrop 卡片：進來就顯示，第二張排隊")
        _ = C.tick(100)
        _ = C.tick(100 + C.lifetime + 1)
        check(!C.shown && C.current == photo, "AirDrop 卡片：逾時開始收起")
        _ = C.tick(130)
        check(C.current == other && C.shown, "AirDrop 卡片：收完換下一張")
        C.dismiss(); _ = C.tick(131); _ = C.tick(160)
        check(C.queue.isEmpty && !C.shown, "AirDrop 卡片：點掉後清空")
        C.clear()

        // 訪客臨時接收（2026-11-07 改用系統官方開關）：按下只開系統設定，不寫系統設定；舊版的待還原紀錄啟動時補還原一次就刪
        check(AirDropGuest.shared.store is AirDropMemoryStore && !AirDropGuest.shared.persist, "AirDrop 訪客接收：自檢用記憶體版，不碰系統設定")
        check(AirDropGuest.settingsURL == "x-apple.systempreferences:com.apple.AirDrop-Handoff-Settings.extension", "AirDrop 訪客接收：打開的是系統設定的 AirDrop 頁")   // l10n-ignore
        let suite = "homeplay.selftest.airdrop"
        let ud = UserDefaults(suiteName: suite)!
        ud.removePersistentDomain(forName: suite)
        defer { ud.removePersistentDomain(forName: suite) }
        let mem = AirDropMemoryStore("Contacts Only")
        var opened = 0
        let g = AirDropGuest(store: mem, persist: true, defaults: ud)
        g.openSettings = { opened += 1 }
        g.open(); g.open()
        check(opened == 2 && mem.writes.isEmpty && mem.value == "Contacts Only" && ud.dictionary(forKey: AirDropGuest.recordKey) == nil,
              "AirDrop 訪客接收：按下＝打開系統設定，不寫系統設定、不留紀錄")   // l10n-ignore
        check(!g.recoverIfNeeded() && mem.writes.isEmpty, "AirDrop 訪客接收：沒有舊紀錄就不動")   // l10n-ignore
        ud.set(["original": "Off", "has": true], forKey: AirDropGuest.recordKey)
        mem.value = "Everyone"
        check(g.recoverIfNeeded() && mem.value == "Off" && mem.writes == ["Off"] && ud.dictionary(forKey: AirDropGuest.recordKey) == nil && !g.recoverIfNeeded() && mem.writes.count == 1,
              "AirDrop 訪客接收：舊版留下的紀錄補還原一次（原值 Off），刪掉紀錄後不再寫")   // l10n-ignore
        ud.set(["original": "", "has": false], forKey: AirDropGuest.recordKey)
        check(g.recoverIfNeeded() && mem.value == "Contacts Only" && AirDropGuest.restoreTarget("Everyone") == "Contacts Only" && AirDropGuest.restoreTarget(nil) == "Contacts Only",
              "AirDrop 訪客接收：舊紀錄沒有原值或原值是 Everyone＝還原成 Contacts Only")   // l10n-ignore
        let ro = AirDropGuest(store: mem, persist: false, defaults: ud)
        ud.set(["original": "Off", "has": true], forKey: AirDropGuest.recordKey)
        check(!ro.recoverIfNeeded() && ud.dictionary(forKey: AirDropGuest.recordKey) != nil, "AirDrop 訪客接收：快照／自檢版（不存紀錄）不動舊紀錄")   // l10n-ignore

        // 傳到手機
        var sent: [[Any]] = []
        let perform0 = AirDropShare.perform
        AirDropShare.perform = { sent.append($0); return true }
        defer { AirDropShare.perform = perform0 }
        let page = URL(string: "https://example.com/p")
        check(AirDropShare.send(AirDropShare.items(page: page)) && sent.count == 1 && (sent[0].first as? URL) == page, "AirDrop 分享：網頁送網址")
        check(AirDropShare.items(page: URL(string: "about:blank")).isEmpty && AirDropShare.items(page: nil).isEmpty && AirDropShare.items(photoFile: nil).isEmpty
              && AirDropShare.items(image: nil).isEmpty && !AirDropShare.send([]), "AirDrop 分享：空白頁、沒有照片不送")   // l10n-ignore：selftest 訊息
        let withURL = Recipe(title: "Soup", ingredients: ["water"], steps: [RecipeStep(text: "boil")], sourceURL: "https://example.com/soup")
        let noURL = Recipe(title: "Soup", ingredients: ["water"], steps: [RecipeStep(text: "boil")])
        check((AirDropShare.items(recipe: withURL).first as? URL)?.host == "example.com", "AirDrop 分享：食譜有網址送網址")
        let body = AirDropShare.items(recipe: noURL).first as? String ?? ""
        check(body.contains("Soup") && body.contains("• water") && body.contains("1. boil"), "AirDrop 分享：沒網址的食譜送文字")

        // 控制中心的開關
        check(CCLayout.standard.contains(.airDrop) && ControlCenter.Tile.airDrop.sizes.contains(.s2x1) && ControlCenter.Tile.airDrop.category == .connectivity,
              "AirDrop：控制中心有 AirDrop 開關（連線類、預設在第二頁）")   // l10n-ignore：selftest 訊息
        check(ControlCenter.locked(.airDrop, PersonalGate.Inputs(guestMode: true)) && !ControlCenter.locked(.airDrop, PersonalGate.Inputs()), "AirDrop：訪客模式鎖住開關，要主人才能開")
    }
}
