// 2.0 首次設定：第一次打開（沒有任何設定）或設定裡「重新設定」時，走幾頁全螢幕引導：
// 歡迎（👀）→ 語言 → 權限 → 連 iPhone／CarPlay → 外觀（Look）→ 完成。
// 節奏照官方的首次設定：一頁一件事、一句標題、一兩句說明、底下一顆主要按鈕；能略過的寫「以后再说」。
// 權限按了才請求（不在進頁時一口氣跳系統框），已給的打勾；家庭交給「HomePlay Home」小幫手自己問。
// 升級上來的使用者不會被強迫走：偏好裡有任何一個用過的痕跡、或 CarPlay 設定檔已經存在，就不自動出現。
// 快照：--demo-onboarding welcome|language|permissions|carplay|look|done（假資料，不讀也不寫偏好）。
// 畫在 SetupScreen.swift；hello 停著當背景、設定走完才出操作提示卡（Onboarding.swift）。

import AppKit
import AVFoundation
import Contacts
import Speech

enum SetupPage: String, CaseIterable {
    case welcome, language, permissions, carplay, look, done
}

/// 首次設定裡問的權限（跟 PermissionKind 分開：家庭、完整磁碟取用、螢幕錄製沒有「彈系統框」這一步）
enum SetupPermission: String, CaseIterable {
    case home, contacts, fullDisk, screenRecording, microphone
}

enum SetupPermState: Equatable { case granted, notDetermined, denied, unavailable }

enum SetupFlow {
    /// 走完或略過（之後就不自動出現；設定裡「重新设置」照樣能叫出來）
    static let doneKey = "setup.completed"
    /// 用過的痕跡：有任何一個就不是全新（升級上來的使用者不會被強迫走一遍）
    static let footprintKeys = [doneKey, Onboarding.defaultsKey, PetLanguage.defaultsKey, HPLook.defaultsKey, PosterStore.defaultsKey,
                                PersonHome.key, SBStore.key, RemindersApp.sharedKey]
    static let askedScreenKey = "setup.askedScreenRecording"

    enum Action: Equatable {
        case next, back, skipAll, language(PetLanguage?), permission(SetupPermission), look(String)
    }

    nonisolated(unsafe) static var active = false
    /// 排著：等 hello 寫完再出（第一次打開）
    nonisolated(unsafe) static var pending = false
    nonisolated(unsafe) static var page: SetupPage = .welcome
    nonisolated(unsafe) static var pageAt = -1e9
    nonisolated(unsafe) static var from: SetupPage?
    /// 往後 1、往回 -1（轉場的方向）
    nonisolated(unsafe) static var direction: CGFloat = 1
    /// 快照：固定在這一頁、用假資料
    nonisolated(unsafe) static var demo: SetupPage?
    nonisolated(unsafe) static var hits: [(Action, CGRect)] = []
    nonisolated(unsafe) static var pressed: Action?
    nonisolated(unsafe) static var pressAt = -1e9
    nonisolated(unsafe) static var tracking = false
    /// 權限狀態：進權限頁時讀一次，之後每秒重讀（完整磁碟取用、螢幕錄製是在系統設定裡打開的）
    nonisolated(unsafe) static var perms: [SetupPermission: SetupPermState] = [:]
    nonisolated(unsafe) private static var permsAt = -1e9
    /// 走完（不是快照）：AppDelegate 接著做原本的第一次流程（操作提示、CarPlay 配對引導）
    nonisolated(unsafe) static var onFinish: (() -> Void)?

    static let transition = 0.32

    // MARK: 要不要自動出現（純函數，selftest 直接測）

    /// 全新：偏好裡沒有任何用過的痕跡、也沒有 CarPlay 設定檔
    static func isPristine(hasKey: (String) -> Bool, configExists: Bool) -> Bool {
        !configExists && !footprintKeys.contains(where: hasKey)
    }
    static func shouldAutoShow(defaults: UserDefaults = .standard, configExists: Bool) -> Bool {
        isPristine(hasKey: { defaults.object(forKey: $0) != nil }, configExists: configExists)
    }
    static func markDone(defaults: UserDefaults = .standard) { defaults.set(true, forKey: doneKey) }

    // MARK: 頁序（純函數）

    static func after(_ p: SetupPage) -> SetupPage? {
        let all = SetupPage.allCases
        guard let i = all.firstIndex(of: p), i + 1 < all.count else { return nil }
        return all[i + 1]
    }
    static func before(_ p: SetupPage) -> SetupPage? {
        let all = SetupPage.allCases
        guard let i = all.firstIndex(of: p), i > 0, p != .done else { return nil }
        return all[i - 1]
    }

    // MARK: 開始、換頁、結束

    /// 設定裡「重新设置」：馬上出現（不等 hello）
    static func start(now: Double = CACurrentMediaTime()) {
        active = true; pending = false
        go(.welcome, now: now, dir: 1)
        from = nil
    }

