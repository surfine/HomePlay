// AI System 6 系列（1988）：原生 1-bit。先在很小的畫布上逐點畫（256 或 128 個「Mac 點」見方），
// 門檻化成純黑白，再用最近鄰整數倍放大到 1024（256→×4、128→×8；貼圖 512 時也剛好是整數倍，網點不會起波紋）。
// 稿：docs/design-drafts/faces-v3/artifact/engine_tail.js（class Mac1、sys6(...)）與 template.html 的 System 6 表。
// 這裡放共用的 1-bit 畫布、點陣圖、預設按鈕膠囊與 1-bit 👀（drawPixelIsland），以及 Alarm Clock、About 兩款錶面
// 和連線時的「Welcome to HomePlay.」開機畫面。Finder 在 System6Face.swift。

import AppKit

// MARK: - 1-bit 畫布

/// 左上原點、不反鋸齒的小畫布；finish() 時門檻化成純黑白（透明處保持透明）
final class Bit1 {
    let w: Int, h: Int
    let ctx: CGContext
    init(_ w: Int, _ h: Int) {
        self.w = w; self.h = h
        ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        ctx.setShouldAntialias(false); ctx.setAllowsAntialiasing(false)
        ctx.setShouldSmoothFonts(false); ctx.setAllowsFontSmoothing(false)
        ctx.setShouldSubpixelPositionFonts(false); ctx.setShouldSubpixelQuantizeFonts(false)
        ctx.interpolationQuality = .none
    }
    /// 從快取的像素開始畫（靜態層）
    convenience init(_ w: Int, _ h: Int, pixels: Data) {
        self.init(w, h)
        if let p = ctx.data { _ = pixels.withUnsafeBytes { memcpy(p, $0.baseAddress!, min(pixels.count, w * h * 4)) } }
    }
    var pixels: Data { Data(bytes: ctx.data!, count: w * h * 4) }

