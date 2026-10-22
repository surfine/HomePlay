import AppKit
import SwiftUI

// 設定插畫的共用畫具。規格以 docs/design-drafts/設定動畫設計稿.html（第二版：插畫）為準：
// 版式借系統設定「觸控式軌跡板／滑鼠」——左格線稿輸入、右格平塗結果；HomeView 照 apple-homeview.usdz 的比例抽象化。
// 每格邏輯畫布 200 × 125，時間單位是秒；改這裡要同步改稿。

// MARK: - 彈簧與軌道

enum DemoSpring {
    case calm, settle, glide, bloom, pop, walk

    var response: Double {
        switch self {
        case .calm: return 0.34
        case .settle: return 0.38
        case .glide, .bloom: return 0.42
        case .pop: return 0.30
        case .walk: return 1.4
        }
    }
    var damping: Double {
        switch self {
        case .calm, .settle, .walk: return 1
        case .glide: return 0.88
        case .bloom: return 0.84
        case .pop: return 0.75
        }
    }
    /// 0→1 的階躍響應（WWDC23「Animate with springs」：ω₀ = 2π/response）
    func step(_ tau: Double) -> Double {
        guard tau > 0 else { return 0 }
        let w = 2 * Double.pi / response, z = damping
        if z >= 1 { return 1 - exp(-w * tau) * (1 + w * tau) }
        let wd = w * (1 - z * z).squareRoot()
        return 1 - exp(-z * w * tau) * (cos(wd * tau) + (z * w / wd) * sin(wd * tau))
    }
}

/// 關鍵幀軌道：每換一次目標疊一段階躍響應，起點速度為 0，換目標不頓。
struct Track {
    let start: Double
    let keys: [(Double, Double, DemoSpring)]
    init(_ start: Double, _ keys: [(Double, Double, DemoSpring)]) { self.start = start; self.keys = keys }
    func callAsFunction(_ t: Double) -> Double {
        var v = start, prev = start
        for (tk, vk, s) in keys { v += (vk - prev) * s.step(t - tk); prev = vk }
        return v
    }
}

enum DemoMath {
    static let deg = Double.pi / 180
    static func clamp(_ x: Double, _ a: Double = 0, _ b: Double = 1) -> Double { min(b, max(a, x)) }
    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    static func outCubic(_ x: Double) -> Double { 1 - pow(1 - clamp(x), 3) }
    static func presence(_ t: Double, _ a: Double, _ b: Double) -> Double {
        clamp(DemoSpring.calm.step(t - a) - DemoSpring.calm.step(t - b))
    }
    static func blink(_ t: Double, at: Double) -> Double {
        let x = (t - at) / 0.16
        return x > 0 && x < 1 ? sin(.pi * x) : 0
    }
    /// App 的 Aim（與 Aim.swift 同參數）數值積分到 t。follow：死區 3°、回應 0.5 s；否則回應 1.2 s。限速 70°/s。
    static func aim(at t: Double, follow: Bool, target: (Double) -> Double) -> Double {
        let dt = 1.0 / 120, w = 2 * Double.pi / (follow ? Aim.followResponse : Aim.returnResponse)
        var a = target(0), v = 0.0, held = a, s = 0.0
        while s < t {
            var tg = target(s)
            if follow, abs(tg - held) < Aim.deadZone { tg = held }
            held = tg
            v += ((tg - a) * w * w - v * 2 * w) * dt
            v = min(Aim.maxSpeed, max(-Aim.maxSpeed, v))
            a += v * dt
            s += dt
        }
        return a
    }
}

// MARK: - 色票

extension Color {
    static func demo(_ rgb: UInt32, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
              blue: Double(rgb & 0xFF) / 255, opacity: alpha)
    }
}

/// 平塗色（兩種外觀共用）
enum Ink {
    static let coral = Color.demo(0xFF4E62), violet0 = Color.demo(0x8B7BF7), violet1 = Color.demo(0x5E54E0)
    static let sun = Color.demo(0xFFC23D), mint = Color.demo(0x34C795), navy = Color.demo(0x1E3A8A), sky = Color.demo(0x4C9BFF)
    static let frame = Color.white, frameEdge = Color.demo(0xD3D3D9), side = Color.demo(0xD9D9DF), bezel = Color.demo(0x131316)
    static let base = Color.demo(0xE5E5EA), baseDark = Color.demo(0xCBCBD2), baseLight = Color.demo(0xF2F2F5), dots = Color.demo(0xA8A8B2)
}

