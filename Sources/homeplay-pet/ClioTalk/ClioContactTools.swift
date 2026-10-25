// 2.0: ClioTalk 的 call（打 FaceTime）與 find_messages（找訊息）。
// call：先從通訊錄把名字找成一個人、挑一個號碼或信箱，再用 facetime:// 或 facetime-audio:// 叫「FaceTime」；
// 替你打電話＝用你的名義，所以引擎先念「要用 FaceTime 打給 X 嗎？」，你說「好」才走到這裡。FaceTime 自己還會再問一次。
// find_messages：在最近的對話裡按聯絡人或關鍵字找幾則；內文只回給模型，不寫日誌。

import AppKit
import Contacts
import Foundation

enum ClioCallTools {
    /// 號碼／信箱 → FaceTime 網址（純函式，selftest 用）
    static func url(handle: String, video: Bool) -> URL? {
        let h = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return nil }
        let scheme = video ? "facetime" : "facetime-audio"
        if h.contains("@") {
            guard let e = h.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed.union(CharacterSet(charactersIn: "@"))) else { return nil }
            return URL(string: "\(scheme)://\(e)")
        }
        let digits = h.filter { $0.isASCII && $0.isNumber }
        guard digits.count >= 3 else { return nil }
        return URL(string: "\(scheme)://" + (h.hasPrefix("+") ? "+" : "") + digits)
    }

    /// 這個人的哪一個號碼：手機優先，其次 iPhone／主要，再來第一個；沒有號碼就用信箱
    static func bestHandle(phones: [(label: String?, value: String)], emails: [String]) -> String? {
        func rank(_ l: String?) -> Int {
            let s = (l ?? "").lowercased()
            if s.contains("iphone") || s.contains("mobile") || s.contains("cell") { return 0 }
            if s.contains("main") { return 1 }
            return 2
        }
        if let p = phones.enumerated().min(by: { (rank($0.element.label), $0.offset) < (rank($1.element.label), $1.offset) }) { return p.element.value }
        return emails.first
    }

    static func displayName(_ c: CNContact) -> String {
        let cjk = (c.givenName + c.familyName).unicodeScalars.contains { $0.value >= 0x2E80 }
        let n = cjk ? c.familyName + c.givenName : [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        return n.isEmpty ? (c.nickname.isEmpty ? c.organizationName : c.nickname) : n
    }

    static func run(input: [String: Any]) async -> ClioToolResult {
        func fail(_ s: String) -> ClioToolResult { ClioToolResult(content: s, isError: true, source: .calls) }
        guard PersonalGate.cached else { return fail("Calling is only available to the owner of this Mac. Guest mode is on or the owner is not recognized.") }
        let name = (input["contact"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return fail("contact is required") }
        let video = (input["video"] as? Bool) ?? false
        // 通訊錄授權（沒問過才問；Info.plist 沒寫用途說明就不問）
        var status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined, Bundle.main.object(forInfoDictionaryKey: "NSContactsUsageDescription") != nil {
            _ = try? await CNContactStore().requestAccess(for: .contacts)
            status = CNContactStore.authorizationStatus(for: .contacts)
        }
        guard status == .authorized else { return fail("Contacts access is not granted, so ClioTalk cannot look up who to call. Tell the user to allow Contacts for HomePlay in System Settings › Privacy & Security.") }
        let keys: [CNKeyDescriptor] = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
                                       CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactThumbnailImageDataKey] as [CNKeyDescriptor]
        let store = CNContactStore()
        var found = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)) ?? []
        if found.isEmpty, let t = name.applyingTransform(StringTransform("Hant-Hans"), reverse: false), t != name {
            found = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: t), keysToFetch: keys)) ?? []
        }
        found = found.filter { !$0.phoneNumbers.isEmpty || !$0.emailAddresses.isEmpty }
        guard !found.isEmpty else { return fail("No contact with a phone number or email matches \"\(name)\". Ask the user for the name as it appears in Contacts.") }
        guard found.count == 1 else {
            return fail("Several contacts match: " + found.prefix(5).map(displayName).joined(separator: ", ") + ". Ask the user which one.")
        }
        let c = found[0]
        let handle = bestHandle(phones: c.phoneNumbers.map { ($0.label, $0.value.stringValue) },
                                emails: c.emailAddresses.map { $0.value as String })
        guard let h = handle, url(handle: h, video: video) != nil else { return fail("That contact has no number that FaceTime can call.") }
        // 2.0 第四輪 #10：走 FaceTime App 的通話畫面（撥出、交給 FaceTime、通話中的綠色膠囊、掛斷轉場）；確認已經在引擎念過
        let who = FaceTimeContact(id: c.identifier, name: displayName(c), handle: h, label: "", photo: c.isKeyAvailable(CNContactThumbnailImageDataKey) ? c.thumbnailImageData : nil)
        let opened: Bool = await MainActor.run { FaceTimeApp.shared.startFromClio(who, video: video) }
        return opened ? ClioToolResult(content: "FaceTime \(video ? "video" : "audio") call to \(displayName(c)) is starting; FaceTime may ask the user to press Call.", source: .calls)
                      : fail("FaceTime could not be opened.")
    }
}

enum ClioFindMessages {
    /// 內文是否含關鍵字（小寫、繁→簡都比；純函式，selftest 用）
    static func matches(_ text: String, keyword: String) -> Bool {
        let k = ClioHomeControl.normalized(keyword)
        return k.isEmpty || ClioHomeControl.normalized(text).contains(k)
    }

    static func run(input: [String: Any]) async -> ClioToolResult {
        func fail(_ s: String) -> ClioToolResult { ClioToolResult(content: s, isError: true, source: .messages) }
        guard PersonalGate.cached else { return fail("Messages are only available to the owner of this Mac. Guest mode is on or the owner is not recognized.") }
        guard let store = ClioMessagesTools.openStoreForSearch() else {
            return fail(MessagesAccess.check() == .needsFullDiskAccess
                        ? "HomePlay cannot read Messages yet: the user has to allow Full Disk Access for HomePlay in System Settings › Privacy & Security."
                        : "Messages is not set up on this Mac.")
        }
        let contact = (input["contact"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let keyword = (input["keyword"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contact.isEmpty || !keyword.isEmpty else { return fail("Give a contact name, a keyword, or both.") }
        let limit = max(1, min(8, (input["limit"] as? NSNumber)?.intValue ?? 5))
        let all = store.conversations(limit: 200)
        let convs = contact.isEmpty ? Array(all.prefix(20)) : Array(ClioMessagesTools.match(contact, in: all).prefix(4))
        guard !convs.isEmpty else { return fail("No conversation matches \"\(contact)\". Ask the user for the name as it appears in Messages.") }
        var hits: [(Date, String)] = []
        for conv in convs {
            for m in store.messages(chat: conv.rowID, limit: 80) where !m.text.isEmpty && matches(m.text, keyword: keyword) {
                let who = m.isFromMe ? "me" : (store.nameResolver?(m.senderHandle) ?? (conv.isGroup ? m.senderHandle : conv.title))
                hits.append((m.date, "- \(ClioDates.machine(m.date).prefix(16)) \(conv.title) / \(who): \(m.text.count > 200 ? String(m.text.prefix(200)) + "…" : m.text)"))
            }
        }
        hits.sort { $0.0 > $1.0 }
        guard !hits.isEmpty else { return ClioToolResult(content: "No matching messages in the recent conversations.", source: .messages) }
        return ClioToolResult(content: "Newest first:\n" + hits.prefix(limit).map(\.1).joined(separator: "\n"), source: .messages)
    }
}
