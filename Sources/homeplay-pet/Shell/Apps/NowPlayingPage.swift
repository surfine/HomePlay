// 「正在播放」整頁（音樂 App 與播客 App 共用）：封面滿版（糊掉當底、取代表色染色）、歌名／演出者、進度、
// 上一首／播放暫停／下一首三顆玻璃圓鈕（≥ 88）、右上角來源徽章（CarPlay 連著的 iPhone 正在播就標「iPhone」，否則是 Mac 的音樂／Spotify）。
// 資料來源都是現成的：iPhone＝CarPlay iAP2 0x5001 + HID 控制（PhoneNowPlayingBridge）；Mac＝NowPlaying.swift 的 AppleScript 輪詢。
// 封面：iPhone 走 iAP2 檔案傳輸，Mac 的音樂／Spotify 在曲目換了之後問一次（背景佇列）。歌詞不在這一版。

import AppKit

final class NowPlayingPage {
    static let shared = NowPlayingPage()
    enum Source { case phone, mac }

    /// --demo-music：固定的曲目、來源與程式畫的封面（不讀真的播放器）
    struct Demo {
        var info: NowPlayingInfo
        var source: Source
        var art: CGImage?
        var podcast = false          // 2.0 #11：--demo-music podcast（Mac 的播客，MediaRemote 控制）
        var lyrics: Lyrics? = nil    // 2.0 #8：--demo-music lyrics（我們自己寫的示範歌詞，不連網）
    }
    var demo: Demo?
    /// 2.0 #8：歌詞模式（按歌詞泡泡切換）
    /// v2-music：封面那一塊可以換成歌詞、待播、播放到、「…」、睡眠定時（NowPlayingPanels.swift）
    enum Panel: Equatable { case none, lyrics, queue, route, more, sleep }
    private(set) var panel: Panel = .none
    var lyricsMode: Bool { panel == .lyrics }
    var panelHits: [(CGRect, () -> Void)] = []
    var panelScroll = AppScroll()
    var panelContentHeight: CGFloat = 0
    /// 清單看得到的那一段：列只在這裡畫、只在這裡能點（被頂端切換鈕蓋住的不算）
    var panelBand: ClosedRange<CGFloat> = HPTokens.MediaPanel.top...HPTokens.MediaPanel.bottom
    /// 最近一次點按的位置（音量滑桿要知道點在哪）
    var lastTapPoint: CGPoint?
    private let lyricsView = LyricsView()
    /// 2.0 #11：倍速（MediaRemote 讀得到就用讀到的；送出後先在本地顯示）
    private var pendingRate: (rate: Double, at: Double)?

    weak var face: Face?
    private var key = ""                       // 目前這首的身分（換了就重算底色）
    private var art: CGImage?
    private(set) var blur: CGImage?
    private var accent = srgb(0x3a3a44)
    private var tone = (top: srgb(0x3a4a56), bottom: srgb(0x1c2329))
    private var revision = 0                   // 畫面底下的東西換了（曲目、封面到了）就加一：玻璃按鈕要重算
    private var phoneSerial = -1
    private var macArt: [String: CGImage] = [:]
    private var macArtOrder: [String] = []
    private var requested = Set<String>()
    private let queue = DispatchQueue(label: "homeplay.nowplaying.art", qos: .utility)

    // MARK: 資料

    /// 現在要顯示的曲目與來源；沒有就是 nil（畫「未在播放」）
    func state(face: Face) -> (info: NowPlayingInfo, source: Source)? {
        if let d = demo { return (d.info, d.source) }
        guard let i = face.nowPlaying.info, !i.title.isEmpty else { return nil }
        return (i, PhoneNowPlayingBridge.shared.active ? .phone : .mac)
    }

    /// 來源 App 是不是播客（只有 iPhone 的 iAP2 會告訴我們）
    func isPodcast(face: Face) -> Bool {
        if let d = demo { return d.podcast }
        // 2.0 #11：Mac 上的「播客」（MediaRemote 讀得到來源 App）
        if let s = state(face: face), s.source == .mac { return MediaRemoteReader.shared.latest?.bundle.lowercased() == PodcastsApp.bundle }
        guard let s = state(face: face), s.source == .phone else { return false }
        let n = (PhoneNowPlayingBridge.shared.appName ?? "").lowercased()
        return n.contains("podcast") || n.contains("播客") || n.contains("ポッドキャスト")   // l10n-ignore
    }

    private static let artworkScripts: [String: String] = [
        "com.apple.Music": """
            if application id "com.apple.Music" is not running then return missing value
            tell application id "com.apple.Music"
              if player state is stopped then return missing value
              if (count of artworks of current track) is 0 then return missing value
              return raw data of artwork 1 of current track
            end tell
            """,
        "com.spotify.client": """
            if application id "com.spotify.client" is not running then return missing value
            tell application id "com.spotify.client" to return artwork url of current track
            """,
    ]

    /// 曲目身分變了就換封面：iPhone 取 bridge 收到的圖；Mac 在背景問播放器
    private func sync(_ s: (info: NowPlayingInfo, source: Source)) {
        let newKey: String
        var newArt: CGImage?
        if let d = demo {
            newKey = "demo|\(d.info.title)"; newArt = d.art
        } else if s.source == .phone {
            let b = PhoneNowPlayingBridge.shared
            newKey = "phone|\(b.artworkSerial)|\(s.info.title)"
            newArt = b.artworkImage.flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        } else {
            let bundle = NowPlayingPoller.shared.activeBundle ?? "com.apple.Music"
            newKey = "mac|\(bundle)|\(s.info.title)|\(s.info.artist)"
            newArt = macArt[newKey]
            // 2.0 #11：MediaRemote 給的封面（播客等沒有 AppleScript 的 App 也有）
            let mr = MediaRemoteReader.shared
            if newArt == nil, let a = mr.art, mr.latest?.title == s.info.title { newArt = a }
            if newArt == nil, !requested.contains(newKey), Self.artworkScripts[bundle] != nil { requestMacArt(newKey, bundle: bundle) }
        }
        let artChanged = (newArt == nil) != (art == nil)
        guard newKey != key || artChanged else { return }
        if demo == nil, newKey != key, s.source == .mac { MusicControl.shared.noteTrack(title: s.info.title, artist: s.info.artist) }   // v2-music：播過的
        key = newKey; art = newArt; revision += 1
        if let a = newArt { blur = MediaUI.blurred(a); accent = MediaUI.accent(of: a); tone = MediaUI.twoTone(of: a) }
        else { blur = nil; accent = MediaUI.gradient(for: s.info.title + s.info.artist).1; let gr = MediaUI.gradient(for: s.info.title + s.info.artist); tone = (gr.0, gr.1) }
    }

