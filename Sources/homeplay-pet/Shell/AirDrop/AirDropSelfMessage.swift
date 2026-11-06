// CarPlay 連著時「傳到手機」改走訊息傳給自己。iPhone 在 CarPlay 會話中（這台 Mac 就是那台車）時，iOS 不給用 AirDrop
// （系統提示「連接 CarPlay 車載時不能使用隔空投送」），所以照片錶面、照片小工具、Safari、食譜的分享鈕這時改成「用訊息傳給自己」：
// 照片送附件、網頁送網址、食譜送文字（有原網址就附在最後）。不在會話中時照舊 AirDrop（AirDropShare）。
// 收件人＝主人自己的 iMessage 帳號：設定裡選過的優先；沒選就從 chat.db 外送 iMessage 的寄件帳號挑次數最多的（MessagesStore.ownHandles）。
// 自己帳號的查詢（開 chat.db）在背景佇列做、結果快取 10 分鐘；CarPlay 連上時先查好，按下時快取還沒好就先顯示「正在載入」，不卡主執行緒。
// 一定先出確認卡（SelfShareFlow：要傳嗎？取消／傳送），送完照 MessagesSender 回頭查 chat.db；查不到就說「可能已送出」，不自動重送。
// 訪客模式、認不出主人：不送（傳的是主人的 iPhone）。沒有完整磁碟取用權限：說明要打開，不送（找不到帳號、也確認不了）。
// 卡片畫法在 AirDropCarPlayCard.swift；這個檔是規則與流程，--selftest 直接驗。

import AppKit

/// 要傳出去的東西（跟 AirDrop 分享鈕同一組來源）
enum SharePayload {
    case photoFile(URL)
    case image(CGImage)
    case page(URL)
    case recipe(Recipe)
}

enum SelfShare {
    /// 主人的 iPhone 正在 CarPlay 會話中（ControlCenter.carPlayOn 每幀照 face.status 填）；快照／自檢可強制
    nonisolated(unsafe) static var forceCarPlay: Bool?
    static var carPlayActive: Bool { forceCarPlay ?? ControlCenter.carPlayOn }
    static var useMessages: Bool { carPlayActive }

    /// 分享鈕的字、符號、說明（會話中換成訊息）
    static var title: String { useMessages ? L("airdrop.self.title", "用信息传给自己") : AirDropShare.title }
    static var symbol: String { useMessages ? "message.fill" : AirDropShare.symbol }
    static var note: String { L("airdrop.self.note", "CarPlay 连着时 iPhone 不能用 AirDrop，改用信息传给你自己") }
    /// 照片錶面右鍵選單那一項
    static var photoMenuTitle: String { useMessages ? L("airdrop.self.photo", "用信息把这张照片传给自己…") : L("airdrop.share.photo", "通过 AirDrop 发送这张照片…") }

    /// 分享鈕的入口：會話中→確認卡；不在會話中→AirDrop
    @discardableResult
    static func share(_ p: SharePayload?) -> Bool {
        guard let p else { return false }
        if useMessages { SelfShareFlow.shared.propose(p); return true }
        return AirDropShare.send(airDropItems(p))
    }

    static func airDropItems(_ p: SharePayload) -> [Any] {
        switch p {
        case .photoFile(let u): return AirDropShare.items(photoFile: u)
        case .image(let i): return AirDropShare.items(image: i)
        case .page(let u): return AirDropShare.items(page: u)
        case .recipe(let r): return AirDropShare.items(recipe: r)
        }
    }

    // MARK: 送什麼（純函數）

