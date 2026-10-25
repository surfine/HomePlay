// 2.0 v2-music：手錶與 HomeView 的「正在播放」能做的事，在 Mac 上用公開的路做到——
// - 「音樂」App（AppleScript，Music.sdef 實測有這些屬性）：隨機播放（shuffle enabled）、重複（song repeat off/one/all）、
//   喜好（track 的 favorited）、待播（current playlist 裡目前這首之後的曲目；Music 沒有 Up Next 的腳本介面，所以隨機播放開著時
//   順序讀不到，老實說「讀不到」）、AirPlay 輸出（AirPlay devices／current AirPlay devices）、跳到某秒（player position）。
// - 其他 App（Spotify、播客、瀏覽器）：MediaRemote 的 seek；輸出改用 Core Audio 的預設輸出裝置（公開 API，整台 Mac 的聲音都換過去）。
// - 「加入資料庫」：Music 的腳本沒有可靠的「加入 Apple Music 曲目」指令（duplicate 對串流曲目不保證），所以這一項是在「音樂」裡顯示這首（reveal），
//   讓使用者在那裡按「加入」，不假裝做到。
// 只在「音樂」已經在跑、而且它就是正在播放的來源時才問；腳本在背景佇列跑，曲名不寫進日誌。

import AppKit
import CoreAudio

/// 重複模式（照 Music 的 song repeat）
enum MusicRepeat: String { case off, all, one
    /// iOS 的循環：關 → 全部 → 單曲 → 關
    var next: MusicRepeat { self == .off ? .all : (self == .all ? .one : .off) }
    var symbol: String { self == .one ? "repeat.1" : "repeat" }
}

/// 待播或播過的一首
struct MusicQueueItem: Equatable {
    var title: String
    var artist: String
    var index: Int = 0          // 在 current playlist 裡的位置（0＝不知道；播過的清單用）
    var pid: String = ""
}

/// 一個輸出（AirPlay 喇叭或 Mac 的音訊裝置）
struct MediaRoute: Equatable {
    var name: String
    var kind: String            // computer／AirPlay device／HomePod／speaker…（Music 的 kind）；Core Audio 來源一律 "output"
    var selected: Bool
    var available: Bool = true
    var deviceID: UInt32 = 0    // Core Audio 的裝置（Music 來源是 0）
    var symbol: String {
        let k = kind.lowercased()
        if k.contains("computer") || k == "output" && name.lowercased().contains("macbook") { return "laptopcomputer" }
        if k.contains("homepod") { return "homepod.fill" }
        if k.contains("tv") { return "appletv.fill" }
        if k.contains("headphone") || name.lowercased().contains("airpods") { return "airpods" }
        return "hifispeaker.fill"
    }
}

/// 「音樂」此刻的播放狀態（隨機、重複、喜好、待播、AirPlay）
struct MusicPlayerExtras: Equatable {
    var shuffle = false
    var repeatMode: MusicRepeat = .off
    var favorited = false
    var trackPID = ""
    var trackName = ""          // 讀到 trackPID 那一刻的歌名（「播過的」要對得上才記 PID）
    var playlist = ""
    var currentIndex = 0
    var upNext: [MusicQueueItem] = []
    var routes: [MediaRoute] = []
    /// 待播的順序讀得到（隨機播放開著、或沒有播放列表時讀不到）
    var queueReadable: Bool { !shuffle && currentIndex > 0 }
}

final class MusicControl {
    static let shared = MusicControl()
    static let bundle = "com.apple.Music"

    private(set) var extras: MusicPlayerExtras?
    /// 快照與自檢用的固定狀態（--demo-music）
    var demo: MusicPlayerExtras?
    var current: MusicPlayerExtras? { demo ?? extras }
    /// 這次開機以來播過的（只在記憶體，最多 20 首，最新在前）
    private(set) var history: [MusicQueueItem] = []
    var demoHistory: [MusicQueueItem]?
    var recent: [MusicQueueItem] { demoHistory ?? history }
    private var lastKey = ""
    private var busy = false
    private var loadedAt = -1e9
    private let queue = DispatchQueue(label: "homeplay.music.control", qos: .utility)
    var onChange: (() -> Void)?

