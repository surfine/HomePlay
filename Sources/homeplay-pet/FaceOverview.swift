// 錶面畫廊——一張海報就是一張臉（Rushmore：Scroll to switch between faces／zoom in, show leading/trailing）。
// 進入：連按兩下並按住，或原來的長按 0.5 s。左右露出鄰居；點中間卡鋪滿並套用（zoom out）。
// 選中卡上方是名字，下方是 Customize 與圓形＋。＋只把焦點放到 AddFace，不改目前這張臉。
// 訪客或鎖定時不開（Secure rendering enabled. Dismissing gallery and editor.）。

import AppKit

/// 总览的状态（extension 不能存属性，放在这里；桌宠只有一张 Face）
enum FaceOverview {
    enum Page { case gallery, templates, editor }
    /// 快照用：--overview 强制进入，也不会闲置退出
    static var forced = false
    static var active = false
    static var page: Page = .gallery
    static var sel = 0                       // 海報下標；等於張數時是末尾的 AddFace
    static var pos: CGFloat = 0, vel: CGFloat = 0   // 轮播位置（弹簧追 sel）
    static var enter: CGFloat = 0, enterV: CGFloat = 0   // 进场：0 整屏 … 1 缩成卡片
    static var lastInput = 0.0, lastThumbPass = -1e9
    static var thumbs: [Int: (img: CGImage, t: Double)] = [:]
    static var rendering = false             // 正在画缩图（里面那次 render 不要再画总览）
    // 长按与总览里的点按
    static var pressAt: NSPoint?, pressToken = 0
    static var downAt: NSPoint?, swallowUp = false
    static var lastWheel = 0.0, wheelAcc: CGFloat = 0

    static let idleTimeout = 8.0
    static let longPress = 0.5
    static let slop: CGFloat = 10   // 長按進總覽的容差（視窗點）：4 太敏感，滑鼠/觸控板很容易被手抖取消

    /// 訪客模式、遠端訪客，或個人內容的門關著：不開畫廊，開著也收起。
    static var secureBlocked: Bool {
        Shell.guestMode || CommandLine.arguments.contains("--guest")
            || PersonalGate.inputs.remoteGuest || !PersonalGate.allowed
    }

    /// 畫廊格數＝海報張數再加末尾的 AddFace。
    static var slotCount: Int { PosterLibraryStore.all.count + 1 }

    /// 影片量測（/tmp/homeplay-refs/rambo/f/0033、0049）：名字在卡上方；Customize 深色藥丸在左、圓形＋在右，成組放在選中卡下方。
    /// 1024 畫布、卡中心 y=425.6、邊長 544 時卡底約 698。沒有固件像素常數。
    static let customizeRect = CGRect(x: 344, y: 748, width: 248, height: 64)
    static let addRect = CGRect(x: 608, y: 744, width: 72, height: 72)

    static func templateRect(_ i: Int) -> CGRect {
        CGRect(x: 88 + CGFloat(i % 4) * 216, y: 180 + CGFloat(i / 4) * 150, width: 200, height: 134)
    }
    static func editorRow(_ i: Int) -> CGRect {
        CGRect(x: 96, y: 708 + CGFloat(i) * 52, width: 832, height: 46)
    }
    static let editorDone = CGRect(x: 392, y: 28, width: 240, height: 56)
    static let templateCancel = CGRect(x: 392, y: 900, width: 240, height: 56)

    /// 选中往前/往后挪一格，到头就停（不绕回，跟页点一致）
    static func step(_ i: Int, _ d: Int, count: Int) -> Int { max(0, min(count - 1, i + d)) }

    /// 临界阻尼弹簧的解析解（ω=18，约 0.3 s 到位），dt 再大也稳
    static func spring(_ x: CGFloat, _ v: CGFloat, to target: CGFloat, dt: CGFloat, omega: CGFloat = 18) -> (CGFloat, CGFloat) {
        let c1 = x - target, c2 = v + omega * c1, e = exp(-omega * dt)
        let nx = target + (c1 + c2 * dt) * e
        let nv = (c2 - omega * (c1 + c2 * dt)) * e
        if abs(nx - target) < 0.0005 && abs(nv) < 0.005 { return (target, 0) }
        return (nx, nv)
    }
}

