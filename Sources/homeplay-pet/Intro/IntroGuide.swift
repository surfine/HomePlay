// 2.0 開場手勢引導：在桌寵自己的螢幕上播幾頁手勢示範（設計稿：手勢引導 canvas，512 稿 ×2＝1024 畫布）。
// 頁序：歡迎 → 從 👀 往下拉回主畫面 → 拉住停一下開切換器 → 右上角往下拉開控制中心 → 左右滑換頁與資源庫 → 桌寵本身 → 其他手勢。
// 每頁都能略過；→／Return 下一頁、← 上一頁、Esc 略過。畫在 IntroScreen.swift。
//
// 出現時機（取代 1.x 的「操作提示卡」：舊卡教的四件事都收進新引導，不再另外出）：
// - 全新安裝：首次設定（Setup/SetupFlow.swift）走完後自動播一次（沿用 Onboarding 的排隊：hello 停著當背景、設定先走）；
// - 升級上來的使用者（偏好裡已經有 HomePlayOnboarded）：不自動播，第一次回到主畫面出一張小提示卡（點了開引導、可關）；
// - 設定 › 一般「重看…」、選單列 HomePlay 選單「手勢引導」隨時重看。
// 依輸入方式換字與換示範：滑鼠說「拖」、觸控板說「拖」或「雙指滑」、手指說「拉／滑」。「自動」看最近一次的輸入來源：
// 直接觸控（Shell/TouchInput.swift 的 .direct 觸控）、觸控板（MultitouchSupport 接觸帧，TrackpadPinch.lastContactAt）、
// 其餘指標事件＝滑鼠。設定裡可以固定一種。
// 快照：--demo-intro <page>[,mouse|trackpad|touch]（不讀也不寫偏好）；HOMEPLAY_ANIM=intro:秒 凍結示範動畫（配 --frames 逐格）。

import AppKit

enum IntroPage: String, CaseIterable {
    case welcome, home, switcher, control, swipe, pet, more

    /// 一輪示範多長（秒；設計稿的 animation-duration）
    var loop: Double {
        switch self {
        case .home, .control: return 3.6
        case .switcher, .pet: return 4
        case .swipe: return 5
        case .welcome: return 4      // 眨眼一輪
        case .more: return 1
        }
    }
    /// 減少動態效果：前後兩格靜態對照（loop 裡的位置 0…1）
    var stills: (before: Double, after: Double)? {
        switch self {
        case .home: return (0.12, 0.76)
        case .switcher: return (0.12, 0.64)
        case .control: return (0.12, 0.48)
        case .swipe: return (0.08, 0.72)
        case .pet: return (0.14, 0.40)
        case .welcome, .more: return nil
        }
    }
    /// 快照沒凍結時鐘時拍哪一格：手勢做到一半、畫面正在回應
    var snapshotPhase: Double {
        switch self {
        case .home: return 0.40
        case .switcher: return 0.60
        case .control: return 0.40
        case .swipe: return 0.24
        case .pet: return 0.38
        case .welcome, .more: return 0.5
        }
    }
}

/// 引導依照的輸入方式
enum IntroInput: String, CaseIterable { case mouse, trackpad, touch }
/// 設定裡的選項（自動＝看最近一次用的）
enum IntroInputSetting: String, CaseIterable { case auto, mouse, trackpad, touch }

enum IntroGuide {
    /// 看過（走完或略過）這一版的手勢引導
    static let seenKey = "intro.seen"
    /// 設定：引導依照的輸入方式（auto|mouse|trackpad|touch）
    static let inputKey = "intro.input"
    /// 最近一次用的輸入來源（自動時用；跨啟動記著）
    static let lastInputKey = "intro.lastInput"
    /// 設定：遇到新手勢時提示一次（預設開；關掉時觸控螢幕的第一次提示卡不出）
    static let tipsKey = "intro.newGestureTips"

    enum Action: Equatable { case next, back, skip, input(IntroInput) }

