// 2.0 v2-music：「正在播放」上面的幾層（照 iOS 27／watchOS 27 的做法：封面那一塊換成別的內容，底下的歌名、進度、控制留著）：
// - 待播（佇列鈕）：隨機播放、重複兩顆清玻璃膠囊；「继续播放／来自 某播放列表」；播過的（這次開機以來）。點一首就播。
// - 播放到（右上 AirPlay 膠囊）：Mac 的輸出音量滑桿（Core Audio）＋輸出清單（「音樂」的 AirPlay 喇叭；別的 App 是 Mac 的音訊裝置）。
// - 「…」：喜愛、在「音樂」中顯示（加入資料庫）、播放到、睡眠定時（播客）、打開來源 App。
// - 睡眠定時（播客）：5／10／15／30／45／60 分鐘、這一集結束時。
// 底是封面糊掉、慢慢飄的「活的」背景（iOS 26 起歌詞與佇列的底）；降低動態效果時不動。
// 文字一律白色疊在暗底上；開著的切換鈕是白底黑符號（跟歌詞泡泡選中一樣），沒有玻璃疊玻璃。

import AppKit

extension HPTokens {
    /// 佇列、播放到、「…」這幾層的版面（1024 畫布；內容只佔封面那一塊，y 168…590，底下是歌名與控制）
    enum MediaPanel {
        static let top: CGFloat = 168
        static let bottom: CGFloat = 592
        static let x: CGFloat = Media.textX
        static var width: CGFloat { 1024 - x * 2 }
        /// 頂端兩顆切換鈕（隨機、重複）：高 88、寬 300、間距 20
        static let toggleH: CGFloat = 88, toggleW: CGFloat = 300, toggleGap: CGFloat = 20
        /// 清單列：高 104；標題 semibold 38、副標 regular 30（白 60%）；分區標題 semibold 30（白 60%）
        static let rowH: CGFloat = 104
        static let rowTitle: CGFloat = 38, rowSub: CGFloat = 30, section: CGFloat = 30
        static let sectionH: CGFloat = 64
        /// 音量列：高 88，軌道粗 14（未滿白 25%、已滿白）
        static let volumeH: CGFloat = 88, volumeTrack: CGFloat = 14
        /// 背景：封面糊掉後放大 1.6 倍、40 秒繞一圈；上面壓暗 0.30
        static let backdropScale: CGFloat = 1.6, backdropPeriod: Double = 40, backdropDim: CGFloat = 0.30
    }
}

extension NowPlayingPage {
    typealias MP = HPTokens.MediaPanel

    /// 「活的」封面背景：同一張模糊封面兩層，一層正轉一層反轉、慢慢漂移（快照與降低動態效果時停在 t = 0）
    static func livingBackdrop(_ g: CGContext, face: Face, blur: CGImage?, seed: String, now: Double) {
        let full = MediaUI.full
        guard let b = blur else {
            let (a, c) = MediaUI.gradient(for: seed); MediaUI.fillGradient(g, full, MediaUI.darkened(a, brightness: 0.45), MediaUI.darkened(c, brightness: 0.22)); return
        }
        let still = HPMotion.reduceMotion || SnapshotPrivacy.active
        let t = still ? 0 : now.truncatingRemainder(dividingBy: MP.backdropPeriod * 4) / MP.backdropPeriod * 2 * .pi
        let side = 1024 * MP.backdropScale
        g.saveGState(); g.clip(to: full)
        for (k, alpha) in [(1.0, 1.0), (-1.0, 0.55)] as [(Double, CGFloat)] {
            g.saveGState(); g.setAlpha(alpha)
            g.translateBy(x: 512 + CGFloat(cos(t * k)) * 90, y: 512 + CGFloat(sin(t * k * 0.7)) * 70)
            g.rotate(by: CGFloat(t * k * 0.25) + (k < 0 ? .pi : 0))
            face.drawUpright(g, b, in: CGRect(x: -side / 2, y: -side / 2, width: side, height: side))
            g.restoreGState()
        }
        g.restoreGState()
        g.setFillColor(NSColor(white: 0, alpha: MP.backdropDim).cgColor); g.fill(full)
    }