    static func go(_ p: SetupPage, now: Double = CACurrentMediaTime(), dir: CGFloat) {
        from = page; page = p; pageAt = now; direction = dir
        if p == .permissions { refreshPermissions(now: now, force: true) }
    }

    static func finish() {
        guard active else { return }
        active = false; pending = false; hits = []
        if demo == nil { markDone() }
        onFinish?()
    }

    // MARK: 輸入（1024 座標）

    @discardableResult
    static func press(x: CGFloat, y: CGFloat) -> Bool {
        guard active else { return false }
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
        hits.last { $0.1.insetBy(dx: -8, dy: -8).contains(p) }?.0
    }

    /// Return＝主要按鈕，Esc＝上一頁；回 true＝吃掉
    static func key(_ code: UInt16) -> Bool {
        guard active else { return false }
        switch code {
        case 36, 76: perform(.next); return true
        case 53: perform(.back); return true
        default: return false
        }
    }

    static func perform(_ a: Action, now: Double = CACurrentMediaTime()) {
        guard demo == nil || a == .next || a == .back else { return }   // 快照：只看不改
        switch a {
        case .next:
            if let n = after(page) { go(n, now: now, dir: 1) } else { finish() }
        case .back:
            if let b = before(page) { go(b, now: now, dir: -1) }
        case .skipAll:
            finish()
        case .language(let l):
            PetLanguage.chosen = l
            L10n.language = l ?? .fromSystem()
        case .look(let n):
            HPLook.select(n)
            Shell.homeLayer = nil
        case .permission(let p):
            request(p) { refreshPermissions(force: true) }
        }
    }

    /// 這一幀要不要重畫（換頁轉場、按下回饋、權限頁每秒重讀）
    static func tick(_ now: Double) -> Bool {
        guard active else { return false }
        var dirty = now - pageAt < transition + 0.05 || now - pressAt < 0.3
        if page == .permissions, refreshPermissions(now: now) { dirty = true }
        return dirty
    }

    // MARK: 權限

    /// 快照用的假狀態：各種狀態都看得到
    static let demoPerms: [SetupPermission: SetupPermState] = [.home: .granted, .contacts: .granted, .fullDisk: .notDetermined,
                                                                .screenRecording: .denied, .microphone: .notDetermined]

    /// 重讀（每秒一次，force 時馬上）；有變回 true
    @discardableResult
    static func refreshPermissions(now: Double = CACurrentMediaTime(), force: Bool = false) -> Bool {
        guard force || now - permsAt >= 1 else { return false }
        permsAt = now
        var next: [SetupPermission: SetupPermState] = [:]
        for p in SetupPermission.allCases { next[p] = demo != nil ? demoPerms[p]! : state(p) }
        guard next != perms else { return false }
        perms = next
        return true
    }

    static func state(_ p: SetupPermission) -> SetupPermState {
        switch p {
        case .home:
            guard HomeLink.helperInstalled else { return .unavailable }
            return HomeLink.shared.connected ? .granted : .notDetermined
        case .contacts:
            let s = CNContactStore.authorizationStatus(for: .contacts)
            if s == .authorized || s.rawValue == 4 { return .granted }   // 4＝只給部分聯絡人（新系統的 limited）
            return s == .notDetermined ? .notDetermined : .denied
        case .fullDisk:
            return fullDiskGranted() ? .granted : .notDetermined   // 系統不告訴我們「拒絕」：一律給「打開設置」
        case .screenRecording:
            if CGPreflightScreenCaptureAccess() { return .granted }
            return UserDefaults.standard.bool(forKey: askedScreenKey) ? .denied : .notDetermined
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        }
    }

    /// 只用 open(2) 試兩個受保護的檔（訊息資料庫、隱私權資料庫）：開得了就是有完整磁碟取用；不讀內容
    static func fullDiskGranted() -> Bool {
        for path in [MessagesAccess.defaultPath, NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"] {
            let fd = open(path, O_RDONLY)
            if fd >= 0 { close(fd); return true }
        }
        return false
    }

