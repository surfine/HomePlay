// 訊息（Messages）資料層的純值型別與純函式：日期換算、Tapback 對照、號碼／信箱正規化、typedstream 掃描。
// 全部不碰 IO，selftest 直接測（MessagesSelftest.swift）。
// 隱私：這個資料夾裡的任何程式都不得把訊息內文或 handle 寫進日誌；日誌只能出現筆數。

import Foundation

// MARK: - 模型

enum TapbackKind: Int, CaseIterable {
    case love = 0, like, dislike, laugh, emphasis, question, emoji

    /// associated_message_type：2000…2007 加上、3000…3007 取消。nil＝不是 Tapback
    static func parse(_ type: Int) -> (kind: TapbackKind, added: Bool)? {
        switch type {
        case 2000...2006: return (TapbackKind(rawValue: type - 2000)!, true)
        case 3000...3006: return (TapbackKind(rawValue: type - 3000)!, false)
        case 2007, 3007: return nil   // 貼圖回應：先不顯示
        default: return nil
        }
    }
    static func isTapbackRow(_ type: Int) -> Bool { (2000...2007).contains(type) || (3000...3007).contains(type) }
}

struct MsgTapback: Equatable {
    var kind: TapbackKind
    var fromMe: Bool
    var handle: String      // 對方的 handle id；自己送的為 ""
    var emoji: String?      // kind == .emoji 時
}

struct MsgAttachment: Equatable {
    var rowID: Int64
    var path: String        // 已展開 ~；檔案可能已被清除（空字串）
    var mimeType: String
    var name: String
    var uti: String
    var isSticker: Bool
    var bytes: Int64
    var isImage: Bool { mimeType.hasPrefix("image/") || uti.contains("image") || ["public.heic", "public.png", "public.jpeg", "com.compuserve.gif", "org.webmproject.webp"].contains(uti) }
    // 2.0 imsg
    var isVideo: Bool { mimeType.hasPrefix("video/") || uti.contains("movie") || uti == "public.mpeg-4" }
    var isAudio: Bool { mimeType.hasPrefix("audio/") || uti.contains("audio") || uti == "com.apple.coreaudio-format" }
    var sensitive = false              // is_commsafety_sensitive：照系統的敏感內容警告先模糊
}

struct MsgMessage {
    var rowID: Int64
    var guid: String
    var chatRowID: Int64
    var text: String
    var date: Date
    var isFromMe: Bool
    var senderHandle: String
    var service: String
    var isEdited: Bool
    var attachments: [MsgAttachment]
    var tapbacks: [MsgTapback]
    // 2.0 imsg：手錶／HomeView 對等的顯示資訊（舊資料庫沒有的欄位就是預設值）
    var isUnsent = false              // message_summary_info 的 rp 蓋住全部段落（imessage-exporter 的判斷）
    var isDelivered = false
    var dateRead: Date?               // 自己送的：對方已讀的時間（有開已讀回條才有）
    var replyToGUID: String?          // thread_originator_guid：回覆串的原訊息
    var link: MsgLink?                // URL 預覽（payload_data 的 LPLinkMetadata）
    var effect: String?               // expressive_send_style_id
    var isAudioMessage = false
    var failed = false                // message.error ≠ 0：自己送的沒送出去（iPhone 的「未送達」）
}

/// 連結預覽：LPLinkMetadata 的標題與網站名；imageIndex＝預覽圖是這則訊息的第幾個附件
struct MsgLink: Equatable {
    var url: String
    var title: String
    var site: String
    var imageIndex: Int?
    var host: String { URL(string: url)?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? url }
}

struct MsgConversation {
    var rowID: Int64
    var guid: String
    var chatIdentifier: String
    var title: String
    var participants: [String]
    var isGroup: Bool
    var lastText: String
    var lastDate: Date
    var lastIsFromMe: Bool
    var lastHasAttachments: Bool
    var unread: Int
    var lastRowID: Int64 = 0          // 2.0 imsg：本機「看過」的游標（MessagesSeen）用
    var service = ""                  // chat.service_name：iMessage／SMS／RCS（送出的備援路要具體服務）
}

// MARK: - 日期

enum MessagesDate {
    /// chat.db 的 date：新版是自 2001-01-01 起算的奈秒，舊版是秒；>= 1e12 視為奈秒（imessage-database 的同一判斷）
    static func date(fromRaw raw: Int64) -> Date {
        if raw == 0 { return Date(timeIntervalSinceReferenceDate: 0) }
        let seconds = raw >= 1_000_000_000_000 ? Double(raw) / 1e9 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }
    static func raw(from d: Date) -> Int64 { Int64(d.timeIntervalSinceReferenceDate * 1e9) }
}

// MARK: - handle 正規化（對照通訊錄用）

