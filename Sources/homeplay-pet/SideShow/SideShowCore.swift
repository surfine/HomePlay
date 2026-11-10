// 副屏能看到什麼（白名單）——純邏輯，--selftest 直接驗。
//
// 這是 Windows SideShow 的 SCF endpoint 在 HomePlay 的等價物（考據與拍板：docs/plans/sideshow.md）：
// 主機睡著，裝置照樣看得到最後一份內容（快取在裝置的 service worker 裡）。
// 白名單：時鐘設定、天氣、正在播放、計時器、家庭警報；下一個行程是個人內容，每台裝置各自決定。
// 訊息、攝影機、通訊錄、照片、地點、備註這些欄位在型別裡根本不存在。
//
// 身分與網路由 Remote/RemoteStore 與 Remote/RemoteServer 管：一個 listener、一份名冊、一套配對碼。

import Foundation

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
        var showCalendar = false           // 這台裝置允許看下一個行程
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

// MARK: - HTTP 路由的位元組容器（純函數：伺服器只負責收送）

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
    var location: String? = nil
    static func json(_ code: Int, _ o: [String: String]) -> SideShowResponse {
        SideShowResponse(code: code, type: "application/json", body: (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data())
    }
    static let unauthorized = json(401, ["error": "unauthorized"])
    static func redirect(_ to: String) -> SideShowResponse {
        SideShowResponse(code: 308, type: "text/plain; charset=utf-8", body: Data(), location: to)
    }
}