struct IllusPalette {
    let dark: Bool
    var inBg: Color { dark ? .demo(0x2B2B2E) : .demo(0xF4F4F6) }
    var line: Color { dark ? .demo(0x5E5E64) : .demo(0xC3C3C8) }
    var line2: Color { dark ? .demo(0x46464B) : .demo(0xDADADF) }
    var dot: Color { dark ? .demo(0x4A8BFF) : .demo(0x3B7CF5) }
    var out0: Color { dark ? .demo(0x33629F) : .demo(0x82BFF6) }
    var out1: Color { dark ? .demo(0x244C85) : .demo(0x5AA2EE) }
    var shadow: Color { dark ? .demo(0x000818, 0.35) : .demo(0x0A2A5A, 0.20) }
    var deco: Color { .white.opacity(dark ? 0.10 : 0.22) }
    var menubar: Color { .white.opacity(dark ? 0.22 : 0.55) }
}

// MARK: - 畫布

enum Illus {
    static let W = 200.0, H = 125.0
    static let full = Path(CGRect(x: 0, y: 0, width: 200, height: 125))
}

/// 一格插畫：把 200 × 125 的邏輯畫布放進 Canvas（外框固定 1.6 : 1）。
struct IllusCanvas: View {
    let t: Double
    let draw: (GraphicsContext, IllusPalette, Double) -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Canvas { g, size in
            var c = g
            c.scaleBy(x: size.width / Illus.W, y: size.height / Illus.H)
            draw(c, IllusPalette(dark: scheme == .dark), t)
        }
    }
}

// MARK: - 形狀

enum DemoShape {
    /// 方圓角輪廓（角是 r·(cos^½, sin^½) 的超橢圓）
    static func squircle(half: Double, r: Double, n: Int = 10) -> [(Double, Double)] {
        var pts: [(Double, Double)] = []
        let corners: [(Double, Double)] = [(1, 1), (-1, 1), (-1, -1), (1, -1)]
        for c in 0..<4 {
            let cx = corners[c].0 * (half - r), cy = corners[c].1 * (half - r)
            for i in 0...n {
                let a = (Double(c) * 90 + 90 * Double(i) / Double(n)) * DemoMath.deg
                let ca = cos(a), sa = sin(a)
                pts.append((cx + r * (ca < 0 ? -1 : 1) * abs(ca).squareRoot(), cy + r * (sa < 0 ? -1 : 1) * abs(sa).squareRoot()))
            }
        }
        return pts
    }
    static let frame = squircle(half: 0.5, r: 0.19)
    static let bezel = squircle(half: 0.465, r: 0.165)
    static let display = squircle(half: 0.43, r: 0.13)

    static func path(_ pts: [CGPoint]) -> Path {
        Path { p in guard let f = pts.first else { return }; p.move(to: f); for q in pts.dropFirst() { p.addLine(to: q) }; p.closeSubpath() }
    }
    static func line(_ pts: [CGPoint]) -> Path {
        Path { p in guard let f = pts.first else { return }; p.move(to: f); for q in pts.dropFirst() { p.addLine(to: q) } }
    }
    static func ellipse(_ c: CGPoint, _ rx: Double, _ ry: Double) -> Path {
        Path(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry, width: rx * 2, height: ry * 2))
    }
    static func circle(_ c: CGPoint, _ r: Double) -> Path { ellipse(c, r, r) }
    static func circle(_ x: Double, _ y: Double, _ r: Double) -> Path { ellipse(CGPoint(x: x, y: y), r, r) }
    static func round(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r, style: .continuous)
    }
    /// 橢圓弧（畫布角度：y 朝下，所以 0…π 是下半）
    static func arc(_ c: CGPoint, _ rx: Double, _ ry: Double, from a0: Double, to a1: Double, steps: Int = 32) -> Path {
        Path { p in
            for i in 0...steps {
                let a = a0 + (a1 - a0) * Double(i) / Double(steps)
                let q = CGPoint(x: c.x + rx * cos(a), y: c.y + ry * sin(a))
                i == 0 ? p.move(to: q) : p.addLine(to: q)
            }
        }
    }
    static func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }
}

// MARK: - HomeView（平塗；螢幕寬 = 1，比例照 USDZ）

