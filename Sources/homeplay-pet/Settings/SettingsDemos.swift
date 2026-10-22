import SwiftUI

// 設定裡的九段插畫說明（第二版）：每段兩格，左格線稿輸入、右格平塗結果。
// 分鏡（時間、數值、彈簧）逐項照 docs/design-drafts/設定動畫設計稿.html §4；畫具在 DemoKit.swift。t 是秒。

private typealias M = DemoMath
private let deg = DemoMath.deg

enum IllusScene: String, CaseIterable, Identifiable {
    case pinch, slide, three, force, facing, facingFront, follow, charge, onTop, light
    var id: String { rawValue }

    var cycle: Double {
        switch self {
        case .pinch: return 3.4
        case .slide: return 3.8
        case .three: return 4.2
        case .force, .onTop: return 4.4
        case .facing, .facingFront: return 4.8
        case .follow, .charge, .light: return 6.0
        }
    }
    /// 播完 3 輪停住的那一幀（秒）
    var key: Double {
        switch self {
        case .pinch: return 1.15
        case .slide: return 0.85
        case .three: return 1.0
        case .force: return 0.98
        case .facing, .facingFront: return 1.6
        case .follow: return 1.7
        case .charge: return 2.2
        case .onTop: return 1.4
        case .light: return 2.3
        }
    }

    func left(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        InPanel.background(g, p)
        switch self {
        case .pinch: Self.pinchL(g, p, t)
        case .slide: Self.slideL(g, p, t)
        case .three: Self.threeL(g, p, t)
        case .force: Self.forceL(g, p, t)
        case .facing, .facingFront: Self.facingL(g, p, t)
        case .follow: Self.followL(g, p, t)
        case .charge: Self.chargeL(g, p, t)
        case .onTop: Self.onTopL(g, p, t)
        case .light: Self.lightL(g, p, t)
        }
    }
    func right(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        switch self {
        case .pinch: Self.pinchR(g, p, t)
        case .slide: Self.slideR(g, p, t)
        case .three: Self.threeR(g, p, t)
        case .force: Self.forceR(g, p, t)
        case .facing: Self.facingR(g, p, t, fixed: false)
        case .facingFront: Self.facingR(g, p, t, fixed: true)
        case .follow: Self.followR(g, p, t)
        case .charge: Self.chargeR(g, p, t)
        case .onTop: Self.onTopR(g, p, t)
        case .light: Self.lightR(g, p, t)
        }
    }

    // MARK: 雙指張合：縮放

    private static let pinchSep = Track(0.09, [(0.55, 0.30, .settle), (1.55, 0.09, .settle)])
    private static func pinchL(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        InPanel.trackpad(g, p)
        let d = (x: cos(-32 * deg), y: sin(-32 * deg) * 1.4)
        for (s, dn) in [(1.0, 0.30), (-1.0, 0.34)] {
            InPanel.finger(g, p, t: t, down: dn, up: 2.25) { u in InPanel.padPt(0.5 + s * d.x * pinchSep(u), 0.52 + s * d.y * pinchSep(u)) }
        }
    }
    private static func pinchR(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        OutPanel.background(g, p); OutPanel.sun(g, 26, 24); OutPanel.dots(g, 160, 92)
        let sc = Track(1, [(0.62, 1.24, .settle), (1.62, 1.0, .settle)])(t), guide = M.presence(t, 0.6, 1.62)
        if guide > 0.01 {
            let dash = StrokeStyle(lineWidth: 1.4, dash: [3, 3])
            g.stroke(DemoShape.circle(100, 66, 34), with: .color(.white.opacity(0.7 * guide)), style: dash)
            g.stroke(DemoShape.circle(100, 66, 34 * sc), with: .color(.white.opacity(0.7 * guide)), style: dash)
        }
        FlatHome(x: 100, y: 104, S: 52, scale: sc, look: CGPoint(x: 0, y: -0.2), blink: M.blink(t, at: 2.7)).draw(g, p)
    }

    // MARK: 雙指一起滑：轉身體

