// 首次設定的畫面（1024 畫布、左上原點、8 的倍數）：狀態與動作在 SetupFlow.swift。
// 版面照官方首次設定：上面頁點與返回鈕、中間一句標題＋說明＋內容、底下一顆主要按鈕（寬 560、高 96）＋一行次要文字鈕。
// 顏色全走 HPTokens（淺／深色、增加對比），按鈕是 HPGlass（減少透明度時自動霧面）；減少動態效果時換頁只淡入淡出。

import AppKit

/// 首次設定頁的列表卡：框在這裡（EdgeContainers 登記同一個框），圓角跟螢幕同心
enum SetupCards {
    static let languageRowH: CGFloat = 96, permissionRowH: CGFloat = 96
    static func language(rows: Int) -> CGRect { CGRect(x: 112, y: 376, width: 800, height: languageRowH * CGFloat(rows)) }
    static func permissions(rows: Int) -> CGRect { CGRect(x: 64, y: 320, width: 896, height: permissionRowH * CGFloat(rows)) }
    static func radius(_ card: CGRect) -> CGFloat { HPTokens.Radius.concentric(rect: card) }
}

extension Face {
    /// 主要按鈕與次要文字鈕：每頁只給標題，畫在不跟著滑的那一層（玻璃要在沒有位移的畫布上合成）
    nonisolated(unsafe) private static var chromeSpec: (primary: (String, SetupFlow.Action)?, secondary: (String, SetupFlow.Action)?) = (nil, nil)
    private var chrome: (primary: (String, SetupFlow.Action)?, secondary: (String, SetupFlow.Action)?) {
        get { Self.chromeSpec } set { Self.chromeSpec = newValue }
    }

    private enum SL {
        static let primary = CGRect(x: 232, y: 808, width: 560, height: HPTokens.Size.cta)
        static let secondaryBaseline: CGFloat = 960
        static let titleBaseline: CGFloat = 240
        static let bodyTop: CGFloat = 296
        static let card = CGRect(x: 64, y: 0, width: 896, height: 0)
    }