/// 螢幕後仰 19°、鉸鏈 (y 0.23, z 0.40)；底座圓柱半徑 0.29、高 0.62；俯角 6°、透視距離 6。
struct HomeProjection {
    static let elevation = 6 * DemoMath.deg, distance = 6.0, tilt = 19 * DemoMath.deg
    static let hinge = (y: 0.23, z: 0.40), baseRadius = 0.29, baseHeight = 0.62
    let ox: Double, oy: Double, S: Double, cy: Double, sy: Double
    init(x: Double, y: Double, S: Double, yaw: Double) { ox = x; oy = y; self.S = S; cy = cos(yaw); sy = sin(yaw) }
    func callAsFunction(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
        let ce = cos(Self.elevation), se = sin(Self.elevation)
        let x1 = x * cy + z * sy, z1 = -x * sy + z * cy
        let y2 = y * ce - z1 * se, z2 = z1 * ce + y * se
        let k = Self.distance / (Self.distance - z2)
        return CGPoint(x: ox + x1 * k * S, y: oy - y2 * k * S)
    }
    func screen(_ u: Double, _ v: Double, _ w: Double = 0) -> CGPoint {
        let ly = v + 0.5, ct = cos(Self.tilt), st = sin(Self.tilt)
        return self(u, Self.hinge.y + ly * ct + w * st, Self.hinge.z - ly * st + w * ct)
    }
}

struct FlatHome {
    var x: Double, y: Double, S: Double
    var scale = 1.0
    var yaw = 0.0
    var reveal = 0.0          // CarPlay 從島中心揭開：0 錶面 … 1 CarPlay
    var look = CGPoint.zero   // 瞳孔方向 -1…1
    var blink = 0.0
    var camOn = false
    var phase = 0.0           // CarPlay 路線進度（跟週期對齊）
    var dim = 0.0
    var tint: Color? = nil
    var room = false          // 房間裡：影子用中性黑

    struct Anchors { var eyes: CGPoint; var ground: CGPoint; var top: CGPoint }

    @discardableResult
    func draw(_ g: GraphicsContext, _ pal: IllusPalette) -> Anchors {
        let S = self.S * scale
        let pr = HomeProjection(x: x, y: y, S: S, yaw: yaw)
        let ground = pr(0, 0, 0)
        // 影子：平塗橢圓
        g.fill(DemoShape.ellipse(ground, 0.5 * S, 0.075 * S), with: .color(room ? .black.opacity(0.14) : pal.shadow))
        // 底座：三階色帶＋半色調網點（跟著轉）
        let R = HomeProjection.baseRadius, top = pr(0, HomeProjection.baseHeight, 0)
        let rx = R * S, ry = R * sin(HomeProjection.elevation) * S
        let base = Path { p in
            p.move(to: CGPoint(x: top.x - rx, y: top.y))
            p.addLine(to: CGPoint(x: ground.x - rx, y: ground.y))
            for i in 0...24 { let a = Double.pi - Double.pi * Double(i) / 24; p.addLine(to: CGPoint(x: ground.x + rx * cos(a), y: ground.y + ry * sin(a))) }
            p.addLine(to: CGPoint(x: top.x + rx, y: top.y))
            p.closeSubpath()
        }
        do {
            var c = g
            c.fill(base, with: .color(Ink.base))
            c.clip(to: base)
            let h = ground.y - top.y + ry + 4
            c.fill(Path(CGRect(x: ground.x - rx, y: top.y - 2, width: rx * 0.34, height: h)), with: .color(Ink.baseDark))
            c.fill(Path(CGRect(x: ground.x - rx * 0.42, y: top.y - 2, width: rx * 0.36, height: h)), with: .color(Ink.baseLight))
            var dots = Path()
            for j in 0..<14 {
                let yy = 0.035 + Double(j) * 0.042
                for a in stride(from: Double(j % 2) * 7.5, to: 360, by: 15) {
                    let ang = a * DemoMath.deg, cv = cos(ang + yaw)
                    guard cv > 0.12 else { continue }
                    let p = pr(R * sin(ang), yy, R * cos(ang)), r = 0.0105 * S * (0.35 + 0.65 * cv), w = r * (0.4 + 0.6 * cv)
                    dots.addEllipse(in: CGRect(x: p.x - w, y: p.y - r, width: w * 2, height: r * 2))
                }
            }
            c.fill(dots, with: .color(Ink.dots))
            if let tint { c.fill(base, with: .color(tint)) }
        }
        // 螢幕：背面 → 側面 → 外框 → 黑邊 → 顯示 → 鏡頭
        let back = DemoShape.frame.map { pr.screen($0.0, $0.1, -0.06) }
        let front = DemoShape.frame.map { pr.screen($0.0, $0.1) }
        g.fill(DemoShape.path(back), with: .color(Ink.side))
        g.fill(Path { p in
            for i in front.indices {
                let j = (i + 1) % front.count
                p.move(to: front[i]); p.addLine(to: front[j]); p.addLine(to: back[j]); p.addLine(to: back[i]); p.closeSubpath()
            }
        }, with: .color(Ink.side))
        let framePath = DemoShape.path(front)
        g.fill(framePath, with: .color(Ink.frame))
        if let tint { g.fill(framePath, with: .color(tint)) }
        g.stroke(framePath, with: .color(Ink.frameEdge), lineWidth: 0.6)
        g.fill(DemoShape.path(DemoShape.bezel.map { pr.screen($0.0, $0.1) }), with: .color(Ink.bezel))
        let TL = pr.screen(-0.43, 0.43), TR = pr.screen(0.43, 0.43), BL = pr.screen(-0.43, -0.43)
        do {
            var c = g
            c.clip(to: DemoShape.path(DemoShape.display.map { pr.screen($0.0, $0.1) }))
            c.concatenate(CGAffineTransform(a: (TR.x - TL.x) / 100, b: (TR.y - TL.y) / 100,
                                            c: (BL.x - TL.x) / 100, d: (BL.y - TL.y) / 100, tx: TL.x, ty: TL.y))
            HomeScreens.face(c, look: look, blink: blink)
            if reveal > 0.001 {
                var r = c
                r.clip(to: DemoShape.circle(50, 64, reveal * 80))
                HomeScreens.carPlay(r, phase: phase)
            }
            if dim > 0.001 { c.fill(Path(CGRect(x: 0, y: 0, width: 100, height: 100)), with: .color(.black.opacity(dim))) }
        }
        let cam = pr.screen(0, 0.482)
        g.fill(DemoShape.circle(cam, max(0.8, S * 0.011)), with: .color(camOn ? Ink.mint : .demo(0x2A2A2E)))
        return Anchors(eyes: pr.screen(0, -0.14), ground: ground, top: pr.screen(0, 0.5))
    }
}

