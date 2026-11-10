// 2.0：錶面跟手換頁（使用者 2026-10-25：「螢幕裡橫向拖／觸控板兩指橫滑＝照官方 HomeView 一頁一頁跟手換錶面；
// 在機身、邊框、底座上拖＝照舊轉身體」）。用動效包的 FacePager（1:1、rubber band、投射）與 Face.pageStart（放手時的位置與速度交給彈簧）。
//
// - 判定：按在螢幕平面的圓角方塊裡（FacePaging.insideScreen）才算；移動超過 10 pt 才決定方向——橫向（|dx| > 1.2|dy|）歸換頁，
//   直向照舊（👀 往下＝主畫面、右上往下＝控制中心、底緣往上＝主畫面；螢幕中間直拖什麼都不做——螢幕上的拖不轉身體）；
// - 一決定方向就把下一個（或上一個）錶面換上來、過場停在手指的位置（Face.pageHold）；拖回原點再往另一邊＝換成另一邊那個；
//   陣容尾端再往前是主畫面（跟滾輪、方向鍵同一條路：ShellNav .page）；第一個再往回是橡皮筋（橫軸不繞圈，2026-11-07）；
// - 放手：FacePager.release 照投射挑頁；換過去＝從手指的位置與速度接著走；退回＝同一條彈簧走回 0，到了再把原本的錶面換回來（不另外過場）；
// - 減少動態效果：不跟手，放手時照方向換（交叉淡化）；鎖定錶面時不接（拖了什麼都不做）。

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
    /// 這一下觸控板捲動歸錶面換頁嗎：換頁拖動中、或剛放手（1.5 s 內）的慣性——不管現在畫面已經換到哪一層
    static func ownsScroll(precise: Bool, dragging: Bool, momentum: Bool, sinceRelease: Double) -> Bool {
        precise && (dragging || (momentum && sinceRelease < 1.5))
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
    /// 往 dir（+1 下一個、−1 上一個）那一頁是什麼：陣容裡的錶面、主畫面（只有尾端往前）、沒有（第一個往回＝橡皮筋）
    enum Neighbor: Equatable { case face(Int), home, none }
    static func neighbor(dir: Int, index i: Int, count: Int) -> Neighbor {
        if dir > 0 { return i >= count - 1 ? .home : .face(i + 1) }
        if dir < 0 { return i <= 0 ? .none : .face(i - 1) }
        return .none
    }
    /// 這一下手勢的邊界照起手的錶面。預覽已經把畫面換成目標臉，不能改用那個 index：
    /// 從第二個往前滑時畫面先變成第一個，若用第一個的 index，canPrev 變 false，放手的停點裡沒有「上一頁」，永遠彈回第二個。
    static func gestureOrigin(_ style: FaceStyle) -> Int {
        FaceStyle.lineup.firstIndex(of: style.inLineup) ?? 0
    }
    nonisolated(unsafe) static var drag: Drag?
    nonisolated(unsafe) static var releasedAt = -10.0
    nonisolated(unsafe) static var verticalUntilEnd = false
}

