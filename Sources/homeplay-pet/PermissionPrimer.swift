import AppKit
import AVFoundation
import CoreGraphics
import CoreText
import EventKit

// 权限：先在桌宠屏幕上说清楚「要什么、为什么、只在本机」，用户点「继续」才弹系统框；
// 系统框之后给回馈——允许就笑眼打勾、功能立刻开始；拒绝就担心脸，卡片给「打开系统设置」。
// （2026-10-22 Aaron 定案：动画放在桌宠屏幕上的卡片＋表情，不用原生弹窗。）

enum PermissionKind: String, CaseIterable {
    case camera, microphone, inputMonitoring, automation, calendar, location

    /// 系统设置 › 隐私与安全性 里对应的那一页
    var settingsURL: URL? {
        let pane: String
        switch self {
        case .camera: pane = "Privacy_Camera"
        case .microphone: pane = "Privacy_Microphone"
        case .inputMonitoring: pane = "Privacy_ListenEvent"
        case .automation: pane = "Privacy_Automation"
        case .calendar: pane = "Privacy_Calendars"
        case .location: pane = "Privacy_LocationServices"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }

    var title: String {
        switch self {
        case .camera: return L("perm.camera.title", "让我看见你")
        case .microphone: return L("perm.mic.title", "让 Siri 听见你")
        case .inputMonitoring: return L("perm.input.title", "让 F5 叫出 Siri")
        case .automation: return L("perm.automation.title", "显示 Mac 正在播放")
        case .calendar: return L("perm.calendar.title", "显示下一个行程")
        case .location: return L("perm.location.title", "读取 Wi-Fi 名称")
        }
    }
    var body: String {
        switch self {
        case .camera: return L("perm.camera.body", "转头看你、配合房间光线\n不录制、不上传")
        case .microphone: return L("perm.mic.body", "按住 F5 跟 Siri 说话\n声音只送到你的 iPhone")
        case .inputMonitoring: return L("perm.input.body", "任何 App 里按 F5 叫 Siri\n只认这一个键")
        case .automation: return L("perm.automation.body", "显示正在播放的歌\n点一下播放或暂停")
        case .calendar: return L("perm.calendar.body", "显示你的下一个行程\n只读取，不离开这台 Mac")
        case .location: return L("perm.location.body", "iPhone 要知道连哪个 Wi-Fi 才能无线连 CarPlay\nmacOS 只给有定位权限的 App 看网络名称")
        }
    }
    var grantedLine: String {
        switch self {
        case .camera: return L("perm.camera.granted", "开始跟着你了")
        case .microphone: return L("perm.mic.granted", "按住 F5 就能说话")
        case .inputMonitoring: return L("perm.input.granted", "F5 已经可以叫 Siri")
        case .automation: return L("perm.automation.granted", "正在播放会显示在胶囊上")
        case .calendar: return L("perm.calendar.granted", "下一个行程已就位")
        case .location: return L("perm.location.granted", "Wi-Fi 名称已交给 iPhone")
        }
    }
}

enum PermissionStatus { case notDetermined, granted, denied }

/// 查询／申请／打开设置：全部集中在这里，调用方不再各自弹 NSAlert。
enum PermissionCenter {
    static let askedInputKey = "HomePlayAskedInputMonitoring"