    // MARK: 畫

    /// 封面那一塊的內容（待播、播放到、「…」、睡眠定時）；hits 每次重建
    func drawPanelContent(_ g: CGContext, face: Face, _ s: (info: NowPlayingInfo, source: Source), podcast: Bool, now: Double) {
        panelHits = []
        panelBand = MP.top...MP.bottom
        // 內容區上下柔和淡出（捲動的清單不要硬切）
        g.saveGState()
        g.clip(to: CGRect(x: 0, y: MP.top - 4, width: 1024, height: MP.bottom - MP.top + 8))
        switch panel {
        case .queue: drawQueue(g, face: face)
        case .route: drawRoute(g, face: face, s)
        case .more: drawMore(g, face: face, s, podcast: podcast)
        case .sleep: drawSleep(g, face: face)
        case .none, .lyrics: break
        }
        g.restoreGState()
    }

    /// 一列：左邊可選的符號、標題、副標、右邊可選的符號；回傳列框
    @discardableResult
    private func row(_ g: CGContext, face: Face, y: CGFloat, symbol: String?, title: String, sub: String?, trailing: String? = nil,
                     dim: Bool = false, action: (() -> Void)?) -> CGRect {
        let r = CGRect(x: MP.x - 16, y: y, width: MP.width + 32, height: MP.rowH)
        guard r.maxY > panelBand.lowerBound, r.minY < panelBand.upperBound else { return r }
        let tf = HPComponents.sf(MP.rowTitle, weight: .semibold), sf = HPComponents.sf(MP.rowSub, weight: .regular)
        // 清單捲到內容區下緣時漸漸淡掉（不硬切）
        let a: CGFloat = (dim ? 0.4 : 1) * max(0, min(1, (MP.bottom - r.midY) / 60))
        let pk = Press.amount(r)
        if pk > 0.01 { g.setFillColor(NSColor(white: 1, alpha: 0.12 * pk).cgColor); g.addPath(continuousRoundedRect(r, radius: 30)); g.fillPath() }
        var x = MP.x
        if let symbol {
            face.drawSymbol(g, symbol, in: CGRect(x: x, y: r.midY - 24, width: 48, height: 48), color: HPTokens.onMedia.withAlphaComponent(a), weight: .semibold)
            x += 72
        }
        let maxW = MP.x + MP.width - x - (trailing == nil ? 0 : 70)
        if let sub, !sub.isEmpty {
            face.drawLeft(g, Face.clipped(title, tf, maxW), font: tf, x: x, y: r.midY - 4, color: HPTokens.onMedia.withAlphaComponent(a))
            face.drawLeft(g, Face.clipped(sub, sf, maxW), font: sf, x: x, y: r.midY + 34, color: HPTokens.onMedia.withAlphaComponent(0.6 * a))
        } else {
            face.drawLeft(g, Face.clipped(title, tf, maxW), font: tf, x: x, y: r.midY + tf.capHeight / 2, color: HPTokens.onMedia.withAlphaComponent(a))
        }
        if let trailing {
            face.drawSymbol(g, trailing, in: CGRect(x: MP.x + MP.width - 44, y: r.midY - 20, width: 40, height: 40), color: HPTokens.onMedia.withAlphaComponent(0.9 * a), weight: .semibold)
        }
        HPAX.note(g, r, .button, sub.map { "\(title), \($0)" } ?? title)
        // 只有看得到的部分能點（被頂端切換鈕蓋住、在下緣淡掉的不算）
        let vis = CGRect(x: r.minX, y: max(r.minY, panelBand.lowerBound), width: r.width, height: min(r.maxY, panelBand.upperBound) - max(r.minY, panelBand.lowerBound))
        if let action, !dim, a > 0.3, vis.height > 20 { panelHits.append((vis, action)) }
        return r
    }