    private func set(_ x: Int, _ y: Int, _ black: Bool) {
        guard x >= 0, y >= 0, x < w, y < h, let d = ctx.data else { return }
        let p = d.assumingMemoryBound(to: UInt8.self) + (y * w + x) * 4
        let v: UInt8 = black ? 0 : 255
        p[0] = v; p[1] = v; p[2] = v; p[3] = 255
    }
    func fill(_ x: Int, _ y: Int, _ ww: Int, _ hh: Int, _ black: Bool = true) {
        ctx.setFillColor(black ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: x, y: y, width: ww, height: hh))
    }
    /// 白底黑框（1 點）
    func box(_ x: Int, _ y: Int, _ ww: Int, _ hh: Int, fill white: Bool = true) {
        if white { fill(x, y, ww, hh, false) }
        fill(x, y, ww, 1); fill(x, y + hh - 1, ww, 1); fill(x, y, 1, hh); fill(x + ww - 1, y, 1, hh)
    }
    /// 50% 網點：黑白相間的點（以絕對座標排，跟別層對得上）
    func desktop(_ x0: Int = 0, _ y0: Int = 0, _ ww: Int? = nil, _ hh: Int? = nil) {
        for y in y0..<min(h, y0 + (hh ?? h)) { for x in x0..<min(w, x0 + (ww ?? w)) { set(x, y, (x + y) % 2 == 0) } }
    }
    /// 點陣圖：X 黑、. 白、: 50% 網點（依絕對座標）、空白透明
    func bitmap(_ rows: [String], _ x: Int, _ y: Int, _ s: Int = 1) {
        for (j, r) in rows.enumerated() {
            for (i, ch) in r.enumerated() {
                let px = x + i * s, py = y + j * s
                switch ch {
                case "X": fill(px, py, s, s, true)
                case ".", "o": fill(px, py, s, s, false)
                case ":": fill(px, py, s, s, (px / max(1, s) + py / max(1, s)) % 2 == 0)
                default: break
                }
            }
        }
    }
    /// 圓角矩形（填滿；不反鋸齒）
    func roundRect(_ x: Int, _ y: Int, _ ww: Int, _ hh: Int, _ r: Int, _ black: Bool) {
        let rr = CGFloat(min(r, min(ww, hh) / 2))
        ctx.setFillColor(black ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1))
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: ww, height: hh), cornerWidth: rr, cornerHeight: rr, transform: nil))
        ctx.fillPath()
    }
    /// 逐字排：每個字的步進取整數，像當年的點陣字（CoreText 的小數步進在不反鋸齒時會忽寬忽窄）
    private func glyphs(_ s: String, _ font: NSFont) -> (glyphs: [CGGlyph], x: [CGFloat], width: Int)? {
        let f = font as CTFont, chars = Array(s.utf16), n = chars.count
        var gl = [CGGlyph](repeating: 0, count: n)
        guard CTFontGetGlyphsForCharacters(f, chars, &gl, n) else { return nil }
        var adv = [CGSize](repeating: .zero, count: n)
        CTFontGetAdvancesForGlyphs(f, .horizontal, gl, &adv, n)
        var xs: [CGFloat] = [], x: CGFloat = 0
        for a in adv { xs.append(x); x += max(1, a.width.rounded()) }
        return (gl, xs, Int(x))
    }
    func width(_ s: String, _ font: NSFont) -> Int {
        if let g = glyphs(s, font) { return g.width }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font]))
        return Int(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)).rounded())
    }
    /// 黑字；y 是基線；align -1 左、0 中、1 右。回傳字寬
    @discardableResult
    func text(_ s: String, _ x: Int, _ y: Int, _ font: NSFont, align: Int = -1, white: Bool = false) -> Int {
        let wd = width(s, font)
        let x0 = align < 0 ? x : (align == 0 ? x - wd / 2 : x - wd)
        ctx.saveGState(); ctx.translateBy(x: CGFloat(x0), y: CGFloat(y)); ctx.scaleBy(x: 1, y: -1)
        if let g = glyphs(s, font) {
            ctx.setFillColor(CGColor(gray: white ? 1 : 0, alpha: 1))
            CTFontDrawGlyphs(font as CTFont, g.glyphs, g.x.map { CGPoint(x: $0, y: 0) }, g.glyphs.count, ctx)
        } else {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
                .font: font, .foregroundColor: white ? NSColor.white : NSColor.black]))
            ctx.textPosition = .zero; CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
        return wd
    }
    /// 門檻化成純黑白，回傳圖
    func finish() -> CGImage {
        if let d = ctx.data {
            let p = d.assumingMemoryBound(to: UInt8.self)
            for i in 0..<(w * h) {
                let q = p + i * 4
                let a = Int(q[3])
                if a < 128 { q[0] = 0; q[1] = 0; q[2] = 0; q[3] = 0; continue }
                let v: UInt8 = Int(q[0]) * 2 > a ? 255 : 0   // 預乘過的亮度過半＝白
                q[0] = v; q[1] = v; q[2] = v; q[3] = 255
            }
        }
        return ctx.makeImage()!
    }

    // MARK: System 6 的零件

    /// 選單列：20 點高（含底下 1 點黑線），左上是 1-bit 👀（取代蘋果標誌），Chicago 12 的選單
    func menubar(_ items: [String], iconX: Int = 16, firstX: Int = 38) {
        fill(0, 0, w, 19, false); fill(0, 19, w, 1)
        bitmap(Sys6Art.eyesMenu, iconX, 5)
        var x = firstX
        for s in items { x += text(s, x, 14, Sys6Art.chicago(12)) + 13 }
    }
    /// 文件視窗：1 點框、右下 1 點陰影；標題列 6 道橫紋、左上關閉框、標題置中、兩側留白
    func window(_ x: Int, _ y: Int, _ ww: Int, _ hh: Int, title: String) {
        box(x, y, ww, hh)
        fill(x + 1, y + hh, ww, 1); fill(x + ww, y + 1, 1, hh)       // 陰影
        fill(x, y + 18, ww, 1)                                        // 標題列底線
        for k in stride(from: 4, through: 14, by: 2) { fill(x + 2, y + k, ww - 4, 1) }
        fill(x + 8, y + 3, 13, 13, false); box(x + 9, y + 4, 11, 11)  // 關閉框（左右各留 1 點白）
        let f = Sys6Art.chicago(12), tw = width(title, f)
        let pad = max(1, min(6, (ww - tw) / 2 - 22))                 // 窄視窗（桌上附件）時白邊收窄，不壓到關閉框
        fill(x + ww / 2 - tw / 2 - pad, y + 2, tw + pad * 2, 15, false)
        text(title, x + ww / 2 - tw / 2, y + 14, f)
    }
    /// 小型一體機（Happy Mac 的身形），螢幕裡是 1-bit 👀
    func compactMac(_ x: Int, _ y: Int) {
        bitmap(Sys6Art.mac, x, y)
        bitmap(Sys6Art.eyesMenu, x + 4, y + 4)
    }
}

