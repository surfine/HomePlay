// 2.0 第四輪 #10：FaceTime App。兩頁：
// - 名單：最近通話（從 HomePlay 撥出的）＋通訊錄裡有電話或信箱的人；上面一條搜尋（實體鍵盤或聽寫，沒有螢幕鍵盤）。
// - 通話畫面（照官方 lineup5.png 第二台，透視校正後量）：滿版畫面、左上名字、底下一排四顆 156 的玻璃圓鈕
//   （白底綠攝影機、白底橘麥克風、玻璃「…」、紅 ✕）。撥出前右下是綠色撥號鈕（你自己按才撥）；撥出後換成紅 ✕。
//   撥出前：滿版自己的鏡頭（已授權才開，否則對方頭像糊成底）；通話中：對方頭像糊成底（我們拿不到對方的畫面）＋右上自己的小窗。
// 通話本體交給「FaceTime」（見 FaceTimeCall.swift）。

import AppKit
import SwiftUI

final class FaceTimeApp: PetApp {
    static let shared = FaceTimeApp()
    let id = "facetime"
    var title: String { "FaceTime" }   // l10n-ignore：App 名稱三種語言都叫 FaceTime
    // 圖示：外殼的 HPIcons 以 "facetime" 自畫（合併前先用綠底白攝影機當佔位）
    let icon = AppIcon(color: srgb(0x34C759), symbol: "video.fill")

    private weak var face: Face?
    private var contacts: [FaceTimeContact] = []
    private var loaded = false
    private var loading = false
    private var query = ""
    private var scroll: CGFloat = 0
    private var maxScroll: CGFloat = 0
    private var permissionButton = CGRect.zero
    private var rowHits: [(CGRect, FaceTimeContact, Bool)] = []    // (框, 人, 視訊)
    private let input = FaceTimeSearchModel()
    private var popover: NSPopover?
    private var demo: String?
    private var lastSecond = -1