    enum Piece: Equatable {
        case text(String)
        case file(URL)
        case image   // 記憶體裡的圖：送出時才寫成 PNG
    }
    static func piece(_ p: SharePayload) -> Piece? {
        switch p {
        case .photoFile(let u): return .file(u)
        case .image: return .image
        case .page(let u): return AirDropShare.items(page: u).isEmpty ? nil : .text(u.absoluteString)
        case .recipe(let r): return .text(recipeText(r))
        }
    }
    /// 食譜：標題、材料、步驟；有原網址附在最後一行
    static func recipeText(_ r: Recipe) -> String {
        var parts = [r.title]
        if !r.ingredients.isEmpty { parts.append(r.ingredients.map { "• \($0)" }.joined(separator: "\n")) }
        if !r.steps.isEmpty { parts.append(r.steps.enumerated().map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n")) }
        if let s = r.sourceURL, let u = URL(string: s), !AirDropShare.items(page: u).isEmpty { parts.append(u.absoluteString) }
        return parts.joined(separator: "\n\n")
    }
    /// 確認卡上說要傳的是什麼
    static func summary(_ p: SharePayload) -> String {
        switch p {
        case .photoFile, .image: return L("airdrop.self.what.photo", "这张照片")
        case .page(let u): return u.host ?? u.absoluteString
        case .recipe(let r): return r.title
        }
    }

    // MARK: 自己的帳號

    static let handleKey = "airdrop.selfHandle"
    /// 設定裡選的（nil＝自動）
    static var chosenHandle: String? {
        get { UserDefaults.standard.string(forKey: handleKey).flatMap { $0.isEmpty ? nil : $0 } }
        set { if let v = newValue, !v.isEmpty { UserDefaults.standard.set(v, forKey: handleKey) } else { UserDefaults.standard.removeObject(forKey: handleKey) } }
    }
    /// 選過的優先；沒選就用 chat.db 裡次數最多的
    static func resolve(chosen: String?, candidates: [String]) -> String? { chosen ?? candidates.first }

    // MARK: 照片的暫存（「訊息」要讀得到的地方）

    /// 放在「訊息」自己的附件資料夾底下（要完整磁碟取用權限，跟讀 chat.db 一樣）；寫不進去退到暫存資料夾
    static func stage(_ piece: Piece, image: CGImage?, fm: FileManager = .default) -> URL? {
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/Attachments/HomePlay", isDirectory: true)
        let dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let alt = fm.temporaryDirectory.appendingPathComponent("homeplay-selfshare/\(UUID().uuidString)", isDirectory: true)
        prune(base, fm: fm)
        for d in [dir, alt] {
            guard (try? fm.createDirectory(at: d, withIntermediateDirectories: true)) != nil else { continue }
            switch piece {
            case .file(let src):
                let dst = d.appendingPathComponent(src.lastPathComponent)
                if (try? fm.copyItem(at: src, to: dst)) != nil { return dst }
            case .image:
                guard let image else { return nil }
                let dst = d.appendingPathComponent("HomePlay \(Self.stamp()).png")
                if let dest = CGImageDestinationCreateWithURL(dst as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, image, nil)
                    if CGImageDestinationFinalize(dest) { return dst }
                }
            case .text: return nil
            }
        }
        return nil
    }
    /// 一天以前暫存的照片清掉（「訊息」送出時已經拷進自己的附件裡）
    private static func prune(_ base: URL, fm: FileManager) {
        guard let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for u in items where (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).flatMap({ $0 }).map({ Date().timeIntervalSince($0) > 86400 }) == true {
            try? fm.removeItem(at: u)
        }
    }
    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}

/// 傳給自己的流程：確認 → 傳送中 → 結果。畫在 AirDropCarPlayCard
final class SelfShareFlow {
    nonisolated(unsafe) static var shared = SelfShareFlow()

    enum Outcome: Equatable {
        case sent, unconfirmed, needsAutomation, failed
        case needsFullDisk   // 沒有完整磁碟取用權限：找不到自己的帳號、也確認不了
        case noHandle        // chat.db 裡沒有外送 iMessage 的紀錄：請到設定選一次
        case guest           // 訪客模式、認不出主人
    }
    enum State: Equatable {
        case idle
        case loading   // 自己的帳號還在背景查（chat.db）
        case confirming(summary: String)
        case sending
        case done(Outcome)
    }
    private(set) var state: State = .idle
    private(set) var payload: SharePayload?
    private var handle: String?
    var since = 0.0

    // 注入點（自檢換成假的）。access／candidates 在背景佇列跑；換掉就清快取
    var allowed: () -> Bool = { PersonalGate.allowed && !Shell.guestMode }
    var access: () -> MessagesAccess = { CCSystem.demo ? .available : MessagesAccess.check() } { didSet { lookup = nil } }
    var candidates: () -> [String] = { CCSystem.demo ? ["demo"] : (MessagesStore.openDefault()?.ownHandles() ?? []) } { didSet { lookup = nil } }
    /// 背景查、回主執行緒交結果（自檢換成同步的）
    var runLookup: (@escaping () -> (MessagesAccess, [String]), @escaping ((MessagesAccess, [String])) -> Void) -> Void = { work, done in
        SelfShareFlow.lookupQueue.async { let r = work(); DispatchQueue.main.async { done(r) } }
    }
    /// 查好了（主執行緒）：載入中的卡片要重畫
    var onLookup: () -> Void = { (NSApp?.delegate as? AppDelegate)?.view?.face.forceDirty = true }
    static let lookupQueue = DispatchQueue(label: "homeplay.selfshare.lookup", qos: .userInitiated)
    /// 自己帳號的快取（主執行緒讀寫）：權限、候選帳號、查的時間
    private(set) var lookup: (access: MessagesAccess, handles: [String], at: Double)?
    private(set) var lookingUp = false
    static let lookupTTL: Double = 600
    func lookupFresh(_ now: Double) -> Bool { lookup.map { now - $0.at < Self.lookupTTL } ?? false }

