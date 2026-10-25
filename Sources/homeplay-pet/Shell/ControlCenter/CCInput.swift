// 2.0 cc：控制中心的輸入（ShellInput 的控制中心分支各一行呼叫這裡；往上推收起的 1:1 跟手仍在 ShellInput）。
//
// 一般：點模組＝開關或打開；長按 0.5 秒＝會展開的模組長成大卡、空白處＝進編輯模式（iOS）；滑桿按下就跳到那裡、之後 1:1 跟手，
//       拖著時旋鈕變玻璃；點空白處收起（照舊）。
// 大卡：點卡外＝收回；卡裡的列、晶片、配件磚、輸出各自有動作。
// 編輯：「−」移除、右下把手換大小、拖曳排序（放在別的模組上＝排到它的位置；放在右緣的頁點＝搬到那一頁）、點空白或「完成」離開、
//       「加入控制項目」開圖庫。圖庫：拖曳或滾輪捲動、點一個加到目前這頁。

import AppKit

extension ControlCenter {
    /// 長按：按著不動 0.5 秒（tick 每幀問）
    static func checkLongPress(_ now: Double) -> Bool {
        guard let d = ShellInput.down, case .cc(nil) = d.kind, !ShellInput.claimed, !longFired, drag == nil, !gallery,
              ProcessInfo.processInfo.systemUptime - d.event.timestamp > 0.5, let uv = d.uv else { return false }
        let p = CGPoint(x: uv.x * 1024, y: uv.y * 1024)
        if expanded != nil || editing { return false }
        if let t = tile(at: p) {
            guard t.expands, !locked(t) else { return false }
            longFired = true
            HPGlass.pressUp()
            expand(t, now: now)
            return true
        }
        guard PersonCC.canEdit, !bottomButtons(editing: false).contains(where: { $0.0.contains(p) }) else { return false }
        longFired = true
        setEditing(true, now: now)
        return true
    }

    static func expand(_ t: Tile, now: Double) {
        expandFrom = rect(t)
        guard !expandFrom.isNull else { return }
        expanded = t; lastExpanded = t
        expandAnim = MotionValue("cc.expand", spring: expandSpring, from: 0, to: 1, now: now)
    }
    static func collapse(now: Double) {
        guard expanded != nil else { return }
        if let t = expanded { expandFrom = rect(t) }
        expanded = nil
        expandAnim.retarget(0, now: now, spring: Spring(damping: 1, response: 0.32))   // 收回：臨界阻尼（點按沒有動量，不回彈）
    }
    static func setEditing(_ on: Bool, now: Double) {
        editing = on
        editAnim.retarget(on ? 1 : 0, now: now)
        if !on { gallery = false; galleryAnim.retarget(0, now: now); drag = nil; layout.pages.removeAll { $0.isEmpty }; if layout.pages.isEmpty { layout.pages = [[]] }; page = min(page, layout.pages.count - 1) }
    }
    static func showPage(_ p: Int, now: Double) {
        let n = layout.pages.count
        guard p >= 0, p < n || (editing && p == n) else { return }
        if p == n { layout.appendPage() }
        page = p
        pageAnim.retarget(CGFloat(p), now: now)
    }
    /// 返回鍵（Esc、↓、往上推）：先收圖庫、大卡、編輯模式，都沒有才收控制中心
    static func back(now: Double) -> Bool {
        if gallery { gallery = false; galleryAnim.retarget(0, now: now); return true }
        if expanded != nil { collapse(now: now); return true }
        if editing { setEditing(false, now: now); return true }
        return false
    }

    static func hit(at p: CGPoint, face: Face? = nil) -> CCHit? {
        // 還沒畫過這一幀（剛打開）就照版面算；小的優先（列在卡上、「−」在模組上）
        let list = hits.isEmpty ? face.map { moduleHits(face: $0) } ?? [] : hits
        return list.filter { $0.rect.contains(p) }.min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
    }