/// 螢幕內容（局部 0…100，y 朝下）。錶面不寫字：兩個圓疊在深藍上＋島和眼睛。
enum HomeScreens {
    static func face(_ c: GraphicsContext, look: CGPoint, blink: Double) {
        let full = Path(CGRect(x: 0, y: 0, width: 100, height: 100))
        c.fill(full, with: .linearGradient(Gradient(colors: [.demo(0x3557C6), .demo(0x5B80E6)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: 100)))
        c.fill(DemoShape.circle(34, 36, 30), with: .linearGradient(Gradient(colors: [Ink.violet0, Ink.violet1]),
                                                                    startPoint: CGPoint(x: 10, y: 10), endPoint: CGPoint(x: 50, y: 60)))
        c.fill(DemoShape.circle(66, 25, 24), with: .color(Ink.coral.opacity(0.94)))
        c.fill(DemoShape.round(22, 54, 56, 21, 10.5), with: .color(.demo(0x0E1430, 0.85)))
        for dx in [-8.5, 8.5] {
            let e = CGPoint(x: 50 + dx, y: 64.5), eh = 7 * (1 - 0.9 * blink)
            let eye = DemoShape.ellipse(e, 5.4, eh)
            c.fill(eye, with: .color(.white))
            if blink < 0.7 {
                var ec = c; ec.clip(to: eye)
                ec.fill(DemoShape.circle(e.x + look.x * 1.9, e.y + 1 + look.y * 1.4, 3.6), with: .color(.demo(0x141414)))
            }
        }
        c.fill(DemoShape.round(38, 86, 24, 5, 2.5), with: .color(.white.opacity(0.35)))
    }

    static let route = [CGPoint(x: 32, y: 54), CGPoint(x: 49, y: 50), CGPoint(x: 52, y: 34), CGPoint(x: 73, y: 30), CGPoint(x: 89, y: 14)]
    static func along(_ f: Double) -> CGPoint {
        var lens: [Double] = [], total = 0.0
        for i in 1..<route.count { let d = hypot(route[i].x - route[i - 1].x, route[i].y - route[i - 1].y); lens.append(d); total += d }
        var s = f * total
        for i in lens.indices {
            if s <= lens[i] { let k = s / lens[i]; return CGPoint(x: DemoMath.lerp(route[i].x, route[i + 1].x, k), y: DemoMath.lerp(route[i].y, route[i + 1].y, k)) }
            s -= lens[i]
        }
        return route.last!
    }

    static func carPlay(_ c: GraphicsContext, phase: Double) {
        c.fill(Path(CGRect(x: 0, y: 0, width: 100, height: 100)), with: .color(.demo(0x0D1117)))
        c.fill(Path(CGRect(x: 0, y: 0, width: 20, height: 100)), with: .color(.demo(0x1A1F29)))
        for (k, col) in [Ink.mint, Ink.coral, Ink.sky].enumerated() { c.fill(DemoShape.round(4, 18 + Double(k) * 20, 12, 12, 3.5), with: .color(col)) }
        let card = DemoShape.round(25, 6, 70, 54, 6)
        c.fill(card, with: .color(.demo(0x22304A)))
        do {
            var m = c
            m.clip(to: card)
            for (a, b) in [((25.0, 24.0), (95.0, 32.0)), ((25, 47), (95, 41)), ((46, 6), (53, 60)), ((76, 6), (72, 60))] {
                m.stroke(DemoShape.line([DemoShape.pt(a.0, a.1), DemoShape.pt(b.0, b.1)]), with: .color(.demo(0x2E3D5C)), lineWidth: 3.4)
            }
            m.stroke(DemoShape.line(route), with: .color(Ink.sky), style: StrokeStyle(lineWidth: 3.4, lineCap: .round, lineJoin: .round))
            let at = along(phase.truncatingRemainder(dividingBy: 1))
            m.fill(DemoShape.circle(at, 3.4), with: .color(.white))
            m.fill(DemoShape.circle(at, 2), with: .color(Ink.sky))
        }
        c.fill(DemoShape.round(25, 65, 70, 29, 6), with: .color(.demo(0x1A1F29)))
        c.fill(DemoShape.round(29, 69, 21, 21, 4), with: .linearGradient(Gradient(colors: [Ink.violet0, Ink.coral]),
                                                                        startPoint: CGPoint(x: 29, y: 69), endPoint: CGPoint(x: 50, y: 90)))
        c.fill(DemoShape.round(55, 73, 30, 4, 2), with: .color(.white.opacity(0.85)))
        c.fill(DemoShape.round(55, 80, 20, 3.4, 1.7), with: .color(.white.opacity(0.4)))
    }
}

// MARK: - 左格：線稿與手指

enum InPanel {
    static let pad = CGRect(x: 42, y: 22, width: 116, height: 80)
    static func padPt(_ u: Double, _ v: Double) -> CGPoint { CGPoint(x: pad.minX + pad.width * u, y: pad.minY + pad.height * v) }

