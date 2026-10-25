import AppKit
import Foundation

// 桌宠屏幕上和「谁在看」有关的两样东西（画在 1024 画布上，左上原点）：
// 1. 录脸引导：「看着屏幕，慢慢转头」＋进度圈＋画质提示＋取消钮（按钮 ≥88 px）；
// 2. 个人问候：认出人后短暂出现的一张玻璃卡「早安，名字」＋头像（Personal.dc.html 左边的设备稿）。
// 玻璃只用在这两张控件层的卡上（glass(...)），圆角跟屏幕同心（Screen.concentric）。
// 快照：--people-demo 画问候；--people-demo-enroll 画录脸引导（可再加 --people-demo-progress 0…1）。

enum PeopleOverlay {
    struct Enroll {
        var person: Person
        var phase: FaceEnrollmentFlow.Phase = .framing(hint: nil)
        var progress = 0.0
        var asksToTurn = false
        var endedAt: Double?
        var firstTime = false   // 2.0 hello：这个人第一次录脸（录好就写一次 hello）
    }

    nonisolated(unsafe) static var enroll: Enroll?
    nonisolated(unsafe) static var greeting: (person: Person, since: Double)?
    nonisolated(unsafe) static var demoGreeting = false
    nonisolated(unsafe) static var demoEnroll = false
    nonisolated(unsafe) static var demoProgress = 0.5
    /// 最近一次画出来的取消钮（1024 坐标，y 向下），点击用
    nonisolated(unsafe) static var cancelRect: CGRect = .zero
    /// 最近一次画出来的文案（VoiceOver 用；who 只有录的时候有）
    nonisolated(unsafe) static var enrollText: (title: String, sub: String, who: String, rect: CGRect)?
    nonisolated(unsafe) static var lastDraw = -1e9
    nonisolated(unsafe) static var wasVisible = false
    nonisolated(unsafe) static var cancelPressedAt = -1e9

    static let greetingDuration = 4.0
    static let terminalHold = 2.0

    static var visible: Bool { enroll != nil || greetingActive(CACurrentMediaTime()) || demoGreeting || demoEnroll }

    static func greetingActive(_ now: Double) -> Bool {
        guard let g = greeting else { return false }
        return now - g.since < greetingDuration
    }

    static func greet(_ person: Person) {
        guard enroll == nil else { return }
        greeting = (person, CACurrentMediaTime())
    }

    // MARK: 录脸状态（WhoIsLooking 在主线程调）

    static func beginEnrollment(_ person: Person?) {
        guard let person else { return }
        greeting = nil
        enroll = Enroll(person: person)
        enroll?.firstTime = PeopleRegistry.shared.faceDataState(person.id) != .enrolled   // 2.0 hello
    }

    static func updateEnrollment(phase: FaceEnrollmentFlow.Phase, progress: Double, asksToTurn: Bool) {
        guard enroll != nil else { return }
        enroll?.phase = phase; enroll?.progress = progress; enroll?.asksToTurn = asksToTurn
    }

    static func finishEnrollment(_ phase: FaceEnrollmentFlow.Phase) {
        guard enroll != nil else { return }
        if case .ended(.cancelled) = phase { enroll = nil; return }   // 自己取消的：直接收起
        enroll?.phase = phase
        enroll?.endedAt = CACurrentMediaTime()
        if case .saved = phase { enroll?.progress = 1 }
    }

    /// 取消钮：返回这次点击是不是归录脸卡。
    @discardableResult
    static func press(x: CGFloat, y: CGFloat) -> Bool {
        guard let e = enroll else { return false }
        if e.endedAt == nil, cancelRect.insetBy(dx: -12, dy: -12).contains(CGPoint(x: x, y: y)) {
            cancelPressedAt = CACurrentMediaTime()
            WhoIsLooking.shared.cancelEnrollment()
        }
        return true   // 录脸卡在屏幕上时，屏幕上的点击都归卡片
    }
    static var capturesClicks: Bool { enroll != nil }
}

extension Face {
    /// 可见时约 30fps 重画；返回要不要重画（刚收起来那一下也要画一次，把残影擦掉）
    func tickPeopleOverlay(_ now: Double, _ dt: Double) -> Bool {
        if let e = PeopleOverlay.enroll, let t = e.endedAt, now - t >= PeopleOverlay.terminalHold {
            PeopleOverlay.enroll = nil
            if case .saved = e.phase, e.firstTime { beginHello(now) }   // 2.0 hello：新的人录好脸，跟他说 hello
        }
        let visible = PeopleOverlay.visible
        defer { PeopleOverlay.wasVisible = visible }
        guard visible else { return PeopleOverlay.wasVisible }
        return now - PeopleOverlay.lastDraw >= 1.0 / 30
    }

