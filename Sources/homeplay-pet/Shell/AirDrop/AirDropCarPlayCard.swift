// CarPlay 連著時的 AirDrop 卡片：疊在最上層、貼在畫面下緣（上緣留給收件卡 AirDropCard，兩張同時在也不疊）。
// 內容：「收 AirDrop」暫停 CarPlay 時的倒數卡（CarPlayAirDropPause），或傳給自己的確認卡與結果（SelfShareFlow）。標題、內文、一行說明、按鈕；主要動作藍底白字，其他淡底。
// 材質：Regular 玻璃（HPGlass，減少透明度由它換成實底）；減少動態效果時不滑動；增加對比多一圈描邊；深淺色跟 HPGlass.ink。

import AppKit

enum CarPlayAirDropCard {
    enum Btn: Equatable { case cancel, send, ok, openFullDisk, openAutomation, openSettings, resume }

    struct Model {
        var symbol: String
        var tint: NSColor
        var title: String
        var body: String
        var note: String?
        var buttons: [(Btn, String, Bool)]   // （動作、字、主要）
    }

    nonisolated(unsafe) static var hits: [(CGRect, Btn)] = []
    nonisolated(unsafe) static var rect: CGRect = .null
    nonisolated(unsafe) static var last: Model?

    static var shown: Bool { SelfShareFlow.shared.visible || CarPlayAirDropPause.shared.isPaused }
    static func presence(_ now: Double = CACurrentMediaTime()) -> CGFloat { HPPresence.value("carplay.airdrop.card", shown: shown, HPMotion.T.sheet, now: now) }

    /// 目前要畫的內容（純函數，selftest 驗）
    static func model(_ s: SelfShareFlow.State) -> Model? {
        let title = L("airdrop.self.title", "用信息传给自己")
        let cancel = (Btn.cancel, L("clio.chip.cancel", "取消"), false), ok = (Btn.ok, L("clio.chip.ok", "好"), true)
        func m(_ body: String, _ buttons: [(Btn, String, Bool)], note: String? = nil, symbol: String = "message.fill", tint: NSColor = HPTokens.green) -> Model {
            Model(symbol: symbol, tint: tint, title: title, body: body, note: note, buttons: buttons)
        }
        switch s {
        case .idle: return nil
        case .confirming(let what):
            return m(String(format: L("airdrop.self.confirm", "要用信息把“%@”传给你自己吗？"), what),
                     [cancel, (.send, L("msg.send", "发送"), true)], note: SelfShare.note)
        case .sending: return m(L("msg.sending", "正在传送…"), [], note: SelfShare.note)
        case .loading: return m(L("msg.loading", "正在载入…"), [cancel], note: SelfShare.note)   // 自己的帳號還在背景查
        case .done(let o):
            switch o {
            case .sent: return m(L("airdrop.self.sent", "已传送：在 iPhone 的“信息”里和自己的对话中"), [ok], symbol: "checkmark.circle.fill")
            case .unconfirmed: return m(L("msg.unconfirmed", "可能已经送出，但查不到记录。请到「信息」看一下，不要重送。"), [ok], tint: HPTokens.orange)
            case .needsAutomation:
                return m(L("msg.needsAutomation", "没有送出：要允许 HomePlay 控制「信息」（系统设置 › 隐私与安全性 › 自动化）"),
                         [cancel, (.openAutomation, L("msg.fda.open", "打开系统设置"), true)], tint: HPTokens.orange)
            case .failed: return m(L("msg.failed", "没有送出：「信息」回报错误"), [ok], tint: HPTokens.red)
            case .needsFullDisk:
                return m(L("airdrop.self.needsFDA", "要先在系统设置 › 隐私与安全性 › 完全磁盘访问权限里允许 HomePlay，才能找到你的 iMessage 账户、确认送到了"),
                         [cancel, (.openFullDisk, L("msg.fda.open", "打开系统设置"), true)], note: SelfShare.note, tint: HPTokens.orange)
            case .noHandle:
                return m(L("airdrop.self.noHandle", "找不到你自己的 iMessage 账户：请在 HomePlay 设置 › CarPlay 里选一次"),
                         [cancel, (.openSettings, L("airdrop.self.openSettings", "打开设置"), true)], note: SelfShare.note, tint: HPTokens.orange)
            case .guest: return m(L("airdrop.self.guest", "访客模式下不能传到主人的 iPhone"), [ok], symbol: "person.fill", tint: HPTokens.blue)
            }
        }
    }
    static var current: Model? {
        if let p = CarPlayAirDropPause.shared.plan { return paused(p, now: CACurrentMediaTime()) }
        return model(SelfShareFlow.shared.state)
    }

