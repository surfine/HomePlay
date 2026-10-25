// ClioTalk 的工具：定義（固定順序，前綴才快取得住）、確認時念給你聽的那句、實際執行（EventKit、天氣、計時器、音樂）。
// 個人資料只在模型呼叫工具時才讀，只回那幾筆；會改資料的（加行程、加提醒）引擎會先停下來等你說「好」。

import AppKit
import EventKit

struct ClioToolResult: Equatable {
    var content: String
    var isError = false
    var source: ClioToolGroup?
}

/// 工具執行器：真的那份在下面（ClioSystemTools），selftest 用假的
protocol ClioToolRunner {
    func run(name: String, input: [String: Any]) async -> ClioToolResult
}

enum ClioToolCatalog {
    static func group(of name: String) -> ClioToolGroup? {
        switch name {
        case "calendar_events", "calendar_add_event": return .calendar
        case "reminders_list", "reminders_add": return .reminders
        case "music_now_playing", "music_control", "music_play": return .music   // 2.0 v2-music：music_play
        case "get_time", "get_weather", "timer_set", "timer_status", "timer_cancel": return .weatherTime
        case "web_search": return .webSearch
        case "messages_read_recent", "messages_send", "find_messages": return .messages
        case "search_web": return .webSearch
        case "home_control": return .home
        case "call": return .calls
        case "identify_song": return .music
        case "open_app": return .apps
        default: return nil
        }
    }

