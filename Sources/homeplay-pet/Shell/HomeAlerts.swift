// 家庭警報（HomeView 對齊 WP5）：官方家庭警報詞彙——
// 煙霧／一氧化碳／二氧化碳／水漏／門窗安全五類，文案照官方原文（標題＋「…detected in 房間」；
// 門窗是「%@ opened at 時間」）。桌寵的數據源：HomeLink 快照裡對應的配件狀態；這裡只放
// 純邏輯（種類、文案、過期）與橫幅資料，畫在 HomeApp 頂部。
import AppKit

enum HomeAlertKind: String, CaseIterable, Equatable {
    case smoke, carbonMonoxide, carbonDioxide, leak, security

    /// 官方標題原文
    var officialTitle: String {
        switch self {
        case .smoke: return "Smoke"
        case .carbonMonoxide: return "Carbon Monoxide"
        case .carbonDioxide: return "Carbon Dioxide"
        case .leak: return "Water Leak"
        case .security: return "Home Security"
        }
    }
    /// 本地化標題（走 L()；三語鍵在 xcstrings）
    var title: String {
        switch self {
        case .smoke: return L("home.alert.smoke", "烟雾")
        case .carbonMonoxide: return L("home.alert.co", "一氧化碳")
        case .carbonDioxide: return L("home.alert.co2", "二氧化碳")
        case .leak: return L("home.alert.leak", "漏水")
        case .security: return L("home.alert.security", "家庭安防")
        }
    }
    var symbol: String {
        switch self {
        case .smoke: return "smoke.fill"
        case .carbonMonoxide, .carbonDioxide: return "wind"
        case .leak: return "drop.fill"
        case .security: return "door.left.hand.open"
        }
    }
}

enum HomeAlerts {
    struct Alert: Equatable {
        var kind: HomeAlertKind
        var room: String
        var detail: String?     // 門窗類：「前門 opened at 14:32」
        var at: Double          // CACurrentMediaTime
    }

    nonisolated(unsafe) static var active: [Alert] = []
    /// 有變化就 +1（觸發/收掉/過期）——畫面端 tick 對比它決定重畫
    nonisolated(unsafe) static var version = 0

    /// 官方文案格式（🟢 實測）：leak/smoke/CO/CO₂＝「X detected in 房間」；security＝「門 opened at 時間」
    static func body(_ a: Alert) -> String {
        switch a.kind {
        case .leak: return String(format: L("home.alert.leak.body", "检测到%@漏水"), a.room)
        case .smoke: return String(format: L("home.alert.smoke.body", "检测到%@有烟雾"), a.room)
        case .carbonMonoxide: return String(format: L("home.alert.co.body", "检测到%@有一氧化碳"), a.room)
        case .carbonDioxide: return String(format: L("home.alert.co2.body", "检测到%@有二氧化碳"), a.room)
        case .security: return a.detail ?? String(format: L("home.alert.security.body", "%@被打开"), a.room)
        }
    }

    static func fire(_ kind: HomeAlertKind, room: String, detail: String? = nil, now: Double) {
        // 去重：同類型+同房間還在顯示中就不疊（`at` 不參與身分）
        guard !active.contains(where: { $0.kind == kind && $0.room == room && !expired($0, now: now) }) else { return }
        active.append(Alert(kind: kind, room: room, detail: detail, at: now))
        version &+= 1
    }
    static func dismiss(_ a: Alert) { active.removeAll { $0 == a }; version &+= 1 }

    /// 警報放多久自己收（官方沒有實測值；對齊桌寵橫幅節奏取 30 秒 🟡）
    static let autoDismiss: Double = 30
    static func expired(_ a: Alert, now: Double) -> Bool { now - a.at > autoDismiss }
    static func tick(_ now: Double) -> Bool {
        let before = active.count
        active.removeAll { expired($0, now: now) }
        if active.count != before { version &+= 1 }
        return active.count != before
    }
}

// MARK: - 真實事件（HomeLink 快照轉移；HomeView 對齊後續 #3）

extension HomeAlerts {
    /// 特徵碼 → 警報類型。幫手（HomePlay Home）目前送 contact/motion/lockCurrent/doorState；
    /// smoke/co/co2/leak 等幫手加上映射後這裡自動生效（前向相容）。
    static func kind(forCode code: String) -> HomeAlertKind? {
        switch code {
        case "smoke": return .smoke
        case "co": return .carbonMonoxide
        case "co2": return .carbonDioxide
        case "leak": return .leak
        case "contact", "motion", "doorState", "lockCurrent": return .security
        default: return nil
        }
    }

    /// 快照轉移：false→true 的偵測類特徵就觸發一則（房間名取 room，沒有取配件名）。
    /// 純讀舊新兩份快照，時間用傳入的 now（可測）。
    @discardableResult
    static func note(old: HomeSnapshot?, new: HomeSnapshot, now: Double) -> Bool {
        var fired = false
        for acc in new.accessories {
            for ch in acc.characteristics {
                guard let k = kind(forCode: ch.type), ch.value?.bool == true else { continue }
                let was = old?.accessories.first { $0.id == acc.id }?
                    .characteristics.first { $0.id == ch.id }?.value?.bool ?? false
                guard !was else { continue }
                let room = acc.room ?? acc.name
                let detail: String?
                switch ch.type {
                case "contact", "doorState":   // 官方安防文案：「%@ opened at 時間」
                    let f = DateFormatter(); f.dateFormat = "HH:mm"
                    detail = String(format: L("home.alert.opened.at", "%1$@ opened at %2$@"), acc.name, f.string(from: Date(timeIntervalSinceReferenceDate: ClockKit.wall)))
                case "motion": detail = L("home.alert.motion", "检测到移动")
                default: detail = nil
                }
                fire(k, room: room, detail: detail, now: now)
                fired = true
            }
        }
        return fired
    }
}

