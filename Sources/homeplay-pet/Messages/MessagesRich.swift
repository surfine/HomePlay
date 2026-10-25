// 2.0 imsg：讓對話頁跟手錶／iPhone 的「訊息」一樣豐富的純邏輯——連結預覽、收回、大表情、特效、
// 時間分隔、泡泡尾巴、群組寄件人、已送達／已讀、回覆串的引用。全部不碰 IO，selftest 直接測（MessagesSelftest）。
// 做法參考 imessage-exporter（GPL-3.0，ReagentX）：message_summary_info 的 "rp"＝收回的段落、"otr"＝段落表；
// URL 預覽在 payload_data（NSKeyedArchiver plist）的 LPLinkMetadata。這裡是照它的欄位語義自己寫的 Swift，沒有搬程式碼。
// 隱私：這個檔案只轉換資料，不寫任何日誌。

import Foundation

// MARK: - message_summary_info（編輯／收回）

enum MessagesSummaryInfo {
    /// 全部段落都被收回：plist 的 "rp"（收回的段落索引）蓋住 "otr"（段落表）的每一段；沒有 otr 時 rp 不空就算
    static func isFullyUnsent(_ blob: Data?) -> Bool {
        guard let blob, !blob.isEmpty,
              let root = try? PropertyListSerialization.propertyList(from: blob, format: nil) as? [String: Any],
              let rp = root["rp"] as? [Any], !rp.isEmpty else { return false }
        let parts = (root["otr"] as? [String: Any])?.count ?? 0
        return parts == 0 || rp.count >= parts
    }
}

// MARK: - URL 預覽（payload_data）

enum MessagesLinkPreview {
    static let balloonID = "com.apple.messages.URLBalloonProvider"

    /// NSKeyedArchiver 的 plist：$objects 裡找 LPLinkMetadata（有 title／URL 的那個字典），把 UID 解回字串。
    /// 只用 PropertyListSerialization（壞資料回 nil，不丟 ObjC 例外），不用 NSKeyedUnarchiver。
    static func parse(_ blob: Data?) -> MsgLink? {
        guard let blob, !blob.isEmpty,
              let root = try? PropertyListSerialization.propertyList(from: blob, format: nil) as? [String: Any],
              let objs = root["$objects"] as? [Any] else { return nil }
        func uid(_ v: Any?) -> Int? {
            guard let v else { return nil }
            if let n = v as? Int { return n }
            // CFKeyedArchiverUID：描述是「<CFKeyedArchiverUID …>{value = N}」
            let d = String(describing: v)
            guard d.contains("CFKeyedArchiverUID"), let r = d.range(of: "value = ") else { return nil }
            return Int(d[r.upperBound...].prefix { $0.isNumber })
        }
        func object(_ v: Any?) -> Any? { uid(v).flatMap { $0 >= 0 && $0 < objs.count ? objs[$0] : nil } }
        func string(_ v: Any?) -> String? {
            guard let o = object(v) else { return nil }
            if let s = o as? String, s != "$null" { return s }
            if let d = o as? [String: Any] {   // NSURL：NS.relative 指向字串
                if let s = string(d["NS.relative"]) { return s }
                if let s = string(d["NS.string"]) { return s }
            }
            return nil
        }
        for o in objs {
            guard let d = o as? [String: Any], d["title"] != nil || d["originalURL"] != nil,
                  d["richLinkMetadata"] == nil else { continue }
            let url = string(d["URL"]) ?? string(d["originalURL"]) ?? ""
            let title = string(d["title"]) ?? ""
            let site = string(d["siteName"]) ?? ""
            guard !url.isEmpty || !title.isEmpty else { continue }
            var imageIndex: Int?
            if let img = object(d["image"]) as? [String: Any], let n = img["richLinkImageAttachmentSubstituteIndex"] as? Int { imageIndex = n }
            return MsgLink(url: url, title: title, site: site, imageIndex: imageIndex)
        }
        return nil
    }
}

// MARK: - 大表情、特效

enum MessagesEmoji {
    /// 1～3 個 emoji、沒有別的字：iOS 畫成不帶泡泡的大表情（影片 v1 01:37.5 的 🫶）
    static func isBigEmoji(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 3 else { return false }
        return t.allSatisfy { c in
            c.unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x238C) }
                && !c.unicodeScalars.contains { $0.properties.isASCIIHexDigit && $0.value < 0x80 }
        }
    }
}

enum MessagesEffect {
    /// expressive_send_style_id → 「以○○效果傳送」用的名字；不認得就 nil（只顯示「重播」）
    static func name(_ id: String?) -> String? {
        switch id {
        case "com.apple.MobileSMS.expressivesend.impact": return L("msg.effect.slam", "重击")
        case "com.apple.MobileSMS.expressivesend.loud": return L("msg.effect.loud", "大声")
        case "com.apple.MobileSMS.expressivesend.gentle": return L("msg.effect.gentle", "轻声")
        case "com.apple.MobileSMS.expressivesend.invisibleink": return L("msg.effect.ink", "隐形墨水")
        default: return nil
        }
    }
    /// 隱形墨水：先遮起來（跟 iPhone 一樣，要點一下才看）
    static func isInvisibleInk(_ id: String?) -> Bool { id == "com.apple.MobileSMS.expressivesend.invisibleink" }
}