    nonisolated(unsafe) static var page: IntroPage = .welcome
    nonisolated(unsafe) static var pageAt = -1e9
    nonisolated(unsafe) static var openedAt = -1e9
    /// 收起的時刻（收起後再畫 0.3 s 淡出）
    nonisolated(unsafe) static var closedAt = -1e9
    /// 往後 1、往回 -1（換頁轉場的方向）
    nonisolated(unsafe) static var direction: CGFloat = 1
    /// 快照：固定在這一頁、這種輸入
    nonisolated(unsafe) static var demo: IntroPage?
    nonisolated(unsafe) static var demoInput: IntroInput?
    /// 這一次看的時候在「桌寵本身」那頁手動換的輸入方式（不寫進設定）
    nonisolated(unsafe) static var picked: IntroInput?
    nonisolated(unsafe) static var hits: [IntroHitArea] = []
    nonisolated(unsafe) static var pressed: Action?
    nonisolated(unsafe) static var pressAt = -1e9
    nonisolated(unsafe) static var tracking = false
    /// 這一格畫出來、要給 VoiceOver 念的字（標題、說明、列）
    nonisolated(unsafe) static var texts: [(role: HPAXNote.Role, label: String, rect: CGRect)] = []
    /// 收起時呼叫（Onboarding.close：記下看過、接著原本的第一次流程）
    nonisolated(unsafe) static var onClose: (() -> Void)? = { Onboarding.close() }

    static let transition = 0.32
    static let fadeOut = 0.3

    // MARK: 頁序（純函數）

    /// 頁點只數前六頁（「其他手勢」是收尾清單，沒有頁點）
    static let dotted: [IntroPage] = [.welcome, .home, .switcher, .control, .swipe, .pet]

    static func after(_ p: IntroPage) -> IntroPage? {
        let all = IntroPage.allCases
        guard let i = all.firstIndex(of: p), i + 1 < all.count else { return nil }
        return all[i + 1]
    }
    static func before(_ p: IntroPage) -> IntroPage? {
        let all = IntroPage.allCases
        guard let i = all.firstIndex(of: p), i > 0 else { return nil }
        return all[i - 1]
    }

    // MARK: 出現時機（純函數）

    enum Launch: Equatable { case autoPlay, upgradeHint, nothing }
    /// onboarded：偏好裡有 HomePlayOnboarded（1.x 看過操作提示卡、或 2.0 已經看過引導）；seen：看過這版引導；hintDone：升級提示卡處理過
    static func launch(onboarded: Bool, seen: Bool, hintDone: Bool) -> Launch {
        if !onboarded { return .autoPlay }
        return seen || hintDone ? .nothing : .upgradeHint
    }

    static var seen: Bool { UserDefaults.standard.bool(forKey: seenKey) }
    static var newGestureTips: Bool {
        get { UserDefaults.standard.object(forKey: tipsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: tipsKey) }
    }

    // MARK: 輸入方式