    /// 「音樂」是不是現在的來源（Mac 上、在跑）
    static var isSource: Bool {
        if MediaRemoteReader.shared.latest.map({ $0.bundle != bundle && !$0.bundle.isEmpty }) == true { return false }
        guard NowPlayingPoller.shared.activeBundle == bundle || MediaRemoteReader.shared.latest?.bundle == bundle else { return false }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundle }
    }

    // MARK: 播過的

    /// 曲目換了就把上一首記進「播過的」（主執行緒；NowPlayingPage 同步時叫）
    func noteTrack(title: String, artist: String) {
        let key = title + "\u{1}" + artist
        guard key != lastKey else { return }
        if !lastKey.isEmpty {
            let p = lastKey.components(separatedBy: "\u{1}")
            var item = MusicQueueItem(title: p[0], artist: p.count > 1 ? p[1] : "")
            if let e = extras, !e.trackPID.isEmpty, e.trackName == item.title { item.pid = e.trackPID }   // 對不上（換太快、別的 App）就不記，列變淡
            history.removeAll { $0.title == item.title && $0.artist == item.artist }
            history.insert(item, at: 0)
            if history.count > 20 { history.removeLast() }
        }
        lastKey = key
        refresh(force: true)
    }

    // MARK: 讀

    static let stateScript = """
    if application id "com.apple.Music" is not running then return "NOTRUNNING"
    with timeout of 10 seconds
      tell application id "com.apple.Music"
        set sh to shuffle enabled
        set rp to (song repeat as text)
        set fav to false
        set pid to ""
        set nm to ""
        set pl to ""
        set ix to 0
        try
          set t to current track
          set pid to (persistent ID of t)
          set nm to (name of t)
          try
            set fav to (favorited of t)
          end try
          try
            set ix to (index of t)
          end try
        end try
        try
          set pl to (name of current playlist)
        end try
        set out to "S" & tab & (sh as text) & tab & rp & tab & (fav as text) & tab & pid & tab & pl & tab & (ix as text) & tab & nm & linefeed
        if ix > 0 and not sh then
          try
            set n to (count of tracks of current playlist)
            set endK to ix + 25
            if endK > n then set endK to n
            if endK > ix then
              set ns to (name of tracks (ix + 1) thru endK of current playlist)
              set ars to (artist of tracks (ix + 1) thru endK of current playlist)
              set ps to (persistent ID of tracks (ix + 1) thru endK of current playlist)
              repeat with k from 1 to (count of ns)
                set out to out & "Q" & tab & ((ix + k) as text) & tab & (item k of ns) & tab & (item k of ars) & tab & (item k of ps) & linefeed
              end repeat
            end if
          end try
        end if
        try
          repeat with d in AirPlay devices
            set out to out & "R" & tab & (name of d) & tab & (kind of d as text) & tab & (selected of d as text) & tab & (available of d as text) & linefeed
          end repeat
        end try
        return out
      end tell
    end timeout
    """

    /// 腳本輸出 → 狀態（純函式，自檢用）；"NOTRUNNING"／沒有 S 行＝nil
    static func parse(_ out: String) -> MusicPlayerExtras? {
        var e = MusicPlayerExtras(), sawState = false
        for line in out.components(separatedBy: CharacterSet.newlines) where !line.isEmpty {
            let f = line.components(separatedBy: "\t")
            switch f.first {
            case "S" where f.count >= 7:
                sawState = true
                e.shuffle = f[1] == "true"
                e.repeatMode = MusicRepeat(rawValue: f[2].trimmingCharacters(in: .whitespaces)) ?? .off
                e.favorited = f[3] == "true"
                e.trackPID = f[4]; e.playlist = f[5]
                e.currentIndex = Int(f[6].trimmingCharacters(in: .whitespaces)) ?? 0
                if f.count >= 8 { e.trackName = f[7] }
            case "Q" where f.count >= 5:
                guard let k = Int(f[1]), !f[2].isEmpty else { continue }
                e.upNext.append(MusicQueueItem(title: f[2], artist: f[3], index: k, pid: f[4]))
            case "R" where f.count >= 5:
                guard !f[1].isEmpty else { continue }
                e.routes.append(MediaRoute(name: f[1], kind: f[2], selected: f[3] == "true", available: f[4] != "false"))
            default: continue
            }
        }
        return sawState ? e : nil
    }

    /// 背景問一次（同一時間只有一個；force＝不管上次多久前）
    func refresh(force: Bool = false) {
        guard demo == nil, !busy, !SnapshotPrivacy.active, Self.isSource else { return }
        let now = CACurrentMediaTime()
        if !force, now - loadedAt < 3 { return }
        busy = true
        queue.async { [weak self] in
            let r = NSAppleScript(source: Self.stateScript)?.executeAndReturnError(nil).stringValue
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false; self.loadedAt = CACurrentMediaTime()
                let e = r.flatMap(Self.parse)
                if e != self.extras { self.extras = e; self.onChange?() }
            }
        }
    }

    // MARK: 控制（先在本地改，畫面立刻跟上；下一次讀回來再對齊）

    private func run(_ src: String, then refreshAfter: Bool = true) {
        queue.async { [weak self] in
            _ = NSAppleScript(source: src)?.executeAndReturnError(nil)
            if refreshAfter { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.refresh(force: true) } }
        }
    }
    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    private func mutate(_ f: (inout MusicPlayerExtras) -> Void) {
        if demo != nil { f(&demo!); onChange?(); return }
        if extras != nil { f(&extras!); onChange?() }
    }

    func setShuffle(_ on: Bool) {
        mutate { $0.shuffle = on; if on { $0.upNext = [] } }
        if demo == nil { run("tell application id \"\(Self.bundle)\" to set shuffle enabled to \(on)") }
    }
    func cycleRepeat() {
        let next = (current?.repeatMode ?? .off).next
        mutate { $0.repeatMode = next }
        if demo == nil { run("tell application id \"\(Self.bundle)\" to set song repeat to \(next.rawValue)") }
    }
    func toggleFavorite() {
        let on = !(current?.favorited ?? false)
        mutate { $0.favorited = on }
        if demo == nil { run("tell application id \"\(Self.bundle)\" to set favorited of current track to \(on)") }
    }
    /// 待播清單的某一首（current playlist 的第 k 首）
    func playQueue(_ item: MusicQueueItem) {
        if demo != nil { return }
        if item.index > 0 { run("tell application id \"\(Self.bundle)\" to play track \(item.index) of current playlist") }
        else if !item.pid.isEmpty { playTrack(pid: item.pid) }
    }
    func playTrack(pid: String) {
        run("tell application id \"\(Self.bundle)\" to play (first track of library playlist 1 whose persistent ID is \(Self.quote(pid)))")
    }
    /// 只用這一個 AirPlay 輸出（手錶與 HomeView 的輸出選單一次選一個）
    func selectRoute(_ r: MediaRoute) {
        if r.deviceID != 0 { OutputDevices.setDefault(r.deviceID); onChange?(); return }
        mutate { e in for k in e.routes.indices { e.routes[k].selected = e.routes[k].name == r.name } }
        if demo == nil { run("tell application id \"\(Self.bundle)\" to set current AirPlay devices to {AirPlay device \(Self.quote(r.name))}") }
    }
    /// 跳到某秒：MediaRemote 送得到就用（任何 App），否則「音樂」的 player position
    @discardableResult
    func seek(to seconds: Double) -> Bool {
        if MediaRemoteReader.shared.latest != nil, MediaRemote.shared.seek(to: seconds) { return true }
        guard Self.isSource else { return false }
        run("tell application id \"\(Self.bundle)\" to set player position to \(String(format: "%.2f", max(0, seconds)))", then: false)
        return true
    }
    /// 在「音樂」裡顯示這首（加入資料庫、加到播放列表、建立電台都在那裡做）
    func revealInMusic() {
        if demo != nil { return }
        run("tell application id \"\(Self.bundle)\"\n reveal current track\n activate\nend tell", then: false)
    }

    /// 打開「音樂」的某一頁（主頁、廣播、搜尋）：music:// 由「音樂」處理
    static func openMusic(path: String, query: String? = nil) {
        var c = URLComponents(); c.scheme = "music"; c.host = "music.apple.com"; c.path = path
        if let q = query { c.queryItems = [URLQueryItem(name: "term", value: q)] }
        guard let url = c.url, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: 示範（--demo-music）

    static let demoState = MusicPlayerExtras(
        shuffle: false, repeatMode: .off, favorited: true, trackPID: "demo", playlist: "Golden Hour Mix", currentIndex: 3,
        upNext: [MusicQueueItem(title: "Paper Boats", artist: "The Quiet Hours", index: 4), MusicQueueItem(title: "Long Way Home", artist: "Eli Ward", index: 5),
                 MusicQueueItem(title: "Tidal", artist: "Marin & Co.", index: 6), MusicQueueItem(title: "Soft Machines", artist: "Kiri Okafor", index: 7),
                 MusicQueueItem(title: "Late Bloom", artist: "Aoi Hayashi", index: 8), MusicQueueItem(title: "Blue Hour", artist: "Nova Sato", index: 9)],
        routes: [MediaRoute(name: "MacBook Air", kind: "computer", selected: true), MediaRoute(name: "Kitchen", kind: "HomePod", selected: false),
                 MediaRoute(name: "Living Room", kind: "Apple TV", selected: false)])   // l10n-ignore：示範資料（自己編的）
    static let demoHistory = [MusicQueueItem(title: "Morning Coffee", artist: "Lena Brooks"), MusicQueueItem(title: "Window Seat", artist: "Juno Park")]   // l10n-ignore
}

