// 2.0 第五輪：「聊天是一個 App，不是整台電腦」（AI System 6）。回答產出東西時，終點是交給對的 App 的一個物件——
// 計時器、提醒、行程、場景、訊息草稿、通話——畫成物件卡，不只是一段字。
// 物件卡的資料來自工具的輸入（模型不能在卡上加料）；等你說「好」時是草稿（pending），做完是 done，取消就不留卡。

import AppKit

struct ClioHandoff: Equatable {
    enum Kind: String, Equatable { case timer, reminder, event, scene, message, call }
    enum State: Equatable { case pending, done }
    var kind: Kind
    var title: String
    var detail: String
    var state: State

    /// 交給哪個 App（名字照主畫面上的）
    var app: String {
        switch kind {
        case .timer: return L("app.timers", "计时器")
        case .reminder: return L("app.reminders", "提醒事项")
        case .event: return L("app.calendar", "日历")
        case .scene: return L("app.home", "家庭")
        case .message: return L("app.messages", "信息")
        case .call: return "FaceTime"
        }
    }
    var icon: HPIcons.Kind {
        switch kind {
        case .timer: return .timers
        case .reminder: return .reminders
        case .event: return .calendar
        case .scene: return .home
        case .message: return .messages
        case .call: return .facetime
        }
    }
    /// 右邊那一句：草稿＝等你說「好」；做完＝在哪個 App 裡、做了什麼
    var stateText: String {
        guard state == .done else { return L("clio.card.pending", "等你说「好」") }
        switch kind {
        case .timer: return L("clio.card.started", "已开始")
        case .reminder, .event: return L("clio.card.added", "已加入")
        case .scene: return L("clio.card.ran", "已执行")
        case .message: return L("clio.card.sent", "已送出")
        case .call: return L("clio.card.calling", "正在拨打")
        }
    }