    static func settingsURL(_ p: SetupPermission) -> URL? {
        let pane: String
        switch p {
        case .home: pane = "Privacy_HomeKit"
        case .contacts: pane = "Privacy_Contacts"
        case .fullDisk: return MessagesAccess.fullDiskAccessURL
        case .screenRecording: pane = "Privacy_ScreenCapture"
        case .microphone: pane = "Privacy_Microphone"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }

    /// 按了才問：沒問過的跳系統框；問過被拒、或系統不給框的（完整磁碟取用）就打開系統設定那一頁
    static func request(_ p: SetupPermission, done: @escaping () -> Void) {
        let main: () -> Void = { DispatchQueue.main.async(execute: done) }
        let st = state(p)
        if st == .denied, let u = settingsURL(p) { NSWorkspace.shared.open(u); return }
        switch p {
        case .home:
            // 家庭的授權在小幫手那邊問（它是有 HomeKit 權利的 App）：打開它，連上就打勾
            let paths = [NSHomeDirectory() + "/Applications/HomePlay Home.app", "/Applications/HomePlay Home.app"]
            if let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration()) { _, _ in main() }
                HomeLink.shared.start()
            }
        case .contacts:
            guard Bundle.main.object(forInfoDictionaryKey: "NSContactsUsageDescription") != nil else { return }   // 沒有用途說明就問，系統會直接結束行程
            CNContactStore().requestAccess(for: .contacts) { _, _ in main() }
        case .fullDisk:
            NSWorkspace.shared.open(MessagesAccess.fullDiskAccessURL)
        case .screenRecording:
            UserDefaults.standard.set(true, forKey: askedScreenKey)
            if !CGRequestScreenCaptureAccess(), let u = settingsURL(p) { NSWorkspace.shared.open(u) }
            main()
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                // 舊系統的語音辨識要另外授權（macOS 26 起本機轉寫不需要）；有用途說明才問
                if ok, !speechAnalyzerAvailable, SFSpeechRecognizer.authorizationStatus() == .notDetermined,
                   Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil {
                    SFSpeechRecognizer.requestAuthorization { _ in main() }
                } else { main() }
            }
        }
    }

    static var speechAnalyzerAvailable: Bool {
        if #available(macOS 26.0, *) { return SpeechTranscriber.isAvailable }
        return false
    }

    // MARK: 連 iPhone 那一頁的狀態

    enum PhoneState: Equatable { case connected(String?), paired(String?), notPaired }

    /// 純函數：CarPlay 狀態＋配過的手機 → 要寫哪一句
    static func phoneState(status: CarPlayStatus, phones: [String], configPhone: String, currentName: String?) -> PhoneState {
        if [.live, .paused, .pausedResume, .background].contains(status) { return .connected(currentName) }
        if !phones.isEmpty || !configPhone.isEmpty { return .paired(currentName ?? phones.first) }
        return .notPaired
    }

    // MARK: selftest

    static func selftest(_ check: (Bool, String) -> Void) {
        let suite = "homeplay.selftest.setup"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }
        check(shouldAutoShow(defaults: d, configExists: false), "首次設定：全新（沒有任何偏好、沒有設定檔）才自動出現")   // l10n-ignore：selftest 訊息
        check(!shouldAutoShow(defaults: d, configExists: true), "首次設定：已經有 CarPlay 設定檔＝用過，不出現")   // l10n-ignore：selftest 訊息
        for k in [Onboarding.defaultsKey, PetLanguage.defaultsKey, HPLook.defaultsKey, SBStore.key] {
            d.set("x", forKey: k)
            let shown = shouldAutoShow(defaults: d, configExists: false)
            d.removeObject(forKey: k)
            check(!shown, "首次設定：升級上來的使用者（偏好有 \(k)）不會被強迫走")   // l10n-ignore：selftest 訊息
        }
        markDone(defaults: d)
        check(!shouldAutoShow(defaults: d, configExists: false), "首次設定：走完或略過一次，就不再自動出現")   // l10n-ignore：selftest 訊息
        // 頁序：歡迎 → 語言 → 權限 → CarPlay → 外觀 → 完成；歡迎沒有上一頁、完成不能往回
        var p = SetupPage.welcome, seen = [p]
        while let n = after(p) { p = n; seen.append(p) }
        check(seen == SetupPage.allCases && before(.welcome) == nil && before(.done) == nil && before(.look) == .carplay,
              "首次設定：頁序與上一頁")   // l10n-ignore：selftest 訊息
        check(phoneState(status: .live, phones: ["a"], configPhone: "", currentName: "P") == .connected("P")
              && phoneState(status: .notConnected, phones: [], configPhone: "AA:BB", currentName: nil) == .paired(nil)
              && phoneState(status: .notConnected, phones: [], configPhone: "", currentName: nil) == .notPaired,
              "首次設定：連 iPhone 那一頁的狀態（連上／配過／沒配過）")   // l10n-ignore：selftest 訊息
        // 快照只看不改：示範模式按語言、外觀都不動偏好
        let saved = (demo, active, page, L10n.language, UserDefaults.standard.object(forKey: PetLanguage.defaultsKey))
        demo = .language; active = true
        perform(.language(.en))
        let untouched = L10n.language == saved.3 && (UserDefaults.standard.object(forKey: PetLanguage.defaultsKey) as? String) == (saved.4 as? String)
        (demo, active, page) = (saved.0, saved.1, saved.2)
        check(untouched, "首次設定：快照（示範）按語言不改真的偏好")   // l10n-ignore：selftest 訊息
    }
}