    static let all: [ClioToolSpec] = [
        ClioToolSpec(name: "get_time", description: "Current local date, time, weekday and time zone.",
                     schema: #"{"type":"object","properties":{}}"#),
        ClioToolSpec(name: "get_weather", description: "Current weather and today's high/low near the user (approximate location).",
                     schema: #"{"type":"object","properties":{}}"#),
        // 2.0 P10：多組計時器——加一個不取代、可取名、指名取消（ClioTimers.swift）
        ClioToolSpec(name: "timer_set", description: "Start a new countdown timer on the desk pet screen. Adds to any timers already running (several can run at once). Give it a short name when the user names it (\"pasta\").",
                     schema: #"{"type":"object","properties":{"seconds":{"type":"integer","minimum":1,"maximum":86400},"label":{"type":"string","description":"Short name, e.g. pasta"}},"required":["seconds"]}"#),
        ClioToolSpec(name: "timer_status", description: "List every running timer with its name and time left.",
                     schema: #"{"type":"object","properties":{}}"#),
        ClioToolSpec(name: "timer_cancel", description: "Cancel a timer by name, or every timer with name \"all\". Without a name it cancels the only running timer; if several are running it cancels nothing and lists them so you can ask which.",
                     schema: #"{"type":"object","properties":{"name":{"type":"string","description":"Timer name, or \"all\""}}}"#),
        ClioToolSpec(name: "calendar_events", description: "List the user's calendar events from the start of the given day for a number of days. Dates are local, format YYYY-MM-DD.",
                     schema: #"{"type":"object","properties":{"from":{"type":"string","description":"YYYY-MM-DD, default today"},"days":{"type":"integer","minimum":1,"maximum":31}}}"#),
        ClioToolSpec(name: "calendar_add_event", description: "Add an event to the user's default calendar. The user is asked to confirm before it is added; only report success after the result says it was added. Times are local, format YYYY-MM-DDTHH:MM.",
                     schema: #"{"type":"object","properties":{"title":{"type":"string"},"start":{"type":"string"},"end":{"type":"string"},"all_day":{"type":"boolean"},"location":{"type":"string"}},"required":["title","start"]}"#,
                     needsConfirmation: true),
        ClioToolSpec(name: "reminders_list", description: "List the user's incomplete reminders (title and due date).",
                     schema: #"{"type":"object","properties":{"limit":{"type":"integer","minimum":1,"maximum":50}}}"#),
        ClioToolSpec(name: "reminders_add", description: "Add a reminder to the user's default Reminders list. The user is asked to confirm first; only report success after the result says it was added. Due time is local, format YYYY-MM-DDTHH:MM.",
                     schema: #"{"type":"object","properties":{"title":{"type":"string"},"due":{"type":"string"}},"required":["title"]}"#,
                     needsConfirmation: true),
        ClioToolSpec(name: "music_now_playing", description: "What is playing in Music or Spotify on this Mac (or on the iPhone over CarPlay).",
                     schema: #"{"type":"object","properties":{}}"#),
        ClioToolSpec(name: "music_control", description: "Play, pause, skip to next or previous track.",
                     schema: #"{"type":"object","properties":{"action":{"type":"string","enum":["play","pause","next","previous"]}},"required":["action"]}"#),
        // 2.0 v2-music：「播放…」——在 Mac「音乐」的资料库里找歌名、艺人、专辑或播放列表并播放（ClioTalk/ClioMusicTools.swift）
        ClioToolSpec(name: "music_play", description: "Play a song, artist, album or playlist from the user's Music library on this Mac. Only the local library is searched; Apple Music catalog search is not available.",
                     schema: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#),
        // 2.0: 訊息（放最後：關著時前面的前綴不變，快取照樣吃得到）
        ClioToolSpec(name: "messages_read_recent", description: "Read the latest messages of one conversation in the Mac's Messages app, found by the contact or group name the user said.",
                     schema: #"{"type":"object","properties":{"contact":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":20}},"required":["contact"]}"#),
        ClioToolSpec(name: "messages_send", description: "Send a message in the user's name through the Mac's Messages app to an existing conversation, found by contact or group name. Write exactly the words to send. The user hears it read back and must say OK first; only report it as sent if the result says it was sent.",
                     schema: #"{"type":"object","properties":{"contact":{"type":"string"},"text":{"type":"string"}},"required":["contact","text"]}"#,
                     needsConfirmation: true),
        // 2.0: ClioTalk 2 新增（放最後，前面的快取前綴不變）
        ClioToolSpec(name: "home_control", description: "Control the user's smart home through Apple Home: lights, outlets, thermostats, window coverings, door locks and scenes, or show the camera view on the desk pet screen. Names can be an accessory, a room plus a kind of device (\"living room lights\"), or a scene. Give one entry per accessory or room in \"commands\"; use \"scene\" to run a scene; use \"show_camera\" (a camera name, or empty for all cameras) to open the camera view. Unlocking a door, opening a garage door and disarming security are read back and need the user's OK first; only say it is done after the result says so. Temperatures are in degrees Celsius.",
                     schema: #"{"type":"object","properties":{"commands":{"type":"array","items":{"type":"object","properties":{"target":{"type":"string","description":"Accessory name or room name as the user said it"},"action":{"type":"string","enum":["on","off","set_brightness","set_temperature","set_position","lock","unlock","open","close"]},"value":{"type":"number","description":"Brightness or position 0-100, or temperature in Celsius"}},"required":["target","action"]}},"scene":{"type":"string"},"show_camera":{"type":"string","description":"Camera name, or an empty string for all cameras"}}}"#,
                     needsConfirmation: false),   // 要不要確認看內容：needsConfirmation(name:input:)
        ClioToolSpec(name: "find_messages", description: "Search the user's recent Messages by contact name, keyword, or both, and return a few matching messages (newest first).",
                     schema: #"{"type":"object","properties":{"contact":{"type":"string"},"keyword":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":8}}}"#),
        ClioToolSpec(name: "call", description: "Start a FaceTime audio or video call to a contact from the user's Contacts. The user hears it read back and must say OK first; only report that the call is starting if the result says so.",
                     schema: #"{"type":"object","properties":{"contact":{"type":"string"},"video":{"type":"boolean","description":"true for a video call; default audio"}},"required":["contact"]}"#,
                     needsConfirmation: true),
        ClioToolSpec(name: "identify_song", description: "Listen through the Mac's microphone for about 8 seconds and identify the song that is playing nearby. Tell the user you are listening before you call it.",
                     schema: #"{"type":"object","properties":{}}"#),
        // 2.0 App 平台（放最後：前面的快取前綴不動）
        ClioToolSpec(name: "open_app", description: "Open an app on the desk pet screen by the name the user said: a built-in app (Music, Weather, Timers…) or a web app the user added to the Home Screen from Safari.",
                     schema: #"{"type":"object","properties":{"name":{"type":"string","description":"App name as the user said it"}},"required":["name"]}"#),
    ]
    static let escalate = ClioToolSpec(name: ClioRouter.escalateTool,
                                       description: "Hand this question to a slower, more capable model. Call it only when the question needs multi-step reasoning, careful analysis, long writing or planning; do not answer yourself in the same turn.",
                                       schema: #"{"type":"object","properties":{"reason":{"type":"string"}}}"#)
    static let webSearch = ClioToolSpec(name: "web_search", description: "", schema: "{}", serverType: AnthropicProvider.webSearchType)

    /// 這一輪送給模型的工具：照固定順序，關掉的組不送；網頁搜尋：Anthropic 用伺服器工具，
    /// 其他（DeepSeek、本機模型）有 DeepSeek 金鑰才送 search_web；escalate 只給快模型
    static func specs(_ groups: Set<ClioToolGroup>, provider: ClioProviderID, includeEscalate: Bool, canSearchWeb: Bool = false) -> [ClioToolSpec] {
        guard provider != .onDevice else { return [] }
        var out = all.filter { group(of: $0.name).map(groups.contains) ?? false }
        if provider == .anthropic, groups.contains(.webSearch) { out.append(webSearch) }
        if groups.contains(.webSearch), ClioWebSearch.offered(provider: provider, hasKey: canSearchWeb) { out.append(ClioWebSearch.spec) }
        if includeEscalate { out.append(escalate) }
        return out
    }

    static func spec(_ name: String) -> ClioToolSpec? { all.first { $0.name == name } ?? (name == ClioWebSearch.spec.name ? ClioWebSearch.spec : nil) }

    /// 這次呼叫要不要先念給你聽：多數工具看定義；home_control 看實際動作（開鎖、開車庫、解除警戒才要）
    static func needsConfirmation(name: String, input: [String: Any]) -> Bool {
        if name == "home_control" { return ClioHomeControl.needsConfirmation(input: input) }
        return spec(name)?.needsConfirmation == true
    }

    /// 要你確認的那句（畫面顯示＋朗讀）：第一行問句，第二行「時間：內容」（卡片畫成資料卡）。不需要確認的工具回 nil。
    static func readback(name: String, input: [String: Any], locale: Locale = L10n.language.locale) -> String? {
        func detail(_ when: String, _ title: String) -> String {
            when.isEmpty ? title : String(format: L("clio.confirm.detail", "%1$@：%2$@"), when, title)
        }
        switch name {
        case "calendar_add_event":
            let title = input["title"] as? String ?? ""
            let allDay = input["all_day"] as? Bool ?? false
            var when = ""
            if let s = (input["start"] as? String).flatMap({ ClioDates.parse($0) }) {
                when = ClioDates.spoken(s, allDay: allDay, locale: locale)
                if !allDay, let e = (input["end"] as? String).flatMap({ ClioDates.parse($0) }) { when += "–" + ClioDates.clock(e) }
            }
            return L("clio.confirm.event", "要加这个行程吗？") + "\n" + detail(when, title)
        case "reminders_add":
            let title = input["title"] as? String ?? ""
            let when = (input["due"] as? String).flatMap { ClioDates.parse($0) }.map { ClioDates.spoken($0, allDay: false, locale: locale) } ?? ""
            return L("clio.confirm.reminder", "要加这个提醒吗？") + "\n" + detail(when, title)
        case "home_control":
            return ClioHomeControl.readback(input: input)
        case "call":
            let video = input["video"] as? Bool ?? false
            let who = (input["contact"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return String(format: video ? L("clio.confirm.callVideo", "要用 FaceTime 视频打给 %@ 吗？") : L("clio.confirm.callAudio", "要用 FaceTime 语音打给 %@ 吗？"), who)
        case "messages_send":
            return MessagesReadback.text(name: ClioMessagesTools.displayName(input["contact"] as? String ?? ""), body: input["text"] as? String ?? "")
        default:
            return spec(name)?.needsConfirmation == true ? String(format: L("clio.confirm.generic", "要执行「%@」吗？"), name) : nil
        }
    }
}

enum ClioDates {
    /// 模型給的本地時間：YYYY-MM-DDTHH:MM[:SS]、YYYY-MM-DD HH:MM、YYYY-MM-DD，也接受帶時區的 ISO 8601
    static func parse(_ s: String, timeZone: TimeZone = .current) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: t) { return d }
        for f in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = timeZone; df.dateFormat = f
            if let d = df.date(from: t) { return d }
        }
        return nil
    }
    static func clock(_ d: Date) -> String {
        Face.shortTime(d)   // 2.0：時制照系統（「下午 6:00」「6:00 PM」「18:00」），不再寫死 24 小時
    }
    /// 「10月27日 週二 下午 6:00」這種念得出來的寫法（照介面語言，時制照系統）
    static func spoken(_ d: Date, allDay: Bool, locale: Locale) -> String {
        let df = DateFormatter()
        df.locale = locale
        df.setLocalizedDateFormatFromTemplate("MMMdEEE")
        return allDay ? df.string(from: d) : df.string(from: d) + " " + clock(d)
    }
    /// 給模型看的：本地時間、星期、時區
    static func machine(_ d: Date, timeZone: TimeZone = .current) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = timeZone
        df.dateFormat = "yyyy-MM-dd'T'HH:mm EEE"
        return df.string(from: d) + " " + timeZone.identifier
    }
}

// MARK: - 真的執行

// 計時器轉接（ClioTimerAdapter）在 ClioTimers.swift

final class ClioSystemTools: ClioToolRunner {
    private let store = EKEventStore()

    func run(name: String, input: [String: Any]) async -> ClioToolResult {
        let g = ClioToolCatalog.group(of: name)
        func ok(_ s: String) -> ClioToolResult { ClioToolResult(content: s, source: g) }
        func fail(_ s: String) -> ClioToolResult { ClioToolResult(content: s, isError: true, source: g) }
        switch name {
        case "get_time":
            return ok("Local time: " + ClioDates.machine(Date()))
        case "get_weather":
            let d: WeatherData? = await MainActor.run {
                WeatherSource.shared.activate {}
                return WeatherSource.shared.data
            }
            guard let w = d else { return fail("Weather is not available yet (no location or network). Try again in a minute.") }
            var s = String(format: "Now %.0f°C, %@; today high %.0f°C, low %.0f°C; humidity %.0f%%; wind %.0f km/h",
                           w.temp, Self.weatherText(w.code), w.hi, w.lo, w.humidity, w.wind)
            if let c = w.city { s += "; place: \(c)" }
            if let a = w.aqi { s += String(format: "; US AQI %.0f", a) }
            if let ss = w.sunset { s += "; sunset \(ss)" }
            return ok(s)
        case "timer_set":
            let secs = (input["seconds"] as? NSNumber)?.doubleValue ?? 0
            guard secs >= 1 else { return fail("seconds must be at least 1") }
            let label = input["label"] as? String
            guard let r = await MainActor.run(body: { ClioTimerAdapter.add(seconds: secs, label: label) }) else { return fail("The desk pet is not ready.") }
            return ok("Timer \"\(r.name)\" started for \(Int(secs)) seconds. \(r.running == 1 ? "It is the only timer running." : "\(r.running) timers are running now.")")
        case "timer_status":
            let xs = await MainActor.run { ClioTimerAdapter.list() }
            return ok(ClioTimers.describe(xs, now: TimersApp.wallNow))
        case "timer_cancel":
            let name = input["name"] as? String
            return ok(await MainActor.run { ClioTimerAdapter.cancel(name: name) })
        case "calendar_events":
            guard await access(.event) else { return fail(Self.noAccess("Calendar")) }
            let from = (input["from"] as? String).flatMap { ClioDates.parse($0) } ?? Date()
            let start = Calendar.current.startOfDay(for: from)
            let days = max(1, min(31, (input["days"] as? NSNumber)?.intValue ?? 1))
            let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start.addingTimeInterval(86400)
            let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            let events = store.events(matching: pred).sorted { $0.startDate < $1.startDate }.prefix(40)
            if events.isEmpty { return ok("No events.") }
            return ok(events.map { e in
                var s = "- \(e.title ?? "(untitled)"): " + (e.isAllDay ? ClioDates.machine(e.startDate).prefix(10) + " all day"
                                                                       : ClioDates.machine(e.startDate) + " to " + ClioDates.clock(e.endDate))
                if let l = e.location, !l.isEmpty { s += " @ \(l)" }
                return s
            }.joined(separator: "\n"))
        case "calendar_add_event":
            guard await access(.event) else { return fail(Self.noAccess("Calendar")) }
            guard let title = input["title"] as? String, !title.isEmpty,
                  let start = (input["start"] as? String).flatMap({ ClioDates.parse($0) }) else { return fail("title and start are required") }
            let e = EKEvent(eventStore: store)
            e.title = title
            e.isAllDay = input["all_day"] as? Bool ?? false
            e.startDate = start
            e.endDate = (input["end"] as? String).flatMap { ClioDates.parse($0) } ?? start.addingTimeInterval(e.isAllDay ? 86400 : 3600)
            e.location = input["location"] as? String
            guard let cal = store.defaultCalendarForNewEvents else { return fail("No default calendar.") }
            e.calendar = cal
            do { try store.save(e, span: .thisEvent); return ok("Added to calendar \"\(cal.title)\".") }
            catch { return fail("Could not save the event.") }
        case "reminders_list":
            guard await access(.reminder) else { return fail(Self.noAccess("Reminders")) }
            let limit = max(1, min(50, (input["limit"] as? NSNumber)?.intValue ?? 20))
            let pred = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            let items: [(String, Date?)] = await withCheckedContinuation { c in
                store.fetchReminders(matching: pred) { rs in
                    c.resume(returning: (rs ?? []).map { ($0.title ?? "", $0.dueDateComponents?.date) })
                }
            }
            if items.isEmpty { return ok("No incomplete reminders.") }
            return ok(items.prefix(limit).map { "- \($0.0)" + ($0.1.map { " (due " + ClioDates.machine($0) + ")" } ?? "") }.joined(separator: "\n"))
        case "reminders_add":
            guard await access(.reminder) else { return fail(Self.noAccess("Reminders")) }
            guard let title = input["title"] as? String, !title.isEmpty else { return fail("title is required") }
            let r = EKReminder(eventStore: store)
            r.title = title
            guard let cal = store.defaultCalendarForNewReminders() else { return fail("No default Reminders list.") }
            r.calendar = cal
            if let due = (input["due"] as? String).flatMap({ ClioDates.parse($0) }) {
                r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
                r.addAlarm(EKAlarm(absoluteDate: due))
            }
            do { try store.save(r, commit: true); return ok("Added to Reminders list \"\(cal.title)\".") }
            catch { return fail("Could not save the reminder.") }
        case "music_now_playing":
            let info = await MainActor.run { (NSApp.delegate as? AppDelegate)?.view?.face.nowPlaying.info }
            guard let i = info else { return ok("Nothing is playing (or Mac Now Playing is turned off in HomePlay settings).") }
            return ok("\(i.playing ? "Playing" : "Paused"): \"\(i.title)\" by \(i.artist.isEmpty ? "unknown artist" : i.artist)")
        case "music_control":
            let cmd: MediaCommand
            switch input["action"] as? String {
            case "play": cmd = .play
            case "pause": cmd = .pause
            case "next": cmd = .next
            case "previous": cmd = .previous
            default: return fail("action must be play, pause, next or previous")
            }
            let handled: Bool = await MainActor.run {
                if NowPlayingPoller.shared.activeBundle != nil || PhoneNowPlayingBridge.shared.active { NowPlayingPoller.shared.control(cmd); return true }
                return false
            }
            if handled { return ok("Done.") }
            // 「正在播放」沒開：直接叫「音乐」，但只在它已經在跑的時候（絕不替使用者打開）
            guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.Music" }) else {
                return fail("No music app is running.")
            }
            let verb = ["play": "play", "pause": "pause", "next": "next track", "previous": "previous track"][input["action"] as? String ?? ""] ?? "playpause"
            await MainActor.run { _ = NSAppleScript(source: "tell application id \"com.apple.Music\" to \(verb)")?.executeAndReturnError(nil) }
            return ok("Done.")
        case "music_play":
            return await ClioMusicTools.play(query: input["query"] as? String ?? "")
        case "messages_read_recent", "messages_send":
            return await ClioMessagesTools.run(name: name, input: input)
        case "find_messages":
            return await ClioFindMessages.run(input: input)
        case "call":
            return await ClioCallTools.run(input: input)
        case "home_control":
            return await ClioHomeTools.run(input: input)
        case "identify_song":
            return await ClioSongTools.run()
        case "open_app":
            return await ClioAppTools.run(input: input)
        case "search_web":
            return await ClioWebSearch.run(input: input, key: ClioKeychain.load(.deepseek))
        default:
            return ClioToolResult(content: "Unknown tool \(name).", isError: true)
        }
    }

    private static func noAccess(_ what: String) -> String {
        "\(what) access is not granted. Tell the user to allow it in HomePlay Settings › Permissions (or System Settings › Privacy & Security)."
    }

    /// 只在用途說明有寫進 App 時才問（沒寫就問，系統會讓行程崩掉）
    private func access(_ type: EKEntityType) async -> Bool {
        let st = EKEventStore.authorizationStatus(for: type)
        if st == .fullAccess { return true }
        guard st == .notDetermined else { return false }
        let key = type == .event ? CalendarSource.usageKey : "NSRemindersFullAccessUsageDescription"
        guard Bundle.main.object(forInfoDictionaryKey: key) != nil else { return false }
        do {
            return type == .event ? try await store.requestFullAccessToEvents() : try await store.requestFullAccessToReminders()
        } catch { return false }
    }

    /// WMO 天氣代碼 → 給模型看的英文
    static func weatherText(_ code: Int) -> String {
        switch code {
        case 0: return "clear"
        case 1, 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "fog"
        case 51...57: return "drizzle"
        case 61...67, 80...82: return "rain"
        case 71...77, 85, 86: return "snow"
        case 95...99: return "thunderstorm"
        default: return "code \(code)"
        }
    }
}
