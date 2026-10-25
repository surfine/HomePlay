// 2.0：錶面跟手換頁（使用者 2026-10-25：「螢幕裡橫向拖／觸控板兩指橫滑＝照官方 HomeView 一頁一頁跟手換錶面；
// 在機身、邊框、底座上拖＝照舊轉身體」）。用動效包的 FacePager（1:1、rubber band、投射）與 Face.pageStart（放手時的位置與速度交給彈簧）。
//
// - 判定：按在螢幕平面的圓角方塊裡（FacePaging.insideScreen）才算；移動超過 10 pt 才決定方向——橫向（|dx| > 1.2|dy|）歸換頁，
//   直向照舊（頂端往下＝ClioTalk、右上往下＝控制中心、底緣往上＝主畫面；螢幕中間直拖＝轉身體）；
// - 一決定方向就把下一個（或上一個）錶面換上來、過場停在手指的位置（Face.pageHold）；拖回原點再往另一邊＝換成另一邊那個；
//   陣容頭尾的下一頁是主畫面（跟滾輪、方向鍵同一條路：ShellNav .page）；
// - 放手：FacePager.release 照投射挑頁；換過去＝從手指的位置與速度接著走；退回＝同一條彈簧走回 0，到了再把原本的錶面換回來（不另外過場）；
// - 減少動態效果：不跟手，放手時照方向換（交叉淡化）；鎖定錶面時不接（照舊轉身體）。

import AppKit

enum FacePaging {
    /// 按在螢幕裡（圓角方塊內，uv 0…1）
    static func insideScreen(_ uv: CGPoint?) -> Bool {
        guard let uv, uv.x >= 0, uv.x <= 1, uv.y >= 0, uv.y <= 1 else { return false }
        let r = Screen.cornerRadius / 1024
        let cx = min(max(uv.x, r), 1 - r), cy = min(max(uv.y, r), 1 - r)
        return hypot(uv.x - cx, uv.y - cy) <= r
    }
    enum Axis: Equatable { case undecided, horizontal, vertical }
    static let hysteresis: CGFloat = 10   // pt（視窗座標）
    static func classify(dx: CGFloat, dy: CGFloat) -> Axis {
        guard hypot(dx, dy) > hysteresis else { return .undecided }
        return abs(dx) > abs(dy) * 1.2 ? .horizontal : .vertical
    }
    /// 拖了多少頁（正＝往右拖＝看前一頁）：螢幕寬 w 個點對應 1024＋頁縫
    static func offset(dx: CGFloat, screenWidth w: CGFloat) -> CGFloat { w > 1 ? dx / w * 1024 / (1024 + Face.pageGap) : 0 }

    struct Drag {
        var at: NSPoint
        var uv: CGPoint?
        var axis: Axis = .undecided
        var dx: CGFloat = 0            // 累積的位移（視窗點；觸控板用 deltaX 累積）
        var dy: CGFloat = 0
        var screenW: CGFloat = 300
        var dir = 0                    // 已經換上來的方向：+1 下一個、−1 上一個、0 還沒
        var fromStyle: FaceStyle
        var fromNav: ShellNav
        var pager = FacePager()
        var samples: [(t: Double, x: CGFloat)] = []
    }
    nonisolated(unsafe) static var drag: Drag?
    nonisolated(unsafe) static var releasedAt = -10.0
    nonisolated(unsafe) static var verticalUntilEnd = false
}

extension PetView {
    private var fpIndex: Int { FaceStyle.lineup.firstIndex(of: face.style.inLineup) ?? 0 }

    /// 錶面上按下（ShellInput.shellMouseDown 裡，邊緣手勢與一般按下都先記一筆）
    func facePageArm(_ e: NSEvent, uv: CGPoint?) {
        FacePaging.drag = nil
        if let c = Face.pageCancel {   // 上一下還在退回：先把原本的錶面放回去，再開始新的
            Face.pageCancel = nil; Face.pageGoal = 1; face.faceTransition = nil; c()
        }
        guard Shell.nav.screen == .face, Shell.nav.overlay == .none, !Shell.lockFace, !face.inOverview, !face.onboardingActive,
              !showingVideo, !carVideo.active, !ClioTalkPanel.visible, FacePaging.insideScreen(uv), FaceStyle.lineup.count > 0 else { return }
        let c = screenCorners()
        let w = c.count == 4 ? hypot(c[1].x - c[0].x, c[1].y - c[0].y) : 300
        FacePaging.drag = FacePaging.Drag(at: e.locationInWindow, uv: uv, screenW: w, fromStyle: face.style, fromNav: Shell.nav)
    }

