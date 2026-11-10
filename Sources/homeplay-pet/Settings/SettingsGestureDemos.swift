import SwiftUI

// 手勢頁的插畫：選中哪一行就播哪一個手勢。左格線稿畫「手在哪裡做什麼」（滑鼠＝游標、觸控板＝軌跡板上的手指、觸控＝螢幕上的手指），
// 右格平塗畫桌寵的回應。語法照 docs/plans/gestures.md 二：螢幕上的拖動只歸畫面，轉身體只拖機身；👀 往下拉＝回主畫面。
// 畫具在 DemoKit.swift，t 是秒。

private typealias M = DemoMath
private let deg = DemoMath.deg

/// 手勢頁的一行＝一種手勢
enum GestureKind: String, CaseIterable {
    case home, switcher, control, page, back, hold, turn, rotate, front, resize, move, carplay, carDrag, menu, apart
}

enum GestureDemo {
    static func cycle(_ k: GestureKind, _ i: IntroInput) -> Double {
        switch k {
        case .resize: return i == .mouse ? 3.6 : 3.4
        case .move: return i == .trackpad ? 4.2 : 4.0
        case .carplay: return 4.4
        case .switcher, .turn, .rotate, .apart: return 4.0
        case .menu: return 3.6
        default: return 3.6
        }
    }
    static func key(_ k: GestureKind, _ i: IntroInput) -> Double {
        switch k {
        // 「減少動態效果」與截圖只畫這一幀：選在手還在、結果已經出來的那一刻
        case .home, .control, .page, .back, .carDrag: return 1.0
        case .switcher: return 2.1
        case .hold: return 1.5
        case .turn, .rotate: return 1.25
        case .front: return 1.9
        case .resize: return i == .mouse ? 1.4 : 1.15
        case .move: return 1.0
        case .carplay: return 0.98
        case .menu: return 0.85
        case .apart: return 0.7
        }
    }

    // MARK: 左格

    static func left(_ k: GestureKind, _ i: IntroInput, _ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        switch (k, i) {
        case (.resize, .trackpad): IllusScene.pinchL(g, p, t)
        case (.move, .trackpad): IllusScene.threeL(g, p, t)
        case (.carplay, .trackpad): IllusScene.forceL(g, p, t)
        case (.page, .trackpad): twoFingerSwipe(g, p, t)
        case (.rotate, _): twoFingerRotate(g, p, t)
        case (.apart, _): twoFingerDoubleTap(g, p, t)
        case (.menu, .trackpad): twoFingerClick(g, p, t)
        case (.carDrag, .trackpad): twoFingerSwipe(g, p, t)
        case (.resize, .mouse): keys(g, p, t, ["⌘", "+"], at: 1.0)
        case (.carplay, _): keys(g, p, t, ["space"], at: 0.78)
        default: onDevice(k, i, g, p, t)
        }
    }

