import AppKit
import CoreGraphics

// 第一次打開的引導排隊：hello 寫完（首次設定走完）才出，收起後記下 HomePlayOnboarded。
// 2.0 起出的是開場手勢引導（Intro/IntroGuide.swift）——取代 1.x 那張四條手勢的操作提示卡（重按、右鍵、拖動轉身、搬位置都收進
// 「桌寵本身」那頁），不再兩個都播。設定 › 一般「重看…」與選單列「手勢引導」可以重看。

enum Onboarding {
    static let defaultsKey = "HomePlayOnboarded"
    static var armed = false          // 等 hello 写完再出
    static var active = false
    static var forced = false         // 快照用（--onboarding、--demo-intro）：不读也不写偏好
    /// 用户收起引导后（不是快照）：AppDelegate 接着说明「输入监控」（F5 叫 Siri 要用）
    static var onDismiss: (() -> Void)?
    static var done: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
    /// hello 停著當背景的條件：引導排著或開著，或首次設定（Setup/SetupFlow.swift）排著或開著
    static var holding: Bool { armed || active || SetupFlow.pending || SetupFlow.active }

    /// 收起（走完、略過、進 CarPlay）：記下看過，接著原本的第一次流程
    static func close() {
        guard active || armed else { return }
        if active { IntroGuide.closedAt = CACurrentMediaTime() }
        active = false; armed = false
        IntroGuide.hits = []; IntroGuide.texts = []
        if !forced {
            UserDefaults.standard.set(true, forKey: defaultsKey)
            IntroGuide.markSeen()
            onDismiss?()
        }
    }
}

extension Face {
    var onboardingActive: Bool { Onboarding.active || SetupFlow.active }   // 首次設定、手勢引導開著時，外殼、翻頁、長按都不收

    /// 排队：hello 写完（或根本没有 hello）就出现
    func armOnboarding() { Onboarding.armed = true; forceDirty = true }

    func dismissOnboarding() {
        guard Onboarding.active || Onboarding.armed else { return }
        Onboarding.close()
        forceDirty = true
    }

    /// 每帧：到点出现；引导开着时示范动画一直在动；有变化回 true
    func tickOnboarding(_ now: Double) -> Bool {
        // 首次設定排在引導前面：hello 寫完先走設定，走完引導才出來（armed 一直留著）
        if SetupFlow.pending, !sayingHello || helloReadyForSetup { SetupFlow.start(now: now); return true }
        if SetupFlow.active || SetupFlow.pending { return SetupFlow.tick(now) }
        if Onboarding.armed, !sayingHello || helloReadyForSetup {   // 2.0 hello：第一次打開時 hello 停住當背景，引導蓋在上面
            Onboarding.armed = false; Onboarding.active = true
            IntroGuide.begin(now: now)
            log("intro: gesture guide shown")
            return true
        }
        if Onboarding.active { return true }
        if now - IntroGuide.closedAt < IntroGuide.fadeOut + 0.05 { return true }   // 收起的淡出
        return tickIntroHint(now)   // 升級上來的使用者：主畫面的小提示卡
    }

    /// 手勢引導（Intro/IntroScreen.swift）與升級提示卡
    func drawOnboarding(_ g: CGContext, _ now: Double) {
        drawIntroHint(g, now)
        drawIntroGuide(g, now)
    }
}
