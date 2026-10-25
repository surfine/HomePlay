// 2.0 個人內容的門：訪客模式、「認出誰在看」與主畫面頭像（稿：hv-design/project/Personal.dc.html）。
//
// 個人內容（下一個行程小工具、日曆、提醒事項、訊息、ClioTalk 讀個人資料的工具）只給這台 Mac 的主人：
// - 控制中心的「訪客模式」開著：一律關門；
// - 「認出誰在看」開著（而且至少有人錄過臉）：照 WhoIsLooking 的門——眼前是主人才開，沒人、認不出、家人都關；
// - 沒開認人：當作主人在用；「換人」選了別人只會把門關上（提示只能更嚴，不能替誰開門）。
// 每個用到的人都問 PersonalGate.allowed（主執行緒）；ClioTalk 的引擎在背景，讀每幀更新的 PersonalGate.cached。

import AppKit
import Contacts

enum PersonalGate {
    /// 鎖在「需要主人」後面的 App
    static let personalApps: Set<String> = ["calendar", "reminders", "messages", "facetime", "findmy"]   // FaceTime 的聯絡人與最近通話也是個人內容；2.0 depth：尋找有這台 Mac 的名字與主人的大概位置

    /// 「換人」選的人（只是提示）；nil＝沒選。遠距回錶面時清掉
    nonisolated(unsafe) static var hint: String?
    /// 背景執行緒讀這個（shellStep 每幀更新）
    nonisolated(unsafe) static var cached = true

    struct Inputs: Equatable {
        var guestMode = false
        var recognitionActive = false      // 認人開著、而且有人錄過臉
        var viewer: Viewer = .nobody
        var contradictsOwner = false
        var requirePhone = false
        var phonePresent: Bool?
        var hintIsOwner: Bool?             // 「換人」選的是不是主人；nil＝沒選
        var remoteGuest = false            // 2.0 idle: 訪客的 iPhone／iPad 一分鐘內點過（Remote/RemoteInput.swift）
    }

    /// 「需要主人」鎖定頁下面那句說明的判定（純函數，selftest 直接測）。
    /// P09：眼前是認出的家人時，明白寫「個人內容只開給這台 Mac 的主人」——家人等不到「認出主人」，不要再叫家人盯著螢幕。
    enum LockReason { case guestMode, remoteGuest, followOff, family, look, hint }

    static func lockReason(_ i: Inputs, followOn: Bool) -> LockReason {
        if i.guestMode { return .guestMode }
        if i.remoteGuest { return .remoteGuest }
        if i.recognitionActive && !followOn { return .followOff }
        if i.recognitionActive {
            if case .known = i.viewer { return .family }
            return .look
        }
        return .hint
    }

    /// 真值表（純函數，selftest 直接測）
    static func allowed(_ i: Inputs) -> Bool {
        if i.guestMode || i.remoteGuest { return false }
        if i.recognitionActive {
            return WhoIsLooking.gate(viewer: i.viewer, contradictsOwner: i.contradictsOwner, requirePhone: i.requirePhone, phonePresent: i.phonePresent)
        }
        return i.hintIsOwner ?? true
    }

    /// 2.0：共享相簿的觀眾（主人＝全部、家人＝只有共享相簿、其他＝都不給）
    enum Audience: Equatable { case owner, family, none }

    /// 觀眾真值表（純函數）：訪客模式一律 none；認人開著＝主人照 allowed 的門、登記的家人 family、其他（認不出、沒人）none；
    /// 沒開認人＝主人照舊，「換人」選了家人就只給家人（提示只能更嚴）
    static func audience(_ i: Inputs, hintIsFamily: Bool = false) -> Audience {
        if i.guestMode || i.remoteGuest { return .none }   // 2.0 idle: 訪客裝置在用：相片小工具不給主人的圖庫
        if i.recognitionActive {
            if allowed(i) { return .owner }
            if case .known = i.viewer { return .family }
            return .none
        }
        if i.hintIsOwner == false { return hintIsFamily ? .family : .none }
        return .owner
    }
    nonisolated(unsafe) static var cachedAudience = Audience.owner

    static var audience: Audience { audience(inputs, hintIsFamily: hint != nil && PeopleRegistry.shared.person(hint!) != nil) }

    static var recognitionActive: Bool { WhoIsLooking.recognitionEnabled && WhoIsLooking.shared.hasReferences }

