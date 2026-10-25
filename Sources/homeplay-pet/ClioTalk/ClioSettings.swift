// ClioTalk 的偏好（UserDefaults；金鑰不在這裡，在鑰匙圈）。設定頁與引擎都讀這一份。

import Foundation

/// 每組工具一個同意開關（設定頁「ClioTalk 可以用的资料」）。個人資料只在模型呼叫工具時才讀。
enum ClioToolGroup: String, CaseIterable, Codable {
    case calendar, reminders, music, weatherTime, webSearch, messages
    // 2.0: 家庭控制、打電話（新增放最後：設定頁的順序與工具快取前綴都不動）
    case home, calls
    case apps   // 2.0 App 平台：打開 App 與 Web App

    /// 只給主人的（訪客模式、認不出主人時不送給模型）
    var isPersonal: Bool { self == .calendar || self == .reminders || self == .messages || self == .home || self == .calls }
    /// 預設開著？訊息讀的是別人寫給你的話、又能替你送出：預設關
    var defaultOn: Bool { self != .messages }

    var title: String {
        switch self {
        case .calendar: return L("clio.tool.calendar", "日历")
        case .reminders: return L("clio.tool.reminders", "提醒事项")
        case .music: return L("clio.tool.music", "音乐")
        case .weatherTime: return L("clio.tool.weatherTime", "天气、时间与计时器")
        case .webSearch: return L("clio.tool.web", "网页搜索")
        case .messages: return L("clio.tool.messages", "信息")
        case .home: return L("clio.tool.home", "家庭")
        case .calls: return L("clio.tool.calls", "电话")
        case .apps: return L("clio.tool.apps", "打开 App")
        }
    }
    var note: String {
        switch self {
        case .calendar: return L("clio.tool.calendar.note", "查行程、加行程；加之前会先念给你听")
        case .reminders: return L("clio.tool.reminders.note", "列出、新增；新增前会先念给你听")
        case .music: return L("clio.tool.music.note", "控制 Mac 的「音乐」或 Spotify")
        case .weatherTime: return L("clio.tool.weatherTime.note", "用大概的位置；开、查、取消计时器")
        case .webSearch: return L("clio.tool.web.note", "Anthropic 用它自己的搜索；DeepSeek 与本机模型用 DeepSeek 的搜索 API")
        case .messages: return L("clio.tool.messages.note", "读最近的对话、拟回复；送出前会先念给你听")
        case .home: return L("clio.tool.home.note", "控制配件与场景、看摄像头；开锁、开车库门前会先念给你听")
        case .calls: return L("clio.tool.calls.note", "用 FaceTime 打给联系人；拨出前会先念给你听")
        case .apps: return L("clio.tool.apps.note", "按名字打开 App 和 Web App；访客打不开个人的")
        }
    }
    /// 卡片底下「来自…」
    var source: String {
        switch self {
        case .calendar: return L("clio.source.calendar", "日历")
        case .reminders: return L("clio.source.reminders", "提醒事项")
        case .music: return L("clio.source.music", "音乐")
        case .weatherTime: return L("clio.source.weather", "天气")
        case .webSearch: return L("clio.source.web", "网页")
        case .messages: return L("clio.source.messages", "信息")
        case .home: return L("clio.source.home", "家庭")
        case .calls: return L("clio.source.calls", "电话")
        case .apps: return L("clio.source.apps", "App")
        }
    }
}

/// 一次請求用的設定快照（引擎只認這個，selftest 可以自己給）
struct ClioConfig {
    var provider: ClioProviderID = .anthropic
    var fastModel = ClioProviderID.anthropic.defaultFast
    var deepModel = ClioProviderID.anthropic.defaultDeep
    var autoEscalate = true
    var tools: Set<ClioToolGroup> = Set(ClioToolGroup.allCases)
    var monthlyCap = 5.0
    /// 2.0: 有 DeepSeek 金鑰＝DeepSeek／本機模型可以用 search_web
    var canSearchWeb = false
    /// 2.0 第六輪（使用者決定 #2）：每輪的狀態帶主人的名（不帶姓）和大約的城市；關掉時只對雲端模型拿掉，本機模型（LM Studio、Apple Intelligence）照帶
    var shareNameAndCity = true
    var sendsNameAndCity: Bool { shareNameAndCity || !provider.needsKey }
    /// 對話紀錄的 token 預算（估算）；裝置端情境小得多
    var historyBudget: Int { provider == .onDevice ? 2_000 : provider == .lmStudio ? 12_000 : 24_000 }   // lmStudio：上限，供應商按實際情境長度再修剪
}

