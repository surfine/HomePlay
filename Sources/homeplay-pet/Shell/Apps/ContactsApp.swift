// 通訊錄：用 Contacts 框架列出聯絡人（照系統的排序、依字首分組），點進去看電話與信箱，一鍵 FaceTime（視訊或語音）。
// FaceTime 交給既有的 FaceTimeApp／FaceTimeCall：這裡只把人與號碼準備好、打開 FaceTime 的撥號前畫面，撥不撥由你按綠色鈕決定。
// 個人內容：跟訊息、FaceTime 一樣鎖在「需要主人」後面（PersonalGate）；沒有通訊錄權限時說明並給開設定的路。
// 唯讀：不新增、不修改聯絡人。快照旗標：--demo-contacts [list|detail|perm]（假的名字與號碼，不讀真的通訊錄）

import AppKit
import Contacts

struct ContactCard: Equatable {
    struct Item: Equatable { var label: String; var value: String; var phone: Bool }
    var id: String
    var name: String
    var org: String
    var items: [Item]          // 電話在前、信箱在後
    var photo: Data?
    /// FaceTime 用哪一個：手機優先（ClioCallTools.bestHandle 的規則）
    var best: Item? {
        let h = ClioCallTools.bestHandle(phones: items.filter(\.phone).map { (label: $0.label, value: $0.value) }, emails: items.filter { !$0.phone }.map(\.value))
        return items.first { $0.value == h }
    }
    func faceTime(_ item: Item? = nil) -> FaceTimeContact? {
        guard let it = item ?? best else { return nil }
        return FaceTimeContact(id: id, name: name, handle: it.value, label: it.label, photo: photo)
    }
}

enum ContactsBook {
    static var status: CNAuthorizationStatus { CNContactStore.authorizationStatus(for: .contacts) }

    /// 整本列出來（背景執行緒叫）：有名字的人都列（沒電話也列，只是不能 FaceTime）
    static func load() -> [ContactCard] {
        guard status == .authorized else { return [] }
        let keys: [CNKeyDescriptor] = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
                                       CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactThumbnailImageDataKey] as [CNKeyDescriptor]
        var out: [ContactCard] = []
        let req = CNContactFetchRequest(keysToFetch: keys)
        req.sortOrder = .userDefault
        try? CNContactStore().enumerateContacts(with: req) { c, _ in
            let name = ClioCallTools.displayName(c)
            guard !name.isEmpty else { return }
            func label(_ l: String?) -> String { l.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? "" }
            let items = c.phoneNumbers.map { ContactCard.Item(label: label($0.label), value: $0.value.stringValue, phone: true) }
                + c.emailAddresses.map { ContactCard.Item(label: label($0.label), value: $0.value as String, phone: false) }
            out.append(ContactCard(id: c.identifier, name: name, org: name == c.organizationName ? "" : c.organizationName, items: items, photo: c.thumbnailImageData))
        }
        return out
    }

    /// 分組的字首：拉丁字母取第一個字母，中日韓字轉拼音取第一個字母，其他歸「#」（純函數）
    static func section(_ name: String) -> String {
        let latin = name.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? name
        guard let ch = latin.trimmingCharacters(in: .whitespaces).first, ch.isASCII, ch.isLetter else { return "#" }
        return String(ch).uppercased()
    }
    /// 照原本的順序分組（同一個字首連在一起的才同一組）
    static func grouped(_ list: [ContactCard]) -> [(String, [ContactCard])] {
        var out: [(String, [ContactCard])] = []
        for c in list {
            let s = section(c.name)
            if out.last?.0 == s { out[out.count - 1].1.append(c) } else { out.append((s, [c])) }
        }
        return out
    }
}

final class ContactsApp: PetApp {
    static let shared = ContactsApp()
    let id = "contacts"
    var title: String { L("app.contacts", "通讯录") }
    let icon = AppIcon(color: srgb(0x8E8E93), symbol: "person.crop.circle.fill", system: "/System/Applications/Contacts.app")

    private weak var face: Face?
    private var contacts: [ContactCard] = []
    private var loaded = false
    private var loading = false
    private var demo: String?
    private var detail: ContactCard?
    private var scroll = AppScroll()
    private var contentHeight: CGFloat = 0
    private var rowHits: [(CGRect, ContactCard)] = []
    private var itemHits: [(CGRect, ContactCard.Item)] = []
    private var permissionButton = CGRect.zero
    private var videoButton = CGRect.zero, audioButton = CGRect.zero

    private static let rowH: CGFloat = 112, avatar: CGFloat = 72, sectionH: CGFloat = 64

