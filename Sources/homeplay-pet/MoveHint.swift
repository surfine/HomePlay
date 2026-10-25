import AppKit

// 搬位置的提示。拖機身＝轉身體（設計如此），但第一次用的人常以為拖機身就能搬走它：
// 在機身上一路拖到窗外、或拖得很遠，30 秒內兩次，就在桌寵旁邊浮一條系統玻璃小條
// 「按住 ⌘ 拖動（或拖底座）就能移動 HomePlay」。搬成功過一次、或已經提示過三次，就不再出。

/// 「其實想搬走它」的偵測（純邏輯，selftest 直接驅動）
struct MoveHintDetector {
    static let window = 30.0
    static let needed = 2
    private(set) var recent: [Double] = []

    /// 一次「轉身體」的拖動結束。leftWindow：放手時游標在窗外；travel：累計位移（點）；width：窗寬（點）
    mutating func rotateDragEnded(now: Double, leftWindow: Bool, travel: Double, width: Double) -> Bool {
        guard leftWindow || travel > width * 1.2 else { return false }
        recent = recent.filter { now - $0 < Self.window } + [now]
        guard recent.count >= Self.needed else { return false }
        recent.removeAll()
        return true
    }
}

enum MoveHint {
    static let shownKey = "HomePlayMoveHintCount"
    static let movedKey = "HomePlayMovedOnce"
    static let maxShows = 3

    static var shouldOffer: Bool {
        !UserDefaults.standard.bool(forKey: movedKey) && UserDefaults.standard.integer(forKey: shownKey) < maxShows
    }
    /// 用 ⌘、三指或底座搬成功過：已經會了，之後不再提示
    static func noteMoved() {
        if !UserDefaults.standard.bool(forKey: movedKey) { UserDefaults.standard.set(true, forKey: movedKey) }
    }
    static var text: String { L("moveHint.text", "按住 ⌘ 拖动（或拖底座）就能移动 HomePlay") }

    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    /// 在桌寵窗下方（放不下就上方）浮一條小條，4.5 秒後淡出；VoiceOver 會念出來；「減少動態效果」時不淡入淡出。
    static func show(near window: NSWindow) {
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: shownKey) + 1, forKey: shownKey)
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.preferredMaxLayoutWidth = 300
        let fit = label.fittingSize
        let size = NSSize(width: ceil(fit.width) + 32, height: ceil(fit.height) + 18)

        let p = panel ?? makePanel()
        panel = p
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        label.frame = NSRect(x: 16, y: 9, width: ceil(fit.width), height: ceil(fit.height))
        container.addSubview(label)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: container.frame)
            glass.cornerRadius = size.height / 2
            glass.contentView = container
            p.contentView = glass
        } else {
            let fx = NSVisualEffectView(frame: container.frame)
            fx.material = .hudWindow; fx.blendingMode = .behindWindow; fx.state = .active
            fx.wantsLayer = true; fx.layer?.cornerRadius = size.height / 2; fx.layer?.masksToBounds = true
            fx.addSubview(container)
            p.contentView = fx
        }

        let wf = window.frame
        let vf = window.screen?.visibleFrame ?? wf
        var origin = NSPoint(x: wf.midX - size.width / 2, y: wf.minY - size.height - 8)
        if origin.y < vf.minY { origin.y = wf.maxY + 8 }
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
        p.level = window.level == .normal ? .floating : window.level
        p.setFrame(NSRect(origin: origin, size: size), display: true)

        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        p.alphaValue = reduce ? 1 : 0
        p.orderFrontRegardless()
        if !reduce { NSAnimationContext.runAnimationGroup { $0.duration = 0.2; p.animator().alphaValue = 1 } }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        hideWork?.cancel()
        let work = DispatchWorkItem { hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: work)
    }

    static func hide() {
        hideWork?.cancel(); hideWork = nil
        guard let p = panel, p.isVisible else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { p.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        return p
    }
}