    private static let slideX = Track(0.34, [(0.42, 0.66, .glide), (1.82, 0.34, .glide)])
    private static func slideL(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        InPanel.trackpad(g, p)
        for (dx, d1, u1) in [(-0.075, 0.25, 1.05), (0.075, 0.28, 1.07)] {
            let second = t >= 1.5
            InPanel.finger(g, p, t: t, down: second ? d1 + 1.5 : d1, up: second ? u1 + 1.4 : u1) { u in InPanel.padPt(slideX(u) + dx, 0.54) }
        }
    }
    private static func slideR(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        OutPanel.background(g, p); OutPanel.half(g, 22, Illus.H, 22); OutPanel.zig(g, 150, 22)
        let yf = Track(0, [(0.47, 30 * deg, .glide), (1.05, 38 * deg, .glide), (1.86, 4 * deg, .glide), (2.47, 0, .glide)])
        let yaw = yf(t), vel = (yaw - yf(t - 0.016)) / 0.016
        let look = Track(0, [(0.40, 1, .calm), (1.5, 0.2, .calm), (1.80, -1, .calm), (2.7, 0, .calm)])(t)
        let h = FlatHome(x: 100, y: 102, S: 56, yaw: yaw, look: CGPoint(x: look, y: -0.1), blink: M.blink(t, at: 3.2)).draw(g, p)
        // 轉向弧：底座前緣，亮度跟角速度；箭頭在正面移動的那一端
        let va = M.clamp(abs(vel) / (110 * deg))
        if va > 0.02 {
            let c = CGPoint(x: h.ground.x, y: h.ground.y + 2), rx = 0.5 * 56 + 6, ry = rx * 0.16
            InPanel.stroke(g, DemoShape.arc(c, rx, ry, from: 0.2 * .pi, to: 0.8 * .pi), .white.opacity(0.85 * va), 2)
            let a = vel > 0 ? 0.2 * Double.pi : 0.8 * Double.pi, dir = vel > 0 ? 1.0 : -1.0
            let q = CGPoint(x: c.x + rx * cos(a), y: c.y + ry * sin(a))
            g.fill(DemoShape.path([DemoShape.pt(q.x + dir * 5, q.y - 1), DemoShape.pt(q.x - dir, q.y - 4.5), DemoShape.pt(q.x - dir, q.y + 3)]),
                   with: .color(.white.opacity(0.85 * va)))
        }
    }

    // MARK: 三指拖移：搬視窗

    private static func threeL(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        InPanel.trackpad(g, p)
        let cx = Track(0.3, [(0.5, 0.7, .glide), (2.05, 0.3, .glide)])
        let off: [(Double, Double)] = [(-0.13, 0.05), (0, -0.05), (0.13, 0.05)]
        for k in 0..<3 {
            let first = t < 1.6
            InPanel.finger(g, p, t: t, down: (first ? 0.30 : 1.85) + Double(k) * 0.03, up: (first ? 1.35 : 3.1) + Double(k) * 0.02, scale: 0.9) { u in
                InPanel.padPt(cx(u) + off[k].0, 0.52 + off[k].1)
            }
        }
    }
    private static func threeR(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        OutPanel.background(g, p); OutPanel.desktop(g, p); OutPanel.window(g, 18, 22, 70, 52)
        let px = Track(0.22, [(0.5, 0.80, .glide), (2.05, 0.22, .glide)])
        let lift = Track(0, [(0.32, 1, .calm), (1.38, 0, .calm), (1.88, 1, .calm), (3.12, 0, .calm)])(t)
        let yaw = M.aim(at: t, follow: false) { atan(-(2 * px($0) - 1) * Aim.parallax) }
        FlatHome(x: 30 + 140 * px(t), y: 104 - lift * 3, S: 34 * (1 + 0.04 * lift), yaw: yaw, reveal: 1, phase: t / IllusScene.three.cycle).draw(g, p)
    }

    // MARK: 稍微用力按下：進入／退出 CarPlay

