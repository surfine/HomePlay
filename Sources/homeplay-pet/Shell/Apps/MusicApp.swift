// 音樂 App：第一頁「正在播放」（NowPlayingPage.swift，iPhone 或 Mac 的來源）；「資料庫」只管 Mac 的「音樂」App（AppleScript，背景佇列跑）：
// v2-music：資料庫照 iOS 音樂的「資料庫」——搜尋列、播放列表／藝人／專輯／歌曲四列、「在『音樂』中打開」的主頁與廣播、最近加入的專輯格；
// 點進去是清單頁（‹ 回來），點一首就播（MusicLibrary.swift 算清單）。搜尋用實體鍵盤或聽寫（桌寵旁的原生小框）。
// 「音樂」沒開時只顯示一顆「打開音樂」，絕不替使用者偷偷啟動它。
// 「正在播放」的 Live Activity（頂端藥丸）也由這裡提供，點藥丸打開這個 App。

import AppKit
import SwiftUI

final class MusicApp: PetApp {
    let id = "music"
    var title: String { L("app.music", "音乐") }
    let icon = AppIcon(color: srgb(0xfa2d48), symbol: "music.note", system: "/System/Applications/Music.app")
    static let bundle = "com.apple.Music"
    static let accent = srgb(0xfa2d48)

    /// v2-music：被打斷就先停、結束後接著播（MusicControl.swift）——App 清單建好時就開始看
    init() { MediaInterruption.shared.start() }

    enum ListKind: Equatable { case playlists, artists, albums, songs, artist(String), search(String) }
    enum Page: Equatable { case nowPlaying, library, list(ListKind) }
    private(set) var page: Page = .nowPlaying
    private weak var face: Face?

    struct Item: Equatable {
        enum Kind { case album, playlist, song, artist }
        var kind: Kind
        var name: String
        var detail: String = ""
        var pid: String = ""
        var art: CGImage?
        static func == (a: Item, b: Item) -> Bool { a.kind == b.kind && a.name == b.name && a.pid == b.pid && (a.art == nil) == (b.art == nil) }
    }
    enum Library: Equatable { case idle, loading, notRunning, denied, failed, ready([Item]) }
    private(set) var library: Library = .idle
    private var scroll: CGFloat = 0
    private var maxScroll: CGFloat = 0
    private var loadedAt = -1e9
    private var generation = 0
    private let queue = DispatchQueue(label: "homeplay.music.library", qos: .utility)

    // MARK: 版面
    // 2.0 逼真化（實機 HomeView 的音樂）：黑底、左上「♪ 音樂」膠囊、右上時間；分區標題「开始聆听 ›」SF Pro semibold，
    // 兩欄大方形封面，名稱與灰色副標在封面底下；內容捲到頂端列底下時柔和淡出；底下浮著一條玻璃迷你播放器。
    // 2.0 r2：資料庫跟著淺／深色（影片 v1 02:19 的 Music 搜尋頁是淺色）；大標題「音乐」放回左上
    private static var bg: NSColor { HPComponents.bg }
    private static let side: CGFloat = 436, gap: CGFloat = 24, x0: CGFloat = 64
    /// 一格＝封面＋底下兩行字
    private static let cellH: CGFloat = 436 + 108, rowGap: CGFloat = 28
    private static let headerH: CGFloat = 84
    private static let top: CGFloat = 206
    private static let miniPlayer = CGRect(x: 64, y: 1024 - 56 - 112, width: 896, height: 112)
    private static var cardRadius: CGFloat { 36 }

    func didOpen(now: Double) {
        page = .nowPlaying; scroll = 0; transition = nil
        NowPlayingPage.shared.closePanel()
    }
    /// 子頁顯示 ‹（清單頁回資料庫）
    var backSymbol: String { if case .list = page { return "chevron.left" }; return "xmark" }
    /// Esc／↓／‹：清單頁 → 資料庫 → 正在播放；正在播放上開著的那一層先收
    func handleBack(now: Double) -> Bool {
        guard let f = face else { return false }
        switch page {
        case .nowPlaying: return NowPlayingPage.shared.handleBack()
        case .library: go(.nowPlaying, face: f); return true
        case .list: go(.library, face: f); listScroll = AppScroll(); return true
        }
    }

    /// 換頁：Now Playing ↔ 資料庫是模糊交叉淡化（影片 v1 02:19.88 → 02:20.18 量到約 0.29 s，無回彈）
    private var transition: PageTransition?
    /// 2.0 idle：換頁的模糊交叉淡化還在畫上一頁（資料庫）——這幾幀不給訪客裝置（Remote/RemoteInput.swift）
    var transitioning: Bool { transition != nil }
    private func go(_ p: Page, face: Face) {
        guard p != page else { return }
        transition = PageTransition(.blurFade, face: face, now: CACurrentMediaTime(), spring: HPMotion.T.blurFade.spring, name: "music.page")
        page = p
    }

    /// 2.0 r2（R1）：正在播放是全螢幕媒體——不畫外殼的返回鈕與時間（左上換成音樂的玻璃圓鈕，點了到資料庫）
    private var mediaFullScreen: Bool { page == .nowPlaying && face.map { NowPlayingPage.shared.state(face: $0) != nil } ?? (NowPlayingPage.shared.demo != nil) }
    var showsCloseButton: Bool { !mediaFullScreen }
    func showsNowPlaying(face: Face) -> Bool { page == .nowPlaying && NowPlayingPage.shared.state(face: face) != nil }
    var showsClock: Bool { !mediaFullScreen }

