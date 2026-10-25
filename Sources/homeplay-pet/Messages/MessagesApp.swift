// 2.0: 訊息 App（外殼裡的 PetApp）：對話列表 → 對話頁 → 返回；新訊息；捲動；新訊息的 Live Activity；回覆。
// 畫面本身是 MessagesScreen（純繪製）；這裡管狀態、讀 chat.db（自己的佇列、自己的連線）、點按、確認卡與其他浮層。
//
// 2.0 imsg：對齊手錶（watchOS 27）與 HomeView 能做的事——
//   回覆：「用說的」（本機聽寫，原話）、「打字」（實體鍵盤，桌寵旁邊的原生小框；沒有螢幕鍵盤）、表情面板、建議回覆；
//   新訊息：最近的對話＋通訊錄，用說的或打字找人；
//   看：照片（點開全螢幕）、影片（交給 QuickTime）、語音訊息（原地播）、連結（交給瀏覽器）、隱形墨水（點一下顯示）、特效「重播」；
//   Tapback、標為已讀在 macOS 沒有公開路徑：只顯示，不假裝能做（本機「看過」只讓 HomePlay 的未讀點消失）。
// 回覆照 AI System 6：任何送出都先出確認卡「要傳給 [名字]：『…』嗎？」好／取消，按「好」才 MessagesSender.send(confirmed: true)；
// 結果照實說：查到外送列才算「已傳送」；查不到是「可能已送出，別重送」；沒有自動化權限就說要去哪裡開。
// 新訊息：頂端藥丸 8 秒「名字：預覽」；認人開著而眼前不是主人（或訪客模式）只寫「新信息」；專注模式開著不跳、眼睛不瞄。
// 隱私：不記錄任何內文、名字、號碼。

import AppKit
import SwiftUI

/// 送出前的確認流程（純邏輯，selftest 直接測）：沒經過 confirming → 好，answer 不會交出要送的字
struct MessagesReplyFlow: Equatable {
    enum State: Equatable { case idle, confirming(String), sending(String), done(MessagesSendResult) }
    private(set) var state = State.idle

    /// 擬好一句（打字、聽寫或建議回覆）：先念回來等確認
    @discardableResult
    mutating func propose(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        switch state { case .sending: return false; default: break }
        state = .confirming(t)
        return true
    }
    /// 好／取消；回傳要送的字（只有在確認中按「好」才有）
    /// 2.0 depth：最後一次按了「好」的那一句（「信息」回報錯誤時給「重試」：重新念一次、再按一次「好」才送）
    private(set) var lastAnswered: String?
    mutating func answer(_ yes: Bool) -> String? {
        guard case .confirming(let t) = state else { return nil }
        state = yes ? .sending(t) : .idle
        if yes { lastAnswered = t }
        return yes ? t : nil
    }
    mutating func finish(_ r: MessagesSendResult) {
        guard case .sending = state else { return }
        state = .done(r)
    }
    mutating func dismiss() {
        switch state { case .sending: return; default: state = .idle }
    }
    var showsCard: Bool { state != .idle }
}

/// 新訊息 Live Activity 的字（純函數）
enum MessagesActivityText {
    static func text(name: String, preview: String, allowed: Bool) -> (title: String, detail: String) {
        allowed ? (name, preview) : (L("app.messages", "信息"), L("msg.activity.new", "新信息"))
    }
}

/// 新訊息的收件人（純值，selftest 測）：既有對話用 chat id 送，通訊錄的人用 participant 送
struct MessagesRecipient: Equatable {
    var name: String
    var detail: String
    var chatGUID: String?
    var handle: String?
    var target: MessagesSendTarget? {
        if let g = chatGUID { return .chat(guid: g) }
        if let h = handle { return .handle(h) }
        return nil
    }
}

final class MessagesApp: PetApp {
    static let shared = MessagesApp()
    let id = "messages"
    var title: String { L("app.messages", "信息") }
    let icon = AppIcon(color: srgb(0x30d158), symbol: "message.fill", system: "/System/Applications/Messages.app")
    static let activitySeconds = 8.0

    enum Page: Equatable { case list, thread(String), compose }
    private(set) var page = Page.list
    private(set) var flow = MessagesReplyFlow()
    /// 最近一則新訊息（Live Activity 用）
    private(set) var incoming: (title: String, preview: String, at: Double)?
    /// 2.0 P03：那則新訊息在哪串對話（chat ROWID；點 Live Activity 直接開到那裡）
    private var incomingChat: Int64?
    /// 對話列表還沒讀好就點了：讀好再開
    private var pendingChat: Int64?
    /// 2.0 imsg：從橫幅按「回覆」：開到對話就直接開始聽
    private var pendingVoiceReply = false

    private var convs: [MsgConversation] = []
    private var listModel: MessagesListModel?
    private var thread: (guid: String, title: String, isGroup: Bool, items: [MessagesItem])?
    /// 2.0 imsg：這串已讀進來的訊息（舊到新）；往上捲到頂再讀更舊的一頁
    private var threadMsgs: [MsgMessage] = []
    private var threadLoading = false, threadMore = false, loadingOlder = false
    static let pageSize = 40
    private let speaker = ClioSpeaker()
    private var chips: [String] = ClioReplySuggest.fixed
    private var listFirst = 0, threadSkip = 0, scrollAcc: CGFloat = 0
    private var hits: MessagesScreen.Hits = []
    private enum CardButton { case ok, cancel, dismiss, retry, automation, dictDone, dictCancel, emoji(Int), emojiClose, viewerClose }
    private var cardButtons: [(CardButton, CGRect)] = []
    private var flowAt = 0.0
    private var toast: (text: String, at: Double)?
    private var dirty = false
    private let queue = DispatchQueue(label: "homeplay.messages.app")
    private var store: MessagesStore?            // 只在 queue 上用
    private var watcher: MessagesWatcher?
    private var popover: NSPopover?
    private let input = MessagesInputModel()