    /// 寬滑桿：點在 x 對應的值（大卡裡的大滑桿用大軌道）
    static func sliderValue(_ t: Tile, at p: CGPoint) -> CGFloat {
        let tr: CGRect
        if expanded == t { tr = track(t, CGRect(x: expandedRect.minX, y: expandedRect.minY, width: expandedRect.width, height: 200), .s4x1, big: true) }
        else { tr = track(t, rect(t), size(t), big: false) }
        return max(0, min(1, (p.x - tr.minX) / max(1, tr.width)))
    }
}

extension PetView {
    /// 按下：滑桿回傳它（之後拖曳都交給它）；其他按下放大變亮
    func ccPress(_ p: CGPoint?) -> ControlCenter.Tile? {
        let C = ControlCenter.self, now = CACurrentMediaTime()
        C.longFired = false
        guard let p else { return nil }
        if C.gallery { C.dragScrollFrom = C.galleryScroll; return nil }
        if let h = C.hit(at: p, face: face) {
            switch h.action {
            case .slider(let t):
                C.sliding = t
                C.slideAnim = MotionValue("cc.knob", spring: .interactive, from: C.slideAnim.value(now), to: 1, now: now)
                ccSetSlider(t, C.sliderValue(t, at: p))
                return t
            case .module(let t) where C.editing:
                C.dragCandidate = (t, CGPoint(x: p.x - C.rect(t).minX, y: p.y - C.rect(t).minY))
            default: break
            }
        }
        if !C.editing, C.expanded == nil, C.tile(at: p) != nil || C.hit(at: p) != nil { HPGlass.pressDown(p) }
        face.forceDirty = true
        return nil
    }

    /// 拖曳中：滑桿、編輯排序、圖庫捲動吃掉（回 true）；一般狀態回 false 讓 ShellInput 做往上推收起
    func ccDragged(_ slider: ControlCenter.Tile?, _ p: CGPoint?, dx: CGFloat, dy: CGFloat) -> Bool {
        let C = ControlCenter.self
        if let slider, let p { ccSetSlider(slider, C.sliderValue(slider, at: p)); return true }
        if C.gallery {
            let k = 1024 / max(80, bounds.height * 0.6)   // 視窗點 → 畫布 px（螢幕約佔視窗高的六成）
            C.galleryScroll = max(0, min(max(0, C.galleryContentH - (C.galleryRect.height - 160)), C.dragScrollFrom + dy * k))
            face.forceDirty = true; return true
        }
        if C.editing {
            if let p, let cand = C.dragCandidate, hypot(dx, dy) > ShellInput.slop {
                HPGlass.pressUp()
                C.drag = (cand.tile, cand.grab, p)
                face.forceDirty = true
            }
            return true
        }
        if C.expanded != nil || C.longFired { return true }
        return false
    }

