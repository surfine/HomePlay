import AppKit

// 2.0 P06（HIG Live Activities：Mac 上的 Live Activity 在選單列）：
// 計時器（單次、番茄鐘、計時器 App 鏡射進來的）進行中時，選單列圖示旁顯示倒數 mm:ss；沒有計時就只剩圖示。

enum MenuBarClock {
    /// 04:32、00:09、1:02:03（一小時以上才帶小時；無條件進位，最後一秒顯示 00:01）
    static func text(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.up))), h = s / 3600, m = (s % 3600) / 60, r = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%02d:%02d", m, r)
    }
}

final class MenuBarTimer {
    private weak var item: NSStatusItem?
    private let remaining: () -> Double?
    private var ticker: Timer?
    /// 沒有計時時放慢到 5 秒（只剩「有沒有新計時」一件事要看），有倒數才回 0.5 秒走字
    private var fast = true

    /// remaining：還剩幾秒；沒有計時回 nil
    init(item: NSStatusItem, remaining: @escaping () -> Double?) {
        self.item = item
        self.remaining = remaining
        // common 模式：選單開著、拖動視窗時也照樣走字
        arm()
        tick()
    }
    deinit { ticker?.invalidate() }

    private func arm() {
        ticker?.invalidate()
        let t = Timer(timeInterval: fast ? 0.5 : 5, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = fast ? 0.1 : 2
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    func tick() {
        guard let item, let b = item.button else { return }
        if let left = remaining(), left > 0 {
            let title = " " + MenuBarClock.text(left)
            if b.title != title {
                b.title = title
                b.setAccessibilityLabel(String(format: L("menubar.timer.a11y", "HomePlay，计时器剩 %@"), MenuBarClock.text(left)))
            }
            if b.imagePosition != .imageLeft {
                b.imagePosition = .imageLeft
                b.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .medium)
                item.length = NSStatusItem.variableLength
            }
            if !fast { fast = true; arm() }
        } else {
            if !b.title.isEmpty {
                b.title = ""
                b.imagePosition = .imageOnly
                b.setAccessibilityLabel(nil)
                item.length = NSStatusItem.squareLength
            }
            if fast { fast = false; arm() }
        }
    }
}