/// Mac 的音訊輸出裝置（Core Audio，公開 API）：列出、換預設輸出
enum OutputDevices {
    static var defaultID: AudioDeviceID {
        var id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }
    /// 有輸出聲道的裝置
    static func list() -> [MediaRoute] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        let def = defaultID
        return ids.compactMap { id in
            var sa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var ss: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &sa, 0, nil, &ss) == noErr, ss > 0 else { return nil }
            var name: Unmanaged<CFString>?
            var na = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var ns = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &na, 0, nil, &ns, &name) == noErr, let n = name?.takeRetainedValue() as String?, !n.isEmpty else { return nil }
            return MediaRoute(name: n, kind: "output", selected: id == def, deviceID: id)
        }
    }
    /// 畫面每幀要：2 秒內重用上一次的清單（Core Audio 的查詢在藍牙裝置上可能卡）
    nonisolated(unsafe) private static var cache: (at: Double, list: [MediaRoute])?
    static func cachedList() -> [MediaRoute] {
        let now = CACurrentMediaTime()
        if let c = cache, now - c.at < 2 { return c.list }
        let l = list(); cache = (now, l); return l
    }
    static func setDefault(_ id: AudioDeviceID) {
        cache = nil
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v = id
        _ = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &v)
    }
}

/// 播客的睡眠計時（手錶／iPhone 播客都有）：時間到或這一集結束就暫停（MediaRemote 的 pause，任何 App 都吃）
final class SleepTimer {
    static let shared = SleepTimer()
    enum Mode: Equatable { case off, minutes(Int), endOfEpisode }
    static let choices: [Mode] = [.off, .minutes(5), .minutes(10), .minutes(15), .minutes(30), .minutes(45), .minutes(60), .endOfEpisode]
    private(set) var mode: Mode = .off
    private(set) var endsAt: Double?     // CACurrentMediaTime
    var demoRemaining: Double?

