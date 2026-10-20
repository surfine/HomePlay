// 即时动态「正在播放」——照 LiveMusic.dc.html：岛长成胶囊，左边眼睛，中间歌名/演出者，底下一条细进度。
// 只读 Music / Spotify（已经在跑才问，绝不替用户启动它们），AppleScript 在后台队列里跑。

import AppKit

/// 一次读到的播放信息（全是播放器给的真值）
struct NowPlayingInfo: Equatable {
    var title: String
    var artist: String
    var duration: Double      // 秒；0＝未知
    var position: Double      // 读取那一刻的秒数
    var playing: Bool
    var stamp: Double         // 读取时的 CACurrentMediaTime
    var fixed = false         // 快照测试用：进度不往前走
    /// 比较时不看 stamp：暂停中每 3 秒轮询读到的内容一样，就不该重画
    static func == (a: Self, b: Self) -> Bool {
        a.title == b.title && a.artist == b.artist && a.duration == b.duration && a.position == b.position
            && a.playing == b.playing && a.fixed == b.fixed
    }
}

/// Face 存的状态（extension 不能存属性，所以单独一个 struct）
struct NowPlayingState {
    var info: NowPlayingInfo?
    var shown: NowPlayingInfo?     // 最近一次要画的内容；收起动画期间还要用
    var lastPlayingAt = -1e9
    var lastSecond = -1
}

enum NowPlayingLogic {
    static let pauseGrace = 30.0   // 暂停超过这么久就收起