    private func requestMacArt(_ key: String, bundle: String) {
        requested.insert(key)
        guard let src = Self.artworkScripts[bundle] else { return }
        queue.async { [weak self] in
            var err: NSDictionary?
            let r = NSAppleScript(source: src)?.executeAndReturnError(&err)
            let finish: (Data?) -> Void = { data in
                DispatchQueue.main.async {
                    guard let self, let data, let img = MediaUI.cgImage(from: data, maxSide: 800) else { return }
                    self.macArt[key] = img; self.macArtOrder.append(key)
                    if self.macArtOrder.count > 8 { self.macArt[self.macArtOrder.removeFirst()] = nil }
                    self.face?.forceDirty = true
                }
            }
            if bundle == "com.spotify.client" {
                guard let s = r?.stringValue, let url = URL(string: s) else { return }
                DispatchQueue.main.async { MediaUI.fetch(url, accept: "image/*") { res in if case .success(let ok) = res { finish(ok.data) } } }
            } else if let d = r?.data, d.count > 100 {
                finish(d)
            }
        }
    }

    // MARK: 版面（1024 畫布）
    // 2.0 r2（R7，照影片 v2 00:33.2 O88–O96 量到的比例換算到 1024）：
    // 封面 660 見方、水平置中偏上；歌名左對齊疊在封面下半（左距 88，超出封面左緣）；進度條與控制也壓在封面下半；
    // 控制是不帶圓底的符號（暫停最大）；左上一顆玻璃圓鈕（音樂符號，回資料庫）、右上一顆玻璃膠囊（來源）；沒有標題、沒有時間。
    // 2.0 r3（R15，nowplaying-crop.png 透視校正到 1024 後量的，數字在 HPTokens.NowPlaying）：
    // 歌名 semibold 60 基線 653、演出者 40 基線 708；進度條粗 10（x 90…934）；控制列中線 891：歌詞泡泡、倒退、暫停、快進、佇列；
    // 演出者那行右邊一顆「…」。播放中閒置 12 秒控制收起、封面鋪滿（官方 Questions／Maisie Peters 那張），點一下回來。
    static let artRect = CGRect(x: 182, y: 168, width: 660, height: 660)
    static let textX: CGFloat = HPTokens.Media.textX
    static let titleBase = HPTokens.NowPlaying.titleBaseline, artistBase = HPTokens.NowPlaying.artistBaseline
    static let bar = HPTokens.NowPlaying.bar
    static let controlsY = HPTokens.NowPlaying.controlsY
    static let prev = CGRect(x: HPTokens.NowPlaying.backX - 60, y: controlsY - 60, width: 120, height: 120)
    static let play = CGRect(x: HPTokens.NowPlaying.playX - 64, y: controlsY - 64, width: 128, height: 128)
    static let next = CGRect(x: HPTokens.NowPlaying.forwardX - 60, y: controlsY - 60, width: 120, height: 120)
    /// 右下：清單符號＝資料庫（只有音樂有；官方是「待播清單」，我們讀不到待播，就當資料庫入口）
    static let libraryStrip = CGRect(x: HPTokens.NowPlaying.queueX - 50, y: controlsY - 50, width: 100, height: 100)
    /// 左下：歌詞泡泡（我們拿不到歌詞：畫成停用的灰色，點了不做事）
    static let lyrics = CGRect(x: HPTokens.NowPlaying.lyricsX - 50, y: controlsY - 50, width: 100, height: 100)
    /// 「…」：打開來源（Mac 的音樂／Spotify；iPhone 走 CarPlay 看手機上的正在播放）
    static var more: CGRect { HPTokens.NowPlaying.more }
    /// 閒置時控制收起、封面鋪滿
    private var chrome = HPComponents.Chrome(visible: true, idle: HPTokens.NowPlaying.ambientAfter, name: "nowplaying.chrome")
    /// 快照用：直接拍全版封面（--demo-music fullart）
    func setAmbient(_ on: Bool) {
        let now = CACurrentMediaTime()
        chrome = HPComponents.Chrome(visible: !on, idle: HPTokens.NowPlaying.ambientAfter, now: now, name: "nowplaying.chrome")
    }
    /// 左上：App 的玻璃圓鈕（同外殼返回鈕的位置）
    static var appButton: CGRect { HPTokens.backButton }
    /// 右上：來源膠囊（186×88，右端半圓與螢幕圓角同心）
    static let sourceBadge: CGRect = {
        let c = Screen.cornerCapsuleCenter(.topRight, width: 186, height: 88); return CGRect(x: c.x - 93, y: c.y - 44, width: 186, height: 88)
    }()
    static let open = CGRect(x: 512 - HPTokens.Size.pairedButton.width / 2, y: 640, width: HPTokens.Size.pairedButton.width, height: HPTokens.Size.pairedButton.height)
    /// 資料庫頁底下的迷你播放器要的：目前這首的封面（還沒同步過就是 nil）
    var currentArt: CGImage? { demo?.art ?? art }
    /// v2-music：頂端藥丸、控制中心要的封面——沒打開過音樂 App 也先同步一次（跟正在播放同一張）
    func artwork(face: Face) -> CGImage? {
        if demo == nil, let s = state(face: face) { self.face = face; sync(s) }
        return currentArt
    }