    private func sectionLabel(_ g: CGContext, face: Face, _ s: String, sub: String? = nil, y: CGFloat) {
        guard y + MP.sectionH > MP.top, y < MP.bottom else { return }
        let f = HPComponents.sf(MP.section, weight: .semibold)
        face.drawLeft(g, s, font: f, x: MP.x, y: y + 42, color: .white)
        if let sub {
            let sf = HPComponents.sf(MP.section, weight: .regular), w = Typo.width(s, f) + 14
            face.drawLeft(g, Face.clipped(sub, sf, MP.width - w), font: sf, x: MP.x + w, y: y + 42, color: HPTokens.onMedia.withAlphaComponent(0.6))
        }
    }

    /// 白底黑符號（開）或清玻璃白符號（關）的膠囊切換鈕
    private func toggleCapsule(_ g: CGContext, face: Face, _ r: CGRect, symbol: String, title: String, on: Bool, enabled: Bool, action: @escaping () -> Void) {
        let f = HPComponents.sf(32, weight: .semibold)
        func label(_ c: CGContext, ink: NSColor) {
            let w = 40 + 14 + Typo.width(title, f), x0 = r.midX - w / 2
            face.drawSymbol(c, symbol, in: CGRect(x: x0, y: r.midY - 20, width: 40, height: 40), color: ink, weight: .semibold)
            face.drawLeft(c, title, font: f, x: x0 + 54, y: r.midY + f.capHeight / 2, color: ink)
        }
        if on {
            let k = Press.scale(r), rr = HPComponents.scaled(r, k)
            g.setFillColor(HPTokens.onMedia.withAlphaComponent(enabled ? 0.92 : 0.4).cgColor); g.addPath(MediaUI.capsule(rr)); g.fillPath()
            label(g, ink: .black)
        } else {
            g.saveGState(); if !enabled { g.setAlpha(0.4) }
            HPComponents.glassCapsule(g, r, tint: HPComponents.mediaTint) { c in label(c, ink: .white) }
            g.restoreGState()
        }
        HPAX.note(g, r, .button, title + (on ? "，" + L("cc.state.on", "打开") : ""))
        if enabled { panelHits.append((r, action)) }
    }

    private func drawQueue(_ g: CGContext, face: Face) {
        let mc = MusicControl.shared
        let e = mc.current
        let musicSource = demo != nil || MusicControl.isSource
        let r1 = CGRect(x: MP.x, y: MP.top, width: MP.toggleW, height: MP.toggleH)
        let r2 = CGRect(x: r1.maxX + MP.toggleGap, y: MP.top, width: MP.toggleW, height: MP.toggleH)
        let rep = e?.repeatMode ?? .off
        toggleCapsule(g, face: face, r1, symbol: "shuffle", title: L("music.shuffle", "随机播放"), on: e?.shuffle ?? false, enabled: musicSource && e != nil) { [weak self] in
            mc.setShuffle(!(mc.current?.shuffle ?? false)); self?.face?.forceDirty = true
        }
        toggleCapsule(g, face: face, r2, symbol: rep.symbol, title: L("music.repeat", "重复"), on: rep != .off, enabled: musicSource && e != nil) { [weak self] in
            mc.cycleRepeat(); self?.face?.forceDirty = true
        }
        let listTop = MP.top + MP.toggleH + 24
        panelBand = listTop...MP.bottom
        g.saveGState(); g.clip(to: CGRect(x: 0, y: listTop, width: 1024, height: MP.bottom - listTop))
        var y = listTop - panelScroll.offset
        if !MediaAccess.personal, demo == nil || MediaAccess.simulate != nil {
            // 待播與播放列表名稱是主人的（訪客模式、認不出、訪客裝置）
            row(g, face: face, y: y, symbol: "lock.fill", title: L("apps.locked.title", "需要主人"), sub: L("apps.locked.body", "认出主人之后才会显示"), action: nil)
            y += MP.rowH
        } else if !musicSource {
            sectionLabel(g, face: face, L("music.queue.unavailable", "这个 App 的待播清单读不到"), y: y)
            y += MP.sectionH
            row(g, face: face, y: y, symbol: "arrow.up.forward.app", title: L("music.queue.openSource", "在来源 App 里查看"), sub: nil) { [weak self] in self?.openCurrentSource() }
            y += MP.rowH
        } else if let e {
            if e.shuffle {
                sectionLabel(g, face: face, L("music.queue.next", "继续播放"), y: y); y += MP.sectionH
                row(g, face: face, y: y, symbol: "shuffle", title: L("music.queue.shuffled", "随机播放中"), sub: L("music.queue.shuffledHint", "「音乐」不公开随机后的顺序"), action: nil)
                y += MP.rowH
            } else if e.upNext.isEmpty {
                sectionLabel(g, face: face, L("music.queue.next", "继续播放"), y: y); y += MP.sectionH
                row(g, face: face, y: y, symbol: "music.note.list", title: L("music.queue.empty", "后面没有歌了"), sub: nil, action: nil); y += MP.rowH
            } else {
                sectionLabel(g, face: face, L("music.queue.next", "继续播放"), sub: e.playlist.isEmpty ? nil : String(format: L("music.queue.from", "来自「%@」"), e.playlist), y: y)
                y += MP.sectionH
                for it in e.upNext {
                    row(g, face: face, y: y, symbol: nil, title: it.title, sub: it.artist) { [weak self] in mc.playQueue(it); self?.closePanel() }
                    y += MP.rowH
                }
            }
        } else {
            sectionLabel(g, face: face, L("music.lib.loading", "读取中…"), y: y); y += MP.sectionH
        }
        if !mc.recent.isEmpty, MediaAccess.personal || (demo != nil && MediaAccess.simulate == nil) {   // 播放記錄是個人內容
            y += 16
            sectionLabel(g, face: face, L("music.queue.history", "播放记录"), y: y); y += MP.sectionH
            for it in mc.recent {
                row(g, face: face, y: y, symbol: "clock.arrow.circlepath", title: it.title, sub: it.artist, dim: it.pid.isEmpty && demo == nil) { [weak self] in
                    if !it.pid.isEmpty { mc.playTrack(pid: it.pid) }; self?.closePanel()
                }
                y += MP.rowH
            }
        }
        panelContentHeight = y + panelScroll.offset - listTop + 20
        g.restoreGState()
    }