    // 2.0 imsg：浮層與新訊息
    private let dictation = MessagesDictation()
    private enum Listen { case reply, name }
    private var listenFor = Listen.reply
    private var demoDictation: String?
    private var emojiOpen = false
    private var viewer: CGImage?
    private var revealed: Set<Int64> = []
    private var pulse: (row: Int64, at: Double)?
    private var demoAudioAt: Double?
    private var composeQuery = ""
    private var recipient: MessagesRecipient?
    private var suggestions: [MessagesRecipient] = []
    static let emojis = ["❤️", "👍", "😂", "🥰", "😮", "😢", "🙏", "👏", "🎉", "🔥", "👀", "🫶"]

    private var demo: Bool { MessagesDemo.mode != nil }

    init() {
        dictation.onChange = { [weak self] in self?.redraw() }
        dictation.onDone = { [weak self] t in self?.heard(t) }
        dictation.onFail = { [weak self] why in self?.toast = (why, CACurrentMediaTime()); self?.redraw() }
        MessagesMedia.shared.onReady = { [weak self] in self?.redraw() }
    }

    private func redraw() {
        dirty = true
        (NSApp.delegate as? AppDelegate)?.view?.face.forceDirty = true
    }

    // MARK: 開機：監看新訊息

    /// AppDelegate 開機時叫一次（快照、示範資料時不碰真的 chat.db）
    func install() {
        guard !demo, !CommandLine.arguments.contains("--snapshot"), watcher == nil, MessagesAccess.check() == .available else { return }
        if MessagesContacts.status == .authorized { DispatchQueue.global(qos: .utility).async { MessagesContacts.shared.reload() } }
        let w = MessagesWatcher()
        w.handler = { [weak self] arr in self?.received(arr) }
        if w.start() { watcher = w }
    }

    private func received(_ arr: [MessagesIncoming]) {
        guard let m = arr.last else { return }
        reloadList()
        if case .thread(let g) = page { loadThread(g) }
        // 2.0 imsg：專注模式（勿擾）開著：不跳橫幅、眼睛不瞄（跟手錶一樣安靜）；未讀點照樣更新
        if MessagesFocus.active { log("messages: \(arr.count) new, quiet (focus)"); return }
        let who = MessagesContacts.shared.name(for: m.message.senderHandle)
        let name = m.isGroup ? (m.chatTitle.isEmpty ? who ?? m.message.senderHandle : m.chatTitle)
                             : who ?? (m.chatTitle.isEmpty ? m.message.senderHandle : m.chatTitle)
        let preview = m.message.text.isEmpty ? L("msg.attachment", "附件") : m.message.text
        incoming = (name, preview, CACurrentMediaTime()); incomingChat = m.message.chatRowID
        if let v = (NSApp.delegate as? AppDelegate)?.view { v.face.glanceNow(); v.face.forceDirty = true }   // 眼睛瞄一下
    }

    /// 快照：--live-activity message（官方影片那一句）
    func demoIncoming() {
        incoming = (L("msg.demo.friendB", "[朋友 B]"), L("msg.demo.scene2", "7:20 见？？？"), CACurrentMediaTime() + 3600)
    }

    // MARK: PetApp

    var showsCloseButton: Bool { page == .list && !overlayOpen }
    private var overlayOpen: Bool { flow.showsCard || dictation.active || demoDictation != nil || emojiOpen || viewer != nil }

    func didOpen(now: Double) {
        listFirst = 0; threadSkip = 0; scrollAcc = 0
        emojiOpen = false; viewer = nil; demoDictation = nil
        if demo {
            switch MessagesDemo.mode {
            case "thread", "confirm", "dictate", "emoji": page = .thread("demo")
            case "rich", "group": page = .thread(MessagesDemo.mode!)
            case "compose": page = .compose; composeQuery = ""; recipient = nil; suggestions = demoSuggestions()
            default: page = .list
            }
            if MessagesDemo.mode == "confirm" { flow = MessagesReplyFlow(); flow.propose(L("msg.demo.reply", "我 7:20 到！")); flowAt = now }
            if MessagesDemo.mode == "dictate" { demoDictation = L("msg.demo.reply", "我 7:20 到！") }
            if MessagesDemo.mode == "emoji" { emojiOpen = true }
            return
        }
        page = .list
        guard PersonalGate.allowed else { listModel = nil; listRequested = false; return }   // 鎖著（訪客）：什麼都不讀，解鎖後 render 再讀
        if MessagesContacts.status == .notDetermined, MessagesAccess.check() == .available {
            MessagesContacts.shared.requestAccess { [weak self] _ in self?.reloadList() }
        }
        reloadList()
    }

    func handleBack(now: Double) -> Bool {
        if viewer != nil { viewer = nil; dirty = true; return true }
        if emojiOpen { emojiOpen = false; dirty = true; return true }
        if dictation.active || demoDictation != nil { dictation.cancel(); demoDictation = nil; dirty = true; return true }
        if flow.showsCard { flow.dismiss(); dirty = true; logState(); return true }
        if page != .list { leaveToList(); dirty = true; logState(); return true }
        return false
    }

    private func leaveToList() {
        page = .list; threadSkip = 0
        MessagesMedia.shared.stop(); demoAudioAt = nil
        recipient = nil; composeQuery = ""
    }

    /// 2.0 r2：對話頁是子頁（返回鈕由訊息畫面自己畫成 ‹）
    var backSymbol: String { page == .list ? "xmark" : "chevron.left" }