extension Face {
    var inOverview: Bool { FaceOverview.active }

    func beginOverview(now: Double = CACurrentMediaTime(), animated: Bool = true) {
        let S = FaceOverview.self
        if S.secureBlocked { return }
        // 打開畫廊時，目前這張跟螢幕上的錶面對上。快照不寫偏好。
        let live = style.inLineup.rawValue
        if PosterLibraryStore.all.indices.contains(PosterLibraryStore.index),
           PosterLibraryStore.current.extras.faceKind != live {
            var c = PosterLibraryStore.current
            c.extras.faceKind = live
            let write = !Face.snapshotFreeze
            PosterLibraryStore.replace(PosterLibraryStore.index, with: c, persistChanges: write)
            PosterConfiguration.suppressLibraryWrite = true
            PosterConfiguration.current = c
            PosterConfiguration.suppressLibraryWrite = false
        }
        S.active = true
        S.page = .gallery
        S.sel = min(PosterLibraryStore.index, max(0, S.slotCount - 1))
        S.pos = CGFloat(S.sel); S.vel = 0
        S.enter = animated ? 0 : 1; S.enterV = 0
        S.lastInput = now; S.thumbs = [:]; S.lastThumbPass = -1e9
        forceDirty = true
        log("overview on")
    }
    /// 收起总览。套用哪一張由 PetView 在收起前寫好；這裡不再改錶面。
    @discardableResult
    func endOverview(confirm: Bool) -> FaceStyle? {
        let S = FaceOverview.self
        guard S.active else { return nil }
        let picked: FaceStyle? = confirm && S.page == .gallery && PosterLibraryStore.all.indices.contains(S.sel)
            ? PosterLibraryStore.all[S.sel].galleryFace : nil
        S.active = false; S.page = .gallery; S.thumbs = [:]; forceDirty = true
        log("overview \(confirm ? "confirm" : "cancel")")
        return picked
    }
    func moveOverview(_ d: Int, now: Double = CACurrentMediaTime()) {
        let S = FaceOverview.self
        guard S.page == .gallery else { return }
        S.sel = FaceOverview.step(S.sel, d, count: S.slotCount)
        S.lastInput = now; forceDirty = true
    }

    /// tickLive 里调：弹簧动画、闲置退出、缩图每秒换一次；要重画回 true
    func tickOverview(_ now: Double, _ dt: Double) -> Bool {
        let S = FaceOverview.self
        if S.active, S.secureBlocked { endOverview(confirm: false); return true }
        if S.forced, !S.active, !S.secureBlocked { beginOverview(now: now, animated: false) }
        // --style 可能比 --overview 晚一步。快照才把目前這張對上螢幕上的錶面，不寫偏好。
        if S.forced, S.active, PosterLibraryStore.current.galleryFace != style.inLineup {
            var c = PosterLibraryStore.current
            c.extras.faceKind = style.inLineup.rawValue
            PosterLibraryStore.replace(PosterLibraryStore.index, with: c, persistChanges: false)
            PosterConfiguration.suppressLibraryWrite = true
            PosterConfiguration.current = c
            PosterConfiguration.suppressLibraryWrite = false
            S.thumbs = [:]
            forceDirty = true
        }
        guard S.active else { return false }
        if !S.forced, now - S.lastInput > FaceOverview.idleTimeout { endOverview(confirm: false); return true }
        var dirty = false
        if S.page == .gallery, S.pos != CGFloat(S.sel) || S.vel != 0 {
            (S.pos, S.vel) = FaceOverview.spring(S.pos, S.vel, to: CGFloat(S.sel), dt: CGFloat(dt)); dirty = true
        }
        if S.enter != 1 || S.enterV != 0 {
            (S.enter, S.enterV) = FaceOverview.spring(S.enter, S.enterV, to: 1, dt: CGFloat(dt)); dirty = true
        }
        if now - S.lastThumbPass >= 3 { dirty = true }   // 缩图 3 秒刷新一次就够
        return dirty
    }

