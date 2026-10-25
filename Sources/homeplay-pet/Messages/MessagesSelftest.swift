// --selftest 的訊息資料層檢查：回傳失敗清單（空＝全過）。用記憶體 SQLite（真實欄位名）造資料，不碰真的 chat.db。

import Foundation
import SQLite3

enum MessagesSelftest {
    static func run() -> [String] {
        var bad: [String] = []
        func check(_ c: Bool, _ m: String) { if !c { bad.append("messages: " + m) } }

        // typedstream 掃描：手工位元組（標頭＋NSString＋01 94 84 01 2B＋長度＋UTF-8）
        func blob(_ text: String, lenBytes: [UInt8]? = nil) -> Data {
            let u = Array(text.utf8)
            var d: [UInt8] = [0x04, 0x0B] + Array("streamtyped".utf8) + [0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84, 0x12]
            d += Array("NSAttributedString".utf8) + [0x00, 0x84, 0x84, 0x08] + Array("NSObject".utf8) + [0x00, 0x85, 0x92, 0x84, 0x84, 0x84, 0x08]
            d += Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B]
            if let lb = lenBytes { d += lb } else if u.count < 0x80 { d.append(UInt8(u.count)) } else { d += [0x81, UInt8(u.count & 255), UInt8(u.count >> 8)] }
            d += u + [0x86, 0x84, 0x02] + Array("NSDictionary".utf8) + [0x00, 0x94, 0x84, 0x01, 0x69, 0x01, 0x92]
            return Data(d)
        }
        check(Typedstream.decode(blob("Hello")) == "Hello", "typedstream 短英文")
        check(Typedstream.decode(blob("週五晚餐 7 點，可以嗎？")) == "週五晚餐 7 點，可以嗎？", "typedstream 中文")
        let long = String(repeating: "\u{597D}", count: 100)   // 300 位元組 → 0x81 長度前綴
        check(Typedstream.decode(blob(long)) == long, "typedstream 0x81 長度")
        check(Typedstream.decode(blob("a\u{FFFC}b ")) == "ab", "typedstream 去掉附件佔位字元")
        check(Typedstream.scanString(Data([1, 2, 3])) == nil, "typedstream 垃圾資料回 nil")
        var cut = blob("Hello"); cut.removeLast(cut.count - 90)
        check(Typedstream.scanString(cut) == nil || Typedstream.scanString(cut) != "Hello!", "typedstream 截斷不崩")

        // handle 正規化
        check(HandleKey.make("+886 912-345-678") == HandleKey.make("0912 345 678"), "電話：+886 與 0 開頭同鑰匙")
        check(HandleKey.make("+14155552671") == HandleKey.make("(415) 555-2671"), "電話：+1 與括號格式同鑰匙")
        check(HandleKey.make("Foo@Example.COM ") == HandleKey.make("foo@example.com"), "信箱不分大小寫")
        check(HandleKey.make("+886912345678") != HandleKey.make("+886912345679"), "不同號碼不同鑰匙")
        check(HandleKey.initial(of: "[朋友 B]") == "朋" && HandleKey.initial(of: "anna") == "A", "圓圈上的字")

        // 日期
        check(abs(MessagesDate.date(fromRaw: 700_000_000_000_000_000).timeIntervalSinceReferenceDate - 7e8) < 1e-6, "日期：奈秒")
        check(abs(MessagesDate.date(fromRaw: 700_000_000).timeIntervalSinceReferenceDate - 7e8) < 1e-6, "日期：舊版秒")
        check(MessagesDate.date(fromRaw: 0).timeIntervalSinceReferenceDate == 0, "日期：0")
        check(MessagesDate.date(fromRaw: 0).timeIntervalSince1970 == 978307200, "日期：2001 紀元")

        // AppleScript 字串跳脫
        check(MessagesSender.literal("a\"b\\c") == "\"a\\\"b\\\\c\"", "AppleScript 跳脫引號與反斜線")
        check(MessagesSender.literal("x\ny") == "\"x\" & linefeed & \"y\"", "AppleScript 換行")

        // 未授權就不送
        var res: MessagesSendResult?
        MessagesSender.send(text: "hi", to: .handle("+10000000000"), confirmed: false) { res = $0 }
        check(res == .notConfirmed, "confirmed=false 不送")

