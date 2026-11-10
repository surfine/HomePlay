// 副屏（side endpoint）的內容：一份白名單，主執行緒每 5 秒拍一次，請求直接拿最近那份。
//
// 這是 Windows SideShow 的 SCF endpoint 在 HomePlay 的等價物（docs/plans/sideshow.md）：
// 主機睡著，装置照樣看得到最後一份內容——差別只在 HomePlay 的快取在裝置的 service worker 裡。
//
// 兩種版本同時備好：有個人內容（主人自己的裝置）與沒有。個人內容只有「下一個行程」一種，
// 訊息、攝影機、通訊錄、照片、地點在型別裡根本不存在（SideShowContent）。

import AppKit

final class SideShowFeed {
    static let shared = SideShowFeed()

    weak var face: Face?
    /// 測試／快照：用這個取代真的收集（不讀任何使用者資料）
    var inputsOverride: (() -> SideShowContent.Inputs)?

    private let lock = NSLock()
    private var broad = Data("{}".utf8)      // 主人裝置：含下一個行程
    private var narrow = Data("{}".utf8)     // 訪客裝置：只有公開內容
    private var timer: Timer?

    var currentState: Data { lock.lock(); defer { lock.unlock() }; return narrow }

    func state(personal: Bool) -> Data {
        lock.lock(); defer { lock.unlock() }
        return personal ? broad : narrow
    }

    func start() {
        refresh()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate(); timer = nil
    }

    /// 主執行緒：拍一份白名單內容（兩種版本）
    func refresh() {
        let i = inputsOverride?() ?? Self.collect(face: face)
        var a = i; a.showCalendar = true
        var b = i; b.showCalendar = false
        let da = SideShowContent.json(SideShowContent.build(a)), db = SideShowContent.json(SideShowContent.build(b))
        lock.lock(); broad = da; narrow = db; lock.unlock()
    }

    /// 從 HomePlay 已有的來源收（主執行緒）
    static func collect(face: Face?) -> SideShowContent.Inputs {
        let now = Date().timeIntervalSince1970
        var i = SideShowContent.Inputs(now: now)
        i.fahrenheit = Locale.current.measurementSystem == .us
        i.h24 = !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")
        i.weather = WeatherSource.shared.data
        if let f = face, let t = f.nowPlaying.info, !t.title.isEmpty {
            i.track = t
            i.trackPosition = t.position + (t.playing && !t.fixed ? max(0, CACurrentMediaTime() - t.stamp) * max(0.25, t.rate) : 0)
        }
        i.timers = Shell.timers.sorted
        i.guestMode = Shell.guestMode
        if !i.guestMode { i.events = SBWidgetData.events(now: Date()) ?? [] }   // 給不給由每台裝置的 personal 決定（build 再看 showCalendar）
        i.alerts = HomeAlerts.active
        return i
    }
}
