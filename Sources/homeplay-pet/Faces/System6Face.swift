// 錶面「System 6」（Finder）：1988 年 Macintosh System 6 的預設桌面，原生 1-bit（256 點的格子，×4 最近鄰放大）。
// 50% 網點桌布、Chicago 選單列（左上是 1-bit 👀，不是蘋果標誌）、條紋標題列的「HomePlay」視窗、
// 右上硬碟「HomePlay HD」、右下垃圾桶；膠囊是一顆預設按鈕。共用零件在 System6Series.swift。
// 介面一律英文：System 6 沒有中文介面。

import AppKit

nonisolated(unsafe) private var finderCache: (key: String, image: CGImage)?

extension Face {
    func renderSystem6Face(_ g: CGContext, _ now: Double) {
        let date = Self.displayDate
        let time = Self.clock(date), dl = Self.enFormatter("EEEE, MMMM d, yyyy").string(from: date)
        let timer = sys6TimerText
        let wx = 14, wy = 34, ww = 164, wh = 184
        let near = reveal > 0.5   // 有人靠近時，視窗底下多一行說明：點一下會打開網站（不是隱藏行為）
        let key = "finder|\(time)|\(dl)|\(timer ?? "")|\(near)"
        let img: CGImage
        if let c = finderCache, c.key == key { img = c.image }
        else {
            let b = Bit1(256, 256)
            b.desktop(); b.menubar(["File", "Edit", "View", "Special"])
            // 桌面圖示：右上硬碟、右下垃圾桶；標籤白底（離圓角留距離）
            let ix = 212, g9 = Sys6Art.geneva(9)
            func label(_ s: String, _ cx: Int, _ base: Int) {
                let w = b.width(s, g9)
                b.fill(cx - w / 2 - 2, base - 9, w + 4, 12, false)
                b.text(s, cx - w / 2, base, g9)
            }
            b.bitmap(Sys6Art.hd, ix - 16, 32); label("HomePlay HD", ix, 57)
            b.bitmap(Sys6Art.trash, ix - 8, 196); label("Trash", ix, 226)
            b.window(wx, wy, ww, wh, title: "HomePlay")
            var top = wy + 19
            if let timer {   // Finder 視窗標題下的資訊列：計時器在跑時才出現
                b.text(timer, wx + ww / 2, top + 11, g9, align: 0)
                b.fill(wx + 1, top + 14, ww - 2, 1); b.fill(wx + 1, top + 16, ww - 2, 1)
                top += 10
            }
            let cx = wx + ww / 2
            let tf = Sys6Art.chicago(min(46, 46 * 140 / CGFloat(max(1, b.width(time, Sys6Art.chicago(46))))))
            b.text(time, cx, top + 60, tf, align: 0)
            b.text(dl, cx, top + 80, Sys6Art.geneva(b.width(dl, Sys6Art.geneva(12)) > ww - 12 ? 9 : 12), align: 0)
            if near { b.text("Click to visit system6.aaronlau.me", cx, wy + wh - 6, Sys6Art.geneva(9), align: 0) }
            img = b.finish()
            finderCache = (key, img)
        }
        g.setFillColor(NSColor.black.cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        blit1(g, img, x: 0, y: 0, pixel: 4)
        drawPixelButton(g, x: wx + ww / 2 - 42, y: wy + wh - 50, w: 84, h: 30, pixel: 4, now: now)
    }
    /// 計時器的秒與分鐘變化由全局 tickLive 處理；這裡沒有自己的動畫
    func tickSystem6Face(_ now: Double) -> Bool { false }
}
