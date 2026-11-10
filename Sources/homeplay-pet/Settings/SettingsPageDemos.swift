import SwiftUI

// 家庭、ClioTalk、家人、iPhone 與 iPad 四頁的頁首插畫：左格線稿畫「你做什麼」，右格平塗畫「桌寵怎麼回應」。
// 取代原本整段的文字說明（家庭頁的三步教學改成這段捷徑示意）。畫具在 DemoKit.swift，t 是秒。

private typealias M = DemoMath

enum PageDemo {

    // MARK: 家庭：打開捷徑 → 加「控制家庭」→ 取名填進來 → 桌寵叫得動燈

    static func shortcutL(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        let win = DemoShape.round(32, 10, 136, 104, 9)
        InPanel.stroke(g, win, p.line)
        InPanel.stroke(g, DemoShape.line([DemoShape.pt(32, 26), DemoShape.pt(168, 26)]), p.line2, 1.6)
        for k in 0..<3 { InPanel.stroke(g, DemoShape.circle(42 + Double(k) * 7, 18, 2), p.line, 1.4) }
        // ① 按「＋」
        let plus = CGPoint(x: 156, y: 18)
        InPanel.stroke(g, Path { q in q.move(to: CGPoint(x: plus.x - 4, y: plus.y)); q.addLine(to: CGPoint(x: plus.x + 4, y: plus.y))
                                      q.move(to: CGPoint(x: plus.x, y: plus.y - 4)); q.addLine(to: CGPoint(x: plus.x, y: plus.y + 4)) }, p.line, 2)
        // ② 「控制家庭」動作滑進來
        let a = DemoSpring.bloom.step(t - 1.3) - DemoSpring.calm.step(t - 6.0)
        if a > 0.01 {
            var c = g
            c.opacity = M.clamp(a)
            c.translateBy(x: 0, y: 10 * (1 - M.clamp(a)))
            let block = DemoShape.round(44, 36, 112, 26, 7)
            c.fill(block, with: .color(p.dot.opacity(0.14)))
            InPanel.stroke(c, block, p.dot, 2)
            c.draw(Text(Image(systemName: "house.fill")).font(.system(size: 11, weight: .semibold)).foregroundColor(p.dot), at: CGPoint(x: 58, y: 49))
            c.draw(Text(L("settings.home.demo.action", "控制家庭")).font(.system(size: 10, weight: .semibold)).foregroundColor(p.dot),
                   at: CGPoint(x: 70, y: 49), anchor: .leading)
        }
        // ③ 取名：一個字一個字打進來
        let field = DemoShape.round(44, 76, 112, 22, 6)
        InPanel.stroke(g, field, p.line, 2)
        let name = L("settings.home.demo.name", "回家")
        let typed = Int(M.clamp((t - 3.1) / 0.9) * Double(name.count) + 0.0001)
        let shown = t > 6.1 ? "" : String(name.prefix(typed))
        if !shown.isEmpty {
            g.draw(Text(shown).font(.system(size: 11, weight: .medium)).foregroundColor(p.dark ? .white : .black), at: CGPoint(x: 52, y: 87), anchor: .leading)
        }
        if t > 2.9, t < 6.1, Int(t * 2.5) % 2 == 0 {   // 游標閃
            let x = 52 + Double(shown.count) * 11.5
            g.fill(Path(CGRect(x: x, y: 81, width: 1.4, height: 12)), with: .color(p.dot))
        }
        // 游標：先去按「＋」，再去點名稱欄
        let pos = Track(0, [(0.3, 1, .glide), (2.4, 2, .glide), (5.6, 0, .calm)])
        GestureDemo.pointer(g, p, .mouse, t, down: 0.95, up: 1.15) { s in
            let v = pos(s)
            let p0 = CGPoint(x: 120, y: 104), p1 = CGPoint(x: plus.x + 1, y: plus.y + 1), p2 = CGPoint(x: 140, y: 88)
            return v < 1 ? CGPoint(x: M.lerp(p0.x, p1.x, v), y: M.lerp(p0.y, p1.y, v))
                         : CGPoint(x: M.lerp(p1.x, p2.x, min(1, v - 1)), y: M.lerp(p1.y, p2.y, min(1, v - 1)))
        }
    }