    /// 快照：--looking owner|family|guest|nobody 模擬「認出誰在看」（P09：鎖定頁要家人入鏡才拍得到）。
    /// id 故意用名冊裡不存在的：快照讀不到真名（頭像與問候語會當成訪客，SnapshotPrivacy 的立場）。
    nonisolated(unsafe) static var viewerOverride: Viewer? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--looking"), i + 1 < a.count else { return nil }
        switch a[i + 1] {
        case "owner": return .owner("snapshot-owner")
        case "family": return .known("snapshot-family")
        case "guest": return .guest
        case "nobody": return .nobody
        default: return nil
        }
    }()

    static var inputs: Inputs {
        let w = WhoIsLooking.shared
        let v = viewerOverride
        return Inputs(guestMode: Shell.guestMode, recognitionActive: v != nil || recognitionActive, viewer: v ?? w.viewer, contradictsOwner: w.contradictsOwner,
                      requirePhone: WhoIsLooking.requireOwnerPhone, phonePresent: w.phonePresence?(),
                      hintIsOwner: hint.map { h in PeopleRegistry.shared.person(h)?.isOwner ?? true }, remoteGuest: RemotePrivacy.guestActive)
    }

    /// 主執行緒用
    static var allowed: Bool { allowed(inputs) }

    static func locks(_ appID: String) -> Bool { locks(appID, inputs) || AppProviders.locks(appID) }   // 2.0 Web App：照提供者自己的門
    /// 純函數：個人 App 門關著就鎖；2.0 idle: 訪客裝置在用時，允許清單外的 App（家庭、尋找…）也鎖（Remote/RemoteInput.swift）
    static func locks(_ appID: String, _ i: Inputs) -> Bool {
        (personalApps.contains(appID) && !allowed(i)) || (i.remoteGuest && RemotePrivacy.guestLocks(appID))
    }

    /// 主畫面右上的頭像：誰在看（沒開認人＝主人；換人提示只在沒開認人時顯示）；nil＝訪客
    static func avatarPerson(_ i: Inputs, people: [Person], owner: Person?) -> Person? {
        if i.guestMode || i.remoteGuest { return nil }   // 2.0 idle: 訪客裝置在用：不畫主人的頭像
        if i.recognitionActive {
            guard let id = i.viewer.personID else { return nil }
            return people.first { $0.id == id }
        }
        if let h = hint, let p = people.first(where: { $0.id == h }) { return p }
        return owner
    }
}

// MARK: - 畫：頭像、「換人」、「需要主人」

extension Shell {
    /// 「換人」小卡開著
    nonisolated(unsafe) static var peopleSheet = false
    nonisolated(unsafe) static var peopleSheetRows: [(String, CGRect)] = []
    /// 2.0 R4：直徑 96（影片 v1 0:45 右上 Memoji 圓：右距約 90、跟問候語兩行的中線齊）
    static let avatarRect = CGRect(x: 1024 - 150 - HPTokens.Home.avatar / 2, y: 152 - HPTokens.Home.avatar / 2, width: HPTokens.Home.avatar, height: HPTokens.Home.avatar)   // 第三輪：直徑 100，中心照舊 (874, 152)
    /// 卡片貼著人數長高；左右離螢幕 72，圓角跟螢幕同心
    static var sheetCard: CGRect {
        let n = CGFloat(min(4, max(1, PeopleRegistry.shared.people.count)))
        let h = 130 + n * 108 + 96
        return CGRect(x: 72, y: max(170, 540 - h / 2), width: 1024 - 144, height: h)
    }
}

/// 2.0 R4：Contacts 裡「我」的照片（只在已經允許讀聯絡人時讀，不為了頭像跳權限框）；背景讀一次、快取
enum MeCard {
    nonisolated(unsafe) static var photo: CGImage?
    nonisolated(unsafe) private static var asked = false
    static func load(_ done: @escaping () -> Void) {
        guard !asked, !AccountPicture.blocked else { return }   // 第五輪：快照不讀真的照片
        asked = true
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return }
        DispatchQueue.global(qos: .utility).async {
            let keys = [CNContactThumbnailImageDataKey, CNContactImageDataKey] as [CNKeyDescriptor]
            guard let me = try? CNContactStore().unifiedMeContactWithKeys(toFetch: keys),
                  let data = me.thumbnailImageData ?? me.imageData,
                  let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
            DispatchQueue.main.async { photo = img; done() }
        }
    }
}