    /// 某一張海報的縮圖：暫時換成它的錶面與配置來畫，不寫進目前這張臉。
    private func overviewThumb(_ i: Int, _ now: Double) -> CGImage {
        let S = FaceOverview.self
        if let c = S.thumbs[i], now - c.t < 3 { return c.img }
        let items = PosterLibraryStore.all
        guard items.indices.contains(i) else {
            return makeImage(8, 8) { $0.setFillColor(NSColor.black.cgColor); $0.fill(CGRect(x: 0, y: 0, width: 8, height: 8)) }
        }
        let cfg = items[i]
        let oldStyle = style, oldForce = forceDirty
        let oldCurrent = PosterConfiguration.current, oldSnap = PosterConfiguration.snapshotOverride
        S.rendering = true
        PosterConfiguration.suppressLibraryWrite = true
        PosterConfiguration.snapshotOverride = cfg
        PosterConfiguration.current = cfg
        style = cfg.galleryFace
        textLayerCache = nil; staticCache = nil
        let full = render(now)
        style = oldStyle
        PosterConfiguration.current = oldCurrent
        PosterConfiguration.snapshotOverride = oldSnap
        PosterConfiguration.suppressLibraryWrite = false
        textLayerCache = nil; staticCache = nil
        forceDirty = oldForce
        S.rendering = false
        let small = makeImage(544, 544) { g in
            g.scaleBy(x: 544 / 1024, y: 544 / 1024)
            drawUpright(g, full, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        }
        S.thumbs[i] = (small, now)
        return small
    }

    /// render 里 bannerUntil 那行前面调：整面盖上总览
    func drawOverview(_ g: CGContext, _ now: Double) {
        let S = FaceOverview.self
        guard S.active, !S.rendering, let live = g.makeImage() else { return }
        if now - S.lastThumbPass >= 3 { S.lastThumbPass = now }
        let e = max(0, min(1.05, S.enter)), ek = min(1, e)
        g.setFillColor(NSColor(srgbRed: 0.043, green: 0.047, blue: 0.055, alpha: 1).cgColor)
        g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        switch S.page {
        case .templates: drawTemplatePage(g)
        case .editor: drawEditorPage(g, now, live)
        case .gallery: drawGallery(g, now, live, e, ek)
        }
    }

    private func drawGallery(_ g: CGContext, _ now: Double, _ live: CGImage, _ e: CGFloat, _ ek: CGFloat) {
        let S = FaceOverview.self
        let items = PosterLibraryStore.all
        let count = items.count + 1
        // 稿 640 → ×1.6：中卡 544 见方、中心 (512, 425.6)；邻卡 480、中心往下 19.2、间距 585.6
        let spacing: CGFloat = 585.6
        let lo = max(0, Int((S.pos - 1.8).rounded(.up))), hi = min(count - 1, Int((S.pos + 1.8).rounded(.down)))
        guard lo <= hi else { return }
        let order = (lo...hi).sorted { abs(CGFloat($0) - S.pos) > abs(CGFloat($1) - S.pos) }
        for i in order {
            let d = CGFloat(i) - S.pos, k = min(1, abs(d))
            let side = 544 - 64 * k
            let card = CGRect(x: 512 + d * spacing - side / 2, y: 425.6 + 19.2 * k - side / 2, width: side, height: side)
            let isCenter = abs(d) < 0.5
            let r = isCenter ? lerp(CGRect(x: 0, y: 0, width: 1024, height: 1024), card, e) : card
            let radius = Screen.cornerRadius * r.width / Screen.side
            let alpha = (1 - 0.45 * k) * (isCenter ? 1 : ek)
            let path = continuousRoundedRect(r, radius: radius)
            g.saveGState()
            g.setAlpha(alpha)
            if isCenter {
                g.setShadow(offset: CGSize(width: 0, height: -48 * ek), blur: 96 * ek, color: NSColor(white: 0, alpha: 0.5).cgColor)
                g.setFillColor(NSColor.black.cgColor); g.addPath(path); g.fillPath()
                g.setShadow(offset: .zero, blur: 0, color: nil)
            }
            g.addPath(path); g.clip()
            if i < items.count {
                let applied = i == PosterLibraryStore.index && items[i].galleryFace == style
                let img = applied ? live : overviewThumb(i, now)
                drawUpright(g, img, in: r)
            } else {
                g.setFillColor(NSColor(white: 0.14, alpha: 1).cgColor)
                g.fill(r)
                drawPlus(g, CGRect(x: r.midX - 28, y: r.midY - 28, width: 56, height: 56), weight: 6, color: .white)
            }
            g.restoreGState()
        }

        let near = max(0, min(count - 1, Int(S.pos.rounded())))
        if near < items.count {
            drawCentered(g, items[near].galleryName, font: Self.rounded(40, weight: .bold), kern: 0.5, y: 132,
                         color: NSColor.white.withAlphaComponent(ek))
        }
        let chrome = ek * (1 - min(1, abs(S.pos - CGFloat(S.sel)) * 2))
        if chrome > 0.02 { drawGalleryChrome(g, chrome) }
        drawCentered(g, L("overview.hint", "滚轮或 ← → 挑表面 · 点按套用 · Esc 取消"), font: Self.rounded(22, weight: .semibold), kern: 0.4, y: 980,
                     color: NSColor.white.withAlphaComponent(0.42 * ek))
    }

    /// Customize 藥丸與圓形＋。鋪滿（enter 還是 0）時 chrome 為 0，不畫。
    private func drawGalleryChrome(_ g: CGContext, _ a: CGFloat) {
        let pill = FaceOverview.customizeRect
        g.saveGState()
        g.setAlpha(a)
        g.setFillColor(NSColor(white: 0.16, alpha: 1).cgColor)
        g.addPath(continuousRoundedRect(pill, radius: pill.height / 2)); g.fillPath()
        drawCentered(g, L("overview.customize", "自定义"), font: Self.rounded(26, weight: .semibold), kern: 0, y: pill.midY + 9,
                     color: .white)
        let plus = FaceOverview.addRect
        g.setFillColor(NSColor(white: 0.16, alpha: 1).cgColor)
        g.fillEllipse(in: plus)
        drawPlus(g, plus.insetBy(dx: 22, dy: 22), weight: 3.5, color: .white)
        g.restoreGState()
    }

    private func drawPlus(_ g: CGContext, _ r: CGRect, weight: CGFloat, color: NSColor) {
        g.setFillColor(color.cgColor)
        g.fill(CGRect(x: r.midX - weight / 2, y: r.minY, width: weight, height: r.height))
        g.fill(CGRect(x: r.minX, y: r.midY - weight / 2, width: r.width, height: weight))
    }

    private func drawTemplatePage(_ g: CGContext) {
        drawCentered(g, L("settings.posters.template", "选择模板"), font: Self.rounded(34, weight: .bold), kern: 0, y: 120, color: .white)
        for (i, look) in HVTruth.looks.enumerated() {
            let r = FaceOverview.templateRect(i)
            g.setFillColor(look.background_color.cgColor)
            g.addPath(continuousRoundedRect(r, radius: 28)); g.fillPath()
            drawCentered(g, "10:09", font: Self.rounded(28, weight: .semibold), kern: 0, y: r.midY + 4, color: look.numerals_color)
            drawCentered(g, look.name, font: Self.rounded(16, weight: .medium), kern: 0, y: r.maxY - 18, color: look.secondary_color)
        }
        let cancel = FaceOverview.templateCancel
        g.setFillColor(NSColor(white: 0.16, alpha: 1).cgColor)
        g.addPath(continuousRoundedRect(cancel, radius: 28)); g.fillPath()
        drawCentered(g, L("sb.cancel", "取消"), font: Self.rounded(24, weight: .semibold), kern: 0, y: cancel.midY + 8, color: .white)
    }

    /// 全螢幕編輯：上面是這張臉，下面是已有的四個欄位再加上錶面種類。不畫佔位槽。
    private func drawEditorPage(_ g: CGContext, _ now: Double, _ live: CGImage) {
        let items = PosterLibraryStore.all
        guard items.indices.contains(FaceOverview.sel) else { return }
        let c = items[FaceOverview.sel]
        let preview = CGRect(x: 232, y: 100, width: 560, height: 560)
        let img = (FaceOverview.sel == PosterLibraryStore.index && c.galleryFace == style) ? live : overviewThumb(FaceOverview.sel, now)
        g.saveGState()
        let path = continuousRoundedRect(preview, radius: Screen.cornerRadius * preview.width / Screen.side)
        g.addPath(path); g.clip()
        drawUpright(g, img, in: preview)
        g.restoreGState()
        let done = FaceOverview.editorDone
        g.setFillColor(NSColor(white: 0.16, alpha: 1).cgColor)
        g.addPath(continuousRoundedRect(done, radius: 28)); g.fillPath()
        drawCentered(g, L("overview.done", "完成"), font: Self.rounded(24, weight: .semibold), kern: 0, y: done.midY + 8, color: .white)
        let rows: [(String, String)] = [
            (L("overview.field.look", "Look"), c.look),
            (L("overview.field.typeface", "字体"), c.typeface.title),
            (L("overview.field.numerals", "数字"), c.numerals == nil ? L("settings.posters.autoNumerals", "自动数字") : L("settings.posters.customNumerals", "自订数字")),
            (L("overview.field.style", "版式"), c.style.title),
            (L("overview.field.face", "表面"), c.galleryFace.title),
        ]
        for (i, row) in rows.enumerated() {
            let r = FaceOverview.editorRow(i)
            g.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
            g.addPath(continuousRoundedRect(r, radius: 16)); g.fillPath()
            drawLeft(g, row.0, font: Self.rounded(22, weight: .semibold), x: r.minX + 22, y: r.midY + 8, color: NSColor(white: 1, alpha: 0.55))
            drawLeft(g, row.1, font: Self.rounded(22, weight: .semibold), x: r.maxX - 22 - Typo.width(row.1, Self.rounded(22, weight: .semibold)), y: r.midY + 8, color: .white)
        }
    }

    private func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }
}

