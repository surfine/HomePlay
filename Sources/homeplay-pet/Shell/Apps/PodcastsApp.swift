// 播客：
// - 正在播播客（iPhone 經 CarPlay，或 Mac 的「播客」經 MediaRemote）：全螢幕「正在播放」（NowPlayingPage；後退 15、快轉 30、倍速、點進度條跳、
//   「…」裡的睡眠定時與播放到）。左上的播客圓鈕進資料庫。
// - 資料庫（v2-music）：待播清單、節目、節目的單集——讀 Mac 上「播客」自己的本機資料庫（PodcastLibrary.swift，只讀、要使用者先同意）；
//   點一集＝在「播客」裡打開那一集（macOS 沒有公開的路能叫它直接播某一集）。沒同意前是說明卡＋「顯示我的播客」。
// - CarPlay 連著 →「在 iPhone 上播放」（走原本進入 CarPlay 的路，iPhone 上的播客就在那裡）。

import AppKit

final class PodcastsApp: PetApp {
    let id = "podcasts"
    var title: String { L("app.podcasts", "播客") }
    let icon = AppIcon(color: srgb(0x9b3ce0), symbol: "antenna.radiowaves.left.and.right", system: "/System/Applications/Podcasts.app")
    static let bundle = "com.apple.podcasts"
    private static let purple = srgb(0x9b3ce0)
    private weak var face: Face?

    enum Page: Equatable { case library, show(PodcastShow) }
    private var page: Page = .library
    /// 正在播播客時也能進資料庫（左上播客圓鈕）；關掉 App 再開回到「正在播放」
    private var browsing = false
    private var scroll = AppScroll()
    private var content: CGFloat = 0
    private var hits: [(CGRect, () -> Void)] = []

    // 2.0 逼真化：不重複膠囊上的 App 名稱；說明＝系統空狀態（符號、標題、灰字），主要動作紫色實心、次要玻璃
    private static let primary = CGRect(x: 512 - 300, y: 700, width: 600, height: 104)
    private static let secondary = CGRect(x: 512 - 300, y: 828, width: 600, height: 100)
    private static let rowH: CGFloat = 124, x0: CGFloat = 64, top: CGFloat = 206

    /// CarPlay 連著（畫面在播、暫停、在背景，或手機的正在播放資料正在進來）
    static func carPlayConnected(_ face: Face) -> Bool {
        [.live, .paused, .pausedResume, .background].contains(face.status) || PhoneNowPlayingBridge.shared.active
    }

    func showsNowPlaying(face: Face) -> Bool { nowPlayingShown(face) }
    private func nowPlayingShown(_ face: Face) -> Bool { !browsing && NowPlayingPage.shared.isPodcast(face: face) }
    /// 2.0 r2：在播播客時是全螢幕媒體（不畫外殼的返回鈕與時間；左上播客圓鈕＝資料庫）
    private var mediaFullScreen: Bool { face.map { nowPlayingShown($0) } ?? false }
    var showsCloseButton: Bool { !mediaFullScreen }
    var showsClock: Bool { !mediaFullScreen }
    var backSymbol: String { if case .show = page { return "chevron.left" }; return browsing ? "chevron.left" : "xmark" }

    func didOpen(now: Double) {
        browsing = false; page = .library; scroll = AppScroll()
        NowPlayingPage.shared.closePanel()
        PodcastLibrary.shared.refresh()
    }
    func handleBack(now: Double) -> Bool {
        guard let f = face else { return false }
        if nowPlayingShown(f) { return NowPlayingPage.shared.handleBack() }
        if case .show = page { page = .library; scroll = AppScroll(); f.forceDirty = true; return true }
        if browsing { browsing = false; f.forceDirty = true; return true }
        return false
    }

    func tick(_ now: Double) -> Bool {
        if HPComponents.needsFrame(now) { return true }
        guard let f = face, nowPlayingShown(f) else { return false }
        return NowPlayingPage.shared.tick(now, face: f)
    }

    func liveActivity(face: Face, now: Double) -> LiveActivity? { nil }   // 「正在播放」的藥丸歸音樂 App，點下去也能看到