    static func status(_ k: PermissionKind) -> PermissionStatus {
        switch k {
        case .camera, .microphone:
            switch AVCaptureDevice.authorizationStatus(for: k == .camera ? .video : .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .inputMonitoring:
            if CGPreflightListenEventAccess() { return .granted }
            return UserDefaults.standard.bool(forKey: askedInputKey) ? .denied : .notDetermined
        case .automation:
            switch automationCheck(ask: false) {
            case noErr: return .granted
            case OSStatus(errAEEventNotPermitted): return .denied
            default: return .notDetermined   // 还没问过，或「音乐」没在跑（问不了）
            }
        case .calendar:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess, .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .location:
            switch WiFiName.auth {
            case .granted: return .granted
            case .notDetermined: return .notDetermined
            case .denied: return .denied
            }
        }
    }

    /// 弹系统框；结果回主线程。
    static func request(_ k: PermissionKind, completion: @escaping (Bool) -> Void) {
        let done: (Bool) -> Void = { ok in DispatchQueue.main.async { completion(ok) } }
        switch k {
        case .camera, .microphone:
            AVCaptureDevice.requestAccess(for: k == .camera ? .video : .audio, completionHandler: done)
        case .inputMonitoring:
            UserDefaults.standard.set(true, forKey: askedInputKey)
            if CGRequestListenEventAccess() { done(true); return }
            // 系统把 App 加进「输入监控」列表并弹框；用户勾上后 preflight 才变真：轮询 30 秒
            var tries = 0
            func poll() {
                tries += 1
                if CGPreflightListenEventAccess() { done(true); return }
                guard tries < 30 else { done(false); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: poll)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: poll)
        case .automation:
            DispatchQueue.global(qos: .userInitiated).async {
                let st = automationCheck(ask: true)
                // 「音乐」没在跑时问不了：先放行，第一次真正读取时系统自己会问
                done(st == noErr || st == OSStatus(procNotFound))
            }
        case .calendar:
            EKEventStore().requestFullAccessToEvents { ok, _ in done(ok) }
        case .location:
            WiFiName.request(done)
        }
    }

    static func openSettings(_ k: PermissionKind) {
        if let url = k.settingsURL { NSWorkspace.shared.open(url) }
    }

    /// 对「音乐」的 Apple Events 授权（AEDeterminePermissionToAutomateTarget 会阻塞，别在主线程问）
    private static func automationCheck(ask: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Music")
        guard let desc = target.aeDesc else { return OSStatus(procNotFound) }
        return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask)
    }
}

/// 屏幕卡片的状态机。时间、点击都由 PetView 喂进来。
enum PermissionPrimer {
    enum Phase: Equatable { case intro, waiting, granted, denied }
    enum Button { case primary, secondary }

    static var kind: PermissionKind?
    static var phase: Phase = .intro
    static var alpha: CGFloat = 0
    static var phaseAt: Double = 0
    static var lastDraw: Double = -1e9
    static var forced = false                       // 快照用（--permission）
    /// 最近一次画出来的按钮（1024 坐标，y 向下），点击用
    static var buttons: [(Button, CGRect)] = []
    /// 阶段变化时通知 PetView（换表情）
    static var onPhase: ((Phase) -> Void)?
    private static var completion: ((Bool) -> Void)?

    static var visible: Bool { kind != nil && alpha > 0.01 }
    static var active: Bool { kind != nil }

    /// 出卡片。已允许直接回调 true；被拒先出拒绝卡；没问过出说明卡。
    static func present(_ k: PermissionKind, completion: @escaping (Bool) -> Void) {
        let st = PermissionCenter.status(k)
        if st == .granted { completion(true); return }
        // 同时只有一张：新的请求让旧的那张按「以后」结束
        if kind != nil { finish(false) }
        kind = k
        self.completion = completion
        set(st == .denied ? .denied : .intro)
    }

    static func set(_ p: Phase) {
        phase = p
        phaseAt = CACurrentMediaTime()
        onPhase?(p)
    }

    /// 按下的那颗按钮（按下就有回馈，放开还在按钮上才算数；拖出去放开＝取消）
    static var pressed: Button?
    static var lastPressed: Button?   // 刚放开的那颗：只有它弹回
    static var tracking = false       // 这次按下归卡片（放开也归卡片，不漏给桌宠）
    static var pressAt: Double = 0
    private static func hit(_ x: CGFloat, _ y: CGFloat) -> Button? {
        buttons.first { $0.1.insetBy(dx: -12, dy: -12).contains(CGPoint(x: x, y: y)) }?.0
    }

    /// 按下（1024 坐标）。返回 true＝卡片吃掉这次点击（卡片在时，屏幕上的点击都归卡片）。
    @discardableResult
    static func press(x: CGFloat, y: CGFloat) -> Bool {
        guard kind != nil else { return false }
        tracking = true
        pressed = hit(x, y)
        pressAt = CACurrentMediaTime()
        return true
    }

    /// 放开：x、y 为 nil 表示指标不在屏幕上（当作取消）
    static func release(x: CGFloat?, y: CGFloat?) {
        tracking = false
        let b = pressed
        lastPressed = b
        pressed = nil
        pressAt = CACurrentMediaTime()
        if phase == .granted { click(nil); return }
        guard let b, let x, let y, hit(x, y) == b else { return }
        click(b)
    }