// MARK: - 本機「看過」（無法同步到 iPhone 的已讀；只讓 HomePlay 的未讀點消失）

enum MessagesSeen {
    static let key = "HomePlayMessagesSeen"
    static func load(_ d: UserDefaults = .standard) -> [String: Int64] {
        (d.dictionary(forKey: key) as? [String: NSNumber])?.mapValues { $0.int64Value } ?? [:]
    }
    static func mark(_ guid: String, upTo row: Int64, _ d: UserDefaults = .standard) {
        var m = load(d)
        guard row > (m[guid] ?? 0) else { return }
        m[guid] = row
        if m.count > 300 { m = Dictionary(uniqueKeysWithValues: m.sorted { $0.value > $1.value }.prefix(200).map { ($0.key, $0.value) }) }
        d.set(m.mapValues { NSNumber(value: $0) }, forKey: key)
    }
    /// chat.db 說未讀、而且最後一則比本機看過的新
    static func isUnread(_ c: MsgConversation, seen: [String: Int64]) -> Bool {
        c.unread > 0 && c.lastRowID > (seen[c.guid] ?? 0)
    }
}

// MARK: - 對話頁的一列一列

/// 畫面上的一個項目（泡泡、照片、系統訊息、時間分隔、狀態字）
struct MessagesItem {
    enum Kind {
        case text(String)
        case bigEmoji(String)
        case photo(MessagesMediaRef)
        case video(MessagesMediaRef)
        case sticker(MessagesMediaRef)
        case audio(MessagesMediaRef, seconds: Double?)
        case link(MsgLink, image: MessagesMediaRef?)
        case file(String)
        case hidden                   // 隱形墨水：點一下才顯示
        case unsent(String)           // 系統句：「你收回了一則訊息」
        case separator(String)        // 「今天 7:12」
    }
    var kind: Kind
    var fromMe = false
    var sms = false                   // 綠色泡泡（SMS／RCS）
    var tail = false                  // 同一個人連續幾則的最後一則才有尾巴
    var sender: String?               // 群組裡對方那一串的第一則：名字
    var senderInitials: String?       // 群組裡對方那一串的最後一則：頭像（縮寫）
    var senderHandle: String?
    var senderName: String?           // VoiceOver 用：每一則都知道是誰
    var tapbacks: [MsgTapback] = []
    var edited = false
    var replyQuote: String?           // 回覆串：原訊息的開頭
    var status: String?               // 這一則底下的「已送達」「已讀 7:12」
    var failed = false                // 「未送達」：紅字（每一則都標，不只最後一則）
    var effect = false                // 有特效：底下「↺ 重播」
    var messageRow: Int64 = 0
    var tappable: Bool {
        switch kind { case .photo, .video, .audio, .link, .hidden, .sticker: return true; default: return effect }
    }
}

/// 附件的參照：示範資料直接給圖；真資料給附件 ROWID＋路徑，縮圖由 MessagesMedia 背景產生
struct MessagesMediaRef {
    var id: Int64
    var path: String
    var aspect: CGFloat                // 寬／高；不知道時 4/3
    var sensitive = false
}

enum MessagesThreadBuilder {
    /// 時間分隔：前後兩則差超過這個就插一條（iOS 大約一小時）
    static let separatorGap: TimeInterval = 3600
    /// 同一個人連續、間隔在這之內算一串（尾巴只畫在最後一則）
    static let runGap: TimeInterval = 60

    /// 頭像上的縮寫：先去掉方括號與空白（示範名字「[姊姊]」）
    static func initials(_ name: String) -> String {
        AvatarResolver.initials(name.trimmingCharacters(in: CharacterSet(charactersIn: "[]［］「」 ")))
    }