    func tick(_ now: Double) -> Bool {
        if HPComponents.needsFrame(now) { return true }
        guard let f = face else { return false }
        return page == .nowPlaying && NowPlayingPage.shared.tick(now, face: f)
    }

    func liveActivity(face: Face, now: Double) -> LiveActivity? {
        // 第四輪：音樂（或播客）自己開著的時候頂端不重複一份（iOS：前景 App 的 Live Activity 不顯示；官方歌詞畫面也沒有）
        if Shell.currentApp === self || Shell.currentApp is PodcastsApp { return nil }
        return NowPlayingPage.shared.liveActivity(face: face, now: now, appID: id)
    }

    // MARK: 畫

    func render(into g: CGContext, face: Face, rect: CGRect, now: Double) {
        self.face = face
        switch page {
        case .nowPlaying:
            if !NowPlayingPage.shared.render(g, face: face, now: now, withLibraryStrip: true) {
                Self.openButton(g, face, L("music.open", "打开音乐"))
                NowPlayingPage.drawLibraryStrip(g, face: face)
            }
        case .library:
            renderLibrary(g, face)
        case .list(let k):
            renderList(g, face, k)
        }
        if let t = transition { if t.progress(now) == nil { transition = nil } else { t.drawOver(g, face, now) } }
    }

    private func rowsHeight(_ n: Int) -> CGFloat { n == 0 ? 0 : CGFloat((n + 1) / 2) * (Self.cellH + Self.rowGap) }

    // v2-music：資料庫頁與清單頁的列（iOS 音樂「資料庫」那種：紅色符號、字 40、右邊 chevron）
    private var hits: [(CGRect, () -> Void)] = []
    private var listScroll = AppScroll()
    private var listContent: CGFloat = 0
    private var searchPopover: NSPopover?
    private var listCache: (kind: ListKind, count: Int, first: String?, items: [Item])?
    private static let rowH: CGFloat = 116
    private static let searchH: CGFloat = 96