// MARK: - Demo 觸發（拍板 2026-11-05：接真數據源前先能演示/逐格拍）

extension HomeAlerts {
    /// --demo-alert leak|smoke|co|co2|security [房間名]：直接觸發一則警報（返回有沒有觸發）
    @discardableResult
    static func demoTrigger(_ args: [String]) -> Bool {
        guard let i = args.firstIndex(of: "--demo-alert"), i + 1 < args.count else { return false }
        let kind: HomeAlertKind? = {
            switch args[i + 1] {
            case "leak": return .leak
            case "smoke": return .smoke
            case "co": return .carbonMonoxide
            case "co2": return .carbonDioxide
            case "security": return .security
            default: return .leak
            }
        }()
        guard let k = kind else { return false }
        let room = i + 2 < args.count && !args[i + 2].hasPrefix("--") ? args[i + 2] : L("home.alert.demo.room", "厨房")
        fire(k, room: room, detail: k == .security ? L("home.alert.demo.opened", "前门 opened at 14:32") : nil, now: CACurrentMediaTime())
        return true
    }
}

// MARK: - 自檢

enum HomeAlertsSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        check(HomeAlertKind.allCases.map(\.rawValue) == HVTruth.alertKinds, "警報：五類＝官方詞彙（煙霧/CO/CO₂/水漏/安防）")   // l10n-ignore
        check(HomeAlertKind.leak.officialTitle == "Water Leak" && HomeAlertKind.security.officialTitle == "Home Security", "警報：官方標題原文對得上")   // l10n-ignore
        let t = 1000.0
        HomeAlerts.active = []
        HomeAlerts.fire(.leak, room: "Kitchen", now: t)
        HomeAlerts.fire(.leak, room: "Kitchen", now: t)   // l10n-ignore：重複不疊
        HomeAlerts.fire(.smoke, room: "Living", now: t)   // l10n-ignore
        check(HomeAlerts.active.count == 2 && HomeAlerts.body(HomeAlerts.active[0]).contains("Kitchen"), "警報：觸發、去重、文案帶房間")   // l10n-ignore
        check(!HomeAlerts.expired(HomeAlerts.active[0], now: t + 29) && HomeAlerts.expired(HomeAlerts.active[0], now: t + 31), "警報：30 秒自動收")   // l10n-ignore
        _ = HomeAlerts.tick(t + 31)
        check(HomeAlerts.active.isEmpty, "警報：tick 收走過期的")   // l10n-ignore
        HomeAlerts.active = []

        // 真實事件：快照轉移偵測（HomeLink 特徵碼；smoke/co/leak 等幫手加上後自動生效）
        let mk: (String, String, String?, Bool) -> HomeSnapshot = { accID, code, room, on in
            HomeSnapshot(ready: true, homes: [], rooms: [], accessories: [
                HomeAccessory(id: accID, name: accID == "door" ? "Front Door" : accID, home: nil, room: room,
                              category: "sensor", categoryName: "Sensor", reachable: true,
                              characteristics: [HomeCharacteristic(id: "c1", type: code, value: HomeValue(bool: on), writable: false, units: nil, min: nil, max: nil, step: nil)])
            ], scenes: [], automations: [])
        }
        let before = mk("door", "contact", "Living", false), opened = mk("door", "contact", "Living", true)
        HomeAlerts.note(old: before, new: opened, now: 2000)
        check(HomeAlerts.active.count == 1 && HomeAlerts.active[0].kind == .security && HomeAlerts.active[0].room == "Living"
              && HomeAlerts.active[0].detail?.contains("opened at") == true, "警報：門窗 false→true 觸發安防（帶 opened at）")   // l10n-ignore
        HomeAlerts.note(old: before, new: opened, now: 2000)   // 沒有舊值可對？old 一樣是 false：再來一則同 kind+room 被去重
        check(HomeAlerts.active.count == 1, "警報：同房間同類不重複")   // l10n-ignore
        HomeAlerts.note(old: opened, new: opened, now: 2001)   // true→true：不是轉移
        HomeAlerts.active = []
        check(HomeAlerts.active.isEmpty, "警報：持續開著不重複觸發")   // l10n-ignore
        HomeAlerts.note(old: mk("s", "smoke", "Kitchen", false), new: mk("s", "smoke", "Kitchen", true), now: 2002)
        check(HomeAlerts.active.first?.kind == .smoke && HomeAlerts.active.first?.room == "Kitchen", "警報：煙霧碼直接生效（前向相容）")   // l10n-ignore
        HomeAlerts.active = []
    }
}

extension Notification.Name { static let homeAlertFired = Notification.Name("HomePlayHomeAlertFired") }