extension Face {
    /// 主畫面右上的頭像：誰在看（第五輪：帳號頭像 → 聯絡人「我」→ 灰色縮寫；選了 👀 才是 👀 人物）。
    /// 官方的頭像沒有白色描邊（量到右緣外直接是背景），只畫圓形裁切
    func drawShellAvatar(_ g: CGContext) {
        let av = Shell.avatarRect
        let reg = PeopleRegistry.shared
        if let p = Shell.demoPerson ?? PersonalGate.avatarPerson(PersonalGate.inputs, people: reg.people, owner: reg.owner) {
            drawPersonAvatar(g, p, in: av)
        } else {
            // 訪客：灰底、人形
            g.setFillColor(NSColor(white: 1, alpha: 0.28).cgColor); g.fillEllipse(in: av)
            drawSymbol(g, "person.fill", in: av.insetBy(dx: 25, dy: 25), color: .white)
        }
    }

    /// 主畫面的「下一個行程」在訪客時：只畫鎖與一句話
    func drawGuestUpNext(_ g: CGContext, _ r: CGRect) {
        drawSymbol(g, "lock.fill", in: CGRect(x: r.minX + 34, y: r.minY + 36, width: 34, height: 40), color: NSColor.white.withAlphaComponent(0.78))
        drawLeft(g, L("guest.title", "访客模式"), font: FaceType.sf(28, .bold, mono: false), x: r.minX + 80, y: r.minY + 66, color: NSColor.white.withAlphaComponent(0.78))
        let bf = FaceType.sf(36, .bold, mono: false)
        drawLeft(g, Face.clipped(L("guest.upNextHidden", "行程已隐藏"), bf, r.width - 68), font: bf, x: r.minX + 34, y: r.minY + 124, color: .white)
    }

    /// 鎖住的個人 App：深色底＋大圖示＋「需要主人」
    /// 10-grid：垂直節奏——圖示 236…436，標題基線 436＋96、原因基線再＋64（HPGrid.scale）
    static let lockIconY: CGFloat = 236
    static var lockTitleY: CGFloat { 436 + 96 }
    static var lockWhyY: CGFloat { 436 + 96 + 64 }

