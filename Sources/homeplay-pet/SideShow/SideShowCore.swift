// SideShow：區網上的舊 iPad／手機當副屏（致敬 Windows SideShow——主機睡著，小螢幕照樣顯示最後的內容）。
// 這個檔是純邏輯（--selftest 直接驗）：金鑰、配對碼、裝置名冊、副屏能看到什麼（白名單）、HTTP 路由。
//
// - 配對：設定 › SideShow › 加入裝置 顯示 QR 碼（網址＋一次性配對碼）。配對碼 40 bits、10 分鐘失效、用一次就失效；
//   同一個來源打錯 3 次就不讓它再試，全部加起來 20 次作廢（照 Remote/RemoteStore 的規則）。
// - 金鑰：裝置用配對碼換一把 32 bytes 的長期金鑰（SecRandomCopyBytes），只存在裝置的 localStorage；
//   Mac 只存 SHA-256 雜湊（~/Library/Application Support/HomePlay/sideshow-devices.json，0600），比對用常數時間。
// - 之後每個請求帶 Authorization: Bearer <裝置 id>.<金鑰>；沒有或不對一律 401，回應裡沒有任何內容。
// - 內容白名單：時鐘設定、天氣、正在播放、計時器、家庭警報；下一個行程是個人內容，主人在設定裡打開才給（訪客模式一律不給）。
//   訊息、攝影機、通訊錄、照片、地點、備註這些欄位在型別裡根本不存在。
// - 網址、配對碼、金鑰都不進日誌。

import Foundation
import CryptoKit
import Security

enum SideShowCrypto {
    /// 系統的密碼學亂數；拿不到就回 nil（呼叫端當失敗處理，不退回較弱的亂數）
    static func random(_ n: Int) -> [UInt8]? {
        var b = [UInt8](repeating: 0, count: n)
        return SecRandomCopyBytes(kSecRandomDefault, n, &b) == errSecSuccess ? b : nil
    }
    static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    static func unhex(_ s: String) -> [UInt8]? {
        guard s.count % 2 == 0 else { return nil }
        var out: [UInt8] = [], it = s.makeIterator()
        while let a = it.next(), let b = it.next() {
            guard let v = UInt8(String([a, b]), radix: 16) else { return nil }
            out.append(v)
        }
        return out
    }
    /// base64url、不補等號（放進 Authorization 標頭不用跳脫）
    static func b64url(_ b: [UInt8]) -> String {
        Data(b).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func sha256(_ s: String) -> [UInt8] { Array(SHA256.hash(data: Data(s.utf8))) }
    /// 常數時間比對：長度不同直接 false（長度本身不是祕密），其餘每個 byte 都比完才回
    static func equal(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var d: UInt8 = 0
        for i in a.indices { d |= a[i] ^ b[i] }
        return d == 0
    }
}

struct SideShowDevice: Codable, Equatable {
    var id: String          // 16 個十六進位字
    var name: String
    var keyHash: String     // SHA-256(金鑰) 的十六進位
    var created: Double
    var lastSeen: Double?
}

final class SideShowStore {
    static let shared = SideShowStore()

    static let enabledKey = "sideshow.enabled"
    static let calendarKey = "sideshow.showCalendar"
    static let portKey = "sideshow.port"
    static let defaultPort: UInt16 = 52426
    static let pairingLifetime: Double = 600
    static let maxFailures = 20, maxFailuresPerIP = 3
    static let maxDevices = 12

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
    /// 主人允許副屏顯示下一個行程（個人內容，預設關）
    static var showCalendar: Bool {
        get { UserDefaults.standard.bool(forKey: calendarKey) }
        set { UserDefaults.standard.set(newValue, forKey: calendarKey) }
    }
    static var port: UInt16 {
        let p = UserDefaults.standard.integer(forKey: portKey)
        return p > 1024 && p < 65536 ? UInt16(p) : defaultPort
    }

    private let lock = NSLock()
    private var devices: [SideShowDevice] = []
    private var pairing: (code: [UInt8], expires: Double, failures: Int, perIP: [String: Int])?
    private var savedSeen: [String: Double] = [:]
    let file: URL?
    var now: () -> Double = { Date().timeIntervalSince1970 }
    /// 名冊變了（配對、移除）：設定頁重畫
    var onChange: (() -> Void)?