    static func shortcutR(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        OutPanel.background(g, p); OutPanel.dots(g, 16, 16)
        let on = M.clamp(DemoSpring.bloom.step(t - 4.3) - DemoSpring.calm.step(t - 6.0))
        if on > 0.01 {
            g.fill(Illus.full, with: .radialGradient(Gradient(colors: [Ink.sun.opacity(0.5 * on), Ink.sun.opacity(0)]),
                                                     center: CGPoint(x: 160, y: 46), startRadius: 0, endRadius: 80))
        }
        // 落地燈
        g.fill(Path(CGRect(x: 159, y: 50, width: 3, height: 56)), with: .color(Ink.navy))
        g.fill(DemoShape.round(150, 104, 21, 4, 2), with: .color(Ink.navy))
        let shade = DemoShape.path([DemoShape.pt(146, 50), DemoShape.pt(175, 50), DemoShape.pt(168, 30), DemoShape.pt(153, 30)])
        g.fill(shade, with: .color(.white))
        if on > 0.01 { g.fill(shade, with: .color(Ink.sun.opacity(on))) }
        // 桌寵：螢幕上跳出「回家」那張卡
        FlatHome(x: 82, y: 104, S: 58, yaw: 10 * DemoMath.deg, screen: { c in
            HomeScreens.home(c)
            let k = M.clamp(DemoSpring.pop.step(t - 4.1) - DemoSpring.calm.step(t - 5.9))
            if k > 0.01 {
                var a = c
                a.opacity = k
                a.translateBy(x: 50, y: 50); a.scaleBy(x: 0.8 + 0.2 * k, y: 0.8 + 0.2 * k); a.translateBy(x: -50, y: -50)
                a.fill(DemoShape.round(14, 34, 72, 30, 9), with: .color(.white))
                a.fill(DemoShape.round(20, 40, 18, 18, 5), with: .color(Ink.sun))
                a.fill(DemoShape.round(43, 43, 34, 4.5, 2.2), with: .color(.demo(0x1C1C1E)))
                a.fill(DemoShape.round(43, 51, 22, 3.6, 1.8), with: .color(.demo(0xB8BFCC)))
            }
        }).draw(g, p)
    }

    // MARK: ClioTalk：按住 F5 說話 → 桌寵回答

    static func clioL(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        let held = M.presence(t, 0.5, 2.2)
        GestureDemo.keycap(g, p, CGPoint(x: 74, y: 64), "F5", pressed: held, width: 40)
        InPanel.finger(g, p, t: t, down: 0.45, up: 2.2) { _ in CGPoint(x: 74, y: 62) }
        // 說話的聲波：按著的時候跳
        for n in 0..<5 {
            let x = 112 + Double(n) * 9
            let h = 4 + 16 * held * (0.5 + 0.5 * sin(t * 11 + Double(n) * 1.3)) * (n == 2 ? 1 : n % 2 == 0 ? 0.55 : 0.8)
            g.fill(DemoShape.round(x, 64 - h / 2, 4, h, 2), with: .color((held > 0.05 ? p.dot : p.line).opacity(0.4 + 0.6 * held)))
        }
    }

    static func clioR(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        OutPanel.background(g, p); OutPanel.sun(g, 24, 24, 6); OutPanel.zig(g, 26, 104)
        let listening = M.presence(t, 0.55, 2.3)
        FlatHome(x: 66, y: 106, S: 56, yaw: -12 * DemoMath.deg, look: CGPoint(x: 0.8, y: -0.2), blink: M.blink(t, at: 3.9)).draw(g, p)
        let b = M.clamp(DemoSpring.bloom.step(t - 0.55) - DemoSpring.calm.step(t - 4.8), 0, 1.1)
        guard b > 0.01 else { return }
        var c = g
        c.opacity = M.clamp(b)
        c.translateBy(x: 112, y: 64); c.scaleBy(x: b, y: b); c.translateBy(x: -112, y: -64)
        let bubble = DemoShape.round(108, 22, 78, 50, 12)
        c.fill(bubble, with: .color(.white))
        c.fill(DemoShape.path([DemoShape.pt(112, 60), DemoShape.pt(102, 74), DemoShape.pt(122, 66)]), with: .color(.white))
        if listening > 0.05 {   // 聽的時候三個點
            for n in 0..<3 {
                let a = 0.35 + 0.65 * (0.5 + 0.5 * sin(t * 7 - Double(n) * 0.9))
                c.fill(DemoShape.circle(134 + Double(n) * 13, 47, 3.6), with: .color(Ink.sky.opacity(a * listening)))
            }
        }
        let answer = M.clamp((t - 2.3) / 0.9)   // 回答一行一行出來
        for n in 0..<3 where answer > Double(n) / 3 {
            let w = [58.0, 46, 30][n] * M.clamp(answer * 3 - Double(n))
            c.fill(DemoShape.round(118, 32 + Double(n) * 11, w, 5, 2.5), with: .color(n == 0 ? Ink.navy : .demo(0xB8BFCC)))
        }
    }