    func tick(_ now: Double) -> Bool {
        var d = dirty; dirty = false
        // 主人走開了（或換成訪客、遠端訪客）：正在聽的、正在打的、還沒按的確認卡、看著的照片都收掉，朗讀停下；送出中的照樣跑完
        let confirming: Bool = { if case .confirming = flow.state { return true }; return false }()
        if !demo, dictation.active || popover?.isShown == true || speaker.pending > 0 || emojiOpen || viewer != nil || confirming, !PersonalGate.allowed {
            dictation.cancel(); popover?.performClose(nil); speaker.stop()
            emojiOpen = false; viewer = nil
            if case .confirming = flow.state { flow.dismiss() }
            log("messages app: closed overlays (owner left)")
            d = true
        }
        if HPComponents.needsFrame(now) { d = true }
        if let t = toast, now - t.at > 2.6 { toast = nil; d = true }
        if case .done(.sent) = flow.state, now - flowAt > 3 { flow.dismiss(); d = true }
        if case .sending = flow.state { d = true }   // 「正在傳送…」的點在跑
        if dictation.active { d = true }             // 聽寫中：波紋在動
        if MessagesMedia.shared.playingID != nil || demoAudioAt != nil { d = true }
        if let a = demoAudioAt, now - a > 7 { demoAudioAt = nil }
        if let p = pulse { if now - p.at > 0.6 { pulse = nil }; d = true }
        return d
    }

    func liveActivity(face: Face, now: Double) -> LiveActivity? {
        guard let inc = incoming, now - inc.at < Self.activitySeconds else { return nil }
        // 2.0 P03：設定裡關掉「顯示預覽」也只寫「新信息」
        let t = MessagesActivityText.text(name: inc.title, preview: inc.preview, allowed: PersonalGate.allowed && LiveActivityStack.showsMessagePreview)
        return LiveActivity(kind: .message, title: t.title, detail: t.detail, accent: srgb(0x30d158), progress: nil, appID: id, symbol: "message.fill",
                            link: demo ? "demo" : incomingChat.map { String($0) })
    }

    /// 2.0 P03：點新訊息的 Live Activity：開到那串對話（不是只開列表）。訪客看不到內容，就停在 App 的鎖畫面
    func openFromActivity(_ link: String?) {
        guard let link, PersonalGate.allowed else { return }
        if demo { openThread("demo"); logState(); return }
        guard let row = Int64(link) else { return }
        if let c = convs.first(where: { $0.rowID == row }) { openThread(c.guid) } else { pendingChat = row }
        logState()
    }

    /// 2.0 imsg：橫幅大卡的「回覆」：開到那串對話後直接開始聽（HomeView 的「用說的回覆」）
    func replyByVoice() {
        guard PersonalGate.allowed else { return }
        if case .thread = page { startListening(.reply) } else { pendingVoiceReply = true }
    }

    func render(into g: CGContext, face: Face, rect: CGRect, now: Double) {
        if !demo, listModel == nil, !listRequested { reloadList() }
        let model = screenModel(now)
        if Shell.appMorph == nil, !overlayOpen {   // 浮層開著：底下的按鈕不上玻璃（玻璃在幀尾才畫，會蓋過浮層）
            // 2.0 r2（R13）：訊息的按鈕走 GlassPass（外殼包在幀尾用系統 Liquid Glass 一起算）
            MessagesScreen.controlGlass = { g, path, _, content in HPComponents.glass(g, path, interactive: true, content: content); return true }
        }
        hits = MessagesScreen.render(model, in: g, rect: rect)
        MessagesScreen.controlGlass = nil
        cardButtons = []
        if let v = viewer { drawViewer(g, face: face, v) }
        else if emojiOpen { drawEmoji(g, face: face) }
        else if dictation.active || demoDictation != nil { drawDictation(g, face: face, now: now) }
        else if flow.showsCard { drawCard(g, face: face, now: now) }
        if let t = toast { drawToast(g, face: face, t.text) }
    }

    func handleTap(_ p: CGPoint, face: Face, now: Double) -> Bool {
        if overlayOpen {
            if let b = cardButtons.first(where: { $0.1.insetBy(dx: -8, dy: -8).contains(p) })?.0 { cardTap(b, now: now) }
            logState()
            return true                                    // 浮層在時，點別處不穿過去
        }
        guard let hit = hits.last(where: { $0.1.contains(p) })?.0 else { return false }
        switch hit {
        case .back: leaveToList()
        case .row(let id), .pin(let id): openThread(id)
        case .chip(let i): if i < chips.count, flow.propose(chips[i]) { flowAt = now }
        case .type: showTyping(forName: false)
        case .speak: startListening(.reply)
        case .emoji: emojiOpen = true
        case .newMessage: openCompose()
        case .typeName: showTyping(forName: true)
        case .sayName: startListening(.name)
        case .suggestion(let i): if i < suggestions.count { recipient = suggestions[i] }
        case .clearRecipient: recipient = nil
        case .item(let i): tapItem(i, now: now)
        case .openSettings: NSWorkspace.shared.open(MessagesAccess.fullDiskAccessURL)
        case .none: return false
        }
        dirty = true
        logState()
        return true
    }

    /// 2.0 imsg：按住一則訊息＝念出來（「用說的讀」：手上沾著麵粉時聽就好；只給主人，聲音只從這台 Mac 出來）
    func handleLongPress(_ p: CGPoint, face: Face, now: Double) -> Bool {
        guard !overlayOpen, case .thread = page, demo || PersonalGate.allowed,
              case .item(let i)? = hits.last(where: { $0.1.contains(p) })?.0 else { return false }
        let items = currentThreadModel(now).items
        guard i < items.count else { return false }
        let it = items[i]
        let who = it.fromMe ? L("msg.ax.me", "我") : (it.senderName ?? targetName)
        speaker.stop()
        speaker.say(String(format: L("msg.readAloud", "%1$@说：%2$@"), who, MessagesScreen.axValue(it, currentThreadModel(now))))
        log("messages app: read aloud")
        return true
    }

