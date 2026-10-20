// 长按换錶面总览——照「HomePlay 屏幕介面稿」的 Gallery.dc.html（像 Apple Watch 长按錶面）。
// 长按屏幕 0.5 s 进入：当前錶面缩小在中间、白圈框住，左右露出邻居；滚轮或 ← → 挑，点按或 Return 套用，Esc 或 8 s 不动取消。

import AppKit

/// 总览的状态（extension 不能存属性，放在这里；桌宠只有一张 Face）
enum FaceOverview {
    /// 快照用：--overview 强制进入，也不会闲置退出
    static var forced = false
    static var active = false
    static var sel = 0                       // 选中第几个（FaceStyle.allCases 的下标）
    static var pos: CGFloat = 0, vel: CGFloat = 0   // 轮播位置（弹簧追 sel）
    static var enter: CGFloat = 0, enterV: CGFloat = 0   // 进场：0 整屏 … 1 缩成卡片
    static var lastInput = 0.0, lastThumbPass = -1e9
    static var thumbs: [FaceStyle: (img: CGImage, t: Double)] = [:]
    static var rendering = false             // 正在画缩图（里面那次 render 不要再画总览）
    // 长按与总览里的点按
    static var pressAt: NSPoint?, pressToken = 0
    static var downAt: NSPoint?, swallowUp = false
    static var lastWheel = 0.0, wheelAcc: CGFloat = 0