    // MARK: 家人：認出是你 → 你的那一份主畫面

    static func peopleL(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        InPanel.stroke(g, DemoShape.round(36, 14, 128, 98, 10), p.line)
        g.fill(DemoShape.circle(100, 20, 2.2), with: .color(Ink.mint))
        InPanel.stroke(g, DemoShape.circle(100, 58, 15), p.line)
        InPanel.stroke(g, Path { q in q.addArc(center: CGPoint(x: 100, y: 108), radius: 29, startAngle: .radians(.pi * 1.15), endAngle: .radians(.pi * 1.85), clockwise: false) }, p.line)
        // 取景框從寬收到臉上
        let k = Track(0, [(0.5, 1, .settle), (4.5, 0, .calm)])(t), b = 40 - 18 * k, L = 7.0
        let found = M.clamp(DemoSpring.pop.step(t - 1.3) - DemoSpring.calm.step(t - 4.5))
        let col = found > 0.5 ? Ink.mint : p.dot
        InPanel.stroke(g, Path { q in
            for (sx, sy) in [(-1.0, -1.0), (1, -1), (-1, 1), (1, 1)] {
                q.move(to: CGPoint(x: 100 + sx * b, y: 58 + sy * b - sy * L)); q.addLine(to: CGPoint(x: 100 + sx * b, y: 58 + sy * b))
                q.addLine(to: CGPoint(x: 100 + sx * b - sx * L, y: 58 + sy * b))
            }
        }, col, 2.2)
        if found > 0.01 {   // 認出：打勾
            var c = g
            c.opacity = M.clamp(found)
            c.fill(DemoShape.circle(134, 32, 9 * found), with: .color(Ink.mint))
            InPanel.stroke(c, DemoShape.line([DemoShape.pt(130, 32), DemoShape.pt(133, 35.5), DemoShape.pt(138.5, 28.5)]), .white, 2)
        }
    }

    static func peopleR(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        OutPanel.background(g, p); OutPanel.dots(g, 160, 16)
        let k = M.clamp(DemoSpring.settle.step(t - 1.4) - DemoSpring.calm.step(t - 4.5))
        FlatHome(x: 84, y: 104, S: 58, yaw: 12 * DemoMath.deg, screen: { c in
            HomeScreens.home(c, page: 1)
            if k < 0.99 {   // 認出之前：個人內容蓋著、上鎖
                var a = c
                a.opacity = 1 - k
                a.fill(Path(CGRect(x: 0, y: 0, width: 100, height: 100)), with: .color(.demo(0x0E1430, 0.72)))
                a.draw(Text(Image(systemName: "lock.fill")).font(.system(size: 22, weight: .semibold)).foregroundColor(.white), at: CGPoint(x: 50, y: 48))
            }
            if k > 0.01 {   // 你的頭像
                var a = c
                a.opacity = k
                a.fill(DemoShape.circle(82, 9, 6.5), with: .color(Ink.coral))
                a.fill(DemoShape.circle(82, 9, 3.2), with: .color(.white.opacity(0.85)))
            }
        }).draw(g, p)
        OutPanel.person(g, 164, 112, 0.85)
    }

    // MARK: iPhone 與 iPad：掃碼配對 → 同一個畫面出現在 iPad 上

