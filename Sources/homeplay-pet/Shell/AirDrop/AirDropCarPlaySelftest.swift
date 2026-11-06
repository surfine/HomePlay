// --selftest：CarPlay 連著時的 AirDrop 對策（傳給自己）。不碰真的「訊息」、chat.db、系統設定。

import AppKit
import SQLite3

enum AirDropCarPlaySelftest {
    static func run(_ check: (Bool, String) -> Void) {
        selfShare(check)
        ownHandles(check)
        pause(check)
    }

    // MARK: 收 AirDrop：暫停 CarPlay

    static func pause(_ check: (Bool, String) -> Void) {
        typealias P = CarPlayPausePlan
        // 時間規則
        var p = P(now: 0)
        check(p.tick(now: 59, writing: false) == .none && p.tick(now: 60, writing: false) == .resume(.timeout), "收 AirDrop：預設 60 秒，沒收到東西到時恢復")   // l10n-ignore：selftest 訊息
        p = P(now: 0)
        check(p.tick(now: 10, writing: true) == .none, "收 AirDrop：剛開始就在寫，不用延長")   // l10n-ignore：selftest 訊息
        p.fileReceived(now: 12)
        check(p.tick(now: 16.9, writing: false) == .none && p.tick(now: 17, writing: false) == .resume(.received), "收 AirDrop：傳完再 5 秒恢復")   // l10n-ignore：selftest 訊息
        p = P(now: 0); p.fileReceived(now: 10)
        _ = p.tick(now: 13, writing: true)   // 第二個檔案開始寫
        check(p.tick(now: 17, writing: true) == .none && p.tick(now: 20, writing: false) == .none && p.tick(now: 21.9, writing: false) == .none && p.tick(now: 22, writing: false) == .resume(.received),
              "收 AirDrop：還有檔案在寫就不恢復，從最後一次寫入重算 5 秒")   // l10n-ignore：selftest 訊息
        p = P(now: 0)
        check(p.tick(now: 45, writing: true) == .extend(40) && p.remaining(45) == 40, "收 AirDrop：快到時還在寫就延長")   // l10n-ignore：selftest 訊息
        var last = P.Action.none
        for t in stride(from: 46.0, through: 200, by: 1) { last = p.tick(now: t, writing: true); if case .resume = last { check(t == 180, "收 AirDrop：一直在寫也最多 3 分鐘（\(t)）"); break } }   // l10n-ignore：selftest 訊息
        check(last == .resume(.timeout), "收 AirDrop：寫不完到 3 分鐘照樣恢復")   // l10n-ignore：selftest 訊息

        // 控制器：送給接收端的指令
        let saved = (CarPlayAirDropPause.shared, SelfShare.forceCarPlay)
        defer { CarPlayAirDropPause.shared = saved.0; SelfShare.forceCarPlay = saved.1 }
        let c = CarPlayAirDropPause(); CarPlayAirDropPause.shared = c
        var sent: [String] = []
        c.send = { sent.append($0) }; c.writing = { false }
        SelfShare.forceCarPlay = false
        check(!c.available && !c.begin(now: 0) && sent.isEmpty && ControlCenter.unavailable(.airDropReceive), "收 AirDrop：沒有 CarPlay 會話按不了")   // l10n-ignore：selftest 訊息
        SelfShare.forceCarPlay = true
        check(c.available && !ControlCenter.unavailable(.airDropReceive) && c.begin(now: 0) && sent == [#"{"type":"pauseCarPlay","seconds":60}"#], "收 AirDrop：會話中按下送 pauseCarPlay 60 秒")   // l10n-ignore：selftest 訊息
        check(!c.begin(now: 1) && sent.count == 1, "收 AirDrop：暫停中再按不會重送暫停")   // l10n-ignore：selftest 訊息
        c.writing = { true }
        check(c.tick(now: 45) && sent.last == #"{"type":"pauseCarPlay","seconds":40}"#, "收 AirDrop：還在寫就送延長")   // l10n-ignore：selftest 訊息
        c.writing = { false }; c.fileReceived(now: 50)
        check(!c.tick(now: 54) && c.tick(now: 55) && sent.last == CarPlayAirDropPause.resumeJSON && !c.isPaused, "收 AirDrop：傳完 5 秒送 resumeCarPlay")   // l10n-ignore：selftest 訊息
        check(!c.shutdown() && sent.count == 3, "收 AirDrop：沒在暫停，結束時不送")   // l10n-ignore：selftest 訊息
        _ = c.begin(now: 100)
        c.receiverSaid(#"{"type":"carPlayPause","state":"resumed","seconds":0,"reason":"timeout"}"#)
        check(!c.isPaused && sent.last == #"{"type":"pauseCarPlay","seconds":60}"#, "收 AirDrop：接收端自己到時恢復，桌寵收掉倒數、不再送")   // l10n-ignore：selftest 訊息
        _ = c.begin(now: 200)
        check(c.shutdown() && sent.last == CarPlayAirDropPause.resumeJSON, "收 AirDrop：暫停中結束桌寵一定送 resume")   // l10n-ignore：selftest 訊息
        // 無感恢復：按下時在哪個畫面，重連後回哪個畫面；只取一次；不是暫停造成的重連不插手
        var onCarPlay = false
        c.showingCarPlay = { onCarPlay }
        _ = c.begin(now: 300)
        check(c.intentional(now: 310), "收 AirDrop：暫停中斷線算自己要的")   // l10n-ignore：selftest 訊息
        c.resume(.received, now: 320)
        check(c.intentional(now: 321) && c.takeRestore(now: 322) == false && c.takeRestore(now: 323) == nil && !c.intentional(now: 324),
              "收 AirDrop：在主畫面按的，重連後留在主畫面（只取一次）")   // l10n-ignore：selftest 訊息
        onCarPlay = true; _ = c.begin(now: 400); c.resume(.user, now: 410)
        check(c.takeRestore(now: 412) == true, "收 AirDrop：在 CarPlay 畫面按的，重連後回 CarPlay")   // l10n-ignore：selftest 訊息
        _ = c.begin(now: 500); c.resume(.user, now: 510)
        check(c.takeRestore(now: 500 + CarPlayPausePlan.maxTotal + 31) == nil, "收 AirDrop：太久之後的重連不算這次暫停")   // l10n-ignore：selftest 訊息
        // 延長與恢復由暫停期間自己的計時器推動，不靠錶面每幀：只跑 RunLoop、不叫 tick
        let c2 = CarPlayAirDropPause()
        var sent2: [String] = [], changes = 0, fake = 0.0, wr = true
        c2.send = { sent2.append($0) }; c2.writing = { wr }; c2.clockNow = { fake }; c2.onChange = { changes += 1 }
        func spin(_ until: () -> Bool) { let lim = Date().addingTimeInterval(2); while !until() && Date() < lim { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
        let began = c2.begin(now: 0) && c2.hasTicker
        fake = 45; spin { sent2.count >= 2 }
        let extended = sent2.count == 2 && sent2[1] == #"{"type":"pauseCarPlay","seconds":40}"#
        wr = false; c2.fileReceived(now: 46); fake = 52; spin { !c2.isPaused }
        check(began && extended && !c2.isPaused && sent2.last == CarPlayAirDropPause.resumeJSON && changes >= 2 && !c2.hasTicker,
              "收 AirDrop：延長與恢復由自己的計時器推動，錶面不更新也照跑（\(sent2.count)、\(changes)）")   // l10n-ignore：selftest 訊息
        check(CarPlayAirDropPause.clock(42) == "0:42" && CarPlayAirDropPause.clock(125) == "2:05" && CarPlayAirDropPause.clock(0.2) == "0:01", "收 AirDrop：倒數格式")   // l10n-ignore：selftest 訊息

        // 控制中心與卡片
        check(CCLayout.standard.normalized() == CCLayout.standard && CCLayout.standard.page(of: .airDropReceive) == 1 && ControlCenter.Tile.airDropReceive.category == .connectivity,
              "收 AirDrop：控制中心預設在第二頁、連線類")   // l10n-ignore：selftest 訊息
        check(ControlCenter.locked(.airDropReceive, PersonalGate.Inputs(guestMode: true)) && ControlCenter.locked(.airDropReceive, PersonalGate.Inputs(remoteGuest: true))
              && !ControlCenter.locked(.airDropReceive, PersonalGate.Inputs()), "收 AirDrop：訪客、遠端訪客鎖住")   // l10n-ignore：selftest 訊息
        let m = CarPlayAirDropCard.paused(P(now: 0), now: 18)
        check(m.buttons.map(\.0) == [.resume] && (m.note ?? "").contains("0:42") && !m.body.isEmpty, "收 AirDrop：倒數卡有剩餘時間與「恢復 CarPlay」")   // l10n-ignore：selftest 訊息
        var r = P(now: 0); r.fileReceived(now: 5)
        check(CarPlayAirDropCard.paused(r, now: 6).note != m.note, "收 AirDrop：收到檔案後卡片改說馬上恢復")   // l10n-ignore：selftest 訊息
    }

    // MARK: 傳給自己

    static func selfShare(_ check: (Bool, String) -> Void) {
        let force0 = SelfShare.forceCarPlay, flow0 = SelfShareFlow.shared, perform0 = AirDropShare.perform
        defer { SelfShare.forceCarPlay = force0; SelfShareFlow.shared = flow0; AirDropShare.perform = perform0 }
        var airdropped: [[Any]] = []
        AirDropShare.perform = { airdropped.append($0); return true }
        let page = URL(string: "https://example.com/p")!

        // 不在會話中：照舊 AirDrop；會話中：出確認卡、不走 AirDrop
        SelfShare.forceCarPlay = false
        let f = SelfShareFlow(); SelfShareFlow.shared = f
        f.runLookup = { work, done in done(work()) }; f.onLookup = {}   // 自檢：同步查
        f.allowed = { true }; f.access = { .available }; f.candidates = { ["me@example.com"] }; f.chosen = { nil }
        var delivered: [(SelfShare.Piece, String)] = []
        f.deliver = { piece, _, h, done in delivered.append((piece, h)); done(.sent) }
        check(SelfShare.share(.page(page)) && airdropped.count == 1 && !f.visible, "CarPlay AirDrop：不在會話中照舊 AirDrop")   // l10n-ignore：selftest 訊息
        check(SelfShare.title == AirDropShare.title && SelfShare.symbol == AirDropShare.symbol, "CarPlay AirDrop：不在會話中分享鈕照舊")   // l10n-ignore：selftest 訊息
        SelfShare.forceCarPlay = true
        check(SelfShare.title != AirDropShare.title && SelfShare.symbol == "message.fill" && !SelfShare.note.isEmpty, "CarPlay AirDrop：會話中分享鈕換成訊息、有一行說明")   // l10n-ignore：selftest 訊息
        _ = SelfShare.share(.page(page))
        check(airdropped.count == 1 && f.state == .confirming(summary: "example.com") && delivered.isEmpty, "CarPlay AirDrop：會話中先出確認卡，不走 AirDrop、還沒送")   // l10n-ignore：selftest 訊息
        f.confirm()
        check(delivered.count == 1 && delivered[0].0 == .text(page.absoluteString) && delivered[0].1 == "me@example.com" && f.state == .done(.sent),
              "CarPlay AirDrop：按傳送才送，網頁送網址給自己的帳號")   // l10n-ignore：selftest 訊息
        check(f.tick(now: f.since + 3) && f.state == .idle, "CarPlay AirDrop：已傳送幾秒後自己收")   // l10n-ignore：selftest 訊息

        // 照片送附件；選過的帳號優先
        f.chosen = { "+886900000000" }
        f.propose(.photoFile(URL(fileURLWithPath: "/tmp/a.jpg")))
        f.confirm()
        check(delivered.last.map { $0.0 == .file(URL(fileURLWithPath: "/tmp/a.jpg")) && $0.1 == "+886900000000" } == true, "CarPlay AirDrop：照片送附件、設定裡選的帳號優先")   // l10n-ignore：selftest 訊息
        f.cancel()

        // 不能送的情況：訪客、沒有完整磁碟取用權限、找不到帳號；取消不送
        let n = delivered.count
        f.allowed = { false }; f.propose(.page(page))
        check(f.state == .done(.guest), "CarPlay AirDrop：訪客模式不能傳給主人的 iPhone")   // l10n-ignore：selftest 訊息
        f.allowed = { true }; f.access = { .needsFullDiskAccess }; f.propose(.page(page))
        check(f.state == .done(.needsFullDisk), "CarPlay AirDrop：沒有完整磁碟取用權限就說明，不送")   // l10n-ignore：selftest 訊息
        f.access = { .available }; f.chosen = { nil }; f.candidates = { [] }; f.propose(.page(page))
        check(f.state == .done(.noHandle), "CarPlay AirDrop：找不到自己的帳號就請到設定選")   // l10n-ignore：selftest 訊息
        f.candidates = { ["me@example.com"] }; f.propose(.page(page)); f.cancel(); f.confirm()
        check(f.state == .idle && delivered.count == n, "CarPlay AirDrop：取消就不送")   // l10n-ignore：selftest 訊息
        // 確認卡開著時主人走開：按傳送也不送
        f.propose(.page(page)); f.allowed = { false }; f.confirm()
        check(f.state == .done(.guest) && delivered.count == n, "CarPlay AirDrop：確認卡開著時主人走開，按傳送也不送")   // l10n-ignore：selftest 訊息
        f.allowed = { true }
        // 自己的帳號在背景查：查好之前顯示「正在載入」、不在主執行緒查；查好接著出確認卡；之後用快取不再查
        var pendingLookup: (() -> Void)?, lookups = 0
        f.runLookup = { work, done in pendingLookup = { let r = work(); done(r) } }
        f.candidates = { lookups += 1; return ["me@example.com"] }
        f.propose(.page(page))
        let loadingShown = f.state == .loading && lookups == 0 && CarPlayAirDropCard.model(.loading)?.buttons.map(\.0) == [.cancel]
        pendingLookup?(); pendingLookup = nil
        check(loadingShown && f.state == .confirming(summary: "example.com") && lookups == 1, "CarPlay AirDrop：帳號還沒查好先顯示正在載入，查好接著出確認卡")   // l10n-ignore：selftest 訊息
        f.cancel(); f.propose(.page(page))
        check(f.state == .confirming(summary: "example.com") && lookups == 1 && pendingLookup == nil, "CarPlay AirDrop：查過的帳號快取起來，再按不再查 chat.db")   // l10n-ignore：selftest 訊息
        f.cancel()
        f.candidates = { ["me@example.com"] }; f.propose(.page(page)); f.cancel()
        let n2 = delivered.count
        pendingLookup?(); pendingLookup = nil
        check(f.state == .idle && delivered.count == n2, "CarPlay AirDrop：載入中按取消，查好也不再跳出確認卡")   // l10n-ignore：selftest 訊息
        // 真的背景佇列：查詢不在主執行緒
        let g = SelfShareFlow(); var bgMain: Bool?
        g.onLookup = {}; g.allowed = { true }; g.chosen = { nil }; g.access = { .available }
        g.candidates = { bgMain = Thread.isMainThread; return ["me@example.com"] }
        g.propose(.page(page))
        let lim = Date().addingTimeInterval(2)
        while g.state == .loading && Date() < lim { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        check(bgMain == false && g.state == .confirming(summary: "example.com"), "CarPlay AirDrop：查自己的帳號在背景佇列，不在主執行緒")   // l10n-ignore：selftest 訊息
        f.runLookup = { work, done in done(work()) }
        // 送出結果照 MessagesSender：查不到＝可能已送出（不給重試）
        f.finish(.unconfirmed); check(f.state == .done(.unconfirmed), "CarPlay AirDrop：查不到記錄說「可能已送出」")   // l10n-ignore：selftest 訊息
        f.finish(.needsAutomation); check(f.state == .done(.needsAutomation), "CarPlay AirDrop：沒有自動化權限要說明")   // l10n-ignore：selftest 訊息
        f.finish(.failed("x")); check(f.state == .done(.failed), "CarPlay AirDrop：腳本錯誤說沒送出")   // l10n-ignore：selftest 訊息

        // 食譜：文字，有原網址附在最後
        let r = Recipe(title: "Soup", ingredients: ["water"], steps: [RecipeStep(text: "boil")], sourceURL: "https://example.com/soup")
        let t = SelfShare.recipeText(r)
        check(t.hasPrefix("Soup") && t.contains("• water") && t.contains("1. boil") && t.hasSuffix("https://example.com/soup"), "CarPlay AirDrop：食譜送文字、原網址附在最後")   // l10n-ignore：selftest 訊息
        check(!SelfShare.recipeText(Recipe(title: "Soup", ingredients: [], steps: [])).contains("http"), "CarPlay AirDrop：沒網址的食譜只送文字")   // l10n-ignore：selftest 訊息
        check(SelfShare.piece(.page(URL(string: "about:blank")!)) == nil, "CarPlay AirDrop：空白頁不送")   // l10n-ignore：selftest 訊息

        // 卡片：每個狀態都有字；要做事的有按鈕；確認卡帶那一行說明
        let states: [SelfShareFlow.State] = [.loading, .confirming(summary: "x"), .sending] + [.sent, .unconfirmed, .needsAutomation, .failed, .needsFullDisk, .noHandle, .guest].map { .done($0) }
        check(states.allSatisfy { s in CarPlayAirDropCard.model(s).map { !$0.body.isEmpty && ($0.buttons.isEmpty == (s == .sending)) } == true } && CarPlayAirDropCard.model(.idle) == nil,
              "CarPlay AirDrop：卡片每個狀態都有字，只有傳送中沒有按鈕")   // l10n-ignore：selftest 訊息
        check(CarPlayAirDropCard.model(.confirming(summary: "x"))?.note == SelfShare.note && CarPlayAirDropCard.model(.confirming(summary: "x"))?.buttons.map(\.0) == [.cancel, .send],
              "CarPlay AirDrop：確認卡有說明、取消／傳送")   // l10n-ignore：selftest 訊息
        let lay = CarPlayAirDropCard.layout(CarPlayAirDropCard.model(.done(.needsFullDisk))!)
        check(lay.rect.maxY <= 1024 - 40 && lay.rect.minY > AirDropCard.rect.maxY, "CarPlay AirDrop：卡片貼下緣，不跟上緣的收件卡疊")   // l10n-ignore：selftest 訊息

        // AppleScript：路徑與帳號都當字串常值
        let s = MessagesSender.fileScript(path: "/tmp/a \"b\".png", to: "me@example.com")
        check(s.contains("POSIX file \"/tmp/a \\\"b\\\".png\"") && s.contains("participant \"me@example.com\""), "CarPlay AirDrop：附件腳本跳脫路徑")   // l10n-ignore：selftest 訊息
        var res: MessagesSendResult?
        MessagesSender.sendFile(URL(fileURLWithPath: "/tmp/x.png"), to: "a", confirmed: false) { res = $0 }
        check(res == .notConfirmed, "CarPlay AirDrop：附件沒帶 confirmed 不送")   // l10n-ignore：selftest 訊息
    }

    // MARK: 自己的帳號、附件回查（記憶體資料庫）

    static func ownHandles(_ check: (Bool, String) -> Void) {
        var h: OpaquePointer?
        guard sqlite3_open(":memory:", &h) == SQLITE_OK, let h else { check(false, "CarPlay AirDrop：開不了記憶體資料庫"); return }   // l10n-ignore：selftest 訊息
        var ok = true
        func exec(_ s: String) { if sqlite3_exec(h, s, nil, nil, nil) != SQLITE_OK { ok = false } }
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let recent = Int64((now.timeIntervalSinceReferenceDate - 86400) * 1e9), old = Int64((now.timeIntervalSinceReferenceDate - 400 * 86400) * 1e9)
        let ancient = Int64((now.timeIntervalSinceReferenceDate - 1000 * 86400) * 1e9)   // 兩年外：不掃
        exec("""
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT, attributedBody BLOB, is_from_me INTEGER, service TEXT, date INTEGER,
          destination_caller_id TEXT, error INTEGER DEFAULT 0, associated_message_type INTEGER DEFAULT 0);
        CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, filename TEXT, transfer_name TEXT);
        CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT);
        INSERT INTO message (is_from_me, service, date, destination_caller_id) VALUES
          (1,'iMessage',\(old),'old@example.com'),(1,'iMessage',\(old),'old@example.com'),(1,'iMessage',\(old),'old@example.com'),
          (1,'iMessage',\(recent),'+886900000000'),(1,'iMessage',\(recent),'e:Me@Example.com'),(1,'iMessage',\(recent),'+886900000000'),
          (0,'iMessage',\(recent),'+886911111111'),(1,'SMS',\(recent),'+886922222222'),(1,'iMessage',\(recent),''),
          (1,'iMessage',\(ancient),'ancient@example.com'),(1,'iMessage',\(ancient),'ancient@example.com'),(1,'iMessage',\(ancient),'ancient@example.com'),
          (1,'iMessage',\(ancient),'ancient@example.com');
        """)
        let store = MessagesStore(connection: h)
        let hs = store.ownHandles(now: now)
        check(ok && hs == ["+886900000000", "Me@Example.com", "old@example.com"], "CarPlay AirDrop：自己的帳號＝外送 iMessage 的寄件帳號，最近常用的排前面、兩年外的不查（\(hs.count)）")   // l10n-ignore：selftest 訊息
        let base = store.maxRowID()
        check(store.outgoingAttachment(after: base, name: "a.png") == .none, "CarPlay AirDrop：還沒送出就查不到附件")   // l10n-ignore：selftest 訊息
        exec("""
        INSERT INTO message (ROWID, is_from_me, service, date) VALUES (\(base + 1), 1, 'iMessage', \(recent));
        INSERT INTO attachment VALUES (1, '~/Library/Messages/Attachments/x/a.png', 'a.png');
        INSERT INTO message_attachment_join VALUES (\(base + 1), 1);
        """)
        check(store.outgoingAttachment(after: base, name: "a.png") == .found && store.outgoingAttachment(after: base, name: "b.png") == .none,
              "CarPlay AirDrop：送出後照檔名查到附件")   // l10n-ignore：selftest 訊息
    }
}