    private func renderLibrary(_ g: CGContext, _ face: Face) {
        g.setFillColor(Self.bg.cgColor); g.fill(MediaUI.full)
        hits = []; centerButtonShown = false
        // v2-music：資料庫是主人的（訪客模式、認不出、家人、訪客裝置都看不到）；正在播放照常
        if !MediaAccess.personal, MusicCatalogStore.shared.demo == nil || MediaAccess.simulate != nil {
            AppUI.drawLock(g, face, title: L("music.library", "资料库")); AppUI.title(g, face, L("music.library", "资料库")); return
        }
        switch library {
        case .idle, .loading:
            drawCenter(g, face, symbol: "music.note.list", text: L("music.lib.loading", "读取中…"), button: nil)
        case .notRunning:
            drawCenter(g, face, symbol: "music.note", text: L("music.lib.notRunning", "音乐 App 还没打开"), button: L("music.open", "打开音乐"))
        case .denied:
            drawCenter(g, face, symbol: "lock.fill", text: L("music.lib.denied", "请在「系统设置 → 隐私与安全性 → 自动化」里允许桌宠控制「音乐」。"), button: nil)
        case .failed:
            drawCenter(g, face, symbol: "exclamationmark.triangle.fill", text: L("music.lib.failed", "读不到资料库，稍后再试。"), button: L("recipe.retry", "重试"))
        case .ready(let items):
            let albums = items.filter { $0.kind == .album }
            var y = Self.top - scroll
            // 搜尋列
            let sr = CGRect(x: Self.x0, y: y, width: 1024 - Self.x0 * 2, height: Self.searchH)
            searchBar(g, face, sr, text: nil)
            hits.append((sr, { [weak self] in self?.askSearch("") }))
            y += Self.searchH + 32
            // 四類
            let cats: [(String, String, ListKind)] = [
                ("music.note.list", L("music.lib.playlists", "播放列表"), .playlists), ("music.microphone", L("music.lib.artists", "艺人"), .artists),
                ("square.stack", L("music.lib.albums", "专辑"), .albums), ("music.note", L("music.lib.songs", "歌曲"), .songs)]
            y = rowsCard(g, face, top: y, rows: cats.map { c in (c.0, c.1, nil, "chevron.right", { [weak self] in self?.openList(c.2) }) })
            y += 40
            // 在「音樂」中打開（Apple Music 的推薦與廣播要 MusicKit 權杖，桌寵沒有）
            HPComponents.sectionHeader(g, face, "Apple Music", x: Self.x0, baseline: y + 40, size: 38)   // l10n-ignore：服務名稱
            y += 64
            let ext: [(String, String, String?, String?, () -> Void)] = [
                ("house", L("music.lib.home", "主页"), L("music.lib.inMusic", "在「音乐」中打开"), "arrow.up.forward", { MusicControl.openMusic(path: "/listen-now") }),
                ("dot.radiowaves.left.and.right", L("music.lib.radio", "广播"), L("music.lib.inMusic", "在「音乐」中打开"), "arrow.up.forward", { MusicControl.openMusic(path: "/radio") })]
            y = rowsCard(g, face, top: y, rows: ext)
            y += 40
            // 最近加入
            if !albums.isEmpty {
                if y + Self.headerH > 120, y < 1024 { HPComponents.sectionHeader(g, face, L("music.lib.recent", "最近加入"), x: Self.x0, baseline: y + 52, size: 42, chevron: false) }
                y += Self.headerH
                for (k, it) in albums.enumerated() {
                    let r = Self.cardRect(k, top: y)
                    if r.maxY + 108 > 120, r.minY < 1024 { drawCard(g, face, it, r) }
                    hits.append((CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height + 108), { [weak self] in self?.play(it) }))
                }
                y += rowsHeight(albums.count)
            }
            let content = y + scroll - Self.top
            maxScroll = max(0, content - (Self.miniPlayer.minY - 24 - Self.top))
            scroll = min(scroll, maxScroll)
            fades(g)
        }
        AppUI.title(g, face, L("music.library", "资料库"))   // 標題＝這一頁（資料庫），不是 App 名稱
        if case .ready = library { drawMiniPlayer(g, face) }
    }

    /// 頂端列底下柔和淡出；底下迷你播放器後面也淡一點
    private func fades(_ g: CGContext) {
        HPComponents.topFade(g, Self.bg, solidTo: 190, height: 50)
        if let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [Self.bg.withAlphaComponent(0).cgColor, Self.bg.cgColor] as CFArray, locations: [0, 1]) {
            g.drawLinearGradient(grad, start: CGPoint(x: 0, y: Self.miniPlayer.minY - 90), end: CGPoint(x: 0, y: Self.miniPlayer.minY + 24), options: [.drawsAfterEndLocation])
        }
    }

    /// 搜尋列（iOS 的灰色填色膠囊，不是玻璃：內容層）
    private func searchBar(_ g: CGContext, _ face: Face, _ r: CGRect, text: String?) {
        g.addPath(MediaUI.capsule(r)); g.setFillColor(HPComponents.fill.cgColor); g.fillPath()
        face.drawSymbol(g, "magnifyingglass", in: CGRect(x: r.minX + 34, y: r.midY - 20, width: 40, height: 40), color: HPComponents.secondary)
        let f = HPComponents.sf(36, weight: .regular)
        let t = text ?? L("music.search.prompt", "搜索资料库")
        face.drawLeft(g, Face.clipped(t, f, r.width - 140), font: f, x: r.minX + 92, y: r.midY + f.capHeight / 2, color: text == nil ? HPComponents.secondary : HPComponents.label)
        face.drawSymbol(g, "mic.fill", in: CGRect(x: r.maxX - 70, y: r.midY - 20, width: 32, height: 40), color: HPComponents.secondary)
        HPAX.note(g, r, .button, t)
    }

    /// 分組卡裡的一排列；回傳卡片下緣
    private func rowsCard(_ g: CGContext, _ face: Face, top: CGFloat, rows: [(String, String, String?, String?, () -> Void)], thumbs: [Item]? = nil) -> CGFloat {
        let card = CGRect(x: Self.x0, y: top, width: 1024 - Self.x0 * 2, height: CGFloat(rows.count) * Self.rowH)
        guard !rows.isEmpty else { return top }
        if card.maxY > 150, card.minY < 1024 {
            HPComponents.groupCard(g, card)
            g.saveGState(); g.addPath(continuousRoundedRect(card, radius: 52)); g.clip()
        }
        let tf = HPComponents.sf(40, weight: .regular), df = HPComponents.sf(30, weight: .regular)
        for (k, r) in rows.enumerated() {
            let rr = CGRect(x: card.minX, y: top + CGFloat(k) * Self.rowH, width: card.width, height: Self.rowH)
            hits.append((rr, r.4))
            guard rr.maxY > 150, rr.minY < 1024 else { continue }
            if Press.amount(rr) > 0.01 { g.setFillColor(HPComponents.fill.withAlphaComponent(0.6 * Press.amount(rr)).cgColor); g.fill(rr) }
            var x = rr.minX + 40
            if let thumbs, k < thumbs.count {
                let th = CGRect(x: x, y: rr.midY - 42, width: 84, height: 84)
                drawThumb(g, face, thumbs[k], th)
                x = th.maxX + 28
            } else {
                face.drawSymbol(g, r.0, in: CGRect(x: x, y: rr.midY - 26, width: 52, height: 52), color: Self.accent)
                x += 84
            }
            let w = rr.maxX - 90 - x
            if let d = r.2, !d.isEmpty {
                face.drawLeft(g, Face.clipped(r.1, tf, w), font: tf, x: x, y: rr.midY - 2, color: HPComponents.label)
                face.drawLeft(g, Face.clipped(d, df, w), font: df, x: x, y: rr.midY + 38, color: HPComponents.secondary)
            } else {
                face.drawLeft(g, Face.clipped(r.1, tf, w), font: tf, x: x, y: rr.midY + tf.capHeight / 2, color: HPComponents.label)
            }
            if let t = r.3 { face.drawSymbol(g, t, in: CGRect(x: rr.maxX - 70, y: rr.midY - 17, width: 28, height: 34), color: HPComponents.tertiary) }
            if k < rows.count - 1 { HPComponents.separatorLine(g, x: x, maxX: rr.maxX, y: rr.maxY) }
            HPAX.note(g, rr, .button, r.2.map { "\(r.1), \($0)" } ?? r.1)
        }
        if card.maxY > 150, card.minY < 1024 { g.restoreGState() }
        return card.maxY
    }

    /// 清單列左邊的小方塊（專輯、歌、播放列表；藝人是圓的）
    private func drawThumb(_ g: CGContext, _ face: Face, _ it: Item, _ r: CGRect) {
        let path = it.kind == .artist ? CGPath(ellipseIn: r, transform: nil) : continuousRoundedRect(r, radius: 14)
        g.saveGState(); g.addPath(path); g.clip()
        if let a = it.art { MediaUI.drawCover(g, face: face, a, in: r) }
        else {
            let (a, b) = MediaUI.gradient(for: it.kind == .song ? it.detail : it.name)
            MediaUI.fillGradient(g, r, a, b)
            let sym: String
            switch it.kind { case .album: sym = "square.stack"; case .playlist: sym = "music.note.list"; case .song: sym = "music.note"; case .artist: sym = "music.microphone" }
            face.drawSymbol(g, sym, in: r.insetBy(dx: 22, dy: 22), color: NSColor.white.withAlphaComponent(0.85))
        }
        g.restoreGState()
    }

    private func listTitle(_ k: ListKind) -> String {
        switch k {
        case .playlists: return L("music.lib.playlists", "播放列表")
        case .artists: return L("music.lib.artists", "艺人")
        case .albums: return L("music.lib.albums", "专辑")
        case .songs: return L("music.lib.songs", "歌曲")
        case .artist(let a): return a
        case .search: return L("music.search.title", "搜索")
        }
    }

    /// 清單頁：資料還沒來就轉圈；空的就說空
    private func renderList(_ g: CGContext, _ face: Face, _ k: ListKind) {
        g.setFillColor(Self.bg.cgColor); g.fill(MediaUI.full)
        hits = []; centerButtonShown = false
        if !MediaAccess.personal, MusicCatalogStore.shared.demo == nil || MediaAccess.simulate != nil {
            AppUI.drawLock(g, face, title: listTitle(k)); AppUI.title(g, face, listTitle(k)); return
        }
        var items: [Item] = []
        var ready = true
        let store = MusicCatalogStore.shared
        if k == .playlists {
            if case .ready(let all) = library { items = all.filter { $0.kind == .playlist } } else { ready = false }
        } else if store.state == .ready || store.demo != nil {
            // 排序 4000 首很貴：同一個清單、同一份資料庫只算一次（捲動時每幀不重算）
            let c = store.current
            if let hit = listCache, hit.kind == k, hit.count == c.tracks.count, hit.first == c.tracks.first?.pid { items = hit.items }
            else {
                switch k {
                case .artists: items = c.artists()
                case .albums: items = c.albums()
                case .songs: items = c.songs()
                case .artist(let a): items = c.songs(artist: a)
                case .search(let q): items = c.search(q)
                case .playlists: break
                }
                listCache = (k, c.tracks.count, c.tracks.first?.pid, items)
            }
        } else { ready = false }
        var y = Self.top - listScroll.offset
        if case .search(let q) = k {
            let sr = CGRect(x: Self.x0, y: y, width: 1024 - Self.x0 * 2, height: Self.searchH)
            searchBar(g, face, sr, text: q)
            hits.append((sr, { [weak self] in self?.askSearch(q) }))
            y += Self.searchH + 32
            y = rowsCard(g, face, top: y, rows: [("magnifyingglass", String(format: L("music.search.catalog", "在 Apple Music 中搜索“%@”"), q), L("music.lib.inMusic", "在「音乐」中打开"),
                                                  "arrow.up.forward", { MusicControl.openMusic(path: "/search", query: q) })])
            y += 40
            if ready, !items.isEmpty {
                HPComponents.sectionHeader(g, face, L("music.search.inLibrary", "资料库"), x: Self.x0, baseline: y + 40, size: 38); y += 64
            }
        }
        if !ready {
            if store.state == .notRunning { drawCenter(g, face, symbol: "music.note", text: L("music.lib.notRunning", "音乐 App 还没打开"), button: L("music.open", "打开音乐")) }
            else if store.state == .denied { drawCenter(g, face, symbol: "lock.fill", text: L("music.lib.denied", "请在「系统设置 → 隐私与安全性 → 自动化」里允许桌宠控制「音乐」。"), button: nil) }
            else { HPComponents.spinner(g, in: CGRect(x: 512 - 30, y: max(y, Self.top) + 40, width: 60, height: 60), ink: HPComponents.secondary) }
        } else if items.isEmpty {
            if case .search = k {} else { drawCenter(g, face, symbol: "music.note.list", text: L("music.lib.empty", "资料库里还没有内容"), button: nil) }
        } else {
            let rows: [(String, String, String?, String?, () -> Void)] = items.map { it in
                (it.kind == .artist ? "music.microphone" : "music.note", it.name, it.detail.isEmpty ? nil : it.detail, it.kind == .artist ? "chevron.right" : nil,
                 { [weak self] in if it.kind == .artist { self?.openList(.artist(it.name)) } else { self?.play(it) } })
            }
            y = rowsCard(g, face, top: y, rows: rows, thumbs: items)
        }
        listContent = y + listScroll.offset - Self.top + 24
        listScroll.clamp(contentHeight: listContent, viewport: Self.miniPlayer.minY - 24 - Self.top)
        fades(g)
        AppUI.title(g, face, listTitle(k))
        drawMiniPlayer(g, face)
    }

    private func openList(_ k: ListKind) {
        guard let f = face else { return }
        listScroll = AppScroll()
        if k != .playlists { MusicCatalogStore.shared.load { [weak self] in self?.face?.forceDirty = true } }
        go(.list(k), face: f)
    }

    /// 搜尋：桌寵旁的原生小框（實體鍵盤或聽寫），按 Return 就搜
    private func askSearch(_ current: String) {
        if SnapshotPrivacy.active { return }
        guard let v = (NSApp.delegate as? AppDelegate)?.view, searchPopover?.isShown != true else { return }
        let m = MediaSearchModel()
        m.text = current
        m.onSubmit = { [weak self] q in
            self?.searchPopover?.performClose(nil)
            let t = q.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { self?.openList(.search(t)) }
        }
        let p = NSPopover()
        p.behavior = .transient; p.animates = true
        p.contentViewController = NSHostingController(rootView: MediaSearchView(model: m, prompt: L("music.search.prompt", "搜索资料库")))
        NSApp.activate(ignoringOtherApps: true)
        p.show(relativeTo: v.bounds, of: v, preferredEdge: .maxX)
        searchPopover = p
    }

    /// 底下浮著的玻璃迷你播放器（iOS 26 的分頁列上方那條）：封面、歌名、演出者、播放鍵；點了回「正在播放」
    private func drawMiniPlayer(_ g: CGContext, _ face: Face) {
        let r = Self.miniPlayer
        let st = NowPlayingPage.shared.state(face: face)
        HPComponents.glassCapsule(g, r) { g in
            let art = CGRect(x: r.minX + 16, y: r.minY + 16, width: 80, height: 80)
            g.saveGState(); g.addPath(continuousRoundedRect(art, radius: 16)); g.clip()
            if let a = NowPlayingPage.shared.currentArt { MediaUI.drawCover(g, face: face, a, in: art) }
            else {
                MediaUI.fillGradient(g, art, HPComponents.grouped2, HPComponents.grouped)
                face.drawSymbol(g, "music.note", in: art.insetBy(dx: 22, dy: 20), color: HPComponents.secondary)
        }
        g.restoreGState()
        let tf = HPComponents.sf(34, weight: .semibold), sf = HPComponents.sf(28, weight: .regular)
        let tx = art.maxX + 24, tw = r.maxX - 120 - tx
        if let st {
            face.drawLeft(g, Face.clipped(st.info.title, tf, tw), font: tf, x: tx, y: r.midY - 4, color: HPComponents.label)
            face.drawLeft(g, Face.clipped(st.info.artist, sf, tw), font: sf, x: tx, y: r.midY + 34, color: HPComponents.secondary)
        } else {
            face.drawLeft(g, L("music.idle.title", "未在播放"), font: tf, x: tx, y: r.midY + 12, color: HPComponents.secondary)
        }
        let playing = st?.info.playing ?? false
        face.drawSymbol(g, playing ? "pause.fill" : "play.fill", in: CGRect(x: r.maxX - 84, y: r.midY - 22, width: 44, height: 44), color: HPComponents.label)
        }
    }

    private static func cardRect(_ k: Int, top: CGFloat) -> CGRect {
        CGRect(x: x0 + CGFloat(k % 2) * (side + gap), y: top + CGFloat(k / 2) * (cellH + rowGap), width: side, height: side)
    }

    /// 一張專輯卡：方形封面（細邊、淡陰影），底下名稱（白）與副標（灰）
    private func drawCard(_ g: CGContext, _ face: Face, _ it: Item, _ r: CGRect) {
        let path = continuousRoundedRect(r, radius: Self.cardRadius)
        g.saveGState(); g.addPath(path); g.clip()
        if let art = it.art { MediaUI.drawCover(g, face: face, art, in: r) }
        else {
            let (a, b) = MediaUI.gradient(for: it.name)
            MediaUI.fillGradient(g, r, a.blended(withFraction: 0.2, of: .black) ?? a, b.blended(withFraction: 0.35, of: .black) ?? b)
            face.drawSymbol(g, it.kind == .album ? "music.note" : "music.note.list", in: CGRect(x: r.midX - 60, y: r.midY - 66, width: 120, height: 132), color: NSColor.white.withAlphaComponent(0.55))
        }
        g.restoreGState()
        g.addPath(path); g.setStrokeColor((HPTokens.dark ? NSColor.white : NSColor.black).withAlphaComponent(0.1).cgColor); g.setLineWidth(2); g.strokePath()
        let nf = HPComponents.sf(36, weight: .medium), df = HPComponents.sf(32, weight: .regular)
        face.drawLeft(g, Face.clipped(it.name, nf, r.width - 8), font: nf, x: r.minX + 4, y: r.maxY + 46, color: HPComponents.label)
        let detail = it.detail.isEmpty ? L("music.lib.playlists", "播放列表") : it.detail
        face.drawLeft(g, Face.clipped(detail, df, r.width - 8), font: df, x: r.minX + 4, y: r.maxY + 88, color: HPComponents.secondary)
    }

    /// 這一幀有沒有畫「打開音樂／重試」那顆（沒畫就不攔那一塊的點按）
    private var centerButtonShown = false
    private func drawCenter(_ g: CGContext, _ face: Face, symbol: String, text: String, button: String?) {
        HPComponents.emptyState(g, face, symbol: symbol, tint: Self.accent, title: text, body: nil, top: 270)
        if let button { Self.openButton(g, face, button); centerButtonShown = true }
    }

    // MARK: 點、滾

    func handleTap(_ p: CGPoint, face: Face, now: Double) -> Bool {
        self.face = face
        switch page {
        case .nowPlaying:
            if NowPlayingPage.shared.state(face: face) == nil {
                if NowPlayingPage.open.insetBy(dx: -8, dy: -8).contains(p) { if !Self.launching { Self.launch() }; return true }
                if NowPlayingPage.idleLibrary.insetBy(dx: -8, dy: -8).contains(p) { showLibrary(); return true }
                return false
            } else if NowPlayingPage.shared.handleTap(p, face: face, now: now) { return true }
            if HPComponents.hitBack(p) { if !MediaAccess.guestTap { NowPlayingPage.shared.closePanel(); showLibrary() }; return true }   // 左上音樂圓鈕＝資料庫
            return false
        case .library, .list:
            if Self.miniPlayer.insetBy(dx: -6, dy: -6).contains(p), page != .library || { if case .ready = library { return true }; return false }() {
                go(.nowPlaying, face: face); return true
            }
            if centerButtonShown, NowPlayingPage.open.insetBy(dx: -8, dy: -8).contains(p) {
                if case .failed = library, page == .library { refresh(force: true); return true }
                let off: Bool = { if case .notRunning = library { return true }; return MusicCatalogStore.shared.state == .notRunning }()
                if off { if !Self.launching { Self.launch() }; return true }
            }
            guard p.y > 190 else { return false }
            if let h = hits.first(where: { $0.0.contains(p) }) { h.1(); return true }
            return false
        }
    }

    func handleScroll(_ dy: CGFloat, now: Double) -> Bool {
        switch page {
        case .nowPlaying: return NowPlayingPage.shared.handleScroll(dy)
        case .library:
            guard maxScroll > 0 else { return false }
            scroll = max(0, min(maxScroll, scroll - dy * 1.6)); return true
        case .list:
            return listScroll.scroll(dy * 1.6, contentHeight: listContent, viewport: Self.miniPlayer.minY - 24 - Self.top)
        }
    }

    private func showLibrary() {
        if let f = face { go(.library, face: f) } else { page = .library }
        scroll = 0
        refresh(force: false)
    }
    /// 打開 Mac 的「音樂」（使用者按了才開）
    static func launch() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        launchingSince = CACurrentMediaTime()
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// 2.0 P04：按下「打開音樂」到「音樂」真的跑起來之間（最多 8 秒）按鈕顯示轉圈與「打開中…」
    nonisolated(unsafe) private static var launchingSince: Double?
    static var launching: Bool {
        if ProcessInfo.processInfo.environment["HOMEPLAY_BUSY"] != nil { return true }   // 快照：HOMEPLAY_BUSY=1 畫出忙碌的按鈕
        guard let t = launchingSince else { return false }
        if CACurrentMediaTime() - t > 8 || NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundle }) {
            launchingSince = nil; return false
        }
        return true
    }
    static func openButton(_ g: CGContext, _ face: Face, _ title: String) {
        HPComponents.filledButton(g, face, NowPlayingPage.open, title, tint: accent, symbol: "arrow.up.forward.app",
                                  busy: launching, busyTitle: L("music.opening", "打开中…"))
    }

    // MARK: 資料庫（AppleScript）

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static let listScript = """
    if application id "com.apple.Music" is not running then return "NOTRUNNING"
    with timeout of 25 seconds
      tell application id "com.apple.Music"
        set out to ""
        try
          set pls to (get name of every user playlist whose special kind is none)
        on error
          set pls to {}
        end try
        set c to 0
        repeat with n in pls
          set c to c + 1
          if c > 40 then exit repeat
          set out to out & "P" & tab & (n as text) & linefeed
        end repeat
        try
          set cutoff to (current date) - (45 * days)
          set ts to (every track of library playlist 1 whose date added > cutoff)
          set seen to {}
          set k to 0
          repeat with t in ts
            set al to (album of t as text)
            if al is not "" and seen does not contain al then
              set end of seen to al
              set out to out & "A" & tab & al & tab & (artist of t as text) & tab & (persistent ID of t as text) & linefeed
              set k to k + 1
              if k >= 8 then exit repeat
            end if
          end repeat
        end try
        return out
      end tell
    end timeout
    """

    /// 腳本輸出 → 項目；"NOTRUNNING" 另外處理。純函式，selftest 驗
    static func parseLibrary(_ out: String) -> [Item] {
        var albums: [Item] = [], lists: [Item] = []
        for line in out.components(separatedBy: CharacterSet.newlines) where !line.isEmpty {
            let f = line.components(separatedBy: "\t")
            if f.first == "A", f.count >= 4, !f[1].isEmpty { albums.append(Item(kind: .album, name: f[1], detail: f[2], pid: f[3])) }
            else if f.first == "P", f.count >= 2, !f[1].isEmpty { lists.append(Item(kind: .playlist, name: f[1])) }
        }
        return albums + lists
    }

    func refresh(force: Bool) {
        let now = CACurrentMediaTime()
        if !force, now - loadedAt < 20, case .ready = library { return }
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.bundle }
        guard running else { library = .notRunning; return }
        generation += 1
        let gen = generation
        library = .loading
        queue.async { [weak self] in
            var err: NSDictionary?
            let r = NSAppleScript(source: Self.listScript)?.executeAndReturnError(&err)
            let code = (err?[NSAppleScript.errorNumber] as? Int) ?? 0
            let out = r?.stringValue
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.loadedAt = CACurrentMediaTime()
                if code == -1743 { self.library = .denied }
                else if out == "NOTRUNNING" { self.library = .notRunning }
                else if let out { self.library = .ready(Self.parseLibrary(out)); self.loadArtworks(gen) }
                else { self.library = .failed }
                self.face?.forceDirty = true
            }
        }
    }

    /// 專輯卡的封面：一張一張補上（背景佇列，補一張重畫一次）
    private func loadArtworks(_ gen: Int) {
        guard case .ready(let items) = library else { return }
        for it in items where it.kind == .album && !it.pid.isEmpty {
            let pid = it.pid
            queue.async { [weak self] in
                let src = """
                if application id "com.apple.Music" is not running then return missing value
                tell application id "com.apple.Music"
                  set t to (first track of library playlist 1 whose persistent ID is \(Self.quote(pid)))
                  if (count of artworks of t) is 0 then return missing value
                  return raw data of artwork 1 of t
                end tell
                """
                let d = NSAppleScript(source: src)?.executeAndReturnError(nil).data
                guard let d, d.count > 100, let img = MediaUI.cgImage(from: d, maxSide: 700) else { return }
                DispatchQueue.main.async {
                    guard let self, gen == self.generation, case .ready(var cur) = self.library, let k = cur.firstIndex(where: { $0.pid == pid }) else { return }
                    cur[k].art = img; self.library = .ready(cur); self.face?.forceDirty = true
                }
            }
        }
    }

    private func play(_ it: Item) {
        let src: String
        switch it.kind {
        case .playlist: src = "tell application id \"\(Self.bundle)\" to play user playlist \(Self.quote(it.name))"
        case .album, .song: src = "tell application id \"\(Self.bundle)\" to play (first track of library playlist 1 whose persistent ID is \(Self.quote(it.pid)))"
        case .artist: return
        }
        if MusicCatalogStore.shared.demo != nil || it.pid.hasPrefix("demo") { if let f = face { go(.nowPlaying, face: f) }; return }
        queue.async { NSAppleScript(source: src)?.executeAndReturnError(nil) }
        if let f = face { go(.nowPlaying, face: f) } else { page = .nowPlaying }
        log("music play \(it.kind)")
    }

    // MARK: Demo（--demo-music [library]）

    func applyDemo(page name: String?, face: Face) {
        self.face = face
        var info = NowPlayingInfo(title: "Golden Hour", artist: "Mika Lindqvist", duration: 214, position: 83, playing: true, stamp: CACurrentMediaTime())
        info.fixed = true
        if OfficialDemo.on {   // R15：官方 nowplaying-crop 的文字與進度（--demo-official）
            info = NowPlayingInfo(title: OfficialDemo.songTitle, artist: OfficialDemo.songArtist, duration: OfficialDemo.songDuration,
                                  position: OfficialDemo.songPosition, playing: true, stamp: CACurrentMediaTime())
            info.fixed = true
        }
        NowPlayingPage.shared.demo = NowPlayingPage.Demo(info: info, source: name?.contains("mac") == true ? .mac : .phone, art: NowPlayingPage.demoArt())
        NowPlayingPage.shared.setAmbient(name == "fullart")   // R15：--demo-music fullart 拍閒置的全版封面
        // 2.0 #8／#11：--demo-music lyrics｜lyrics-plain｜lyrics-none｜podcast（示範歌詞是我們自己寫的，不連網）
        // v2-music：queue｜route｜more（待播、播放到、「…」）；其餘頁也帶隨機／重複／AirPlay 的示範狀態
        NowPlayingPage.shared.applyDemo(name ?? "")
        if name?.hasPrefix("library") == true {
            page = .library
            var items = ["Blue Hour|Nova Sato", "Paper Boats|The Quiet Hours", "Long Way Home|Eli Ward", "Tidal|Marin & Co.", "Soft Machines|Kiri Okafor", "Late Bloom|Aoi Hayashi"].enumerated().map { (i, s) -> Item in
                let p = s.components(separatedBy: "|")
                return Item(kind: .album, name: p[0], detail: p[1], pid: "demo\(i)", art: i % 2 == 0 ? NowPlayingPage.demoArt() : nil)
            }
            items += ["Morning Coffee", "Rainy Day", "Focus", "Road Trip"].map { Item(kind: .playlist, name: $0) }
            library = .ready(items)
            loadedAt = CACurrentMediaTime() + 1e6
            if name == "library-off" { library = .notRunning }
            if name == "library-bottom" { scroll = 1e5 }
            // v2-music：library-artists｜library-albums｜library-songs｜library-artist｜library-search（示範資料庫，不問真的「音樂」）
            MusicCatalogStore.shared.demo = MusicCatalogStore.demoCatalog
            switch name {
            case "library-artists": page = .list(.artists)
            case "library-albums": page = .list(.albums)
            case "library-songs": page = .list(.songs)
            case "library-playlists": page = .list(.playlists)
            case "library-artist": page = .list(.artist("Nova Sato"))   // l10n-ignore
            case "library-search": page = .list(.search("gold"))         // l10n-ignore
            default: break
            }
        }
        face.forceDirty = true
    }
}