    /// 自檢腳本看得到走到哪（只記頁面與卡片狀態，沒有內容）
    private func logState() {
        let card: String
        switch flow.state { case .idle: card = "none"; case .confirming: card = "confirm"; case .sending: card = "sending"; case .done(let r): card = "done \(r == .sent ? "sent" : "other")" }
        let pg: String
        switch page { case .list: pg = "list"; case .thread: pg = "thread"; case .compose: pg = "compose" }
        log("messages app: \(pg) card=\(card)\(dictation.active ? " listening" : "")\(emojiOpen ? " emoji" : "")")
    }

    func handleScroll(_ dy: CGFloat, now: Double) -> Bool {
        guard !overlayOpen else { return true }
        scrollAcc += dy
        let step: CGFloat = 40
        while abs(scrollAcc) >= step {
            let up = scrollAcc > 0
            scrollAcc -= up ? step : -step
            switch page {
            case .list:
                let rows = (demo ? MessagesDemo.list().rows.count : listModel?.rows.count ?? 0)
                listFirst = max(0, min(max(0, rows - 1), listFirst + (up ? -1 : 1)))
            case .thread:
                let n = currentThreadModel(now).items.count
                threadSkip = max(0, min(max(0, n - 1), threadSkip + (up ? 1 : -1)))   // 往上滑看舊的
                loadOlderIfNeeded()
            case .compose: break
            }
        }
        dirty = true
        return true
    }

    // MARK: 畫面模型

    private func screenModel(_ now: Double) -> MessagesScreenModel {
        switch page {
        case .list:
            var m = demo ? MessagesDemo.list(MessagesDemo.mode == "fda" || MessagesDemo.mode == "nodb" ? MessagesDemo.mode! : "list")
                         : listModel ?? MessagesListModel(pins: [], rows: [], access: MessagesAccess.check(), loading: MessagesAccess.check() == .available)
            m.firstRow = listFirst
            m.titleLeading = HPTokens.titleX     // 2.0 r2：大標題接在左上返回圓鈕旁
            return .list(m)
        case .thread:
            return .thread(currentThreadModel(now))
        case .compose:
            return .compose(MessagesComposeModel(recipient: recipient?.name, query: composeQuery,
                                                 suggestions: suggestions.map { .init(id: $0.chatGUID ?? $0.handle ?? $0.name, name: $0.name, detail: $0.detail, initials: MessagesThreadBuilder.initials($0.name)) }))
        }
    }

    private func currentThreadModel(_ now: Double) -> MessagesThreadModel {
        var t: MessagesThreadModel
        if demo {
            t = page == .thread("rich") ? MessagesDemo.rich() : page == .thread("group") ? MessagesDemo.rich(replies: true) : MessagesDemo.scene()
            if let a = demoAudioAt { t.playing = (-2, min(1, (now - a) / 7)) }
        } else {
            t = MessagesThreadModel(title: thread?.title ?? "", items: thread?.items ?? [], chips: chips, isGroup: thread?.isGroup ?? false)
            t.loading = threadLoading
            t.missing = { MessagesMedia.shared.isMissing($0) }
            t.image = { ref, video in MessagesMedia.shared.image(ref, video: video) }
            t.audioSeconds = { MessagesMedia.shared.duration($0) }
            if let id = MessagesMedia.shared.playingID, let p = MessagesMedia.shared.progress { t.playing = (id, p) }
        }
        t.chips = demo ? ClioReplySuggest.fixed : chips
        t.skipNewest = threadSkip; t.inShell = true
        t.revealed = revealed
        if let p = pulse { t.pulse = (p.row, CGFloat((now - p.at) / 0.6)) }
        return t
    }

    private var targetName: String {
        if page == .compose { return recipient?.name ?? "" }
        if demo { return page == .thread("rich") || page == .thread("group") ? L("msg.demo.family", "[家人群组]") : L("msg.demo.friendB", "[朋友 B]") }
        return thread?.title ?? ""
    }

    // MARK: 點對話裡的東西