    private var timer: Timer?
    func set(_ m: Mode, now: Double = CACurrentMediaTime()) {
        mode = m
        if case .minutes(let n) = m { endsAt = now + Double(n) * 60 } else { endsAt = nil }
        timer?.invalidate(); timer = nil
        guard m != .off, !SnapshotPrivacy.active else { return }
        // 一秒看一次（App 關著也要算：計時器掛在主 run loop，不靠畫面重畫）
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let face = (NSApp.delegate as? AppDelegate)?.view?.face
            if self.tick(info: face?.nowPlaying.info) { face?.forceDirty = true }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common); timer = t
    }
    /// 剩幾秒（只有分鐘模式有）
    func remaining(_ now: Double = CACurrentMediaTime()) -> Double? {
        if let d = demoRemaining { return d }
        return endsAt.map { max(0, $0 - now) }
    }
    /// 每秒叫：時間到了／這一集只剩 1 秒就暫停、關掉。回 true＝剛剛暫停了
    @discardableResult
    func tick(info: NowPlayingInfo?, now: Double = CACurrentMediaTime()) -> Bool {
        guard demoRemaining == nil else { return false }
        // 時間到了但沒在播（中途自己暫停了）：只把計時器關掉，不等下次按播放才突然停
        if case .minutes = mode, (endsAt ?? .infinity) <= now, info?.playing != true { set(.off); return false }
        guard let info, info.playing else { return false }
        var fire = false
        switch mode {
        case .off: return false
        case .minutes: fire = (endsAt ?? .infinity) <= now
        case .endOfEpisode:
            if let p = NowPlayingLogic.progress(info, now: now), info.duration > 0 { fire = (1 - p) * info.duration < 1.2 }
        }
        guard fire else { return false }
        set(.off)
        NowPlayingPoller.shared.control(.pause)
        return true
    }
    static func label(_ m: Mode) -> String {
        switch m {
        case .off: return L("sleep.off", "关闭")
        case .minutes(let n): return String(format: L("sleep.minutes", "%d 分钟"), n)
        case .endOfEpisode: return L("sleep.endOfEpisode", "这一集结束时")
        }
    }
}