// MARK: - PetView 的输入钩子（main.swift 里各方法开头一行调用；回 true＝这下给总览吃掉了）

extension PetView {
    private func overviewTouch() {
        FaceOverview.lastInput = CACurrentMediaTime()
    }
    /// 點中間那張：套用並鋪滿。焦點在 AddFace 時改開模板頁，不改目前這張臉。
    private func confirmOverview() {
        let S = FaceOverview.self
        switch S.page {
        case .editor: S.page = .gallery; face.forceDirty = true; return
        case .templates: return
        case .gallery: break
        }
        if S.sel >= PosterLibraryStore.all.count {
            S.page = .templates; face.forceDirty = true; return
        }
        applyGalleryPoster(S.sel)
        _ = face.endOverview(confirm: false)
    }

    /// 套用第 i 張海報：換成它的 Look 與錶面種類。
    private func applyGalleryPoster(_ i: Int) {
        guard PosterLibraryStore.all.indices.contains(i) else { return }
        if i != PosterLibraryStore.index { _ = PosterLibraryStore.select(i) }
        let c = PosterLibraryStore.current
        PosterConfiguration.current = c
        HPLook.select(c.look)
        setFaceStyle(c.galleryFace)
        face.textLayerCache = nil; face.staticCache = nil
        log("overview apply \(c.galleryFace.rawValue)")
    }