    func render(into g: CGContext, face: Face, rect: CGRect, now: Double) {
        self.face = face
        if PodcastLibrary.shared.onChange == nil { PodcastLibrary.shared.onChange = { [weak face] in face?.forceDirty = true } }
        if nowPlayingShown(face) {
            NowPlayingPage.shared.render(g, face: face, now: now, withLibraryStrip: false)
            return
        }
        g.setFillColor(HPComponents.bg.cgColor); g.fill(rect)
        hits = []
        let lib = PodcastLibrary.shared
        // v2-music：待播與訂閱是主人的（訪客模式、認不出、家人、訪客裝置都看不到）
        if !MediaAccess.personal, !lib.demo || MediaAccess.simulate != nil {
            AppUI.drawLock(g, face, title: L("podcasts.library", "资料库")); AppUI.title(g, face, L("podcasts.library", "资料库")); return
        }
        if !PodcastLibrary.allowed && !lib.demo {
            drawIntro(g, face)
            return
        }
        switch page {
        case .library: drawLibrary(g, face, lib)
        case .show(let s): drawShow(g, face, lib, s)
        }
    }

    // MARK: 說明（還沒同意讀資料庫）

    private func drawIntro(_ g: CGContext, _ face: Face) {
        AppUI.title(g, face, L("podcasts.library", "资料库"))
        face.drawSymbol(g, "antenna.radiowaves.left.and.right", in: CGRect(x: 512 - 64, y: 250, width: 128, height: 128), color: HPComponents.purple)
        let hf = HPComponents.fitted(L("podcasts.intro.title", "显示你在 Mac 上的播客"), size: 48, weight: .bold, maxWidth: 860)
        HPComponents.center(g, face, L("podcasts.intro.title", "显示你在 Mac 上的播客"), hf, y: 460, HPComponents.label)
        let bf = HPComponents.sf(34, weight: .regular)
        let text = L("podcasts.intro.body", "桌宠会只读地打开「播客」在这台 Mac 上的资料库，显示待播清单和节目。不修改、不上传、不记录。")
        for (i, l) in MediaUI.wrap(text, bf, 800, maxLines: 4).enumerated() { HPComponents.center(g, face, l, bf, y: 530 + CGFloat(i) * 46, HPComponents.secondary) }
        HPComponents.filledButton(g, face, Self.primary, L("podcasts.intro.allow", "显示我的播客"), tint: Self.purple, symbol: "books.vertical")
        hits.append((Self.primary, { [weak self] in
            PodcastLibrary.allowed = true; PodcastLibrary.shared.refresh(force: true); self?.face?.forceDirty = true
        }))
        if let f = self.face, Self.carPlayConnected(f) {
            HPComponents.glassButton(g, face, Self.secondary, L("podcasts.play", "在 iPhone 上播放"), symbol: "iphone")
            hits.append((Self.secondary, { (NSApp.delegate as? AppDelegate)?.enterCarPlay() }))
        } else {
            HPComponents.glassButton(g, face, Self.secondary, L("podcasts.openMac", "打开 Mac 上的播客"), symbol: "macbook")
            hits.append((Self.secondary, { Self.openPodcasts(nil) }))
        }
    }

    // MARK: 資料庫