    private init() {
        FaceTimeMic.restoreIfNeeded()   // 上次是我們靜音的（例如當掉）就還原
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            if FaceTimeMic.mutedByUs { FaceTimeMic.setMuted(false) }
        }
        FaceTimeCall.shared.onChange = { [weak self] in self?.face?.forceDirty = true }
        FaceTimeCamera.shared.onFrame = { [weak self] in
            guard let self, Shell.currentApp === self else { return }
            self.face?.forceDirty = true
        }
        applyDemoFlag()
    }

    private var call: FaceTimeCall { FaceTimeCall.shared }
    private var onCallScreen: Bool { call.phase != .idle }

    var showsCloseButton: Bool { !onCallScreen || call.phase == .preDial }
    var showsClock: Bool { !onCallScreen }
    var backSymbol: String { call.phase == .preDial ? "chevron.left" : "xmark" }
    func handleBack(now: Double) -> Bool {
        guard call.phase == .preDial else { return false }
        call.end(); return true
    }

    /// 2.0 depth：離開 App 就關自拍相機；還在撥號前那一頁就當作取消（不留著舊的聯絡人）
    func didClose() {
        FaceTimeCamera.shared.stop()
        if call.phase == .preDial { call.end() }
    }

    func didOpen(now: Double) {
        scroll = 0
        if !loaded { reload() }
    }

    func tick(_ now: Double) -> Bool {
        if HPComponents.needsFrame(now) { return true }
        if call.active { let s = Int(FaceTimeCall.wall); if s != lastSecond { lastSecond = s; return true } }
        return false
    }

    func liveActivity(face: Face, now: Double) -> LiveActivity? {
        guard call.active, let c = call.contact, Shell.currentApp !== self else { return nil }
        let detail = call.phase == .connected || call.demoElapsed != nil ? NowPlayingPage.clock(call.elapsed) : L("facetime.calling", "正在呼叫…")
        // 2.0 depth：沒認出主人時膠囊上不寫是誰（跟訊息的 Live Activity 一樣）
        return LiveActivity(kind: .call, title: PersonalGate.allowed ? c.name : title, detail: detail, accent: HPTokens.FaceTime.callGreen, progress: nil, appID: id,
                            symbol: call.video ? "video.fill" : "phone.fill")
    }

    // MARK: 資料

    private func reload() {
        if demo != nil { contacts = Self.demoContacts; loaded = true; return }
        guard FaceTimeContacts.status == .authorized, !loading else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let list = FaceTimeContacts.load()
            DispatchQueue.main.async { self?.contacts = list; self?.loaded = true; self?.loading = false; self?.face?.forceDirty = true }
        }
    }

    static let demoContacts: [FaceTimeContact] = [
        FaceTimeContact(id: "d1", name: "Mari", handle: "mari@example.com", label: "iCloud", photo: nil),            // l10n-ignore：示範
        FaceTimeContact(id: "d2", name: "Alex Chen", handle: "+1 415 555 0134", label: "mobile", photo: nil),        // l10n-ignore
        FaceTimeContact(id: "d3", name: "Jordan Lee", handle: "+1 415 555 0178", label: "iPhone", photo: nil),       // l10n-ignore
        FaceTimeContact(id: "d4", name: "Priya Patel", handle: "priya@example.com", label: "home", photo: nil),      // l10n-ignore
        FaceTimeContact(id: "d5", name: "Sam Rivera", handle: "+1 415 555 0101", label: "mobile", photo: nil),       // l10n-ignore
        FaceTimeContact(id: "d6", name: "Taylor Kim", handle: "+1 415 555 0199", label: "work", photo: nil),         // l10n-ignore
    ]

    /// --demo-facetime [list|outgoing|audio|call|search]
    private func applyDemoFlag() {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--demo-facetime") else {
            // 隱私：快照／示範出圖不讀真的聯絡人與最近通話
            if SnapshotPrivacy.active { demo = "list"; contacts = Self.demoContacts; loaded = true }
            return
        }
        demo = i + 1 < a.count && !a[i + 1].hasPrefix("--") ? a[i + 1] : "list"
        contacts = Self.demoContacts; loaded = true
        call.demoElapsed = 0
        switch demo {
        case "outgoing", "audio": call.prepare(Self.demoContacts[0], video: demo != "audio")
        case "call": call.prepare(Self.demoContacts[0], video: true); call.dial(confirmedByUser: true); call.demoElapsed = 42
        case "calling": call.prepare(Self.demoContacts[0], video: true); call.dial(confirmedByUser: true); call.demoElapsed = nil   // 2.0 P04 快照：撥出後、接通前
        case "search": query = "a"; call.demoElapsed = nil
        default: call.demoElapsed = nil
        }
    }

    // MARK: 畫

    func render(into g: CGContext, face: Face, rect: CGRect, now: Double) {
        self.face = face
        if onCallScreen { renderCall(g, face); return }
        FaceTimeCamera.shared.stop()
        g.setFillColor(AppUI.bg.cgColor); g.fill(rect)
        AppUI.title(g, face, pageTitle)
        permissionButton = .zero; rowHits = []
        // 通話是用你的名義：跟其他個人 App 一樣，要先認出主人
        if AppUI.personalLocked || !PersonalGate.allowed { AppUI.drawLock(g, face, title: title); return }
        if demo == nil, FaceTimeContacts.status != .authorized {
            let denied = FaceTimeContacts.status != .notDetermined || !FaceTimeContacts.canAsk
            permissionButton = AppUI.drawPermission(g, face, appTitle: title, symbol: "person.crop.circle.fill", tint: AppUI.green,
                headline: denied ? L("facetime.perm.denied", "通讯录没有开放") : L("facetime.perm.title", "需要读取通讯录"),
                body: denied ? L("facetime.perm.deniedBody", "到系统设置的「隐私与安全性 › 通讯录」里允许 HomePlay，才能选人打 FaceTime")
                             : L("facetime.perm.body", "只用来列出可以打 FaceTime 的人；不修改，也不离开这台 Mac"),
                button: denied ? L("perm.openSettings", "打开系统设置") : L("facetime.perm.button", "允许读取通讯录"))
            return
        }
        renderList(g, face)
    }

    private typealias T = HPTokens.FaceTime
    /// 大標題照頁面內容（HPDS：根頁不直接寫 App 名稱；「FaceTime」也放不進 👀 膠囊左邊）
    private var pageTitle: String { L("facetime.title", "FaceTime") }

    private func renderList(_ g: CGContext, _ face: Face) {
        let x0 = AppUI.margin, w = AppUI.contentW
        let recents = query.isEmpty ? recentEntries() : []
        let shown = FaceTimeContacts.filter(contacts, query)
        var y = T.listTop - scroll
        // 最近
        if !recents.isEmpty {
            AppUI.sectionTitle(g, face, L("facetime.recents", "最近通话"), y: y + 40)
            y += T.sectionGap
            let card = CGRect(x: x0, y: y, width: w, height: CGFloat(recents.count) * T.rowHeight)
            AppUI.group(g, card)
            for (k, r) in recents.enumerated() {
                let row = CGRect(x: x0, y: y + CGFloat(k) * T.rowHeight, width: w, height: T.rowHeight)
                let sub = (r.video ? L("facetime.video", "FaceTime 视频") : L("facetime.audio", "FaceTime 语音")) + " · " + Self.relative(r.at)
                drawRow(g, face, row, name: r.name, subtitle: sub, photo: contacts.first { $0.id == r.id }?.photo, video: r.video, last: k == recents.count - 1)
                rowHits.append((row, FaceTimeContact(id: r.id, name: r.name, handle: r.handle, label: r.label, photo: nil), r.video))
                HPAX.note(g, row, .button, r.name, value: sub, shape: .rounded(0))   // 2.0 depth：VoiceOver
            }
            y += card.height + T.sectionAfter
        }
        // 聯絡人
        AppUI.sectionTitle(g, face, query.isEmpty ? L("facetime.contacts", "联系人") : L("facetime.results", "搜索结果"), y: y + 40)
        y += T.sectionGap
        if shown.isEmpty {
            let msg = !loaded ? L("music.lib.loading", "读取中…") : (query.isEmpty ? L("facetime.empty", "通讯录里没有可以打 FaceTime 的人") : L("facetime.noMatch", "没有符合的人"))
            AppUI.center(face, g, msg, AppUI.font(34), cx: 512, y: y + 70, AppUI.secondary)
            y += 140
        } else {
            let card = CGRect(x: x0, y: y, width: w, height: CGFloat(shown.count) * T.rowHeight)
            // 只畫看得到的那幾列（通訊錄可能有幾千人）
            if card.maxY > 150, card.minY < 1024 { AppUI.group(g, card) }
            let first = max(0, Int((150 - y) / T.rowHeight)), last = min(shown.count - 1, Int((1024 - y) / T.rowHeight))
            if first <= last {
                for k in first...last {
                    let c = shown[k]
                    let row = CGRect(x: x0, y: y + CGFloat(k) * T.rowHeight, width: w, height: T.rowHeight)
                    drawRow(g, face, row, name: c.name, subtitle: c.label.isEmpty ? c.handle : c.label, photo: c.photo, video: true, last: k == shown.count - 1)
                    rowHits.append((row, c, true))
                    HPAX.note(g, row, .button, c.name, value: c.label.isEmpty ? c.handle : c.label, shape: .rounded(0))   // 2.0 depth：VoiceOver
                }
            }
            y += card.height
        }
        maxScroll = max(0, y + scroll + 60 - 1024)
        // 頂端：內容捲到搜尋列底下時柔和淡出，再畫搜尋列（玻璃）
        g.setFillColor(AppUI.bg.cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: T.searchRect.maxY + 12))
        HPComponents.topFade(g, AppUI.bg, solidTo: T.searchRect.maxY + 12)
        AppUI.title(g, face, pageTitle)
        drawSearch(g, face)
    }

    private func drawSearch(_ g: CGContext, _ face: Face) {
        let r = T.searchRect
        HPAX.note(g, r, .button, L("facetime.search.field", "搜索联系人"), value: query.isEmpty ? nil : query)   // 2.0 depth：VoiceOver
        HPGlass.addCapsule(r, interactive: true) { [weak face] c in
            guard let face else { return }
            let f = AppUI.font(34)
            face.drawSymbol(c, "magnifyingglass", in: CGRect(x: r.minX + 30, y: r.midY - 19, width: 38, height: 38), color: HPGlass.ink.withAlphaComponent(0.6), weight: .medium)
            let text = self.query.isEmpty ? L("facetime.search", "搜索：用键盘输入或听写") : self.query
            face.drawLeft(c, Face.clipped(text, f, r.width - 140), font: f, x: r.minX + 86, y: r.midY + 12,
                          color: self.query.isEmpty ? HPGlass.ink.withAlphaComponent(0.5) : HPGlass.ink)
            if !self.query.isEmpty {
                face.drawSymbol(c, "xmark.circle.fill", in: CGRect(x: r.maxX - 66, y: r.midY - 19, width: 38, height: 38), color: HPGlass.ink.withAlphaComponent(0.45), weight: .regular)
            }
        }
    }

    private func recentEntries() -> [FaceTimeRecents.Entry] {
        if demo != nil {
            let now = FaceTimeCall.wall
            return [FaceTimeRecents.Entry(id: "d2", name: "Alex Chen", handle: "+1 415 555 0134", label: "mobile", video: true, at: now - 3600),   // l10n-ignore
                    FaceTimeRecents.Entry(id: "d4", name: "Priya Patel", handle: "priya@example.com", label: "home", video: false, at: now - 86400 * 2)]   // l10n-ignore
        }
        return Array(FaceTimeRecents.all().prefix(T.maxRecents))
    }

    static func relative(_ t: Double) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = L10n.language.locale; f.unitsStyle = .short
        return f.localizedString(for: Date(timeIntervalSince1970: t), relativeTo: Date())
    }

    private func drawRow(_ g: CGContext, _ face: Face, _ r: CGRect, name: String, subtitle: String, photo: Data?, video: Bool, last: Bool) {
        guard r.maxY > 140, r.minY < 1024 else { return }
        if Press.amount(r) > 0.01 { g.setFillColor(AppUI.label.withAlphaComponent(0.06 * Press.amount(r)).cgColor); g.fill(r) }
        let av = CGRect(x: r.minX + 28, y: r.midY - T.avatar / 2, width: T.avatar, height: T.avatar)
        Self.drawAvatar(g, face, av, name: name, photo: photo)
        let tx = av.maxX + 28, tw = r.maxX - 120 - tx
        let nf = AppUI.font(HPType.Size.list, .regular)
        face.drawLeft(g, Face.clipped(name, nf, tw), font: nf, x: tx, y: r.midY - 4, color: AppUI.label)
        let sf = AppUI.font(HPType.Size.secondary)
        // 電話號碼／handle 用中間刪節號：頭尾（國碼與末幾碼）都要留著辨識（HIG-LIST-23）
        face.drawLeft(g, Face.clippedMiddle(subtitle, sf, tw), font: sf, x: tx, y: r.midY + 38, color: AppUI.secondary)
        face.drawSymbol(g, video ? "video.fill" : "phone.fill", in: CGRect(x: r.maxX - 96, y: r.midY - 24, width: 60, height: 48), color: AppUI.green, weight: .regular)
        if !last { AppUI.separator(g, x: tx, maxX: r.maxX, y: r.maxY) }
    }

    /// 頭像：通訊錄照片；沒有就灰色漸層圓＋縮寫（iOS 的 monogram）
    static func drawAvatar(_ g: CGContext, _ face: Face, _ r: CGRect, name: String, photo: Data?) {
        g.saveGState()
        g.addEllipse(in: r); g.clip()
        if let d = photo, let img = MediaUI.cgImage(from: d, maxSide: 256) {
            MediaUI.drawCover(g, face: face, img, in: r)
        } else {
            MediaUI.fillGradient(g, r, srgb(0xA6ABB7), srgb(0x858994))
            let s = FaceTimeContacts.initials(name)
            let f = HPType.sf(r.height * 0.42, .semibold)
            face.drawLeft(g, s, font: f, x: r.midX - Typo.width(s, f) / 2, y: r.midY + f.capHeight / 2, color: .white)
        }
        g.restoreGState()
    }

    // MARK: 通話畫面

    private func renderCall(_ g: CGContext, _ face: Face) {
        guard let c = call.contact else { return }
        let full = MediaUI.full
        let pre = call.phase == .preDial
        // 底：撥出前＝自己的鏡頭（有授權、要視訊）；否則對方頭像糊成底
        let showSelf = call.video && FaceTimeCamera.authorized && demo == nil
        if showSelf { FaceTimeCamera.shared.start() } else { FaceTimeCamera.shared.stop() }
        let cam = showSelf ? FaceTimeCamera.shared.latest : nil
        if pre, let cam { MediaUI.drawCover(g, face: face, cam, in: full) }
        else { drawAvatarBackdrop(g, face, c) }
        // 上緣壓暗，名字才讀得到（照片上的白字）
        if let grad = MediaUI.shade(0.45) {
            g.saveGState(); g.translateBy(x: 0, y: 360); g.scaleBy(x: 1, y: -1)
            g.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 360), options: [])
            g.restoreGState()
        }
        if let grad = MediaUI.shade(0.4) { g.drawLinearGradient(grad, start: CGPoint(x: 0, y: 720), end: CGPoint(x: 0, y: 1024), options: [.drawsAfterEndLocation]) }
        // 通話中：右上自己的小窗
        if !pre, let cam {
            let p = T.pip, path = continuousRoundedRect(p, radius: T.pipRadius)
            g.saveGState(); g.addPath(path); g.clip(); MediaUI.drawCover(g, face: face, cam, in: p); g.restoreGState()
        }
        // 名字（左上；撥出前要讓出左上的返回鈕，接在它右邊）、狀態
        let nx = pre ? HPTokens.titleX : T.nameX
        let nf = HPComponents.fitted(c.name, size: T.nameSize, weight: .regular, maxWidth: T.nameMaxX - nx)
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: 2), blur: 12, color: NSColor(white: 0, alpha: 0.35).cgColor)
        face.drawLeft(g, Face.clipped(c.name, nf, T.nameMaxX - nx), font: nf, x: nx, y: T.nameBaseline, color: .white)
        let status: String
        switch call.phase {
        case .preDial: status = call.video ? L("facetime.ask.video", "按绿色按钮打 FaceTime 视频") : L("facetime.ask.audio", "按绿色按钮打 FaceTime 语音")
        case .calling: status = L("facetime.handoff", "已交给 FaceTime，正在呼叫…")
        default: status = (call.video ? L("facetime.video", "FaceTime 视频") : L("facetime.audio", "FaceTime 语音")) + " · " + NowPlayingPage.clock(call.elapsed)
        }
        let sf = AppUI.font(T.statusSize)
        face.drawLeft(g, Face.clipped(status, sf, T.nameMaxX - nx), font: sf, x: nx, y: T.statusBaseline, color: NSColor.white.withAlphaComponent(0.75))
        g.restoreGState()
        // 控制列：攝影機、麥克風、…、撥號／結束
        let rs = T.controls
        let camOn = call.video
        whiteButton(rs[0], symbol: camOn ? "video.fill" : "video.slash.fill", glyph: camOn ? HPTokens.FaceTime.callGreen : srgb(0x8E8E93), enabled: pre, face: face)
        let muted = FaceTimeMic.mutedByUs || (pre && FaceTimeMic.pendingMute)
        whiteButton(rs[1], symbol: muted ? "mic.slash.fill" : "mic.fill", glyph: muted ? srgb(0x8E8E93) : HPTokens.FaceTime.micOrange,
                    enabled: FaceTimeMic.canMute || demo != nil, face: face)
        HPGlass.addCapsule(rs[2], tint: HPComponents.mediaTint, interactive: true) { [weak face] cg in
            let s = rs[2].width * 0.3
            face?.drawSymbol(cg, "ellipsis", in: CGRect(x: rs[2].midX - s / 2, y: rs[2].midY - s / 2, width: s, height: s), color: .white, weight: .bold)
        }
        // 2.0 depth：VoiceOver——四顆控制鈕（note 只認主畫布，所以記在玻璃閉包外面）
        HPAX.note(g, rs[0], .toggle(camOn), L("a11y.camera", "摄像头"), shape: .circle)
        HPAX.note(g, rs[1], .toggle(!muted), L("a11y.microphone", "麦克风"), shape: .circle)
        HPAX.note(g, rs[2], .button, L("a11y.more", "更多"), shape: .circle)
        HPAX.note(g, rs[3], .button, pre ? (call.video ? L("facetime.video", "FaceTime 视频") : L("facetime.audio", "FaceTime 语音")) : L("call.hangUp", "挂断"), shape: .circle)
        let endTint = pre ? HPTokens.FaceTime.callGreen : HPTokens.FaceTime.endRed
        HPGlass.addCapsule(rs[3], tint: endTint, interactive: true) { [weak face] cg in
            // 官方的紅／綠比染色玻璃飽和（量到 #D70F0C）：再鋪一層同色，只留邊緣的玻璃
            cg.setFillColor(endTint.withAlphaComponent(HPTokens.FaceTime.tintFill).cgColor)
            cg.fillEllipse(in: rs[3].insetBy(dx: 3, dy: 3))
            let s = rs[3].width * (pre ? 0.36 : 0.3)
            face?.drawSymbol(cg, pre ? (self.call.video ? "video.fill" : "phone.fill") : "xmark", in: CGRect(x: rs[3].midX - s / 2, y: rs[3].midY - s / 2, width: s, height: s), color: .white, weight: .semibold)
            // 2.0 P04：撥出後、接通前（「正在呼叫…」）紅色的結束鈕外圈轉圈——動作還在進行，點它是取消
            if self.call.phase == .calling { HPComponents.spinner(cg, in: rs[3].insetBy(dx: rs[3].width * 0.12, dy: rs[3].width * 0.12), ink: NSColor.white.withAlphaComponent(0.75)) }
        }
    }

    /// 白底玻璃圓鈕（官方攝影機、麥克風）：白色染色玻璃＋彩色符號；停用時半透明
    private func whiteButton(_ r: CGRect, symbol: String, glyph: NSColor, enabled: Bool, face: Face) {
        HPGlass.addCapsule(r, tint: NSColor.white, interactive: enabled, presence: enabled ? 1 : 0.55) { [weak face] cg in
            // 官方這兩顆幾乎是不透明的白（量到 #FDFDFC）：玻璃上再鋪一層白，只留邊緣 3 px 的玻璃折射
            cg.setFillColor(NSColor.white.withAlphaComponent(enabled ? HPTokens.FaceTime.whiteFill : HPTokens.FaceTime.whiteFill * 0.55).cgColor)
            cg.fillEllipse(in: r.insetBy(dx: 3, dy: 3))
            let s = r.width * 0.34
            face?.drawSymbol(cg, symbol, in: CGRect(x: r.midX - s * 0.6, y: r.midY - s / 2, width: s * 1.2, height: s), color: enabled ? glyph : glyph.withAlphaComponent(0.45), weight: .semibold)
        }
    }

    private func drawAvatarBackdrop(_ g: CGContext, _ face: Face, _ c: FaceTimeContact) {
        let full = MediaUI.full
        if let d = c.photo, let img = MediaUI.cgImage(from: d, maxSide: 400), let b = MediaUI.blurred(img, sigma: 10, side: 160) {
            MediaUI.drawCover(g, face: face, b, in: full)
            g.setFillColor(NSColor(white: 0, alpha: 0.25).cgColor); g.fill(full)
            return
        }
        // 沒照片：名字取色的漸層＋一顆糊掉的大頭像
        let (a, b) = MediaUI.gradient(for: c.name)
        MediaUI.fillGradient(g, full, MediaUI.darkened(a, brightness: 0.42), MediaUI.darkened(b, brightness: 0.22))
        let av = CGRect(x: 512 - 190, y: 300, width: 380, height: 380)
        let img = makeImage(380, 380) { cg in Self.drawAvatar(cg, face, CGRect(x: 0, y: 0, width: 380, height: 380), name: c.name, photo: nil) }
        let ci = CIImage(cgImage: img)
        if let blurred = Face.ciContext.createCGImage(ci.clampedToExtent().applyingGaussianBlur(sigma: 18).cropped(to: ci.extent), from: ci.extent) {
            g.saveGState(); g.setAlpha(0.55); face.drawUpright(g, blurred, in: av); g.restoreGState()
        }
    }

    // MARK: 點

    func handleTap(_ p: CGPoint, face: Face, now: Double) -> Bool {
        self.face = face
        if onCallScreen { return tapCall(p, face: face) }
        if AppUI.personalLocked || !PersonalGate.allowed { return false }
        if permissionButton != .zero, AppUI.hit(permissionButton, p) {
            if FaceTimeContacts.status == .notDetermined, FaceTimeContacts.canAsk {
                MessagesContacts.shared.requestAccess { [weak self] _ in self?.reload(); self?.face?.forceDirty = true }
            } else {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")!)
            }
            return true
        }
        if demo == nil, FaceTimeContacts.status != .authorized { return false }
        let sr = T.searchRect
        if sr.insetBy(dx: -6, dy: -6).contains(p) {
            if !query.isEmpty, p.x > sr.maxX - 90 { query = ""; scroll = 0; return true }
            showSearch(face: face); return true
        }
        guard p.y > sr.maxY + 8 else { return false }
        for (r, c, video) in rowHits where r.contains(p) {
            call.prepare(c, video: video)
            if demo != nil { call.demoElapsed = 0 }
            return true
        }
        return false
    }

    private func tapCall(_ p: CGPoint, face: Face) -> Bool {
        let rs = T.controls
        func hit(_ r: CGRect) -> Bool { r.insetBy(dx: -10, dy: -10).contains(p) }
        let pre = call.phase == .preDial
        if hit(rs[0]) { if pre { call.video.toggle() }; return true }   // 通話中攝影機歸 FaceTime 管：停用
        if hit(rs[1]) {
            guard FaceTimeMic.canMute || demo != nil else { return true }
            if pre { FaceTimeMic.pendingMute.toggle() } else if demo == nil { FaceTimeMic.setMuted(!FaceTimeMic.mutedByUs) }
            return true
        }
        if hit(rs[2]) { if demo == nil { FaceTimeCall.bringFaceTimeForward() }; return true }   // 「…」：打開 FaceTime 的視窗（更多控制在那裡）
        if hit(rs[3]) {
            if pre {
                // 綠色撥號鈕：這一下就是你的確認
                if !call.dial(confirmedByUser: true) { showDialFailed() }
            } else {
                call.end()
                // 影片的掛斷轉場：錶面從模糊變清楚（外殼的錶面過場）
                (NSApp.delegate as? AppDelegate)?.view?.shellNavigate(.idle)
            }
            return true
        }
        return false
    }

    private func showDialFailed() {
        call.end()
        face?.forceDirty = true
        NSSound.beep()
    }

    func handleScroll(_ dy: CGFloat, now: Double) -> Bool {
        guard !onCallScreen else { return false }
        let s = max(0, min(maxScroll, scroll - dy))
        guard s != scroll else { return false }
        scroll = s; return true
    }

    // MARK: ClioTalk 的 call 工具走這裡（已念過、使用者說了「好」）

    @MainActor
    func startFromClio(_ c: FaceTimeContact, video: Bool) -> Bool {
        if call.active { call.end() }
        call.prepare(c, video: video)
        guard call.dial(confirmedByUser: true) else { call.end(); return false }
        if let v = (NSApp.delegate as? AppDelegate)?.view { v.shellOpenApp(id) }
        return true
    }

    // MARK: 搜尋（桌寵旁邊的原生小框；沒有螢幕鍵盤，用實體鍵盤或聽寫）

    private func showSearch(face: Face) {
        guard let v = (NSApp.delegate as? AppDelegate)?.view, popover?.isShown != true else { return }
        input.text = query
        input.onChange = { [weak self] t in self?.query = t; self?.scroll = 0; self?.face?.forceDirty = true }
        input.onDone = { [weak self] in self?.popover?.performClose(nil) }
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        p.contentViewController = NSHostingController(rootView: FaceTimeSearchView(model: input))
        NSApp.activate(ignoringOtherApps: true)
        p.show(relativeTo: v.bounds, of: v, preferredEdge: .maxX)
        popover = p
    }
}

final class FaceTimeSearchModel: ObservableObject {
    @Published var text = "" { didSet { onChange?(text) } }
    var onChange: ((String) -> Void)?
    var onDone: (() -> Void)?
}

struct FaceTimeSearchView: View {
    @ObservedObject var model: FaceTimeSearchModel
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(L("facetime.search.field", "搜索联系人"), text: $model.text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { model.onDone?() }
                .frame(width: 280)
            Label(L("input.noOnscreenKeyboard", "没有屏幕键盘：用键盘打字，或按两下 fn 听写"), systemImage: "keyboard")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .onAppear { focused = true }
    }
}
