// 錶面「System 6」——照「HomePlay 屏幕介面稿」的 System6.dc.html 实现（640 稿 ×1.6）。
// 只在这个文件里写；1988 年 Macintosh System 6 的 1-bit 黑白语法。

import AppKit

/// 50% 点阵桌面：4px 方格的黑白棋盘，画一次缓存起来
private let system6Desktop: CGImage? = {
    let cs = CGColorSpaceCreateDeviceGray()
    guard let c = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    c.setFillColor(gray: 1, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    c.setFillColor(gray: 0, alpha: 1)
    for y in 0..<256 { for x in 0..<256 where (x + y) % 2 == 0 { c.fill(CGRect(x: x * 4, y: y * 4, width: 4, height: 4)) } }
    return c.makeImage()
}()

/// 字体：Chicago 系 → Geneva → Monaco → 等宽系统字；不合成粗体
private func system6Font(_ size: CGFloat) -> NSFont {
    for n in ["Chicago", "ChicagoFLF", "Geneva", "Monaco"] { if let f = NSFont(name: n, size: size) { return f } }
    return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
}

extension Face {
    func renderSystem6Face(_ g: CGContext, _ now: Double) {
        let K = NSColor.black, W = NSColor.white
        func rect(_ r: CGRect, _ c: NSColor) { g.setFillColor(c.cgColor); g.fill(r) }
        func frame(_ r: CGRect, _ w: CGFloat) {                       // 向内的描边
            rect(CGRect(x: r.minX, y: r.minY, width: r.width, height: w), K)
            rect(CGRect(x: r.minX, y: r.maxY - w, width: r.width, height: w), K)
            rect(CGRect(x: r.minX, y: r.minY, width: w, height: r.height), K)
            rect(CGRect(x: r.maxX - w, y: r.minY, width: w, height: r.height), K)
        }
        func width(_ s: String, _ f: NSFont, _ kern: CGFloat = 0) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: f]).width + kern * CGFloat(max(0, s.count - 1))
        }
        g.saveGState(); g.setShouldAntialias(false); g.setAllowsAntialiasing(true)
        if let d = system6Desktop { drawUpright(g, d, in: CGRect(x: 0, y: 0, width: 1024, height: 1024)) }
        else { rect(CGRect(x: 0, y: 0, width: 1024, height: 1024), W) }

        // 菜单栏：白底、2px 黑线；AI System 6 标志（方框里两条横杠，不是苹果）
        rect(CGRect(x: 0, y: 0, width: 1024, height: 64), W)
        rect(CGRect(x: 0, y: 62, width: 1024, height: 2), K)
        let mark = CGRect(x: 35, y: 15, width: 35, height: 35)
        frame(mark, 5)
        rect(CGRect(x: mark.minX + 5, y: mark.minY + 12, width: 25, height: 3), K)
        rect(CGRect(x: mark.minX + 5, y: mark.minY + 20, width: 25, height: 3), K)
        let mf = system6Font(29); var mx: CGFloat = 112
        for s in ["File", "Edit", "View", "Special"] { drawLeft(g, s, font: mf, x: mx, y: 42, color: K); mx += width(s, mf) + 42 }

        // 窗口：2px 边框、3px 硬阴影（×1.6≈5）
        let win = CGRect(x: 112, y: 166, width: 800, height: 608)
        rect(win.offsetBy(dx: 5, dy: 5), K)
        rect(win, W); frame(win, 3)
        // 标题栏：2px 黑白相间横纹、关闭框、白底标题板
        let tb = CGRect(x: win.minX + 3, y: win.minY + 3, width: win.width - 6, height: 51)
        rect(CGRect(x: tb.minX, y: tb.maxY - 3, width: tb.width, height: 3), K)
        var sy = tb.minY + 10
        while sy + 3 <= tb.maxY - 6 { rect(CGRect(x: tb.minX + 10, y: sy, width: tb.width - 20, height: 3), K); sy += 6 }
        let cb = CGRect(x: tb.minX + 22, y: tb.minY + 11, width: 29, height: 29)
        rect(cb, W); frame(cb, 3)
        let tf = system6Font(29), title = "HomePlay", tw = width(title, tf)
        rect(CGRect(x: 512 - tw / 2 - 22, y: tb.minY + 6, width: tw + 44, height: 38), W)
        drawLeft(g, title, font: tf, x: 512 - tw / 2, y: tb.minY + 34, color: K)

        // 内容：大时间 + 1-bit 岛 + 日期
        let date = Date()
        let tmf = system6Font(180), ts = Face.clock(date), tkern: CGFloat = -3
        let tsw = width(ts, tmf, tkern)
        drawLeft(g, ts, font: tmf, x: 512 - tsw / 2, y: 478, color: K, kern: tkern)
        let cap = CGRect(x: 512 - 176, y: 521, width: 352, height: 134)
        g.setFillColor(K.cgColor)
        g.addPath(CGPath(roundedRect: cap, cornerWidth: 67, cornerHeight: 67, transform: nil)); g.fillPath()
        let bf = blinkFactor(now), sep = cur.sep
        for s: CGFloat in [-1, 1] { drawEye(g, cx: cap.midX + s * sep, cy: cap.midY, side: s, blinkF: bf, k: 1.0) }
        let df = system6Font(27), dl = Face.dateLine(date)
        drawLeft(g, dl, font: df, x: 512 - width(dl, df) / 2, y: 704, color: K)

        // 窗口底栏：左「AI System 6」，右「單擊打開」；计时器在跑时右侧换成剩余时间（反白）
        let ft = CGRect(x: win.minX + 3, y: win.maxY - 51, width: win.width - 6, height: 48)
        rect(CGRect(x: ft.minX, y: ft.minY, width: ft.width, height: 3), K)
        let ff = system6Font(24), fy = ft.minY + 33
        drawLeft(g, "AI System 6", font: ff, x: ft.minX + 19, y: fy, color: K)
        if let end = timerEnd {
            let txt = L("timer.title", "计时器") + " " + timerClock(max(0, end - now)), w = width(txt, ff)
            rect(CGRect(x: ft.maxX - 19 - w - 16, y: ft.minY + 8, width: w + 32, height: 36), K)
            drawLeft(g, txt, font: ff, x: ft.maxX - 19 - w, y: fy, color: W)
        } else {
            let t = L("system6.open", "单击打开"); drawLeft(g, t, font: ff, x: ft.maxX - 19 - width(t, ff), y: fy, color: K)
        }

        // 桌面图标：Project Hard Disk
        let lf = system6Font(22), lt = "Project Hard Disk", lw = width(lt, lf)
        let ic = CGRect(x: 1024 - 48 - (lw + 20) / 2 - 38, y: 832, width: 77, height: 58)   // 文字板右缘留 48px
        rect(CGRect(x: ic.minX + 3, y: ic.minY + 10, width: 70, height: 42), W)
        frame(CGRect(x: ic.minX + 3, y: ic.minY + 10, width: 70, height: 42), 5)
        rect(CGRect(x: ic.minX + 13, y: ic.minY + 35, width: 16, height: 6), K)
        rect(CGRect(x: ic.midX - lw / 2 - 10, y: ic.maxY + 8, width: lw + 20, height: 30), W)
        drawLeft(g, lt, font: lf, x: ic.midX - lw / 2, y: ic.maxY + 31, color: K)
        g.restoreGState()
    }
    /// 有需要重画（秒针走动、轮替、漂动）就回 true；没有就回 false，省电
    /// 计时器的秒变化与分钟变化由全局 tickLive 已处理，这里没有自己的动画
    func tickSystem6Face(_ now: Double) -> Bool { false }
}
