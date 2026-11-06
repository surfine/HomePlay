// 2.0 家人個人檔案：從「主人／訪客」擴成每位家人各自一份（官方：「家庭成員可以建立自己的個人檔案，取用個人的播放列表、訊息、提醒事項等」）。
//
// - 誰是「目前這位家人」：PersonalGate.avatarPerson（主畫面右上的頭像）——認人開著＝眼前認出的人；沒開＝主人，或手動換的那位；
//   訪客模式、訪客裝置在用、認不出＝訪客（nil）。每幀在 shellStep 算一次存在 currentID，背景與每幀都要讀的地方讀它。
// - 每位家人自己的：名字與頭像（名冊 people.json；頭像多一種 emoji）、主畫面排列（SBStore，本來就照人存）、
//   Look、播放列表、iPhone／Mac 誰優先、自己的提醒事項清單（這裡，存 UserDefaults family.profiles.v1，不含生物特徵）。
// - 主人照舊用原本那幾個全域設定（HomePlayLook、共用清單…）：既有使用者升級上來，主人＝第一位家人，資料一筆都不搬，所以不會丟。
//   家人沒設的那一項跟著主人。
// - 換人：主畫面右上頭像選單、控制中心「家人」、對 ClioTalk 說「我是 X」。macOS 沒有公開的聲紋（說話者辨識）API，
//   所以說「我是 X」是自稱，不是驗證——跟手動點頭像選單同一個門：認人開著時由認人決定，訪客模式要先在控制中心關掉。
// - 個人 App 的門照「目前這位家人」：主人＝全部；家人＝自己的提醒事項清單（設了才開）與播放列表；
//   訊息、日曆、FaceTime、通訊錄、尋找是這台 Mac 帳號的資料，照舊只開給主人。

import AppKit

/// iPhone 與 Mac 同時在播時先顯示誰（nil＝照舊 iPhone 優先）
enum MusicSourcePref: String, Codable, CaseIterable { case iPhone, mac }

struct ProfilePrefs: Codable, Equatable {
    var look: String?
    var playlist: String?
    var musicSource: MusicSourcePref?
    var remindersList: String?
}

enum FamilyProfiles {
    static let key = "family.profiles.v1"
    /// selftest 與快照時關掉寫檔
    nonisolated(unsafe) static var persist = !SnapshotPrivacy.active
    nonisolated(unsafe) static var store: UserDefaults = .standard
    nonisolated(unsafe) static var prefs: [String: ProfilePrefs] = load(UserDefaults.standard.data(forKey: key))
    /// 目前這位家人（nil＝訪客）與他是不是主人；shellStep 每幀更新
    nonisolated(unsafe) static var currentID: String?
    nonisolated(unsafe) static var currentIsOwner = true

    /// 讀不懂的那幾份（例如將來版本多了新選項值）：原樣留著，存檔時照寫回去，不覆寫掉
    nonisolated(unsafe) static var unreadable: [String: Any] = loadAll(UserDefaults.standard.data(forKey: key)).unreadable

    /// 逐人解碼：一份讀不懂不影響其他人（跟 SBStore.load 同一個作法）
    static func load(_ raw: Data?) -> [String: ProfilePrefs] { loadAll(raw).ok }
    static func loadAll(_ raw: Data?) -> (ok: [String: ProfilePrefs], unreadable: [String: Any]) { PerPersonCodec.decode(raw, as: ProfilePrefs.self) }
    static func encoded(_ p: [String: ProfilePrefs], keeping bad: [String: Any]) -> Data? { PerPersonCodec.encode(p, keeping: bad) }
    static func save() {
        guard persist, let raw = encoded(prefs, keeping: unreadable) else { return }
        store.set(raw, forKey: key)
    }

    // MARK: 快照（--demo-profiles switcher|home）：示範的三位家人，不讀真的名冊