enum HandleKey {
    /// 信箱：小寫去空白；電話：只留數字，取末 9 碼（吃掉 +886／0／+1 之類的國碼與長途前綴差異）。
    /// 例：「+886 912-345-678」與「0912 345 678」同一把鑰匙。
    static func make(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains("@") { return "e:" + s.lowercased() }
        let digits = s.filter { $0.isASCII && $0.isNumber }
        if digits.isEmpty { return "x:" + s.lowercased() }
        return "p:" + (digits.count > 9 ? String(digits.suffix(9)) : digits)
    }
    /// 沒有通訊錄名字時顯示用：電話原樣、信箱原樣
    static func display(_ raw: String) -> String { raw }
    /// 頭像／圓圈上的一個字：取名字第一個字元（中文取第一字、英文大寫）
    static func initial(of name: String) -> String {
        let t = name.trimmingCharacters(in: CharacterSet(charactersIn: "[] \n\t"))
        guard let c = t.first else { return "?" }
        return String(c).uppercased()
    }
}

// MARK: - typedstream（attributedBody）

enum Typedstream {
    /// message.attributedBody 是 NSArchiver 的 typedstream（"\x04\x0bstreamtyped"），內文是 NSString 之後的
    /// 「長度前綴 UTF-8」：類別名 "NSString" 後面跟 01 94 84 01 2B（'+' ＝ C 字串編碼），然後是長度：
    /// 單位元組 < 0x80；0x81 → 後 2 位元組小端；0x82 → 後 4 位元組小端。純位元組掃描，不會丟例外。
    static func scanString(_ blob: Data) -> String? {
        let b = [UInt8](blob)
        guard b.count > 20 else { return nil }
        // 第一個 NSString（或 NSMutableString）就是 NSAttributedString 的字串本體（屬性字典裡的 NSString 在它後面）
        var found: Int?
        for name in ["NSString", "NSMutableString"] {
            let marker = Array(name.utf8)
            var i = 0
            while i + marker.count < b.count {
                if b[i] == marker[0], Array(b[i..<(i + marker.count)]) == marker { found = min(found ?? .max, i + marker.count); break }
                i += 1
            }
        }
        // 2.0 imsg：找不到類別名時退回 imessage-exporter 的起始樣式 01 2B（SOH '+'）
        if found == nil {
            var i = 0
            while i + 1 < b.count { if b[i] == 0x01, b[i + 1] == 0x2B { found = i; break }; i += 1 }
        }
        guard var p = found else { return nil }
        // 跳到 '+'（0x2B）：類別資訊後面最多幾個位元組
        let limit = min(b.count, p + 12)
        var plus: Int?
        while p < limit { if b[p] == 0x2B { plus = p; break }; p += 1 }
        guard let pl = plus, pl + 1 < b.count else { return nil }
        var q = pl + 1
        var len = 0
        switch b[q] {
        case 0x81:
            guard q + 2 < b.count else { return nil }
            len = Int(b[q + 1]) | Int(b[q + 2]) << 8; q += 3
        case 0x82:
            guard q + 4 < b.count else { return nil }
            len = Int(b[q + 1]) | Int(b[q + 2]) << 8 | Int(b[q + 3]) << 16 | Int(b[q + 4]) << 24; q += 5
        case 0x80...0xFF:
            return nil
        default:
            len = Int(b[q]); q += 1
        }
        guard len >= 0, q + len <= b.count else { return nil }
        return String(data: Data(b[q..<(q + len)]), encoding: .utf8)
    }

    /// 內文：只走位元組掃描（壞資料不會丟例外；不退回 NSUnarchiver——它在壞資料上丟 NSException，Swift 接不住會整個崩掉）。
    static func decode(_ blob: Data) -> String? {
        scanString(blob).map(clean)
    }

    /// 附件在內文裡是 U+FFFC；去掉，再裁掉空白
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Tapback 折疊

enum TapbackFolder {
    struct Row {
        var rowID: Int64
        var targetGUID: String   // 已去掉 p:N/ 或 bp: 前綴
        var type: Int
        var fromMe: Bool
        var handle: String
        var emoji: String?
    }

    /// associated_message_guid 形如 "p:0/GUID" 或 "bp:GUID" → GUID
    static func targetGUID(_ assoc: String) -> String {
        if assoc.hasPrefix("bp:") { return String(assoc.dropFirst(3)) }
        if assoc.hasPrefix("p:"), let slash = assoc.firstIndex(of: "/") { return String(assoc[assoc.index(after: slash)...]) }
        return assoc
    }

    /// 依 ROWID 順序：2xxx 加上（同一人同一種先蓋掉舊的）、3xxx 取消。每個人對一則訊息只留最新一個 Tapback。
    static func fold(_ rows: [Row]) -> [String: [MsgTapback]] {
        var out: [String: [MsgTapback]] = [:]
        for r in rows.sorted(by: { $0.rowID < $1.rowID }) {
            guard let (kind, added) = TapbackKind.parse(r.type) else { continue }
            let who = r.fromMe ? "" : r.handle
            var list = out[r.targetGUID] ?? []
            if added {
                list.removeAll { $0.fromMe == r.fromMe && $0.handle == who }   // 換一種反應＝取代
                list.append(MsgTapback(kind: kind, fromMe: r.fromMe, handle: who, emoji: r.emoji))
            } else {
                list.removeAll { $0.fromMe == r.fromMe && $0.handle == who && $0.kind == kind }
            }
            out[r.targetGUID] = list
        }
        return out.filter { !$0.value.isEmpty }
    }
}