    private func drawLibrary(_ g: CGContext, _ face: Face, _ lib: PodcastLibrary) {
        var y = Self.top - scroll.offset
        switch lib.state {
        case .off, .loading:
            HPComponents.spinner(g, in: CGRect(x: 512 - 30, y: 300, width: 60, height: 60), ink: HPComponents.secondary)
        case .missing, .failed:
            let missing = lib.state == .missing
            HPComponents.emptyState(g, face, symbol: missing ? "antenna.radiowaves.left.and.right" : "exclamationmark.triangle.fill", tint: HPComponents.purple,
                                    title: missing ? L("podcasts.missing", "这台 Mac 上还没有播客资料库") : L("podcasts.failed", "读不到播客的资料库"),
                                    body: missing ? nil : L("podcasts.failedHint", "「播客」更新后格式可能变了；可以先在「播客」里收听。"), top: 250)
            HPComponents.glassButton(g, face, Self.secondary, L("podcasts.openMac", "打开 Mac 上的播客"), symbol: "macbook")
            hits.append((Self.secondary, { Self.openPodcasts(nil) }))
        case .ready:
            if NowPlayingPage.shared.isPodcast(face: face) {
                y = rows(g, face, top: y, [(L("nowplaying.playing", "正在播放"), NowPlayingPage.shared.state(face: face)?.info.title ?? "", nil, "waveform", "chevron.right",
                                            { [weak self] in self?.browsing = false; self?.face?.forceDirty = true })], middleTitle: true)
                y += 40
            }
            y = section(g, face, L("podcasts.upNext", "待播清单"), y)
            if lib.upNext.isEmpty {
                y = rows(g, face, top: y, [(L("podcasts.upNextEmpty", "待播清单是空的"), L("podcasts.upNextEmptyHint", "在「播客」里关注节目，新单集会出现在这里"), nil, "tray", nil, {})])
            } else {
                y = rows(g, face, top: y, lib.upNext.map { e in (e.title, [e.show, e.detail].filter { !$0.isEmpty }.joined(separator: " · "), e.progress, "play.circle.fill", nil, { [weak self] in self?.play(e) }) }, middleTitle: true)
            }
            y += 40
            if !lib.shows.isEmpty {
                y = section(g, face, L("podcasts.shows", "节目"), y)
                y = rows(g, face, top: y, lib.shows.map { s in (s.title, s.author, nil, "square.stack", "chevron.right", { [weak self] in
                    guard let self else { return }
                    PodcastLibrary.shared.loadEpisodes(s); self.page = .show(s); self.scroll = AppScroll(); self.face?.forceDirty = true
                }) })
                y += 40
            }
            y = rows(g, face, top: y, [(L("podcasts.openMac", "打开 Mac 上的播客"), nil, nil, "arrow.up.forward.app", nil, { Self.openPodcasts(nil) }),
                                       (L("podcasts.stopReading", "停止读取播客资料库"), nil, nil, "hand.raised", nil, { [weak self] in
                                           PodcastLibrary.allowed = false; PodcastLibrary.shared.refresh(); self?.face?.forceDirty = true })])
        }
        content = y + scroll.offset - Self.top + 40
        HPComponents.topFade(g, HPComponents.bg, solidTo: 190, height: 50)
        AppUI.title(g, face, L("podcasts.library", "资料库"))
    }

    private func drawShow(_ g: CGContext, _ face: Face, _ lib: PodcastLibrary, _ s: PodcastShow) {
        var y = Self.top - scroll.offset
        if let eps = lib.episodes[s.id], eps.isEmpty {   // 2.0 depth：讀到了但一集都沒有（或讀失敗）：說一句，不是空白頁
            HPComponents.emptyState(g, face, symbol: "list.bullet", tint: AppUI.secondary, title: L("podcasts.show.empty", "这个节目还没有单集"),
                                    body: L("podcasts.show.empty.hint", "在 Mac 的「播客」里下载或更新后，这里就会显示。"), top: 300)
        } else if let eps = lib.episodes[s.id] {
            y = section(g, face, L("podcasts.episodes", "单集"), y)
            y = rows(g, face, top: y, eps.map { e in (e.title, e.detail, e.progress, e.played ? "checkmark.circle" : "play.circle.fill", nil, { [weak self] in self?.play(e) }) }, middleTitle: true)
        } else {
            HPComponents.spinner(g, in: CGRect(x: 512 - 30, y: 300, width: 60, height: 60), ink: HPComponents.secondary)
        }
        content = y + scroll.offset - Self.top + 40
        HPComponents.topFade(g, HPComponents.bg, solidTo: 190, height: 50)
        AppUI.title(g, face, s.title)
    }

    private func section(_ g: CGContext, _ face: Face, _ s: String, _ y: CGFloat) -> CGFloat {
        if y + 64 > 150, y < 1024 { HPComponents.sectionHeader(g, face, s, x: Self.x0, baseline: y + 42, size: 38) }
        return y + 64
    }