    /// 這一刻能選的輸出：「音樂」來源＝AirPlay 喇叭；其他＝Mac 的音訊裝置
    func currentRoutes() -> [MediaRoute] {
        if let d = demo { return d.podcast ? MusicControl.demoState.routes : (MusicControl.shared.current?.routes ?? []) }
        if MusicControl.isSource, let r = MusicControl.shared.current?.routes, !r.isEmpty { return r }
        return OutputDevices.cachedList()
    }

    private func drawRoute(_ g: CGContext, face: Face, _ s: (info: NowPlayingInfo, source: Source)) {
        var y = MP.top
        // 音量（Mac 的輸出）
        let vr = CGRect(x: MP.x, y: y, width: MP.width, height: MP.volumeH)
        let level = CGFloat(ControlCenter.volume)
        face.drawSymbol(g, "speaker.fill", in: CGRect(x: vr.minX, y: vr.midY - 18, width: 36, height: 36), color: HPTokens.onMedia.withAlphaComponent(0.7))
        face.drawSymbol(g, "speaker.wave.3.fill", in: CGRect(x: vr.maxX - 50, y: vr.midY - 20, width: 50, height: 40), color: HPTokens.onMedia.withAlphaComponent(0.7))
        let track = volumeTrack
        g.setFillColor(HPTokens.onMedia.withAlphaComponent(0.25).cgColor); g.addPath(MediaUI.capsule(track)); g.fillPath()
        g.setFillColor(HPTokens.onMedia.cgColor)
        g.addPath(MediaUI.capsule(CGRect(x: track.minX, y: track.minY, width: max(track.height, track.width * level), height: track.height))); g.fillPath()
        HPAX.note(g, vr, .button, L("cc.volume", "音量"))
        panelHits.append((vr.insetBy(dx: 0, dy: -6), { [weak self] in
            guard let self, let p = self.lastTapPoint else { return }
            let v = Float(max(0, min(1, (p.x - track.minX) / track.width)))
            ControlCenter.volume = v; if self.demo == nil { SystemVolume.set(v) }; self.face?.forceDirty = true
        }))
        y += MP.volumeH + 16
        panelBand = y...MP.bottom
        y -= panelScroll.offset
        let listStart = y
        defer { panelContentHeight = y - listStart }
        let phone = s.source == .phone
        sectionLabel(g, face: face, L("music.route.title", "播放到"), sub: phone ? L("music.route.phone", "iPhone 正在播放：在 iPhone 上选择输出") : nil, y: y)
        y += MP.sectionH
        guard !phone else { return }
        for r in currentRoutes() {
            row(g, face: face, y: y, symbol: r.symbol, title: r.name, sub: nil, trailing: r.selected ? "checkmark" : nil, dim: !r.available) { [weak self] in
                MusicControl.shared.selectRoute(r); self?.face?.forceDirty = true
            }
            y += MP.rowH
        }
    }
    func volumeHit(_ p: CGPoint) -> Bool { CGRect(x: MP.x, y: MP.top - 6, width: MP.width, height: MP.volumeH + 12).contains(p) }
    var volumeTrack: CGRect { CGRect(x: MP.x + 64, y: MP.top + (MP.volumeH - MP.volumeTrack) / 2, width: MP.width - 64 - 72, height: MP.volumeTrack) }

