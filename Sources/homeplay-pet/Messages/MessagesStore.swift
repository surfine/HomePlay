// 唯讀的 chat.db：對話列表、對話內訊息（新到舊分頁）、附件、Tapback 折疊。
// 用系統的 libsqlite3（import SQLite3），以 file:...?mode=ro 開啟，不用 immutable=1（會漏掉 WAL 裡的新資料）。
// 同一個 MessagesStore 不是執行緒安全的：每條執行緒／佇列各開自己的一個。
// 隱私：不記錄任何內文或 handle；日誌只許出現筆數。

import Foundation
import SQLite3

enum MessagesAccess: Equatable {
    case available
    case needsFullDiskAccess   // 開檔被系統擋下（EPERM／EACCES）
    case noDatabase            // 沒有 chat.db（沒登入過訊息）
    case failed(Int32)

    static var defaultPath: String { NSHomeDirectory() + "/Library/Messages/chat.db" }

    /// 不開資料庫，只用 open(2) 判斷權限，所以不會有任何資料落地
    static func check(path: String = defaultPath) -> MessagesAccess {
        let fd = open(path, O_RDONLY)
        if fd >= 0 { close(fd); return .available }
        switch errno {
        case EPERM, EACCES: return .needsFullDiskAccess
        case ENOENT: return .noDatabase
        default: return .failed(errno)
        }
    }

    /// 系統設定 › 隱私權與安全性 › 完整磁碟取用權限
    static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}

final class MessagesStore {
    private var db: OpaquePointer?
    private let hasFiltered: Bool
    private let hasEmoji: Bool
    private let hasEdited: Bool
    /// 2.0 imsg：豐富顯示用的欄位（啟動時探測；沒有就降級成預設值）
    private let msgCols: Set<String>, chatCols: Set<String>, attCols: Set<String>
    /// handle → 顯示名字（通訊錄）；nil＝沒有對應，顯示原 handle
    var nameResolver: ((String) -> String?)?

    // MARK: 開啟

    /// 預設的 chat.db；開不了就回 nil，原因用 MessagesAccess.check() 另外問
    static func openDefault() -> MessagesStore? { MessagesStore(path: MessagesAccess.defaultPath) }