enum ClioSettings {
    private static let d = UserDefaults.standard
    static let changed = Notification.Name("ClioTalkSettingsChanged")
    private static func note() { NotificationCenter.default.post(name: changed, object: nil) }

    static var provider: ClioProviderID {
        get { d.string(forKey: "ClioTalkProvider").flatMap(ClioProviderID.init(rawValue:)) ?? .anthropic }
        set { d.set(newValue.rawValue, forKey: "ClioTalkProvider"); note() }
    }
    static func fastModel(_ p: ClioProviderID) -> String {
        d.string(forKey: "ClioTalkFast.\(p.rawValue)").flatMap { p.fastChoices.contains($0) ? $0 : nil } ?? p.defaultFast
    }
    static func setFastModel(_ m: String, _ p: ClioProviderID) { d.set(m, forKey: "ClioTalkFast.\(p.rawValue)"); note() }
    static func deepModel(_ p: ClioProviderID) -> String {
        d.string(forKey: "ClioTalkDeep.\(p.rawValue)").flatMap { p.deepChoices.contains($0) ? $0 : nil } ?? p.defaultDeep
    }
    static func setDeepModel(_ m: String, _ p: ClioProviderID) { d.set(m, forKey: "ClioTalkDeep.\(p.rawValue)"); note() }

    static var autoEscalate: Bool {
        get { d.object(forKey: "ClioTalkAutoEscalate") as? Bool ?? true }
        set { d.set(newValue, forKey: "ClioTalkAutoEscalate"); note() }
    }
    static func toolOn(_ g: ClioToolGroup) -> Bool { d.object(forKey: "ClioTalkTool.\(g.rawValue)") as? Bool ?? g.defaultOn }
    static func setTool(_ g: ClioToolGroup, _ on: Bool) { d.set(on, forKey: "ClioTalkTool.\(g.rawValue)"); note() }

    /// 每月上限（美元）；0＝不限
    static var monthlyCap: Double {
        get { d.object(forKey: "ClioTalkMonthlyCap") as? Double ?? 5 }
        set { d.set(max(0, newValue), forKey: "ClioTalkMonthlyCap"); note() }
    }
    /// 一句一句念出回答
    static var speak: Bool {
        get { d.object(forKey: "ClioTalkSpeak") as? Bool ?? true }
        set { d.set(newValue, forKey: "ClioTalkSpeak"); note() }
    }
    /// F5：CarPlay 沒在直播時交給 ClioTalk（直播時一律給 iPhone 的 Siri）
    static var f5OpensClioTalk: Bool {
        get { d.object(forKey: "ClioTalkF5") as? Bool ?? true }
        set { d.set(newValue, forKey: "ClioTalkF5"); note() }
    }

    /// 用說的問完、回答也念完之後再聽 8 秒（不用再按 F5）；說話也能打斷朗讀
    static var followUpListening: Bool {
        get { d.object(forKey: "ClioTalkFollowUp") as? Bool ?? true }
        set { d.set(newValue, forKey: "ClioTalkFollowUp"); note() }
    }

    /// 「讓模型知道我的名字與城市」（設定 › ClioTalk，預設開）
    static var shareNameAndCity: Bool {
        get { d.object(forKey: "ClioTalkShareNameCity") as? Bool ?? true }
        set { d.set(newValue, forKey: "ClioTalkShareNameCity"); note() }
    }

    static var config: ClioConfig {
        let p = provider
        var c = ClioConfig(provider: p, fastModel: fastModel(p), deepModel: deepModel(p), autoEscalate: autoEscalate,
                           tools: Set(ClioToolGroup.allCases.filter { toolOn($0) && (PersonalGate.cached || !$0.isPersonal) }), monthlyCap: monthlyCap,
                           canSearchWeb: ClioKeychain.load(.deepseek) != nil)   // 訪客：個人資料的工具不送
        c.shareNameAndCity = shareNameAndCity
        return c
    }
}

/// F5 的分流（純邏輯）：直播中 → iPhone Siri；沒直播且設定打開 → ClioTalk。按下時決定，放開跟著同一邊。
struct ClioF5Router {
    private(set) var heldForClio = false
    /// 回 true＝這次按鍵歸 ClioTalk（呼叫端不要再送給 iPhone）
    mutating func route(down: Bool, carPlayLive: Bool, clioEnabled: Bool) -> Bool {
        if down {
            heldForClio = !carPlayLive && clioEnabled
            return heldForClio
        }
        defer { heldForClio = false }
        return heldForClio
    }
}