    /// 分組卡裡的列：標題、副標、可選的進度、左邊紫色符號、右邊 chevron；回傳卡片下緣
    /// middleTitle＝標題太長用中間刪節號（單集名稱頭尾都要留，HIG-LIST-23）
    private func rows(_ g: CGContext, _ face: Face, top: CGFloat, _ list: [(String, String?, Double?, String, String?, () -> Void)], middleTitle: Bool = false) -> CGFloat {
        guard !list.isEmpty else { return top }
        let card = CGRect(x: Self.x0, y: top, width: 1024 - Self.x0 * 2, height: CGFloat(list.count) * Self.rowH)
        let visible = card.maxY > 150 && card.minY < 1024
        if visible { HPComponents.groupCard(g, card); g.saveGState(); g.addPath(continuousRoundedRect(card, radius: 52)); g.clip() }
        let tf = HPComponents.sf(38, weight: .regular), df = HPComponents.sf(30, weight: .regular)
        for (k, r) in list.enumerated() {
            let rr = CGRect(x: card.minX, y: top + CGFloat(k) * Self.rowH, width: card.width, height: Self.rowH)
            hits.append((rr, r.5))
            guard rr.maxY > 150, rr.minY < 1024 else { continue }
            if Press.amount(rr) > 0.01 { g.setFillColor(HPComponents.fill.withAlphaComponent(0.6 * Press.amount(rr)).cgColor); g.fill(rr) }
            face.drawSymbol(g, r.3, in: CGRect(x: rr.minX + 40, y: rr.midY - 26, width: 52, height: 52), color: HPComponents.purple)
            let x = rr.minX + 124, w = rr.maxX - 100 - x
            if let d = r.1, !d.isEmpty {
                face.drawLeft(g, middleTitle ? Face.clippedMiddle(r.0, tf, w) : Face.clipped(r.0, tf, w), font: tf, x: x, y: rr.midY - 6, color: HPComponents.label)
                let dw = r.2 == nil ? w : w - 150
                face.drawLeft(g, Face.clipped(d, df, dw), font: df, x: x, y: rr.midY + 36, color: HPComponents.secondary)
                if let p = r.2 {   // 聽到哪：一條小進度（紫色）
                    let bar = CGRect(x: rr.maxX - 100 - 130, y: rr.midY + 24, width: 130, height: 8)
                    g.setFillColor(HPComponents.fill.cgColor); g.addPath(MediaUI.capsule(bar)); g.fillPath()
                    g.setFillColor(HPComponents.purple.cgColor)
                    g.addPath(MediaUI.capsule(CGRect(x: bar.minX, y: bar.minY, width: max(8, bar.width * CGFloat(p)), height: bar.height))); g.fillPath()
                }
            } else {
                face.drawLeft(g, Face.clipped(r.0, tf, w), font: tf, x: x, y: rr.midY + tf.capHeight / 2, color: HPComponents.label)
            }
            if let t = r.4 { face.drawSymbol(g, t, in: CGRect(x: rr.maxX - 70, y: rr.midY - 17, width: 28, height: 34), color: HPComponents.tertiary) }
            if k < list.count - 1 { HPComponents.separatorLine(g, x: x, maxX: rr.maxX, y: rr.maxY) }
            HPAX.note(g, rr, .button, r.1.map { "\(r.0), \($0)" } ?? r.0)
        }
        if visible { g.restoreGState() }
        return card.maxY
    }

    /// 播一集：正在播的就是這一集＝回「正在播放」；否則在「播客」裡打開那一集
    private func play(_ e: PodcastEpisode) {
        if let f = face, NowPlayingPage.shared.isPodcast(face: f), NowPlayingPage.shared.state(face: f)?.info.title == e.title {
            browsing = false; f.forceDirty = true; return
        }
        if PodcastLibrary.shared.demo { return }
        Self.openPodcasts(e.url)
    }
    static func openPodcasts(_ url: URL?) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        if let url { NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) }
        else { NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) }
    }

    // MARK: 點、滾

    func handleTap(_ p: CGPoint, face: Face, now: Double) -> Bool {
        self.face = face
        if nowPlayingShown(face) {
            if NowPlayingPage.shared.handleTap(p, face: face, now: now) { return true }
            if HPComponents.hitBack(p) {   // 左上播客圓鈕＝資料庫（訪客裝置不行）
                if MediaAccess.guestTap { return true }
                NowPlayingPage.shared.closePanel(); browsing = true; page = .library; scroll = AppScroll()
                PodcastLibrary.shared.refresh(); face.forceDirty = true; return true
            }
            return false
        }
        guard p.y > 190 || !PodcastLibrary.allowed else { return false }
        if let h = hits.first(where: { $0.0.insetBy(dx: -4, dy: -4).contains(p) }) { h.1(); face.forceDirty = true; return true }
        return false
    }

    func handleScroll(_ dy: CGFloat, now: Double) -> Bool {
        if let f = face, nowPlayingShown(f) { return NowPlayingPage.shared.handleScroll(dy) }
        return scroll.scroll(dy * 1.6, contentHeight: content, viewport: 1024 - Self.top - 40)
    }

    // MARK: Demo（--demo-podcasts [show]）

    func applyDemo(_ name: String?, face: Face) {
        self.face = face
        PodcastLibrary.shared.applyDemo()
        browsing = true
        if name == "show", let s = PodcastLibrary.shared.shows.first { page = .show(s) }
        if name == "intro" { PodcastLibrary.shared.demo = false; PodcastLibrary.allowedOverride = false }
        face.forceDirty = true
    }
}