    /// file＝nil：只在記憶體（自檢用）
    init(file: URL?) {
        self.file = file
        if let file, let d = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([SideShowDevice].self, from: d) { devices = list }
    }
    /// 名冊檔：跟其他狀態同一個資料夾（HomePlayState.directory），預演用的隔離名字（HOMEPLAY_STATE_NAME）也跟著隔開
    static var defaultFile: URL {
        let dir = ProcessInfo.processInfo.environment["HOMEPLAY_SIDESHOW_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? HomePlayState.directory
        return dir.appendingPathComponent("sideshow-devices.json")
    }
    convenience init() { self.init(file: Self.defaultFile) }

    var all: [SideShowDevice] { lock.lock(); defer { lock.unlock() }; return devices }

    func revoke(_ id: String) {
        lock.lock(); devices.removeAll { $0.id == id }; lock.unlock()
        save(); onChange?()
    }

    // MARK: 配對碼

    /// 產生新的配對碼（舊的同時失效）；回顯示用的 XXXX-XXXX
    @discardableResult
    func newPairing() -> String? {
        guard let b = SideShowCrypto.random(5) else { return nil }
        lock.lock(); pairing = (b, now() + Self.pairingLifetime, 0, [:]); lock.unlock()
        return Self.display(b)
    }
    static func display(_ b: [UInt8]) -> String {
        let s = Array(RemoteCrypto.encode(b))
        return stride(from: 0, to: s.count, by: 4).map { String(s[$0..<min(s.count, $0 + 4)]) }.joined(separator: "-")
    }
    /// 目前有效的配對碼（顯示用）；過期、作廢回 nil
    var pairingCode: String? {
        lock.lock(); defer { lock.unlock() }
        guard let p = pairing, now() < p.expires else { return nil }
        return Self.display(p.code)
    }
    var pairingExpires: Double? { lock.lock(); defer { lock.unlock() }; return pairing?.expires }
    func cancelPairing() { lock.lock(); pairing = nil; lock.unlock() }

    enum PairResult: Equatable { case ok(id: String, key: String), badCode, blocked, full }

    /// 裝置拿配對碼換金鑰：成功＝碼立刻作廢、記下金鑰雜湊、回明文金鑰（只有這一次）
    func redeem(code: String, ip: String, name: String) -> PairResult {
        lock.lock()
        guard var p = pairing, now() < p.expires else { lock.unlock(); return .badCode }
        if p.perIP[ip, default: 0] >= Self.maxFailuresPerIP { lock.unlock(); return .blocked }
        guard let given = RemoteCrypto.decode(code), SideShowCrypto.equal(given, p.code) else {
            p.failures += 1; p.perIP[ip, default: 0] += 1
            pairing = p.failures >= Self.maxFailures ? nil : p
            lock.unlock(); return .badCode
        }
        guard devices.count < Self.maxDevices else { lock.unlock(); return .full }
        guard let idb = SideShowCrypto.random(8), let kb = SideShowCrypto.random(32) else { lock.unlock(); return .badCode }
        let id = SideShowCrypto.hex(idb), key = SideShowCrypto.b64url(kb)
        devices.append(SideShowDevice(id: id, name: Self.clean(name), keyHash: SideShowCrypto.hex(SideShowCrypto.sha256(key)), created: now(), lastSeen: now()))
        pairing = nil
        lock.unlock()
        save(); onChange?()
        return .ok(id: id, key: key)
    }

    /// 裝置自己報的名字：只留可見字元、最多 40 字
    static func clean(_ s: String) -> String {
        let t = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(40)).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "SideShow" : t
    }

    // MARK: 驗證