    /// 在桌寵正面的線稿上做的手勢（游標或手指）
    private static func onDevice(_ k: GestureKind, _ i: IntroInput, _ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        device(g, p)
        let pill = CGPoint(x: 100, y: 25)
        switch k {
        case .home:
            pointer(g, p, i, t, down: 0.4, up: 1.2) { s in lerp(pill, CGPoint(x: 100, y: 70), Track(0, [(0.45, 1, .glide), (3.0, 0, .calm)])(s)) }
        case .switcher:
            pointer(g, p, i, t, down: 0.4, up: 2.0) { s in lerp(pill, CGPoint(x: 100, y: 50), Track(0, [(0.45, 1, .settle), (3.3, 0, .calm)])(s)) }
            let hold = M.presence(t, 1.0, 1.95)   // 拉住停一下：等待環
            if hold > 0.01 {
                let c = CGPoint(x: 100, y: 50), frac = M.clamp((t - 1.0) / 0.8)
                InPanel.stroke(g, Path { q in q.addArc(center: c, radius: 13, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * frac), clockwise: false) },
                               p.dot.opacity(hold), 2)
            }
        case .control:
            pointer(g, p, i, t, down: 0.4, up: 1.2) { s in lerp(CGPoint(x: 132, y: 19), CGPoint(x: 132, y: 66), Track(0, [(0.45, 1, .glide), (3.0, 0, .calm)])(s)) }
        case .page:
            pointer(g, p, i, t, down: 0.4, up: 1.2) { s in lerp(CGPoint(x: 124, y: 56), CGPoint(x: 76, y: 56), Track(0, [(0.45, 1, .glide), (3.0, 0, .calm)])(s)) }
        case .carDrag:   // CarPlay 顯示時：拖動交給 iPhone（地圖跟著走）
            pointer(g, p, i, t, down: 0.4, up: 1.6) { s in lerp(CGPoint(x: 84, y: 64), CGPoint(x: 120, y: 44), Track(0, [(0.45, 1, .glide), (3.0, 0, .calm)])(s)) }
        case .back:
            g.stroke(DemoShape.line([DemoShape.pt(66, 30), DemoShape.pt(66, 80)]), with: .color(p.dot.opacity(0.35)), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 3]))
            pointer(g, p, i, t, down: 0.4, up: 1.2) { s in lerp(CGPoint(x: 67, y: 56), CGPoint(x: 122, y: 56), Track(0, [(0.45, 1, .glide), (3.0, 0, .calm)])(s)) }
        case .hold:
            let c = CGPoint(x: 100, y: 58)
            pointer(g, p, i, t, down: 0.4, up: 1.7) { _ in c }
            let a = M.presence(t, 0.45, 1.7)
            if a > 0.01 {
                let frac = M.clamp((t - 0.45) / 0.5)
                InPanel.stroke(g, Path { q in q.addArc(center: c, radius: 13, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * frac), clockwise: false) }, p.dot.opacity(a), 2)
            }
        case .turn:
            // 拖的是機身外框，不是螢幕：外框描成強調色
            let hi = M.presence(t, 0.3, 2.2)
            InPanel.stroke(g, DemoShape.round(56, 10, 88, 84, 14), p.dot.opacity(0.55 * hi))
            pointer(g, p, i, t, down: 0.4, up: 2.1) { s in
                CGPoint(x: 141 + Track(0, [(0.45, 26, .glide), (1.3, -14, .glide), (2.0, 0, .glide)])(s), y: 70)
            }
        case .front:
            let c = CGPoint(x: 141, y: 44)
            pointer(g, p, i, t, down: 0.75, up: 1.15) { _ in c }
            for s in [0.8, 1.0] { ripple(g, p, c, t - s) }
        case .resize:   // 觸控：螢幕上兩指張合
            let d = (x: cos(-32 * deg), y: sin(-32 * deg))
            let sep = Track(10, [(0.55, 26, .settle), (1.55, 10, .settle)])
            for (sg, dn) in [(1.0, 0.30), (-1.0, 0.34)] {
                InPanel.finger(g, p, t: t, down: dn, up: 2.25) { u in CGPoint(x: 100 + sg * d.x * sep(u), y: 54 + sg * d.y * sep(u)) }
            }
        case .move:
            if i == .mouse {
                keycap(g, p, CGPoint(x: 28, y: 100), "⌘", pressed: M.presence(t, 0.3, 1.6))
                pointer(g, p, i, t, down: 0.4, up: 1.5) { s in CGPoint(x: 100 + Track(0, [(0.45, 30, .glide), (2.2, 0, .calm)])(s), y: 56) }
            } else {   // 觸控：拖底座
                let hi = M.presence(t, 0.3, 1.6)
                InPanel.stroke(g, DemoShape.line([DemoShape.pt(88, 94), DemoShape.pt(84, 112), DemoShape.pt(116, 112), DemoShape.pt(112, 94)]), p.dot.opacity(0.6 * hi))
                pointer(g, p, i, t, down: 0.4, up: 1.5) { s in CGPoint(x: 100 + Track(0, [(0.45, 30, .glide), (2.2, 0, .calm)])(s), y: 104) }
            }
        case .menu:
            let c = CGPoint(x: 141, y: 64)
            if i == .mouse {
                mouse(g, p, CGPoint(x: 30, y: 92), right: M.presence(t, 0.6, 0.9))
                pointer(g, p, i, t, down: 0.6, up: 0.9) { _ in c }
            } else {   // 觸控：機身上按住
                pointer(g, p, i, t, down: 0.3, up: 1.3) { _ in c }
                let a = M.presence(t, 0.35, 1.3), frac = M.clamp((t - 0.35) / 0.45)
                if a > 0.01 {
                    InPanel.stroke(g, Path { q in q.addArc(center: c, radius: 12, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * frac), clockwise: false) }, p.dot.opacity(a), 2)
                }
            }
        default: break
        }
    }

    // MARK: 右格

    static func right(_ k: GestureKind, _ i: IntroInput, _ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        switch k {
        case .resize: if i == .mouse { resizeR(g, p, t) } else { IllusScene.pinchR(g, p, t) }
        case .move: moveR(g, p, t)
        case .carplay: IllusScene.forceR(g, p, t)
        case .turn, .rotate: IllusScene.slideR(g, p, t)
        default:
            OutPanel.background(g, p)
            switch k {
            case .home:
                OutPanel.sun(g, 26, 24); OutPanel.dots(g, 156, 18)
                let pull = Track(0, [(0.5, 1, .glide), (3.0, 0, .calm)])(t)
                FlatHome(x: 100, y: 106, S: 60, screen: { c in
                    HomeScreens.home(c, showPill: false)
                    HomeScreens.scaled(c, toward: CGPoint(x: 50, y: 6), by: 1 - 0.75 * pull, alpha: 1 - pull) { HomeScreens.app($0, showPill: false) }
                    HomeScreens.pill(c, dy: 14 * M.presence(t, 0.45, 1.2) * pull)
                }).draw(g, p)
            case .switcher:
                OutPanel.half(g, 24, Illus.H, 22); OutPanel.zig(g, 150, 22)
                let k = Track(0, [(1.2, 1, .settle), (3.3, 0, .calm)])(t), drag = Track(0, [(0.45, 1, .settle), (3.3, 0, .calm)])(t)
                FlatHome(x: 100, y: 106, S: 60, screen: { c in
                    HomeScreens.switcher(c, k, drag: drag)
                }).draw(g, p)
            case .control:
                OutPanel.dots(g, 16, 16); OutPanel.sun(g, 176, 22, 6)
                let k = Track(0, [(0.5, 1, .glide), (3.0, 0, .calm)])(t)
                FlatHome(x: 100, y: 106, S: 60, screen: { c in HomeScreens.home(c); HomeScreens.control(c, k) }).draw(g, p)
            case .page:
                OutPanel.half(g, 22, Illus.H, 22); OutPanel.dots(g, 160, 18)
                let k = Track(0, [(0.5, 1, .glide), (3.0, 0, .glide)])(t)
                FlatHome(x: 100, y: 106, S: 60, screen: { c in
                    var a = c; a.translateBy(x: -100 * k, y: 0); HomeScreens.home(a)
                    var b = c; b.translateBy(x: 100 * (1 - k), y: 0); HomeScreens.home(b, page: 1)
                    HomeScreens.pageDots(c, k)
                }).draw(g, p)
            case .back:
                OutPanel.sun(g, 26, 24); OutPanel.zig(g, 150, 22)
                let k = Track(0, [(0.5, 1, .glide), (3.0, 0, .calm)])(t)
                FlatHome(x: 100, y: 106, S: 60, screen: { c in
                    HomeScreens.home(c)
                    var a = c; a.translateBy(x: 100 * k, y: 0); a.opacity = 1 - 0.3 * k; HomeScreens.app(a)
                }).draw(g, p)
            case .carDrag:
                OutPanel.halo(g, p, 100, 64, 48); OutPanel.sun(g, 170, 24, 6)
                let k = Track(0, [(0.5, 1, .glide), (3.0, 0, .calm)])(t)
                FlatHome(x: 100, y: 104, S: 58, reveal: 1.2, phase: 0.15 + 0.5 * k).draw(g, p)
            case .hold:
                OutPanel.dots(g, 16, 16); OutPanel.half(g, 178, Illus.H, 20)
                let k = Track(0, [(0.95, 1, .settle), (3.0, 0, .calm)])(t)
                FlatHome(x: 100, y: 106, S: 60, screen: { c in HomeScreens.overview(c, k) }).draw(g, p)
            case .front:
                OutPanel.half(g, 22, Illus.H, 22); OutPanel.zig(g, 150, 22)
                let yaw = Track(34 * deg, [(1.05, 0, .bloom), (3.0, 34 * deg, .calm)])(t)
                FlatHome(x: 100, y: 104, S: 58, yaw: yaw, look: CGPoint(x: 0, y: 0.1), blink: M.blink(t, at: 1.5)).draw(g, p)
            case .menu:
                OutPanel.sun(g, 24, 24, 6); OutPanel.dots(g, 160, 92)
                let h = FlatHome(x: 84, y: 104, S: 56, yaw: -8 * deg).draw(g, p)
                let k = M.clamp(DemoSpring.pop.step(t - (i == .touch ? 0.8 : 0.65)) - DemoSpring.calm.step(t - 2.9), 0, 1.2)
                if k > 0.01 { HomeScreens.menuCard(g, at: CGPoint(x: h.top.x + 26, y: h.top.y + 4), k) }
            case .apart:
                OutPanel.dots(g, 16, 16); OutPanel.sun(g, 176, 22, 6)
                let lift = Track(0, [(0.75, 0.32, .bloom), (2.75, 0, .settle)])(t)
                FlatHome(x: 100, y: 108, S: 52, yaw: 14 * deg, lift: lift).draw(g, p)
            default: break
            }
        }
    }

    /// 滑鼠的放大：⌘＋ 一下大一號
    private static func resizeR(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        OutPanel.background(g, p); OutPanel.sun(g, 26, 24); OutPanel.dots(g, 160, 92)
        let sc = Track(1, [(1.05, 1.22, .bloom), (2.9, 1.0, .calm)])(t)
        FlatHome(x: 100, y: 104, S: 52, scale: sc, look: CGPoint(x: 0, y: -0.2), blink: M.blink(t, at: 2.4)).draw(g, p)
    }

    /// 搬視窗：整個桌寵在桌面上換位置
    private static func moveR(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        OutPanel.background(g, p); OutPanel.desktop(g, p); OutPanel.window(g, 18, 22, 70, 52)
        let px = Track(0.3, [(0.5, 0.78, .glide), (2.2, 0.3, .calm)])(t)
        let lift = M.presence(t, 0.35, 1.55)
        FlatHome(x: 30 + 140 * px, y: 104 - lift * 3, S: 34 * (1 + 0.04 * lift), yaw: -8 * deg).draw(g, p)
    }

    // MARK: 左格的零件

    /// 桌寵正面線稿：外框、螢幕、頂端的 👀 膠囊、底座
    static func device(_ g: GraphicsContext, _ p: IllusPalette) {
        InPanel.stroke(g, DemoShape.round(56, 10, 88, 84, 14), p.line)
        InPanel.stroke(g, DemoShape.round(64, 18, 72, 68, 8), p.line2, 1.6)
        g.fill(DemoShape.round(91, 22, 18, 6, 3), with: .color(p.line))
        InPanel.stroke(g, DemoShape.line([DemoShape.pt(88, 94), DemoShape.pt(84, 112), DemoShape.pt(116, 112), DemoShape.pt(112, 94)]), p.line)
    }

    /// 游標（滑鼠、觸控板）或手指（觸控）；按著的時候游標尖端有一圈
    static func pointer(_ g: GraphicsContext, _ p: IllusPalette, _ i: IntroInput, _ t: Double, down: Double, up: Double, _ pos: @escaping (Double) -> CGPoint) {
        if i == .touch { InPanel.finger(g, p, t: t, down: down, up: up, pos); return }
        let q = pos(t), pressed = M.presence(t, down, up)
        if pressed > 0.01 {
            g.fill(DemoShape.circle(q, 8.5), with: .color(p.dot.opacity(0.22 * pressed)))
            g.fill(DemoShape.circle(q, 3.2), with: .color(p.dot.opacity(pressed)))
        }
        let arrow: [(Double, Double)] = [(0, 0), (0, 15), (4, 11.4), (6.8, 17.4), (9.4, 16.2), (6.7, 10.4), (11.4, 10.4)]
        let path = DemoShape.path(arrow.map { CGPoint(x: q.x + $0.0 * 0.95, y: q.y + $0.1 * 0.95) })
        g.fill(path, with: .color(p.dark ? .demo(0xF2F2F5) : .demo(0x1C1C1E)))
        g.stroke(path, with: .color(p.dark ? .demo(0x1C1C1E) : .white), style: StrokeStyle(lineWidth: 1.1, lineJoin: .round))
    }

    /// 點兩下的漣漪
    private static func ripple(_ g: GraphicsContext, _ p: IllusPalette, _ c: CGPoint, _ age: Double) {
        guard age > 0, age < 0.4 else { return }
        let e = M.outCubic(age / 0.4)
        InPanel.stroke(g, DemoShape.circle(c, 6 + 10 * e), p.dot.opacity(1 - e), 2)
    }

    /// 鍵帽（線稿）；按下時填色、往下沉一點
    static func keycap(_ g: GraphicsContext, _ p: IllusPalette, _ c: CGPoint, _ label: String, pressed: Double, width: Double = 26) {
        let r = DemoShape.round(c.x - width / 2, c.y - 13 + 1.5 * pressed, width, 26, 6)
        if pressed > 0.01 { g.fill(r, with: .color(p.dot.opacity(0.22 * pressed))) }
        InPanel.stroke(g, r, pressed > 0.5 ? p.dot : p.line, 2)
        g.draw(Text(label).font(.system(size: label.count > 1 ? 9 : 13, weight: .semibold)).foregroundColor(pressed > 0.5 ? p.dot : p.line),
               at: CGPoint(x: c.x, y: c.y + 1.5 * pressed))
    }

    /// 只按鍵盤的手勢（滑鼠的放大、空白鍵進出 CarPlay）
    private static func keys(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double, _ labels: [String], at s: Double) {
        let wide = labels == ["space"]
        let shown = labels.map { $0 == "space" ? L("settings.gesture.key.space", "空格") : $0 }
        let w = wide ? 96.0 : 34.0, gap = 12.0, total = Double(labels.count) * w + Double(labels.count - 1) * gap
        for (n, label) in shown.enumerated() {
            let x = 100 - total / 2 + w / 2 + Double(n) * (w + gap)
            let press = M.presence(t, s + Double(n) * 0.08, s + 0.45)
            keycap(g, p, CGPoint(x: x, y: 62), label, pressed: press, width: w)
        }
    }

    /// 觸控板：兩指一起往左滑（換頁）
    private static func twoFingerSwipe(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        InPanel.trackpad(g, p)
        let x = Track(0.66, [(0.45, 0.34, .glide), (3.0, 0.66, .calm)])
        for (dy, dn) in [(-0.09, 0.30), (0.09, 0.33)] {
            InPanel.finger(g, p, t: t, down: dn, up: 1.2) { u in InPanel.padPt(x(u), 0.52 + dy) }
        }
    }

    /// 觸控板：兩指旋轉（轉身體）
    private static func twoFingerRotate(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        InPanel.trackpad(g, p)
        let a = Track(-20 * deg, [(0.45, 40 * deg, .glide), (1.3, -10 * deg, .glide), (2.0, -20 * deg, .calm)])
        let c = InPanel.padPt(0.5, 0.52), r = 20.0
        let guide = M.presence(t, 0.4, 2.0)
        if guide > 0.01 {
            g.stroke(DemoShape.circle(c, r), with: .color(p.line2.opacity(guide)), style: StrokeStyle(lineWidth: 1.4, dash: [2, 4]))
        }
        for (off, dn) in [(0.0, 0.30), (Double.pi, 0.33)] {
            InPanel.finger(g, p, t: t, down: dn, up: 2.1) { u in CGPoint(x: c.x + r * cos(a(u) + off), y: c.y + r * 0.8 * sin(a(u) + off)) }
        }
    }

    /// 觸控板：兩指輕點兩下（拆開看看）
    private static func twoFingerDoubleTap(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        InPanel.trackpad(g, p)
        for dx in [-0.08, 0.08] {
            let q = InPanel.padPt(0.5 + dx, 0.52)
            for (dn, up) in [(0.40, 0.52), (0.62, 0.74)] { InPanel.finger(g, p, t: t, down: dn, up: up) { _ in q } }
            for s in [0.45, 0.67] { ripple(g, p, q, t - s) }
        }
    }

    /// 觸控板：兩指點按（選單）
    private static func twoFingerClick(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        InPanel.trackpad(g, p)
        for dx in [-0.08, 0.08] {
            let q = InPanel.padPt(0.5 + dx, 0.55)
            InPanel.finger(g, p, t: t, down: 0.4, up: 0.95) { _ in q }
            ripple(g, p, q, t - 0.62)
        }
    }

    /// 滑鼠線稿：按右鍵時右半邊亮起來
    private static func mouse(_ g: GraphicsContext, _ p: IllusPalette, _ c: CGPoint, right: Double) {
        let body = DemoShape.round(c.x - 11, c.y - 17, 22, 34, 11)
        if right > 0.01 {
            var r = g
            r.clip(to: Path(CGRect(x: c.x, y: c.y - 17, width: 11, height: 14)))
            r.fill(body, with: .color(p.dot.opacity(0.85 * right)))
        }
        InPanel.stroke(g, body, p.line, 2)
        InPanel.stroke(g, DemoShape.line([DemoShape.pt(c.x, c.y - 17), DemoShape.pt(c.x, c.y - 3)]), p.line, 1.6)
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ k: Double) -> CGPoint { CGPoint(x: M.lerp(a.x, b.x, k), y: M.lerp(a.y, b.y, k)) }
}