    static var setting: IntroInputSetting {
        get { UserDefaults.standard.string(forKey: inputKey).flatMap(IntroInputSetting.init(rawValue:)) ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: inputKey) }
    }
    nonisolated(unsafe) static var lastInput: IntroInput? = UserDefaults.standard.string(forKey: lastInputKey).flatMap(IntroInput.init(rawValue:))

    /// 純函數：設定＋最近一次的輸入＋這台 Mac 有沒有觸控板 → 照哪一種講
    static func resolve(_ s: IntroInputSetting, last: IntroInput?, hasTrackpad: Bool) -> IntroInput {
        switch s {
        case .mouse: return .mouse
        case .trackpad: return .trackpad
        case .touch: return .touch
        case .auto: return last ?? (hasTrackpad ? .trackpad : .mouse)
        }
    }
    /// 現在照哪一種講（快照 > 這次手動換的 > 設定／自動）
    static var input: IntroInput {
        demoInput ?? picked ?? resolve(setting, last: lastInput, hasTrackpad: TrackpadPinch.shared.available)
    }

    /// 純函數：一下指標事件是哪一種輸入。touch＝觸控造的；sinceTrackpadContact＝觸控板上一次有手指到現在幾秒（nil＝讀不到觸控板）
    static func classify(touch: Bool, sinceTrackpadContact: Double?, preciseScroll: Bool? = nil) -> IntroInput? {
        if touch { return .touch }
        if let s = sinceTrackpadContact { return s < 0.6 ? .trackpad : .mouse }
        // 讀不到觸控板接觸帧：只有捲動事件看得出來（精確捲動＝觸控板；Magic Mouse 也是精確捲動，寧可當觸控板）
        return preciseScroll.map { $0 ? .trackpad : .mouse }
    }
    /// 記下這一下的輸入來源（PetView 的 mouseDown、scrollWheel、觸控開始時叫）
    static func note(_ i: IntroInput?) {
        guard let i, i != lastInput else { return }
        lastInput = i
        if !CommandLine.arguments.contains("--selftest") { UserDefaults.standard.set(i.rawValue, forKey: lastInputKey) }
    }
    static func notePointer(touch: Bool, preciseScroll: Bool? = nil) {
        let tp = TrackpadPinch.shared
        note(classify(touch: touch, sinceTrackpadContact: tp.available ? CACurrentMediaTime() - tp.lastContactAt : nil, preciseScroll: preciseScroll))
    }

    // MARK: 開始、換頁、收起

    static func begin(now: Double = CACurrentMediaTime()) {
        page = demo ?? .welcome
        pageAt = demo != nil ? -1e9 : now
        openedAt = demo != nil ? -1e9 : now
        direction = 1; picked = nil; pressed = nil; tracking = false
        IntroHint.pending = false   // 看了引導，升級提示卡就不用再出
    }

    static func go(_ p: IntroPage, now: Double = CACurrentMediaTime(), dir: CGFloat) {
        page = p; pageAt = now; direction = dir
    }

    /// 走完或略過：記下看過（快照不寫）
    static func markSeen(defaults: UserDefaults = .standard) {
        guard demo == nil else { return }
        defaults.set(true, forKey: seenKey)
    }

    // MARK: 輸入（1024 座標）

    @discardableResult
    static func press(x: CGFloat, y: CGFloat) -> Bool {
        tracking = true
        pressed = hit(CGPoint(x: x, y: y)); pressAt = CACurrentMediaTime()
        return true
    }
    static func release(x: CGFloat?, y: CGFloat?) {
        tracking = false
        let a = pressed
        pressed = nil; pressAt = CACurrentMediaTime()
        guard let a, let x, let y, hit(CGPoint(x: x, y: y)) == a else { return }
        perform(a)
    }
    private static func hit(_ p: CGPoint) -> Action? {
        hits.last { $0.rect.insetBy(dx: -8, dy: -8).contains(p) }?.action
    }

    /// 鍵盤：→／Return 下一頁、← 上一頁、Esc 略過；回 true＝吃掉
    static func action(forKey code: UInt16) -> Action? {
        switch code {
        case 124, 36, 76: return .next
        case 123: return .back
        case 53: return .skip
        default: return nil
        }
    }
    static func key(_ code: UInt16) -> Bool {
        guard let a = action(forKey: code) else { return false }
        perform(a)
        return true
    }

    static func perform(_ a: Action, now: Double = CACurrentMediaTime()) {
        switch a {
        case .next:
            if let n = after(page) { go(n, now: now, dir: 1) } else if demo == nil { close(now: now) }
        case .back:
            if let b = before(page) { go(b, now: now, dir: -1) }
        case .skip:
            if demo == nil { close(now: now) }
        case .input(let i):
            picked = i
        }
    }

    static func close(now: Double = CACurrentMediaTime()) {
        closedAt = now; hits = []; texts = []; pressed = nil; tracking = false
        onClose?()
    }

    /// 示範動畫的時間（秒，0…loop）：HOMEPLAY_ANIM=intro:秒 凍結；快照沒凍結時拍 snapshotPhase 那一格
    static func clock(_ now: Double) -> Double {
        let d = page.loop
        if let f = HPMotion.frozen("intro") { return f.truncatingRemainder(dividingBy: d) }
        if demo != nil { return page.snapshotPhase * d }
        return max(0, now - pageAt).truncatingRemainder(dividingBy: d)
    }

    // MARK: 文案（依輸入方式換字；純函數，selftest 直接驗）

    static func title(_ p: IntroPage, _ i: IntroInput) -> String {
        switch p {
        case .welcome: return L("intro.welcome.title", "嗨，我是 HomePlay")
        case .home: return i == .touch ? L("intro.home.title.touch", "从 👀 往下拉，回主屏幕") : L("intro.home.title.drag", "从 👀 往下拖，回主屏幕")
        case .switcher: return i == .touch ? L("intro.switcher.title.touch", "拉住停一下，开 App 切换器") : L("intro.switcher.title.drag", "拖住停一下，开 App 切换器")
        case .control: return i == .touch ? L("intro.control.title.touch", "右上角往下拉，开控制中心") : L("intro.control.title.drag", "右上角往下拖，开控制中心")
        case .swipe:
            switch i {
            case .touch: return L("intro.swipe.title.touch", "左右滑换页，最后一页之后是资源库")
            case .trackpad: return L("intro.swipe.title.trackpad", "双指左右滑换页，最后一页之后是资源库")
            case .mouse: return L("intro.swipe.title.mouse", "左右拖换页，最后一页之后是资源库")
            }
        case .pet: return L("intro.pet.title", "桌宠本身")
        case .more: return L("intro.more.title", "还有这些")
        }
    }

    static func body(_ p: IntroPage, _ i: IntroInput) -> String {
        switch p {
        case .welcome: return L("intro.welcome.body", "顶端这颗 👀 就是我。\n几个手势，半分钟就会。")
        case .home: return i == .mouse ? L("intro.home.body.click", "在哪里都一样，CarPlay 也是。按一下 👀 也行。")
                                       : L("intro.home.body.tap", "在哪里都一样，CarPlay 也是。点一下 👀 也行。")
        case .switcher:
            switch i {
            case .touch: return L("intro.switcher.body.touch", "左右滑挑一个，往上推掉就关闭。")
            case .trackpad: return L("intro.switcher.body.trackpad", "双指左右滑挑一个，往上拖掉就关闭。")
            case .mouse: return L("intro.switcher.body.mouse", "左右拖挑一个，往上拖掉就关闭。")
            }
        case .control: return i == .touch ? L("intro.control.body.touch", "往上推或按 Esc 收起。键盘上按 C 也能开。")
                                          : L("intro.control.body.drag", "往上拖或按 Esc 收起。键盘上按 C 也能开。")
        case .swipe:
            switch i {
            case .touch: return L("intro.swipe.body.touch", "表盘上左右滑就换表盘。所有 App 都在资源库。")
            case .trackpad: return L("intro.swipe.body.trackpad", "表盘上双指左右滑就换表盘。所有 App 都在资源库。")
            case .mouse: return L("intro.swipe.body.mouse", "表盘上左右拖就换表盘。所有 App 都在资源库。")
            }
        case .pet, .more: return ""
        }
    }

    /// 桌寵本身：三種輸入各自的動作表（同一張表，換字不換結構）
    static func petRows(_ i: IntroInput) -> [(how: String, what: String)] {
        let rotate = L("intro.do.rotate", "转身体"), front = L("intro.do.front", "转回正面"), size = L("intro.do.resize", "放大缩小")
        let carplay = L("intro.do.carplay", "进出 CarPlay"), menu = L("intro.do.menu", "菜单"), move = L("intro.do.move", "搬窗口")
        switch i {
        case .mouse:
            return [(L("intro.pet.dragBody", "拖机身"), rotate), (L("intro.pet.doubleClick", "按两下机身"), front),
                    (L("intro.pet.cmdDrag", "按住 ⌘ 拖"), move), (L("intro.pet.dragCorner", "拖右下角"), size),
                    // 滑鼠沒有重按：空白鍵跟 👀 同一條路（CarPlay ⇄ 主畫面）
                    (L("intro.pet.space", "按空格键"), carplay), (L("intro.pet.rightClick", "按右键"), menu)]
        case .trackpad:
            // 2026-11-07：兩指旋轉＝原地轉身（跟拖機身同一件事，併成一列，表維持六列）
            return [(L("intro.pet.dragOrTwist", "拖机身，或双指旋转"), rotate), (L("intro.pet.doubleTap", "点两下机身"), front),
                    (L("intro.pet.pinch", "双指捏合"), size), (L("intro.pet.twoFingerSwipe", "双指左右滑"), L("intro.do.pages", "换表盘、换页")),
                    (L("intro.pet.forceClick", "用力按屏幕（重按）"), carplay), (L("intro.pet.twoFingerClick", "双指点按"), menu)]
        case .touch:
            return [(L("intro.pet.dragBodyFinger", "单指拖机身"), rotate), (L("intro.pet.doubleTap", "点两下机身"), front),
                    (L("intro.pet.pinch", "双指捏合"), size), (L("intro.pet.dragBase", "拖底座"), move),
                    (L("intro.pet.holdBody", "按住机身"), menu), (L("intro.pet.swipeScreen", "屏幕上单指滑"), L("intro.do.scroll", "滚动、换页"))]
        }
    }

    /// 其他手勢
    static func moreRows(_ i: IntroInput) -> [(how: String, what: String)] {
        [(i == .touch ? L("intro.more.holdEyes.touch", "长按 👀") : L("intro.more.holdEyes", "按住 👀"), L("intro.more.clio", "叫 ClioTalk")),
         (i == .touch ? L("intro.more.edge.touch", "从左缘往右滑") : L("intro.more.edge.drag", "从左缘往右拖"), L("intro.more.back", "返回上一层")),
         (L("intro.more.space", "空格键"), L("intro.more.spaceDoes", "同 👀：CarPlay ⇄ 主屏幕")),
         (L("intro.more.arrows", "CarPlay 上的方向键"), L("intro.more.knob", "像车上的旋钮")),
         (i == .mouse ? "⌘+  ⌘−" : L("intro.pet.pinch", "双指捏合"), L("intro.more.resize", "把桌宠放大缩小"))]
    }

    static func inputName(_ i: IntroInput) -> String {
        switch i {
        case .mouse: return L("intro.input.mouse", "鼠标")
        case .trackpad: return L("intro.input.trackpad", "触控板")
        case .touch: return L("intro.input.touch", "手指")
        }
    }

    // MARK: selftest

    static func selftest(_ check: (Bool, String) -> Void) {
        // 頁序：歡迎 → 回主畫面 → 切換器 → 控制中心 → 換頁與資源庫 → 桌寵本身 → 其他手勢
        var p = IntroPage.welcome, seen = [p]
        while let n = after(p) { p = n; seen.append(p) }
        check(seen == [.welcome, .home, .switcher, .control, .swipe, .pet, .more] && before(.welcome) == nil && before(.more) == .pet,
              "手勢引導：頁序（桌寵本身在其他手勢前面）與上一頁")   // l10n-ignore：selftest 訊息
        check(dotted.count == 6 && !dotted.contains(.more), "手勢引導：頁點六顆，其他手勢那頁沒有頁點")   // l10n-ignore：selftest 訊息
        // 出現時機：全新自動播；升級上來不自動播、出一次提示卡；看過或提示卡處理過就都不出
        check(launch(onboarded: false, seen: false, hintDone: false) == .autoPlay, "手勢引導：全新安裝（沒看過操作提示）自動播")   // l10n-ignore：selftest 訊息
        check(launch(onboarded: true, seen: false, hintDone: false) == .upgradeHint, "手勢引導：升級上來的不自動播，出主畫面小提示")   // l10n-ignore：selftest 訊息
        check(launch(onboarded: true, seen: true, hintDone: false) == .nothing && launch(onboarded: true, seen: false, hintDone: true) == .nothing,
              "手勢引導：看過或提示卡關過，就不再提示")   // l10n-ignore：selftest 訊息
        // 輸入方式：設定固定一種就照它；自動看最近一次，沒有紀錄時有觸控板講觸控板
        check(resolve(.mouse, last: .touch, hasTrackpad: true) == .mouse && resolve(.touch, last: .mouse, hasTrackpad: false) == .touch
              && resolve(.auto, last: .touch, hasTrackpad: true) == .touch && resolve(.auto, last: nil, hasTrackpad: true) == .trackpad
              && resolve(.auto, last: nil, hasTrackpad: false) == .mouse, "手勢引導：輸入方式（固定／自動看最近一次）")   // l10n-ignore：selftest 訊息
        check(classify(touch: true, sinceTrackpadContact: 0.1) == .touch && classify(touch: false, sinceTrackpadContact: 0.1) == .trackpad
              && classify(touch: false, sinceTrackpadContact: 5) == .mouse && classify(touch: false, sinceTrackpadContact: nil) == nil
              && classify(touch: false, sinceTrackpadContact: nil, preciseScroll: true) == .trackpad,
              "手勢引導：輸入來源判斷（觸控造的＝手指、觸控板剛有手指＝觸控板、其餘＝滑鼠）")   // l10n-ignore：selftest 訊息
        // 選字：手指說「拉／滑」，滑鼠說「拖」，觸控板換頁說「雙指滑」
        let saved = L10n.language
        L10n.language = .zhHans
        let homeT = title(.home, .touch), homeM = title(.home, .mouse), swipeP = title(.swipe, .trackpad), swipeM = title(.swipe, .mouse)
        L10n.language = saved
        check(homeT.contains("拉") && homeM.contains("拖") && swipeP.contains("双指") && swipeM.contains("拖") && !swipeM.contains("双指"),   // l10n-ignore：selftest 斷言
              "手勢引導：依輸入方式換字（手指拉、滑鼠拖、觸控板雙指滑）")   // l10n-ignore：selftest 訊息
        // 2026-11-07 手勢語法：轉身體一律說「拖機身」（不說拖螢幕）；觸控板版要教兩指旋轉
        L10n.language = .zhHans
        let rotRows = IntroInput.allCases.map { i in petRows(i).filter { $0.what == L("intro.do.rotate", "转身体") }.map(\.how).joined() }
        L10n.language = saved
        check(rotRows.allSatisfy { $0.contains("机身") && !$0.contains("屏幕") } && rotRows[1].contains("旋转"),   // l10n-ignore：selftest 斷言
              "手勢引導：轉身體只教拖機身；觸控板版加兩指旋轉")   // l10n-ignore：selftest 訊息
        check(IntroInput.allCases.allSatisfy { petRows($0).count == 6 } && Set(IntroInput.allCases.map { petRows($0).map(\.how) }).count == 3,
              "手勢引導：桌寵本身三種輸入各一張六列的表")   // l10n-ignore：selftest 訊息
        // 鍵盤：→／Return 下一頁、← 上一頁、Esc 略過
        check(action(forKey: 124) == .next && action(forKey: 36) == .next && action(forKey: 76) == .next && action(forKey: 123) == .back
              && action(forKey: 53) == .skip && action(forKey: 49) == nil, "手勢引導：鍵盤 → Return 下一頁、← 上一頁、Esc 略過")   // l10n-ignore：selftest 訊息
        // 略過與走完：都記下看過、叫收起；中間按下一頁不收
        let keep = (page, pageAt, demo, onClose, closedAt)
        let suite = "homeplay.selftest.intro"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        var closed = 0
        demo = nil; onClose = { closed += 1; markSeen(defaults: d) }
        page = .welcome; perform(.next)
        let advanced = page == .home && closed == 0
        perform(.skip)
        let skipped = closed == 1 && d.bool(forKey: seenKey)
        page = .more; perform(.next)
        check(advanced && skipped && closed == 2, "手勢引導：下一頁不收、略過與最後一頁的開始使用都收起並記下看過")   // l10n-ignore：selftest 訊息
        // 快照（示範）：只看不寫——略過不收、不記看過
        demo = .home; page = .home; d.removeObject(forKey: seenKey); closed = 0
        perform(.skip); markSeen(defaults: d)
        check(closed == 0 && !d.bool(forKey: seenKey), "手勢引導：快照不收、不寫偏好")   // l10n-ignore：selftest 訊息
        (page, pageAt, demo, onClose, closedAt) = keep
        d.removePersistentDomain(forName: suite)
        // 減少動態效果：示範頁都有前後兩格，而且「後」在「前」之後
        check(IntroPage.allCases.filter { $0 != .welcome && $0 != .more }.allSatisfy { p in p.stills.map { $0.before < $0.after } ?? false },
              "手勢引導：減少動態效果時每頁示範改成前後兩格靜態對照")   // l10n-ignore：selftest 訊息
    }
}

/// 升級上來的使用者第一次回到主畫面：一張小提示卡「有新的手勢引導」（點了開引導、✕ 關掉；12 秒沒動也收）
enum IntroHint {
    static let doneKey = "intro.upgradeHintDone"
    static let duration = 12.0
    nonisolated(unsafe) static var pending = false
    nonisolated(unsafe) static var forced = false   // 快照（--intro-hint）：不讀也不寫偏好
    nonisolated(unsafe) static var shownAt: Double?
    nonisolated(unsafe) static var cardRect = CGRect.zero
    nonisolated(unsafe) static var closeRect = CGRect.zero
    static var done: Bool { UserDefaults.standard.bool(forKey: doneKey) }
    /// 卡片的框（主畫面頂端藥丸底下；左右離螢幕 64）
    static let card = CGRect(x: 64, y: 176, width: 896, height: 232)
    static var radius: CGFloat { HPTokens.Radius.concentric(rect: card) }

    static func finish() {
        pending = false; shownAt = nil
        if !forced { UserDefaults.standard.set(true, forKey: doneKey) }
    }
}