    /// 拖動：回 true＝換頁吃掉了；false＝不是換頁（呼叫端照舊）
    func facePageDragged(_ e: NSEvent) -> Bool {
        guard var d = FacePaging.drag else { return false }
        let dx = e.locationInWindow.x - d.at.x, dy = e.locationInWindow.y - d.at.y
        if d.axis == .undecided {
            d.axis = FacePaging.classify(dx: dx, dy: dy)
            if d.axis == .vertical { FacePaging.drag = nil; return false }
            if d.axis == .undecided { FacePaging.drag = d; return false }
            // 橫向：不是長按、不是轉身體
            FaceOverview.pressAt = nil; FaceOverview.pressToken += 1
            ShellInput.down = nil; ShellInput.claimed = false
            log("face page drag")
        }
        d.dx = dx
        facePageTrack(&d, now: CACurrentMediaTime())
        FacePaging.drag = d
        return true
    }

    /// 觸控板兩指橫滑（ShellInput.shellScroll 的錶面那段）：回 true＝吃掉
    func facePageScroll(_ e: NSEvent, uv: CGPoint?) -> Bool {
        guard e.hasPreciseScrollingDeltas else { return false }
        if e.momentumPhase != [] { return CACurrentMediaTime() - FacePaging.releasedAt < 1.5 }   // 放手後的慣性捲動：吃掉（不然會轉身體）
        if e.phase == .began { FacePaging.verticalUntilEnd = false }
        if FacePaging.verticalUntilEnd { if e.phase == .ended || e.phase == .cancelled { FacePaging.verticalUntilEnd = false }; return false }   // 這一下已經判成直的：整段交回去
        if e.phase == .began || (FacePaging.drag == nil && e.phase == .changed) {
            facePageArm(NSApp.currentEvent ?? e, uv: uv)
            guard var d = FacePaging.drag else { return false }
            d.at = .zero
            FacePaging.drag = d
        }
        guard var d = FacePaging.drag else { return false }
        if e.phase == .ended || e.phase == .cancelled {
            guard d.axis == .horizontal else { FacePaging.drag = nil; return false }
            return facePageRelease(now: CACurrentMediaTime())
        }
        // 觸控板的 deltaX 跟內容同向（自然捲動）：手指往左＝看下一頁
        d.dx += e.scrollingDeltaX
        d.dy += e.scrollingDeltaY
        if d.axis == .undecided {
            d.axis = FacePaging.classify(dx: d.dx, dy: d.dy)
            if d.axis == .vertical { FacePaging.drag = nil; FacePaging.verticalUntilEnd = true; return false }
            if d.axis == .undecided { FacePaging.drag = d; return abs(d.dx) > abs(d.dy) }   // 還沒決定：偏直的先交回去轉身體
        }
        facePageTrack(&d, now: CACurrentMediaTime())
        FacePaging.drag = d
        return true
    }

    private func facePageTrack(_ d: inout FacePaging.Drag, now: Double) {
        var x = FacePaging.offset(dx: d.dx, screenWidth: d.screenW)
        d.pager.canPrev = true; d.pager.canNext = true   // 頭尾的下一頁是主畫面
        d.pager.drag(x)
        x = d.pager.offset
        d.samples.append((now, x)); if d.samples.count > 5 { d.samples.removeFirst() }
        if HPMotion.reduceMotion { return }
        let want = x < -0.002 ? 1 : (x > 0.002 ? -1 : 0)
        if want != d.dir, want != 0 {
            facePageRestore(d)          // 換了方向：先放回原本的（這時候幾乎在原點，不會跳）
            facePageCommit(want, d)
            d.dir = want
        }
        if d.dir != 0 { Face.pageHold = max(0, -CGFloat(d.dir) * x) }
        face.forceDirty = true
    }

    /// 把那一頁換上來（過場停在 pageHold）：陣容中間換錶面；頭尾換到主畫面
    private func facePageCommit(_ dir: Int, _ d: FacePaging.Drag) {
        Face.pageHold = 0; Face.pageStart = nil; Face.pageGoal = 1; Face.pageCancel = nil
        let last = FaceStyle.lineup.count - 1, i = fpIndex
        if dir > 0 && i >= last || dir < 0 && i <= 0 {
            shellNavigate(.page(dir))   // ShellNav：錶面頭尾的下一頁是主畫面（過場同一種分頁滑動）
        } else {
            Face.pagePrev = face.style.inLineup
            Face.pageDirOverride = dir
            setFaceStyle(FaceStyle.lineup[i + dir])
        }
    }
    /// 放回拖之前的那個（不另外過場）
    private func facePageRestore(_ d: FacePaging.Drag) {
        guard d.dir != 0 else { return }
        if Shell.nav != d.fromNav { Shell.nav = d.fromNav; Shell.pillFrom = nil; Shell.appMorph = nil }
        if face.style != d.fromStyle { setFaceStyle(d.fromStyle) }
        face.faceTransition = nil
        Face.pageHold = nil; Face.pageStart = nil; Face.pageGoal = 1; Face.pageCancel = nil
        Face.pagePrev = face.style.inLineup
        face.forceDirty = true
    }