    convenience init?(path: String) {
        var enc = ""
        for u in path.utf8 {
            let c = Character(UnicodeScalar(u))
            if c.isASCII, c.isLetter || c.isNumber || "/-._~".contains(c) { enc.append(c) } else { enc += String(format: "%%%02X", u) }
        }
        var h: OpaquePointer?
        let rc = sqlite3_open_v2("file:\(enc)?mode=ro", &h, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let h else { if let h { sqlite3_close(h) }; return nil }
        self.init(connection: h)
        // 檔案存在但被 TCC 擋：open 可能成功、第一次查詢才失敗
        guard (try? scalarInt("SELECT COUNT(*) FROM sqlite_master")) != nil else { return nil }
    }

    /// 測試用：直接給連線（例如 ":memory:"）。這個 store 之後擁有並負責關閉它。
    init(connection: OpaquePointer) {
        db = connection
        sqlite3_busy_timeout(connection, 1500)
        func cols(_ t: String) -> Set<String> {
            var s: OpaquePointer?; var out = Set<String>()
            if sqlite3_prepare_v2(connection, "SELECT name FROM pragma_table_info('\(t)')", -1, &s, nil) == SQLITE_OK {
                while sqlite3_step(s) == SQLITE_ROW { if let c = sqlite3_column_text(s, 0) { out.insert(String(cString: c)) } }
            }
            sqlite3_finalize(s); return out
        }
        // 啟動時探測欄位：Apple 改 schema 時降級而不是崩
        let chat = cols("chat"), msg = cols("message")
        hasFiltered = chat.contains("is_filtered")
        hasEmoji = msg.contains("associated_message_emoji")
        hasEdited = msg.contains("date_edited")
        msgCols = msg; chatCols = chat; attCols = cols("attachment")
    }

    deinit { if let db { sqlite3_close(db) } }

    // MARK: 低階

    struct SQLError: Error { var code: Int32 }

    private func query(_ sql: String, _ binds: [Any] = [], row: (OpaquePointer) -> Void) throws {
        var st: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &st, nil)
        guard rc == SQLITE_OK, let st else { sqlite3_finalize(st); throw SQLError(code: rc) }
        defer { sqlite3_finalize(st) }
        for (i, b) in binds.enumerated() {
            let n = Int32(i + 1)
            switch b {
            case let v as Int64: sqlite3_bind_int64(st, n, v)
            case let v as Int: sqlite3_bind_int64(st, n, Int64(v))
            case let v as String: sqlite3_bind_text(st, n, v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            default: sqlite3_bind_null(st, n)
            }
        }
        while true {
            let r = sqlite3_step(st)
            if r == SQLITE_ROW { row(st) } else if r == SQLITE_DONE { return } else { throw SQLError(code: r) }
        }
    }

    func scalarInt(_ sql: String, _ binds: [Any] = []) throws -> Int64 {
        var v: Int64 = 0
        try query(sql, binds) { v = sqlite3_column_int64($0, 0) }
        return v
    }

    private static func str(_ st: OpaquePointer, _ i: Int32) -> String {
        sqlite3_column_text(st, i).map { String(cString: $0) } ?? ""
    }
    private static func blob(_ st: OpaquePointer, _ i: Int32) -> Data? {
        guard let p = sqlite3_column_blob(st, i) else { return nil }
        let n = Int(sqlite3_column_bytes(st, i)); return n > 0 ? Data(bytes: p, count: n) : nil
    }
    /// text 欄優先；空的才解 attributedBody
    private static func body(_ st: OpaquePointer, text i: Int32, attributed j: Int32) -> String {
        let t = Typedstream.clean(str(st, i))
        if !t.isEmpty { return t }
        if let b = blob(st, j), let s = Typedstream.decode(b) { return s }
        return ""
    }

    // MARK: 對話列表

    /// 依最後一則訊息新到舊；預設不含 is_filtered（未知寄件人過濾）的對話
    func conversations(limit: Int = 50) -> [MsgConversation] {
        let filter = hasFiltered ? "AND IFNULL(c.is_filtered,0) = 0" : ""
        let sql = """
        SELECT c.ROWID, c.guid, IFNULL(c.chat_identifier,''), IFNULL(c.display_name,''), IFNULL(c.style,45),
               m.ROWID, m.text, m.attributedBody, m.date, m.is_from_me, IFNULL(m.cache_has_attachments,0),
               (SELECT COUNT(*) FROM chat_message_join j2 JOIN message m2 ON m2.ROWID = j2.message_id
                 WHERE j2.chat_id = c.ROWID AND m2.is_read = 0 AND m2.is_from_me = 0 AND IFNULL(m2.item_type,0) = 0
                   AND IFNULL(m2.associated_message_type,0) NOT BETWEEN 2000 AND 3999),
               \(chatCols.contains("service_name") ? "IFNULL(c.service_name,'')" : "''")
        FROM chat c
        JOIN message m ON m.ROWID = (
              SELECT mm.ROWID FROM chat_message_join j JOIN message mm ON mm.ROWID = j.message_id
               WHERE j.chat_id = c.ROWID AND IFNULL(mm.item_type,0) = 0
                 AND IFNULL(mm.associated_message_type,0) NOT BETWEEN 2000 AND 3999
               ORDER BY mm.date DESC LIMIT 1)
        WHERE 1=1 \(filter)
        ORDER BY m.date DESC LIMIT ?
        """
        var out: [MsgConversation] = []
        try? query(sql, [limit]) { st in
            let chatID = sqlite3_column_int64(st, 0)
            var c = MsgConversation(
                rowID: chatID, guid: Self.str(st, 1), chatIdentifier: Self.str(st, 2), title: Self.str(st, 3), participants: [],
                isGroup: sqlite3_column_int(st, 4) == 43 || Self.str(st, 1).contains(";+;"),
                lastText: Self.body(st, text: 6, attributed: 7), lastDate: MessagesDate.date(fromRaw: sqlite3_column_int64(st, 8)),
                lastIsFromMe: sqlite3_column_int(st, 9) != 0, lastHasAttachments: sqlite3_column_int(st, 10) != 0,
                unread: Int(sqlite3_column_int(st, 11)))
            c.participants = []
            c.lastRowID = sqlite3_column_int64(st, 5); c.service = Self.str(st, 12)
            out.append(c)
        }
        // 參與者與標題（另一輪查詢，避免在迴圈裡重入 statement）
        for i in out.indices {
            out[i].participants = participants(of: out[i].rowID)
            if out[i].title.isEmpty { out[i].title = fallbackTitle(out[i]) }
        }
        return out
    }

    func participants(of chatRowID: Int64) -> [String] {
        var ids: [String] = []
        try? query("SELECT h.id FROM chat_handle_join ch JOIN handle h ON h.ROWID = ch.handle_id WHERE ch.chat_id = ? ORDER BY h.ROWID", [chatRowID]) {
            ids.append(Self.str($0, 0))
        }
        return ids
    }

    private func fallbackTitle(_ c: MsgConversation) -> String {
        let people = c.participants.isEmpty ? [c.chatIdentifier] : c.participants
        let names = people.map { nameResolver?($0) ?? $0 }
        return names.joined(separator: c.isGroup ? "、" : "")
    }

    // MARK: 訊息

    /// 一個對話裡的訊息，新到舊；before＝只取 ROWID 小於它的（分頁）。Tapback 已折疊到被回應的訊息上，本身不出現在列表。
    func messages(chat chatRowID: Int64, limit: Int = 30, before: Int64? = nil) -> [MsgMessage] {
        let editedCol = hasEdited ? "IFNULL(m.date_edited,0)" : "0"
        func col(_ name: String, _ fallback: String = "NULL") -> String { msgCols.contains(name) ? "m.\(name)" : fallback }
        let sql = """
        SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.date, m.is_from_me, IFNULL(h.id,''), IFNULL(m.service,''), \(editedCol),
               \(col("message_summary_info")), IFNULL(\(col("is_delivered", "0")),0), IFNULL(\(col("date_read", "0")),0),
               \(col("thread_originator_guid")), IFNULL(\(col("balloon_bundle_id")),''), \(col("payload_data")),
               \(col("expressive_send_style_id")), IFNULL(\(col("is_audio_message", "0")),0), IFNULL(\(col("error", "0")),0)
        FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE j.chat_id = ? AND IFNULL(m.item_type,0) = 0 AND IFNULL(m.associated_message_type,0) NOT BETWEEN 2000 AND 4000
          AND m.ROWID < ?
        ORDER BY m.ROWID DESC LIMIT ?
        """
        var out: [MsgMessage] = []
        try? query(sql, [chatRowID, before ?? Int64.max, limit]) { st in
            var m = MsgMessage(
                rowID: sqlite3_column_int64(st, 0), guid: Self.str(st, 1), chatRowID: chatRowID,
                text: Self.body(st, text: 2, attributed: 3), date: MessagesDate.date(fromRaw: sqlite3_column_int64(st, 4)),
                isFromMe: sqlite3_column_int(st, 5) != 0, senderHandle: Self.str(st, 6), service: Self.str(st, 7),
                isEdited: sqlite3_column_int64(st, 8) != 0, attachments: [], tapbacks: [])
            // 2.0 imsg：收回、送達／已讀、回覆串、連結預覽、特效、語音訊息
            m.isUnsent = m.text.isEmpty && MessagesSummaryInfo.isFullyUnsent(Self.blob(st, 9))
            if m.isUnsent { m.isEdited = false }
            m.isDelivered = sqlite3_column_int(st, 10) != 0
            let read = sqlite3_column_int64(st, 11)
            m.dateRead = m.isFromMe && read > 0 ? MessagesDate.date(fromRaw: read) : nil
            let reply = Self.str(st, 12); m.replyToGUID = reply.isEmpty ? nil : reply
            if Self.str(st, 13) == MessagesLinkPreview.balloonID { m.link = MessagesLinkPreview.parse(Self.blob(st, 14)) ?? (m.text.isEmpty ? nil : MsgLink(url: m.text, title: "", site: "", imageIndex: nil)) }
            let fx = Self.str(st, 15); m.effect = fx.isEmpty ? nil : fx
            m.isAudioMessage = sqlite3_column_int(st, 16) != 0
            m.failed = m.isFromMe && sqlite3_column_int(st, 17) != 0
            out.append(m)
        }
        guard let oldest = out.last?.rowID else { return out }
        let taps = tapbacks(chat: chatRowID, sinceRowID: oldest)
        for i in out.indices {
            out[i].attachments = attachments(ofMessage: out[i].rowID)
            out[i].tapbacks = taps[out[i].guid] ?? []
        }
        return out
    }

    func attachments(ofMessage rowID: Int64) -> [MsgAttachment] {
        var out: [MsgAttachment] = []
        try? query("""
            SELECT a.ROWID, IFNULL(a.filename,''), IFNULL(a.mime_type,''), IFNULL(a.transfer_name,''), IFNULL(a.uti,''),
                   IFNULL(a.is_sticker,0), IFNULL(a.total_bytes,0), \(attCols.contains("is_commsafety_sensitive") ? "IFNULL(a.is_commsafety_sensitive,0)" : "0")
            FROM message_attachment_join maj JOIN attachment a ON a.ROWID = maj.attachment_id
            WHERE maj.message_id = ? ORDER BY a.ROWID
            """, [rowID]) { st in
            var path = Self.str(st, 1)
            if path.hasPrefix("~") { path = NSHomeDirectory() + path.dropFirst() }
            out.append(MsgAttachment(rowID: sqlite3_column_int64(st, 0), path: path, mimeType: Self.str(st, 2), name: Self.str(st, 3),
                                     uti: Self.str(st, 4), isSticker: sqlite3_column_int(st, 5) != 0, bytes: sqlite3_column_int64(st, 6),
                                     sensitive: sqlite3_column_int(st, 7) != 0))
        }
        return out
    }

    /// 這個對話裡 ROWID >= since 的 Tapback 列，折疊成「被回應訊息 guid → 反應清單」（反應一定出現在被回應訊息之後）
    func tapbacks(chat chatRowID: Int64, sinceRowID since: Int64) -> [String: [MsgTapback]] {
        let emojiCol = hasEmoji ? "IFNULL(m.associated_message_emoji,'')" : "''"
        let sql = """
        SELECT m.ROWID, IFNULL(m.associated_message_guid,''), m.associated_message_type, m.is_from_me, IFNULL(h.id,''), \(emojiCol)
        FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE j.chat_id = ? AND m.ROWID >= ? AND m.associated_message_type BETWEEN 2000 AND 3007
        ORDER BY m.ROWID
        """
        var rows: [TapbackFolder.Row] = []
        try? query(sql, [chatRowID, since]) { st in
            let e = Self.str(st, 5)
            rows.append(.init(rowID: sqlite3_column_int64(st, 0), targetGUID: TapbackFolder.targetGUID(Self.str(st, 1)),
                              type: Int(sqlite3_column_int(st, 2)), fromMe: sqlite3_column_int(st, 3) != 0, handle: Self.str(st, 4),
                              emoji: e.isEmpty ? nil : e))
        }
        return TapbackFolder.fold(rows)
    }

    // MARK: 游標

    func maxRowID() -> Int64 { (try? scalarInt("SELECT IFNULL(MAX(ROWID),0) FROM message")) ?? 0 }

    /// ROWID > cursor 的新訊息（升冪）。incoming＝對方傳來的；Tapback 與系統事件不算。chat 欄給 watcher 用來帶出對話
    func newRows(after cursor: Int64, incomingOnly: Bool) -> [(message: MsgMessage, chatTitle: String, isGroup: Bool)] {
        let sql = """
        SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.date, m.is_from_me, IFNULL(h.id,''), IFNULL(m.service,''),
               IFNULL(j.chat_id,0), IFNULL(c.display_name,''), IFNULL(c.style,45), IFNULL(c.guid,''), IFNULL(m.cache_has_attachments,0)
        FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id
        LEFT JOIN chat_message_join j ON j.message_id = m.ROWID LEFT JOIN chat c ON c.ROWID = j.chat_id
        WHERE m.ROWID > ? AND IFNULL(m.item_type,0) = 0 AND IFNULL(m.associated_message_type,0) NOT BETWEEN 2000 AND 3999
          \(incomingOnly ? "AND m.is_from_me = 0" : "")
        ORDER BY m.ROWID LIMIT 200
        """
        var out: [(MsgMessage, String, Bool)] = []
        try? query(sql, [cursor]) { st in
            let hasAtt = sqlite3_column_int(st, 12) != 0
            let m = MsgMessage(
                rowID: sqlite3_column_int64(st, 0), guid: Self.str(st, 1), chatRowID: sqlite3_column_int64(st, 8),
                text: Self.body(st, text: 2, attributed: 3), date: MessagesDate.date(fromRaw: sqlite3_column_int64(st, 4)),
                isFromMe: sqlite3_column_int(st, 5) != 0, senderHandle: Self.str(st, 6), service: Self.str(st, 7),
                isEdited: false,
                attachments: hasAtt ? [MsgAttachment(rowID: 0, path: "", mimeType: "", name: "", uti: "", isSticker: false, bytes: 0)] : [],
                tapbacks: [])
            let group = sqlite3_column_int(st, 10) == 43 || Self.str(st, 11).contains(";+;")
            var title = Self.str(st, 9)
            if title.isEmpty { title = m.senderHandle }
            out.append((m, title, group))
        }
        return out.map { (message: $0.0, chatTitle: $0.1, isGroup: $0.2) }
    }

    /// 送出後確認用：ROWID > baseline、is_from_me=1、內文相同（可限定對話 guid）。error != 0 回 .failed
    enum OutgoingState { case none, found, failed }
    func outgoing(after baseline: Int64, text: String, chatGUID: String?) -> OutgoingState {
        let want = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var state = OutgoingState.none
        let sql = """
        SELECT m.text, m.attributedBody, IFNULL(m.error,0)
        FROM message m \(chatGUID == nil ? "" : "JOIN chat_message_join j ON j.message_id = m.ROWID JOIN chat c ON c.ROWID = j.chat_id AND c.guid = ?")
        WHERE m.ROWID > ? AND m.is_from_me = 1 AND IFNULL(m.associated_message_type,0) NOT BETWEEN 2000 AND 3999
        ORDER BY m.ROWID
        """
        var binds: [Any] = []
        if let g = chatGUID { binds.append(g) }
        binds.append(baseline)
        try? query(sql, binds) { st in
            guard Self.body(st, text: 0, attributed: 1) == want else { return }
            state = sqlite3_column_int(st, 2) != 0 ? .failed : .found
        }
        return state
    }
}