    /// uv：点到屏幕的哪里（nil＝没点到屏幕）
    func overviewMouseDown(_ e: NSEvent, uv: CGPoint?) -> Bool {
        let S = FaceOverview.self
        if showingVideo { return false }                 // 直播时点按全交给 CarPlay
        if face.inOverview {
            S.downAt = e.locationInWindow; overviewTouch(); return true
        }
        S.pressToken += 1; S.pressAt = nil; S.swallowUp = false
        // 長按 0.5 s，或連按兩下並按住（Rushmore：Double-tap and hold to edit face.）。
        // 主畫面／App 不進（那裡的長按是圖示編輯／選單），也不搶藥丸。
        guard Shell.nav.screen == .face, !showingVideo, !face.bannerShowing, uv != nil,
              e.clickCount == 1 || e.clickCount == 2, !e.modifierFlags.contains(.command),
              !S.secureBlocked else { return false }
        S.pressAt = e.locationInWindow
        let token = S.pressToken
        DispatchQueue.main.asyncAfter(deadline: .now() + FaceOverview.longPress) { [weak self] in
            guard let self, S.pressToken == token, S.pressAt != nil, !self.showingVideo, !self.face.inOverview,
                  !S.secureBlocked else { return }
            S.pressAt = nil; S.swallowUp = true
            self.face.beginOverview()
            self.mood.show(.wink, for: 0.5, now: CACurrentMediaTime())
        }
        return false
    }