    nonisolated(unsafe) static var demo: String? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--demo-profiles"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }()
    static let demoPeople: [Person] = [
        Person(id: "demo-erica", name: "Erica", colorIndex: 3, isOwner: true, avatar: HPAvatar.presets[1], avatarSource: .eyes),   // l10n-ignore：示範人名
        Person(id: "demo-marco", name: "Marco", colorIndex: 1, isOwner: false, emoji: "🦖"),   // l10n-ignore：示範人名
        Person(id: "demo-lily", name: "Lily", colorIndex: 2, isOwner: false),   // l10n-ignore：示範人名
    ]
    static func applyDemo() {
        guard demo != nil else { return }
        persist = false; SBStore.persist = false
        prefs = ["demo-marco": ProfilePrefs(look: "Sage", playlist: "Dino Mix", musicSource: .mac, remindersList: "l2")]   // l10n-ignore：示範播放列表
        var l = SBLayout.official
        l.pages[0].items.removeAll { $0 == .app("messages") || $0 == .app("calendar") }
        l.pages[0].items.append(.app("sing"))
        SBStore.layouts["demo-marco"] = l
        PersonalGate.hint = "demo-marco"
        if demo == "switcher" { Shell.peopleSheet = true }
    }

    /// 名冊（快照用示範的）
    static var roster: [Person] { demo != nil ? demoPeople : PeopleRegistry.shared.people }
    static var owner: Person? { roster.first(where: \.isOwner) }

    // MARK: 目前這位家人

    /// 每幀（shellStep）：換人了回 true（主畫面靜態層、Look 要重畫）
    @discardableResult
    static func refresh() -> Bool {
        let p = Shell.demoPerson ?? PersonalGate.avatarPerson(PersonalGate.inputs, people: roster, owner: owner)
        let id = p?.id, own = p?.isOwner ?? false
        guard id != currentID || own != currentIsOwner else { return false }
        currentID = id; currentIsOwner = own
        Shell.homeLayer = nil
        return true
    }

    static func prefs(for id: String) -> ProfilePrefs { prefs[id] ?? ProfilePrefs() }
    static func set(_ p: ProfilePrefs, for id: String) {
        prefs[id] = p == ProfilePrefs() ? nil : p
        unreadable[id] = nil   // 這個人自己改過了：讀不懂的舊那份不再寫回
        save()
        Shell.homeLayer = nil
    }
    /// 名冊裡已經沒有的人：那一份一起清
    static func prune(keeping ids: Set<String>) {
        let before = prefs.count
        prefs = prefs.filter { ids.contains($0.key) }
        let badBefore = unreadable.count
        unreadable = unreadable.filter { ids.contains($0.key) }
        if prefs.count != before || unreadable.count != badBefore { save() }
    }

    /// 目前是家人（不是主人、不是訪客）時他自己的那一份
    static var memberPrefs: ProfilePrefs? { memberPrefs(currentID: currentID, isOwner: currentIsOwner, prefs: prefs) }
    static func memberPrefs(currentID: String?, isOwner: Bool, prefs: [String: ProfilePrefs]) -> ProfilePrefs? {
        guard let id = currentID, !isOwner else { return nil }
        return prefs[id] ?? ProfilePrefs()
    }

    // MARK: 各項的解析（純函數，selftest 直接測）

    /// Look：家人選過用他的；主人、訪客、家人沒選＝全域那一份（主人的）
    static func resolvedLook(member: ProfilePrefs?, global: String) -> String {
        if let l = member?.look, HVTruth.look(l) != nil { return l }
        return global
    }
    static var memberLook: String? { memberPrefs?.look.flatMap { HVTruth.look($0) != nil ? $0 : nil } }
    /// 設定裡選 Look：目前是家人就存到他那一份；回 true＝存好了（主人照舊存全域）
    static func selectLookForMember(_ name: String) -> Bool {
        guard let id = currentID, !currentIsOwner else { return false }
        var p = prefs(for: id); p.look = name; set(p, for: id)
        return true
    }

    static var musicSource: MusicSourcePref {
        if demo != nil { return .iPhone }
        guard let id = currentID else { return .iPhone }
        return prefs[id]?.musicSource ?? .iPhone
    }

    /// 個人 App 的門：家人設了自己的提醒事項清單，提醒事項就開（只畫那一份）；訪客裝置在用時照舊鎖
    static func memberUnlocks(_ appID: String, member: ProfilePrefs?, remoteGuest: Bool) -> Bool {
        guard !remoteGuest, let m = member else { return false }
        switch appID {
        case "reminders": return m.remindersList != nil
        default: return false
        }
    }