    func drawPeopleOverlay(_ g: CGContext, _ now: Double) {
        let demoPerson = Person(id: "demo", name: PeopleRegistry.systemOwnerName(), colorIndex: 0, isOwner: true)
        if let e = PeopleOverlay.enroll {
            PeopleOverlay.lastDraw = now
            drawEnrollCard(g, e, now)
        } else if PeopleOverlay.demoEnroll {
            PeopleOverlay.lastDraw = now
            var e = PeopleOverlay.Enroll(person: demoPerson)
            e.phase = .collecting(front: 4, sideA: 1, sideB: 0)
            e.progress = PeopleOverlay.demoProgress
            e.asksToTurn = true
            drawEnrollCard(g, e, now)
        } else if PeopleOverlay.demoGreeting {
            PeopleOverlay.lastDraw = now
            drawGreetingCard(g, demoPerson, alpha: 1)
        } else if let gr = PeopleOverlay.greeting, PeopleOverlay.greetingActive(now) {
            PeopleOverlay.lastDraw = now
            let t = now - gr.since
            let a = min(1, t / 0.3) * min(1, (PeopleOverlay.greetingDuration - t) / 0.5)
            drawGreetingCard(g, gr.person, alpha: CGFloat(max(0, a)))
        }
    }

    // MARK: 个人问候

    private func drawGreetingCard(_ g: CGContext, _ person: Person, alpha: CGFloat) {
        let hour = hourNow
        let fmt = hour >= 5 && hour < 11 ? L("people.greet.morning", "早安，%@")
            : hour >= 11 && hour < 18 ? L("people.greet.afternoon", "午安，%@") : L("people.greet.evening", "晚安，%@")
        let title = String(format: fmt, person.name)
        let sub = L("people.greet.recognized", "认出你了")   // iPhone 在不在旁边還沒接，不寫

        // 卡：贴着内容的宽度、顶边离屏幕 56，圆角跟屏幕同心；头像圆在卡里留 30 的边，
        // 半径＝卡圆角 − 30，圆心正好落在卡圆角的圆心上
        let inset: CGFloat = 56
        let cardRadius = Screen.concentric(inset: inset)
        let pad: CGFloat = 30, gap: CGFloat = 26, tail: CGFloat = 44
        let avatarR = cardRadius - pad
        let maxRoom = 1024 - inset * 2 - pad - avatarR * 2 - gap - tail
        let tf = Self.fitted(title, size: 58, weight: .bold, maxWidth: maxRoom, minScale: 0.6)
        let sf = Self.fitted(sub, size: 38, weight: .medium, maxWidth: maxRoom, minScale: 0.6)
        let textW = max(Typo.width(title, tf), Typo.width(sub, sf))
        let width = min(1024 - inset * 2, pad + avatarR * 2 + gap + textW + tail)
        let card = CGRect(x: 512 - width / 2, y: inset, width: width, height: cardRadius * 2)
        g.saveGState(); g.setAlpha(alpha)
        g.translateBy(x: 0, y: (1 - alpha) * -16)
        glass(g, card, radius: cardRadius, tint: NSColor(white: 1, alpha: 0.18), band: 14)
        let c = CGPoint(x: card.minX + cardRadius, y: card.midY)
        drawAvatar(g, person, center: c, radius: avatarR)
        let tx = c.x + avatarR + gap
        drawLeft(g, title, font: tf, x: tx, y: c.y - 2, color: .white)
        drawLeft(g, sub, font: sf, x: tx, y: c.y + 50, color: NSColor.white.withAlphaComponent(0.72))
        g.restoreGState()
    }