        // 記憶體資料庫：對話、訊息、Tapback 折疊、未讀、新列、外送確認
        var h: OpaquePointer?
        guard sqlite3_open(":memory:", &h) == SQLITE_OK, let h else { return bad + ["messages: cannot open in-memory db"] }
        func exec(_ s: String) { var e: UnsafeMutablePointer<CChar>?; if sqlite3_exec(h, s, nil, nil, &e) != SQLITE_OK { bad.append("messages: SQL failed \(e.map { String(cString: $0) } ?? "")") } }
        exec("""
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, style INTEGER, chat_identifier TEXT, display_name TEXT, is_filtered INTEGER);
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB, handle_id INTEGER, service TEXT, date INTEGER,
          is_from_me INTEGER, is_read INTEGER, item_type INTEGER DEFAULT 0, associated_message_guid TEXT, associated_message_type INTEGER DEFAULT 0,
          associated_message_emoji TEXT, cache_has_attachments INTEGER DEFAULT 0, date_edited INTEGER DEFAULT 0, error INTEGER DEFAULT 0,
          message_summary_info BLOB, is_delivered INTEGER DEFAULT 0, date_read INTEGER DEFAULT 0, thread_originator_guid TEXT,
          balloon_bundle_id TEXT, payload_data BLOB, expressive_send_style_id TEXT, is_audio_message INTEGER DEFAULT 0);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, filename TEXT, mime_type TEXT, transfer_name TEXT, uti TEXT, is_sticker INTEGER, total_bytes INTEGER);
        CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
        INSERT INTO handle VALUES (1, '+886912345678'), (2, 'a@b.com'), (3, '+886900000001');
        INSERT INTO chat VALUES (1, 'iMessage;-;+886912345678', 45, '+886912345678', '', 0),
                                (2, 'iMessage;+;chat123', 43, 'chat123', 'Family', 0),
                                (3, 'iMessage;-;spam', 45, 'spam', '', 1);
        INSERT INTO chat_handle_join VALUES (1, 1), (2, 2), (2, 3), (3, 3);
        """)
        func selftestMsg(_ id: Int, chat: Int, text: String?, ab: Data? = nil, handle: Int, fromMe: Int, read: Int = 1, date: Int, assoc: String = "", type: Int = 0, emoji: String = "", att: Int = 0) {
            var st: OpaquePointer?
            sqlite3_prepare_v2(h, "INSERT INTO message (ROWID, guid, text, attributedBody, handle_id, service, date, is_from_me, is_read, associated_message_guid, associated_message_type, associated_message_emoji, cache_has_attachments) VALUES (?,?,?,?,?, 'iMessage', ?,?,?,?,?,?,?)", -1, &st, nil)
            let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_int(st, 1, Int32(id)); sqlite3_bind_text(st, 2, "G\(id)", -1, T)
            if let text { sqlite3_bind_text(st, 3, text, -1, T) } else { sqlite3_bind_null(st, 3) }
            if let ab { ab.withUnsafeBytes { _ = sqlite3_bind_blob(st, 4, $0.baseAddress, Int32(ab.count), T) } } else { sqlite3_bind_null(st, 4) }
            sqlite3_bind_int(st, 5, Int32(handle)); sqlite3_bind_int64(st, 6, Int64(date) * 1_000_000_000)
            sqlite3_bind_int(st, 7, Int32(fromMe)); sqlite3_bind_int(st, 8, Int32(read)); sqlite3_bind_text(st, 9, assoc, -1, T)
            sqlite3_bind_int(st, 10, Int32(type)); sqlite3_bind_text(st, 11, emoji, -1, T); sqlite3_bind_int(st, 12, Int32(att))
            if sqlite3_step(st) != SQLITE_DONE { bad.append("messages: INSERT failed") }
            sqlite3_finalize(st)
            exec("INSERT INTO chat_message_join VALUES (\(chat), \(id), \(date))")
        }
        selftestMsg(1, chat: 1, text: "晚餐 7 點？", handle: 1, fromMe: 0, read: 0, date: 100)
        selftestMsg(2, chat: 1, text: "可以！", handle: 1, fromMe: 1, date: 110)
        selftestMsg(3, chat: 1, text: nil, ab: blob("只有 attributedBody"), handle: 1, fromMe: 0, read: 0, date: 120)
        selftestMsg(4, chat: 1, text: "Loved “可以！”", handle: 1, fromMe: 0, date: 125, assoc: "p:0/G2", type: 2000)
        selftestMsg(5, chat: 1, text: "Liked “可以！”", handle: 1, fromMe: 0, date: 126, assoc: "p:0/G2", type: 2001)   // 換一種反應＝取代愛心
        selftestMsg(6, chat: 1, text: "Loved “可以！”", handle: 0, fromMe: 1, date: 127, assoc: "p:0/G2", type: 2000)   // 自己也按愛心
        selftestMsg(7, chat: 1, text: "Removed a like", handle: 1, fromMe: 0, date: 128, assoc: "p:0/G2", type: 3001)    // 對方取消讚
        selftestMsg(8, chat: 2, text: "群組訊息", handle: 2, fromMe: 0, read: 0, date: 200)
        selftestMsg(9, chat: 3, text: "過濾掉的", handle: 3, fromMe: 0, read: 0, date: 300)
        exec("INSERT INTO attachment VALUES (1, '~/Library/Messages/Attachments/ab/IMG.heic', 'image/heic', 'IMG.heic', 'public.heic', 0, 1234); INSERT INTO message_attachment_join VALUES (3, 1)")
        // 2.0 imsg：群組裡自己送的三則——已讀＋回覆、撤回、連結預覽
        selftestMsg(20, chat: 2, text: "ok", handle: 0, fromMe: 1, date: 210)
        selftestMsg(21, chat: 2, text: nil, handle: 0, fromMe: 1, date: 220)
        selftestMsg(22, chat: 2, text: "https://example.com/a", handle: 0, fromMe: 1, date: 230)
        let unsentPlist = (try? PropertyListSerialization.data(fromPropertyList: ["otr": ["0": ["le": 3]], "rp": [0]], format: .binary, options: 0)) ?? Data()
        let linkArchive = Self.linkArchive(title: "Example Title", url: "https://example.com/a", site: "Example")
        func bindBlob(_ sql: String, _ d: Data) {
            var st: OpaquePointer?; sqlite3_prepare_v2(h, sql, -1, &st, nil)
            d.withUnsafeBytes { _ = sqlite3_bind_blob(st, 1, $0.baseAddress, Int32(d.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            if sqlite3_step(st) != SQLITE_DONE { bad.append("messages: blob UPDATE failed") }
            sqlite3_finalize(st)
        }
        exec("UPDATE message SET is_delivered = 1, date_read = 215000000000, thread_originator_guid = 'G8' WHERE ROWID = 20")
        bindBlob("UPDATE message SET message_summary_info = ?, date_edited = 225000000000 WHERE ROWID = 21", unsentPlist)
        bindBlob("UPDATE message SET payload_data = ?, balloon_bundle_id = 'com.apple.messages.URLBalloonProvider' WHERE ROWID = 22", linkArchive)

        let store = MessagesStore(connection: h)
        store.nameResolver = { $0 == "+886912345678" ? "\u{5C0F}\u{660E}" : nil }
        let convs = store.conversations()
        check(convs.count == 2, "對話：過濾掉 is_filtered（得到 \(convs.count)）")
        check(convs.first?.guid == "iMessage;+;chat123" && convs.first?.isGroup == true && convs.first?.title == "Family", "對話：群組、display_name、新到舊")
        if let c1 = convs.first(where: { $0.rowID == 1 }) {
            check(!c1.isGroup && c1.unread == 2, "對話：一對一、未讀 2（Tapback 不算，得到 \(c1.unread)）")
            check(c1.title == "\u{5C0F}\u{660E}" && c1.lastText == "只有 attributedBody", "對話：標題用通訊錄名字、最後一則解 attributedBody")
        } else { check(false, "對話 1 不見了") }
        let ms = store.messages(chat: 1)
        check(ms.map(\.rowID) == [3, 2, 1], "訊息：新到舊、Tapback 列不出現")
        check(ms.first?.attachments.first?.path.hasSuffix("/Library/Messages/Attachments/ab/IMG.heic") == true && ms.first?.attachments.first?.isImage == true, "附件：展開 ~、判圖片")
        let t: [MsgTapback] = ms.first(where: { $0.rowID == 2 }).map { $0.tapbacks } ?? []
        check(t.count == 1 && t[0].kind == .love && t[0].fromMe, "Tapback 折疊：對方換讚→取消、只剩自己的愛心（得到 \(t.count)）")
        check(store.messages(chat: 1, limit: 1, before: 3).map(\.rowID) == [2], "分頁：before")
        check(store.newRows(after: 8, incomingOnly: true).count == 1, "新列：游標之後、只要對方的")
        let gm = store.messages(chat: 2)
        if let r20 = gm.first(where: { $0.rowID == 20 }), let r21 = gm.first(where: { $0.rowID == 21 }), let r22 = gm.first(where: { $0.rowID == 22 }) {
            check(r20.isDelivered && r20.dateRead != nil && r20.replyToGUID == "G8", "豐富欄位：已送達、已讀、回覆串")
            check(r21.isUnsent && !r21.isEdited, "豐富欄位：message_summary_info 的 rp 蓋住全部＝撤回（不是已編輯）")
            check(r22.link?.title == "Example Title" && r22.link?.site == "Example" && r22.link?.host == "example.com", "豐富欄位：payload_data 的連結預覽（得到 \(String(describing: r22.link))）")
            let items = MessagesThreadBuilder.items(Array(gm.reversed()), isGroup: true, name: { _ in "Ann" })
            check(items.contains { if case .unsent = $0.kind { return true }; return false }, "對話頁：撤回變成系統句")
            check(items.contains { if case .link(let l, _) = $0.kind { return l.title == "Example Title" }; return false }, "對話頁：連結預覽卡")
            check(items.first { $0.messageRow == 20 }?.replyQuote == "群組訊息", "對話頁：回覆串引用原文")
        } else { check(false, "豐富欄位：群組訊息讀不到（\(gm.map(\.rowID))）") }
        check(store.newRows(after: 0, incomingOnly: false).allSatisfy { $0.message.rowID != 4 }, "新列：Tapback 不算新訊息")
        check(store.maxRowID() == 22, "最大 ROWID")
        check(store.outgoing(after: 1, text: "可以！", chatGUID: "iMessage;-;+886912345678") == .found, "外送確認：找到")
        check(store.outgoing(after: 2, text: "可以！", chatGUID: nil) == .none, "外送確認：游標之前不算")
        check(store.outgoing(after: 0, text: "沒送過", chatGUID: nil) == .none, "外送確認：內文不符（幽靈列）")

        // 監看器：游標之後的對方新列才交出去；內文未填好的列先不放過
        let w = MessagesWatcher(open: { nil })
        _ = w   // 觸發器本身靠檔案事件，這裡只確認型別可建；游標邏輯由 newRows 的檢查涵蓋

        // 時間標籤
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        check(MessagesScreen.timeLabel(now.addingTimeInterval(-60), now: now, calendar: cal).contains(":"), "時間：今天顯示時分")

        // 版面命中：列表上的釘選、列、＋；對話頁的三顆按鈕
        let rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        if let lm = MessagesDemo.model("list"), let tm = MessagesDemo.model("thread") {
            let lh = MessagesScreen.layout(lm, in: rect), th = MessagesScreen.layout(tm, in: rect)
            check(lh.contains { $0.0 == .newMessage } && lh.contains { $0.0 == .pin("f") } && lh.contains { $0.0 == .row("r1") }, "版面：列表命中表")
            check(th.contains { $0.0 == .speak } && th.contains { $0.0 == .type } && th.contains { $0.0 == .emoji } && th.contains { $0.0 == .chip(2) } && th.contains { $0.0 == .back }, "版面：對話頁命中表")
            // 豐富的群組對話一頁放不下：往上捲著看，把每一頁的命中合起來
            var rh: MessagesScreen.Hits = []
            if case .thread(var rm)? = MessagesDemo.model("rich") {
                for skip in 0..<rm.items.count { rm.skipNewest = skip; rh += MessagesScreen.layout(.thread(rm), in: rect) }
            }
            let ch = MessagesDemo.model("compose").map { MessagesScreen.layout($0, in: rect) } ?? []
            check(Set(rh.compactMap { if case .item(let i) = $0.0 { return i }; return nil }).count >= 3, "版面：照片／語音／連結可以點（得到 \(rh.count) 個命中）")
            check(ch.contains { $0.0 == .sayName } && ch.contains { $0.0 == .typeName } && ch.contains { $0.0 == .suggestion(0) }, "版面：新訊息命中表")
            let all = lh + th + rh + ch
            check(all.allSatisfy { min($0.1.width, $0.1.height) >= 88 }, "版面：觸控目標 ≥ 88（最小 \(all.map { min($0.1.width, $0.1.height) }.min() ?? 0)）")
            if let r = th.first(where: { $0.0 == .emoji }) {
                check(MessagesScreen.hit(tm, in: rect, at: CGPoint(x: r.1.midX, y: r.1.midY)) == .emoji, "點擊測試：表情鈕")
                let half = MessagesScreen.layout(tm, in: CGRect(x: 100, y: 100, width: 512, height: 512)).first { $0.0 == .emoji }
                check(half.map { abs($0.1.midX - (100 + r.1.midX / 2)) < 0.5 } == true, "版面：縮放到子矩形")
            }
        } else { check(false, "示範模型建不出來") }
        bad += richChecks()
        return bad
    }

    /// 測試用：照 LPLinkMetadata 的欄位名做一份真的 NSKeyedArchiver（UID 是真的 CFKeyedArchiverUID）
    @objc(HPSelftestFakeLink) private final class FakeLink: NSObject, NSCoding {
        let title: String, url: URL, site: String
        init(title: String, url: URL, site: String) { self.title = title; self.url = url; self.site = site }
        func encode(with c: NSCoder) { c.encode(title, forKey: "title"); c.encode(url, forKey: "URL"); c.encode(url, forKey: "originalURL"); c.encode(site, forKey: "siteName") }
        required init?(coder: NSCoder) { nil }
    }
    @objc(HPSelftestFakeRich) private final class FakeRich: NSObject, NSCoding {
        let meta: FakeLink
        init(_ m: FakeLink) { meta = m }
        func encode(with c: NSCoder) { c.encode(meta, forKey: "richLinkMetadata"); c.encode(false, forKey: "richLinkIsPlaceholder") }
        required init?(coder: NSCoder) { nil }
    }
    static func linkArchive(title: String, url: String, site: String) -> Data {
        let root = FakeRich(FakeLink(title: title, url: URL(string: url)!, site: site))
        return (try? NSKeyedArchiver.archivedData(withRootObject: root, requiringSecureCoding: false)) ?? Data()
    }

    /// 2.0 imsg：純邏輯——attributedBody 變體、Tapback、撤回、大表情、時間分隔與尾巴、送達／已讀、送出備援路、專注模式、本機看過、收件人
    static func richChecks() -> [String] {
        var bad: [String] = []
        func check(_ c: Bool, _ m: String) { if !c { bad.append("messages: " + m) } }

        // attributedBody：NSMutableString、沒有類別名時的 01 2B 起始樣式、4 位元組長度
        func stream(_ cls: String?, _ text: String, len: [UInt8]? = nil) -> Data {
            let u = Array(text.utf8)
            var d: [UInt8] = [0x04, 0x0B] + Array("streamtyped".utf8) + [0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84]
            if let cls { d += [UInt8(cls.utf8.count)] + Array(cls.utf8) + [0x01, 0x94, 0x84] }
            d += [0x01, 0x2B] + (len ?? [UInt8(u.count)]) + u + [0x86, 0x84, 0x02, 0x69, 0x49, 0x01]
            return Data(d)
        }
        check(Typedstream.decode(stream("NSMutableString", "edited text")) == "edited text", "typedstream：NSMutableString")
        check(Typedstream.decode(stream(nil, "no class name")) == "no class name", "typedstream：沒有類別名退回 01 2B 樣式")
        let big = String(repeating: "x", count: 70_000)
        check(Typedstream.decode(stream("NSString", big, len: [0x82, 0x70, 0x11, 0x01, 0x00])) == big, "typedstream：0x82 四位元組長度")
        check(Typedstream.decode(stream("NSString", "hi", len: [0x82, 0xFF, 0xFF, 0xFF, 0x7F])) == nil, "typedstream：長度超出不崩、回 nil")

        // Tapback：自訂 emoji（2006）、取消（3006）、貼圖回應（2007）不顯示、bp: 前綴
        let rows: [TapbackFolder.Row] = [
            .init(rowID: 1, targetGUID: TapbackFolder.targetGUID("bp:AAA"), type: 2006, fromMe: false, handle: "x", emoji: "🔥"),
            .init(rowID: 2, targetGUID: "AAA", type: 2007, fromMe: false, handle: "y", emoji: nil),
            .init(rowID: 3, targetGUID: "AAA", type: 2003, fromMe: true, handle: "", emoji: nil),
            .init(rowID: 4, targetGUID: TapbackFolder.targetGUID("p:1/BBB"), type: 2006, fromMe: false, handle: "x", emoji: "🎉"),
            .init(rowID: 5, targetGUID: "BBB", type: 3006, fromMe: false, handle: "x", emoji: "🎉"),
        ]
        let f = TapbackFolder.fold(rows)
        check(f["AAA"]?.count == 2 && f["AAA"]?.contains { $0.kind == .emoji && $0.emoji == "🔥" } == true && f["AAA"]?.contains { $0.kind == .laugh && $0.fromMe } == true,
              "Tapback：自訂 emoji＋自己的哈哈、貼圖回應不顯示（得到 \(f["AAA"]?.count ?? 0)）")   // l10n-ignore：selftest 斷言
        check(f["BBB"] == nil, "Tapback：p:1/ 前綴、3006 取消自訂 emoji")
        check(TapbackKind.parse(2005)?.kind == .question && TapbackKind.parse(3000)?.added == false && TapbackKind.parse(1000) == nil, "Tapback：類型對照")
        check(MessagesScreen.glyph(MsgTapback(kind: .emoji, fromMe: false, handle: "", emoji: "🔥")) == "🔥" && MessagesScreen.glyph(MsgTapback(kind: .love, fromMe: true, handle: "", emoji: nil)) == "❤️",
              "Tapback：角標畫自訂 emoji 本身")   // l10n-ignore：selftest 斷言

        // message_summary_info
        func plist(_ o: Any) -> Data { (try? PropertyListSerialization.data(fromPropertyList: o, format: .binary, options: 0)) ?? Data() }
        check(MessagesSummaryInfo.isFullyUnsent(plist(["otr": ["0": ["le": 5]], "rp": [0]])), "撤回：唯一段落被收回")
        check(!MessagesSummaryInfo.isFullyUnsent(plist(["otr": ["0": ["le": 5], "1": ["le": 2]], "rp": [1]])), "撤回：只收回一段不算整則撤回")
        check(!MessagesSummaryInfo.isFullyUnsent(plist(["ec": ["0": []], "otr": ["0": ["le": 5]]])) && !MessagesSummaryInfo.isFullyUnsent(Data([1, 2, 3])), "撤回：只是編輯、壞資料都不算")
        check(MessagesLinkPreview.parse(Data([0, 1])) == nil, "連結預覽：壞資料回 nil")

        // 大表情
        check(["🫶", "👍🏽", "❤️", "👨‍👩‍👧", "😂😂😂"].allSatisfy(MessagesEmoji.isBigEmoji), "大表情：1～3 個 emoji")
        check(!["1", "OK", "#", "ok 👍", "😂😂😂😂", ""].contains(where: MessagesEmoji.isBigEmoji), "大表情：有字或太多不算")

        // 對話頁的項目：時間分隔、尾巴、群組寄件人、送達／已讀、SMS 綠泡泡、特效
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func m(_ r: Int64, _ t: String, me: Bool, _ ago: TimeInterval, from: String = "a", svc: String = "iMessage") -> MsgMessage {
            MsgMessage(rowID: r, guid: "G\(r)", chatRowID: 1, text: t, date: now.addingTimeInterval(-ago), isFromMe: me, senderHandle: me ? "" : from,
                       service: svc, isEdited: false, attachments: [], tapbacks: [])
        }
        var a3 = m(3, "c", me: true, 7000); a3.isDelivered = true
        var a4 = m(4, "d", me: false, 100, from: "b"); a4.effect = "com.apple.messages.effect.CKHeartEffect"
        var a5 = m(5, "e", me: true, 50); a5.isDelivered = true; a5.dateRead = now.addingTimeInterval(-40)
        let items = MessagesThreadBuilder.items([m(1, "a", me: false, 7200), m(2, "b", me: false, 7190), a3, a4, a5], isGroup: true, name: { $0 == "a" ? "Ann" : "Bo" }, now: now, calendar: cal)
        let seps = items.filter { if case .separator = $0.kind { return true }; return false }
        check(seps.count == 2, "對話頁：隔一小時以上插時間分隔（得到 \(seps.count)）")
        let r1 = items.first { $0.messageRow == 1 }, r2 = items.first { $0.messageRow == 2 }
        check(r1?.tail == false && r2?.tail == true && r1?.sender == "Ann" && r2?.sender == nil && r2?.senderInitials == "A", "對話頁：同一串只有最後一則有尾巴與頭像、第一則有名字")
        check(items.first { $0.messageRow == 3 }?.status == nil && items.first { $0.messageRow == 5 }?.status?.isEmpty == false, "對話頁：狀態只在自己最後一則")
        check(items.first { $0.messageRow == 4 }?.effect == true, "對話頁：特效有「重播」")
        check(MessagesThreadBuilder.status(a3) == L("msg.status.delivered", "已送达") && MessagesThreadBuilder.status(a5, now: now, calendar: cal)?.hasPrefix(String(L("msg.status.read", "已读 %@").prefix(2))) == true,
              "對話頁：已送達／已讀")   // l10n-ignore：selftest 斷言
        check(MessagesThreadBuilder.status(m(9, "x", me: true, 1, svc: "SMS")) == nil, "對話頁：SMS 沒有已讀狀態")
        check(MessagesThreadBuilder.items([m(6, "s", me: true, 1, svc: "SMS")], isGroup: false, name: { _ in nil }, now: now).last?.sms == true, "對話頁：SMS 是綠泡泡")
        check(MessagesThreadBuilder.items([m(7, "🫶", me: true, 1)], isGroup: false, name: { _ in nil }, now: now).contains { if case .bigEmoji = $0.kind { return true }; return false }, "對話頁：只有 emoji＝大表情")

        // 送出：chat id 出錯時一對一退 participant＋具體服務；群組、未知服務不退
        check(MessagesSender.fallback(for: .chat(guid: "any;-;+886912345678"), service: "SMS") == .participant("+886912345678", service: "SMS"), "送出：any;-; 退 participant（SMS）")
        check(MessagesSender.fallback(for: .chat(guid: "any;+;chat123"), service: "iMessage") == nil && MessagesSender.fallback(for: .chat(guid: "any;-;+1"), service: "any") == nil,
              "送出：群組、服務不明不退")   // l10n-ignore：selftest 斷言
        check(MessagesSender.script(text: "hi", to: .participant("+1", service: "SMS")).contains("service type = SMS")
              && MessagesSender.script(text: "hi", to: .participant("+1", service: "bogus\" & do shell script")).contains("service type = iMessage"), "送出：服務只准三個常數")   // l10n-ignore：selftest 斷言
        // 送出前一定要確認：新訊息的收件人、確認卡上的字
        let rc = MessagesRecipient(name: "Ann", detail: "", chatGUID: nil, handle: "a@b.com")
        check(rc.target == .handle("a@b.com") && MessagesRecipient(name: "G", detail: "", chatGUID: "any;+;c", handle: "x").target == .chat(guid: "any;+;c"), "新訊息：既有對話用 chat id，其他用 participant")
        var flow = MessagesReplyFlow()
        check(!flow.propose("") && flow.answer(true) == nil, "確認：沒有內容不出卡、不送")
        flow.propose("👍")
        check(flow.state == .confirming("👍") && flow.answer(true) == "👍", "確認：表情也要先確認")
        var got: MessagesSendResult?
        MessagesSender.send(text: "hi", to: .handle("+10000000000"), confirmed: false, fallbackService: "SMS") { got = $0 }
        check(got == .notConfirmed, "確認：備援路也一樣沒 confirmed 不送")

        // 收件人建議：沒字＝最近的對話；有字＝對話＋通訊錄（已在對話裡的號碼不重複）
        let convs = [MsgConversation(rowID: 1, guid: "g1", chatIdentifier: "+886912345678", title: "Ann", participants: ["+886912345678"], isGroup: false,
                                     lastText: "", lastDate: now, lastIsFromMe: false, lastHasAttachments: false, unread: 0)]
        let people = [MessagesContacts.Person(name: "Ann", handles: ["0912 345 678", "ann@x.com"], photo: nil)]
        let sg = MessagesApp.suggest("ann", convs: convs, contacts: people)
        check(sg.count == 2 && sg[0].chatGUID == "g1" && sg[1].handle == "ann@x.com", "新訊息：對話優先、通訊錄去重（得到 \(sg.count)）")
        check(MessagesApp.suggest("", convs: convs, contacts: people).count == 1, "新訊息：沒打字只列最近的對話")

        // 專注模式
        check(MessagesFocus.isActive(json: Data(#"{"data":[{"storeAssertionRecords":[{"assertionUUID":"x"}]}]}"#.utf8)), "專注：有 assertion＝開著")
        check(!MessagesFocus.isActive(json: Data(#"{"data":[{"storeInvalidationRecords":[{}]}]}"#.utf8)) && !MessagesFocus.isActive(json: Data("nope".utf8)), "專注：沒有或讀不懂＝沒開")

        // 本機看過
        let suite = "messages.selftest.\(UUID().uuidString)"
        if let d = UserDefaults(suiteName: suite) {
            var c = convs[0]; c.unread = 2; c.lastRowID = 50
            check(MessagesSeen.isUnread(c, seen: MessagesSeen.load(d)), "看過：還沒看＝未讀")
            MessagesSeen.mark("g1", upTo: 50, d)
            check(!MessagesSeen.isUnread(c, seen: MessagesSeen.load(d)), "看過：看過就不畫未讀點")
            c.lastRowID = 51
            check(MessagesSeen.isUnread(c, seen: MessagesSeen.load(d)), "看過：又來新的＝未讀")
            d.removePersistentDomain(forName: suite)
        }
        // 每一種狀態：未送達、載入中、空的、陌生人頭像、遠端訪客、VoiceOver 的字
        var bad1 = m(30, "late", me: true, 1); bad1.failed = true
        let fi = MessagesThreadBuilder.items([bad1], isGroup: false, name: { _ in nil }, now: now)
        check(fi.last?.failed == true && MessagesScreen.axValue(fi.last!, MessagesThreadModel(title: "Bo", items: fi, chips: [])).contains(L("msg.status.failed", "未送达")), "狀態：未送達標紅、VoiceOver 唸得到")
        let rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let loadingList = MessagesScreen.layout(.list(MessagesListModel(pins: [], rows: [], loading: true)), in: rect)
        check(!loadingList.contains { if case .row = $0.0 { return true }; return false } && loadingList.contains { $0.0 == .newMessage }, "狀態：載入中只有「新訊息」鈕")
        let emptyThread = MessagesScreen.layout(.thread(MessagesThreadModel(title: "Bo", items: [], chips: ["a"], loading: true)), in: rect)
        check(emptyThread.contains { $0.0 == .speak } && emptyThread.contains { $0.0 == .back }, "狀態：空對話／載入中照樣能回覆、能返回")
        check(MessagesThreadBuilder.initials("+886 912 345 678").contains(where: \.isLetter) == false && MessagesThreadBuilder.initials("[Ann Lee]") == "AL", "頭像：沒有名字＝人形、方括號去掉")
        check(!PersonalGate.allowed(PersonalGate.Inputs(remoteGuest: true)) && !PersonalGate.allowed(PersonalGate.Inputs(guestMode: true)), "隱私：訪客與遠端訪客看不到訊息")
        check(MessagesActivityText.text(name: "Bo", preview: "x", allowed: false).detail == L("msg.activity.new", "新信息"), "隱私：橫幅不給預覽")
        let longText = String(repeating: "Supercalifragilistic expialidocious ", count: 40)
        let lt = MessagesScreen.layout(.thread(MessagesThreadModel(title: "Bo", items: MessagesThreadBuilder.items([m(31, longText, me: false, 1)], isGroup: false, name: { _ in nil }, now: now), chips: [])), in: rect)
        check(lt.contains { $0.0 == .item(1) }, "長訊息：截到 8 行還是畫得出來、點得到")
        // 附件路徑：只准 ~/Library/Messages 底下
        check(MessagesMedia.allowed(NSHomeDirectory() + "/Library/Messages/Attachments/a/b.heic") && !MessagesMedia.allowed("/etc/passwd")
              && !MessagesMedia.allowed(NSHomeDirectory() + "/Library/Messages/../Keychains/x"), "附件：只讀訊息自己的資料夾")   // l10n-ignore：selftest 斷言
        return bad
    }
}