    /// 暫停中的倒數卡（純函數，selftest 驗）
    static func paused(_ p: CarPlayPausePlan, now: Double) -> Model {
        let note = p.received > 0 ? L("airdrop.pause.received", "收到了：传完就恢复 CarPlay")
            : String(format: L("airdrop.pause.left", "剩余 %@，收到文件后会自动恢复"), CarPlayAirDropPause.clock(p.remaining(now)))
        return Model(symbol: AirDropShare.symbol, tint: HPTokens.blue, title: L("airdrop.pause.title", "CarPlay 已暂停"),
                     body: L("airdrop.pause.body", "现在可以从 iPhone 用 AirDrop 传过来"), note: note,
                     buttons: [(.resume, L("airdrop.pause.resume", "恢复 CarPlay"), true)])
    }

    static let titleFont = HPComponents.sf(34, weight: .semibold), bodyFont = HPComponents.sf(30, weight: .regular)
    static let noteFont = HPComponents.sf(24, weight: .regular), buttonFont = HPComponents.sf(30, weight: .semibold)
    static let pad: CGFloat = 36, textX: CGFloat = 36 + 88 + 24
    /// 圓角跟螢幕同心（下緣離螢幕 48 → 138 − 48；卡片矮時被連續圓角夾小，見 EdgeContainers）
    static func radius(_ r: CGRect) -> CGFloat { HPTokens.Radius.concentric(rect: r) }
    /// 左上圖示貼著卡片角（內距 pad）：半徑＝卡片實際畫出的半徑 − pad
    static func iconRadius(_ r: CGRect) -> CGFloat { HPTokens.Radius.concentric(parent: HPTokens.Radius.drawn(radius(r), in: r), padding: pad) }

    /// 排版：下緣往上長；回卡片範圍與內文行
    static func layout(_ m: Model) -> (rect: CGRect, body: [String], note: [String]) {
        let w: CGFloat = 896, textW = w - textX - pad
        let body = MessagesScreen.wrap(m.body, bodyFont, textW, maxLines: 4)
        let note = m.note.map { MessagesScreen.wrap($0, noteFont, textW, maxLines: 2) } ?? []
        var h = pad + 44 + CGFloat(body.count) * 40 + (note.isEmpty ? 0 : 12 + CGFloat(note.count) * 32) + pad
        h = max(h, pad + 88 + pad)
        if !m.buttons.isEmpty { h += 80 + pad - 8 }
        return (CGRect(x: 64, y: 1024 - 48 - h, width: w, height: h), body, note)
    }
}