    /// 先在背景查好自己的帳號（CarPlay 連著時每幀叫，快取新鮮或正在查就不動）
    func prefetch(now: Double = CACurrentMediaTime(), force: Bool = false, then: (() -> Void)? = nil) {
        guard force || !lookupFresh(now), !lookingUp else { return }
        lookingUp = true
        let acc = access, cand = candidates
        runLookup({ let a = acc(); return (a, a == .available ? cand() : []) }) { [weak self] r in
            guard let self else { return }
            self.lookingUp = false
            self.lookup = (r.0, r.1, CACurrentMediaTime())
            then?()
            self.onLookup()
        }
    }
    var chosen: () -> String? = { SelfShare.chosenHandle }
    /// 真的送：文字直接送；照片先拷到「訊息」讀得到的地方再送。示範不碰真的「訊息」
    var deliver: (SelfShare.Piece, CGImage?, String, @escaping (MessagesSendResult) -> Void) -> Void = { piece, img, h, done in
        if CCSystem.demo { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { done(.sent) }; return }
        switch piece {
        case .text(let t): MessagesSender.send(text: t, to: .handle(h), confirmed: true, completion: done)
        case .file, .image:
            guard let staged = SelfShare.stage(piece, image: img) else { done(.failed("stage")); return }
            MessagesSender.sendFile(staged, to: h, confirmed: true, completion: done)
        }
    }

    var visible: Bool { state != .idle }

    /// 按了分享鈕：先檢查能不能送，能就出確認卡。自己的帳號還沒查好就先顯示「正在載入」，查好再接著判斷（不在主執行緒查 chat.db）
    func propose(_ p: SharePayload, now: Double = CACurrentMediaTime()) {
        since = now
        payload = p
        guard allowed() else { state = .done(.guest); return }
        guard SelfShare.piece(p) != nil else { state = .idle; return }
        // 快取裡是「可以讀」才直接用；沒權限、沒資料庫的結果按下時重查（使用者可能剛去打開權限）
        if let c = lookup, lookupFresh(now), c.access == .available { decide(p, c.access, c.handles); return }
        state = .loading
        prefetch(now: now, force: true) { [weak self] in
            guard let self, self.state == .loading, let c = self.lookup else { return }   // 載入中被取消了就不接著出卡
            guard self.allowed() else { self.state = .done(.guest); return }
            self.decide(p, c.access, c.handles)
        }
    }
    private func decide(_ p: SharePayload, _ acc: MessagesAccess, _ handles: [String]) {
        guard acc == .available else { state = .done(.needsFullDisk); return }
        guard let h = SelfShare.resolve(chosen: chosen(), candidates: handles) else { state = .done(.noHandle); return }
        handle = h
        state = .confirming(summary: SelfShare.summary(p))
    }

    /// 確認卡的「傳送」
    func confirm(now: Double = CACurrentMediaTime()) {
        guard case .confirming = state, let p = payload, let h = handle, let piece = SelfShare.piece(p) else { return }
        guard allowed() else { state = .done(.guest); since = now; return }   // 主人走開了：不送
        state = .sending; since = now
        var img: CGImage?
        if case .image(let i) = p { img = i }
        deliver(piece, img, h) { [weak self] r in self?.finish(r) }
    }

    func finish(_ r: MessagesSendResult, now: Double = CACurrentMediaTime()) {
        since = now
        switch r {
        case .sent: state = .done(.sent)
        case .unconfirmed: state = .done(.unconfirmed)
        case .needsAutomation: state = .done(.needsAutomation)
        case .notConfirmed, .failed: state = .done(.failed)
        }
        log("selfshare: \(state)")
    }

    func cancel() { state = .idle; payload = nil; handle = nil }

    /// 「已傳送」幾秒後自己收；其他結果要按
    func tick(now: Double) -> Bool {
        if case .done(.sent) = state, now - since > 2.5 { cancel(); return true }
        return state == .sending || state == .loading
    }

    /// 快照用
    func demo(_ s: State, payload p: SharePayload) { payload = p; handle = "demo"; state = s; since = CACurrentMediaTime() }
}