    func drawSetup(_ g: CGContext, _ now: Double) {
        let S = SetupFlow.self
        guard S.active else { return }
        S.hits = []; chrome = (nil, nil)
        HPGlass.flush(g, face: self)   // 底下各層還沒畫的玻璃先畫掉（等一下整面蓋住），這一層的玻璃自己收
        g.setFillColor(HPComponents.bg.cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        // 換頁：新的一頁從行進方向滑進來並淡入（減少動態效果：只淡入）
        let raw = min(1, max(0, (now - S.pageAt) / S.transition))
        let p = CGFloat(1 - pow(1 - raw, 3))
        g.saveGState()
        g.setAlpha(p)
        if !HPMotion.reduceMotion { g.translateBy(x: (1 - p) * 96 * S.direction, y: 0) }
        switch S.page {
        case .welcome: setupWelcome(g, now)
        case .language: setupLanguage(g)
        case .permissions: setupPermissions(g)
        case .carplay: setupCarPlay(g)
        case .look: setupLook(g)
        case .done: setupDone(g, now)
        }
        g.restoreGState()
        setupChrome(g)
    }

    // MARK: 共用

    /// 頁點＋返回鈕（不跟著內容滑）
    private func setupChrome(_ g: CGContext) {
        let pages = SetupPage.allCases
        let i = pages.firstIndex(of: SetupFlow.page) ?? 0
        let d: CGFloat = 16, gap: CGFloat = 16
        let w = CGFloat(pages.count) * d + CGFloat(pages.count - 1) * gap
        let cy = HPTokens.backButton.midY
        for k in pages.indices {
            let r = CGRect(x: 512 - w / 2 + CGFloat(k) * (d + gap), y: cy - d / 2, width: d, height: d)
            g.setFillColor((k == i ? HPComponents.label : HPComponents.tertiary).cgColor); g.fillEllipse(in: r)
        }
        HPAX.note(g, CGRect(x: 512 - w / 2 - 8, y: cy - 24, width: w + 16, height: 48), .text,
                  String(format: L("setup.pageOf", "第 %1$d 页，共 %2$d 页"), i + 1, pages.count))
        if SetupFlow.before(SetupFlow.page) != nil {
            let r = HPTokens.backButton
            HPComponents.glassCircle(g, self, r, symbol: "chevron.left")
            SetupFlow.hits.append((.back, r))
        }
        if let (t, a) = chrome.primary {
            let r = SL.primary
            HPComponents.filledButton(g, self, r, t, tint: HPComponents.blue.withAlphaComponent(SetupFlow.pressed == a ? 0.7 : 1), size: 40)
            SetupFlow.hits.append((a, r))
        }
        if let (t, a) = chrome.secondary {
            let f = HPComponents.sf(34, weight: .medium)
            let w = Typo.width(t, f)
            let r = CGRect(x: 512 - w / 2 - 32, y: SL.secondaryBaseline - 52, width: w + 64, height: 72)
            drawCentered(g, t, font: f, y: SL.secondaryBaseline, color: HPComponents.blue.withAlphaComponent(SetupFlow.pressed == a ? 0.5 : 1))
            HPAX.note(g, r, .button, t)
            SetupFlow.hits.append((a, r))
        }
        HPGlass.flush(g, face: self)
    }

    private func setupTitle(_ g: CGContext, _ s: String, baseline: CGFloat = SL.titleBaseline) {
        let f = HPComponents.fitted(s, size: 64, weight: .bold, maxWidth: 880)
        drawCentered(g, s, font: f, y: baseline, color: HPComponents.label)
        HPAX.note(g, CGRect(x: 72, y: baseline - f.ascender - 8, width: 880, height: f.ascender + 24), .heading, s)
    }

    /// 置中的說明（最多 maxLines 行）；回最後一行的下緣
    @discardableResult
    private func setupBody(_ g: CGContext, _ s: String, top: CGFloat, size: CGFloat = 34, maxLines: Int = 3, color: NSColor? = nil) -> CGFloat {
        let f = HPComponents.sf(size, weight: .regular)
        let lines = MediaUI.wrap(s, f, 820, maxLines: maxLines)
        let lh = size * 1.32
        for (k, line) in lines.enumerated() {
            drawCentered(g, line, font: f, y: top + size + CGFloat(k) * lh, color: color ?? HPComponents.secondary)
        }
        let bottom = top + size + CGFloat(max(0, lines.count - 1)) * lh + 12
        HPAX.note(g, CGRect(x: 102, y: top, width: 820, height: bottom - top), .text, s)
        return bottom
    }

    private func setupPrimary(_ g: CGContext, _ title: String, action: SetupFlow.Action = .next) { chrome.primary = (title, action) }
    private func setupSecondary(_ g: CGContext, _ title: String, action: SetupFlow.Action) { chrome.secondary = (title, action) }

    /// 👀 照桌寵本身的樣子：膠囊照現在的年代與錶面（Faces/Capsule.swift），眼睛不改造型
    private func setupEyes(_ g: CGContext, _ now: Double, cy: CGFloat) {
        let h: CGFloat = 152, w: CGFloat = 512
        let r = CGRect(x: 512 - w / 2, y: cy - h / 2, width: w, height: h)
        drawCapsuleBody(g, r, look: capsuleLook() == .system ? .black : capsuleLook(), animating: false)
        let k = h / 156, bf = blinkFactor(now)
        for s: CGFloat in [-1, 1] { drawEye(g, cx: r.midX + s * cur.sep * k, cy: r.midY, side: s, blinkF: bf, k: k) }
    }

    // MARK: 各頁

    private func setupWelcome(_ g: CGContext, _ now: Double) {
        setupEyes(g, now, cy: 344)
        setupTitle(g, L("setup.welcome.title", "欢迎使用 HomePlay"), baseline: 584)
        setupBody(g, L("setup.welcome.body", "几步就好：选语言、开权限、连上 iPhone，再挑一个外观。"), top: 624)
        setupPrimary(g, L("setup.continue", "继续"))
        setupSecondary(g, L("setup.later", "以后再设置"), action: .skipAll)
    }

    private func setupLanguage(_ g: CGContext) {
        setupTitle(g, L("setup.language.title", "选择语言"))
        setupBody(g, L("setup.language.body", "马上换，之后也能在设置里改。"), top: SL.bodyTop, maxLines: 2)
        let chosen = SetupFlow.demo != nil ? nil : PetLanguage.chosen
        let rows: [(String, PetLanguage?)] = [(L("settings.language.system", "跟随系统"), nil), ("English", .en), ("简体中文", .zhHans), ("繁體中文", .zhHant)]
        let card = SetupCards.language(rows: rows.count), rh = SetupCards.languageRowH, top = card.minY
        HPComponents.groupCard(g, card, radius: SetupCards.radius(card))
        let f = HPComponents.sf(38, weight: .regular)
        for (k, row) in rows.enumerated() {
            let r = CGRect(x: card.minX, y: top + CGFloat(k) * rh, width: card.width, height: rh)
            if k > 0 { HPComponents.separatorLine(g, x: r.minX + 48, maxX: r.maxX, y: r.minY + 1) }
            drawLeft(g, row.0, font: f, x: r.minX + 48, y: r.midY + f.capHeight / 2, color: HPComponents.label)
            let on = chosen == row.1
            if on { drawSymbol(g, "checkmark", in: CGRect(x: r.maxX - 88, y: r.midY - 20, width: 40, height: 40), color: HPComponents.blue) }
            HPAX.note(g, r, .button, row.0, value: on ? L("setup.selected", "已选") : nil, shape: .rounded(24))
            SetupFlow.hits.append((.language(row.1), r))
        }
        setupPrimary(g, L("setup.continue", "继续"))
    }

    private func permTitle(_ p: SetupPermission) -> String {
        switch p {
        case .home: return L("setup.perm.home", "家庭")
        case .contacts: return L("setup.perm.contacts", "通讯录")
        case .fullDisk: return L("setup.perm.fullDisk", "完全磁盘访问")
        case .screenRecording: return L("setup.perm.screen", "屏幕录制")
        case .microphone: return L("setup.perm.mic", "麦克风与语音识别")
        }
    }
    private func permWhy(_ p: SetupPermission, _ st: SetupPermState) -> String {
        if p == .home, st == .unavailable { return L("setup.perm.home.none", "需要 HomePlay Home 小帮手，装好再开") }
        switch p {
        case .home: return L("setup.perm.home.why", "在主屏幕和控制中心开关灯、看摄像头")
        case .contacts: return L("setup.perm.contacts.why", "FaceTime 与信息显示名字和头像")
        case .fullDisk: return L("setup.perm.fullDisk.why", "在「信息」App 里读你的对话")
        case .screenRecording: return L("setup.perm.screen.why", "把桌面上的系统小组件放进主屏幕")
        case .microphone: return L("setup.perm.mic.why", "跟 ClioTalk 说话；说「我是…」换家人")
        }
    }
    private func permSymbol(_ p: SetupPermission) -> (String, NSColor) {
        switch p {
        case .home: return ("house.fill", HPComponents.orange)
        case .contacts: return ("person.fill", HPComponents.purple)
        case .fullDisk: return ("internaldrive.fill", HPComponents.secondary)
        case .screenRecording: return ("rectangle.dashed.badge.record", HPComponents.red)
        case .microphone: return ("mic.fill", HPComponents.orange)
        }
    }

    private func setupPermissions(_ g: CGContext) {
        setupTitle(g, L("setup.perm.title", "开启权限"), baseline: 216)
        setupBody(g, L("setup.perm.body", "按了才会询问；不想现在开，可以略过。"), top: 248, size: 32, maxLines: 2)
        let all = SetupPermission.allCases
        let card = SetupCards.permissions(rows: all.count), rh = SetupCards.permissionRowH, top = card.minY
        HPComponents.groupCard(g, card, radius: SetupCards.radius(card))
        let tf = HPComponents.sf(36, weight: .semibold), sf = HPComponents.sf(27, weight: .regular)
        for (k, p) in all.enumerated() {
            let r = CGRect(x: card.minX, y: top + CGFloat(k) * rh, width: card.width, height: rh)
            if k > 0 { HPComponents.separatorLine(g, x: r.minX + 120, maxX: r.maxX, y: r.minY + 1) }
            let st = SetupFlow.perms[p] ?? .notDetermined
            let (sym, tint) = permSymbol(p)
            let ic = CGRect(x: r.minX + 32, y: r.midY - 30, width: 60, height: 60)
            g.addPath(continuousRoundedRect(ic, radius: 15)); g.setFillColor(tint.cgColor); g.fillPath()
            drawSymbol(g, sym, in: ic.insetBy(dx: 13, dy: 13), color: .white)
            // 右邊：已允許＝打勾；沒問過＝「允许」；被拒＝「打开设置」；裝不了＝不給按
            let btnW: CGFloat = st == .denied ? 196 : 148
            let textMax = r.width - 120 - 32 - btnW - 24
            drawLeft(g, Face.clipped(permTitle(p), tf, textMax), font: tf, x: r.minX + 120, y: r.minY + 44, color: HPComponents.label)
            let why = permWhy(p, st)
            drawLeft(g, Face.clipped(why, sf, textMax), font: sf, x: r.minX + 120, y: r.minY + 80, color: HPComponents.secondary)
            let value: String
            switch st {
            case .granted:
                let c = CGRect(x: r.maxX - 88, y: r.midY - 24, width: 48, height: 48)
                g.setFillColor(HPComponents.green.cgColor); g.fillEllipse(in: c)
                drawSymbol(g, "checkmark", in: c.insetBy(dx: 12, dy: 12), color: .white, weight: .bold)
                value = L("settings.perm.granted", "已允许")
            case .unavailable:
                value = L("setup.perm.unavailable", "暂时不能开")
            case .notDetermined, .denied:
                let b = CGRect(x: r.maxX - 32 - btnW, y: r.midY - 30, width: btnW, height: 60)
                let t = st == .denied ? L("setup.perm.openSettings", "打开设置") : L("setup.perm.allow", "允许")
                g.saveGState()
                if SetupFlow.pressed == .permission(p) { g.setAlpha(0.6) }
                g.addPath(HPComponents.capsulePath(b)); g.setFillColor(HPComponents.fill.cgColor); g.fillPath()
                let bf = HPComponents.fitted(t, size: 30, weight: .semibold, maxWidth: btnW - 32)
                drawLeft(g, t, font: bf, x: b.midX - Typo.width(t, bf) / 2, y: b.midY + bf.capHeight / 2, color: HPComponents.blue)
                g.restoreGState()
                SetupFlow.hits.append((.permission(p), b))
                HPAX.note(g, b, .button, t)
                value = st == .denied ? L("setup.perm.denied", "没有允许") : L("setup.perm.notYet", "还没开")
            }
            HPAX.note(g, CGRect(x: r.minX, y: r.minY, width: r.width - btnW - 40, height: r.height), .text, permTitle(p), value: "\(why)，\(value)", shape: .rounded(24))
        }
        setupPrimary(g, L("setup.continue", "继续"))
        setupSecondary(g, L("setup.skip", "略过"), action: .next)
    }

    private func setupCarPlay(_ g: CGContext) {
        setupTitle(g, L("setup.carplay.title", "连接 iPhone"))
        let bodyEnd = setupBody(g, L("setup.carplay.body", "用蓝牙配对一次，iPhone 的 App 就会用 CarPlay 显示在这里；之后靠近就会连上。"), top: SL.bodyTop, size: 32, maxLines: 2)
        // 狀態列：接收端現在的狀態（綠＝連上、藍＝配過、灰＝還沒配）
        let st: SetupFlow.PhoneState = SetupFlow.demo != nil ? .paired(L("setup.carplay.demoPhone", "Erica 的 iPhone")) :
            SetupFlow.phoneState(status: status, phones: CarPlayPhoneBook.phones.map(\.name), configPhone: ReceiverLauncher.loadConfig().phone,
                                 currentName: CarPlayPhoneBook.currentName)
        let (tint, text): (NSColor, String) = {
            switch st {
            case .connected(let n): return (HPComponents.green, n.map { String(format: L("setup.carplay.connectedNamed", "已连上「%@」"), $0) } ?? L("setup.carplay.connected", "iPhone 已连上"))
            case .paired(let n): return (HPComponents.blue, n.map { String(format: L("setup.carplay.pairedNamed", "已配对「%@」"), $0) } ?? L("setup.carplay.paired", "已配对 iPhone"))
            case .notPaired: return (HPComponents.secondary, L("setup.carplay.notPaired", "还没配对 iPhone"))
            }
        }()
        let sr = CGRect(x: 112, y: max(392, bodyEnd + 32), width: 800, height: 88)
        HPComponents.groupCard(g, sr, radius: 44)
        g.setFillColor(tint.cgColor); g.fillEllipse(in: CGRect(x: sr.minX + 40, y: sr.midY - 12, width: 24, height: 24))
        let tf = HPComponents.fitted(text, size: 32, weight: .semibold, maxWidth: sr.width - 136)
        drawLeft(g, Face.clipped(text, tf, sr.width - 136), font: tf, x: sr.minX + 96, y: sr.midY + tf.capHeight / 2, color: HPComponents.label)
        HPAX.note(g, sr, .text, text, shape: .rounded(44))
        // 步驟：放不下就縮字（英文比較長），不壓到底下的按鈕
        let steps = [L("setup.carplay.step1", "打开 iPhone 的「设置」›「蓝牙」，在「其他设备」里点这台 Mac"),   // iPhone、Mac 前後是不換行空格（中文逐字斷）
                     L("setup.carplay.step2", "iPhone 说「不支持」别理它，也别点「忽略此设备」"),
                     L("setup.carplay.step3", "配好后 iPhone 会问要不要用 CarPlay，点「连接」")]
        let top = sr.maxY + 36, room = SL.primary.minY - 24 - top
        var size: CGFloat = 30, wrapped: [[String]] = []
        while true {
            let f = HPComponents.sf(size, weight: .regular)
            wrapped = steps.map { MediaUI.wrap($0, f, 720, maxLines: 3) }
            let h = CGFloat(wrapped.reduce(0) { $0 + $1.count }) * size * 1.3 + CGFloat(steps.count - 1) * 20
            if h <= room || size <= 24 { break }
            size -= 2
        }
        let f = HPComponents.sf(size, weight: .regular), nf = HPComponents.sf(26, weight: .bold), lh = size * 1.3
        var y = top
        for (k, lines) in wrapped.enumerated() {
            let c = CGRect(x: 120, y: y + lh / 2 - 22, width: 44, height: 44)
            g.setFillColor(HPComponents.fill.cgColor); g.fillEllipse(in: c)
            let n = "\(k + 1)"
            drawLeft(g, n, font: nf, x: c.midX - Typo.width(n, nf) / 2, y: c.midY + nf.capHeight / 2, color: HPComponents.label)
            for (j, line) in lines.enumerated() { drawLeft(g, line, font: f, x: c.maxX + 24, y: y + lh / 2 + f.capHeight / 2 + CGFloat(j) * lh, color: HPComponents.label) }
            HPAX.note(g, CGRect(x: 112, y: y - 4, width: 800, height: CGFloat(lines.count) * lh + 8), .text, "\(n). \(steps[k])", shape: .rounded(16))
            y += CGFloat(max(1, lines.count)) * lh + 20
        }
        setupPrimary(g, L("setup.continue", "继续"))
        if case .notPaired = st { setupSecondary(g, L("setup.carplay.later", "以后再连"), action: .next) }
    }

    private func setupLook(_ g: CGContext) {
        setupTitle(g, L("setup.look.title", "挑一个外观"))
        setupBody(g, L("setup.look.body", "主屏幕和时钟的配色；每位家人可以各选一个。"), top: SL.bodyTop, size: 32, maxLines: 2)
        let looks = HVTruth.looks
        let cols = 4, cw: CGFloat = 200, ch: CGFloat = 128, gx: CGFloat = 32, gy: CGFloat = 8
        let x0 = 512 - (CGFloat(cols) * cw + CGFloat(cols - 1) * gx) / 2, y0: CGFloat = 384
        let current = SetupFlow.demo != nil ? looks[0].name : HPLook.name
        let nf = HPComponents.sf(24, weight: .medium)
        for (k, l) in looks.enumerated() {
            let cell = CGRect(x: x0 + CGFloat(k % cols) * (cw + gx), y: y0 + CGFloat(k / cols) * (ch + gy), width: cw, height: ch)
            let sw = CGRect(x: cell.minX, y: cell.minY, width: cw, height: 88)
            let path = continuousRoundedRect(sw, radius: 26)
            g.addPath(path); g.setFillColor(l.background_color.cgColor); g.fillPath()
            // 樣本：大數字用 numerals 色、小圓點用 secondary 色（官方 Look 的兩層主色）
            let df = FaceType.rounded(54, .bold)
            drawLeft(g, "10", font: df, x: sw.minX + 28, y: sw.midY + df.capHeight / 2, color: l.numerals_color)
            g.setFillColor(l.secondary_color.cgColor); g.fillEllipse(in: CGRect(x: sw.maxX - 60, y: sw.midY - 16, width: 32, height: 32))
            if HPAccessibility.increaseContrast { g.addPath(path); g.setStrokeColor(HPComponents.separator.cgColor); g.setLineWidth(2); g.strokePath() }
            let on = l.name == current
            if on {
                g.addPath(continuousRoundedRect(sw.insetBy(dx: -8, dy: -8), radius: 36)); g.setStrokeColor(HPComponents.blue.cgColor); g.setLineWidth(6); g.strokePath()
            }
            let name = Face.clipped(l.name, nf, cw)
            drawLeft(g, name, font: nf, x: cell.midX - Typo.width(name, nf) / 2, y: sw.maxY + 30, color: on ? HPComponents.label : HPComponents.secondary)
            HPAX.note(g, cell, .button, l.name, value: on ? L("setup.selected", "已选") : nil, shape: .rounded(28))
            SetupFlow.hits.append((.look(l.name), cell))
        }
        setupPrimary(g, L("setup.continue", "继续"))
    }

    private func setupDone(_ g: CGContext, _ now: Double) {
        setupEyes(g, now, cy: 344)
        setupTitle(g, L("setup.done.title", "设置好了"), baseline: 584)
        setupBody(g, L("setup.done.body", "想重来一次，到设置里点「重新设置」。家人可以在设置的「家人」里加入。"), top: 624)
        setupPrimary(g, L("setup.done.start", "开始使用"))
    }
}