    /// 快照：--face-drag x＝手指拖了 x 頁、還按著（逐格：再加 HOMEPLAY_FACE_FLING 看放手）
    func facePageDemo(_ x: CGFloat) {
        guard Shell.nav.screen == .face else { return }
        _ = face.render()
        var d = FacePaging.Drag(at: .zero, uv: CGPoint(x: 0.5, y: 0.5), axis: .horizontal, fromStyle: face.style, fromNav: Shell.nav)
        d.dx = x * d.screenW * (1024 + Face.pageGap) / 1024
        facePageTrack(&d, now: CACurrentMediaTime())
        FacePaging.drag = d
        // 逐格看放手：HOMEPLAY_FACE_FLING="x,v"（Design/HPFrames.swift 把起點與速度交給彈簧），這裡只放開手指
        if ProcessInfo.processInfo.environment["HOMEPLAY_FACE_FLING"] != nil {
            Face.pageHold = nil; FacePaging.drag = nil
            if let t = face.faceTransition { face.faceTransition = (t.sharp, t.frosted, CACurrentMediaTime()) }
        }
    }

    /// 放手（滑鼠、觸控板）：回 true＝吃掉
    @discardableResult
    func facePageRelease(now: Double) -> Bool {
        guard let d = FacePaging.drag else { return false }
        FacePaging.drag = nil
        guard d.axis == .horizontal else { return false }
        FacePaging.releasedAt = now
        let sm = d.samples
        var v: CGFloat = 0
        if let a = sm.first, let b = sm.last, b.t - a.t > 0.004 { v = (b.x - a.x) / CGFloat(b.t - a.t) }
        if let b = sm.last, now - b.t > 0.08 { v = 0 }
        let r = d.pager.release(velocity: v)
        if HPMotion.reduceMotion {
            if r.target != 0 { let dir = r.target < 0 ? 1 : -1; facePageCommit(dir, d); Face.pageHold = nil }
            face.forceDirty = true
            return true
        }
        let x = d.pager.offset
        let wantDir = r.target < 0 ? 1 : (r.target > 0 ? -1 : 0)
        if wantDir != 0 && wantDir != d.dir {      // 甩的方向跟拖的不一樣（很少見）：照甩的換
            facePageRestore(d); facePageCommit(wantDir, d)
        }
        let dir = wantDir != 0 ? wantDir : d.dir
        guard dir != 0 else { facePageRestore(d); return true }
        let progress = max(0, -CGFloat(dir) * x), pv = -CGFloat(dir) * v
        Face.pageHold = nil
        Face.pageStart = (progress, pv)
        if let t = face.faceTransition { face.faceTransition = (t.sharp, t.frosted, now) }
        if wantDir == 0 {
            // 退回：同一條彈簧走回 0，到了把原本的換回來
            Face.pageGoal = 0
            let from = d
            Face.pageCancel = { [weak self] in self?.facePageRestore(from) }
        } else {
            Face.pageGoal = 1
        }
        log("face page release x=\(String(format: "%.2f", x)) v=\(String(format: "%.2f", v)) → \(wantDir == 0 ? "back" : "page \(dir)")")
        face.forceDirty = true
        return true
    }
}

// MARK: - selftest

enum FacePagingSelftest {
    static func run(_ check: (Bool, String) -> Void) {
        let r = Screen.cornerRadius / 1024
        check(FacePaging.insideScreen(CGPoint(x: 0.5, y: 0.5)) && FacePaging.insideScreen(CGPoint(x: 0.02, y: 0.5)) && !FacePaging.insideScreen(nil)
              && !FacePaging.insideScreen(CGPoint(x: 0.005, y: 0.005)) && FacePaging.insideScreen(CGPoint(x: r, y: r)) && !FacePaging.insideScreen(CGPoint(x: 1.02, y: 0.5)),
              "錶面換頁：只認螢幕的圓角方塊裡（角落外、機身上不算）")   // l10n-ignore：selftest 訊息
        check(FacePaging.classify(dx: 6, dy: 2) == .undecided && FacePaging.classify(dx: 14, dy: 3) == .horizontal && FacePaging.classify(dx: 4, dy: 14) == .vertical
              && FacePaging.classify(dx: -12, dy: 11) == .vertical, "錶面換頁：10 pt 遲滯，橫向才換頁、斜的與直的交回原本的手勢")   // l10n-ignore：selftest 訊息
        let w: CGFloat = 400
        check(abs(FacePaging.offset(dx: -w * (1024 + Face.pageGap) / 1024 * 0.5, screenWidth: w) + 0.5) < 1e-9, "錶面換頁：螢幕寬的一半＝半頁（1:1）")
    }
}
