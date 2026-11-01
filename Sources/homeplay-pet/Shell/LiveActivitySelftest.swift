// 2.0 P03 的 --selftest：頂端 👀 膠囊的三種呈現（compact／minimal／expanded）版面、最多三個、8 小時、設定開關、
// 點訊息活動直接進那串對話、點計時器活動選到那一組。全部離線（訊息用示範資料）。

import AppKit

enum LiveActivitySelftest {
    static func run(_ check: (Bool, String) -> Void) {
        typealias S = LiveActivityStack
        func act(_ k: LiveActivity.Kind, _ id: String) -> LiveActivity {
            LiveActivity(kind: k, title: id, detail: "4:30", accent: .orange, progress: 0.5, appID: id)
        }
        // 最多三個、關掉的不顯示、超過 8 小時收掉
        var seen: [String: Double] = ["old": 0, "gone": 50]
        let four = [act(.timer, "timers"), act(.music, "music"), act(.call, "facetime"), act(.message, "messages")]
        let v = S.visible(four, wall: 100, seen: &seen, enabled: { _ in true })
        check(v.map(\.appID) == ["timers", "music", "facetime"] && seen["gone"] == nil, "Live Activity：最多三個，照順序；結束的不再記")   // l10n-ignore：selftest 訊息
        let off = S.visible(four, wall: 100, seen: &seen, enabled: { $0 != "music" })
        check(off.map(\.appID) == ["timers", "facetime", "messages"], "Live Activity：設定關掉的 App 不顯示")
        var aged: [String: Double] = ["timers": 0]
        let old = S.visible([act(.timer, "timers"), act(.music, "music")], wall: S.maxAge + 1, seen: &aged, enabled: { _ in true })
        check(old.map(\.appID) == ["music"], "Live Activity：超過 8 小時就結束")

        // compact：眼睛在正中、左右同寬緊貼、跟島一樣高、碰不到問候語
        let eh: CGFloat = 60
        let c = S.layout(eyesHalf: eh, top: 46, single: (40, 76), minimal: [])
        let greetingTop = HPTokens.Home.greetingBaseline - HPTokens.Home.greetingSize * 0.75
        check(abs(c.pill.midX - 512) < 0.01 && c.pill.height == S.height && c.leading.map { $0.width == c.trailing.width && $0.maxX <= 512 - eh } == true
              && c.trailing.minX >= 512 + eh && c.pill.maxY < greetingTop && c.pill.width < 440,
              "Live Activity compact：👀 正中、左右同寬緊貼眼睛、62 高、比舊的 440 窄、不壓問候語（\(c.pill)）")   // l10n-ignore：selftest 訊息
        // minimal：一個接在膠囊、兩個分離（右、左），寬內容是橢圓
        let m = S.layout(eyesHalf: eh, top: 46, single: nil, minimal: [38, 34, 80])
        check(m.detached.count == 2 && m.detached[0].minX > m.pill.maxX && m.detached[1].maxX < m.pill.minX
              && m.detached[0].width == m.detached[0].height && m.detached[1].width > m.detached[1].height
              && m.trailing.minX >= 512 + eh && m.pill.maxY < greetingTop,
              "Live Activity minimal：一個接在膠囊、其餘分離在兩側；圓形或橢圓")   // l10n-ignore：selftest 訊息
        // expanded：上緣＝膠囊上緣（沒有額頭）、跟螢幕同心、高度照內容
        let big = S.expandedRect(height: S.expandedHeight(.timer), top: 46)
        check(big.minY == 46 && big.minX == S.expandedInset && S.expandedRadius(big) <= Screen.concentric(inset: S.expandedInset)
              && S.expandedHeight(.assistant) < S.expandedHeight(.timer) && S.expandedHeight(.music) > S.expandedHeight(.timer),
              "Live Activity expanded：上緣貼著膠囊、同心圓角、高度隨內容")   // l10n-ignore：selftest 訊息

        // 深連結：點訊息活動 → 訊息 App 停在那串對話
        let face = Face(); face.frozen = true
        let savedMode = MessagesDemo.mode, savedNav = Shell.nav
        MessagesDemo.mode = "list"
        MessagesApp.shared.demoIncoming()
        let navigate: (String) -> Void = { id in
            _ = Shell.nav.handle(.openApp(id), faceIndex: 0, faceCount: 1)
            AppRegistry.app(id)?.didOpen(now: CACurrentMediaTime())
        }
        if let a = MessagesApp.shared.liveActivity(face: face, now: CACurrentMediaTime()) {
            S.open(a, navigate: navigate)
            check(a.link == "demo" && Shell.nav.screen == .app("messages") && MessagesApp.shared.page == .thread("demo"),
                  "Live Activity：點訊息開到那串對話（screen=\(Shell.nav.screen) page=\(MessagesApp.shared.page)）")   // l10n-ignore：selftest 訊息
        } else {
            check(false, "Live Activity：示範的新訊息應該有活動")
        }
        _ = MessagesApp.shared.handleBack(now: 0)
        // 計時器：點了選到那一組（不是最快到點的那組也一樣）
        Shell.nav = savedNav
        let savedTimers = Shell.timers; Shell.timers = TimerBook()   // 用一本乾淨的計時器帳：前面的檢查可能留了計時器
        defer { Shell.timers = savedTimers }
        let id = Shell.timers.add(seconds: 300, label: "t", now: TimersApp.wallNow)
        if let a = TimersApp.shared.liveActivity(face: face, now: CACurrentMediaTime()) {
            S.open(a, navigate: navigate)
            check(a.link == String(id) && Shell.nav.screen == .app("timers") && TimersApp.shared.selected == id, "Live Activity：點計時器開到那一組")
        } else {
            check(false, "Live Activity：計時器應該有活動")
        }
        Shell.timers.remove(id)
        MessagesDemo.mode = savedMode; Shell.nav = savedNav

        // 鬧鐘（iOS 26 AlarmKit）：響鈴中有 LA、按鈕是稍后／停止；貪睡中有 LA、detail 是倒數、只有停止；沒事就沒有
        let alarm = AlarmItem(id: 1, hour: 6, minute: 30, label: "x", days: [], enabled: true)
        let now0 = Date()
        let ringLA = AlarmCenter.activity(ringing: alarm, snoozed: nil, wall: now0)
        check(ringLA?.kind == .alarm && ringLA?.link == "ring" && ringLA?.detail == "6:30" && ringLA?.appID == "alarms"
              && ringLA?.accent == AlarmsApp.accent, "鬧鐘 Live Activity：響鈴中有活動，compact 顯示鬧鐘時間（ring）")   // l10n-ignore：selftest 訊息
        let snoozeLA = AlarmCenter.activity(ringing: nil, snoozed: (alarm, now0.addingTimeInterval(522)), wall: now0)
        check(snoozeLA?.kind == .alarm && snoozeLA?.link == "snooze" && snoozeLA?.detail == "8:42"
              && AlarmCenter.activity(ringing: nil, snoozed: nil, wall: now0) == nil, "鬧鐘 Live Activity：貪睡中有活動，detail 是倒數 8:42；沒響沒貪睡就沒有")   // l10n-ignore：selftest 訊息
        // 按鈕：在大卡裡出現的由 laExpanded 畫，這裡驗核心動作——稍后＝貪睡 9 分鐘、停止＝清掉兩種狀態
        let ac = AlarmCenter.shared   // 不 upsert：那會寫進真的 UserDefaults
        ac.debugRing(alarm)
        ac.snooze(face)
        check(ac.ringing == nil && ac.snoozeUntil.map { abs($0.timeIntervalSinceNow - AlarmCenter.snoozeMinutes * 60) < 2 } == true
              && ac.activity?.link == "snooze", "鬧鐘 Live Activity：「稍后」＝貪睡 \(Int(AlarmCenter.snoozeMinutes)) 分鐘，活動變成倒數版")   // l10n-ignore：selftest 訊息
        ac.stop(face)
        check(ac.activity == nil, "鬧鐘 Live Activity：「停止」（貪睡中也一樣）收掉活動")   // l10n-ignore：selftest 訊息

        // iPhone 即時動態（系統轉來的）：接進同一個堆疊、排最前、點擊交給 iPhone Mirroring、收起後消失
        ActivityBridge.shared.applyDemo(appName: "外送")   // l10n-ignore：自測的假資料（下面照名字比對）
        let acts = face.shellActivities(CACurrentMediaTime())
        check(acts.first?.kind == .iphone && acts.first?.appID == ActivityBridge.mirroringAppID && acts.first?.title == "外送"
              && acts.first?.detail.isEmpty == false,
              "iPhone 即時動態：排在最前、帶 App 名與已進行時間、點擊交給鏡像")   // l10n-ignore：selftest 訊息
        ActivityBridge.shared.hide("demo-iphone")
        check(face.shellActivities(CACurrentMediaTime()).allSatisfy { $0.kind != .iphone },
              "iPhone 即時動態：按「收起」後不再出現在膠囊")   // l10n-ignore：selftest 訊息
        // 2.0 align E：兩則 iPhone 活動共用 mirroringAppID，身分要分得開（展開、8 小時各算各的）
        let blue = NSColor.systemBlue
        let two = ["a", "b"].map { LiveActivity(kind: .iphone, title: $0, detail: "0:01", accent: blue, progress: nil, appID: ActivityBridge.mirroringAppID, link: $0) }
        var seenTwo: [String: Double] = [:]
        let vis = LiveActivityStack.visible(two, wall: 100, seen: &seenTwo, enabled: { _ in true })
        check(two[0].uid != two[1].uid && vis.count == 2 && seenTwo.count == 2, "iPhone 即時動態：兩則同時在，身分各自獨立")   // l10n-ignore：selftest 訊息

        // 快下雨了（WeatherAlert）：60 分鐘內會開始下雨＝有；正在下＝沒有；資料過期＝沒有
        let wall = Date(timeIntervalSince1970: 1_800_000_000)
        let soon = WeatherApp.demoRainData(date: wall)
        let hit = WeatherAlert.next(data: soon, updatedAt: wall.addingTimeInterval(-600), now: wall)
        check(hit?.kind == .rain && hit.map { abs($0.start.timeIntervalSince(wall) - 25 * 60) < 1 } == true,
              "快下雨了：25 分鐘後開始下雨＝有提醒，開始時間是那一格")   // l10n-ignore：selftest 訊息
        var raining = soon; raining.code = 61
        check(WeatherAlert.next(data: raining, updatedAt: wall, now: wall) == nil, "快下雨了：現在已經在下就不提醒")   // l10n-ignore：selftest 訊息
        check(WeatherAlert.next(data: soon, updatedAt: wall.addingTimeInterval(-2 * 3600 - 60), now: wall) == nil
              && WeatherAlert.next(data: soon, updatedAt: nil, now: wall) == nil, "快下雨了：資料超過 2 小時沒更新就不提醒")   // l10n-ignore：selftest 訊息
    }
}