    /// 放手。回 true＝處理完了（滑桿、編輯放下、長按過、圖庫、點按）
    func ccReleased(_ slider: ControlCenter.Tile?, at p: CGPoint?, moved: Bool, claimed: Bool) -> Bool {
        let C = ControlCenter.self, now = CACurrentMediaTime()
        defer { C.dragCandidate = nil }
        if let slider {
            C.slideAnim.retarget(0, now: now, spring: .snappy)
            log("control center slide \(slider)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if C.sliding == slider, C.slideAnim.to == 0 { C.sliding = nil } }
            face.forceDirty = true; return true
        }
        if let d = C.drag {
            ccDrop(d.tile, at: d.at, now: now)
            C.drag = nil; face.forceDirty = true; return true
        }
        if C.longFired { C.longFired = false; face.forceDirty = true; return true }
        if claimed { return false }
        if moved { return C.gallery || C.editing || C.expanded != nil }
        guard let p else { return false }
        ccTap(p); return true
    }

    /// 點按（滑鼠與輔助使用同一條路）
    func ccTap(_ p: CGPoint) {
        let C = ControlCenter.self, now = CACurrentMediaTime()
        defer { face.forceDirty = true }
        guard let h = C.hit(at: p, face: face) else {
            // 空白處：圖庫外＝收圖庫；大卡外＝收回；編輯中＝離開編輯；一般＝收起控制中心
            if C.gallery { if !C.galleryRect.contains(p) { _ = C.back(now: now) }; return }
            if C.expanded != nil { if !C.expandedRect.contains(p) { C.collapse(now: now) }; return }
            if C.editing { C.setEditing(false, now: now); return }
            shellNavigate(.back); return
        }
        ccPerform(h.action, now: now)
    }

    func ccPerform(_ a: CCHit.Action, now: Double = CACurrentMediaTime()) {
        let C = ControlCenter.self, sys = CCSystem.shared
        if C.refuses(a) { log("control center \(a) locked"); return }   // 2.0 cc：遠端訪客、訪客模式不收
        switch a {
        case .module(let t):
            if C.editing { return }
            shellActivate(t)
        case .slider: break
        case .airplay:
            C.expand(.volume, now: now)
        case .edit: C.setEditing(true, now: now)
        case .done: C.setEditing(false, now: now)
        case .add:
            C.gallery = true; C.galleryScroll = 0
            C.galleryAnim = MotionValue("cc.gallery", spring: HPMotion.T.sheet.spring, from: C.galleryAnim.value(now), to: 1, now: now)
        case .galleryClose: _ = C.back(now: now)
        case .galleryAdd(let t):
            C.apply({ $0.add(t, page: C.page) }, now: now)
            if let p = C.layout.page(of: t), p != C.page { C.showPage(p, now: now) }
            C.gallery = false; C.galleryAnim.retarget(0, now: now)
        case .page(let i): C.showPage(i, now: now)
        case .remove(let t): C.apply({ $0.remove(t) }, now: now)
        case .resize(let t): C.apply({ $0.resize(t) }, now: now)
        case .header(let t):
            guard !C.locked(t) else { return }
            if t == .wifi { sys.setWiFi(!sys.wifi.on) } else if t == .bluetooth { sys.toggleBluetooth() }
        case .settings(let t):
            switch t {
            case .wifi: CCSystem.openSettings(.wifi)
            case .bluetooth: CCSystem.openSettings(.bluetooth)
            case .focusMode: CCSystem.openSettings(.focus)
            case .volume: CCSystem.openSettings(.sound)
            default: CCSystem.openSettings(.displays)
            }
        case .wifiRow: CCSystem.openSettings(.wifi)
        case .btDevice(let addr): if !C.locked(.bluetooth) { sys.toggleDevice(addr) }
        case .focusMode(let id): if !C.locked(.focusMode) { sys.toggleFocus(id) }
        case .output(let id): sys.selectOutput(id)
        case .homeTile(let id): ccToggleHome(id)
        case .scene(let id): if !C.homeIsDemo, !C.locked(.home) { HomeLink.shared.runScene(id: id) }
        case .homeOpen: C.collapse(now: now); shellNavigate(.back); shellOpenApp("home")
        case .npPrev: NowPlayingPoller.shared.control(.previous)
        case .npPlay: NowPlayingPoller.shared.control(.playPause)
        case .npNext: NowPlayingPoller.shared.control(.next)
        case .darkRow: shellActivate(.darkMode)
        case .nightRow: shellActivate(.night)
        }
        log("control center \(a)")
    }

    /// 家庭大卡的配件磚：真的家庭走 HomeWrite（本機先改、送出、失敗還原）；示範只改本機
    private func ccToggleHome(_ id: String) {
        let C = ControlCenter.self
        guard !C.locked(.home), let t = C.homeTiles.first(where: { $0.id == id }) else { return }
        if C.homeIsDemo {
            if let i = C.homeTiles.firstIndex(where: { $0.id == id }) {
                let k = "demo.l\(i + 1)"
                if C.demoHomeOn.contains(k) { C.demoHomeOn.remove(k) } else { C.demoHomeOn.insert(k) }
            }
            return
        }
        guard let p = t.powerID else { return }
        HomeWrite.perform(p, HomeValue(bool: !t.on)) { [weak self] _ in self?.face.forceDirty = true }
    }

    /// 編輯模式放下：放在別的模組上＝排到它的位置；放在頁點上＝搬到那一頁最後；其他＝這頁最後
    private func ccDrop(_ t: ControlCenter.Tile, at p: CGPoint, now: Double) {
        let C = ControlCenter.self
        if let h = C.hits.first(where: { $0.rect.contains(p) }), case .page(let i) = h.action {
            if i >= C.layout.pages.count { C.layout.appendPage() }
            C.apply({ $0.move(t, toPage: i, index: Int.max) }, now: now)
            C.showPage(min(i, C.layout.pages.count - 1), now: now)
            return
        }
        let targets = C.placed(page: C.page)
        if let over = targets.first(where: { $0.slot.tile != t && ControlCenter.frame(col: $0.col, row: $0.row, size: $0.slot.size).contains(p) }),
           let idx = C.layout.pages[C.page].firstIndex(where: { $0.tile == over.slot.tile }) {
            C.apply({ $0.move(t, toPage: C.page, index: idx) }, now: now)
        } else {
            C.apply({ $0.move(t, toPage: C.page, index: Int.max) }, now: now)
        }
    }

    func ccSetSlider(_ t: ControlCenter.Tile, _ v: CGFloat) {
        if t == .volume { ControlCenter.volume = Float(v); SystemVolume.set(Float(v)) }
        else { Shell.brightness = max(0.15, v) }
        face.forceDirty = true
    }

    /// 滾輪：滑桿上＝調；圖庫＝捲；其他＝換頁
    func ccScroll(_ e: NSEvent, _ p: CGPoint?) -> Bool {
        let C = ControlCenter.self, now = CACurrentMediaTime()
        let precise = e.hasPreciseScrollingDeltas
        if C.gallery {
            C.galleryScroll = max(0, min(max(0, C.galleryContentH - (C.galleryRect.height - 160)), C.galleryScroll - e.scrollingDeltaY * (precise ? 1 : 12)))
            face.forceDirty = true; return true
        }
        if let p, let h = C.hit(at: p), case .slider(let t) = h.action {
            ccSetSlider(t, max(0, min(1, C.level(t) + e.scrollingDeltaY * (precise ? 0.004 : 0.04))))
            return true
        }
        if C.expanded == nil, !precise || abs(e.scrollingDeltaY) > 4, now - C.lastPageScroll > 0.35 {
            let dir = e.scrollingDeltaY > 0 ? -1 : 1
            C.lastPageScroll = now
            C.showPage(C.page + dir, now: now)
            face.forceDirty = true
        }
        return true
    }

    /// 模組本身的動作（點按、輔助使用的「按下」）
    func ccActivate(_ t: ControlCenter.Tile) {
        let C = ControlCenter.self, sys = CCSystem.shared, now = CACurrentMediaTime()
        if C.locked(t) {   // 要主人：點一下只提示（右上頭像那邊的「需要主人」）
            log("control center \(t) locked"); return
        }
        switch t {
        case .wifi: sys.setWiFi(!sys.wifi.on)
        case .bluetooth: sys.toggleBluetooth()
        case .focusMode: sys.toggleFocus(sys.focus.active ?? CCSystem.defaultModes[0].id)
        case .dnd: sys.toggleFocus(CCSystem.defaultModes[0].id)
        case .nowPlaying: NowPlayingPoller.shared.control(.playPause)
        case .home: C.expand(.home, now: now)
        case .brightness, .volume: C.expand(t, now: now)
        case .darkMode:
            CCSystem.darkAppearance.toggle()
            HPTokens.dark = Shell.appearanceForced ? !HPTokens.dark : (Shell.lowLight(face) || CCSystem.darkAppearance)
            Shell.homeLayer = nil
        case .focus: if face.pomodoro.active { stopPomodoro() } else { startPomodoro() }
        case .guest:
            if Shell.guestMode, !C.canLeaveGuest { log("control center guest: needs owner"); return }   // 訪客自己關不掉
            Shell.guestMode.toggle()
        case .follow: (NSApp.delegate as? AppDelegate)?.toggleGazeFollow()
        case .carPlay:
            shellNavigate(.back)
            if ControlCenter.carPlayOn { onToggleLive?() } else { onForceEnter?() }
        case .timer: shellOpenApp("timers")
        case .alarm: shellOpenApp("alarms")
        case .lockFace: Shell.lockFace.toggle()
        case .night: Shell.manualNight.toggle()   // 第四輪：手動夜間
        case .cameras: CameraGlance.open(from: self)   // 2.0 promo：攝影機全螢幕
        case .screenMirroring: CCSystem.openSettings(.displays)   // macOS 的螢幕鏡像輸出在顯示器設定裡；HomePlay 自己不能當 AirPlay 來源
        }
        log("control center \(t)")
        face.forceDirty = true
    }
}

extension ControlCenter {
    /// 這個動作現在要不要拒絕（純函數照 locked；selftest 驗）
    static func refuses(_ a: CCHit.Action, _ i: PersonalGate.Inputs = PersonalGate.inputs) -> Bool {
        switch a {
        case .module(let t), .header(let t), .settings(let t): return locked(t, i)
        case .npPrev, .npPlay, .npNext: return locked(.nowPlaying, i)
        case .airplay, .output: return i.remoteGuest
        case .wifiRow: return locked(.wifi, i)
        case .btDevice: return locked(.bluetooth, i)
        case .focusMode: return locked(.focusMode, i)
        case .homeTile, .scene, .homeOpen: return locked(.home, i)
        case .darkRow: return locked(.darkMode, i)
        case .nightRow: return locked(.night, i)
        case .edit, .add, .remove, .resize, .galleryAdd: return !PersonCC.canEdit && !CCSystem.demo
        default: return false
        }
    }
    nonisolated(unsafe) static var dragCandidate: (tile: Tile, grab: CGPoint)?
    nonisolated(unsafe) static var dragScrollFrom: CGFloat = 0
    nonisolated(unsafe) static var lastPageScroll = 0.0
}

// MARK: 快照旗標（applyShellSnapshotFlags 一行呼叫）

extension ControlCenter {
    /// --cc-expand <模組>（長到大卡；HOMEPLAY_ANIM=cc.expand:t 凍結在第 t 秒）、--cc-collapse <模組>（從大卡收回）、
    /// --cc-edit、--cc-gallery、--cc-page N、--cc-slide volume|brightness（拖著：旋鈕變玻璃）、--cc-remote-guest（遠端訪客在用）、--cc-black（黑底，對照 macOS 截圖用）
    static func applySnapshotFlags() {
        let a = CommandLine.arguments
        func arg(_ n: String) -> String? { a.firstIndex(of: n).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        guard a.contains(where: { $0.hasPrefix("--cc-") }) || a.contains("--control-center") else { return }
        let now = CACurrentMediaTime()
        willOpen()
        if let p = arg("--cc-page").flatMap(Int.init) { page = max(0, min(p, layout.pages.count - 1)); pageAnim = MotionValue("cc.page", spring: .smooth, from: CGFloat(page), to: CGFloat(page), now: now) }
        if a.contains("--cc-edit") || a.contains("--cc-gallery") { editing = true; editAnim = MotionValue("cc.edit", spring: .smooth, from: 1, to: 1, now: now) }
        if a.contains("--cc-gallery") { gallery = true; galleryAnim = MotionValue("cc.gallery", spring: HPMotion.T.sheet.spring, from: HPMotion.frozen("cc.gallery") == nil ? 1 : 0, to: 1, now: now) }
        if let s = arg("--cc-expand"), let t = Tile(rawValue: s) {
            expand(t, now: now)
            if HPMotion.frozen("cc.expand") == nil { expandAnim = MotionValue("cc.expand", spring: expandSpring, from: 1, to: 1, now: now) }
        }
        if let s = arg("--cc-collapse"), let t = Tile(rawValue: s) {
            expandFrom = rect(t); lastExpanded = t; expanded = nil
            expandAnim = MotionValue("cc.expand", spring: Spring(damping: 1, response: 0.32), from: 1, to: 0, now: now)
        }
        if let s = arg("--cc-slide"), let t = Tile(rawValue: s), t.isSlider {
            sliding = t; slideAnim = MotionValue("cc.knob", spring: .interactive, from: 1, to: 1, now: now)
        }
        if a.contains("--cc-remote-guest") { RemotePrivacy.guestInputAt = CACurrentMediaTime() + 3600 }   // 遠端訪客在用（快照）
        if a.contains("--cc-black") { Shell.ccBackdrop = makeImage(1024, 1024) { $0.setFillColor(NSColor.black.cgColor); $0.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024)) } }
    }
}