    func drawPersonalLock(_ g: CGContext, app: PetApp) {
        g.setFillColor(srgb(0x0b0b0e).cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let ir = CGRect(x: 512 - 100, y: Self.lockIconY, width: 200, height: 200)
        Shell.drawAppIcon(g, face: self, icon: app.icon, in: ir, appID: app.id)
        let lock = CGRect(x: ir.maxX - 58, y: ir.maxY - 58, width: 76, height: 76)
        g.setFillColor(srgb(0x1c1c1e).cgColor); g.fillEllipse(in: lock)
        drawSymbol(g, "lock.fill", in: lock.insetBy(dx: 20, dy: 18), color: .white)
        drawCentered(g, L("guest.needsOwner", "需要主人"), font: Face.rounded(64, weight: .bold), y: Self.lockTitleY, color: .white)
        let why: String
        switch PersonalGate.lockReason(PersonalGate.inputs, followOn: ControlCenter.followOn) {
        case .guestMode: why = L("guest.why.mode", "访客模式开着；在控制中心关掉")
        case .remoteGuest: why = L("guest.why.remote", "访客的 iPhone／iPad 正在用 HomePlay")   // 2.0 idle
        case .followOff: why = L("guest.why.follow", "打开「跟随我」，让 HomePlay 认出你")
        case .family: why = L("guest.why.family", "个人内容只开给这台 Mac 的主人")   // P09：家人有自己的一份主畫面，個人內容不屬於家人
        case .look: why = L("guest.why.look", "看着屏幕，认出主人后打开")
        case .hint: why = L("guest.why.hint", "「换人」选的不是主人")
        }
        let f = Face.fitted(why, size: 36, weight: .semibold, maxWidth: 820, minScale: 0.7)
        drawCentered(g, why, font: f, y: Self.lockWhyY, color: NSColor.white.withAlphaComponent(0.6))
        // 2.0 depth：VoiceOver——鎖卡的標題與原因
        HPAX.note(g, CGRect(x: 112, y: 510, width: 800, height: 160), .text, L("guest.needsOwner", "需要主人"), value: why, shape: .rounded(24))
    }

    /// 「換人」：列出登記的人（點了只是提示，認人開著時由認人決定）
    func drawPeopleSheet(_ g: CGContext) {
        // 動效包：sheet 從下緣升起、底下跟著壓暗；收起時沿原路下去（半路反悔從當下接著走）；減少動態效果時只淡入淡出
        let shown = HPPresence.value("sheet.people", shown: Shell.peopleSheet, HPMotion.T.sheet)
        guard shown > 0.001 else { Shell.peopleSheetRows = []; return }
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        g.saveGState(); defer { g.restoreGState() }
        g.setFillColor(NSColor.black.withAlphaComponent(0.45 * shown).cgColor); g.fill(full)
        if HPMotion.reduceMotion { g.setAlpha(shown) } else { g.translateBy(x: 0, y: (1 - shown) * (1024 - Shell.sheetCard.minY)) }
        let card = Shell.sheetCard
        let radius = Screen.concentric(inset: card.minX)
        if !ShellGlass.draw(g, face: self, path: continuousRoundedRect(card, radius: radius), key: "people|\(PeopleRegistry.shared.people.count)") {
            g.addPath(continuousRoundedRect(card, radius: radius)); g.setFillColor(srgb(0x2c2c30, 0.96).cgColor); g.fillPath()
        }
        drawLeft(g, L("people.switch.title", "换人"), font: FaceType.sf(48, .bold, mono: false), x: card.minX + 56, y: card.minY + 92, color: .white)
        let reg = PeopleRegistry.shared
        let current = PersonalGate.avatarPerson(PersonalGate.inputs, people: reg.people, owner: reg.owner)
        var rows: [(String, CGRect)] = []
        var y = card.minY + 130
        for p in reg.people.prefix(4) {
            let r = CGRect(x: card.minX + 32, y: y, width: card.width - 64, height: 100)
            let av = CGRect(x: r.minX + 24, y: r.midY - 36, width: 72, height: 72)
            drawPersonAvatar(g, p, in: av)   // 第四輪：👀 人物頭像（Design/HPAvatar.swift）
            let nf = FaceType.sf(40, .semibold, mono: false)
            let name = p.isOwner ? String(format: L("people.switch.owner", "%@（主人）"), p.name) : p.name
            drawLeft(g, Face.clipped(name, nf, r.width - 220), font: nf, x: av.maxX + 28, y: r.midY + 14, color: .white)
            if current?.id == p.id { drawSymbol(g, "checkmark", in: CGRect(x: r.maxX - 76, y: r.midY - 22, width: 44, height: 44), color: srgb(0x0a84ff)) }
            rows.append((p.id, r))
            y += 108
        }
        let note = PersonalGate.recognitionActive ? L("people.switch.noteRecognize", "由「认出谁在看」决定；这里只是提示")
                                                  : L("people.switch.note", "只是提示：选别人会先收起个人内容")
        let nf = Face.fitted(note, size: 30, weight: .medium, maxWidth: card.width - 112, minScale: 0.7)
        drawLeft(g, note, font: nf, x: card.minX + 56, y: card.maxY - 52, color: NSColor.white.withAlphaComponent(0.6))
        Shell.peopleSheetRows = rows
    }
}

// MARK: - 控制層的液態玻璃（跟控制中心、主畫面小工具同一套 SystemGlass），算好的結果照 key 重用

enum ShellGlass {
    /// path：1024 座標；底圖拍目前畫布（呼叫端先畫好底下的東西）。
    /// 2.0 iosglass：跟其他控制同一套 iOS 玻璃（HPGlass，Regular——卡片與提示不是媒體上的控制；原本自拼 NSGlassEffectView .clear 的參數）；結果照背景快取在 HPGlass。
    /// App 變形過場中（畫布被縮放）不畫，回 false 讓呼叫端用半透明白退回。key 不再用（快取照背景與形狀）
    @discardableResult
    static func draw(_ g: CGContext, face: Face, path: CGPath, key: String, backdrop: CGImage? = nil) -> Bool {
        guard Shell.appMorph == nil else { return false }
        HPGlass.drawNow(g, face: face, [path], clear: false, backdrop: backdrop)
        return true
    }

    /// 純黑底（訊息 App 的控制都在黑底上）：一張就夠
    nonisolated(unsafe) private static var blackImage: CGImage?
    static var black: CGImage {
        if let b = blackImage { return b }
        let b = makeImage(256, 256) { g in g.setFillColor(NSColor.black.cgColor); g.fill(CGRect(x: 0, y: 0, width: 256, height: 256)) }
        blackImage = b
        return b
    }
}