    static let idleTimeout = 8.0
    static let longPress = 0.5
    static let slop: CGFloat = 4

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
        S.active = true
        S.sel = FaceStyle.allCases.firstIndex(of: style) ?? 0
        S.pos = CGFloat(S.sel); S.vel = 0
        S.enter = animated ? 0 : 1; S.enterV = 0
        S.lastInput = now; S.thumbs = [:]; S.lastThumbPass = -1e9
        forceDirty = true
        log("overview on")
    }
    /// 收起总览；confirm 时回选中的錶面（PetView 去换）
    @discardableResult
    func endOverview(confirm: Bool) -> FaceStyle? {
        let S = FaceOverview.self
        guard S.active else { return nil }
        S.active = false; S.thumbs = [:]; forceDirty = true
        log("overview \(confirm ? "confirm" : "cancel")")
        return confirm ? FaceStyle.allCases[S.sel] : nil
    }
    func moveOverview(_ d: Int, now: Double = CACurrentMediaTime()) {
        let S = FaceOverview.self
        S.sel = FaceOverview.step(S.sel, d, count: FaceStyle.allCases.count)
        S.lastInput = now; forceDirty = true
    }

    /// tickLive 里调：弹簧动画、闲置退出、缩图每秒换一次；要重画回 true
    func tickOverview(_ now: Double, _ dt: Double) -> Bool {
        let S = FaceOverview.self
        // 快照用：开机时 --style 可能晚一步才换，跟着当前錶面重进一次
        if S.forced && (!S.active || FaceStyle.allCases[S.sel] != style) { beginOverview(now: now, animated: false) }
        guard S.active else { return false }
        if !S.forced, now - S.lastInput > FaceOverview.idleTimeout { endOverview(confirm: false); return true }
        var dirty = false
        if S.pos != CGFloat(S.sel) || S.vel != 0 {
            (S.pos, S.vel) = FaceOverview.spring(S.pos, S.vel, to: CGFloat(S.sel), dt: CGFloat(dt)); dirty = true
        }
        if S.enter != 1 || S.enterV != 0 {
            (S.enter, S.enterV) = FaceOverview.spring(S.enter, S.enterV, to: 1, dt: CGFloat(dt)); dirty = true
        }
        if now - S.lastThumbPass >= 3 { dirty = true }   // 缩图 3 秒刷新一次就够
        return dirty
    }

    /// 别的錶面的缩图：临时换 style 画一张，缩成 544 存起来，一秒内重用
    private func overviewThumb(_ st: FaceStyle, _ now: Double) -> CGImage {
        let S = FaceOverview.self
        if let c = S.thumbs[st], now - c.t < 3 { return c.img }
        let old = style, fd = forceDirty
        S.rendering = true
        style = st
        let full = render(now)
        style = old; forceDirty = fd
        S.rendering = false
        let small = makeImage(544, 544) { g in
            g.scaleBy(x: 544 / 1024, y: 544 / 1024)
            drawUpright(g, full, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        }
        S.thumbs[st] = (small, now)
        return small
    }

    /// render 里 bannerUntil 那行前面调：整面盖上总览
    func drawOverview(_ g: CGContext, _ now: Double) {
        let S = FaceOverview.self
        guard S.active, !S.rendering, let live = g.makeImage() else { return }
        let all = FaceStyle.allCases, curIdx = all.firstIndex(of: style) ?? 0
        if now - S.lastThumbPass >= 3 { S.lastThumbPass = now }
        let e = max(0, min(1.05, S.enter)), ek = min(1, e)

        g.setFillColor(NSColor(srgbRed: 0.043, green: 0.047, blue: 0.055, alpha: ek).cgColor)
        g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))

        // 稿 640 → ×1.6：中卡 544 见方、圆角 73.6、中心 (512, 425.6)；邻卡 480、中心往下 19.2、间距 585.6、透明 .55
        let spacing: CGFloat = 585.6
        let lo = max(0, Int((S.pos - 1.8).rounded(.up))), hi = min(all.count - 1, Int((S.pos + 1.8).rounded(.down)))
        guard lo <= hi else { return }
        // 远的先画，中间那张最后盖上
        let order = (lo...hi).sorted { abs(CGFloat($0) - S.pos) > abs(CGFloat($1) - S.pos) }
        for i in order {
            let d = CGFloat(i) - S.pos, k = min(1, abs(d))
            let side = 544 - 64 * k
            let card = CGRect(x: 512 + d * spacing - side / 2, y: 425.6 + 19.2 * k - side / 2, width: side, height: side)
            // 进场：中卡从整屏缩下来，邻卡淡入
            let isCenter = abs(d) < 0.5
            let r = isCenter ? lerp(CGRect(x: 0, y: 0, width: 1024, height: 1024), card, e) : card
            let radius = (73.6 - 9 * k) * (isCenter ? ek : 1)
            let alpha = (1 - 0.45 * k) * (isCenter ? 1 : ek)
            let img = i == curIdx ? live : overviewThumb(all[i], now)
            let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)

            g.saveGState()
            g.setAlpha(alpha)
            if isCenter {
                g.setShadow(offset: CGSize(width: 0, height: -48 * ek), blur: 96 * ek, color: NSColor(white: 0, alpha: 0.5).cgColor)
                g.setFillColor(NSColor.black.cgColor); g.addPath(path); g.fillPath()
                g.setShadow(offset: .zero, blur: 0, color: nil)
            }
            g.addPath(path); g.clip()
            drawUpright(g, img, in: r)
            g.restoreGState()

            // 白圈只跟着正中那张，滑走时淡掉
            let ring = (1 - min(1, abs(d) * 2)) * ek
            if ring > 0.01 {
                let rr = r.insetBy(dx: -3.2, dy: -3.2)
                g.setStrokeColor(NSColor(white: 1, alpha: 0.9 * ring).cgColor); g.setLineWidth(6.4)
                g.addPath(CGPath(roundedRect: rr, cornerWidth: radius + 3.2, cornerHeight: radius + 3.2, transform: nil)); g.strokePath()
            }
        }

        // 名字和页点
        let near = max(0, min(all.count - 1, Int(S.pos.rounded())))
        drawCentered(g, all[near].title, font: Self.rounded(48, weight: .bold), kern: 0, y: 784,
                     color: NSColor.white.withAlphaComponent(ek))
        let dot: CGFloat = 14.4, gap: CGFloat = 12.8
        let w = CGFloat(all.count) * dot + CGFloat(all.count - 1) * gap
        for i in all.indices {
            g.setFillColor(NSColor(white: 1, alpha: (i == S.sel ? 1 : 0.35) * ek).cgColor)
            g.fillEllipse(in: CGRect(x: 512 - w / 2 + CGFloat(i) * (dot + gap), y: 819, width: dot, height: dot))
        }
        drawCentered(g, L("overview.hint", "滚轮或 ← → 挑选 · 点按套用 · Esc 取消"), font: Self.rounded(26, weight: .semibold), kern: 1, y: 950,
                     color: NSColor.white.withAlphaComponent(0.42 * ek))
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
    private func confirmOverview() {
        if let st = face.endOverview(confirm: true) { setFaceStyle(st) }
    }

    /// uv：点到屏幕的哪里（nil＝没点到屏幕）
    func overviewMouseDown(_ e: NSEvent, uv: CGPoint?) -> Bool {
        let S = FaceOverview.self
        if showingVideo { return false }                 // 直播时点按全交给 CarPlay
        if face.inOverview {
            S.downAt = e.locationInWindow; overviewTouch(); return true
        }
        S.pressToken += 1; S.pressAt = nil; S.swallowUp = false
        // 长按屏幕（单击、不在直播）0.5 s 不动 → 进总览
        guard !showingVideo, !face.bannerShowing, uv != nil, e.clickCount == 1, !e.modifierFlags.contains(.command) else { return false }
        S.pressAt = e.locationInWindow
        let token = S.pressToken
        DispatchQueue.main.asyncAfter(deadline: .now() + FaceOverview.longPress) { [weak self] in
            guard let self, S.pressToken == token, S.pressAt != nil, !self.showingVideo, !self.face.inOverview else { return }
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
        if abs(dx) > 30 { face.moveOverview(dx < 0 ? 1 : -1); return true }   // 横着拖一下＝滑一格
        guard let uv else { face.endOverview(confirm: false); return true }   // 点屏幕外面＝取消
        if uv.x < 0.22 { face.moveOverview(-1) }
        else if uv.x > 0.78 { face.moveOverview(1) }
        else { confirmOverview() }
        return true
    }

    func overviewScroll(_ e: NSEvent) -> Bool {
        guard face.inOverview, !showingVideo, !e.modifierFlags.contains(.option) else { return false }
        let S = FaceOverview.self, now = CACurrentMediaTime()
        overviewTouch()
        if e.hasPreciseScrollingDeltas {
            if !e.momentumPhase.isEmpty { return true }   // 手指离开后的惯性不算，免得滑过头
            // 触控板：手指横滑或竖滑累积 40 pt 走一格
            if e.phase == .began { S.wheelAcc = 0 }
            let fx = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
            let fy = e.isDirectionInvertedFromDevice ? -e.scrollingDeltaY : e.scrollingDeltaY
            S.wheelAcc += abs(fx) >= abs(fy) ? fx : fy
            if abs(S.wheelAcc) >= 40, now - S.lastWheel > 0.18 {
                face.moveOverview(S.wheelAcc > 0 ? -1 : 1); S.wheelAcc = 0; S.lastWheel = now
            }
        } else if e.scrollingDeltaY != 0, now - S.lastWheel > 0.12 {
            face.moveOverview(e.scrollingDeltaY > 0 ? -1 : 1); S.lastWheel = now   // 跟平时滚轮换錶面同向
        }
        return true
    }

    func overviewKeyDown(_ e: NSEvent) -> Bool {
        guard face.inOverview, !showingVideo, !e.modifierFlags.contains(.command) else { return false }
        overviewTouch()
        switch e.keyCode {
        case 53: face.endOverview(confirm: false)            // Esc：只收起总览，不退出
        case 36, 76: confirmOverview()                       // Return / Enter
        case 123: face.moveOverview(-1)
        case 124: face.moveOverview(1)
        default: return false
        }
        return true
    }
}