    static func clock(_ s: Double) -> String {
        let t = Int(max(0, s)); return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t % 3600 / 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: 畫

    /// withLibraryStrip：音樂 App 底下有「資料庫」入口；播客沒有
    @discardableResult
    func render(_ g: CGContext, face: Face, now: Double, withLibraryStrip: Bool) -> Bool {
        self.face = face
        if LyricsStore.shared.onUpdate == nil { LyricsStore.shared.onUpdate = { [weak self] in self?.face?.forceDirty = true } }
        guard let s = state(face: face) else {
            drawIdle(g, face: face); return false
        }
        // v2-music：換一層時模糊交叉淡化（跟搜尋 → 正在播放同一種；只蓋封面那一塊，底下的控制不閃）
        defer {
            if let t = panelTransition {
                if t.progress(now) == nil { panelTransition = nil }
                else { g.saveGState(); if let c = panelTransitionClip { g.clip(to: c) }; t.drawOver(g, face, now); g.restoreGState() }
            }
        }
        sync(s)
        let i = s.info
        let podcast = isPodcast(face: face)
        // 2.0 #8：歌詞模式（控制收起時只剩歌詞，不鋪封面）
        if lyricsMode, !podcast { renderLyrics(g, face: face, s, now: now, withLibraryStrip: withLibraryStrip); return true }
        if panel != .none, panel != .lyrics { renderPanel(g, face: face, s, podcast: podcast, now: now, withLibraryStrip: withLibraryStrip); return true }
        // 閒置：控制收起、封面鋪滿；淡入淡出時兩張疊著（玻璃鈕在一半以下就不畫）
        let k = chrome.value(CACurrentMediaTime())
        if k < 0.01 { drawAmbient(g, face: face, i); return true }
        defer {
            if k < 0.99 {
                g.saveGState(); g.setAlpha(1 - k); g.beginTransparencyLayer(auxiliaryInfo: nil)
                drawAmbient(g, face: face, i)
                g.endTransparencyLayer(); g.restoreGState()
            }
        }
        if podcast {
            // 2.0 #11（官方 podcast-lyrics-art 左邊那台）：節目封面鋪滿整面，下半壓暗；字與控制疊在上面
            if let art { MediaUI.drawCover(g, face: face, art, in: MediaUI.full) }
            else { let (a, b) = MediaUI.gradient(for: i.artist + i.title); MediaUI.fillGradient(g, MediaUI.full, a, b) }
            if let grad = MediaUI.shade(0.7) {
                g.drawLinearGradient(grad, start: CGPoint(x: 0, y: 470), end: CGPoint(x: 0, y: 1024), options: [.drawsAfterEndLocation])
            }
        } else {
            drawMusicBackdrop(g, face: face, i)
        }
        drawTitles(g, face: face, i, podcast: podcast)
        drawTransport(g, face: face, s, now: now, podcast: podcast, withLibraryStrip: withLibraryStrip)
        guard k >= 0.5 else { return true }   // 正在淡成全版封面：玻璃鈕先退場
        drawTopBar(g, face: face, s, withLibraryStrip: withLibraryStrip)
        return true
    }

    /// 音樂：封面兩點取色的直向漸層底＋660 見方的封面
    private func drawMusicBackdrop(_ g: CGContext, face: Face, _ i: NowPlayingInfo) {
        let white = NSColor.white
        // 底：封面兩點取色的直向漸層，壓暗到亮度 0.34 → 0.13（影片 Fever Dream：#3A4A56 → #1C2329）
        let topC = MediaUI.darkened(tone.top, brightness: HPTokens.NowPlaying.backgroundTop), botC = MediaUI.darkened(tone.bottom, brightness: HPTokens.NowPlaying.backgroundBottom)
        if let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [topC.cgColor, botC.cgColor] as CFArray, locations: [0, 1]) {
            g.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 1024), options: [])
        }
        // 封面（圓角 28、柔和投影）
        let ar = Self.artRect, apath = continuousRoundedRect(ar, radius: 28)
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: -12), blur: 60, color: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.4).cgColor)
        g.addPath(apath); g.setFillColor(botC.cgColor); g.fillPath()
        g.restoreGState()
        g.saveGState(); g.addPath(apath); g.clip()
        if let art { MediaUI.drawCover(g, face: face, art, in: ar) }
        else {
            let (a, b) = MediaUI.gradient(for: i.title)
            MediaUI.fillGradient(g, ar, a, b)
            face.drawSymbol(g, "music.note", in: ar.insetBy(dx: 230, dy: 210), color: white.withAlphaComponent(0.85))
        }
        // 封面下半壓一層漸層，疊在上面的白字才讀得到
        if let grad = MediaUI.shade(0.62) {
            g.drawLinearGradient(grad, start: CGPoint(x: 0, y: ar.minY + ar.height * 0.42), end: CGPoint(x: 0, y: ar.maxY), options: [])
        }
        g.restoreGState()
    }

    /// 歌名／演出者（音樂）或 節目／單集（播客）
    private func drawTitles(_ g: CGContext, face: Face, _ i: NowPlayingInfo, podcast: Bool) {
        typealias N = HPTokens.NowPlaying
        typealias P = HPTokens.Podcast
        let white = NSColor.white
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: 2), blur: 16, color: NSColor(white: 0, alpha: 0.4).cgColor)
        let maxW: CGFloat = 1024 - Self.textX * 2
        let sideW = Self.more.minX - 24 - Self.textX
        if podcast {
            // 官方：小字（日期）在上、單集名在下；我們讀得到的是節目名，就放節目名
            if !i.artist.isEmpty {
                let sf = HPComponents.sf(P.showSize, weight: .regular)
                face.drawLeft(g, Face.clipped(i.artist, sf, sideW), font: sf, x: Self.textX, y: P.showBaseline, color: white.withAlphaComponent(N.artistAlpha))
            }
            let tf = HPComponents.fitted(i.title, size: P.titleSize, weight: .semibold, maxWidth: maxW, minScale: 0.75)
            face.drawLeft(g, Face.clipped(i.title, tf, maxW), font: tf, x: Self.textX, y: P.titleBaseline, color: white)
            HPAX.note(g, CGRect(x: Self.textX, y: P.showBaseline - 44, width: maxW, height: P.titleBaseline - P.showBaseline + 100), .text,
                      i.artist.isEmpty ? i.title : String(format: L("a11y.pair", "%1$@，%2$@"), i.title, i.artist), shape: .rounded(16))   // 2.0 depth：VoiceOver
        } else {
            // 歌名（semibold 60）、演出者（regular 40，60% 白）：左對齊、疊在封面左下
            let tf = HPComponents.fitted(i.title, size: N.titleSize, weight: .semibold, maxWidth: maxW, minScale: 0.6)
            face.drawLeft(g, Face.clipped(i.title, tf, maxW), font: tf, x: Self.textX, y: Self.titleBase, color: white)
            let artist = i.artist.isEmpty ? (i.playing ? L("nowplaying.playing", "正在播放") : L("nowplaying.paused", "已暂停")) : i.artist
            let af = HPComponents.sf(N.artistSize, weight: .regular)
            face.drawLeft(g, Face.clipped(artist, af, sideW), font: af, x: Self.textX, y: Self.artistBase, color: white.withAlphaComponent(N.artistAlpha))
            HPAX.note(g, CGRect(x: Self.textX, y: Self.titleBase - 66, width: maxW, height: Self.artistBase - Self.titleBase + 90), .text,
                      String(format: L("a11y.pair", "%1$@，%2$@"), i.title, artist), shape: .rounded(16))   // 2.0 depth：VoiceOver
        }
        g.restoreGState()
    }

    /// 這首能不能用 MediaRemote 跳秒／換倍速（Mac 來源、符號都在；iPhone 經 CarPlay 只有播放／上下首）
    private func mrAvailable(_ s: (info: NowPlayingInfo, source: Source)) -> (skip: Bool, rate: Bool) {
        if demo != nil { return (MediaRemote.shared.canSkip, MediaRemote.shared.canRate) }
        guard s.source == .mac, MediaRemoteReader.shared.latest != nil else { return (false, false) }
        return (MediaRemote.shared.canSkip, MediaRemote.shared.canRate)
    }
    /// 目前倍速：剛按過就先顯示按的那個（MediaRemote 要一秒才讀回來）
    private func currentRate(_ i: NowPlayingInfo) -> Double {
        if let p = pendingRate, CACurrentMediaTime() - p.at < 3 { return p.rate }
        if let d = demo, d.podcast { return 1 }
        return MediaRemoteReader.shared.latest?.speed ?? i.rate
    }

    /// 歌詞泡泡的狀態：有歌詞＝亮、讀取中＝半亮、沒有／關掉／播客＝灰
    private func lyricsAvailability(_ i: NowPlayingInfo, podcast: Bool) -> (state: LyricsStore.State, enabled: Bool) {
        if podcast { return (.notFound, false) }
        let st: LyricsStore.State
        if let d = demo { st = d.lyrics.map { .ready($0) } ?? (LyricsStore.enabled ? .notFound : .off) }
        else { st = LyricsStore.shared.state(title: i.title, artist: i.artist, duration: i.duration) }
        switch st { case .ready, .loading: return (st, true); default: return (st, false) }
    }

    /// 進度條、時間、控制列、「…」
    private func drawTransport(_ g: CGContext, face: Face, _ s: (info: NowPlayingInfo, source: Source), now: Double, podcast: Bool, withLibraryStrip: Bool) {
        typealias N = HPTokens.NowPlaying
        typealias P = HPTokens.Podcast
        let white = NSColor.white, i = s.info
        // 進度：10 px（已播放白、未播放 30% 白），時間在兩端底下（等寬數字，60% 白）
        if let p = NowPlayingLogic.progress(i, now: now) {
            let bar = Self.bar
            g.setFillColor(white.withAlphaComponent(N.restAlpha).cgColor); g.addPath(MediaUI.capsule(bar)); g.fillPath()
            g.setFillColor(white.cgColor)
            g.addPath(MediaUI.capsule(CGRect(x: bar.minX, y: bar.minY, width: max(bar.height, bar.width * CGFloat(p)), height: bar.height))); g.fillPath()
            let pos = p * i.duration
            let tf2 = FaceType.sf(N.timeSize, .medium)
            face.drawLeft(g, Self.clock(pos), font: tf2, x: bar.minX, y: N.timeBaseline, color: white.withAlphaComponent(0.6))
            let rest = "−" + Self.clock(i.duration - pos)   // l10n-ignore
            face.drawLeft(g, rest, font: tf2, x: bar.maxX - Typo.width(rest, tf2), y: N.timeBaseline, color: white.withAlphaComponent(0.6))
        }
        // 控制：裸符號（暫停最大），按下時用同一條 quick 彈簧變亮放大；寬度跟著符號自己的比例
        func bare(_ sym: String, _ r: CGRect, _ h: CGFloat, alpha: CGFloat = 1, aspect: CGFloat = 1.9) {
            let k = Press.scale(r), a = Press.amount(r)
            let w = h * aspect * k, hh = h * k
            g.saveGState()
            if a > 0.01 { g.setFillColor(white.withAlphaComponent(0.16 * a).cgColor); g.fillEllipse(in: HPComponents.scaled(r, 0.9 * k)) }
            face.drawSymbol(g, sym, in: CGRect(x: r.midX - w / 2, y: r.midY - hh / 2, width: w, height: hh), color: white.withAlphaComponent(alpha), weight: .semibold)
            g.restoreGState()
        }
        let ly = lyricsAvailability(i, podcast: podcast)
        // 開著的那一層：符號變成白色實心圓底、符號挖空（iOS 的選中狀態）
        func selected(_ sym: String, _ rr: CGRect) {
            let r = HPComponents.scaled(rr, 0.9 * Press.scale(rr))
            g.saveGState(); g.beginTransparencyLayer(auxiliaryInfo: nil)
            g.setFillColor(white.withAlphaComponent(0.92).cgColor); g.fillEllipse(in: r)
            g.setBlendMode(.destinationOut)
            face.drawSymbol(g, sym, in: r.insetBy(dx: r.width * 0.22, dy: r.height * 0.22), color: .black, weight: .semibold)
            g.endTransparencyLayer(); g.restoreGState()
        }
        if lyricsMode {
            selected("quote.bubble.fill", Self.lyrics)
        } else {
            bare("quote.bubble", Self.lyrics, N.lyricsH, alpha: ly.enabled ? (ly.state == .loading ? 0.45 : N.secondaryAlpha) : 0.3, aspect: 1.1)
        }
        if podcast {
            let mr = mrAvailable(s)
            bare("gobackward.15", Self.prev, P.skipH, alpha: mr.skip ? 1 : 0.3, aspect: 1)
            bare(i.playing ? "pause.fill" : "play.fill", Self.play, N.playH)
            bare("goforward.30", Self.next, P.skipH, alpha: mr.skip ? 1 : 0.3, aspect: 1)
            let rf = HPComponents.sf(P.rateSize, weight: .semibold), label = MediaRemote.rateLabel(currentRate(i))
            let r = Self.libraryStrip, pk = Press.scale(r)
            if Press.amount(r) > 0.01 { g.setFillColor(white.withAlphaComponent(0.16 * Press.amount(r)).cgColor); g.fillEllipse(in: HPComponents.scaled(r, 0.9 * pk)) }
            HPComponents.center(g, face, label, rf, cx: r.midX, y: r.midY + rf.capHeight / 2, white.withAlphaComponent(mr.rate ? N.secondaryAlpha : 0.3))
        } else {
            bare("backward.fill", Self.prev, N.skipH)
            bare(i.playing ? "pause.fill" : "play.fill", Self.play, N.playH)
            bare("forward.fill", Self.next, N.skipH)
            // v2-music：右下是待播（官方的佇列鈕）；資料庫改由左上的音樂圓鈕進
            if withLibraryStrip { if panel == .queue { selected("list.bullet", Self.libraryStrip) } else { bare("list.bullet", Self.libraryStrip, N.queueH, alpha: N.secondaryAlpha) } }
        }
        // 「…」：淺色實心圓、三點透出底色（iOS 正在播放的 ellipsis.circle.fill）
        let mk = Press.scale(Self.more)
        face.drawSymbol(g, "ellipsis.circle.fill", in: HPComponents.scaled(Self.more, mk * N.moreSymbolScale), color: white.withAlphaComponent(0.72), weight: .regular)
        // 2.0 depth：VoiceOver——進度條（唯讀的滑桿）、控制列、「…」
        if let p = NowPlayingLogic.progress(i, now: now) {
            HPAX.note(g, Self.bar.insetBy(dx: 0, dy: -30), .slider(p), L("a11y.progress", "播放进度"),
                      value: String(format: L("a11y.progress.value", "%1$@，共 %2$@"), Self.clock(p * i.duration), Self.clock(i.duration)), shape: .rounded(20))
        }
        if ly.enabled { HPAX.note(g, Self.lyrics, .toggle(lyricsMode), L("settings.lyrics", "歌词"), shape: .circle) }
        if podcast {
            HPAX.note(g, Self.prev, .button, L("a11y.back15", "后退 15 秒"), shape: .circle)
            HPAX.note(g, Self.play, .button, i.playing ? L("cc.np.pause", "暂停") : L("cc.np.play", "播放"), shape: .circle)
            HPAX.note(g, Self.next, .button, L("a11y.forward30", "前进 30 秒"), shape: .circle)
            HPAX.note(g, Self.libraryStrip, .button, L("a11y.rate", "播放速度"), value: MediaRemote.rateLabel(currentRate(i)), shape: .circle)
        } else {
            HPAX.note(g, Self.prev, .button, L("cc.np.previous", "上一首"), shape: .circle)
            HPAX.note(g, Self.play, .button, i.playing ? L("cc.np.pause", "暂停") : L("cc.np.play", "播放"), shape: .circle)
            HPAX.note(g, Self.next, .button, L("cc.np.next", "下一首"), shape: .circle)
            if withLibraryStrip { HPAX.note(g, Self.libraryStrip, .toggle(panel == .queue), L("a11y.queue", "待播"), shape: .circle) }
        }
        HPAX.note(g, Self.more, .button, L("a11y.more", "更多"), shape: .circle)
    }

    /// 頂列：左上 App 圓鈕、右上來源膠囊（清玻璃，照片／深色底上）
    private func drawTopBar(_ g: CGContext, face: Face, _ s: (info: NowPlayingInfo, source: Source), withLibraryStrip: Bool) {
        let phone = s.source == .phone
        HPComponents.glassCircle(g, face, Self.appButton, symbol: withLibraryStrip ? "music.note" : "antenna.radiowaves.left.and.right", ink: .white, scale: 0.36, tint: HPComponents.mediaTint)
        // v2-music：右上照官方（podcast-lyrics-art 左邊那台）是「AirPlay＋音量」兩個符號的清玻璃膠囊；iPhone 來源時 AirPlay 換成 iPhone
        let r = Self.sourceBadge
        let routeSym = phone ? "iphone" : (currentRoutes().first { $0.selected && $0.kind != "computer" && $0.kind != "output" }?.symbol ?? "airplay.audio")
        HPAX.note(g, r, .button, L("music.route.title", "播放到"))
        HPComponents.glassCapsule(g, r, tint: HPComponents.mediaTint) { c in
            let sz: CGFloat = 40
            face.drawSymbol(c, routeSym, in: CGRect(x: r.midX - 24 - sz, y: r.midY - sz / 2, width: sz, height: sz), color: .white, weight: .semibold)
            face.drawSymbol(c, "speaker.wave.2.fill", in: CGRect(x: r.midX + 20, y: r.midY - sz / 2, width: sz * 1.1, height: sz), color: .white, weight: .semibold)
        }
    }

    /// 歌詞模式：封面糊掉當底、歌詞滿版；點一下浮出控制（底部壓暗＋進度＋控制列），閒置再收
    private func renderLyrics(_ g: CGContext, face: Face, _ s: (info: NowPlayingInfo, source: Source), now: Double, withLibraryStrip: Bool) {
        let i = s.info
        if let b = blur { MediaUI.drawCover(g, face: face, b, in: MediaUI.full) }
        else { let (a, b) = MediaUI.gradient(for: i.title + i.artist); MediaUI.fillGradient(g, MediaUI.full, a, b) }
        g.setFillColor(NSColor(white: 0, alpha: HPTokens.Lyrics.dim).cgColor); g.fill(MediaUI.full)
        let pos = NowPlayingLogic.progress(i, now: now).map { $0 * i.duration } ?? i.position
        let ly = lyricsAvailability(i, podcast: false)
        let k = chrome.value(CACurrentMediaTime())
        switch ly.state {
        case .ready(let l) where !l.instrumental && !(l.synced.isEmpty && l.plain.isEmpty):
            lyricsView.draw(g, face: face, lyrics: l, position: pos, duration: i.duration, now: now,
                           bottom: HPTokens.Lyrics.bottom - k * (HPTokens.Lyrics.bottom - HPTokens.Lyrics.bottomWithControls))   // 控制浮出時歌詞讓出下半
        default:
            let msg: String
            switch ly.state {
            case .loading: msg = L("lyrics.loading", "正在载入歌词…")
            case .ready: msg = L("lyrics.instrumental", "纯音乐，没有歌词")
            case .off: msg = L("lyrics.off", "歌词已在设置里关闭")
            case .failed: msg = L("lyrics.failed", "暂时读不到歌词")
            case .notFound: msg = L("lyrics.none", "这首歌没有歌词")
            }
            let f = HPType.sf(HPTokens.Lyrics.size, .bold)
            face.drawLeft(g, Face.clipped(msg, f, HPTokens.Lyrics.width), font: f, x: HPTokens.Lyrics.x, y: HPTokens.Lyrics.anchor + HPTokens.Lyrics.lineHeight * 0.78,
                          color: NSColor.white.withAlphaComponent(0.6))
        }
        guard k > 0.01 else { return }
        g.saveGState(); g.setAlpha(k); g.beginTransparencyLayer(auxiliaryInfo: nil)
        if let grad = MediaUI.shade(0.85) {
            g.drawLinearGradient(grad, start: CGPoint(x: 0, y: 600), end: CGPoint(x: 0, y: 1024), options: [.drawsAfterEndLocation])
        }
        drawTitles(g, face: face, i, podcast: false)
        drawTransport(g, face: face, s, now: now, podcast: false, withLibraryStrip: withLibraryStrip)
        g.endTransparencyLayer(); g.restoreGState()
        if k >= 0.5 { drawTopBar(g, face: face, s, withLibraryStrip: withLibraryStrip) }
    }

    /// v2-music：待播、播放到、「…」、睡眠定時——封面那一塊換成清單，底下的歌名、進度、控制照舊（不自動收起）
    private func renderPanel(_ g: CGContext, face: Face, _ s: (info: NowPlayingInfo, source: Source), podcast: Bool, now: Double, withLibraryStrip: Bool) {
        let i = s.info
        Self.livingBackdrop(g, face: face, blur: blur, seed: i.title + i.artist, now: now)
        drawPanelContent(g, face: face, s, podcast: podcast, now: now)
        if let grad = MediaUI.shade(0.55) {
            g.drawLinearGradient(grad, start: CGPoint(x: 0, y: 600), end: CGPoint(x: 0, y: 1024), options: [.drawsAfterEndLocation])
        }
        drawTitles(g, face: face, i, podcast: podcast)
        drawTransport(g, face: face, s, now: now, podcast: podcast, withLibraryStrip: withLibraryStrip)
        drawTopBar(g, face: face, s, withLibraryStrip: withLibraryStrip)
    }

    /// 換一層（同一層再按一次＝關）
    private var panelTransition: PageTransition?
    /// 2.0 idle：面板（待播、AirPlay…）收起的過場還疊著舊畫面——這幾幀不給訪客裝置
    var panelTransitioning: Bool { panelTransition != nil }
    private var panelTransitionClip: CGRect?
    private func beginPanelTransition(to next: Panel) {
        guard let f = face, demo == nil || !SnapshotPrivacy.active else { return }
        let full = next == .lyrics || panel == .lyrics
        panelTransitionClip = full ? nil : CGRect(x: 0, y: HPTokens.MediaPanel.top - 20, width: 1024, height: HPTokens.MediaPanel.bottom - HPTokens.MediaPanel.top + 40)
        panelTransition = PageTransition(.blurFade, face: f, now: CACurrentMediaTime(), spring: HPMotion.T.blurFade.spring, name: "nowplaying.panel")
    }
    func setPanel(_ p: Panel) {
        let now = CACurrentMediaTime()
        let next: Panel = panel == p && p != .more ? .none : p
        if next != panel { beginPanelTransition(to: next) }
        panel = next
        panelScroll = AppScroll(); panelContentHeight = 0
        chrome.show(now)
        if panel == .queue || panel == .more || panel == .route { MusicControl.shared.refresh(force: true) }
        if panel == .route { ControlCenter.volume = SystemVolume.get() ?? ControlCenter.volume }
        face?.forceDirty = true
    }
    /// 訪客裝置可以看這一幀嗎：音樂／播客正顯示「正在播放」，而且沒開待播、「…」、睡眠定時
    func guestViewable(app: PetApp?, face: Face) -> Bool {
        guard [.none, .lyrics, .route].contains(panel) else { return false }
        if let m = app as? MusicApp { return m.showsNowPlaying(face: face) }
        if let p = app as? PodcastsApp { return p.showsNowPlaying(face: face) }
        return false
    }
    func closePanel() { if panel != .none { beginPanelTransition(to: .none); panel = .none; chrome.show(CACurrentMediaTime()); face?.forceDirty = true } }
    /// Esc／↓：先收掉開著的那一層（睡眠定時回「…」）
    func handleBack() -> Bool {
        switch panel {
        case .none: return false
        case .sleep: setPanel(.more)
        default: closePanel()
        }
        return true
    }
    /// 滾輪：清單捲動；播放到那一層調音量
    func handleScroll(_ dy: CGFloat) -> Bool {
        switch panel {
        case .queue, .sleep:
            let view = panel == .queue ? HPTokens.MediaPanel.bottom - HPTokens.MediaPanel.top - HPTokens.MediaPanel.toggleH - 24 : HPTokens.MediaPanel.bottom - HPTokens.MediaPanel.top
            if panelScroll.scroll(dy * 1.6, contentHeight: panelContentHeight, viewport: view) { face?.forceDirty = true }
            return true
        case .route where panelContentHeight > panelBand.upperBound - panelBand.lowerBound:
            if panelScroll.scroll(dy * 1.6, contentHeight: panelContentHeight, viewport: panelBand.upperBound - panelBand.lowerBound) { face?.forceDirty = true }
            return true
        case .route:
            let v = Float(max(0, min(1, CGFloat(ControlCenter.volume) + dy * 0.004)))
            ControlCenter.volume = v; if demo == nil { SystemVolume.set(v) }; face?.forceDirty = true
            return true
        default: return false
        }
    }
    func openCurrentSource() {
        guard let f = face, let s = state(face: f) else { return }
        if demo == nil { openSource(s.source) }
    }

    /// 跳到某秒（歌詞點一句、點進度條）：示範只改本地；真的送 MediaRemote／「音樂」，本地先跳過去
    private func seek(to t: Double, face: Face, now: Double) {
        if demo != nil { demo?.info.position = max(0, t); face.forceDirty = true; return }
        guard var i = face.nowPlaying.info, MusicControl.shared.seek(to: t) else { return }
        i.position = max(0, min(i.duration > 0 ? i.duration : t, t)); i.stamp = now
        face.setNowPlaying(i, now: now)
    }

    /// 給主畫面「正在播放」小工具（v2-springboard 畫）的資料：只讀，不畫
    struct Snapshot { var title: String; var artist: String; var playing: Bool; var progress: Double?; var art: CGImage?; var podcast: Bool; var fromPhone: Bool }
    func snapshot(face: Face, now: Double = CACurrentMediaTime()) -> Snapshot? {
        guard let s = state(face: face) else { return nil }
        return Snapshot(title: s.info.title, artist: s.info.artist, playing: s.info.playing, progress: NowPlayingLogic.progress(s.info, now: now),
                        art: currentArt, podcast: isPodcast(face: face), fromPhone: s.source == .phone)
    }

    /// 全版封面（閒置）：封面鋪滿、下緣加深，歌名 semibold 58／演出者 regular 37（75% 白）疊在左下；沒有控制
    private func drawAmbient(_ g: CGContext, face: Face, _ i: NowPlayingInfo) {
        typealias N = HPTokens.NowPlaying
        if let art { MediaUI.drawCover(g, face: face, art, in: MediaUI.full) }
        else { let (a, b) = MediaUI.gradient(for: i.title); MediaUI.fillGradient(g, MediaUI.full, a, b) }
        if let grad = MediaUI.shade(0.55) {
            g.drawLinearGradient(grad, start: CGPoint(x: 0, y: 640), end: CGPoint(x: 0, y: 1024), options: [.drawsAfterEndLocation])
        }
        let maxW: CGFloat = 1024 - Self.textX * 2
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: 2), blur: 16, color: NSColor(white: 0, alpha: 0.35).cgColor)
        let tf = HPComponents.fitted(i.title, size: N.ambientTitleSize, weight: .semibold, maxWidth: maxW, minScale: 0.6)
        face.drawLeft(g, Face.clipped(i.title, tf, maxW), font: tf, x: Self.textX, y: N.ambientTitleBaseline, color: .white)
        if !i.artist.isEmpty {
            let af = HPComponents.sf(N.ambientArtistSize, weight: .regular)
            face.drawLeft(g, Face.clipped(i.artist, af, maxW), font: af, x: Self.textX, y: N.ambientArtistBaseline, color: NSColor.white.withAlphaComponent(N.ambientArtistAlpha))
        }
        g.restoreGState()
    }

    /// 玻璃膠囊裡「符號＋字」置中
    static func capsuleLabel(_ g: CGContext, face: Face, _ r: CGRect, symbol: String, _ text: String, ink: NSColor = .white) {
        let f = HPComponents.sf(30, weight: .semibold)
        let t = Face.clipped(text, f, r.width - 90)
        let w = 32 + 12 + Typo.width(t, f), x = r.midX - w / 2
        face.drawSymbol(g, symbol, in: CGRect(x: x, y: r.midY - 16, width: 32, height: 32), color: ink, weight: .semibold)
        face.drawLeft(g, t, font: f, x: x + 44, y: r.midY + f.capHeight / 2, color: ink)
    }

    /// 沒在播放時底下的「資料庫」入口（玻璃膠囊）
    /// 2.0 P04：跟「打開音樂」同一個尺寸 token（HPTokens.Size.pairedButton），只靠樣式（染色 vs 玻璃）分主次；符號是 music.note.list（原本的 square.stack.fill 看不出是什麼）
    static let idleLibrary = CGRect(x: open.minX, y: open.maxY + 26, width: open.width, height: open.height)
    static func drawLibraryStrip(_ g: CGContext, face: Face, glass: Bool = true) {
        HPComponents.glassButton(g, face, idleLibrary, L("music.library", "资料库"), symbol: "music.note.list")
    }

    private func drawIdle(_ g: CGContext, face: Face) {
        g.setFillColor(HPComponents.bg.cgColor); g.fill(MediaUI.full)
        HPComponents.emptyState(g, face, symbol: "music.note", tint: srgb(0xfa2d48), title: L("music.idle.title", "未在播放"),
                          body: NowPlayingPoller.enabled ? L("music.idle.hint", "在 iPhone 或 Mac 上播放音乐，这里就会显示。")
                                : L("music.idle.hintOff", "在 iPhone 上播放音乐，这里就会显示。Mac 上的音乐要先打开「设置 › 通用 › Mac 正在播放」。"), top: 250)   // 2.0 depth：預設關著，別說 Mac 也會出現
    }

    // MARK: 點

    /// 控制鈕；吃掉回 true。播放／暫停先在本地翻一下（輪詢要 3 秒才回來）
    func handleTap(_ p: CGPoint, face: Face, now: Double) -> Bool {
        guard let st = state(face: face) else { return false }
        lastTapPoint = p
        let guest = MediaAccess.guestTap   // 訪客裝置：播放控制與音量可以；待播、「…」、換輸出不行
        // v2-music：歌詞模式裡點一句＝跳到那一句（iOS／HomeView 一樣，控制收著也直接跳）
        if lyricsMode, p.y < HPTokens.Lyrics.bottom - chrome.value(CACurrentMediaTime()) * (HPTokens.Lyrics.bottom - HPTokens.Lyrics.bottomWithControls),
           case .ready(let l) = lyricsAvailability(st.info, podcast: false).state, let k = lyricsView.line(at: p), k < l.synced.count {
            if st.source == .mac || demo != nil { seek(to: l.synced[k].time, face: face, now: now) }   // iPhone 來源經 CarPlay 不能跳秒
            chrome.show(CACurrentMediaTime()); return true
        }
        if chrome.touch(CACurrentMediaTime()) { face.forceDirty = true; return true }   // 全版封面：這一下只叫回控制
        func hit(_ r: CGRect) -> Bool { r.insetBy(dx: -4, dy: -4).contains(p) }
        let podcast = isPodcast(face: face)
        // 開著的那一層裡的列與按鈕
        if panel != .none, panel != .lyrics, p.y < HPTokens.MediaPanel.bottom + 4, p.y > HPTokens.MediaPanel.top - 4 {
            if guest, panel != .route { return true }
            if guest, !volumeHit(p) { return true }
            if let h = panelHits.first(where: { $0.0.contains(p) }) { h.1(); face.forceDirty = true }
            return true
        }
        // 2.0 #8：歌詞泡泡切換歌詞模式（沒有歌詞時停用；開著時永遠可以關）
        if hit(Self.lyrics) {
            if lyricsMode || (!podcast && lyricsAvailability(st.info, podcast: false).enabled) { setPanel(.lyrics) }
            return true
        }
        if Self.sourceBadge.insetBy(dx: -6, dy: -6).contains(p) { setPanel(.route); return true }
        if Self.more.insetBy(dx: -22, dy: -22).contains(p) { if guest { return true }; setPanel(panel == .more || panel == .sleep ? .none : .more); return true }
        // 點進度條＝跳到那裡（手錶與 HomeView 拖的那條；這裡沒有拖，點的位置就是要去的地方）
        if st.info.duration > 0, Self.bar.insetBy(dx: -8, dy: -30).contains(p) {
            let f = Double(max(0, min(1, (p.x - Self.bar.minX) / Self.bar.width)))
            if demo != nil || (st.source == .mac && (MediaRemote.shared.canSeek || MusicControl.isSource)) { seek(to: f * st.info.duration, face: face, now: now) }
            return true
        }
        if !podcast, hit(Self.libraryStrip) { if !guest { setPanel(.queue) }; return true }
        // 2.0 #11：播客的後退 15、快轉 30、倍速（MediaRemote；拿不到就灰掉、點了不做事）
        if podcast {
            let mr = mrAvailable(st)
            if hit(Self.prev) || hit(Self.next) {
                let d: Double = hit(Self.prev) ? -15 : 30
                if demo != nil { if mr.skip { demo?.info.position = max(0, min(st.info.duration, st.info.position + d)) }; face.forceDirty = true; return true }
                if mr.skip, MediaRemote.shared.skip(d), var i = face.nowPlaying.info {
                    if let pr = NowPlayingLogic.progress(i, now: now) { i.position = max(0, min(i.duration, pr * i.duration + d)) }
                    i.stamp = now; face.setNowPlaying(i, now: now)
                }
                return true
            }
            if hit(Self.libraryStrip) {
                guard mr.rate else { return true }
                let r = MediaRemote.nextRate(after: currentRate(st.info))
                if demo != nil || MediaRemote.shared.setRate(r) { pendingRate = (r, CACurrentMediaTime()) }
                face.forceDirty = true
                return true
            }
        }
        let cmd: MediaCommand
        if hit(Self.prev) { cmd = .previous } else if hit(Self.next) { cmd = .next } else if hit(Self.play) { cmd = .playPause } else { return false }
        if demo != nil {
            if cmd == .playPause { demo?.info.playing.toggle() }
            face.forceDirty = true; return true
        }
        NowPlayingPoller.shared.control(cmd)
        if cmd == .playPause, var i = face.nowPlaying.info {
            if let pr = NowPlayingLogic.progress(i, now: now) { i.position = pr * i.duration }
            i.playing.toggle(); i.stamp = now
            face.setNowPlaying(i, now: now)
        }
        return true
    }

    /// 「…」：打開正在播的來源（Mac 的音樂／Spotify；iPhone 走原本進 CarPlay 的路，手機上的正在播放就在那裡）
    private func openSource(_ src: Source) {
        if src == .phone { (NSApp.delegate as? AppDelegate)?.enterCarPlay(); return }
        let bundle = NowPlayingPoller.shared.activeBundle ?? "com.apple.Music"
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func liveActivity(face: Face, now: Double, appID: String) -> LiveActivity? {
        if let d = demo {
            return LiveActivity(kind: .music, title: d.info.title, detail: d.info.artist, accent: srgb(0xfa2d48),
                                progress: NowPlayingLogic.progress(d.info, now: now), appID: appID)
        }
        guard face.musicActive(now), let i = face.nowPlaying.info ?? face.nowPlaying.shown else { return nil }
        return LiveActivity(kind: .music, title: i.title,
                            detail: i.artist.isEmpty ? (i.playing ? L("nowplaying.playing", "正在播放") : L("nowplaying.paused", "已暂停")) : i.artist,
                            accent: srgb(0xfa2d48), progress: NowPlayingLogic.progress(i, now: now), appID: appID)
    }

    /// 播放中每秒要重畫一次進度
    private var lastSecond = -1
    private var lastTenth = -1
    func tick(_ now: Double, face: Face) -> Bool {
        let wall = CACurrentMediaTime()
        // 暫停時控制不收（只有播放中閒置才鋪滿封面）
        if let s = state(face: face), !s.info.playing { chrome.show(wall) }
        if panel != .none, panel != .lyrics { chrome.show(wall) }   // 清單開著：控制不收
        if chrome.tick(wall) { return true }
        // v2-music：「音樂」的隨機／重複／喜愛／待播／AirPlay（3 秒問一次，只在它是來源時）
        if demo == nil, MusicControl.isSource { MusicControl.shared.refresh() }
        if MusicControl.shared.onChange == nil { MusicControl.shared.onChange = { [weak self] in self?.face?.forceDirty = true } }
        // 活的背景：播放中每 0.1 秒動一點（降低動態效果時不動）
        if panel != .none, !HPMotion.reduceMotion, let s = state(face: face), s.info.playing {
            let q = Int(now * 10)
            if q != lastTenth { lastTenth = q; return true }
        }
        // 2.0 #8：歌詞模式：捲動中每幀、播放中每 0.1 秒看一次要不要換句
        if lyricsMode {
            if lyricsView.animating(now) { return true }
            if let s = state(face: face), s.info.playing {
                let q = Int(now * 10)
                if q != lastTenth { lastTenth = q; return true }
            }
        }
        guard let s = state(face: face), s.info.playing, !s.info.fixed else { return false }
        let t = Int(now)
        if t != lastSecond { lastSecond = t; return true }
        return false
    }

    // MARK: Demo

    /// --demo-music lyrics｜lyrics-plain｜lyrics-none｜podcast｜queue｜route｜more｜podcast-more｜podcast-sleep
    func applyDemo(_ name: String) {
        guard var d = demo else { return }
        // v2-music：隨機／重複／喜愛／待播／AirPlay 的示範狀態（不問真的「音樂」）
        MusicControl.shared.demo = MusicControl.demoState
        MusicControl.shared.demoHistory = MusicControl.demoHistory
        let words = ["Morning light on the windowsill", "Coffee cooling while the world is still", "I hum the tune you left behind",
                     "A little melody stuck in my mind", "So turn it up, let the kitchen sing", "Every small thing is a golden thing",
                     "We don't need much, just the afternoon", "And a song that ends a little too soon"]   // l10n-ignore：示範歌詞（自己寫的）
        switch name {
        case "lyrics":
            d.lyrics = Lyrics(synced: words.enumerated().map { Lyrics.Line(time: 60 + Double($0.offset) * 6, text: $0.element) }, plain: [], instrumental: false)
            panel = .lyrics
        case "lyrics-plain":
            d.lyrics = Lyrics(synced: [], plain: words, instrumental: false); panel = .lyrics
        case "lyrics-none":
            d.lyrics = nil; panel = .lyrics
        case "queue": panel = .queue; d.source = .mac
        case "route": panel = .route; ControlCenter.volume = 0.62; d.source = .mac
        case "more": panel = .more; d.source = .mac
        case "podcast", "podcast-more", "podcast-sleep":
            if name == "podcast-more" { panel = .more; SleepTimer.shared.set(.minutes(15)); SleepTimer.shared.demoRemaining = 12 * 60 + 40 }
            if name == "podcast-sleep" { panel = .sleep; SleepTimer.shared.set(.minutes(15)) }
            d.podcast = true; d.source = .mac
            d.info = NowPlayingInfo(title: "Capsaicin, Explained", artist: "Field Notes", duration: 3664, position: 2443, playing: true, stamp: CACurrentMediaTime())   // l10n-ignore：示範節目（自己編的）
            d.info.fixed = true
            d.art = Self.demoPodcastArt()
        default: break
        }
        demo = d
        if name != "fullart" { chrome = HPComponents.Chrome(visible: !name.hasPrefix("lyrics"), idle: HPTokens.NowPlaying.ambientAfter, name: "nowplaying.chrome") }
        if CommandLine.arguments.contains("--np-chrome") { chrome.show(CACurrentMediaTime()) }
    }

    /// 程式畫的播客封面（不是任何真節目）：米灰底、幾個手繪感的線條圖案、節目名
    static func demoPodcastArt() -> CGImage {
        makeImage(800, 800) { c in
            c.scaleBy(x: 800.0 / 1024, y: 800.0 / 1024)
            MediaUI.fillGradient(c, MediaUI.full, srgb(0xd8d4bf), srgb(0xa9a58c))
            c.setStrokeColor(srgb(0x2b2a24).cgColor); c.setLineWidth(5); c.setLineCap(.round)
            for k in 0..<9 {
                let cx = 210 + CGFloat(k % 3) * 300, cy = 220 + CGFloat(k / 3) * 290
                if k == 4 { continue }
                c.strokeEllipse(in: CGRect(x: cx - 46, y: cy - 60, width: 92, height: 120))
                c.move(to: CGPoint(x: cx, y: cy - 60)); c.addLine(to: CGPoint(x: cx + 10, y: cy - 92)); c.strokePath()
            }
            let f = NSFont(name: "Georgia-Italic", size: 120) ?? NSFont.systemFont(ofSize: 120)
            let a = NSAttributedString(string: "field notes", attributes: [.font: f, .foregroundColor: srgb(0x1e1d19)])   // l10n-ignore
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
            a.draw(at: CGPoint(x: 512 - a.size().width / 2, y: 452))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// 程式畫的封面（不是任何真專輯）：深藍夜空、一輪橘色落日、幾條山稜
    static func demoArt() -> CGImage {
        makeImage(800, 800) { c in
            c.scaleBy(x: 800.0 / 1024, y: 800.0 / 1024)
            MediaUI.fillGradient(c, MediaUI.full, srgb(0x1b2a6b), srgb(0xf08a4b))
            c.setFillColor(srgb(0xffd27a).cgColor); c.fillEllipse(in: CGRect(x: 330, y: 380, width: 360, height: 360))
            for (k, col) in [srgb(0x3b2a68), srgb(0x241a4a), srgb(0x120d2b)].enumerated() {
                c.setFillColor(col.cgColor)
                let base = 640 + CGFloat(k) * 120
                c.move(to: CGPoint(x: 0, y: 1024)); c.addLine(to: CGPoint(x: 0, y: base))
                c.addCurve(to: CGPoint(x: 1024, y: base - 60), control1: CGPoint(x: 300, y: base - 150 + CGFloat(k) * 40), control2: CGPoint(x: 640, y: base + 80))
                c.addLine(to: CGPoint(x: 1024, y: 1024)); c.closePath(); c.fillPath()
            }
        }
    }
}