// MARK: - 螢幕內容（局部 0…100，y 朝下）

extension HomeScreens {
    static func backdrop(_ c: GraphicsContext) {
        c.fill(Path(CGRect(x: 0, y: 0, width: 100, height: 100)),
               with: .linearGradient(Gradient(colors: [.demo(0x3557C6), .demo(0x5B80E6)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: 100)))
    }

    /// 頂端的 👀 膠囊（往下拉的那一顆）
    static func pill(_ c: GraphicsContext, dy: Double = 0) {
        c.fill(DemoShape.round(39, 3 + dy, 22, 9, 4.5), with: .color(.demo(0x0E1430, 0.92)))
        for dx in [-3.6, 3.6] { c.fill(DemoShape.ellipse(CGPoint(x: 50 + dx, y: 7.5 + dy), 2.2, 2.7), with: .color(.white)) }
    }

    /// 主畫面：四欄圖示＋Dock
    static func home(_ c: GraphicsContext, page: Int = 0, showPill: Bool = true) {
        backdrop(c)
        let palette = page == 0 ? [Ink.coral, Ink.sun, Ink.mint, Ink.sky, Ink.violet0, .white, Ink.mint, Ink.coral, Ink.sky, Ink.sun, Ink.violet0, Ink.mint]
                                : [Ink.mint, Ink.violet0, Ink.sun, .white, Ink.coral, Ink.sky, Ink.sun, Ink.mint, Ink.coral, Ink.violet0, .white, Ink.sky]
        for n in 0..<12 {
            let col = Double(n % 4), row = Double(n / 4)
            c.fill(DemoShape.round(11 + col * 21, 18 + row * 20, 15, 15, 4.5), with: .color(palette[n]))
        }
        c.fill(DemoShape.round(7, 80, 86, 16, 6), with: .color(.white.opacity(0.28)))
        for (n, col) in [Ink.mint, Ink.sky, Ink.sun, Ink.coral].enumerated() { c.fill(DemoShape.round(12 + Double(n) * 21, 82.5, 13, 11, 3.5), with: .color(col)) }
        if showPill { pill(c) }
    }

    /// 一個 App 的畫面（淺色頁、標題列、幾行內容）
    static func app(_ c: GraphicsContext, showPill: Bool = true) {
        c.fill(Path(CGRect(x: 0, y: 0, width: 100, height: 100)), with: .color(.demo(0xF4F5F8)))
        c.fill(Path(CGRect(x: 0, y: 0, width: 100, height: 24)), with: .color(Ink.coral))
        c.fill(DemoShape.round(10, 15, 34, 5, 2.5), with: .color(.white.opacity(0.9)))
        for n in 0..<4 {
            let y = 32 + Double(n) * 15
            c.fill(DemoShape.round(10, y, 10, 10, 3), with: .color([Ink.sky, Ink.mint, Ink.sun, Ink.violet0][n]))
            c.fill(DemoShape.round(25, y + 1.5, 52 - Double(n % 2) * 14, 3.4, 1.7), with: .color(.demo(0xC9D0DC)))
            c.fill(DemoShape.round(25, y + 6.5, 30, 2.6, 1.3), with: .color(.demo(0xDDE2EA)))
        }
        if showPill { pill(c) }
    }

    /// 把 draw 畫的整個畫面縮向 anchor（回主畫面時 App 縮回 👀）
    static func scaled(_ c: GraphicsContext, toward a: CGPoint, by s: Double, alpha: Double, _ draw: (GraphicsContext) -> Void) {
        guard alpha > 0.01 else { return }
        var k = c
        k.opacity = alpha
        k.translateBy(x: a.x, y: a.y); k.scaleBy(x: s, y: s); k.translateBy(x: -a.x, y: -a.y)
        k.clip(to: DemoShape.round(0, 0, 100, 100, 14 * (1 - s) + 0.1))
        draw(k)
    }

    static func pageDots(_ c: GraphicsContext, _ k: Double) {
        for n in 0..<2 {
            let on = n == 0 ? 1 - k : k
            c.fill(DemoShape.circle(46 + Double(n) * 8, 76, 1.8), with: .color(.white.opacity(0.45 + 0.55 * on)))
        }
    }

    /// 控制中心：從右上角拉下來
    static func control(_ c: GraphicsContext, _ k: Double) {
        guard k > 0.01 else { return }
        c.fill(Path(CGRect(x: 0, y: 0, width: 100, height: 100)), with: .color(.black.opacity(0.42 * M.clamp(k))))
        var p = c
        p.translateBy(x: 0, y: -100 * (1 - k))
        let tile = Color.white.opacity(0.82)
        p.fill(DemoShape.round(10, 12, 38, 38, 9), with: .color(tile))
        for (n, col) in [Ink.sky, Ink.sky, Ink.sun, Ink.mint].enumerated() {
            p.fill(DemoShape.circle(20 + Double(n % 2) * 18, 22 + Double(n / 2) * 18, 5.5), with: .color(col))
        }
        p.fill(DemoShape.round(52, 12, 38, 17, 8), with: .color(tile))
        p.fill(DemoShape.round(52, 33, 17, 17, 8), with: .color(tile))
        p.fill(DemoShape.round(73, 33, 17, 17, 8), with: .color(tile))
        p.fill(DemoShape.round(10, 54, 17, 36, 8), with: .color(tile))
        p.fill(DemoShape.round(31, 54, 17, 36, 8), with: .color(tile))
        p.fill(DemoShape.round(10, 70, 17, 20, 0), with: .color(Ink.sun.opacity(0.9)))
        p.fill(DemoShape.round(52, 54, 38, 17, 8), with: .color(tile))
    }

    /// App 切換器：主畫面和 App 縮成兩張卡片
    static func switcher(_ c: GraphicsContext, _ k: Double, drag: Double) {
        home(c, showPill: false)
        c.fill(Path(CGRect(x: 0, y: 0, width: 100, height: 100)), with: .color(.black.opacity(0.45 * M.clamp(k))))
        let s = 1 - 0.55 * M.clamp(k) - 0.12 * drag * (1 - M.clamp(k))
        for (n, dx) in [(0, -24.0), (1, 24.0)] where n == 1 || k > 0.01 {
            var a = c
            let cx = 50 + dx * M.clamp(k), cy = 50 + 4 * drag
            a.opacity = n == 0 ? M.clamp(k) : 1
            a.translateBy(x: cx, y: cy); a.scaleBy(x: s, y: s); a.translateBy(x: -50, y: -50)
            a.clip(to: DemoShape.round(0, 0, 100, 100, 12))
            if n == 0 { home(a, page: 1) } else { app(a) }
        }
        pill(c, dy: 8 * drag)
    }

    /// 錶面總覽：錶面縮成中間一張，左右露出別的錶面
    static func overview(_ c: GraphicsContext, _ k: Double) {
        let s = 1 - 0.42 * M.clamp(k)
        c.fill(Path(CGRect(x: 0, y: 0, width: 100, height: 100)), with: .color(.demo(0x0B0D14)))
        for (dx, col) in [(-62.0, Ink.mint), (62.0, Ink.sun)] where k > 0.01 {
            var a = c
            a.opacity = M.clamp(k)
            a.translateBy(x: 50 + dx * s, y: 50); a.scaleBy(x: s, y: s); a.translateBy(x: -50, y: -50)
            a.fill(DemoShape.round(0, 0, 100, 100, 14), with: .color(col.opacity(0.85)))
            a.fill(DemoShape.round(20, 40, 60, 20, 10), with: .color(.demo(0x0E1430, 0.6)))
        }
        var f = c
        f.translateBy(x: 50, y: 50); f.scaleBy(x: s, y: s); f.translateBy(x: -50, y: -50)
        f.clip(to: DemoShape.round(0, 0, 100, 100, 14 * M.clamp(k) + 0.1))
        face(f, look: .zero, blink: 0)
    }

    /// 右鍵選單：桌寵旁邊彈出一張小卡（畫在面板座標）
    static func menuCard(_ g: GraphicsContext, at p: CGPoint, _ k: Double) {
        var c = g
        c.opacity = M.clamp(k)
        c.translateBy(x: p.x, y: p.y); c.scaleBy(x: 0.6 + 0.4 * k, y: 0.6 + 0.4 * k)
        c.fill(DemoShape.round(2, 3, 52, 50, 8), with: .color(.black.opacity(0.12)))
        c.fill(DemoShape.round(0, 0, 52, 50, 8), with: .color(.white))
        c.fill(DemoShape.round(4, 4, 44, 10, 4), with: .color(Ink.sky))
        c.fill(DemoShape.round(8, 7.5, 24, 3, 1.5), with: .color(.white))
        for n in 0..<3 { c.fill(DemoShape.round(8, 21 + Double(n) * 9.5, 30 - Double(n % 2) * 8, 3, 1.5), with: .color(.demo(0xC9D0DC))) }
    }
}