    static func devicesL(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        let phone = DemoShape.round(76, 8, 48, 108, 10)
        InPanel.stroke(g, phone, p.line)
        g.fill(DemoShape.round(92, 12, 16, 4, 2), with: .color(p.line))
        // 取景框裡的 QR 碼
        let qr = CGRect(x: 84, y: 40, width: 32, height: 32)
        let pattern: [[Int]] = [[1,1,1,0,1,1,1],[1,0,1,0,0,0,1],[1,1,1,1,0,1,1],[0,1,0,1,1,0,0],[1,1,1,0,1,0,1],[1,0,1,1,0,1,0],[1,1,1,0,1,1,1]]
        var dots = Path()
        for (r, row) in pattern.enumerated() { for (cc, v) in row.enumerated() where v == 1 {
            dots.addRect(CGRect(x: qr.minX + Double(cc) * qr.width / 7, y: qr.minY + Double(r) * qr.height / 7, width: qr.width / 7 - 0.6, height: qr.height / 7 - 0.6))
        } }
        g.fill(dots, with: .color(p.line))
        let done = M.clamp(DemoSpring.pop.step(t - 1.9) - DemoSpring.calm.step(t - 5.1))
        let col = done > 0.5 ? Ink.mint : p.dot, b = 22.0, L = 6.0
        InPanel.stroke(g, Path { q in
            for (sx, sy) in [(-1.0, -1.0), (1, -1), (-1, 1), (1, 1)] {
                q.move(to: CGPoint(x: 100 + sx * b, y: 56 + sy * b - sy * L)); q.addLine(to: CGPoint(x: 100 + sx * b, y: 56 + sy * b))
                q.addLine(to: CGPoint(x: 100 + sx * b - sx * L, y: 56 + sy * b))
            }
        }, col, 2.2)
        let scan = M.presence(t, 0.4, 1.9)   // 掃描線
        if scan > 0.01 {
            let y = qr.minY - 4 + (qr.height + 8) * (0.5 - 0.5 * cos((t - 0.4) * 4.2))
            g.fill(Path(CGRect(x: qr.minX - 4, y: y, width: qr.width + 8, height: 1.6)), with: .color(p.dot.opacity(scan)))
        }
        if done > 0.01 {
            var c = g
            c.opacity = done
            c.fill(DemoShape.circle(100, 96, 8 * done), with: .color(Ink.mint))
            InPanel.stroke(c, DemoShape.line([DemoShape.pt(96.5, 96), DemoShape.pt(99.2, 99), DemoShape.pt(104, 93)]), .white, 2)
        }
    }

    static func devicesR(_ g: GraphicsContext, _ p: IllusPalette, _ t: Double) {
        OutPanel.background(g, p); OutPanel.sun(g, 24, 22, 6)
        FlatHome(x: 64, y: 104, S: 54, yaw: 14 * DemoMath.deg, blink: M.blink(t, at: 4.2)).draw(g, p)
        let on = M.clamp(DemoSpring.bloom.step(t - 2.0) - DemoSpring.calm.step(t - 5.2))
        for n in 0..<3 where on > 0.01 {   // 同一個 Wi‑Fi：弧線一直往 iPad 送
            let f = ((t * 0.9 - Double(n) * 0.33).truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
            InPanel.stroke(g, Path { q in q.addArc(center: CGPoint(x: 112, y: 62), radius: 6 + f * 14, startAngle: .radians(-.pi * 0.2), endAngle: .radians(.pi * 0.2), clockwise: false) },
                           .white.opacity(sin(.pi * f) * 0.85 * on), 2)
        }
        // iPad：同一個錶面從中間揭開
        let pad = CGRect(x: 134, y: 30, width: 52, height: 70)
        g.fill(DemoShape.round(pad.minX, pad.minY, pad.width, pad.height, 7), with: .color(Ink.navy))
        let scr = pad.insetBy(dx: 3.5, dy: 4)
        var c = g
        c.clip(to: DemoShape.round(scr.minX, scr.minY, scr.width, scr.height, 4))
        c.fill(Path(scr), with: .color(.demo(0x0B0B10)))
        if on > 0.01 {
            c.clip(to: DemoShape.circle(scr.midX, scr.midY, on * 46))
            c.translateBy(x: scr.minX, y: scr.minY + (scr.height - scr.width) / 2)
            c.scaleBy(x: scr.width / 100, y: scr.width / 100)
            c.fill(Path(CGRect(x: 0, y: -40, width: 100, height: 180)), with: .color(.demo(0x3557C6)))
            HomeScreens.face(c, look: CGPoint(x: -0.6, y: 0), blink: M.blink(t, at: 4.2))
        }
    }
}