    private static func click(_ t: Double) -> Double {
        func c(_ s: Double) -> Double { DemoSpring.pop.step(t - s) - DemoSpring.pop.step(t - s - 0.09) }
        return c(0.78) + c(2.78)
    }
    private static func forceL(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        InPanel.trackpad(g, p)
        let pressure = Track(0, [(0.45, 1, .settle), (0.98, 0, .calm), (2.45, 1, .settle), (2.98, 0, .calm)])(t)
        let c = InPanel.padPt(0.5, 0.52), first = t < 1.8, dn = first ? 0.30 : 2.30, up = first ? 1.25 : 3.25
        let a = M.clamp(DemoSpring.calm.step(t - (dn - 0.1)) - DemoSpring.calm.step(t - up))
        if a > 0.01 {   // 壓力環：喀之後保持全滿到抬手
            InPanel.stroke(g, DemoShape.circle(c, 14), p.line2)
            let held = (t > 0.78 && t < up) || (t > 2.78 && t < up)
            let frac = held ? 1 : M.clamp(pressure / 0.93)
            InPanel.stroke(g, Path { q in q.addArc(center: c, radius: 14, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * frac), clockwise: false) },
                           p.dot.opacity(a))
        }
        for s in [0.78, 2.78] {   // 喀：迸出八條短線
            let age = t - s
            guard age > 0, age < 0.45 else { continue }
            let e = M.outCubic(age / 0.45)
            let rays = Path { q in
                for i in 0..<8 {
                    let an = Double(i) * .pi / 4, r0 = 18 + 6 * e, r1 = 22 + 10 * e
                    q.move(to: CGPoint(x: c.x + cos(an) * r0, y: c.y + sin(an) * r0)); q.addLine(to: CGPoint(x: c.x + cos(an) * r1, y: c.y + sin(an) * r1))
                }
            }
            InPanel.stroke(g, rays, p.dot.opacity(1 - e), 2)
        }
        InPanel.finger(g, p, t: t, down: dn, up: up, scale: 1 - 0.1 * click(t)) { _ in c }
    }
    private static func forceR(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        OutPanel.background(g, p); OutPanel.halo(g, p, 100, 64, 48); OutPanel.sun(g, 170, 24, 6)
        let reveal = Track(0, [(0.80, 1, .bloom), (2.80, 0, .settle)])(t)
        FlatHome(x: 100, y: 104, S: 58, scale: 1 - 0.02 * click(t), reveal: M.clamp(reveal, 0, 1.2), look: CGPoint(x: 0, y: 0.2),
                 blink: M.blink(t, at: 3.7), phase: t / IllusScene.force.cycle).draw(g, p)
    }

    // MARK: 朝向

    private static let facingX = Track(0.16, [(0.5, 0.84, .glide), (2.6, 0.16, .glide)])
    private static func facingL(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        InPanel.stroke(g, DemoShape.round(30, 14, 140, 86, 8), p.line)
        g.fill(DemoShape.round(92, 14, 16, 5, 2.5), with: .color(p.line))
        InPanel.stroke(g, DemoShape.line([DemoShape.pt(84, 100), DemoShape.pt(80, 112), DemoShape.pt(120, 112), DemoShape.pt(116, 100)]), p.line)
        g.stroke(DemoShape.line([DemoShape.pt(100, 22), DemoShape.pt(100, 92)]), with: .color(p.line2), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [2, 4]))
        InPanel.finger(g, p, t: t, down: -1, up: 99, scale: 0.8) { s in CGPoint(x: 40 + 120 * facingX(s), y: 76) }
        InPanel.stroke(g, DemoShape.circle(100, 119, 4), p.line, 2)
    }
    private static func facingR(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double, fixed: Bool) {
        OutPanel.background(g, p); OutPanel.desktop(g, p, dock: false); OutPanel.dots(g, 14, 18)
        let x = 36 + 128 * facingX(t)
        let yaw = fixed ? 0 : M.aim(at: t, follow: false) { atan(-(2 * facingX($0) - 1) * Aim.parallax) }
        let h = FlatHome(x: x, y: 86, S: 42, yaw: yaw, look: CGPoint(x: fixed ? 0 : M.clamp((100 - x) / 70, -1, 1), y: 0.3),
                         blink: M.blink(t, at: 4.3)).draw(g, p)
        g.stroke(DemoShape.line([CGPoint(x: h.eyes.x, y: h.eyes.y + 6), CGPoint(x: fixed ? h.eyes.x : 100, y: 106)]),
                 with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [2, 3]))
        OutPanel.person(g, 100, 116, 0.62)
        if fixed {
            g.fill(DemoShape.circle(182, 22, 9), with: .color(.white))
            g.draw(Text(Image(systemName: "lock.fill")).font(.system(size: 8.5, weight: .semibold)).foregroundColor(Ink.navy), at: CGPoint(x: 182, y: 22))
        }
    }

    // MARK: 跟隨我

    private static let walker = Track(46, [(0.4, 214, .walk), (2.6, 205, .walk), (3.4, 108, .walk), (4.4, 46, .walk)])
    private static func followL(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        InPanel.stroke(g, DemoShape.round(30, 14, 140, 96, 10), p.line)
        let fx = 100 + (walker(t) - 130) * 0.5
        InPanel.stroke(g, DemoShape.circle(fx, 66, 14), p.line)
        InPanel.stroke(g, Path { q in q.addArc(center: CGPoint(x: fx, y: 112), radius: 27, startAngle: .radians(.pi * 1.15), endAngle: .radians(.pi * 1.85), clockwise: false) }, p.line)
        let bx = 100 + (walker(t - 0.08) - 130) * 0.5, b = 21.0, L = 6.0
        let brackets = Path { q in
            for (sx, sy) in [(-1.0, -1.0), (1, -1), (-1, 1), (1, 1)] {
                q.move(to: CGPoint(x: bx + sx * b, y: 66 + sy * b - sy * L)); q.addLine(to: CGPoint(x: bx + sx * b, y: 66 + sy * b))
                q.addLine(to: CGPoint(x: bx + sx * b - sx * L, y: 66 + sy * b))
            }
        }
        InPanel.stroke(g, brackets, p.dot, 2.2)
        g.fill(DemoShape.circle(100, 20, 2.2), with: .color(Ink.mint))
    }
    private static func followR(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        OutPanel.background(g, p); OutPanel.sun(g, 24, 24, 6); OutPanel.zig(g, 150, 22)
        func gx(_ s: Double) -> Double { M.clamp((walker(s) - 130) / 120, -1, 1) }
        let yaw = M.aim(at: t, follow: true) { Aim.followTarget(gazeX: gx($0), baseline: 0, maxDegrees: 25) }
        let x = 30 + (walker(t) - 46) / 168 * 140
        let c = HomeProjection(x: 100, y: 92, S: 50, yaw: yaw).screen(0, 0.05)
        let ang = atan2(104 - c.y, x - c.x)
        g.fill(Path { q in q.move(to: c); q.addArc(center: c, radius: 110, startAngle: .radians(ang - 8 * deg), endAngle: .radians(ang + 8 * deg), clockwise: false); q.closeSubpath() },
               with: .color(.white.opacity(0.22)))
        FlatHome(x: 100, y: 92, S: 50, yaw: yaw, look: CGPoint(x: gx(t - 0.05) * 1.1, y: 0.35), blink: M.blink(t, at: 2.2), camOn: true).draw(g, p)
        let moving = abs(walker(t) - walker(t - 0.05)) > 0.4
        OutPanel.person(g, x, 116 - (moving ? abs(sin(t * 9)) * 1.4 : 0), 0.9)
    }

    // MARK: 插線一次，之後無線

    private static let plug = Track(0, [(0.6, 1, .settle), (3.6, 0, .settle)])
    private static let charging = Track(0, [(0.95, 1, .bloom), (3.7, 0, .calm)])
    private static func chargeL(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        InPanel.stroke(g, DemoShape.round(80, 12, 40, 78, 9), p.line)
        g.fill(DemoShape.round(93, 17, 14, 4, 2), with: .color(p.line))
        let y = M.lerp(122, 94, plug(t))
        InPanel.stroke(g, DemoShape.round(95, y, 10, 9, 2), p.line)
        InPanel.stroke(g, DemoShape.line([DemoShape.pt(100, y + 9), DemoShape.pt(100, 140)]), p.line)
        let b = charging(t)
        if b > 0.01 {
            var c = g
            c.translateBy(x: 100, y: 50)
            InPanel.stroke(c, OutPanel.bolt(1.1 * (0.8 + 0.4 * b)), p.dot.opacity(M.clamp(b)), 2.2)
        }
    }
    private static func chargeR(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        OutPanel.background(g, p); OutPanel.dots(g, 16, 16)
        FlatHome(x: 74, y: 104, S: 60, reveal: 1, phase: t / IllusScene.charge.cycle).draw(g, p)
        for k in 0..<3 {   // 無線弧：一直都在（相位跟週期對齊）
            let f = ((t / IllusScene.charge.cycle * 5 - Double(k) * 0.22).truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
            InPanel.stroke(g, Path { q in q.addArc(center: CGPoint(x: 150, y: 60), radius: 10 + f * 20, startAngle: .radians(.pi * 0.82), endAngle: .radians(.pi * 1.18), clockwise: false) },
                           .white.opacity(sin(.pi * f) * 0.85), 2)
        }
        g.fill(DemoShape.round(152, 28, 30, 60, 7), with: .color(Ink.navy))
        g.fill(DemoShape.round(154, 30, 26, 56, 5.5), with: .linearGradient(Gradient(colors: [Ink.violet0, Ink.coral]),
                                                                           startPoint: CGPoint(x: 152, y: 28), endPoint: CGPoint(x: 182, y: 88)))
        g.fill(DemoShape.round(162, 33, 10, 3, 1.5), with: .color(.demo(0x0B0B10)))
        let b = charging(t)
        if b > 0.01 {
            var c = g
            c.translateBy(x: 167, y: 58)
            c.fill(OutPanel.bolt(b), with: .color(Ink.sun))
        }
    }

    // MARK: 浮在最上層

    private static func onTopL(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        let wx = Track(-60, [(0.4, 0, .glide), (2.6, -60, .glide)])(t)
        InPanel.stroke(g, DemoShape.round(70, 30, 96, 66, 7), p.line2)
        let front = DemoShape.round(34 + wx, 22, 96, 66, 7)
        g.fill(front, with: .color(p.inBg))
        InPanel.stroke(g, front, p.line)
        for k in 0..<3 { InPanel.stroke(g, DemoShape.circle(44 + wx + Double(k) * 7, 30, 2), p.line, 1.4) }
        g.fill(DemoShape.round(118, 58, 22, 22, 6), with: .color(p.dot))
    }
    private static func onTopR(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        OutPanel.background(g, p); OutPanel.desktop(g, p)
        let wx = Track(-110, [(0.4, 0, .glide), (2.6, -110, .glide)])(t)
        OutPanel.window(g, 40 + wx, 18, 104, 76); OutPanel.sun(g, 176, 22, 6)
        FlatHome(x: 136, y: 102, S: 44, yaw: -10 * deg, blink: M.blink(t, at: 3.6)).draw(g, p)
    }

    // MARK: 跟著房間的光

    private static let dayPhase = Track(0, [(0.5, 1, .walk), (2.6, 2, .walk), (4.3, 0, .walk)])
    private static func lightL(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        let ph = dayPhase(t)
        InPanel.stroke(g, DemoShape.line([DemoShape.pt(24, 96), DemoShape.pt(176, 96)]), p.line)
        g.stroke(Path { q in q.addArc(center: CGPoint(x: 100, y: 96), radius: 62, startAngle: .radians(.pi), endAngle: .zero, clockwise: false) },
                 with: .color(p.line2), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [2, 5]))
        let a = Double.pi + 0.12 + M.clamp(ph / 1.2) * .pi * 0.76
        let sun = CGPoint(x: 100 + 62 * cos(a), y: 96 + 62 * sin(a))
        let sunA = M.clamp(1.5 - ph), moonA = M.clamp(ph - 1.2)
        if sunA > 0.01 {
            InPanel.stroke(g, DemoShape.circle(sun, 8), p.dot.opacity(sunA))
            InPanel.stroke(g, Path { q in
                for i in 0..<8 { let an = Double(i) * .pi / 4
                    q.move(to: CGPoint(x: sun.x + cos(an) * 12, y: sun.y + sin(an) * 12)); q.addLine(to: CGPoint(x: sun.x + cos(an) * 15, y: sun.y + sin(an) * 15)) }
            }, p.dot.opacity(sunA), 2)
        }
        if moonA > 0.01 {
            InPanel.stroke(g, Path { q in
                q.addArc(center: CGPoint(x: 70, y: 50), radius: 9, startAngle: .radians(0.35 * .pi), endAngle: .radians(1.65 * .pi), clockwise: false)
                q.addArc(center: CGPoint(x: 74, y: 46), radius: 7, startAngle: .radians(1.5 * .pi), endAngle: .radians(0.5 * .pi), clockwise: true)
            }, p.dot.opacity(moonA), 2.2)
        }
        InPanel.stroke(g, DemoShape.line([DemoShape.pt(150, 96), DemoShape.pt(150, 70)]), p.line)
        let shade = DemoShape.path([DemoShape.pt(140, 70), DemoShape.pt(160, 70), DemoShape.pt(155, 58), DemoShape.pt(145, 58)])
        if moonA > 0.01 { g.fill(shade, with: .color(Ink.sun.opacity(moonA))) }
        InPanel.stroke(g, shade, p.line)
    }

    private struct Room { var wall: [Double]; var sky0: [Double]; var sky1: [Double]; var tint: [Double]; var dim: Double }
    private static let rooms = [
        Room(wall: [226, 236, 248], sky0: [130, 191, 246], sky1: [214, 234, 255], tint: [255, 255, 255, 0], dim: 0),
        Room(wall: [255, 214, 170], sky0: [255, 120, 98], sky1: [255, 196, 120], tint: [255, 150, 80, 0.18], dim: 0.05),
        Room(wall: [44, 48, 86], sky0: [20, 26, 60], sky1: [70, 56, 130], tint: [255, 186, 120, 0.14], dim: 0.4)]
    private static func lightR(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        let ph = dayPhase(t)
        let i = min(1, Int(M.clamp(ph, 0, 1.999))), f = M.clamp(ph - Double(i))
        let A = rooms[i], B = rooms[i + 1]
        func mix(_ a: [Double], _ b: [Double]) -> [Double] { zip(a, b).map { M.lerp($0, $1, f) } }
        func rgb(_ c: [Double], _ a: Double = 1) -> Color { Color(.sRGB, red: c[0] / 255, green: c[1] / 255, blue: c[2] / 255, opacity: a) }
        let wall = mix(A.wall, B.wall), s0 = mix(A.sky0, B.sky0), s1 = mix(A.sky1, B.sky1), ti = mix(A.tint, B.tint)
        g.fill(Illus.full, with: .color(rgb(wall)))
        g.fill(Path(CGRect(x: 0, y: 100, width: Illus.W, height: 25)), with: .color(.black.opacity(0.08)))
        let win = DemoShape.round(126, 16, 56, 60, 6)
        do {
            var c = g
            c.clip(to: win)
            c.fill(win, with: .linearGradient(Gradient(colors: [rgb(s0), rgb(s1)]), startPoint: CGPoint(x: 0, y: 16), endPoint: CGPoint(x: 0, y: 76)))
            c.fill(DemoShape.circle(146 + 14 * M.clamp(ph), 34 + 30 * M.clamp(ph), 9), with: .color(.demo(0xFFE08A, M.clamp(1.4 - ph))))
            let moonA = M.clamp(ph - 1.3)
            if moonA > 0.01 {
                c.fill(DemoShape.circle(166, 30, 5), with: .color(.demo(0xF0F2FF, moonA)))
                c.fill(DemoShape.circle(168.5, 28.5, 4.3), with: .color(rgb(s0)))
            }
        }
        g.fill(Path(CGRect(x: 153, y: 16, width: 2, height: 60)), with: .color(.white.opacity(0.75)))
        let night = M.clamp(ph - 1)
        g.fill(Path(CGRect(x: 30, y: 70, width: 3, height: 30)), with: .color(Ink.navy))
        g.fill(DemoShape.path([DemoShape.pt(20, 70), DemoShape.pt(43, 70), DemoShape.pt(38, 56), DemoShape.pt(25, 56)]), with: .color(night > 0.01 ? Ink.sun : .white))
        if night > 0.01 {
            g.fill(Illus.full, with: .radialGradient(Gradient(colors: [Ink.sun.opacity(0.45 * night), Ink.sun.opacity(0)]),
                                                     center: CGPoint(x: 31, y: 72), startRadius: 0, endRadius: 70))
        }
        FlatHome(x: 86, y: 104, S: 58, yaw: 8 * deg, blink: M.blink(t, at: 4.8), dim: M.lerp(A.dim, B.dim, f),
                 tint: ti[3] > 0.005 ? rgb(ti, ti[3]) : nil, room: true).draw(g, p)
    }
}