    private func tapItem(_ i: Int, now: Double) {
        let items = currentThreadModel(now).items
        guard i < items.count else { return }
        let it = items[i]
        switch it.kind {
        case .photo(let r), .sticker(let r):
            if r.sensitive { toast = (L("msg.sensitive", "可能是敏感内容"), now); return }
            if demo { viewer = MessagesMedia.demoImages[r.id]; return }
            guard MessagesMedia.allowed(r.path) else { return }
            viewer = MessagesMedia.shared.image(r)   // 先用縮圖，背景換大圖
            let path = r.path
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let big = MessagesMedia.thumbnail(path, max: 2048)
                DispatchQueue.main.async { if let big, self?.viewer != nil { self?.viewer = big; self?.redraw() } }
            }
        case .video(let r):
            if demo || !MessagesMedia.allowed(r.path) { toast = (L("msg.video.opens", "视频会在「QuickTime Player」里播放"), now); return }
            NSWorkspace.shared.open(URL(fileURLWithPath: r.path))
        case .audio(let r, _):
            if demo { demoAudioAt = demoAudioAt == nil ? now : nil; return }
            MessagesMedia.shared.toggle(r)
        case .link(let l, _):
            guard let u = URL(string: l.url), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return }
            if demo { toast = (L("msg.link.opens", "链接会在浏览器里打开"), now); return }
            NSWorkspace.shared.open(u)
        case .hidden:
            revealed.insert(it.messageRow)
            if demo { toast = (L("msg.ink.revealed", "已显示"), now) }
        default:
            if it.effect { pulse = (it.messageRow, now) }
        }
    }

    // MARK: 讀 chat.db（自己的佇列）

    private func withStore(_ body: @escaping (MessagesStore?) -> Void) {
        queue.async { [self] in
            if store == nil, MessagesAccess.check() == .available, let s = MessagesStore.openDefault() {
                let contacts = MessagesContacts.shared
                s.nameResolver = { contacts.name(for: $0) }
                store = s
            }
            body(store)
        }
    }

    private var listRequested = false
    private func reloadList() {
        guard !demo else { return }
        listRequested = true
        let access = MessagesAccess.check()
        withStore { [weak self] s in
            let convs = s?.conversations(limit: 40) ?? []
            let contacts = MessagesContacts.shared
            let model = MessagesListModel.from(convs, pins: MessagesPins.load(), access: s == nil && access == .available ? .noDatabase : access,
                                               seen: MessagesSeen.load(), avatar: { contacts.photo(for: $0) }, name: { contacts.name(for: $0) })
            DispatchQueue.main.async {
                guard let self else { return }
                self.convs = convs
                if let r = self.pendingChat, let c = convs.first(where: { $0.rowID == r }) { self.pendingChat = nil; self.openThread(c.guid) }   // 2.0 P03
                self.listModel = model
                self.redraw()
            }
        }
    }

    private func openThread(_ guid: String) {
        page = .thread(guid); threadSkip = 0
        chips = ClioReplySuggest.fixed
        revealed = []
        if pendingVoiceReply { pendingVoiceReply = false; DispatchQueue.main.async { [weak self] in self?.startListening(.reply) } }
        guard !demo else { return }
        let conv = convs.first { $0.guid == guid }
        thread = (guid, conv?.title ?? "", conv?.isGroup ?? false, [])
        threadMsgs = []; threadLoading = true; threadMore = false
        if let c = conv { MessagesSeen.mark(guid, upTo: c.lastRowID) }   // 本機「看過」：只讓這裡的未讀點消失
        loadThread(guid)
    }

    private func loadThread(_ guid: String) {
        guard let conv = convs.first(where: { $0.guid == guid }) else { return }
        let limit = max(Self.pageSize, threadMsgs.count)   // 新訊息進來時重讀：已經往上讀過的那幾頁一起留著
        withStore { [weak self] s in
            let msgs = Array((s?.messages(chat: conv.rowID, limit: limit) ?? []).reversed())
            let contacts = MessagesContacts.shared
            let items = MessagesThreadBuilder.items(msgs, isGroup: conv.isGroup, name: { contacts.name(for: $0) })
            let last = msgs.suffix(6).filter { !$0.text.isEmpty && !$0.isUnsent }.map { (fromMe: $0.isFromMe, text: $0.text) }
            DispatchQueue.main.async {
                guard let self, case .thread(let g) = self.page, g == guid else { return }
                self.thread = (guid, conv.title, conv.isGroup, items)
                self.threadMsgs = msgs; self.threadLoading = false; self.threadMore = msgs.count >= limit
                if let top = msgs.last?.rowID { MessagesSeen.mark(guid, upTo: top) }
                self.redraw()
                ClioReplySuggest.request(last: last) { [weak self] c in
                    guard let self, let c, case .thread(let g) = self.page, g == guid else { return }
                    self.chips = c; self.redraw()
                }
            }
        }
    }

    /// 捲到最舊那幾則：再讀一頁更舊的（ROWID 游標），接在前面
    private func loadOlderIfNeeded() {
        guard !demo, threadMore, !loadingOlder, case .thread(let guid) = page, let first = threadMsgs.first,
              let conv = convs.first(where: { $0.guid == guid }), threadSkip >= (thread?.items.count ?? 0) - 4 else { return }
        loadingOlder = true
        withStore { [weak self] s in
            let older = Array((s?.messages(chat: conv.rowID, limit: Self.pageSize, before: first.rowID) ?? []).reversed())
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingOlder = false
                guard case .thread(let g) = self.page, g == guid else { return }
                self.threadMore = older.count >= Self.pageSize
                guard !older.isEmpty else { return }
                self.threadMsgs = older + self.threadMsgs
                let contacts = MessagesContacts.shared
                self.thread?.items = MessagesThreadBuilder.items(self.threadMsgs, isGroup: conv.isGroup, name: { contacts.name(for: $0) })
                self.redraw()
            }
        }
    }

    // MARK: 新訊息

    private func openCompose() {
        page = .compose; recipient = nil; composeQuery = ""
        suggestions = demo ? demoSuggestions() : Self.suggest("", convs: convs, contacts: [])
    }

    private func demoSuggestions() -> [MessagesRecipient] {
        MessagesDemo.compose().suggestions.map { MessagesRecipient(name: $0.name, detail: $0.detail, chatGUID: "demo", handle: nil) }
    }

    /// 收件人建議（純函數）：沒打字＝最近 6 個對話；有字＝符合的對話＋通訊錄的人（每個號碼／信箱一列），去掉重複
    static func suggest(_ q: String, convs: [MsgConversation], contacts: [MessagesContacts.Person]) -> [MessagesRecipient] {
        let recentLabel = L("msg.to.recent", "最近的对话")
        let matched = q.isEmpty ? Array(convs.prefix(6)) : Array(ClioMessagesTools.match(q, in: convs).prefix(4))
        var out = matched.map { MessagesRecipient(name: $0.title, detail: recentLabel, chatGUID: $0.guid, handle: nil) }
        let known = Set(matched.flatMap(\.participants).map(HandleKey.make))
        for p in contacts where !q.isEmpty {
            for h in p.handles where !known.contains(HandleKey.make(h)) && out.count < 8 {
                out.append(MessagesRecipient(name: p.name, detail: h, chatGUID: nil, handle: h))
            }
        }
        return out
    }

    private func updateSuggestions() {
        let q = composeQuery
        let contacts = MessagesContacts.status == .authorized ? MessagesContacts.shared.search(q) : []
        suggestions = demo ? demoSuggestions().filter { q.isEmpty || ClioMessagesTools.normalized($0.name).contains(ClioMessagesTools.normalized(q)) }
                           : Self.suggest(q, convs: convs, contacts: contacts)
        if suggestions.count == 1, !q.isEmpty { recipient = suggestions[0] }   // 只有一個：直接選上（還要再確認內容才會送）
        redraw()
    }

    // MARK: 回覆：聽寫、打字、表情

    private func startListening(_ purpose: Listen) {
        guard demo || PersonalGate.allowed else { return }
        listenFor = purpose
        if demo { demoDictation = L("msg.demo.reply", "我 7:20 到！"); redraw(); return }
        dictation.start()
    }

    /// 聽完：原話放進確認卡（回覆）或當成名字找人（新訊息）
    private func heard(_ t: String) {
        guard !t.isEmpty else { toast = (L("msg.dictation.empty", "没有听到内容"), CACurrentMediaTime()); redraw(); return }
        switch listenFor {
        case .reply: if flow.propose(t) { flowAt = CACurrentMediaTime() }
        case .name: composeQuery = t; updateSuggestions()
        }
        redraw()
    }

    private func showTyping(forName: Bool) {
        guard let v = (NSApp.delegate as? AppDelegate)?.view else { return }
        if popover?.isShown == true { return }
        input.text = ""
        input.placeholder = forName ? L("msg.to.typeName", "名字、电话或电子邮件") : String(format: L("msg.input.placeholder", "回复 %@…"), targetName)
        input.onSend = { [weak self] t in
            guard let self else { return }
            self.popover?.performClose(nil)
            if forName { self.composeQuery = t; self.updateSuggestions() }
            else if self.flow.propose(t) { self.flowAt = CACurrentMediaTime() }
            self.redraw()
        }
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        p.contentViewController = NSHostingController(rootView: MessagesInputView(model: input))
        NSApp.activate(ignoringOtherApps: true)
        p.show(relativeTo: v.bounds, of: v, preferredEdge: .maxX)
        popover = p
    }

    private func cardTap(_ b: CardButton, now: Double) {
        switch b {
        case .cancel: _ = flow.answer(false)
        case .dismiss: flow.dismiss()
        case .retry: if let t = flow.lastAnswered { flow.dismiss(); if flow.propose(t) { flowAt = now } }
        case .automation:
            flow.dismiss()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
        case .dictDone:
            if let t = demoDictation { demoDictation = nil; heard(t) } else { dictation.finish() }
        case .dictCancel: demoDictation = nil; dictation.cancel()
        case .emoji(let i): emojiOpen = false; if flow.propose(Self.emojis[i]) { flowAt = now }
        case .emojiClose: emojiOpen = false
        case .viewerClose: viewer = nil
        case .ok:
            guard demo || PersonalGate.allowed else { flow.dismiss(); return }   // 主人走開了：不送
            guard let text = flow.answer(true) else { return }
            flowAt = now
            if demo {
                // 示範資料：不碰真的「訊息」，假裝送出
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.finish(.sent) }
            } else if let target = page == .compose ? recipient?.target : thread.map({ .chat(guid: $0.guid) }) {
                let service = page == .compose ? nil : convs.first { $0.guid == thread?.guid }?.service
                MessagesSender.send(text: text, to: target, confirmed: true, fallbackService: service) { [weak self] r in self?.finish(r) }
            } else {
                finish(.failed("no chat"))
            }
        }
        dirty = true
    }

    private func finish(_ r: MessagesSendResult) {
        flow.finish(r); flowAt = CACurrentMediaTime(); redraw()
        guard r == .sent else { return }
        if case .thread(let g) = page { loadThread(g) }
        if page == .compose, !demo {   // 新訊息送出：回到列表，新的對話會出現在最上面
            leaveToList(); reloadList()
        }
    }

    // MARK: 浮層：確認卡、聽寫、表情、看照片、小提示

    private func cardFrame(lines n: Int, buttons: Bool, extra: CGFloat = 0) -> CGRect {
        let inset: CGFloat = 64, pad: CGFloat = 48, lineH: CGFloat = 62
        let h = pad + CGFloat(n) * lineH + extra + (buttons ? 40 + 100 + pad : pad)
        return CGRect(x: inset, y: max(150, 512 - h / 2), width: 1024 - 2 * inset, height: h)
    }

    private func drawCardBase(_ g: CGContext, _ card: CGRect) {
        g.setFillColor(NSColor.black.withAlphaComponent(HPTokens.dark ? 0.55 : 0.28).cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let path = continuousRoundedRect(card, radius: Screen.concentric(inset: card.minX))
        // 2.0 r2：確認卡是不透明的卡（淺色白、深色 #1C1C1E），卡上的按鈕才是玻璃
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: 10), blur: 40, color: NSColor(white: 0, alpha: 0.25).cgColor)
        g.addPath(path); g.setFillColor(HPComponents.grouped.cgColor); g.fillPath()
        g.restoreGState()
    }

    private func drawButtons(_ g: CGContext, face: Face, card: CGRect, _ buttons: [(CardButton, String, Bool)]) {
        let pad: CGFloat = 48, gap: CGFloat = 24, bw = (card.width - 2 * pad - gap * CGFloat(buttons.count - 1)) / CGFloat(buttons.count)
        let bf = FaceType.sf(42, .semibold, mono: false)
        for (i, b) in buttons.enumerated() {
            let r = CGRect(x: card.minX + pad + CGFloat(i) * (bw + gap), y: card.maxY - pad - 100, width: bw, height: 100)
            // 主要動作＝藍色染色玻璃白字，其餘＝玻璃膠囊（label 色字）
            let s = Face.clipped(b.1, bf, r.width - 40)
            let ink: NSColor = b.2 ? .white : HPComponents.label
            HPComponents.glassCapsule(g, r, tint: b.2 ? HPComponents.blue : nil) { c in
                face.drawLeft(c, s, font: bf, x: r.midX - Typo.width(s, bf) / 2, y: r.midY + bf.capHeight / 2, color: ink)
            }
            cardButtons.append((b.0, r))
            HPAX.note(g, r, .button, b.1)   // 2.0 depth：VoiceOver
        }
    }

    private func drawCard(_ g: CGContext, face: Face, now: Double) {
        let message: String, buttons: [(CardButton, String, Bool)]
        switch flow.state {
        case .confirming(let t):
            message = MessagesReadback.text(name: targetName, body: t)
            buttons = [(.cancel, L("clio.chip.cancel", "取消"), false), (.ok, L("msg.send", "发送"), true)]
        case .sending:
            message = L("msg.sending", "正在传送…"); buttons = []
        case .done(let r):
            switch r {
            case .sent: message = L("msg.sent", "已传送"); buttons = [(.dismiss, L("clio.chip.ok", "好"), true)]
            case .unconfirmed: message = L("msg.unconfirmed", "可能已经送出，但查不到记录。请到「信息」看一下，不要重送。"); buttons = [(.dismiss, L("clio.chip.ok", "好"), true)]
            case .needsAutomation:
                message = L("msg.needsAutomation", "没有送出：要允许 HomePlay 控制「信息」（系统设置 › 隐私与安全性 › 自动化）")
                buttons = [(.dismiss, L("clio.chip.cancel", "取消"), false), (.automation, L("msg.fda.open", "打开系统设置"), true)]
            case .notConfirmed: message = L("msg.failed", "没有送出：「信息」回报错误"); buttons = [(.dismiss, L("clio.chip.ok", "好"), true)]
            case .failed:   // 2.0 depth：確定沒送出才給「重試」（「可能已送出」那種不給，免得送兩次）
                message = L("msg.failed", "没有送出：「信息」回报错误")
                buttons = flow.lastAnswered == nil ? [(.dismiss, L("clio.chip.ok", "好"), true)]
                    : [(.dismiss, L("clio.chip.cancel", "取消"), false), (.retry, L("recipe.retry", "重试"), true)]
            }
        case .idle: return
        }
        let pad: CGFloat = 48
        let tf = FaceType.sf(46, .semibold, mono: false)
        let lines = MessagesScreen.wrap(message, tf, 1024 - 2 * 64 - 2 * pad, maxLines: 6)
        let card = cardFrame(lines: lines.count, buttons: !buttons.isEmpty)
        drawCardBase(g, card)
        var y = card.minY + pad
        for l in lines {
            face.drawLeft(g, Face.clipped(l, tf, card.width - 2 * pad), font: tf, x: card.minX + pad, y: y + 46, color: HPComponents.label)
            y += 62
        }
        HPAX.note(g, CGRect(x: card.minX + pad, y: card.minY + pad, width: card.width - 2 * pad, height: CGFloat(lines.count) * 62), .text, message, shape: .rounded(16))   // 2.0 depth：VoiceOver
        if case .sending = flow.state {
            for i in 0..<3 {   // 三個點依次亮
                let on = Int(now * 3) % 3 == i
                g.setFillColor(HPComponents.label.withAlphaComponent(on ? 0.9 : 0.3).cgColor)
                g.fillEllipse(in: CGRect(x: card.maxX - pad - 120 + CGFloat(i) * 42, y: card.minY + pad + 18, width: 24, height: 24))
            }
        }
        if !buttons.isEmpty { drawButtons(g, face: face, card: card, buttons) }
    }

    /// 聽寫中：「正在聽…」＋聽到的字（還沒確定的淡一點）＋取消／完成；講完自動交出去
    private func drawDictation(_ g: CGContext, face: Face, now: Double) {
        let pad: CGFloat = 48
        let tf = FaceType.sf(46, .regular, mono: false), hf = FaceType.sf(34, .semibold, mono: false)
        let heard = demoDictation ?? (dictation.final + dictation.volatile)
        let head: String
        switch dictation.state {
        case .preparing(let p?): head = String(format: L("msg.dictation.downloading", "正在下载语音模型… %d%%"), Int(p * 100))
        case .preparing: head = L("msg.dictation.preparing", "正在准备…")
        case .finishing: head = L("msg.dictation.finishing", "好了，正在整理…")
        default: head = listenFor == .name ? L("msg.dictation.name", "说出名字") : String(format: L("msg.dictation.to", "正在听：回复 %@"), targetName)
        }
        let body = heard.isEmpty ? [L("msg.dictation.hint", "说完会自动停")] : MessagesScreen.wrap(heard, tf, 1024 - 2 * 64 - 2 * pad, maxLines: 4)
        let card = cardFrame(lines: body.count, buttons: true, extra: 70)
        drawCardBase(g, card)
        // 頂端：紅色麥克風點（跟系統的錄音指示一樣）＋說明
        let dot = CGRect(x: card.minX + pad, y: card.minY + pad + 6, width: 30, height: 30)
        let pulseA = HPMotion.reduceMotion ? 1 : 0.55 + 0.45 * abs(sin(now * 3))   // 減少動態效果：不閃
        g.setFillColor(HPComponents.orange.withAlphaComponent(pulseA).cgColor); g.fillEllipse(in: dot)
        face.drawLeft(g, Face.clipped(head, hf, card.width - 2 * pad - 50), font: hf, x: dot.maxX + 18, y: dot.midY + hf.capHeight / 2, color: HPComponents.secondary)
        var y = card.minY + pad + 70
        for l in body {
            face.drawLeft(g, Face.clipped(l, tf, card.width - 2 * pad), font: tf, x: card.minX + pad, y: y + 46,
                          color: heard.isEmpty ? HPComponents.tertiary : HPComponents.label)
            y += 62
        }
        HPAX.note(g, CGRect(x: card.minX + pad, y: card.minY + pad, width: card.width - 2 * pad, height: CGFloat(body.count) * 62 + 70), .text, head,
                  value: heard.isEmpty ? body.first : heard, shape: .rounded(16))   // 2.0 depth：VoiceOver——狀態＋聽到的字
        drawButtons(g, face: face, card: card, [(.dictCancel, L("clio.chip.cancel", "取消"), false), (.dictDone, L("msg.dictation.done", "完成"), true)])
    }

    /// 表情面板：4×3 大格（≥ 88），點一個就進確認卡
    private func drawEmoji(_ g: CGContext, face: Face) {
        let pad: CGFloat = 40, cell: CGFloat = 150, cols = 4
        let rows = (Self.emojis.count + cols - 1) / cols
        let h = pad + 70 + CGFloat(rows) * cell + 40 + 100 + pad
        let card = CGRect(x: 64, y: min(max(150, 512 - h / 2), 1024 - 48 - h), width: 1024 - 128, height: h)
        drawCardBase(g, card)
        let hf = FaceType.sf(38, .bold, mono: false)
        face.drawLeft(g, L("msg.emoji", "表情"), font: hf, x: card.minX + 56, y: card.minY + pad + 44, color: HPComponents.label)
        let x0 = card.midX - CGFloat(cols) * cell / 2, y0 = card.minY + pad + 70
        let f = NSFont.systemFont(ofSize: 84)
        for (i, e) in Self.emojis.enumerated() {
            let r = CGRect(x: x0 + CGFloat(i % cols) * cell, y: y0 + CGFloat(i / cols) * cell, width: cell, height: cell)
            face.drawLeft(g, e, font: f, x: r.midX - Typo.width(e, f) / 2, y: r.midY + 30, color: HPComponents.label)
            cardButtons.append((.emoji(i), r.insetBy(dx: 8, dy: 8)))
            HPAX.note(g, r.insetBy(dx: 8, dy: 8), .button, e, shape: .rounded(24))   // 2.0 depth：VoiceOver
        }
        drawButtons(g, face: face, card: card, [(.emojiClose, L("clio.chip.cancel", "取消"), false)])
    }

    /// 看照片：黑底等比放大，左上 ✕
    private func drawViewer(_ g: CGContext, face: Face, _ img: CGImage) {
        g.setFillColor(NSColor.black.cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let box = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        MessagesScreen.drawAspectFill(g, img, in: box, fit: true)
        let b = HPTokens.backButton
        HPComponents.glass(g, CGPath(ellipseIn: b, transform: nil), interactive: true) { c in
            MessagesScreen.symbol(c, "xmark", in: b.insetBy(dx: 30, dy: 30), color: .white)
        }
        cardButtons.append((.viewerClose, b.insetBy(dx: -10, dy: -10)))
        HPAX.note(g, b, .button, L("a11y.close", "关闭"), shape: .circle)   // 2.0 depth：VoiceOver
    }

    private func drawToast(_ g: CGContext, face: Face, _ text: String) {
        let f = FaceType.sf(34, .semibold, mono: false)
        let s = Face.clipped(text, f, 800)
        let w = Typo.width(s, f) + 72
        let r = CGRect(x: 512 - w / 2, y: 520, width: w, height: 88)
        g.addPath(CGPath(roundedRect: r, cornerWidth: 44, cornerHeight: 44, transform: nil))
        g.setFillColor(HPComponents.grouped2.withAlphaComponent(0.96).cgColor); g.fillPath()
        face.drawLeft(g, s, font: f, x: r.minX + 36, y: r.midY + f.capHeight / 2, color: HPComponents.label)
    }
}

// MARK: - 打字（桌寵旁邊的原生小框，跟 ClioTalk 的一樣）

final class MessagesInputModel: ObservableObject {
    @Published var text = ""
    var placeholder = ""
    var onSend: ((String) -> Void)?
}

struct MessagesInputView: View {
    @ObservedObject var model: MessagesInputModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
            TextField(model.placeholder, text: $model.text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(send)
                .frame(width: 280)
            Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .buttonStyle(.plain).foregroundStyle(model.text.isEmpty ? Color.secondary : Color.accentColor)
                .disabled(model.text.trimmingCharacters(in: .whitespaces).isEmpty)
                .help(L("msg.input.next", "下一步：先念给你确认"))
        }
            // 2.0 第四輪 #9：沒有螢幕鍵盤
            Label(L("input.noOnscreenKeyboard", "没有屏幕键盘：用键盘打字，或按两下 fn 听写"), systemImage: "keyboard")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .onAppear { focused = true }
    }

    private func send() {
        let t = model.text
        guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.text = ""
        model.onSend?(t)
    }
}