    static func background(_ g: GraphicsContext, _ pal: IllusPalette) { g.fill(Illus.full, with: .color(pal.inBg)) }
    static func stroke(_ g: GraphicsContext, _ p: Path, _ color: Color, _ w: Double = 2.4) {
        g.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
    }
    static func trackpad(_ g: GraphicsContext, _ pal: IllusPalette) {
        stroke(g, Path(roundedRect: pad, cornerRadius: 11, style: .continuous), pal.line)
    }
    /// 手指：實心藍點＋殘影（往回 10 個樣本 × 12 ms）；落下前 0.1 s 從稍大淡入，抬起後放大淡出
    static func finger(_ g: GraphicsContext, _ pal: IllusPalette, t: Double, down: Double, up: Double, scale: Double = 1,
                       _ pos: (Double) -> CGPoint) {
        let appear = DemoSpring.calm.step(t - (down - 0.1)), gone = DemoSpring.calm.step(t - up)
        let a = DemoMath.clamp(appear - gone)
        guard a > 0.01 else { return }
        let R = 6.6 * scale * (1.25 - 0.25 * DemoSpring.settle.step(t - (down - 0.1)) + 0.15 * gone)
        for k in stride(from: 10, through: 1, by: -1) {
            let s = t - Double(k) * 0.012
            guard s >= down, s <= up else { continue }
            g.fill(DemoShape.circle(pos(s), R * (1 - Double(k) * 0.025)), with: .color(pal.dot.opacity(0.20 * (1 - Double(k) / 11) * a)))
        }
        let p = pos(t)
        g.fill(DemoShape.circle(p, R * 1.35), with: .color(pal.dot.opacity(0.18 * a)))
        g.fill(DemoShape.circle(p, R), with: .color(pal.dot.opacity(a)))
    }
}

// MARK: - 右格：背景、點綴、桌面道具

enum OutPanel {
    static func background(_ g: GraphicsContext, _ pal: IllusPalette) {
        g.fill(Illus.full, with: .linearGradient(Gradient(colors: [pal.out0, pal.out1]), startPoint: .zero, endPoint: CGPoint(x: 0, y: Illus.H)))
    }
    static func halo(_ g: GraphicsContext, _ pal: IllusPalette, _ x: Double, _ y: Double, _ r: Double) { g.fill(DemoShape.circle(x, y, r), with: .color(pal.deco)) }
    static func sun(_ g: GraphicsContext, _ x: Double, _ y: Double, _ r: Double = 7) { g.fill(DemoShape.circle(x, y, r), with: .color(Ink.sun)) }
    static func half(_ g: GraphicsContext, _ x: Double, _ y: Double, _ r: Double, _ color: Color = Ink.coral) {
        g.fill(Path { p in p.addArc(center: CGPoint(x: x, y: y), radius: r, startAngle: .radians(.pi), endAngle: .zero, clockwise: false); p.closeSubpath() },
               with: .color(color))
    }
    static func dots(_ g: GraphicsContext, _ x: Double, _ y: Double, cols: Int = 4, rows: Int = 3, gap: Double = 6) {
        var p = Path()
        for i in 0..<cols { for j in 0..<rows { p.addEllipse(in: CGRect(x: x + Double(i) * gap - 1.2, y: y + Double(j) * gap - 1.2, width: 2.4, height: 2.4)) } }
        g.fill(p, with: .color(.white.opacity(0.55)))
    }
    static func zig(_ g: GraphicsContext, _ x: Double, _ y: Double, n: Int = 5, w: Double = 5, h: Double = 4) {
        InPanel.stroke(g, DemoShape.line((0...n).map { CGPoint(x: x + Double($0) * w, y: y + ($0 % 2 == 1 ? -h : 0)) }), .white.opacity(0.7), 1.8)
    }
    static func desktop(_ g: GraphicsContext, _ pal: IllusPalette, dock: Bool = true) {
        g.fill(Path(CGRect(x: 0, y: 0, width: Illus.W, height: 7)), with: .color(pal.menubar))
        guard dock else { return }
        g.fill(DemoShape.round(Illus.W / 2 - 42, Illus.H - 14, 84, 10, 4), with: .color(.white.opacity(0.45)))
        for (i, col) in [Ink.sky, Ink.sun, Ink.coral, Ink.mint, Ink.violet0, .white].enumerated() {
            g.fill(DemoShape.round(Illus.W / 2 - 38 + Double(i) * 13, Illus.H - 12, 7, 7, 2), with: .color(col))
        }
    }
    static func window(_ g: GraphicsContext, _ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        let shape = DemoShape.round(x, y, w, h, 5)
        g.fill(shape, with: .color(.white))
        var c = g
        c.clip(to: shape)
        c.fill(Path(CGRect(x: x, y: y + 9, width: w * 0.28, height: h - 9)), with: .color(.demo(0xE9EEF6)))
        c.fill(Path(CGRect(x: x, y: y, width: w, height: 9)), with: .color(.demo(0xE9EEF6)))
        for (k, col) in [Ink.coral, Ink.sun, Ink.mint].enumerated() { c.fill(DemoShape.circle(x + 6 + Double(k) * 5.5, y + 4.5, 1.8), with: .color(col)) }
        for i in 0..<4 { c.fill(DemoShape.round(x + w * 0.34, y + 15 + Double(i) * 8, w * 0.56 - Double(i % 2) * 12, 3.4, 1.7), with: .color(.demo(0xD7E0EE))) }
    }
    static func person(_ g: GraphicsContext, _ x: Double, _ y: Double, _ s: Double) {
        half(g, x, y + 14 * s, 17 * s, Ink.navy)
        g.fill(DemoShape.circle(x, y - 6 * s, 9 * s), with: .color(Ink.coral))
    }
    /// 閃電
    static func bolt(_ s: Double) -> Path {
        DemoShape.path([DemoShape.pt(2 * s, -9 * s), DemoShape.pt(-5.5 * s, 2 * s), DemoShape.pt(-0.5 * s, 2 * s),
                        DemoShape.pt(-2 * s, 9 * s), DemoShape.pt(5.5 * s, -2 * s), DemoShape.pt(0.5 * s, -2 * s)])
    }
}
