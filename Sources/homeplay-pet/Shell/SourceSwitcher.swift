// 2.0 align D：看得見的 CarPlay 切換入口（藥丸＝Home 鍵之外的那一半）。
//
// - CarPlay 會話活著、但 HomeView 在前面（face.status == .background）：藥丸右下掛一顆 CarPlay 角標（HPTokens.Size.sourceBadge）。
// - 這時長按藥丸 0.5 s：藥丸在原處長成「HomeView」，「CarPlay」從它底下滴出來（跟 ClioTalk 同一種 HPDrip 頸子，merge 40；
//   拉開到 48 就斷）。左右排開會壓到頂列的標題，所以往下滴。手指拖到哪顆選哪顆（另一顆 55%），放手切過去；
//   選回 HomeView＝不動。減少動態效果：直接出現兩顆，沒有頸子。
//   沒有 CarPlay 會話時，長按藥丸照舊展開第一個活動（LiveActivityStack）。
// - 快照：--source home（角標）、--source carplay（兩顆拉開、選 CarPlay）；HOMEPLAY_ANIM=source.split:t 凍結在拉開的第 t 秒。
// 「切過去」只動顯示源（AppDelegate.switchSource：不拆會話），跟硬按、空白鍵、Esc 同一條。

import AppKit

enum SourceSwitcher {
    enum Side: Equatable { case home, carPlay }
    /// 長按拉出來的狀態：開始的時刻、目前選哪一顆
    nonisolated(unsafe) static var open: (start: Double, side: Side)?
    /// 快照：--source home|carplay
    nonisolated(unsafe) static var demo: Side? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--source"), i + 1 < a.count else { return nil }
        return a[i + 1] == "carplay" ? .carPlay : (a[i + 1] == "home" ? .home : nil)
    }()
    static let longPress: Double = 0.5

    /// CarPlay 會話活著但在背景（HomeView 在前面）
    static func carPlayBehind(_ face: Face) -> Bool { face.status == .background || demo != nil }

    /// 拉開的進度 0…1（凍結：source.split）
    static func progress(_ now: Double) -> CGFloat {
        guard let o = open else { return 0 }
        if HPMotion.reduceMotion { return 1 }
        let t = HPMotion.frozen("source.split") ?? (now - o.start)
        return ClioTalkPanel.progress(HPMotion.T.sourceSplit.spring, CGFloat(t))
    }
    /// 兩顆的終點：HomeView 留在頂列 105 線上；CarPlay 在它底下，中間 sourceGap
    static func targets() -> (home: CGRect, carPlay: CGRect) {
        let s = HPTokens.Size.sourceCapsule, g = HPTokens.Size.sourceGap, cy = HPTokens.cornerControlCenter
        let home = CGRect(x: 512 - s.width / 2, y: cy - s.height / 2, width: s.width, height: s.height)
        return (home, home.offsetBy(dx: 0, dy: s.height + g))
    }
    /// 這一幀兩顆的位置：兩顆都從藥丸出發，下面那顆往下滴
    static func rects(pill: CGRect, e: CGFloat) -> (home: CGRect, carPlay: CGRect) {
        let t = targets()
        return (Shell.lerp(pill, t.home, e), Shell.lerp(pill, t.carPlay, e))
    }
    /// 兩顆之間的頸子（HPDrip：上是膠囊、下是水滴）
    static func neck(_ a: CGRect, _ b: CGRect) -> CGPath? {
        HPMotion.reduceMotion ? nil : HPDrip.neck(top: a, bottom: b, merge: HPDrip.merge)
    }
    /// 拖到哪：兩顆中間那條線以上＝HomeView
    static func side(atY y: CGFloat) -> Side {
        let t = targets()
        return y < (t.home.maxY + t.carPlay.minY) / 2 ? .home : .carPlay
    }
}

extension Face {
    /// 藥丸右下的 CarPlay 角標（會話在背景）
    func drawSourceBadge(_ g: CGContext, pill r: CGRect) {
        let d = HPTokens.Size.sourceBadge
        let b = CGRect(x: r.maxX - d * 0.75, y: r.maxY - d * 0.75, width: d, height: d)
        g.saveGState()
        g.setFillColor(NSColor.white.cgColor); g.fillEllipse(in: b.insetBy(dx: -2, dy: -2))   // 2 px 白邊：跟藥丸分開
        g.setFillColor(HPComponents.green.cgColor); g.fillEllipse(in: b)
        drawSymbol(g, "car.fill", in: b.insetBy(dx: d * 0.22, dy: d * 0.22), color: .white)
        g.restoreGState()
    }