    /// 「今天 7:12」「昨天 21:03」「星期四 08:15」「10/12 08:15」
    static func separator(_ d: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = L10n.language.locale) -> String {
        let tf = DateFormatter(); tf.locale = locale; tf.calendar = calendar; tf.timeZone = calendar.timeZone
        Face.setTimeFormat(tf)   // 2.0 depth：時制照系統（介面語言的 locale 沒有使用者的覆寫）
        let time = tf.string(from: d)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: d), to: calendar.startOfDay(for: now)).day ?? 99
        let day: String
        if days == 0 { day = L("msg.today", "今天") }
        else if days == 1 { day = L("msg.yesterday", "昨天") }
        else if days > 1 && days < 7 { let f = DateFormatter(); f.locale = locale; f.calendar = calendar; f.timeZone = calendar.timeZone; f.setLocalizedDateFormatFromTemplate("EEEE"); day = f.string(from: d) }
        else { let f = DateFormatter(); f.locale = locale; f.calendar = calendar; f.timeZone = calendar.timeZone; f.setLocalizedDateFormatFromTemplate("MMMd"); day = f.string(from: d) }
        return day + " " + time
    }

    /// 自己送的最後一則底下：已讀（有時間）＞已送達；SMS 沒有狀態
    static func status(_ m: MsgMessage, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard m.isFromMe, m.service == "iMessage" || m.service.isEmpty else { return nil }
        if let r = m.dateRead {
            let f = DateFormatter(); f.locale = L10n.language.locale; f.calendar = calendar; f.timeZone = calendar.timeZone
            if calendar.isDate(r, inSameDayAs: now) { Face.setTimeFormat(f) } else { f.setLocalizedDateFormatFromTemplate("Md") }
            return String(format: L("msg.status.read", "已读 %@"), f.string(from: r))
        }
        return m.isDelivered ? L("msg.status.delivered", "已送达") : nil
    }

    /// 訊息（舊到新）→ 畫面項目。name：handle → 顯示名；media：附件 → 參照（只有路徑可讀的才給）
    static func items(_ msgs: [MsgMessage], isGroup: Bool, name: (String) -> String?,
                      now: Date = Date(), calendar: Calendar = .current) -> [MessagesItem] {
        var out: [MessagesItem] = []
        let byGUID = Dictionary(msgs.map { ($0.guid, $0) }, uniquingKeysWith: { a, _ in a })
        let lastMine = msgs.lastIndex { $0.isFromMe && !$0.isUnsent }
        var prev: MsgMessage?
        for (mi, m) in msgs.enumerated() {
            if prev == nil || m.date.timeIntervalSince(prev!.date) > separatorGap {
                out.append(MessagesItem(kind: .separator(separator(m.date, now: now, calendar: calendar))))
            }
            defer { prev = m }
            let who = m.isFromMe ? "" : (name(m.senderHandle) ?? m.senderHandle)
            if m.isUnsent {
                let s = m.isFromMe ? L("msg.unsent.me", "你撤回了一条信息") : String(format: L("msg.unsent.other", "%@撤回了一条信息"), who)
                out.append(MessagesItem(kind: .unsent(s), fromMe: m.isFromMe, messageRow: m.rowID))
                continue
            }
            var parts: [MessagesItem.Kind] = []
            var linkImage: Int?
            if let l = m.link { linkImage = l.imageIndex }
            for (ai, a) in m.attachments.enumerated() where ai != linkImage || m.link == nil {
                let ref = MessagesMediaRef(id: a.rowID, path: a.path, aspect: 4.0 / 3.0, sensitive: a.sensitive)
                if a.isSticker { parts.append(.sticker(ref)) }
                else if m.isAudioMessage || a.isAudio { parts.append(.audio(ref, seconds: nil)) }
                else if a.isVideo { parts.append(.video(ref)) }
                else if a.isImage { parts.append(.photo(ref)) }
                else { parts.append(.file(a.name.isEmpty ? L("msg.attachment", "附件") : a.name)) }
            }
            if let l = m.link {
                let img = linkImage.flatMap { $0 < m.attachments.count ? m.attachments[$0] : nil }
                    .map { MessagesMediaRef(id: $0.rowID, path: $0.path, aspect: 1.9) }
                parts.append(.link(l, image: img))
            } else if !m.text.isEmpty {
                if MessagesEffect.isInvisibleInk(m.effect) { parts.append(.hidden) }
                else { parts.append(MessagesEmoji.isBigEmoji(m.text) ? .bigEmoji(m.text) : .text(m.text)) }
            }
            if parts.isEmpty { parts.append(.file(L("msg.attachment", "附件"))) }
            let next = mi + 1 < msgs.count ? msgs[mi + 1] : nil
            let runEnds = next == nil || next!.isFromMe != m.isFromMe || next!.senderHandle != m.senderHandle
                || next!.date.timeIntervalSince(m.date) > runGap || next!.isUnsent
            let runStarts = prev == nil || prev!.isFromMe != m.isFromMe || prev!.senderHandle != m.senderHandle
                || m.date.timeIntervalSince(prev!.date) > runGap || out.last.map { if case .separator = $0.kind { return true }; return false } == true
            for (pi, k) in parts.enumerated() {
                var it = MessagesItem(kind: k, fromMe: m.isFromMe, sms: m.service == "SMS" || m.service == "RCS")
                it.messageRow = m.rowID
                it.senderHandle = m.isFromMe ? nil : m.senderHandle
                it.senderName = m.isFromMe ? nil : who
                let lastPart = pi == parts.count - 1
                it.tail = lastPart && runEnds
                if isGroup && !m.isFromMe {
                    if pi == 0 && runStarts { it.sender = who }
                    if it.tail { it.senderInitials = initials(who) }
                }
                if lastPart {
                    it.failed = m.failed
                    it.tapbacks = m.tapbacks
                    it.edited = m.isEdited
                    it.effect = m.effect != nil && !MessagesEffect.isInvisibleInk(m.effect)
                    if mi == lastMine { it.status = status(m, now: now, calendar: calendar) }
                }
                if pi == 0, let r = m.replyToGUID, r != m.guid {
                    let o = byGUID[r]
                    let q = o.map { $0.text.isEmpty ? L("msg.attachment", "附件") : $0.text } ?? L("msg.reply.earlier", "较早的信息")
                    it.replyQuote = q
                }
                out.append(it)
            }
        }
        return out
    }
}