    func overviewMouseDragged(_ e: NSEvent) -> Bool {
        let S = FaceOverview.self
        if let a = S.pressAt, hypot(e.locationInWindow.x - a.x, e.locationInWindow.y - a.y) > FaceOverview.slop {
            S.pressAt = nil; S.pressToken += 1           // 动了就是拖，不算长按
        }
        return face.inOverview || S.swallowUp
    }

    func overviewMouseUp(_ e: NSEvent, uv: CGPoint?) -> Bool {
        let S = FaceOverview.self
        S.pressAt = nil; S.pressToken += 1
        if S.swallowUp { S.swallowUp = false; return true }   // 长按那下放手：留在总览
        guard face.inOverview else { return false }
        let start = S.downAt ?? e.locationInWindow; S.downAt = nil
        let dx = e.locationInWindow.x - start.x
        guard let uv else {
            if S.page == .gallery { face.endOverview(confirm: false) } else { S.page = .gallery; face.forceDirty = true }
            return true
        }
        let p = CGPoint(x: uv.x * 1024, y: uv.y * 1024)
        switch S.page {
        case .editor: return editorClick(p)
        case .templates: return templateClick(p)
        case .gallery:
            if abs(dx) > 30 { face.moveOverview(dx < 0 ? 1 : -1); return true }
            if FaceOverview.customizeRect.insetBy(dx: -8, dy: -8).contains(p), PosterLibraryStore.all.indices.contains(S.sel) {
                S.page = .editor; overviewTouch(); face.forceDirty = true; return true
            }
            if FaceOverview.addRect.insetBy(dx: -8, dy: -8).contains(p) {
                let f = FaceGallery.focusAdd(count: PosterLibraryStore.all.count, index: PosterLibraryStore.index)
                S.sel = f.sel; overviewTouch(); face.forceDirty = true; return true
            }
            if uv.x < 0.22 { face.moveOverview(-1) }
            else if uv.x > 0.78 { face.moveOverview(1) }
            else { confirmOverview() }
            return true
        }
    }

    private func editorClick(_ p: CGPoint) -> Bool {
        overviewTouch()
        if FaceOverview.editorDone.contains(p) {
            FaceOverview.page = .gallery; face.forceDirty = true; return true
        }
        for i in 0..<5 where FaceOverview.editorRow(i).contains(p) {
            cycleEditorField(i); return true
        }
        FaceOverview.page = .gallery; face.forceDirty = true
        return true
    }

    private func templateClick(_ p: CGPoint) -> Bool {
        overviewTouch()
        if FaceOverview.templateCancel.contains(p) {
            FaceOverview.page = .gallery; face.forceDirty = true; return true
        }
        for i in HVTruth.looks.indices where FaceOverview.templateRect(i).contains(p) {
            addGalleryPoster(look: HVTruth.looks[i]); return true
        }
        FaceOverview.page = .gallery; face.forceDirty = true
        return true
    }

    /// 點一個 Look：沿用設定裡的模板（字體照出廠配對），新增、選中、回到畫廊。
    private func addGalleryPoster(look: HVTruth.Look) {
        var c = PosterLibraryStore.current
        c.look = look.name
        if let pair = PosterConfiguration.factoryPresets.first(where: { $0.config.look == look.name }) {
            c.typeface = pair.config.typeface
        }
        c.extras.lookChosen = true
        let i = PosterLibraryStore.add(c)
        PosterConfiguration.current = PosterLibraryStore.current
        HPLook.select(look.name)
        setFaceStyle(PosterLibraryStore.current.galleryFace)
        FaceOverview.sel = i
        FaceOverview.pos = CGFloat(i); FaceOverview.vel = 0
        FaceOverview.page = .gallery
        FaceOverview.thumbs = [:]
        face.forceDirty = true
        log("overview add \(look.name)")
    }

