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

        // compact（2026-11-13）：藥丸貼合內容——圖示緊接文字、中間沒有原本眼睛的空位，整顆置中、54 高、碰不到問候語
        let c = S.layout(top: 46, single: (40, 76), minimal: [])
        let greetingTop = HPTokens.Home.greetingBaseline - HPTokens.Home.greetingSize * 0.75
        check(abs(c.pill.midX - 512) < 0.01 && c.pill.height == S.height && c.pill.minY == 46 && c.pill.maxY < greetingTop
              && c.pill.width == 40 + S.innerGap + 76 + 2 * S.endPad
              && c.leading.map { $0.minX == c.pill.minX + S.endPad && $0.width == 40 && c.trailing.minX - $0.maxX == S.innerGap } == true
              && c.trailing.width == 76 && c.trailing.maxX == c.pill.maxX - S.endPad,
              "Live Activity compact：寬度剛好包住內容（圖示＋12＋文字＋兩端各 18），圖示和文字靠在一起，置中、54 高、不壓問候語（\(c.pill)）")   // l10n-ignore：selftest 訊息
        let iconOnly = S.layout(top: 46, single: (40, 0), minimal: [])
        check(iconOnly.pill.width == 40 + 2 * S.endPad && iconOnly.trailing.width == 0 && iconOnly.leading?.midX == 512 && iconOnly.pill.minY == 46,
              "Live Activity compact：只有圖示的（CarPlay）是一顆 76 寬的小藥丸，圖示在正中")   // l10n-ignore：selftest 訊息
        // 實際的 CarPlay 那則標題是空字串：量出來要是 0，不然整顆會變寬、圖示偏左（2026-11-13 修）
        let cpTrail = S.textWidth(S.carPlayActivity().title, Face.rounded(28, weight: .semibold), cap: 150)
        check(cpTrail == 0 && S.textWidth("Mom", Face.rounded(28, weight: .semibold), cap: 150) > 0,
              "Live Activity compact：空字串的寬度是 0（CarPlay 那顆只有圖示）")   // l10n-ignore：selftest 訊息
        // CarPlay 在背景＝一則即時動態（取代綠色角標）：有會話在背景才出現、排最後、滿了擠掉第三個；點它回 CarPlay、不展開
        let cp = S.carPlayActivity()
        let three = [act(.timer, "timers"), act(.music, "music"), act(.call, "facetime")]
        check(S.isCarPlay(cp) && cp.title.isEmpty && cp.detail.isEmpty && cp.symbol == "car.fill" && !S.isCarPlay(three[0])
              && S.pillActivities([], carPlayBehind: false).isEmpty && S.pillActivities([], carPlayBehind: true).map(\.appID) == [CarPlayApp.id]
              && S.pillActivities(three, carPlayBehind: false).count == 3
              && S.pillActivities(three, carPlayBehind: true).map(\.appID) == ["timers", "music", CarPlayApp.id]
              && S.pillActivities([three[0]], carPlayBehind: true).map(\.appID) == ["timers", CarPlayApp.id],
              "Live Activity：CarPlay 在背景是一顆車子圖示的藥丸，有會話在背景才出現；滿三個時也一定留著")   // l10n-ignore：selftest 訊息
        let savedShown = S.shown, savedHits = S.hits, savedExpanded = S.expandedApp
        var opened: [String] = [], homes = 0
        S.expandedApp = nil
        S.shown = [cp]; S.hits = [(.pill, CGRect(x: 474, y: 46, width: 76, height: 54))]
        let tapCP = S.tap(CGPoint(x: 512, y: 70), long: false, now: 0, face: Face(), open: { opened.append($0.appID) }, home: { homes += 1 })
        let holdCP = S.tap(CGPoint(x: 512, y: 70), long: true, now: 0, face: Face(), open: { opened.append($0.appID) }, home: { homes += 1 })
        S.shown = [three[0], cp]; S.hits = [(.pill, CGRect(x: 474, y: 46, width: 76, height: 54)), (.minimal(1), CGRect(x: 562, y: 46, width: 62, height: 54))]
        let tapTimer = S.tap(CGPoint(x: 512, y: 70), long: false, now: 0, face: Face(), open: { opened.append($0.appID) }, home: { homes += 1 })
        let tapMini = S.tap(CGPoint(x: 590, y: 70), long: true, now: 0, face: Face(), open: { opened.append($0.appID) }, home: { homes += 1 })
        check(tapCP && holdCP && tapTimer && tapMini && opened == [CarPlayApp.id, CarPlayApp.id, CarPlayApp.id] && homes == 1 && S.expandedApp == nil,
              "Live Activity：點 CarPlay 那顆＝回 CarPlay（按住也是，沒有大卡）；其他藥丸照舊是 Home 鍵")   // l10n-ignore：selftest 訊息
        S.shown = savedShown; S.hits = savedHits; S.expandedApp = savedExpanded
        // 回歸 #15：換頁只從「乾淨」的上一幀取舊畫面
        check(Face.transitionSource(dim: 0, pageDir: 0, status: .notConnected, hasLast: true, hasSettled: false) == .last
              && Face.transitionSource(dim: 0.4, pageDir: 0, status: .notConnected, hasLast: true, hasSettled: true) == .settled
              && Face.transitionSource(dim: 0, pageDir: 1, status: .notConnected, hasLast: true, hasSettled: true) == .settled
              && Face.transitionSource(dim: 0, pageDir: 0, status: .live, hasLast: true, hasSettled: true) == .settled
              && Face.transitionSource(dim: 0, pageDir: 0, status: .paused, hasLast: true, hasSettled: false) == .none,
              "換頁來源：壓暗／換頁中／CarPlay 直播暫停都不用 lastFrame（回歸 #15）")   // l10n-ignore：selftest 訊息
        // 回歸 #17b：iPhone 鏡像活動沒有可讀內容，不得把膠囊長成空的深色大藥丸
        let phone = LiveActivity(kind: .iphone, title: "計時器", detail: "1:00", accent: .blue, progress: nil, appID: "bridge")   // l10n-ignore
        let empty = LiveActivity(kind: .call, title: "", detail: " ", accent: .green, progress: nil, appID: "facetime")
        let call = LiveActivity(kind: .call, title: "通話", detail: "1:00", accent: .green, progress: nil, appID: "facetime")   // l10n-ignore
        let music = LiveActivity(kind: .music, title: "歌", detail: "人", accent: .blue, progress: 0.2, appID: "music")   // l10n-ignore
        check(!Face.growsCapsule([phone], musicActive: false)
              && Face.growsCapsule([call], musicActive: false)
              && !Face.growsCapsule([empty], musicActive: false)
              && !Face.growsCapsule([music], musicActive: true)
              && Face.growsCapsule([music], musicActive: false)
              && Face.growsCapsule([phone, call], musicActive: false),
              "Live Activity：空內容與 iPhone 鏡像不長大；通話／有字的活動才長（回歸 #17b）")   // l10n-ignore：selftest 訊息
        // 回歸 #18：再長的內容也不能把膠囊撐成巨物；槽與膠囊同一個上限
        let huge = S.layout(top: 46, single: (40, 2000), minimal: [])
        check(huge.pill.width <= S.maxWidth + 0.01 && huge.trailing.width <= S.maxWidth - 2 * S.endPad - 40 - S.innerGap + 0.01
              && huge.trailing.width < 2000 && huge.trailing.maxX <= huge.pill.maxX - S.endPad + 0.01,
              "Live Activity compact：內容槽受上限約束（膠囊 ≤ \(S.maxWidth)、槽 ≤ \(huge.trailing.width)）")   // l10n-ignore：selftest 訊息
        // minimal：中間一顆、兩個分離（右、左）；每顆都貼合內容——圓形，寬內容是橢圓；中間那顆也沒有空位
        let m = S.layout(top: 46, single: nil, minimal: [38, 26, 80])
        let mSpan = m.detached.reduce(m.pill) { $0.union($1) }
        check(m.detached.count == 2 && m.detached[0].minX > m.pill.maxX && m.detached[1].maxX < m.pill.minX
              && m.detached[0].width == m.detached[0].height && m.detached[1].width > m.detached[1].height
              && m.pill.width == max(S.height, 38 + 2 * S.minimalPad) && abs(mSpan.midX - 512) < 0.01 && abs(m.trailing.midX - m.pill.midX) < 0.01
              && m.trailing.width == 38 && m.pill.maxY < greetingTop && m.pill.minY == 46,
              "Live Activity minimal：整組（主＋分離）置中；每顆寬度跟著內容（圓形或橢圓），沒有留空")   // l10n-ignore：selftest 訊息
        // expanded：上緣＝膠囊上緣（沒有額頭）、左右貼內容邊線（shell-layout.md 第 6 節）、跟螢幕同心、高度照內容
        let big = S.expandedRect(height: S.expandedHeight(.timer), top: 46)
        check(big.minY == 46 && big.minX == HPGrid.Content.leading && big.maxX == HPGrid.Content.trailing && S.expandedRadius(big) <= Screen.concentric(inset: S.expandedInset)
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