    // MARK: 換人

    enum SwitchResult: Equatable { case switched, recognitionDecides, guestMode, unknown }

    /// 手動換（頭像選單、控制中心、說「我是 X」）。認人開著時由認人決定；訪客模式要先關（訪客自己換不出主人）
    @discardableResult
    static func switchTo(_ id: String) -> SwitchResult {
        guard let p = roster.first(where: { $0.id == id }) else { return .unknown }
        if Shell.guestMode || RemotePrivacy.guestActive { return .guestMode }
        if PersonalGate.recognitionActive, demo == nil { return .recognitionDecides }
        PersonalGate.hint = p.isOwner ? nil : p.id
        refresh()
        PeopleOverlay.greet(p)
        log("family profile switched")
        return .switched
    }

    static func blockedText(_ r: SwitchResult) -> String? {
        switch r {
        case .switched, .unknown: return nil
        case .recognitionDecides: return L("profile.switch.byFace", "「认出谁在看」开着：看着屏幕就会换人")
        case .guestMode: return L("guest.why.mode", "访客模式开着；在控制中心关掉")
        }
    }

    /// 對 ClioTalk 說「我是 X」：整句幾乎就是這句、名字對得上名冊才算（純函數）。
    /// 不是聲紋辨識——只是把說出來的名字當成手動換人
    static func voiceTarget(_ text: String, people: [Person]) -> Person? {
        var t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "。．.!！?？,，、~～ "))
        let heads = ["我是", "我係", "换成", "換成", "切换到", "切換到", "换到", "換到", "i'm ", "i am ", "im ", "this is ", "it's ", "switch to "]   // l10n-ignore：比對用詞
        guard let h = heads.first(where: { t.hasPrefix($0) }) else { return nil }
        var name = String(t.dropFirst(h.count)).trimmingCharacters(in: .whitespaces)
        for tail in ["啊", "呀", "啦", "喔", "哦", "了", "的"] where name.count > tail.count && name.hasSuffix(tail) { name = String(name.dropLast(tail.count)) }   // l10n-ignore：比對用詞
        name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        func norm(_ s: String) -> String { s.lowercased().filter { !$0.isWhitespace } }
        let n = norm(name)
        if let p = people.first(where: { norm($0.name) == n }) { return p }
        let firsts = people.filter { ($0.name.split(separator: " ").first.map { norm(String($0)) }) == n }
        return firsts.count == 1 ? firsts[0] : nil
    }

    // MARK: 升級遷移

    static let migratedKey = "family.profiles.migrated"

    /// 既有使用者升級：主人＝第一位家人。主人的排列、Look、共用清單本來就在原處（主畫面排列照人 id 存；其他是全域設定），
    /// 所以只寫一個空的主人檔案與記號——不搬、不刪任何既有的鍵。回 true＝這次做了遷移
    @discardableResult
    static func migrate(defaults: UserDefaults, ownerID: String?) -> Bool {
        guard !defaults.bool(forKey: migratedKey), let ownerID else { return false }
        let all = loadAll(defaults.data(forKey: key))
        var p = all.ok
        let bad = all.unreadable
        if p[ownerID] == nil, bad[ownerID] == nil { p[ownerID] = ProfilePrefs() }
        if let raw = encoded(p, keeping: bad) { defaults.set(raw, forKey: key) }
        defaults.set(true, forKey: migratedKey)
        return true
    }
    static func migrateAtLaunch() {
        guard persist, demo == nil, !SnapshotPrivacy.active else { return }
        if migrate(defaults: .standard, ownerID: PeopleRegistry.shared.owner?.id) {
            let r = loadAll(UserDefaults.standard.data(forKey: key))
            prefs = r.ok; unreadable = r.unreadable
            log("family profiles: owner migrated")
        }
    }

    // MARK: selftest

    static func selftest(_ check: (Bool, String) -> Void) {
        // 遷移不丟資料：一份「升級前」的偏好，遷移後每個既有的鍵原封不動，主人的排列、Look 照樣讀得回來
        let suite = "homeplay.selftest.family"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }
        var ownerLayout = SBLayout.official
        ownerLayout.pages[0].items.removeAll { $0 == .app("podcasts") }
        let layouts = ["owner-1": ownerLayout]
        d.set(SBStore.encoded(layouts), forKey: SBStore.key)
        d.set("Mocha", forKey: HPLook.defaultsKey)
        d.set("list-shop", forKey: RemindersApp.sharedKey)
        d.set(true, forKey: Onboarding.defaultsKey)
        let before = d.dictionaryRepresentation().filter { [SBStore.key, HPLook.defaultsKey, RemindersApp.sharedKey, Onboarding.defaultsKey].contains($0.key) }
        let did = migrate(defaults: d, ownerID: "owner-1")
        let after = d.dictionaryRepresentation()
        let kept = before.allSatisfy { k, v in (after[k] as AnyObject).isEqual(v) }
        let back = SBStore.load(d.data(forKey: SBStore.key))["owner-1"]
        check(did && kept && back == ownerLayout && load(d.data(forKey: key))["owner-1"] == ProfilePrefs(),
              "家人檔案：升級遷移不搬不刪既有的鍵，主人的排列原樣讀回，多一份空的主人檔案")   // l10n-ignore：selftest 訊息
        check(resolvedLook(member: memberPrefs(currentID: "owner-1", isOwner: true, prefs: [:]), global: d.string(forKey: HPLook.defaultsKey)!) == "Mocha",
              "家人檔案：遷移後主人的 Look 還是原本那個")   // l10n-ignore：selftest 訊息
        check(!migrate(defaults: d, ownerID: "owner-1"), "家人檔案：遷移只做一次")   // l10n-ignore：selftest 訊息
        // 一份讀不懂的偏好（將來版本多了新的音樂來源）：其他人照讀，那一份原樣留著、存回去；遷移也不覆寫它
        let mixedRaw = Data(#"{"kid":{"look":"Sage"},"future":{"musicSource":"watch","look":"Mocha"}}"#.utf8)
        let mr = loadAll(mixedRaw)
        let roundTrip = encoded(mr.ok, keeping: mr.unreadable).map { loadAll($0) }
        check(mr.ok["kid"]?.look == "Sage" && mr.ok["future"] == nil && (mr.unreadable["future"] as? [String: Any])?["musicSource"] as? String == "watch"
              && roundTrip?.ok["kid"]?.look == "Sage" && (roundTrip?.unreadable["future"] as? [String: Any])?["musicSource"] as? String == "watch",
              "家人檔案：偏好逐人讀，讀不懂的那份原樣留著、存回去，其他人照讀")   // l10n-ignore：selftest 訊息
        let d2 = UserDefaults(suiteName: suite + ".mixed")!
        d2.removePersistentDomain(forName: suite + ".mixed")
        defer { d2.removePersistentDomain(forName: suite + ".mixed") }
        d2.set(mixedRaw, forKey: key)
        _ = migrate(defaults: d2, ownerID: "owner-1")
        let migrated = loadAll(d2.data(forKey: key))
        check(migrated.ok["kid"]?.look == "Sage" && migrated.ok["owner-1"] == ProfilePrefs() && migrated.unreadable["future"] != nil,
              "家人檔案：遷移時讀不懂的那份也不丟")   // l10n-ignore：selftest 訊息

        // 檔案切換隔離：孩子的 Look、清單、播放列表、主畫面只在他是目前這位時生效；主人與訪客看不到
        let kid = ProfilePrefs(look: "Sage", playlist: "Kid Mix", musicSource: .mac, remindersList: "list-kid")   // l10n-ignore：測試樣本
        let all = ["kid": kid, "owner-1": ProfilePrefs()]
        let asKid = memberPrefs(currentID: "kid", isOwner: false, prefs: all)
        let asOwner = memberPrefs(currentID: "owner-1", isOwner: true, prefs: all)
        let asGuest = memberPrefs(currentID: nil, isOwner: false, prefs: all)
        check(resolvedLook(member: asKid, global: "Mocha") == "Sage" && resolvedLook(member: asOwner, global: "Mocha") == "Mocha"
              && resolvedLook(member: asGuest, global: "Mocha") == "Mocha" && resolvedLook(member: memberPrefs(currentID: "lily", isOwner: false, prefs: all), global: "Mocha") == "Mocha",
              "家人檔案：Look 照目前這位家人（孩子 Sage；主人、訪客、沒選的家人跟著主人）")   // l10n-ignore：selftest 訊息
        check(memberUnlocks("reminders", member: asKid, remoteGuest: false) && !memberUnlocks("reminders", member: asOwner, remoteGuest: false)
              && !memberUnlocks("reminders", member: asGuest, remoteGuest: false) && !memberUnlocks("reminders", member: asKid, remoteGuest: true)
              && !memberUnlocks("messages", member: asKid, remoteGuest: false) && !memberUnlocks("calendar", member: asKid, remoteGuest: false),
              "家人檔案：家人只開自己的提醒事項清單；訊息、日曆照舊只給主人；訪客裝置在用時照舊鎖")   // l10n-ignore：selftest 訊息
        let i = PersonalGate.Inputs(hintIsOwner: false)
        check(PersonalGate.locks("messages", i) && PersonalGate.locks("calendar", i), "家人檔案：換成家人時，主人的訊息與日曆還是鎖著")   // l10n-ignore：selftest 訊息
        let savedSB = (SBStore.layouts, SBStore.persist)
        SBStore.persist = false
        var kidLayout = SBLayout.official
        kidLayout.pages[0].items.removeAll { $0 == .app("messages") }
        SBStore.layouts = ["kid": kidLayout, "owner-1": ownerLayout]
        let iso = SBStore.layout(for: "kid") == kidLayout && SBStore.layout(for: "owner-1") == ownerLayout && SBStore.layout(for: nil) == .official
        (SBStore.layouts, SBStore.persist) = savedSB
        check(iso, "家人檔案：主畫面排列各自一份（孩子沒有訊息、主人沒有 Podcast、訪客用官方預設）")   // l10n-ignore：selftest 訊息
        let savedPrefs = (prefs, persist)
        persist = false; prefs = all
        prune(keeping: ["owner-1"])
        let pruned = prefs.keys.sorted()
        (prefs, persist) = savedPrefs
        check(pruned == ["owner-1"], "家人檔案：名冊刪掉的人，那一份一起清")   // l10n-ignore：selftest 訊息

        // 說「我是 X」：整句就是這句、名字對得上才換；macOS 沒有聲紋 API，這只是自稱
        let people = [Person(id: "o", name: "Aaron Lau", colorIndex: 0, isOwner: true), Person(id: "k", name: "小明", colorIndex: 1, isOwner: false),   // l10n-ignore：測試樣本
                      Person(id: "m", name: "Marco", colorIndex: 2, isOwner: false)]   // l10n-ignore：測試樣本
        let hits = [("我是小明", "k"), ("我是小明啊。", "k"), ("換成 Marco", "m"), ("I'm Marco", "m"), ("this is aaron", "o"), ("我係小明", "k")]   // l10n-ignore：測試樣本
        let misses = ["我是谁", "小明今天几点放学", "我是说明天", "Marco 在哪", ""]   // l10n-ignore：測試樣本
        check(hits.allSatisfy { voiceTarget($0.0, people: people)?.id == $0.1 } && misses.allSatisfy { voiceTarget($0, people: people) == nil },
              "家人檔案：說「我是 X」只認整句、名字要在名冊裡（\(hits.filter { voiceTarget($0.0, people: people)?.id != $0.1 }.map(\.0)) \(misses.filter { voiceTarget($0, people: people) != nil })）")   // l10n-ignore：selftest 訊息
        check(NowPlayingSource.phoneFirst(phoneActive: true, macPlaying: true, pref: .iPhone) && !NowPlayingSource.phoneFirst(phoneActive: true, macPlaying: true, pref: .mac)
              && NowPlayingSource.phoneFirst(phoneActive: true, macPlaying: false, pref: .mac) && !NowPlayingSource.phoneFirst(phoneActive: false, macPlaying: true, pref: .iPhone),
              "家人檔案：音樂來源偏好（偏好 Mac 而 Mac 在播才先顯示 Mac，其餘照舊 iPhone 優先）")   // l10n-ignore：selftest 訊息
    }
}
