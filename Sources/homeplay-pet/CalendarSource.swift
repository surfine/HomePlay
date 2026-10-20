import AppKit
import EventKit

// 模組錶面「下一个行程」的真数据：EventKit 读未来 24 小时的第一个行程（全天的排在最后）。
// 不弹框：只有菜单「偏好设定 › 允许读取行事历…」点了才向系统要权限；没授权就老实写没授权。
// 每 5 分钟刷新一次，行事历有变动（EKEventStoreChanged）时立刻刷新。

struct NextEvent: Equatable {
    var title: String
    var start: Date
    var end: Date
    var allDay = false
}

/// 瓷砖要画哪一种状态
enum CalendarTile: Equatable {
    case notConnected               // 还没问过权限 / 用户选了不读
    case denied                     // 系统里被拒绝或受限
    case empty                      // 已授权，24 小时内没有行程
    case event(NextEvent)
}

enum CalendarLogic {
    /// 挑「下一个」：没结束的按开始时间取最早一个；全天行程只在没有定时行程时才用
    static func pick(_ events: [NextEvent], now: Date) -> NextEvent? {
        let live = events.filter { $0.end > now }
        let timed = live.filter { !$0.allDay }.sorted { $0.start < $1.start }
        return timed.first ?? live.filter(\.allDay).sorted { $0.start < $1.start }.first
    }

    /// "10:30–11:00"（24 小时制，和时钟一致）；全天写「全天」
    static func range(_ e: NextEvent, calendar: Calendar = .current) -> String {
        if e.allDay { return L("calendar.allDay", "全天") }
        func t(_ d: Date) -> String {
            let c = calendar.dateComponents([.hour, .minute], from: d)
            return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        }
        return "\(t(e.start))–\(t(e.end))"
    }

    static func tile(auth: EKAuthorizationStatus, on: Bool, event: NextEvent?) -> CalendarTile {
        switch auth {
        case .fullAccess: return !on ? .notConnected : (event.map(CalendarTile.event) ?? .empty)
        case .notDetermined: return .notConnected
        default: return .denied
        }
    }
}

final class CalendarSource {
    static let shared = CalendarSource()
    static let onKey = "HomePlayCalendarOn"
    static let usageKey = "NSCalendarsFullAccessUsageDescription"

    /// 授权后默认读；用户在菜单里取消勾选才停
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: onKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: onKey) }
    }
    /// 没有用途说明就去要权限，系统会直接让进程崩掉；所以只在打包成 App 后才允许问
    static var canRequest: Bool { Bundle.main.object(forInfoDictionaryKey: usageKey) != nil }
    static var auth: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }

    static var disabled = false      // 快照用 --event 时关掉，免得真数据盖掉测试状态
    private let store = EKEventStore()
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private weak var face: Face?
    private let queue = DispatchQueue(label: "homeplay.calendar", qos: .utility)

    func start(face: Face) {
        guard !Self.disabled else { return }
        self.face = face
        guard timer == nil else { refresh(); return }
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common); timer = t
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    func requestAccess() {
        guard Self.canRequest, Self.auth == .notDetermined else { return }
        store.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                if granted { Self.enabled = true }
                log("calendar access \(granted ? "granted" : "denied")")
                self?.refresh()
            }
        }
    }

    func refresh() {
        let auth = Self.auth, on = Self.enabled
        guard auth == .fullAccess, on else { publish(auth, on, nil); return }
        let store = store
        queue.async { [weak self] in
            let now = Date()
            let pred = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(24 * 3600), calendars: nil)
            let events = store.events(matching: pred).map {
                NextEvent(title: $0.title ?? "", start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay)
            }
            let next = CalendarLogic.pick(events, now: now)
            DispatchQueue.main.async { self?.publish(auth, on, next) }
        }
    }

    private func publish(_ auth: EKAuthorizationStatus, _ on: Bool, _ event: NextEvent?) {
        face?.calendarTile = CalendarLogic.tile(auth: auth, on: on, event: event)
    }
}