/// 音樂 App 的自檢
enum MusicSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        // v2-music：整批資料庫的解析與清單
        let gs = "\u{1D}", rs = "\u{1E}"
        let cat = MusicCatalog.parse(["Bé\(rs)Alpha\(rs)Gold Rush", "Ann\(rs)Bob\(rs)Ann", "X\(rs)Y\(rs)X", "2\(rs)1\(rs)1", "p1\(rs)p2\(rs)p3"].joined(separator: gs))
        check(cat.tracks.count == 3 && cat.albums().map(\.pid) == ["p3", "p2"] && cat.artists().map(\.name) == ["Ann", "Bob"], "音乐：整批资料库解析、专辑取曲序最小那首、艺人去重")
        check(cat.search("be").first?.pid == "p1" && cat.search("gold").first?.pid == "p3" && cat.search("ann").count == 2 && cat.search(" ").isEmpty, "音乐：搜索不分大小写与重音、歌名优先、空白不搜")
        let pg = MusicCatalog.parsePage("4500\(gs)" + ["x", "y", "z", "1", "q"].joined(separator: gs))
        check(pg?.total == 4500 && pg?.tracks.map(\.pid) == ["q"] && MusicCatalog.parsePage("3")?.tracks.isEmpty == true && MusicCatalog.parsePage("NOTRUNNING") == nil, "音乐：分页读取（总数＋这一页；超过总数只回总数）")
        check(MusicCatalog.parse("a\(gs)b").tracks.isEmpty && MusicCatalog.parse(["a\(rs)b", "c", "d", "e", "f"].joined(separator: gs)).tracks.isEmpty, "音乐：资料库段数或长度不对就当空")
        let e = MusicControl.parse("S\ttrue\tone\tfalse\tABC\tMix\t4\nQ\t5\tNext\tArt\tP5\nQ\tx\tBad\t\t\nR\tKitchen\tHomePod\ttrue\ttrue\nR\tMac\tcomputer\tfalse\ttrue\n")
        check(e?.shuffle == true && e?.repeatMode == .one && e?.upNext.map(\.index) == [5] && e?.routes.count == 2 && e?.routes.first?.selected == true && e?.queueReadable == false, "音乐：播放状态解析（随机、重复、待播、AirPlay）")
        check(MusicControl.parse("NOTRUNNING") == nil && MusicRepeat.off.next == .all && MusicRepeat.all.next == .one && MusicRepeat.one.next == .off, "音乐：重复循环 关→全部→单曲→关")
        check(ClioMusicTools.pick(cat, "gold rush")?.pid == "p3" && ClioMusicTools.pick(cat, "bob")?.pid == "p2" && ClioMusicTools.pick(cat, "zzz") == nil, "ClioTalk 播放：歌名完全相同＞艺人；找不到就说找不到")
        typealias MI = MediaInterruption
        let mi = MI.decide(reasons: [.call], wasActive: false, playing: true, pausedByUs: false) == .pause
              && MI.decide(reasons: [], wasActive: true, playing: false, pausedByUs: true) == .resume
              && MI.decide(reasons: [], wasActive: true, playing: false, pausedByUs: false) == nil
              && MI.decide(reasons: [.assistant], wasActive: false, playing: false, pausedByUs: false) == nil
              && MI.decide(reasons: [], wasActive: false, playing: false, pausedByUs: true) == .resume
        check(mi, "媒体：来电／ClioTalk 先停、结束后接着播；本来没在播就不碰")
        let st = SleepTimer()
        st.set(.minutes(5), now: 100)
        var np = NowPlayingInfo(title: "t", artist: "", duration: 600, position: 10, playing: true, stamp: 100); np.fixed = true
        check(st.remaining(100) == 300 && !st.tick(info: np, now: 200), "播客：睡眠定时倒数")
        st.set(.off)
        let items = MusicApp.parseLibrary("P\tRainy Day\nA\tBlue Hour\tNova\tAB12\nP\t\nbad line\nP\tFocus\n")
        check(items.map(\.name) == ["Blue Hour", "Rainy Day", "Focus"] && items.first?.kind == .album && items.first?.pid == "AB12" && items.first?.detail == "Nova", "音乐：资料库输出解析（专辑在前、空行与坏行略过）")
    }
}