    private func drawMore(_ g: CGContext, face: Face, _ s: (info: NowPlayingInfo, source: Source), podcast: Bool) {
        var y = MP.top
        let musicSource = !podcast && (demo != nil || MusicControl.isSource)
        if !podcast {
            let fav = MusicControl.shared.current?.favorited ?? false
            row(g, face: face, y: y, symbol: fav ? "star.fill" : "star", title: fav ? L("music.unfavorite", "取消喜爱") : L("music.favorite", "喜爱"),
                sub: musicSource ? nil : L("music.onlyMusic", "只有「音乐」App 可以"), dim: !musicSource || MusicControl.shared.current == nil) { [weak self] in
                MusicControl.shared.toggleFavorite(); self?.face?.forceDirty = true
            }
            y += MP.rowH
            row(g, face: face, y: y, symbol: "plus.circle", title: L("music.addToLibrary", "加入资料库"), sub: L("music.addToLibraryHint", "在「音乐」里显示这首，在那里加入"),
                trailing: "arrow.up.forward", dim: !musicSource) { MusicControl.shared.revealInMusic() }
            y += MP.rowH
        } else {
            let st = SleepTimer.shared
            var detail = SleepTimer.label(st.mode)
            if let r = st.remaining() { detail = String(format: L("sleep.remaining", "还剩 %@"), Self.clock(r)) }
            row(g, face: face, y: y, symbol: "moon.zzz.fill", title: L("sleep.title", "睡眠定时"), sub: detail, trailing: "chevron.right") { [weak self] in
                self?.setPanel(.sleep)
            }
            y += MP.rowH
        }
        row(g, face: face, y: y, symbol: "airplay.audio", title: L("music.route.title", "播放到"), sub: nil, trailing: "chevron.right") { [weak self] in self?.setPanel(.route) }
        y += MP.rowH
        let open: String
        switch s.source {
        case .phone: open = L("music.more.openPhone", "在 iPhone 上查看")
        case .mac: open = podcast ? L("podcasts.openMac", "打开 Mac 上的播客") : L("music.open", "打开音乐")
        }
        row(g, face: face, y: y, symbol: s.source == .phone ? "iphone" : "arrow.up.forward.app", title: open, sub: nil) { [weak self] in self?.openCurrentSource() }
    }

    private func drawSleep(_ g: CGContext, face: Face) {
        var y = MP.top - panelScroll.offset
        sectionLabel(g, face: face, L("sleep.title", "睡眠定时"), y: y); y += MP.sectionH
        let st = SleepTimer.shared
        for m in SleepTimer.choices {
            row(g, face: face, y: y, symbol: nil, title: SleepTimer.label(m), sub: nil, trailing: st.mode == m ? "checkmark" : nil) { [weak self] in
                st.set(m); self?.setPanel(.more)
            }
            y += MP.rowH
        }
        panelContentHeight = y + panelScroll.offset - MP.top + 20
    }
}