    /// Authorization 標頭 → 配過的裝置；格式不對、沒這台、金鑰不對都回 nil。
    /// 沒這台也照樣算一次雜湊比一次（回應時間不透露 id 存不存在）
    func authenticate(_ header: String?) -> SideShowDevice? {
        guard let h = header, h.hasPrefix("Bearer ") else { return nil }
        let token = h.dropFirst(7)
        guard let dot = token.firstIndex(of: "."), token.count <= 128 else { return nil }
        let id = String(token[..<dot]), key = String(token[token.index(after: dot)...])
        guard !id.isEmpty, !key.isEmpty else { return nil }
        let given = SideShowCrypto.sha256(key)
        lock.lock()
        let d = devices.first { $0.id == id }
        lock.unlock()
        let stored = d.flatMap { SideShowCrypto.unhex($0.keyHash) } ?? [UInt8](repeating: 0, count: 32)
        guard SideShowCrypto.equal(given, stored), let d else { return nil }
        touch(d.id)
        return d
    }

    /// 最後一次看到：記憶體每次更新，檔案一分鐘最多寫一次
    private func touch(_ id: String) {
        let t = now()
        lock.lock()
        if let i = devices.firstIndex(where: { $0.id == id }) { devices[i].lastSeen = t }
        let write = t - (savedSeen[id] ?? 0) > 60
        if write { savedSeen[id] = t }
        lock.unlock()
        if write { save() }
    }

    /// 寫檔：暫存檔 0600 → 換上
    private func save() {
        guard let file else { return }
        lock.lock(); let list = devices; lock.unlock()
        guard let data = try? JSONEncoder().encode(list) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".sideshow-devices.\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(tmp.path, file.path) != 0 { try? fm.removeItem(at: tmp) }
    }
}

// MARK: - 副屏能看到什麼（白名單）

struct SideShowState: Codable, Equatable {
    struct Weather: Codable, Equatable { var temp: Double; var hi: Double; var lo: Double; var code: Int; var night: Bool; var city: String? }
    struct Track: Codable, Equatable { var title: String; var artist: String; var playing: Bool; var duration: Double; var position: Double }
    /// end：到點的 Unix 秒；paused：暫停中還剩幾秒
    struct Timer: Codable, Equatable { var label: String; var end: Double; var total: Double; var paused: Double? }
    struct Event: Codable, Equatable { var title: String; var start: Double; var allDay: Bool }
    struct Alert: Codable, Equatable { var kind: String; var room: String }

    var v = 1
    var at: Double                 // 產生的時間（Unix 秒）；網頁拿它標「上次更新」
    var fahrenheit: Bool
    var h24: Bool
    var weather: Weather?
    var track: Track?
    var timers: [Timer]
    var next: Event?
    var alerts: [Alert]

    /// JSON 裡允許出現的鍵（自檢逐層掃；新欄位要先加進這裡）
    static let allowedKeys: Set<String> = [
        "v", "at", "fahrenheit", "h24", "weather", "track", "timers", "next", "alerts",
        "temp", "hi", "lo", "code", "night", "city",
        "title", "artist", "playing", "duration", "position",
        "label", "end", "total", "paused",
        "start", "allDay",
        "kind", "room",
    ]
}

enum SideShowContent {
    /// 收集好的原料（主執行緒填；純函數 build 決定哪些能上副屏）
    struct Inputs {
        var now: Double
        var fahrenheit = false
        var h24 = true
        var weather: WeatherData?
        var track: NowPlayingInfo?
        var trackPosition: Double = 0      // 收集當下的播放秒數
        var timers: [ShellTimer] = []
        var events: [AgendaEvent] = []
        var alerts: [HomeAlerts.Alert] = []
        var showCalendar = false           // 主人在設定裡允許
        var guestMode = false              // 控制中心的訪客模式：個人內容一律不給
    }

    /// ShellTimer 的 end 是 timeIntervalSinceReferenceDate
    static let referenceOffset = 978_307_200.0

    static func build(_ i: Inputs) -> SideShowState {
        var s = SideShowState(at: i.now, fahrenheit: i.fahrenheit, h24: i.h24, weather: nil, track: nil, timers: [], next: nil, alerts: [])
        if let w = i.weather {
            s.weather = .init(temp: w.temp, hi: w.hi, lo: w.lo, code: w.code, night: w.night ?? false, city: w.city.map { String($0.prefix(40)) })
        }
        if let t = i.track, !t.title.isEmpty {
            s.track = .init(title: String(t.title.prefix(120)), artist: String(t.artist.prefix(120)), playing: t.playing, duration: t.duration, position: i.trackPosition)
        }
        s.timers = i.timers.prefix(4).map { .init(label: String($0.label.prefix(40)), end: $0.end + referenceOffset, total: $0.total, paused: $0.pausedLeft) }
        if i.showCalendar, !i.guestMode, let e = i.events.first(where: { $0.end.timeIntervalSince1970 > i.now }) {
            s.next = .init(title: String(e.title.prefix(80)), start: e.start.timeIntervalSince1970, allDay: e.allDay)
        }
        s.alerts = i.alerts.prefix(3).map { .init(kind: $0.kind.wire, room: String($0.room.prefix(40))) }
        return s
    }