    private static func click(_ hit: Button?) {
        guard let k = kind else { return }
        switch (phase, hit) {
        case (.intro, .primary?):
            set(.waiting)
            NSApp.activate(ignoringOtherApps: true)
            PermissionCenter.request(k) { ok in
                guard kind == k else { return }
                if ok { set(.granted); completeSoon(true) } else { set(.denied); completion?(false); completion = nil }
            }
        case (.intro, .secondary?), (.denied, .secondary?):
            finish(false)
        case (.denied, .primary?):
            PermissionCenter.openSettings(k)
            finish(false)
        case (.granted, _):
            finish(true)
        default:
            break
        }
    }

    /// 关掉卡片：Esc、新卡片顶替、或桌宠被隐藏时
    static func dismiss() { if kind != nil { finish(false) } }

    private static func completeSoon(_ ok: Bool) {
        let token = phaseAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard phase == .granted, phaseAt == token else { return }
            finish(ok)
        }
    }

    private static func finish(_ ok: Bool) {
        let c = completion
        completion = nil
        kind = nil
        buttons = []
        c?(ok)
    }

    /// 进场 0.32 秒、退场 0.18 秒（退场要比进场快）；画的时候再套缓出曲线
    static func nextAlpha(_ a: CGFloat, target: CGFloat, dt: Double) -> CGFloat {
        target > a ? min(target, a + CGFloat(dt / 0.32)) : max(target, a - CGFloat(dt / 0.18))
    }
    static var entering = true
    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - min(1, max(0, x)), 3) }
}

extension Face {
    /// 卡片可见时约 30fps 重画（图示在动）；返回要不要重画
    func tickPermissionPrimer(_ now: Double, _ dt: Double) -> Bool {
        let target: CGFloat = PermissionPrimer.active ? 1 : 0
        let a = PermissionPrimer.alpha
        if PermissionPrimer.forced && a == 0 { PermissionPrimer.alpha = 1; return true }
        let na = PermissionPrimer.nextAlpha(a, target: target, dt: dt)
        if na != a { PermissionPrimer.entering = na > a }
        PermissionPrimer.alpha = na
        if na == 0 { return a != 0 }
        let pressing = now - PermissionPrimer.pressAt < 0.2   // 按钮按下／弹回的那一下要 60fps
        return na != a || pressing || now - PermissionPrimer.lastDraw >= 1.0 / 30
    }