extension PetView {
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
        // 邊界照起手的錶面。尾端往前是主畫面；第一個往回沒有下一頁（橡皮筋，不繞到主畫面）
        let origin = FacePaging.gestureOrigin(d.fromStyle), n = FaceStyle.lineup.count
        d.pager.canPrev = FacePaging.neighbor(dir: -1, index: origin, count: n) != .none
        d.pager.canNext = true
        d.pager.drag(x)
        x = d.pager.offset
        d.samples.append((now, x)); if d.samples.count > 5 { d.samples.removeFirst() }
        if HPMotion.reduceMotion { return }
        var want = x < -0.002 ? 1 : (x > 0.002 ? -1 : 0)
        if want != 0, d.dir == 0 || want != d.dir, FacePaging.neighbor(dir: want, index: origin, count: n) == .none { want = 0 }   // 橡皮筋那邊：不換上任何東西
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
        let target = FacePaging.neighbor(dir: dir, index: FacePaging.gestureOrigin(d.fromStyle), count: FaceStyle.lineup.count)
        guard target != .none else { return }   // 第一個往回：橡皮筋，不換
        Face.pageHold = 0; Face.pageStart = nil; Face.pageGoal = 1; Face.pageCancel = nil
        switch target {
        case .home: shellNavigate(.page(dir))   // ShellNav：陣容尾端往前是主畫面（過場同一種分頁滑動）
        case .face(let j):
            Face.pagePrev = face.style.inLineup
            Face.pageDirOverride = dir
            setFaceStyle(FaceStyle.lineup[j])
        case .none: break
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

    /// 手勢被取消、或這一下交給別人（重播交回轉身體、新的一下開始時上一下還沒收）：沒換上來就只是放掉；
    /// 換上來一半的照「退回」走——同一條彈簧回 0，到了把原本的錶面放回去（減少動態效果：直接放回去）
    func facePageCancel(now: Double) {
        guard let d = FacePaging.drag else { return }
        FacePaging.drag = nil
        guard d.dir != 0 else { return }
        guard !HPMotion.reduceMotion else { facePageRestore(d); return }
        Face.pageHold = nil
        Face.pageStart = (max(0, -CGFloat(d.dir) * d.pager.offset), 0)
        Face.pageGoal = 0
        if let t = face.faceTransition { face.faceTransition = (t.sharp, t.frosted, now, t.islandFrom) }
        Face.pageCancel = { [weak self] in self?.facePageRestore(d) }
        log("face page cancel → back")
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
            if let t = face.faceTransition { face.faceTransition = (t.sharp, t.frosted, CACurrentMediaTime(), t.islandFrom) }
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
        if let t = face.faceTransition { face.faceTransition = (t.sharp, t.frosted, now, t.islandFrom) }
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
        check(FacePaging.ownsScroll(precise: true, dragging: true, momentum: false, sinceRelease: 99)
              && FacePaging.ownsScroll(precise: true, dragging: false, momentum: true, sinceRelease: 0.4)
              && !FacePaging.ownsScroll(precise: true, dragging: false, momentum: false, sinceRelease: 0.4)
              && !FacePaging.ownsScroll(precise: true, dragging: false, momentum: true, sinceRelease: 2)
              && !FacePaging.ownsScroll(precise: false, dragging: true, momentum: false, sinceRelease: 0),
              "手勢歸屬：換頁從起手到慣性結束都歸錶面換頁，換到主畫面也不交給主畫面翻頁")   // l10n-ignore
        let w: CGFloat = 400
        check(abs(FacePaging.offset(dx: -w * (1024 + Face.pageGap) / 1024 * 0.5, screenWidth: w) + 0.5) < 1e-9, "錶面換頁：螢幕寬的一半＝半頁（1:1）")
        // 2026-11-09 錄影：第二個錶面往前滑，預覽先換成第一個，邊界若改看第一個，canPrev 變 false，放手沒有「上一頁」停點
        let n = FaceStyle.lineup.count
        let fromSecond = FacePaging.gestureOrigin(.photos)
        var pager = FacePager()
        pager.canPrev = FacePaging.neighbor(dir: -1, index: fromSecond, count: n) != .none
        pager.canNext = true
        pager.drag(0.6)
        let landed = pager.release(velocity: 2)
        var stuck = FacePager()
        stuck.canPrev = FacePaging.neighbor(dir: -1, index: 0, count: n) != .none
        stuck.drag(0.6)
        check(fromSecond == 1 && pager.canPrev && landed.target == 1 && stuck.release(velocity: 2).target == 0,
              "錶面換頁：從第二個往前的邊界照起手的那張，預覽換成第一個之後仍然停得到第一個")   // l10n-ignore
    }
}