/// 點陣素材
enum Sys6Art {
    static func chicago(_ s: CGFloat) -> NSFont { Face.font1988(s) }
    static func geneva(_ s: CGFloat) -> NSFont { NSFont(name: "Geneva", size: s) ?? chicago(s) }

    /// 選單列的 👀（13×9）：兩顆眼白、瞳孔往左下看
    static let eyesMenu = [
        "  XX     XX  ",
        " X..X   X..X ",
        "X....X X....X",
        "X....X X....X",
        "XXX..X XXX..X",
        "XXX..X XXX..X",
        "X....X X....X",
        " X..X   X..X ",
        "  XX     XX  ",
    ]
    /// 小型一體機（22×26）：螢幕、軟碟槽、底座
    static let mac = [
        " XXXXXXXXXXXXXXXXXXXX ",
        "X....................X",
        "X..XXXXXXXXXXXXXXXX..X",
        "X..X..............X..X",
        "X..X..............X..X",
        "X..X..............X..X",
        "X..X..............X..X",
        "X..X..............X..X",
        "X..X..............X..X",
        "X..X..............X..X",
        "X..X..............X..X",
        "X..X..............X..X",
        "X..X..............X..X",
        "X..X..............X..X",
        "X..XXXXXXXXXXXXXXXX..X",
        "X....................X",
        "X....................X",
        "X..XX................X",
        "X..........XXXXXXX...X",
        "X....................X",
        "X....................X",
        "XXXXXXXXXXXXXXXXXXXXXX",
        "X....................X",
        "X....................X",
        "XXXXXXXXXXXXXXXXXXXXXX",
        " XX                XX ",
    ]
    /// 硬碟（32×14）
    static let hd = [
        "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
        "X..............................X",
        "X..............................X",
        "X..............................X",
        "X..............................X",
        "X..............................X",
        "X.XXX..........................X",
        "X..............................X",
        "X..............................X",
        "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
        "X..............................X",
        "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
        " X                            X ",
        " XX                          XX ",
    ]
    /// 垃圾桶（17×20）
    static let trash = [
        "      XXXXX      ",
        "      X...X      ",
        "XXXXXXXXXXXXXXXXX",
        "X...............X",
        "XXXXXXXXXXXXXXXXX",
        " X.............X ",
        " X..X..X..X..X.X ",
        " X..X..X..X..X.X ",
        " X..X..X..X..X.X ",
        " X..X..X..X..X.X ",
        " X..X..X..X..X.X ",
        " X..X..X..X..X.X ",
        " X..X..X..X..X.X ",
        " X..X..X..X..X.X ",
        " X..X..X..X..X.X ",
        " X..X..X..X..X.X ",
        " X..X..X..X..X.X ",
        " X.............X ",
        "  XXXXXXXXXXXXX  ",
        "                 ",
    ]
    /// Alarm Clock 的三個切換圖示（7×7）：時鐘、月曆、鬧鐘
    static let iconClock = [" XXXXX ", "X..X..X", "X..X..X", "X..XX.X", "X.....X", "X.....X", " XXXXX "]
    static let iconCalendar = ["XXXXXXX", "XXXXXXX", "X.X.X.X", "XXXXXXX", "X.X.X.X", "XXXXXXX", "X.X.X.X"]
    static let iconAlarm = ["X.XXX.X", ".X...X.", "X..X..X", "X..XX.X", "X.....X", ".X...X.", "X.XXX.X"]
    /// Alarm Clock 右邊的小旗（展開鈕）
    static let flag = ["X    ", "XX   ", "XXX  ", "XXXX ", "XXX  ", "XX   ", "X    "]