    /// 編輯器一行點一下往下一個值。寫回這一張；不是目前套用的那張就不換螢幕上的臉。
    private func cycleEditorField(_ field: Int) {
        let i = FaceOverview.sel
        guard PosterLibraryStore.all.indices.contains(i) else { return }
        var c = PosterLibraryStore.all[i]
        switch field {
        case 0:
            let looks = HVTruth.looks
            let cur = looks.firstIndex { $0.name == c.look } ?? 0
            let next = looks[(cur + 1) % looks.count]
            c.look = next.name
            c.extras.lookChosen = true
            if let pair = PosterConfiguration.factoryPresets.first(where: { $0.config.look == next.name }) {
                c.typeface = pair.config.typeface
            }
        case 1:
            let all = ClockLook.Font.allCases
            let cur = all.firstIndex(of: c.typeface) ?? 0
            c.typeface = all[(cur + 1) % all.count]
        case 2:
            let all: [PosterConfiguration.Numerals?] = [nil] + PosterConfiguration.Numerals.allCases
            let cur = all.firstIndex { $0 == c.numerals } ?? 0
            c.numerals = all[(cur + 1) % all.count]
        case 3:
            let all = PosterConfiguration.Style.allCases
            let cur = all.firstIndex(of: c.style) ?? 0
            c.style = all[(cur + 1) % all.count]
        case 4:
            let all = FaceStyle.lineup
            let cur = all.firstIndex(of: c.galleryFace) ?? 0
            c.extras.faceKind = all[(cur + 1) % all.count].rawValue
        default: return
        }
        FaceOverview.thumbs[i] = nil
        if i == PosterLibraryStore.index {
            PosterConfiguration.current = c
            if field == 0 { HPLook.select(c.look) }
            if field == 4 { setFaceStyle(c.galleryFace) }
        } else {
            PosterLibraryStore.replace(i, with: c)
        }
        face.textLayerCache = nil; face.staticCache = nil
        face.forceDirty = true
    }

    func overviewScroll(_ e: NSEvent) -> Bool {
        guard face.inOverview, !showingVideo, !e.modifierFlags.contains(.option) else { return false }
        let S = FaceOverview.self, now = CACurrentMediaTime()
        overviewTouch()
        guard S.page == .gallery else { return true }
        if e.hasPreciseScrollingDeltas {
            if !e.momentumPhase.isEmpty { return true }   // 手指离开后的惯性不算，免得滑过头
            if e.phase == .began { S.wheelAcc = 0 }
            let fx = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
            let fy = e.isDirectionInvertedFromDevice ? -e.scrollingDeltaY : e.scrollingDeltaY
            S.wheelAcc += abs(fx) >= abs(fy) ? fx : fy
            if abs(S.wheelAcc) >= 40, now - S.lastWheel > 0.18 {
                face.moveOverview(S.wheelAcc > 0 ? -1 : 1); S.wheelAcc = 0; S.lastWheel = now
            }
        } else if e.scrollingDeltaY != 0, now - S.lastWheel > 0.12 {
            face.moveOverview(e.scrollingDeltaY > 0 ? -1 : 1); S.lastWheel = now
        }
        return true
    }

    func overviewKeyDown(_ e: NSEvent) -> Bool {
        guard face.inOverview, !showingVideo, !e.modifierFlags.contains(.command) else { return false }
        overviewTouch()
        let S = FaceOverview.self
        switch e.keyCode {
        case 53:
            if S.page != .gallery { S.page = .gallery; face.forceDirty = true }
            else { face.endOverview(confirm: false) }
        case 36, 76: confirmOverview()
        case 123: face.moveOverview(-1)
        case 124: face.moveOverview(1)
        default: return false
        }
        return true
    }
}