/// 誰可以看資料庫、誰可以做什麼（照 HomeView：訪客可以聽音樂、控制正在播放，但主人的資料庫、待播、播放記錄、播客訂閱是個人內容）
enum MediaAccess {
    /// 這一下點按來自訪客的 iPhone／iPad（閒置串流）：可以播放／暫停、上下首、跳秒、倍速、音量；不能進資料庫、待播、「…」、換輸出
    static var guestTap: Bool { simulate == "remote" || RemoteInput.fromGuest }
    /// 資料庫、待播、播放記錄、播客的待播與節目：只給主人（訪客模式、認不出、家人、訪客裝置在用都關——Mac 上只有主人那一份資料庫）
    static var personal: Bool { simulate == nil && PersonalGate.allowed && !RemotePrivacy.guestActive }
    /// 快照：--media-guest remote｜local（訪客裝置／Mac 上的訪客）
    nonisolated(unsafe) static var simulate: String? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--media-guest"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }()
}

/// 被打斷就先停、結束後接著播（iOS 的音訊中斷：來電、Siri；這裡是 FaceTime 通話、ClioTalk 開著麥克風、鬧鐘在響）。
/// 只管 Mac 上的播放（iPhone 經 CarPlay 的由 iPhone 自己處理）；使用者在中斷期間自己按了播放／暫停，就不再替他接著播。
/// 每 0.5 秒看一次各自的狀態（不必在別的 App 的檔案裡加呼叫）。
final class MediaInterruption {
    static let shared = MediaInterruption()
    enum Reason: String { case call, assistant, alarm }
    private(set) var active: Set<Reason> = []
    private(set) var pausedByUs = false
    private var pausedAt = -1e9
    private var timer: Timer?

    /// 純邏輯（自檢用）：這一刻要不要停／接著播。回傳 .pause／.resume／nil
    enum Step: Equatable { case pause, resume }
    static func decide(reasons: Set<Reason>, wasActive: Bool, playing: Bool, pausedByUs: Bool) -> Step? {
        if !reasons.isEmpty, !wasActive, playing, !pausedByUs { return .pause }
        if reasons.isEmpty, pausedByUs, !playing { return .resume }
        return nil
    }

    func start() {
        guard timer == nil, !SnapshotPrivacy.active, !CommandLine.arguments.contains("--selftest") else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common); timer = t
    }

    private func poll() {
        var r: Set<Reason> = []
        if FaceTimeCall.shared.active { r.insert(.call) }
        if ClioTalkController.shared.voice.active { r.insert(.assistant) }
        if AlarmCenter.shared.ringing != nil { r.insert(.alarm) }
        let face = (NSApp.delegate as? AppDelegate)?.view?.face
        let mac = !PhoneNowPlayingBridge.shared.active
        let playing = mac && (face?.nowPlaying.info?.playing ?? false)
        let wasActive = !active.isEmpty
        let since = CACurrentMediaTime() - pausedAt
        switch Self.decide(reasons: r, wasActive: wasActive, playing: playing, pausedByUs: pausedByUs) {
        case .pause?: NowPlayingPoller.shared.control(.pause); pausedByUs = true; pausedAt = CACurrentMediaTime()
        case .resume?: NowPlayingPoller.shared.control(.play); pausedByUs = false
        case nil:
            // 暫停送出 4 秒後還（又）在播：使用者自己按了播放（或暫停沒生效）——交給他，不再替他接著播
            if pausedByUs, playing, since > 4 { pausedByUs = false }
        }
        active = r
    }
}