    // MARK: 1-bit 👀（13×17）
    // 字元：X 黑、. 白、: 網點黑（已按棋盤排好）、空白＝眼外（透明）

    /// 眼睛外形與右下的「枕形」網點陰影（不含瞳孔）
    static let eye = [
        "    XXXXX    ",
        "  XX.....XX  ",
        " X.........X ",
        " X.........X ",
        "X...........X",
        "X...........X",
        "X...........X",
        "X...........X",
        "X...........X",
        "X..........:X",
        "X.........:.X",
        "X........:.:X",
        "X.......:.:.X",
        " X.....:.:.X ",
        " X....:.:.:X ",
        "  XX.:.:.XX  ",
        "    XXXXX    ",
    ]
    /// 瞳孔（7×6），o＝左上高光
    static let pupil = [" XXXXX ", "XXXXXXX", "XooXXXX", "XooXXXX", "XXXXXXX", " XXXXX "]
    static let pupilSmall = [" XXX ", "XoXXX", "XXXXX", "XXXXX", " XXX "]
    static let pupilHeart = [" XX XX ", "XXXXXXX", "XXXXXXX", " XXXXX ", "  XXX  ", "   X   "]
    /// 笑眼：下半被切成彎月（13×7）
    static let happy = [
        "    XXXXX    ",
        "  XX.....XX  ",
        " X.........X ",
        "X...........X",
        "X...XXXXX...X",
        "X.XX     XX.X",
        "XX         XX",
    ]
    /// 閉眼：一道往下彎的線（13×3）
    static let closed = [
        " X         X ",
        "  XX     XX  ",
        "    XXXXX    ",
    ]
}

// MARK: - 預設按鈕膠囊 + 1-bit 👀

extension Face {
    /// 是不是 AI System 6 年代（System 6 系列錶面，或 1988 年代的島）
    var isSystem6Era: Bool {
        [.system6, .alarmClock, .about].contains(style) || (style == .island && era == .y1988)
    }

    /// 1-bit 的島：System 6 的預設按鈕（1 點圓角框，外面隔 1 點白再一圈 3 點粗框），裡面是 1-bit 👀。
    /// center／scale 與 drawIsland 相同（1024 單位）；pixel＝一個 Mac 點佔幾個 1024 單位（4＝256 點的格子）。
    func drawPixelIsland(_ g: CGContext, center: CGPoint, scale: CGFloat, now: Double, pixel: CGFloat = 4) {
        let p = cur
        let bw = max(30, Int((p.cw * 1.4 * scale / pixel).rounded()))
        let bh = max(20, Int((p.ch * 1.4 * scale / pixel).rounded()))
        let x = Int((center.x / pixel - CGFloat(bw) / 2).rounded()), y = Int((center.y / pixel - CGFloat(bh) / 2).rounded())
        let k = max(1, (Int((FaceParams().ch * 1.4 * scale / pixel).rounded()) - 6) / 17)   // 眼睛倍率跟著平常的膠囊，表情變大時不跳級
        drawPixelButton(g, x: x, y: y, w: bw, h: bh, pixel: pixel, now: now, k: k)
    }

    /// 在 Mac 點的格子上畫預設按鈕膠囊（x, y, w, h 是按鈕本身，不含外圈）
    func drawPixelButton(_ g: CGContext, x: Int, y: Int, w: Int, h: Int, pixel P: CGFloat, now: Double, k: Int? = nil) {
        let b = Bit1(w + 8, h + 8)
        let r = max(6, Int((CGFloat(h) * 0.3).rounded()))
        b.roundRect(0, 0, w + 8, h + 8, r + 4, true)        // 外圈 3 點粗框
        b.roundRect(3, 3, w + 2, h + 2, r + 1, false)       // 1 點白縫
        b.roundRect(4, 4, w, h, r, true)                    // 按鈕 1 點框
        b.roundRect(5, 5, w - 2, h - 2, r - 1, false)
        drawPixelEyes(b, cx: 4 + w / 2, cy: 4 + h / 2, k: k ?? max(1, (h - 6) / 17), now: now)
        blit1(g, b.finish(), x: CGFloat(x - 4) * P, y: CGFloat(y - 4) * P, pixel: P)
    }