    static func json(_ s: SideShowState) -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return (try? e.encode(s)) ?? Data("{}".utf8)
    }

    /// 自檢：JSON 裡所有鍵（逐層）
    static func keys(_ data: Data) -> Set<String> {
        func walk(_ o: Any, _ out: inout Set<String>) {
            if let d = o as? [String: Any] { for (k, v) in d { out.insert(k); walk(v, &out) } }
            else if let a = o as? [Any] { for v in a { walk(v, &out) } }
        }
        var out = Set<String>()
        if let o = try? JSONSerialization.jsonObject(with: data) { walk(o, &out) }
        return out
    }
}

extension HomeAlertKind {
    /// 送到網頁的代號（網頁照它挑三語文案）
    var wire: String {
        switch self {
        case .smoke: return "smoke"
        case .carbonMonoxide: return "co"
        case .carbonDioxide: return "co2"
        case .leak: return "leak"
        case .security: return "security"
        }
    }
}

// MARK: - HTTP 路由（純函數：伺服器只負責收送位元組）

struct SideShowRequest {
    var method: String
    var path: String
    var headers: [String: String]     // 鍵小寫
    var body: Data
    var ip: String
}

struct SideShowResponse {
    var code: Int
    var type: String
    var body: Data
    var page = false
    static func json(_ code: Int, _ o: [String: String]) -> SideShowResponse {
        SideShowResponse(code: code, type: "application/json", body: (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data())
    }
    static let unauthorized = json(401, ["error": "unauthorized"])
}

enum SideShowRouter {
    static func handle(_ r: SideShowRequest, store: SideShowStore, state: () -> Data) -> SideShowResponse {
        guard RemoteCrypto.canonicalHost(r.headers["host"] ?? "") != nil else { return .json(421, ["error": "host"]) }
        switch (r.method, r.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return SideShowResponse(code: 200, type: "text/html; charset=utf-8", body: Data(SideShowPage.html.utf8), page: true)
        case ("GET", "/manifest.webmanifest"):
            return SideShowResponse(code: 200, type: "application/manifest+json", body: Data(SideShowPage.manifest.utf8))
        case ("GET", "/sw.js"):
            return SideShowResponse(code: 200, type: "text/javascript; charset=utf-8", body: Data(SideShowPage.serviceWorker.utf8))
        case ("GET", "/sideshow.appcache"):
            return SideShowResponse(code: 200, type: "text/cache-manifest", body: Data(SideShowPage.appCache.utf8))
        case ("GET", "/icon-180.png"), ("GET", "/icon-512.png"):
            return SideShowResponse(code: 200, type: "image/png", body: SideShowPage.icon(r.path == "/icon-180.png" ? 180 : 512))
        case ("POST", "/api/pair"):
            guard r.body.count <= 4096, let o = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any],
                  let code = o["code"] as? String, code.count <= 32 else { return .json(400, ["error": "format"]) }
            switch store.redeem(code: code, ip: r.ip, name: o["name"] as? String ?? "") {
            case .ok(let id, let key): log("sideshow: device paired"); return .json(200, ["id": id, "key": key])
            case .badCode: return .json(403, ["error": "code"])
            case .blocked: return .json(429, ["error": "blocked"])
            case .full: return .json(409, ["error": "full"])
            }
        case ("GET", "/api/state"):
            guard store.authenticate(r.headers["authorization"]) != nil else { return .unauthorized }
            return SideShowResponse(code: 200, type: "application/json", body: state())
        default:
            if r.path.hasPrefix("/api/") { return .unauthorized }
            return r.method == "GET" ? .json(404, ["error": "not found"]) : .json(405, ["error": "method"])
        }
    }
}