    private init() {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--demo-contacts") {
            demo = i + 1 < a.count && !a[i + 1].hasPrefix("--") ? a[i + 1] : "list"
        } else if SnapshotPrivacy.active { demo = "list" }   // 快照：不讀真的通訊錄
        if demo != nil { contacts = Self.demoContacts; loaded = true }
        if demo == "detail" { detail = contacts.first }
    }

    static let demoContacts: [ContactCard] = [
        ContactCard(id: "d1", name: "Alex Chen", org: "", items: [.init(label: "mobile", value: "+1 415 555 0134", phone: true), .init(label: "home", value: "alex@example.com", phone: false)], photo: nil),   // l10n-ignore：示範
        ContactCard(id: "d2", name: "Jordan Lee", org: "Northwind", items: [.init(label: "iPhone", value: "+1 415 555 0178", phone: true)], photo: nil),   // l10n-ignore
        ContactCard(id: "d3", name: "Mari Tanaka", org: "", items: [.init(label: "iCloud", value: "mari@example.com", phone: false)], photo: nil),       // l10n-ignore
        ContactCard(id: "d4", name: "Priya Patel", org: "", items: [.init(label: "mobile", value: "+1 415 555 0101", phone: true), .init(label: "work", value: "+1 415 555 0102", phone: true)], photo: nil),   // l10n-ignore
        ContactCard(id: "d5", name: "Sam Rivera", org: "", items: [], photo: nil),                                                                        // l10n-ignore
        ContactCard(id: "d6", name: "Taylor Kim", org: "Contoso", items: [.init(label: "work", value: "+1 415 555 0199", phone: true)], photo: nil),     // l10n-ignore
    ]

    // MARK: 外殼

    var backSymbol: String { detail == nil ? "xmark" : "chevron.left" }
    func handleBack(now: Double) -> Bool {
        guard detail != nil else { return false }
        detail = nil; return true
    }
    func didOpen(now: Double) {
        scroll = AppScroll()
        if demo == nil { detail = nil; reload() }
    }
    /// 主人走開了（PersonalGate 換成鎖畫面）：下次打開回到列表，不留著某個人的卡片
    func didClose() { if demo == nil { detail = nil } }
    func tick(_ now: Double) -> Bool { HPComponents.needsFrame(now) }

    private func reload() {
        guard ContactsBook.status == .authorized, !loading else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let list = ContactsBook.load()
            DispatchQueue.main.async { self?.contacts = list; self?.loaded = true; self?.loading = false; self?.face?.forceDirty = true }
        }
    }

    // MARK: 畫

    func render(into g: CGContext, face: Face, rect: CGRect, now: Double) {
        self.face = face
        g.setFillColor(AppUI.bg.cgColor); g.fill(rect)
        rowHits = []; itemHits = []; permissionButton = .zero; videoButton = .zero; audioButton = .zero
        // 外殼已經會在門關著時畫「需要主人」；這裡再擋一次（直接被叫到也不畫內容）
        if AppUI.personalLocked || !PersonalGate.allowed { AppUI.title(g, face, title); AppUI.drawLock(g, face, title: title); return }
        if demo == "perm" || (demo == nil && ContactsBook.status != .authorized) {
            AppUI.title(g, face, title)
            let denied = demo == nil && (ContactsBook.status != .notDetermined || !FaceTimeContacts.canAsk)
            permissionButton = AppUI.drawPermission(g, face, appTitle: title, symbol: "person.crop.circle.fill", tint: AppUI.blue,
                headline: denied ? L("facetime.perm.denied", "通讯录没有开放") : L("facetime.perm.title", "需要读取通讯录"),
                body: denied ? L("contacts.perm.deniedBody", "到系统设置的「隐私与安全性 › 通讯录」里允许 HomePlay，才能在这里看到联系人")
                             : L("contacts.perm.body", "只在这台 Mac 上读取，用来列出联系人和打 FaceTime；不会修改"),
                button: denied ? L("perm.openSettings", "打开系统设置") : L("facetime.perm.button", "允许读取通讯录"))
            return
        }
        if let d = detail { drawDetail(g, face, d); return }
        drawList(g, face)
    }

    private func drawList(_ g: CGContext, _ face: Face) {
        let x0 = AppUI.margin, w = AppUI.contentW
        var y = HPTokens.contentTop - scroll.offset
        if contacts.isEmpty {
            let msg = loaded ? L("contacts.empty", "通讯录里还没有联系人") : L("music.lib.loading", "读取中…")
            AppUI.center(face, g, msg, AppUI.font(34), cx: 512, y: 520, AppUI.secondary)
        }
        for (sec, list) in ContactsBook.grouped(contacts) {
            AppUI.header(g, face, sec, y: y + 44)
            y += Self.sectionH
            let card = CGRect(x: x0, y: y, width: w, height: CGFloat(list.count) * Self.rowH)
            if card.maxY > AppUI.topEdge - 60, card.minY < 1024 {
                AppUI.group(g, card)
                for (k, c) in list.enumerated() {
                    let row = CGRect(x: x0, y: y + CGFloat(k) * Self.rowH, width: w, height: Self.rowH)
                    guard row.maxY > AppUI.topEdge - 60, row.minY < 1024 else { continue }
                    if Press.amount(row) > 0.01 { g.setFillColor(AppUI.label.withAlphaComponent(0.06 * Press.amount(row)).cgColor); g.fill(row) }
                    let av = CGRect(x: row.minX + 28, y: row.midY - Self.avatar / 2, width: Self.avatar, height: Self.avatar)
                    FaceTimeApp.drawAvatar(g, face, av, name: c.name, photo: c.photo)
                    let tx = av.maxX + 28, tw = row.maxX - 80 - tx
                    let nf = AppUI.font(HPType.Size.list, .regular)
                    let sub = c.org.isEmpty ? (c.best?.label ?? "") : c.org
                    face.drawLeft(g, Face.clipped(c.name, nf, tw), font: nf, x: tx, y: sub.isEmpty ? row.midY + nf.capHeight / 2 : row.midY - 4, color: AppUI.label)
                    if !sub.isEmpty { face.drawLeft(g, Face.clipped(sub, AppUI.font(HPType.Size.secondary), tw), font: AppUI.font(HPType.Size.secondary), x: tx, y: row.midY + 36, color: AppUI.secondary) }
                    AppUI.chevron(g, face, rightX: row.maxX - 32, midY: row.midY)
                    if k < list.count - 1 { AppUI.separator(g, x: tx, maxX: row.maxX, y: row.maxY) }
                    rowHits.append((row, c))
                    HPAX.note(g, row, .button, c.name, value: sub.isEmpty ? nil : sub, shape: .rounded(0))
                }
            }
            y += card.height + 24
        }
        contentHeight = y + scroll.offset + 40
        g.setFillColor(AppUI.bg.cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: AppUI.topEdge - 40))
        HPComponents.topFade(g, AppUI.bg, solidTo: AppUI.topEdge - 40)
        AppUI.title(g, face, title)
    }

    private func drawDetail(_ g: CGContext, _ face: Face, _ c: ContactCard) {
        let av = CGRect(x: 512 - 96, y: 168, width: 192, height: 192)
        FaceTimeApp.drawAvatar(g, face, av, name: c.name, photo: c.photo)
        let nf = AppUI.fitted(c.name, size: 56, weight: .bold, maxWidth: 840)
        AppUI.center(face, g, c.name, nf, cx: 512, y: 432, AppUI.label)
        if !c.org.isEmpty { AppUI.center(face, g, Face.clipped(c.org, AppUI.font(32), 840), AppUI.font(32), cx: 512, y: 480, AppUI.secondary) }
        // 兩顆大按鈕：FaceTime 視訊、語音（沒有號碼或信箱就灰掉）
        let can = c.best != nil
        let bw: CGFloat = 400, by: CGFloat = 520, bh = HPTokens.Size.pill
        let green = HPTokens.FaceTime.callGreen
        videoButton = AppUI.button(g, face, CGRect(x: 512 - bw - 12, y: by, width: bw, height: bh), L("facetime.video", "FaceTime 视频"),
                                   fill: can ? green : nil, ink: can ? .white : AppUI.tertiary)
        audioButton = AppUI.button(g, face, CGRect(x: 512 + 12, y: by, width: bw, height: bh), L("facetime.audio", "FaceTime 语音"),
                                   fill: nil, ink: can ? green : AppUI.tertiary)
        if !can { videoButton = .zero; audioButton = .zero }
        // 電話與信箱：點一列＝用那一個號碼打 FaceTime
        var y = by + bh + 40
        if c.items.isEmpty {
            AppUI.center(face, g, L("contacts.noHandles", "没有电话或电子邮件"), AppUI.font(32), cx: 512, y: y + 60, AppUI.secondary)
            return
        }
        let rowH: CGFloat = 112, x0 = AppUI.margin, w = AppUI.contentW
        let card = CGRect(x: x0, y: y, width: w, height: CGFloat(c.items.count) * rowH)
        AppUI.group(g, card)
        for (k, it) in c.items.enumerated() {
            let row = CGRect(x: x0, y: y, width: w, height: rowH)
            guard row.minY < 1024 else { break }
            if Press.amount(row) > 0.01 { g.setFillColor(AppUI.label.withAlphaComponent(0.06 * Press.amount(row)).cgColor); g.fill(row) }
            let lf = AppUI.font(HPType.Size.secondary), vf = AppUI.font(HPType.Size.list)
            face.drawLeft(g, it.label.isEmpty ? (it.phone ? L("contacts.phone", "电话") : L("contacts.email", "电子邮件")) : it.label, font: lf, x: row.minX + 36, y: row.minY + 44, color: AppUI.secondary)
            face.drawLeft(g, Face.clippedMiddle(it.value, vf, w - 180), font: vf, x: row.minX + 36, y: row.minY + 88, color: AppUI.label)
            face.drawSymbol(g, "video.fill", in: CGRect(x: row.maxX - 96, y: row.midY - 24, width: 60, height: 48), color: green, weight: .regular)
            if k < c.items.count - 1 { AppUI.separator(g, x: row.minX + 36, maxX: row.maxX, y: row.maxY) }
            itemHits.append((row, it))
            HPAX.note(g, row, .button, it.value, value: it.label, shape: .rounded(0))
            y += rowH
        }
    }

    // MARK: 輸入

    func handleScroll(_ dy: CGFloat, now: Double) -> Bool {
        guard detail == nil else { return false }
        return scroll.scroll(dy * 1.6, contentHeight: contentHeight, viewport: 1024)
    }

    func handleTap(_ p: CGPoint, face: Face, now: Double) -> Bool {
        self.face = face
        if AppUI.personalLocked || !PersonalGate.allowed { return false }
        if permissionButton != .zero, AppUI.hit(permissionButton, p) {
            if demo != nil { return true }
            if ContactsBook.status == .notDetermined, FaceTimeContacts.canAsk {
                MessagesContacts.shared.requestAccess { [weak self] _ in self?.reload(); self?.face?.forceDirty = true }
            } else {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")!)
            }
            return true
        }
        if let d = detail {
            if videoButton != .zero, AppUI.hit(videoButton, p) { call(d, nil, video: true); return true }
            if audioButton != .zero, AppUI.hit(audioButton, p) { call(d, nil, video: false); return true }
            for (r, it) in itemHits where r.contains(p) { call(d, it, video: true); return true }
            return false
        }
        guard p.y > AppUI.topEdge - 40 else { return false }
        for (r, c) in rowHits where r.contains(p) { detail = c; return true }
        return false
    }

    /// 一鍵 FaceTime：把人與號碼交給 FaceTimeCall，打開 FaceTime 的撥號前畫面（綠色鈕由你按，才真的撥）
    private func call(_ c: ContactCard, _ item: ContactCard.Item?, video: Bool) {
        guard let ft = c.faceTime(item) else { return }
        FaceTimeCall.shared.prepare(ft, video: video)
        if demo != nil { FaceTimeCall.shared.demoElapsed = 0 }
        MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.view?.shellOpenApp("facetime") }
    }
}