    /// 兩顆 1-bit 👀（每點放大 k 倍），表情照目前的 FaceParams：眨眼、笑眼、睏（上半切掉）、瞄、好奇跟著看
    func drawPixelEyes(_ b: Bit1, cx: Int, cy: Int, k: Int, now: Double) {
        let p = cur, bf = blinkFactor(now)
        let ew = 13 * k, eh = 17 * k
        for side in [-1, 1] {
            let ex = side < 0 ? cx - ew - k : cx + k, ey = cy - eh / 2
            let closed = expression == .asleep || (expression == .wink && side < 0) || bf < 0.5
            if closed { b.bitmap(Sys6Art.closed, ex, ey + 8 * k, k); continue }
            if p.smile > 0.5 { b.bitmap(Sys6Art.happy, ex, ey + 4 * k, k); continue }
            // 逐點組：外形＋陰影 → 瞳孔（只畫在眼內）→ 眼皮
            var grid = Sys6Art.eye.map { Array($0) }
            if p.ps > 0.05 {
                let spr = expression == .love ? Sys6Art.pupilHeart : (p.ps < 0.8 ? Sys6Art.pupilSmall : Sys6Art.pupil)
                let sw = spr[0].count, sh = spr.count
                let px0 = 6 - sw / 2 + Int((p.pdx * 0.16).rounded()), py0 = 8 - sh / 2 + Int((p.pdy * 0.16).rounded())
                for (j, row) in spr.enumerated() {
                    for (i, ch) in row.enumerated() where ch != " " {
                        let gx = px0 + i, gy = py0 + j
                        guard gy >= 0, gy < 17, gx >= 0, gx < 13, grid[gy][gx] != " " else { continue }
                        if grid[gy][gx] == "X" && ch == "o" { continue }   // 外框不被高光挖白
                        grid[gy][gx] = ch == "o" ? "." : "X"
                    }
                }
            }
            let nTop = Int((17 * p.top).rounded()), nBot = Int((17 * p.bot).rounded())
            for j in 0..<17 {
                if j < nTop || j > 16 - nBot { grid[j] = Array(repeating: " ", count: 13); continue }
                if (nTop > 0 && j == nTop) || (nBot > 0 && j == 16 - nBot) {   // 眼皮：一道平的黑線，左右頂到外框
                    let row = grid[j]
                    if let a = row.firstIndex(where: { $0 != " " }), let z = row.lastIndex(where: { $0 != " " }) {
                        for i in a...z { grid[j][i] = "X" }
                    }
                }
            }
            b.bitmap(grid.map { String($0).replacingOccurrences(of: ":", with: "X") }, ex, ey, k)   // 陰影點已排成棋盤，一律畫黑
        }
    }

    /// 1-bit 圖以最近鄰放大貼上（x, y 是 1024 單位的左上角）
    func blit1(_ g: CGContext, _ img: CGImage, x: CGFloat, y: CGFloat, pixel: CGFloat) {
        let r = CGRect(x: x, y: y, width: CGFloat(img.width) * pixel, height: CGFloat(img.height) * pixel)
        g.saveGState()
        g.interpolationQuality = .none; g.setShouldAntialias(false)
        g.translateBy(x: 0, y: r.minY + r.maxY); g.scaleBy(x: 1, y: -1)
        g.draw(img, in: r)
        g.restoreGState()
    }

    /// 英文日期（System 6 沒有中文介面）
    static func enFormatter(_ fmt: String) -> DateFormatter {
        let key = "en|\(fmt)"
        if let f = sys6Formatters[key] { return f }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = fmt
        sys6Formatters[key] = f
        return f
    }
    nonisolated(unsafe) private static var sys6Formatters: [String: DateFormatter] = [:]