    private func drawAvatar(_ g: CGContext, _ person: Person, center c: CGPoint, radius r: CGFloat) {
        drawPersonAvatar(g, person, in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))   // 2.0 第四輪：👀 人物頭像
    }

    /// 左对齐画一行字，y 是基线
    private func drawLeft(_ g: CGContext, _ s: String, font: NSFont, x: CGFloat, y: CGFloat, color: NSColor) {
        let f = color.isLightInk ? FaceType.graded(font, 440) : font
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: Typo.attributes(f, color: color)))
        g.saveGState()
        g.translateBy(x: x, y: y); g.scaleBy(x: 1, y: -1)
        g.textPosition = .zero; CTLineDraw(line, g)
        g.restoreGState()
    }

    // MARK: 录脸引导

    private func drawEnrollCard(_ g: CGContext, _ e: PeopleOverlay.Enroll, _ now: Double) {
        let ended: FaceEnrollmentFlow.EndReason? = { if case .ended(let r) = e.phase { r } else { nil } }()
        let saved: Bool = { if case .saved = e.phase { true } else { false } }()
        g.saveGState()
        g.setFillColor(NSColor.black.withAlphaComponent(0.42).cgColor)
        g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let card = CGRect(x: 56, y: 150, width: 912, height: 724)
        glass(g, card, radius: Screen.concentric(inset: card.minX), tint: NSColor(white: 1, alpha: 0.18), band: 14)

        // 进度圈 + 头像（录好了换成对勾）
        let c = CGPoint(x: 512, y: card.minY + 52 + 110)
        let ringR: CGFloat = 104
        g.setLineWidth(14); g.setLineCap(.round)
        g.setStrokeColor(NSColor(white: 1, alpha: 0.22).cgColor)
        g.strokeEllipse(in: CGRect(x: c.x - ringR, y: c.y - ringR, width: ringR * 2, height: ringR * 2))
        let p = CGFloat(min(1, max(0, e.progress)))
        if p > 0.003 {
            g.setStrokeColor(NSColor.white.cgColor)
            g.addArc(center: c, radius: ringR, startAngle: -.pi / 2, endAngle: -.pi / 2 + .pi * 2 * p, clockwise: false)
            g.strokePath()
        }
        if saved {
            g.setStrokeColor(NSColor.white.cgColor); g.setLineWidth(14); g.setLineJoin(.round)
            g.move(to: CGPoint(x: c.x - 38, y: c.y + 4)); g.addLine(to: CGPoint(x: c.x - 10, y: c.y + 32))
            g.addLine(to: CGPoint(x: c.x + 42, y: c.y - 30)); g.strokePath()
        } else {
            drawAvatar(g, e.person, center: c, radius: ringR - 24)
        }

        // 文案
        let title: String, sub: String
        if saved {
            title = L("people.enroll.done", "录好了"); sub = L("people.enroll.doneSub", "之后桌宠就认得你")
        } else if let r = ended {
            switch r {
            case .timedOut: title = L("people.enroll.timedOut", "没录到"); sub = L("people.enroll.timedOutSub", "光线亮一点，再试一次")
            case .cameraLost: title = L("people.enroll.cameraLost", "用不了相机"); sub = L("people.enroll.cameraLostSub", "检查相机权限后再试")
            default: title = L("people.enroll.failed", "没存成功"); sub = L("people.enroll.failedSub", "再试一次")
            }
        } else {
            title = L("people.enroll.title", "看着屏幕，慢慢转头")
            if case .framing(let hint) = e.phase, let hint { sub = hint.text }
            else { sub = e.asksToTurn ? L("people.enroll.turn", "再往两边轻轻转一点") : L("people.enroll.front", "先正对着屏幕") }
        }
        let textWidth = card.width - 96
        let tf = Self.rounded(68, weight: .bold)
        let lines = Self.wrap(title, tf, textWidth, maxLines: 2)
        for (i, l) in lines.enumerated() { drawCentered(g, l, font: tf, y: c.y + ringR + 110 + CGFloat(i) * 78, color: .white) }
        let subTop = c.y + ringR + 110 + CGFloat(lines.count - 1) * 78 + 76
        drawCentered(g, sub, font: Self.fitted(sub, size: 46, weight: .medium, maxWidth: textWidth),
                     y: subTop, color: NSColor.white.withAlphaComponent(0.85))
        if !saved, ended == nil {
            let who = String(format: L("people.enroll.for", "正在录制：%@"), e.person.name)
            drawCentered(g, who, font: Self.fitted(who, size: 38, weight: .medium, maxWidth: textWidth),
                         y: subTop + 62, color: NSColor.white.withAlphaComponent(0.6))
            PeopleOverlay.enrollText = (title, sub, who, CGRect(x: card.minX + 48, y: c.y + ringR, width: textWidth, height: subTop + 70 - (c.y + ringR)))   // 2.0 depth：VoiceOver 念得到引导
            // 取消钮：388×116（≥88），白底浅字不抢戏
            let r = CGRect(x: 512 - 194, y: card.maxY - 52 - 116, width: 388, height: 116)
            PeopleOverlay.cancelRect = r
            let since = now - PeopleOverlay.cancelPressedAt
            let k: CGFloat = since < 0.1 ? 1 - CGFloat(since / 0.1) : 0
            g.saveGState()
            g.translateBy(x: r.midX, y: r.midY); g.scaleBy(x: 1 - 0.04 * k, y: 1 - 0.04 * k); g.translateBy(x: -r.midX, y: -r.midY)
            g.setFillColor(NSColor(white: 1, alpha: 0.16).cgColor)
            g.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)); g.fillPath()
            let label = L("people.enroll.cancel", "取消")
            let bf = Self.rounded(46, weight: .semibold)
            drawLeft(g, label, font: bf, x: r.midX - Typo.width(label, bf) / 2, y: r.midY + bf.capHeight / 2, color: .white)
            g.restoreGState()
        } else {
            PeopleOverlay.cancelRect = .zero
            PeopleOverlay.enrollText = (title, sub, "", CGRect(x: card.minX + 48, y: c.y + ringR, width: textWidth, height: subTop + 70 - (c.y + ringR)))   // 2.0 depth：VoiceOver（录好／没录到的结语也念）
        }
        g.restoreGState()
    }
}