enum ContactsSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        check(ContactsBook.section("Alex") == "A" && ContactsBook.section("émile") == "E" && ContactsBook.section("王小明") == "W" && ContactsBook.section("123") == "#",   // l10n-ignore：自檢
              "通訊錄：字首（拉丁、去重音、中文轉拼音、其他歸 #）")   // l10n-ignore
        let g = ContactsBook.grouped(ContactsApp.demoContacts)
        check(g.map(\.0) == ["A", "J", "M", "P", "S", "T"] && g.allSatisfy { $0.1.count == 1 }, "通訊錄：照順序依字首分組")
        let priya = ContactsApp.demoContacts[3], mari = ContactsApp.demoContacts[2], sam = ContactsApp.demoContacts[4]
        check(priya.best?.value == "+1 415 555 0101" && mari.best?.value == "mari@example.com" && sam.best == nil, "通訊錄：FaceTime 先用手機，沒有電話用信箱，都沒有就不能打")
        check(priya.faceTime(priya.items[1])?.handle == "+1 415 555 0102" && priya.faceTime()?.name == "Priya Patel", "通訊錄：點哪一個號碼就用那一個")
        check(PersonalGate.personalApps.contains("contacts") && !PersonalGate.allowed(PersonalGate.Inputs(guestMode: true)), "通訊錄：個人內容，訪客看不到")
    }
}