    /// 計時器在跑時的一行英文（Finder 視窗的資訊列用）
    var sys6TimerText: String? {
        guard let end = timerEnd else { return nil }
        let left = timerClock(max(0, end - CACurrentMediaTime()))
        switch pomodoro.phase {
        case .focus: return "Focus \(pomodoro.displayRound)/\(Pomodoro.roundsPerSet)  \(left) left"
        case .shortBreak: return "Break  \(left) left"
        case .longBreak: return "Long Break  \(left) left"
        case nil: return "Timer  \(left) left"
        }
    }
}

// MARK: - Alarm Clock

nonisolated(unsafe) private var alarmStatic: (key: String, pixels: Data)?
nonisolated(unsafe) private var alarmLastSecond = -1

extension Face {
    /// System 6 的桌上附件「Alarm Clock」放大成錶面（128 點的格子，×8）
    func renderAlarmClockFace(_ g: CGContext, _ now: Double) {
        let N = 128, P: CGFloat = 8, date = Self.displayDate
        let wx = 5, wy = 32, ww = 118, wh = 57
        let key = "alarm|\(Self.enFormatter("M/d/yy").string(from: date))"
        let b: Bit1
        if let s = alarmStatic, s.key == key { b = Bit1(N, N, pixels: s.pixels) }
        else {
            b = Bit1(N, N)
            b.desktop(); b.menubar(["File", "Edit"], iconX: 15, firstX: 36)
            b.window(wx, wy, ww, wh, title: "Alarm Clock")
            b.bitmap(Sys6Art.flag, wx + ww - 12, wy + 25)
            b.fill(wx + 1, wy + 37, ww - 2, 1)                          // 分隔線
            b.text(Self.enFormatter("M/d/yy").string(from: date), wx + 7, wy + 51, Sys6Art.chicago(12))
            b.bitmap(Sys6Art.iconClock, wx + ww - 37, wy + 43)
            b.bitmap(Sys6Art.iconCalendar, wx + ww - 26, wy + 43)
            b.bitmap(Sys6Art.iconAlarm, wx + ww - 15, wy + 43)
            alarmStatic = (key, b.pixels)
        }
        b.text(Self.enFormatter(secondsVisible ? "h:mm:ss a" : "h:mm a").string(from: date), wx + 7, wy + 32, Sys6Art.chicago(12))   // 沒人在看時不跳秒
        g.setFillColor(NSColor.black.cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        blit1(g, b.finish(), x: 0, y: 0, pixel: P)
        drawPixelButton(g, x: 64 - 27, y: 98, w: 54, h: 22, pixel: P, now: now)
    }
    /// 秒在走：每秒重畫一次
    func tickAlarmClockFace(_ now: Double) -> Bool {
        let s = secondsVisible ? Int(Date().timeIntervalSince1970) : -1
        if s == alarmLastSecond { return false }
        alarmLastSecond = s; return true
    }
}

// MARK: - About HomePlay

nonisolated(unsafe) private var aboutCache: (key: String, image: CGImage)?

extension Face {
    /// 「About the Finder」改成「About HomePlay」：版本、電量、陪伴天數、CarPlay 用當年的記憶體長條表示
    func renderAboutFace(_ g: CGContext, _ now: Double) {
        let date = Self.displayDate
        let bat = battery ?? Battery.read()
        let days = CompanionLog.daysThisMonth().count
        let monthDays = Calendar.current.range(of: .day, in: .month, for: date)?.count ?? 30
        let total = UserDefaults.standard.stringArray(forKey: "HomePlayCompanionDays") ?? []
        let live = status == .live
        let key = "about|\(bat.map { "\($0.percent)\($0.charging)\($0.onAC)" } ?? "-")|\(days)|\(monthDays)|\(total.count)|\(live)"
        let img: CGImage
        if let c = aboutCache, c.key == key { img = c.image }
        else {
            let b = Bit1(256, 256)
            b.desktop(); b.menubar(["File", "Edit", "View", "Special"])
            let wx = 14, wy = 30, ww = 228, wh = 176
            b.window(wx, wy, ww, wh, title: "About HomePlay")
            b.compactMac(wx + 12, wy + 27)
            b.text("HomePlay", wx + 44, wy + 46, Sys6Art.chicago(24))
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.6.1"
            b.text("Version \(version)", wx + 45, wy + 60, Sys6Art.geneva(9))
            b.fill(wx + 8, wy + 68, ww - 16, 1)
            let g9 = Sys6Art.geneva(9), g12 = Sys6Art.geneva(12)
            b.text("Total Days: \(total.count)", wx + 10, wy + 81, g9)
            if let first = total.sorted().first, let d = Self.enFormatter("yyyy-MM-dd").date(from: first) {
                b.text("Since: " + Self.enFormatter("MMM d, yyyy").string(from: d), wx + ww - 10, wy + 81, g9, align: 1)
            }
            b.fill(wx + 8, wy + 87, ww - 16, 1)
            let batText = bat.map { "\($0.percent)%" } ?? "AC"
            let rows: [(String, CGFloat, String)] = [
                ("Battery", bat.map { CGFloat($0.percent) / 100 } ?? 1, batText),
                ("With you", CGFloat(days) / CGFloat(max(1, monthDays)), "\(days)/\(monthDays)"),
                ("CarPlay", live ? 1 : 0, live ? "On" : "Off"),
            ]
            for (i, row) in rows.enumerated() {
                let y = wy + 106 + i * 21
                b.bitmap(Sys6Art.eyesMenu, wx + 10, y - 9)
                b.text(row.0, wx + 28, y, g12)
                b.text(row.2, wx + 122, y, g9, align: 1)
                let bx = wx + 128, bw = ww - 138
                b.box(bx, y - 9, bw, 10)
                b.fill(bx + 1, y - 8, Int((CGFloat(bw - 2) * max(0, min(1, row.1))).rounded()), 8)
            }
            if let bat {
                let s = bat.charging ? "Charging" : (bat.onAC ? "Plugged in" : "On battery")
                b.text(s, wx + ww - 10, wy + 106 + 3 * 21 - 2, g9, align: 1)
            }
            img = b.finish()
            aboutCache = (key, img)
        }
        g.setFillColor(NSColor.black.cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        blit1(g, img, x: 0, y: 0, pixel: 4)
        drawPixelButton(g, x: 128 - 36, y: 214, w: 72, h: 26, pixel: 4, now: now)
    }
    func tickAboutFace(_ now: Double) -> Bool { false }
}

// MARK: - Welcome to HomePlay.（連線中）

extension Face {
    /// 開機畫面：50% 桌面、螢幕裡是 👀 的小型一體機、雙框的「Welcome to HomePlay.」。
    /// note：要使用者動手時（配對、信任、太久…）底下再一個 1-bit 對話盒，字照目前語言。
    func drawWelcome1988(_ g: CGContext, note: (title: String, body: String)?) {
        let N = 128, P: CGFloat = 8
        let b = Bit1(N, N)
        b.desktop()
        let top = note == nil ? 30 : 10
        b.compactMac(53, top)
        let by = top + 34
        b.box(14, by, 100, 32); b.box(16, by + 2, 96, 28)
        let f = Sys6Art.chicago(12)
        b.text("Welcome to", 64, by + 14, f, align: 0)
        b.text("HomePlay.", 64, by + 26, f, align: 0)
        if note != nil { b.box(8, 84, 112, 34); b.box(10, 86, 108, 30) }
        blit1(g, b.finish(), x: 0, y: 0, pixel: P)
        guard let note else { return }
        g.saveGState(); g.setShouldAntialias(false)
        func fit(_ s: String, _ size: CGFloat, _ maxW: CGFloat) -> NSFont {
            let f = Face.font1988(size), w = Typo.width(s, f)
            return w > maxW ? Face.font1988(size * maxW / w) : f
        }
        drawCentered(g, note.title, font: fit(note.title, 44, 820), kern: 0, y: 86 * P + 92, color: .black)
        drawCentered(g, note.body, font: fit(note.body, 32, 820), kern: 0, y: 86 * P + 168, color: .black)
        g.restoreGState()
    }
}