extension Face {
    /// 疊在最上層（drawShellOverlays 叫，在 AirDrop 收件卡之後）
    func drawCarPlayAirDropCard(_ g: CGContext, _ now: Double) {
        typealias C = CarPlayAirDropCard
        if let m = C.current { C.last = m }
        let p = C.presence(now)
        guard p > 0.001, let m = C.last else { C.hits = []; C.rect = .null; if p <= 0.001 { C.last = nil }; return }
        let (base, body, note) = C.layout(m)
        let slide: CGFloat = HPMotion.reduceMotion ? 0 : (1 - p) * 48
        let r = base.offsetBy(dx: 0, dy: slide)
        let rad = C.radius(base), iconRad = C.iconRadius(base)   // 用靜止位置的框算（滑入時不跟著變）
        let path = continuousRoundedRect(r, radius: rad)
        HPAX.note(g, r, .text, "\(m.title), \(m.body)" + (m.note.map { ", " + $0 } ?? ""), shape: .rounded(rad))
        var hits: [(CGRect, C.Btn)] = []
        var buttons: [(CGRect, C.Btn, String, Bool)] = []
        if !m.buttons.isEmpty {
            let gap: CGFloat = 20, x0 = r.minX + C.textX, bw = (r.maxX - C.pad - x0 - gap * CGFloat(m.buttons.count - 1)) / CGFloat(m.buttons.count)
            for (i, b) in m.buttons.enumerated() {
                let br = CGRect(x: x0 + CGFloat(i) * (bw + gap), y: r.maxY - C.pad - 80, width: bw, height: 80)
                buttons.append((br, b.0, b.1, b.2)); hits.append((br.insetBy(dx: -8, dy: -8), b.0))
                HPAX.note(g, br, .button, b.1)
            }
        }
        HPGlass.drawNowItems(g, face: self) {
            HPGlass.add(path, tint: nil, interactive: false, union: nil, presence: p) { [weak self] c in
                guard let self else { return }
                let ink = HPGlass.ink
                if HPAccessibility.increaseContrast {
                    c.addPath(path); c.setLineWidth(3); c.setStrokeColor(ink.withAlphaComponent(0.55).cgColor); c.strokePath()
                }
                let icon = CGRect(x: r.minX + C.pad, y: r.minY + C.pad, width: 88, height: 88)
                c.addPath(continuousRoundedRect(icon, radius: iconRad)); c.setFillColor(m.tint.cgColor); c.fillPath()
                self.drawSymbol(c, m.symbol, in: icon.insetBy(dx: 22, dy: 22), color: .white, weight: .semibold)
                let x = r.minX + C.textX, w = r.maxX - C.pad - x
                var y = r.minY + C.pad + 34
                self.drawLeft(c, Face.clipped(m.title, C.titleFont, w), font: C.titleFont, x: x, y: y, color: ink)
                y += 10
                for l in body { y += 40; self.drawLeft(c, Face.clipped(l, C.bodyFont, w), font: C.bodyFont, x: x, y: y, color: ink.withAlphaComponent(0.85)) }
                if !note.isEmpty {
                    y += 12
                    for l in note { y += 32; self.drawLeft(c, Face.clipped(l, C.noteFont, w), font: C.noteFont, x: x, y: y, color: ink.withAlphaComponent(HPAccessibility.increaseContrast ? 0.8 : 0.6)) }
                }
                if m.buttons.isEmpty {   // 傳送中：三個點依次亮（減少動態效果時不閃）
                    for i in 0..<3 {
                        let on = HPMotion.reduceMotion || Int(now * 3) % 3 == i
                        c.setFillColor(ink.withAlphaComponent(on ? 0.8 : 0.3).cgColor)
                        c.fillEllipse(in: CGRect(x: r.maxX - C.pad - 120 + CGFloat(i) * 42, y: r.minY + C.pad + 14, width: 22, height: 22))
                    }
                }
                for (b, _, label, primary) in buttons {
                    c.addPath(HPComponents.capsulePath(b)); c.setFillColor(primary ? HPTokens.blue.cgColor : ink.withAlphaComponent(0.12).cgColor); c.fillPath()
                    let s = Face.clipped(label, C.buttonFont, b.width - 32)
                    self.drawLeft(c, s, font: C.buttonFont, x: b.midX - Typo.width(s, C.buttonFont) / 2, y: b.midY + C.buttonFont.capHeight / 2, color: primary ? .white : ink)
                }
            }
        }
        C.rect = r
        C.hits = p > 0.9 && C.shown ? hits : []
    }
}

extension PetView {
    /// 卡片在時，按在卡片上就由它吃（AirDropCard 的按下／放開路徑先問這裡）
    func carPlayAirDropCardContains(_ uv: CGPoint?) -> Bool {
        guard let uv, CarPlayAirDropCard.shown, !CarPlayAirDropCard.rect.isNull else { return false }
        return CarPlayAirDropCard.rect.insetBy(dx: -8, dy: -8).contains(CGPoint(x: uv.x * 1024, y: uv.y * 1024))
    }

    func carPlayAirDropCardTap(_ uv: CGPoint?) {
        guard let uv else { return }
        let p = CGPoint(x: uv.x * 1024, y: uv.y * 1024)
        guard let b = CarPlayAirDropCard.hits.first(where: { $0.0.contains(p) })?.1 else { return }
        carPlayAirDropPerform(b)
        face.forceDirty = true
    }

    func carPlayAirDropPerform(_ b: CarPlayAirDropCard.Btn) {
        let flow = SelfShareFlow.shared
        switch b {
        case .resume: CarPlayAirDropPause.shared.resume(.user)
        case .send: flow.confirm()
        case .cancel, .ok: flow.cancel()
        case .openFullDisk: flow.cancel(); NSWorkspace.shared.open(MessagesAccess.fullDiskAccessURL)
        case .openAutomation:
            flow.cancel()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
        case .openSettings:
            flow.cancel()
            if let app = NSApp.delegate as? AppDelegate { SettingsWindowController.show(app: app, pane: .carplay) }
        }
    }
}