    func drawPermissionPrimer(_ g: CGContext, _ now: Double) {
        let a = PermissionPrimer.alpha
        guard a > 0.003, let k = PermissionPrimer.kind ?? (PermissionPrimer.forced ? .camera : nil) else { return }
        PermissionPrimer.lastDraw = now
        let phase = PermissionPrimer.phase
        let t = now - PermissionPrimer.phaseAt
        // 进场：缓出，从下面 28 pt、0.96 倍浮上来；退场：只淡出、微缩到 0.98，不往回走
        let e = CGFloat(PermissionPrimer.easeOut(Double(a)))
        let opacity = PermissionPrimer.entering ? e : a
        g.saveGState(); g.setAlpha(opacity)
        g.setFillColor(NSColor.black.withAlphaComponent(0.42).cgColor)
        g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let rise = PermissionPrimer.entering ? (1 - e) * 28 : 0
        let s = PermissionPrimer.entering ? 0.96 + 0.04 * e : 0.98 + 0.02 * a
        g.translateBy(x: 512, y: 512 + rise); g.scaleBy(x: s, y: s); g.translateBy(x: -512, y: -512)
        // 桌宠默认 220 pt 宽，屏幕只占约 150 pt：1024 坐标里的 46 号字才 ≈ 7 pt。字要大、话要短。
        let card = CGRect(x: 56, y: 150, width: 912, height: 724)
        glass(g, card, radius: Screen.concentric(inset: card.minX), tint: NSColor(white: 1, alpha: 0.18), band: 14)   // 與螢幕同心
        // 换阶段（说明 → 等待 → 好了）：内容交叉淡入并往上 10 pt，卡片本身不动
        let c = CGFloat(PermissionPrimer.easeOut(t / 0.22))
        g.setAlpha(opacity * c)
        g.translateBy(x: 0, y: (1 - c) * 10)

        // 图示：每种权限一段小动画；允许后换成打勾，拒绝后图示加一道斜线
        let icon = CGRect(x: 512 - 76, y: card.minY + 52, width: 152, height: 152)
        g.setFillColor(NSColor(white: 1, alpha: 0.16).cgColor)
        g.addPath(continuousRoundedRect(icon, radius: icon.width * 0.2237)); g.fillPath()
        if phase == .granted {
            drawCheck(g, in: icon, progress: CGFloat(PermissionPrimer.easeOut(t / 0.42)))
        } else {
            drawPermissionGlyph(g, k, in: icon, now: now, calm: phase == .denied)
            if phase == .denied { drawSlash(g, in: icon) }
        }

        // 文案
        let title: String, body: String
        switch phase {
        case .intro: title = k.title; body = k.body
        case .waiting where k == .inputMonitoring:   // 輸入監控沒有「允許」框：要去系統設定打開開關
            title = L("perm.waiting.settingsTitle", "在系统设置里打开开关")
            body = L("perm.waiting.body", "随时可以在系统设置里改")
        case .waiting: title = L("perm.waiting.title", "点系统框里的「允许」")
            body = L("perm.waiting.body", "随时可以在系统设置里改")
        case .granted: title = L("perm.granted.title", "好了！"); body = k.grantedLine
        case .denied: title = L("perm.denied.title", "需要在系统设置里打开")
            body = L("perm.denied.body", "在「隐私与安全性」里打开\n回来就能用")
        }
        let textWidth = card.width - 96
        // 標題一律 68 pt：放不下就折兩行（不縮字，每張卡看起來同一個層級）；內文同一個字級
        let tf = Self.rounded(68, weight: .bold)
        let titleLines = Self.wrap(title, tf, textWidth, maxLines: 2)
        for (i, l) in titleLines.enumerated() { drawCentered(g, l, font: tf, y: icon.maxY + 100 + CGFloat(i) * 78, color: .white) }
        let bodyTop = icon.maxY + 174 + CGFloat(titleLines.count - 1) * 78
        let bodyLines = body.split(separator: "\n").map(String.init)
        let bs = bodyLines.map { Self.fitted($0, size: 46, weight: .medium, maxWidth: textWidth).pointSize }.min() ?? 46
        for (i, s) in bodyLines.enumerated() {
            drawCentered(g, s, font: Self.rounded(bs, weight: .medium), y: bodyTop + CGFloat(i) * 60, color: NSColor.white.withAlphaComponent(0.85))
        }

        // 按钮：左「以后」，右主按钮（白底深字）
        var buttons: [(PermissionPrimer.Button, CGRect)] = []
        let by = card.maxY - 52 - 116
        switch phase {
        case .intro, .denied:
            let primary = phase == .intro ? L("perm.continue", "继续") : L("perm.openSettings", "打开系统设置")
            let left = CGRect(x: card.minX + 52, y: by, width: 388, height: 116)
            let right = CGRect(x: card.maxX - 52 - 388, y: by, width: 388, height: 116)
            let later = L("perm.later", "以后再说")
            let ps = [later, primary].map { Self.fitted($0, size: 46, weight: .semibold, maxWidth: 388 - 48).pointSize }.min() ?? 46   // 兩顆按鈕同字級
            pill(g, left, fill: NSColor(white: 1, alpha: 0.16), text: later, color: .white, button: .secondary, size: ps)
            pill(g, right, fill: .white, text: primary, color: srgb(0x111418), button: .primary, size: ps)
            buttons = [(.secondary, left), (.primary, right)]
        case .waiting:
            // 三个点像波一样依次亮起（连续的，不是一格一格跳）：在等你回答系统框
            for i in 0..<3 {
                let w = max(0, sin((now * 0.9 - Double(i) * 0.18) * 2 * .pi))
                let lift = CGFloat(w * w) * 6
                g.setFillColor(NSColor.white.withAlphaComponent(0.3 + 0.65 * CGFloat(w * w)).cgColor)
                g.fillEllipse(in: CGRect(x: 512 - 76 + CGFloat(i) * 58, y: by + 40 - lift, width: 36, height: 36))
            }
        case .granted:
            break
        }
        PermissionPrimer.buttons = buttons
        g.restoreGState()
    }