    /// 這次工具呼叫會不會產出物件；會就給卡（input 是模型給的參數）
    static func make(tool: String, input: [String: Any], state: State, locale: Locale = L10n.language.locale) -> ClioHandoff? {
        func str(_ k: String) -> String { (input[k] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        switch tool {
        case "timer_set":
            let secs = (input["seconds"] as? NSNumber)?.doubleValue ?? 0
            guard secs >= 1 else { return nil }
            return ClioHandoff(kind: .timer, title: duration(secs, locale: locale), detail: str("label"), state: state)
        case "reminders_add":
            guard !str("title").isEmpty else { return nil }
            let due = ClioDates.parse(str("due")).map { ClioDates.spoken($0, allDay: false, locale: locale) } ?? ""
            return ClioHandoff(kind: .reminder, title: str("title"), detail: due, state: state)
        case "calendar_add_event":
            guard !str("title").isEmpty else { return nil }
            let allDay = input["all_day"] as? Bool ?? false
            var when = ""
            if let s = ClioDates.parse(str("start")) {
                when = ClioDates.spoken(s, allDay: allDay, locale: locale)
                if !allDay, let e = ClioDates.parse(str("end")) { when += "–" + ClioDates.clock(e) }
            }
            if !str("location").isEmpty { when += (when.isEmpty ? "" : " · ") + str("location") }
            return ClioHandoff(kind: .event, title: str("title"), detail: when, state: state)
        case "home_control":
            guard !str("scene").isEmpty else { return nil }   // 開關燈這類是動作不是物件；場景才是
            return ClioHandoff(kind: .scene, title: str("scene"), detail: "", state: state)
        case "messages_send":
            guard !str("contact").isEmpty, !str("text").isEmpty else { return nil }
            // 你的原話：一字不改（AI System 6：你的粗糙不是缺陷）
            return ClioHandoff(kind: .message, title: ClioMessagesTools.displayName(str("contact")), detail: str("text"), state: state)
        case "call":
            guard !str("contact").isEmpty else { return nil }
            let video = input["video"] as? Bool ?? false
            return ClioHandoff(kind: .call, title: str("contact"),
                               detail: video ? L("clio.card.video", "FaceTime 视频") : L("clio.card.audio", "FaceTime 语音"), state: state)
        default:
            return nil
        }
    }

    static func duration(_ secs: Double, locale: Locale) -> String {
        let f = DateComponentsFormatter()
        var cal = Calendar.current; cal.locale = locale
        f.calendar = cal
        f.unitsStyle = .full
        f.allowedUnits = secs >= 3600 ? [.hour, .minute] : secs >= 60 ? [.minute, .second] : [.second]
        f.zeroFormattingBehavior = .dropAll
        return f.string(from: secs) ?? "\(Int(secs))s"
    }

    /// 示範（--cliotalk-demo card、confirm）
    static var demoDraft: ClioHandoff {
        ClioHandoff(kind: .reminder, title: L("clio.demo.reminderTitle", "买 B 的生日礼物"), detail: L("clio.demo.reminderDue", "10月29日 周四 18:00"), state: .pending)
    }
    static var demoTimer: ClioHandoff {
        ClioHandoff(kind: .timer, title: duration(15 * 60, locale: L10n.language.locale), detail: L("clio.demo.timerLabel", "南瓜汤"), state: .done)
    }

    static func selftest(_ check: (Bool, String) -> Void) {
        let en = Locale(identifier: "en_US")
        let t = make(tool: "timer_set", input: ["seconds": 900, "label": "Soup"], state: .done, locale: en)
        check(t?.kind == .timer && t?.title == "15 minutes" && t?.detail == "Soup" && t?.icon == .timers, "物件卡：計時器（時長＋名稱、交給計時器）")
        let r = make(tool: "reminders_add", input: ["title": "Buy gift", "due": "2026-10-29T18:00"], state: .pending, locale: en)
        let rTime = ClioDates.parse("2026-10-29T18:00").map(ClioDates.clock) ?? ""   // 時制照系統（「下午 6:00」「6:00 PM」「18:00」）
        check(r?.kind == .reminder && r?.state == .pending && rTime.contains(Face.uses12Hour ? "6:00" : "18:00") && r?.detail.contains(rTime) == true, "物件卡：提醒草稿帶時間")
        let m = make(tool: "messages_send", input: ["contact": "Mom", "text": "  ok see u at 7 i guess "], state: .pending, locale: en)
        check(m?.kind == .message && m?.detail == "ok see u at 7 i guess", "物件卡：訊息草稿保留原話（不潤飾）")
        check(make(tool: "home_control", input: ["commands": [["target": "lamp", "action": "on"]]], state: .done) == nil
              && make(tool: "home_control", input: ["scene": "Good Morning"], state: .done)?.kind == .scene, "物件卡：場景才有卡，開關燈沒有")   // l10n-ignore：selftest 訊息
        check(make(tool: "get_weather", input: [:], state: .done) == nil && make(tool: "reminders_add", input: [:], state: .done) == nil,
              "物件卡：唯讀工具、缺標題都不出卡")   // l10n-ignore：selftest 訊息
    }
}

// MARK: - 2026：物件卡

extension Face {
    /// 物件卡（2026 Liquid Glass 年代）：左邊交給的那個 App 的圖示、App 名（小字）、標題、細節；右上狀態。
    /// 草稿＝淺灰底＋虛線框（還沒交出去）；做完＝實心卡＋細影。回傳卡的框
    @discardableResult
    func drawClioHandoffCard(_ g: CGContext, _ h: ClioHandoff, top: CGFloat) -> CGRect {
        let A = HPTokens.Assistant.self
        let hasDetail = !h.detail.isEmpty
        let r = CGRect(x: A.rowInset, y: top, width: 1024 - 2 * A.rowInset, height: hasDetail ? 176 : 140)
        let path = continuousRoundedRect(r, radius: 44)
        g.saveGState()
        if h.state == .done {
            g.setShadow(offset: CGSize(width: 0, height: -4), blur: 18, color: NSColor(white: 0, alpha: HPTokens.dark ? 0.4 : 0.12).cgColor)
            g.addPath(path); g.setFillColor((HPTokens.dark ? HPTokens.card : NSColor.white).cgColor); g.fillPath()
            g.restoreGState(); g.saveGState()
            g.addPath(path); g.setStrokeColor(HPTokens.separator.cgColor); g.setLineWidth(2); g.strokePath()
        } else {
            g.addPath(path); g.setFillColor((HPTokens.dark ? HPTokens.card : srgb(0xF2F2F7)).cgColor); g.fillPath()
            g.addPath(path); g.setStrokeColor(HPTokens.secondary.withAlphaComponent(0.55).cgColor)
            g.setLineWidth(3); g.setLineDash(phase: 0, lengths: [12, 10]); g.strokePath()
        }
        g.restoreGState()
        let icon = CGRect(x: r.minX + 30, y: r.midY - 46, width: 92, height: 92)
        HPIcons.draw(h.icon, g, in: icon)
        let x = icon.maxX + 26, right = r.maxX - 34
        let af = HPType.sf(HPType.Size.sourceChip + 4, .semibold), tf = HPType.sf(HPType.Size.rowTitle, .semibold), df = HPType.sf(HPType.Size.rowTrailing, .regular)
        let stf = HPType.sf(HPType.Size.sourceChip + 4, .medium)
        let stateW = Typo.width(h.stateText, stf)
        let top1 = hasDetail ? r.minY + 50 : r.minY + 56
        drawLeft(g, Face.clipped(h.app.uppercased(with: L10n.language.locale), af, right - x - stateW - 20), font: af, x: x, y: top1, color: HPTokens.secondary)
        let stColor = h.state == .done ? HPTokens.green : HPTokens.secondary
        if h.state == .done {
            let d: CGFloat = 26
            drawSymbol(g, "checkmark.circle.fill", in: CGRect(x: right - stateW - d - 8, y: top1 - af.capHeight / 2 - d / 2, width: d, height: d), color: stColor)
        }
        drawLeft(g, h.stateText, font: stf, x: right - stateW, y: top1, color: stColor)
        drawLeft(g, Face.clipped(h.title, tf, right - x), font: tf, x: x, y: top1 + 50, color: HPTokens.label)
        if hasDetail {
            let quoted = h.kind == .message ? String(format: L("clio.card.quote", "“%@”"), h.detail) : h.detail
            drawLeft(g, Face.clipped(quoted, df, right - x), font: df, x: x, y: top1 + 92, color: HPTokens.secondary)
        }
        return r
    }
}