    /// 長按拉出的兩顆（取代這一幀的藥丸）；回 true＝畫了。材質跟藥丸同一種（膠囊照錶面年代：黑／Liquid Glass／霧黑），
    /// 兩顆加頸子是同一條路徑，一起畫才看得出是同一顆被拉開
    func drawSourceSwitcher(_ g: CGContext, pill: CGRect, now: Double) -> Bool {
        guard let o = SourceSwitcher.open else { return false }
        let e = SourceSwitcher.progress(now)
        let (h, c) = SourceSwitcher.rects(pill: pill, e: e)
        func cap(_ r: CGRect) -> CGPath { CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil) }
        let look = capsuleLook() == .system ? .black : capsuleLook()
        let glassy = look == .glass
        let ink: NSColor = glassy && !HPTokens.dark ? .black : .white
        let font = HPType.sf(32, .semibold)
        let textK = max(0, min(1, (e - 0.6) / 0.3))   // 字等拉開六成才出來（還連在一起時不寫字）
        func body(_ paths: [CGPath], _ rects: [CGRect]) {
            switch look {
            case .glass:
                if let b = g.makeImage(), faceGlass(g, paths, backdrop: b, clear: false) { break }
                for r in rects { drawCapsuleBody(g, r, look: .glass, animating: true) }
            case .smoke: for r in rects { smokePill(g, r) }
            default: for p in paths { g.addPath(p) }; g.setFillColor(NSColor.black.cgColor); g.fillPath()
            }
        }
        func label(_ r: CGRect, _ t: String) {
            guard textK > 0 else { return }
            let w = min(Typo.width(t, font), r.width - 32)
            g.saveGState(); g.setAlpha(textK)
            drawLeft(g, Face.clipped(t, font, r.width - 32), font: font, x: r.midX - w / 2, y: r.midY + 11, color: ink)
            g.restoreGState()
        }
        let neck = SourceSwitcher.neck(h, c)
        let (sel, other) = o.side == .home ? (h, c) : (c, h)
        // 沒選到的那顆 55%（跟頸子一起，頸子屬於「被拉開的那一截」）
        g.saveGState(); g.setAlpha(1 - 0.45 * textK); g.beginTransparencyLayer(auxiliaryInfo: nil)
        body([cap(other)] + (neck.map { [$0] } ?? []), [other])
        label(other, o.side == .home ? "CarPlay" : "HomeView")
        g.endTransparencyLayer(); g.restoreGState()
        body([cap(sel)], [sel])
        label(sel, o.side == .home ? "HomeView" : "CarPlay")
        return true
    }
}

extension PetView {
    /// 按在藥丸上：會話在背景時排一個 0.5 s 的長按，到了還沒拖、還按著就拉出兩顆
    func sourceSwitcherArm(_ e: NSEvent, at p: CGPoint) {
        guard SourceSwitcher.carPlayBehind(face), LiveActivityStack.pillHit.contains(p), Shell.nav.overlay == .none else { return }
        let ts = e.timestamp
        DispatchQueue.main.asyncAfter(deadline: .now() + SourceSwitcher.longPress) { [weak self] in
            guard let self, let d = ShellInput.down, d.event.timestamp == ts, !ShellInput.claimed else { return }
            SourceSwitcher.open = (CACurrentMediaTime(), .home)
            HPGlass.pressUp()
            self.face.forceDirty = true
            log("source switcher open")
        }
    }
    /// 拉開之後的拖動：照 y 選邊；回 true＝吃掉（不會變成往下拉的 ClioTalk）
    func sourceSwitcherDragged(uv: CGPoint?) -> Bool {
        guard SourceSwitcher.open != nil else { return false }
        if let uv { SourceSwitcher.open?.side = SourceSwitcher.side(atY: uv.y * 1024) }
        face.forceDirty = true
        return true
    }
    /// 放手：選 CarPlay 就切過去（只換顯示源）；回 true＝吃掉
    func sourceSwitcherReleased() -> Bool {
        guard let o = SourceSwitcher.open else { return false }
        SourceSwitcher.open = nil
        ShellInput.down = nil; ShellInput.claimed = false
        face.forceDirty = true
        log("source switcher → \(o.side)")
        if o.side == .carPlay, SourceSwitcher.demo == nil { onSwitchSource?() }   // 快照／腳本的假會話不去碰真的 CarPlay
        return true
    }
}
