// 通訊錄：handle（電話／信箱）→ 名字與頭像。需要 Contacts 授權（NSContactsUsageDescription）；沒授權就退回顯示 handle。
// 對照用 HandleKey.make 正規化。隱私：不記錄名字或號碼，只記筆數。

import Contacts
import CoreGraphics
import Foundation
import ImageIO

final class MessagesContacts: @unchecked Sendable {
    static let shared = MessagesContacts()

    private struct Entry { var name: String; var photo: Data? }
    private var byKey: [String: Entry] = [:]
    /// 2.0 imsg：新訊息選收件人用（名字 → 號碼／信箱，照通訊錄順序）
    struct Person { var name: String; var handles: [String]; var photo: Data? }
    private var people: [Person] = []
    private let lock = NSLock()
    private(set) var loaded = false

    static var status: CNAuthorizationStatus { CNContactStore.authorizationStatus(for: .contacts) }

    /// 向系統要授權（沒決定過才會彈框），然後載入。completion 在主執行緒
    func requestAccess(_ completion: @escaping (Bool) -> Void = { _ in }) {
        CNContactStore().requestAccess(for: .contacts) { ok, _ in
            if ok { self.reload() }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// 已授權才讀；整本通訊錄列舉一次放進記憶體
    func reload() {
        guard Self.status == .authorized else { return }
        let keys: [CNKeyDescriptor] = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
                                       CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactThumbnailImageDataKey] as [CNKeyDescriptor]
        var map: [String: Entry] = [:]
        var list: [Person] = []
        let req = CNContactFetchRequest(keysToFetch: keys)
        try? CNContactStore().enumerateContacts(with: req) { c, _ in
            // 台灣習慣：姓在前、名在後，中間不空格；英文照「名 姓」
            let given = c.givenName, family = c.familyName
            let cjk = (given + family).unicodeScalars.contains { $0.value >= 0x2E80 }
            var name = cjk ? family + given : [given, family].filter { !$0.isEmpty }.joined(separator: " ")
            if name.isEmpty { name = c.nickname }
            if name.isEmpty { name = c.organizationName }
            guard !name.isEmpty else { return }
            let e = Entry(name: name, photo: c.thumbnailImageData)
            for p in c.phoneNumbers { map[HandleKey.make(p.value.stringValue)] = e }
            for m in c.emailAddresses { map[HandleKey.make(m.value as String)] = e }
            let handles = c.phoneNumbers.map { $0.value.stringValue } + c.emailAddresses.map { $0.value as String }
            if !handles.isEmpty { list.append(Person(name: name, handles: handles, photo: c.thumbnailImageData)) }
        }
        lock.lock(); byKey = map; people = list; loaded = true; lock.unlock()
        log("messages: contacts loaded, \(map.count) keys")
    }

    func name(for handle: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return byKey[HandleKey.make(handle)]?.name
    }

    /// 2.0 imsg：照名字找人（不分大小寫、去空白；開頭符合排前面），最多 limit 個
    func search(_ query: String, limit: Int = 8) -> [Person] {
        let q = ClioMessagesTools.normalized(query)
        guard !q.isEmpty else { return [] }
        lock.lock(); let all = people; lock.unlock()
        let hits = all.filter { ClioMessagesTools.normalized($0.name).contains(q) }
        let starts = hits.filter { ClioMessagesTools.normalized($0.name).hasPrefix(q) }
        return Array((starts + hits.filter { h in !starts.contains { $0.name == h.name && $0.handles == h.handles } }).prefix(limit))
    }

    static func image(_ d: Data?) -> CGImage? {
        guard let d, let src = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    func photo(for handle: String) -> CGImage? {
        lock.lock(); let d = byKey[HandleKey.make(handle)]?.photo; lock.unlock()
        guard let d, let src = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