    /// 要不要长成胶囊：在播，或者刚暂停不到 30 秒
    static func active(_ i: NowPlayingInfo?, lastPlayingAt: Double, now: Double) -> Bool {
        guard let i, !i.title.isEmpty else { return false }
        return i.playing || now - lastPlayingAt < pauseGrace
    }
    /// 0…1 进度；时长未知回 nil
    static func progress(_ i: NowPlayingInfo, now: Double) -> Double? {
        guard i.duration > 0 else { return nil }
        let p = i.position + (i.playing && !i.fixed ? max(0, now - i.stamp) : 0)
        return max(0, min(1, p / i.duration))
    }
    /// 解析脚本输出「状态\t歌名\t演出者\t时长\t位置」；停止/空/格式不对＝nil
    static func parse(_ out: String, durationScale: Double, now: Double) -> NowPlayingInfo? {
        let f = out.components(separatedBy: "\t")
        guard f.count >= 5 else { return nil }
        let state = f[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard state == "playing" || state == "paused" else { return nil }
        func num(_ s: String) -> Double { Double(s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")) ?? 0 }
        let title = f[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return NowPlayingInfo(title: title, artist: f[2].trimmingCharacters(in: .whitespacesAndNewlines),
                              duration: num(f[3]) * durationScale, position: num(f[4]), playing: state == "playing", stamp: now)
    }
}

extension Face {
    /// 轮询线程交来新数据（主线程）；nil＝没有可显示的
    func setNowPlaying(_ i: NowPlayingInfo?, now: Double = CACurrentMediaTime()) {
        if i == nowPlaying.info { return }
        nowPlaying.info = i
        if let i {
            if i.playing { nowPlaying.lastPlayingAt = now }
            nowPlaying.shown = i
        }
        forceDirty = true
    }
    func musicActive(_ now: Double) -> Bool {
        NowPlayingLogic.active(nowPlaying.info, lastPlayingAt: nowPlaying.lastPlayingAt, now: now)
    }
    /// 胶囊开着且在播时，每秒重画一次进度
    func tickMusic(_ now: Double) -> Bool {
        guard liveT > 0.02, timerEnd == nil, let i = nowPlaying.info, i.playing, !i.fixed else { return false }
        let s = Int(now)
        if s != nowPlaying.lastSecond { nowPlaying.lastSecond = s; return true }
        return false
    }

    /// 胶囊里的音乐内容（计时器没开时）：歌名粗体、演出者淡、底下细进度条；眼睛由 drawIsland 画
    func drawMusicCapsule(_ g: CGContext, rect: CGRect, c: CGPoint, lt: CGFloat, now: Double, red: Bool) {
        guard let i = nowPlaying.info ?? nowPlaying.shown else { return }
        let fg = red ? srgb(0xb3261e) : NSColor.white
        let x = rect.minX + 300, w = rect.maxX - 70 - x
        g.saveGState(); g.setAlpha(min(1, (lt - 0.3) / 0.7))
        let tf = Self.rounded(46, weight: .bold), af = Self.rounded(32, weight: .semibold)
        drawLeft(g, Self.fit(i.title, tf, w), font: tf, x: x, y: c.y - 14, color: fg)
        drawLeft(g, Self.fit(i.artist.isEmpty ? (i.playing ? L("nowplaying.playing", "正在播放") : L("nowplaying.paused", "已暂停")) : i.artist, af, w), font: af, x: x, y: c.y + 36,
                 color: fg.withAlphaComponent(0.6))
        if let p = NowPlayingLogic.progress(i, now: now) {
            let bar = CGRect(x: x, y: c.y + 66, width: w, height: 10)
            g.setFillColor(fg.withAlphaComponent(0.2).cgColor)
            g.addPath(CGPath(roundedRect: bar, cornerWidth: 5, cornerHeight: 5, transform: nil)); g.fillPath()
            var fill = bar; fill.size.width = max(10, w * CGFloat(p))
            g.setFillColor(fg.withAlphaComponent(i.playing ? 1 : 0.55).cgColor)
            g.addPath(CGPath(roundedRect: fill, cornerWidth: 5, cornerHeight: 5, transform: nil)); g.fillPath()
        }
        g.restoreGState()
    }

    /// 太长就截断加「…」
    static func fit(_ s: String, _ font: NSFont, _ width: CGFloat) -> String {
        func w(_ t: String) -> CGFloat { (t as NSString).size(withAttributes: [.font: font]).width }
        if w(s) <= width { return s }
        var t = s
        while !t.isEmpty, w(t + "…") > width { t.removeLast() }
        return t + "…"
    }
}

/// 每 3 秒问一次 Music / Spotify；只问已经在跑的。用户不让自动化（-1743）就不再问那一个。
enum MediaCommand { case play, pause, playPause, next, previous }

final class NowPlayingPoller {
    static let shared = NowPlayingPoller()
    /// 視窗被遮住／螢幕休眠時不必輪詢（AppleScript 不便宜）
    var paused = false
    static var disabled = false       // 快照用 --music 时关掉，免得真数据盖掉测试状态
    /// 偏好设定「显示正在播放」；默认开
    static let defaultsKey = "HomePlayNowPlayingOn"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    private struct Player { let bundle: String, name: String, scale: Double, source: String }
    private static let players = [
        Player(bundle: "com.apple.Music", name: "Music", scale: 1, source:
            """
            if application id "com.apple.Music" is not running then return "stopped"
            tell application id "com.apple.Music"
              if player state is stopped then return "stopped"
              set t to current track
              return (player state as text) & tab & (name of t) & tab & (artist of t) & tab & (duration of t as text) & tab & (player position as text)
            end tell
            """),
        Player(bundle: "com.spotify.client", name: "Spotify", scale: 0.001, source:
            """
            if application id "com.spotify.client" is not running then return "stopped"
            tell application id "com.spotify.client"
              if player state is stopped then return "stopped"
              set t to current track
              return (player state as text) & tab & (name of t) & tab & (artist of t) & tab & (duration of t as text) & tab & (player position as text)
            end tell
            """),
    ]
    private var denied = Set<String>()          // 主线程读写
    private var timer: Timer?
    private var busy = false
    private var results: [String: NowPlayingInfo] = [:]
    private let queue = DispatchQueue(label: "homeplay.nowplaying", qos: .utility)
    private weak var face: Face?

    func start(face: Face) {
        guard !Self.disabled, timer == nil else { return }
        self.face = face
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common); timer = t
        poll()
    }

    /// 关掉：不再问 Music / Spotify，屏幕上的「正在播放」也一并清掉
    func stop() {
        timer?.invalidate(); timer = nil; results = [:]
        face?.nowPlaying = NowPlayingState(); face?.forceDirty = true
    }

    private func poll() {
        guard !paused, !busy else { return }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let todo = Self.players.filter { running.contains($0.bundle) && !denied.contains($0.bundle) }
        results = results.filter { k, _ in todo.contains { $0.bundle == k } }
        guard !todo.isEmpty else { publish(); return }
        busy = true
        queue.async { [weak self] in
            var out: [(Player, NowPlayingInfo?, Bool)] = []
            for p in todo {
                var err: NSDictionary?
                let r = NSAppleScript(source: p.source)?.executeAndReturnError(&err)
                let code = (err?[NSAppleScript.errorNumber] as? Int) ?? 0
                out.append((p, r?.stringValue.flatMap { NowPlayingLogic.parse($0, durationScale: p.scale, now: CACurrentMediaTime()) }, code == -1743))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                for (p, info, wasDenied) in out {
                    if wasDenied { self.denied.insert(p.bundle) }
                    self.results[p.bundle] = info
                }
                self.publish()
            }
        }
    }

    /// 在播的优先，其次暂停的；记住选中的是哪家（控制就控它）
    private func publish() {
        guard timer != nil else { return }   // 已关掉：在途的结果丢弃
        if PhoneNowPlayingBridge.shared.active { return }   // 手機來源優先
        let playing = Self.players.first { results[$0.bundle]?.playing == true }
        let chosen = playing ?? Self.players.first { results[$0.bundle] != nil }
        if let c = chosen { activeBundle = c.bundle; face?.setNowPlaying(results[c.bundle]) }
        else { activeBundle = nil; face?.setNowPlaying(nil) }
    }

    /// 「正在播放」胶囊的控制：点一下＝播放／暂停，滚轮＝上一首／下一首。
    /// 只控当前显示的那家（Music 或 Spotify），同一个自动化授权，后台队列里发。
    private(set) var activeBundle: String?
    func control(_ c: MediaCommand) {
        // 手機正在播放時，媒體鍵先交給 CarPlay HID；沒有手機來源才控本機 Music/Spotify。
        if PhoneNowPlayingBridge.shared.send(c) { return }
        guard let b = activeBundle else { return }
        let verb: String
        switch c {
        case .play: verb = "play"
        case .pause: verb = "pause"
        case .playPause: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        }
        let src = "tell application id \"\(b)\" to \(verb)"
        queue.async { NSAppleScript(source: src)?.executeAndReturnError(nil) }
    }
}