    private func pill(_ g: CGContext, _ r: CGRect, fill: NSColor, text: String, color: NSColor, button: PermissionPrimer.Button, size: CGFloat = 46) {
        // 按下：缩到 0.96、稍暗（100 ms 缓出）；放开的那颗弹回
        let since = CACurrentMediaTime() - PermissionPrimer.pressAt
        let k = CGFloat(PermissionPrimer.easeOut(since / 0.1))
        let depth: CGFloat = PermissionPrimer.pressed == button ? k
            : (PermissionPrimer.pressed == nil && PermissionPrimer.lastPressed == button && since < 0.1 ? 1 - k : 0)
        let wasPressed = depth > 0.001
        g.saveGState()
        if wasPressed {
            let sc = 1 - 0.04 * depth
            g.translateBy(x: r.midX, y: r.midY); g.scaleBy(x: sc, y: sc); g.translateBy(x: -r.midX, y: -r.midY)
        }
        defer { g.restoreGState() }
        g.setFillColor((wasPressed ? fill.blended(withFraction: 0.12 * depth, of: .black) ?? fill : fill).cgColor)
        g.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)); g.fillPath()
        // 字要在按钮里置中（drawCentered 只会以整块屏幕的中线置中）
        let font = Self.rounded(size, weight: .semibold)
        let attr = NSAttributedString(string: text, attributes: Typo.attributes(font, color: color))
        let line = CTLineCreateWithAttributedString(attr)
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        g.saveGState()
        g.translateBy(x: r.midX - w / 2, y: r.midY + font.capHeight / 2); g.scaleBy(x: 1, y: -1)
        g.textPosition = .zero; CTLineDraw(line, g)
        g.restoreGState()
    }

    private func drawCheck(_ g: CGContext, in r: CGRect, progress p: Double) {
        let pts = [CGPoint(x: r.minX + 42, y: r.midY + 4), CGPoint(x: r.minX + 68, y: r.midY + 30), CGPoint(x: r.maxX - 38, y: r.midY - 28)]
        let l1 = hypot(pts[1].x - pts[0].x, pts[1].y - pts[0].y), l2 = hypot(pts[2].x - pts[1].x, pts[2].y - pts[1].y)
        let len = CGFloat(p) * (l1 + l2)
        g.setStrokeColor(NSColor.white.cgColor); g.setLineWidth(12); g.setLineCap(.round); g.setLineJoin(.round)
        g.move(to: pts[0])
        if len <= l1 {
            g.addLine(to: CGPoint(x: pts[0].x + (pts[1].x - pts[0].x) * len / l1, y: pts[0].y + (pts[1].y - pts[0].y) * len / l1))
        } else {
            let f = (len - l1) / l2
            g.addLine(to: pts[1]); g.addLine(to: CGPoint(x: pts[1].x + (pts[2].x - pts[1].x) * f, y: pts[1].y + (pts[2].y - pts[1].y) * f))
        }
        g.strokePath()
    }

    private func drawSlash(_ g: CGContext, in r: CGRect) {
        g.setStrokeColor(srgb(0xff6b5e).cgColor); g.setLineWidth(10); g.setLineCap(.round)
        g.move(to: CGPoint(x: r.minX + 30, y: r.minY + 30)); g.addLine(to: CGPoint(x: r.maxX - 30, y: r.maxY - 30)); g.strokePath()
    }

    /// 每种权限的小动画（白色线稿，156 pt 方格）
    private func drawPermissionGlyph(_ g: CGContext, _ k: PermissionKind, in r: CGRect, now: Double, calm: Bool) {
        let c = CGPoint(x: r.midX, y: r.midY)
        let phase = calm ? 0 : now
        g.saveGState()
        g.setStrokeColor(NSColor.white.cgColor); g.setFillColor(NSColor.white.cgColor)
        g.setLineWidth(7); g.setLineCap(.round); g.setLineJoin(.round)
        switch k {
        case .camera:
            // 机身＋镜头：光圈一呼一吸，右上角绿色指示灯（系统的摄像头指示）闪一下
            g.addPath(CGPath(roundedRect: CGRect(x: c.x - 54, y: c.y - 36, width: 108, height: 72), cornerWidth: 16, cornerHeight: 16, transform: nil))
            g.strokePath()
            let iris = 16 + 6 * CGFloat(sin(phase * 2.4))
            g.strokeEllipse(in: CGRect(x: c.x - 22, y: c.y - 22, width: 44, height: 44))
            g.fillEllipse(in: CGRect(x: c.x - iris / 2, y: c.y - iris / 2, width: iris, height: iris))
            if Int(phase * 1.5) % 2 == 0 {
                g.setFillColor(srgb(0x34c759).cgColor)
                g.fillEllipse(in: CGRect(x: c.x + 36, y: c.y - 30, width: 10, height: 10))
            }
        case .microphone:
            // 麦克风＋向外扩散的三道声波
            g.addPath(CGPath(roundedRect: CGRect(x: c.x - 15, y: c.y - 46, width: 30, height: 58), cornerWidth: 15, cornerHeight: 15, transform: nil))
            g.strokePath()
            g.addArc(center: CGPoint(x: c.x, y: c.y - 6), radius: 30, startAngle: 0, endAngle: .pi, clockwise: false); g.strokePath()
            g.move(to: CGPoint(x: c.x, y: c.y + 24)); g.addLine(to: CGPoint(x: c.x, y: c.y + 44)); g.strokePath()
            for i in 0..<3 {
                let p = CGFloat((phase * 0.9 + Double(i) / 3).truncatingRemainder(dividingBy: 1))
                g.setStrokeColor(NSColor.white.withAlphaComponent(calm ? 0.35 : (1 - p) * 0.9).cgColor)
                g.setLineWidth(5)
                g.addArc(center: CGPoint(x: c.x, y: c.y - 16), radius: 48 + p * 22, startAngle: -.pi / 4, endAngle: .pi / 4, clockwise: false); g.strokePath()
                g.addArc(center: CGPoint(x: c.x, y: c.y - 16), radius: 48 + p * 22, startAngle: .pi * 3 / 4, endAngle: .pi * 5 / 4, clockwise: false); g.strokePath()
            }
        case .inputMonitoring:
            // F5 键帽：一按一放
            let down = calm ? 0 : max(0, CGFloat(sin(phase * 3.2))) * 8
            let key = CGRect(x: c.x - 46, y: c.y - 40 + down, width: 92, height: 80)
            g.addPath(CGPath(roundedRect: key, cornerWidth: 16, cornerHeight: 16, transform: nil)); g.strokePath()
            drawCentered(g, "F5", font: Self.rounded(36, weight: .bold), kern: 0, y: key.midY + 13, color: .white)
        case .automation:
            // 音符跳一跳
            let hop = calm ? 0 : abs(CGFloat(sin(phase * 3))) * 12
            let y0 = c.y - hop
            g.fillEllipse(in: CGRect(x: c.x - 40, y: y0 + 18, width: 30, height: 24))
            g.fillEllipse(in: CGRect(x: c.x + 10, y: y0 + 8, width: 30, height: 24))
            g.setLineWidth(6)
            g.move(to: CGPoint(x: c.x - 12, y: y0 + 30)); g.addLine(to: CGPoint(x: c.x - 12, y: y0 - 38))
            g.addLine(to: CGPoint(x: c.x + 38, y: y0 - 48)); g.addLine(to: CGPoint(x: c.x + 38, y: y0 + 20)); g.strokePath()
        case .calendar:
            // 日历页：顶部两个环，日期格依次点亮
            let page = CGRect(x: c.x - 50, y: c.y - 40, width: 100, height: 90)
            g.addPath(CGPath(roundedRect: page, cornerWidth: 14, cornerHeight: 14, transform: nil)); g.strokePath()
            g.move(to: CGPoint(x: page.minX, y: page.minY + 24)); g.addLine(to: CGPoint(x: page.maxX, y: page.minY + 24)); g.strokePath()
            for x in [page.minX + 28, page.maxX - 28] {
                g.move(to: CGPoint(x: x, y: page.minY - 10)); g.addLine(to: CGPoint(x: x, y: page.minY + 8)); g.strokePath()
            }
            let lit = calm ? -1 : Int(phase * 2.5) % 6
            for i in 0..<6 {
                let cell = CGRect(x: page.minX + 14 + CGFloat(i % 3) * 26, y: page.minY + 36 + CGFloat(i / 3) * 24, width: 16, height: 14)
                g.setFillColor(NSColor.white.withAlphaComponent(i == lit ? 1 : 0.35).cgColor)
                g.fill(cell)
            }
        case .location:
            // Wi-Fi 扇形：底下一點，三道弧由內往外依次點亮（要的是網路名稱，不是地圖）
            let base = CGPoint(x: c.x, y: c.y + 40)
            g.fillEllipse(in: CGRect(x: base.x - 9, y: base.y - 9, width: 18, height: 18))
            let lit = calm ? 3 : Int(phase * 2.5) % 4
            for i in 0..<3 {
                g.setStrokeColor(NSColor.white.withAlphaComponent(i < lit ? 1 : 0.35).cgColor)
                g.addArc(center: base, radius: CGFloat(30 + i * 24), startAngle: -.pi * 0.75, endAngle: -.pi * 0.25, clockwise: false)
                g.strokePath()
            }
        }
        g.restoreGState()
    }
}
