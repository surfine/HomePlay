// HPDS v1：Components——頂列、圓鈕、膠囊鈕、分段、開關、清單、家庭磚、小工具框、晶片、分區標題（原 Design/HPComponents.swift，
// 加上 AppsKit 的開關、HomeApp 的磚、HomeScreen 的返回鈕／時間／小工具框；舊名 RealUI 留成 typealias）。規格見 Design/README.md。
//
// 2.0 逼真化：所有 App 共用的 iOS 27 系統樣式零件（realism-spec、realism-spec2）。
// - 字：一律 SF Pro（不用圓體）；大數字另外用 FaceType.sf(…, .light) 的等寬數字。
// - 顏色：跟著 Theme——白天淺色（#F2F2F7 底、白卡、黑字），HPTokens.dark 時深色（黑底、#1C1C1E 卡、白字）。
// - 頂列（第二輪 R1）：左上外殼的 ✕／‹ 玻璃圓鈕（HPTokens.backButton），旁邊接大標題（HPTokens.titleFont，在 titleX／titleBaseline）；
//   內容從 y≈220 開始。媒體全螢幕（Now Playing、攝影機）不畫標題也不畫時間。
// - 玻璃（R13）：所有玻璃鈕／膠囊／分段軌道都交給 HPGlass.add（外殼包用系統 Liquid Glass 在幀尾一起算）；
//   玻璃上面的字與符號一律放在 content 裡，因為正式版會延到幀尾才畫玻璃。
// - 主要動作（R6）：150 px 圓鈕，依語意上色（紅＝停止／結束、黃＝麥克風、綠＝開始、玻璃＝導覽或更多）；
//   按下（mouse down）那一刻就變亮＋放大 1.08，放開才觸發（R14 §5）。
// - 動畫（R14）：一律用 Spring（Design/HPMotion.swift）；可中途打斷（從當下值與速度接著走）；
//   HOMEPLAY_ANIM=name:t 把名為 name 的動畫凍結在第 t 秒（快照逐格對照用）；「減少動態效果」時位移／縮放換成 0.2 s 交叉淡化。

import AppKit

typealias RealUI = HPComponents

enum HPComponents {
    // MARK: 字（SF Pro，比例數字；HPType）
    static func sf(_ size: CGFloat, weight: NSFont.Weight) -> NSFont { HPType.sf(size, weight) }
    /// 放得下就用 size，放不下就縮（最小 size × minScale）
    static func fitted(_ s: String, size: CGFloat, weight: NSFont.Weight, maxWidth: CGFloat, minScale: CGFloat = 0.7) -> NSFont {
        HPType.fitted(s, size: size, weight: weight, maxWidth: maxWidth, minScale: minScale)
    }

    // MARK: 系統色（跟著 Theme 的淺／深色）
    static var bg: NSColor { HPTokens.bg }
    static var label: NSColor { HPTokens.label }
    static var secondary: NSColor { HPTokens.secondary }
    static var tertiary: NSColor { HPTokens.tertiary }
    /// 分組卡（secondarySystemGroupedBackground）
    static var grouped: NSColor { HPTokens.card }
    /// 卡上再一層（tertiarySystemGroupedBackground／淺色時的 systemGray5）
    static var grouped2: NSColor { HPTokens.card2 }
    static var separator: NSColor { HPTokens.separator }
    static var fill: NSColor { HPTokens.fill }
    static var orange: NSColor { HPTokens.orange }
    static var red: NSColor { HPTokens.red }
    static var green: NSColor { HPTokens.green }
    static var blue: NSColor { HPTokens.blue }
    static var yellow: NSColor { HPTokens.yellow }
    static var purple: NSColor { HPTokens.purple }
    /// 照片／深色媒體上的字（不跟淺色走）
    static let onMedia = HPTokens.onMedia
    /// 照片／封面／攝影機上的鈕（chan-notes G5：Clear 只用在媒體上、底下依亮度加 0–35% 壓暗）：
    /// 傳這個「記號色」當 tint，glassCapsule 會先在鈕底下畫壓暗層，再交給 GlassPass 一塊無色玻璃（不是染色）
    static let mediaTint = NSColor(white: 0, alpha: 0.0001)
    /// 鈕底下的局部壓暗：取底下的平均亮度，亮 → 35% 黑、暗 → 0（柔邊）
    static func mediaDim(_ g: CGContext, _ r: CGRect) {
        let lum = GlassPassShim.luminance(g, r) ?? 0.5
        let a = max(0, min(0.35, (lum - 0.25) / 0.5 * 0.35))
        guard a > 0.01, let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                               colors: [NSColor(white: 0, alpha: a).cgColor, NSColor(white: 0, alpha: 0).cgColor] as CFArray, locations: [0.55, 1]) else { return }
        let c = CGPoint(x: r.midX, y: r.midY), rad = max(r.width, r.height) * 0.75
        g.saveGState(); g.translateBy(x: c.x, y: c.y); g.scaleBy(x: 1, y: r.height / max(1, r.width))
        g.drawRadialGradient(grad, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: rad, options: [])
        g.restoreGState()
    }

    // MARK: 版面
    /// 左右邊距（跟主畫面圖示欄外緣對齊）
    static let margin: CGFloat = HPTokens.Space.margin
    /// 大標題那一列底下，內容從這裡開始（R1：y≈220）
    static let contentTop: CGFloat = HPTokens.contentTop
    static var screenRadius: CGFloat { Screen.cornerRadius }
    /// 大標題可用的寬度（右上留給時間）
    static var titleMaxWidth: CGFloat { 1024 - HPTokens.titleX - 220 }

    // MARK: 頂列

    /// 大標題（R1）：目前頁的名稱——App 根頁＝App 名稱，子頁＝子頁名稱
    static func bigTitle(_ g: CGContext, _ face: Face, _ s: String, color: NSColor? = nil, maxWidth: CGFloat? = nil) {
        let t = titleLines(s, maxWidth: maxWidth)
        let top = t.baselines[0] - t.font.ascender, bottom = t.baselines[t.baselines.count - 1] - t.font.descender
        HPAX.note(g, CGRect(x: t.x, y: top, width: t.lines.map { Typo.width($0, t.font) }.max() ?? 0, height: bottom - top), .heading, s)   // 2.0 P05：念整個標題
        for (line, y) in zip(t.lines, t.baselines) { face.drawLeft(g, line, font: t.font, x: t.x, y: y, color: color ?? label) }
    }
    /// 2.0 depth：長標題（群組名稱、播客節目、清單名稱）。我們的標題住在返回鈕與 👀 膠囊之間，只有兩百多 px：
    /// 先照比例縮到 44；還放不下就照 iOS 大標題的換行改成兩行（38，兩行一起置中在返回鈕的中線上，不碰 contentTop）。
    /// 第一行在膠囊旁邊；第二行已經在膠囊下緣底下，可以用到右上時間前（titleMaxWidth）。
    /// 第二行還放不下就中間截斷，留住結尾（「…週末計畫」比「[Famil…」好認）；一個長詞斷不開就整串一行中間截斷。
    static func titleLines(_ s: String, maxWidth: CGFloat? = nil) -> (font: NSFont, x: CGFloat, baselines: [CGFloat], lines: [String], width: CGFloat) {
        let f0 = HPTokens.titleFont, tw = Typo.width(s, f0)
        let w = min(maxWidth ?? titleMaxWidth, Shell.pillRect(Shell.pillT).minX - 24 - HPTokens.titleX)
        if tw <= w { return (f0, HPTokens.titleX, [HPTokens.titleBaseline], [s], w) }
        // 字級不是線性的（光學尺寸與 trak 字距跟著字級換），照比例算完再往下試到真的放得下
        var size = (f0.pointSize * w / max(1, tw)).rounded(.down)
        while size >= 44, Typo.width(s, FaceType.sf(size, .bold, mono: false)) > w { size -= 1 }
        if size >= 44 { return (FaceType.sf(size, .bold, mono: false), HPTokens.titleX, [HPTokens.titleBaseline], [s], w) }
        let f = FaceType.sf(38, .bold, mono: false)
        let attr = NSAttributedString(string: s, attributes: Typo.attributes(f))
        let ns = s as NSString
        let n = CTTypesetterSuggestLineBreak(CTTypesetterCreateWithAttributedString(attr), 0, Double(w))
        // 斷點落在一個詞中間（兩邊都不是空白、也不是中日文）＝這個詞一行放不下
        func midWord(_ i: Int) -> Bool {
            let a = ns.substring(with: NSRange(location: i - 1, length: 1)), b = ns.substring(with: NSRange(location: i, length: 1))
            return a.trimmingCharacters(in: .whitespaces) == a && b.trimmingCharacters(in: .whitespaces) == b && !HPType.hasCJK(a + b)
        }
        guard n > 0, n < ns.length, !midWord(n) else {
            return (f, HPTokens.titleX, [HPTokens.titleBaseline - 6], [middleClipped(s, f, w)], w)
        }
        let first = ns.substring(to: n).trimmingCharacters(in: .whitespaces)
        let second = middleClipped(ns.substring(from: n).trimmingCharacters(in: .whitespaces), f, min(maxWidth ?? titleMaxWidth, titleMaxWidth))
        let lh = HPType.lineHeight(38, for: s) - 2, cy = HPTokens.cornerControlCenter
        let b1 = cy - lh / 2 + f.capHeight / 2
        return (f, HPTokens.titleX, [b1, b1 + lh], [first, second], w)
    }
    /// 中間截斷（iOS 的 .byTruncatingMiddle）：頭尾都留
    static func middleClipped(_ s: String, _ font: NSFont, _ width: CGFloat) -> String {
        if Typo.width(s, font) <= width { return s }
        var head = Array(s.prefix(s.count / 2)), tail = Array(s.suffix(s.count - s.count / 2))
        func str() -> String { String(head).trimmingCharacters(in: .whitespaces) + "…" + String(tail).trimmingCharacters(in: .whitespaces) }
        while !(head.isEmpty && tail.isEmpty) && Typo.width(str(), font) > width {
            if head.count >= tail.count { head.removeLast() } else { tail.removeFirst() }
        }
        return str()
    }
    /// 大標題放哪裡：Apple 的頂端中央是空的（鏡頭在邊框裡），我們那裡住著 👀 膠囊——
    /// 標題照官方位置接在返回鈕旁，可用寬度到膠囊左緣前 24；放不下就照比例縮小（最小 38），不壓膠囊、不換行。
    static func titleLayout(_ s: String, maxWidth: CGFloat? = nil) -> (font: NSFont, x: CGFloat, baseline: CGFloat, width: CGFloat) {
        let f0 = HPTokens.titleFont, tw = Typo.width(s, f0)
        let w = min(maxWidth ?? titleMaxWidth, Shell.pillRect(Shell.pillT).minX - 24 - HPTokens.titleX)
        let f = tw > w && tw > 0 ? FaceType.sf(max(38, (f0.pointSize * w / tw).rounded(.down)), .bold, mono: false) : f0
        return (f, HPTokens.titleX, HPTokens.titleBaseline, w)
    }

    /// 自己畫的右上時間（照片上的頁面：外殼的時間跟著淺色會是黑字，照片上要白字）
    static func clock(_ g: CGContext, _ face: Face, color: NSColor) { topClock(g, face, size: 34, baselineDY: 12, color: color) }
    /// 右上小字時間：右緣對齊右上角圓角圓心 +30、基線在圓心下 baselineDY（外殼 32／+11；照片上的頁面 34／+12）
    static func topClock(_ g: CGContext, _ face: Face, size: CGFloat = HPType.Size.clock, baselineDY: CGFloat = 11, color: NSColor) {
        let s = Face.statusClock(Face.displayDate)   // 2.0 depth：12／24 小時制照系統
        let f = FaceType.sf(size, .semibold)
        // 第三輪：跟返回鈕對稱——中線 y＝105、右緣＝1024 − 93（官方 recipe-overview 的「10:09」右緣 931）
        let cy = HPTokens.cornerControlCenter, right = 1024 - HPTokens.cornerControlCenter + 12
        face.drawLeft(g, s, font: f, x: right - Typo.width(s, f), y: cy + baselineDY, color: color)
    }
    /// 外殼的左上返回圓鈕（HPTokens.backButton，90 px、圓心 (105, 105)，Regular 玻璃，可按）：符號 ✕（xmark，0.34）或 ‹（chevron.left，0.36），
    /// 顏色跟著玻璃翻（HPGlass.ink：淺玻璃深色字、深玻璃白字）。影片 v1 0:47 行事曆、0:52 食譜
    static func shellBackButton(_ face: Face, symbol: String) {
        let r = HPTokens.backButton
        HPGlass.addCapsule(r, interactive: true) { [weak face] c in
            let k: CGFloat = symbol == "xmark" ? 0.34 : 0.36
            face?.drawSymbol(c, symbol, in: r.insetBy(dx: r.width * k, dy: r.height * k), color: HPGlass.ink, weight: .semibold)
        }
    }

    /// 自己畫的左上返回圓鈕（照片上的頁面用清玻璃＋白符號；位置與外殼的 HPTokens.backButton 相同）
    static func backButton(_ g: CGContext, _ face: Face, symbol: String, ink: NSColor = .white) {
        glassCircle(g, face, HPTokens.backButton, symbol: symbol, ink: ink, scale: 0.34, tint: mediaTint)
    }

    /// 自己畫返回鈕的頁面（showsCloseButton＝false）點到左上時：照外殼的返回走（先問 App 的 handleBack）
    static func hitBack(_ p: CGPoint) -> Bool { HPTokens.backButton.insetBy(dx: -8, dy: -8).contains(p) }
    static func navigateBack() { (NSApp.delegate as? AppDelegate)?.view?.shellNavigate(.back) }

    // MARK: 玻璃（R13）

    static func capsulePath(_ r: CGRect) -> CGPath { CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil) }

    /// 一塊玻璃：path 形狀、tint 染色（nil＝清玻璃）、content＝玻璃上面的字與符號
    static func glass(_ g: CGContext, _ path: CGPath, tint: NSColor? = nil, interactive: Bool = false, content: @escaping (CGContext) -> Void = { _ in }) {
        GlassPassShim.with(g) { HPGlass.add(path, tint: tint, interactive: interactive, content: content) }
    }
    /// 膠囊玻璃（傳正方形框就是圓）；按下時放大 1.08、變亮
    static func glassCapsule(_ g: CGContext, _ r: CGRect, tint: NSColor? = nil, interactive: Bool = true, content: @escaping (CGContext) -> Void = { _ in }) {
        let onMedia = tint === mediaTint
        if onMedia { mediaDim(g, r) }
        let tint = onMedia ? nil : tint
        let k = Press.scale(r)
        let rr = k == 1 ? r : scaled(r, k)
        glass(g, capsulePath(rr), tint: tint.map { Press.brighten($0, r) }, interactive: interactive) { c in
            if k != 1 { c.saveGState(); c.translateBy(x: r.midX, y: r.midY); c.scaleBy(x: k, y: k); c.translateBy(x: -r.midX, y: -r.midY) }
            content(c)
            // 按下：從觸點亮起、往外擴散到整塊（chan-notes G7）
            let a = Press.amount(r)
            if a > 0.01, let p = Press.point {
                let rad = max(r.width, r.height) * (0.35 + 0.9 * a)
                if let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                         colors: [NSColor(white: 1, alpha: 0.34 * a).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray, locations: [0, 1]) {
                    c.saveGState(); c.addPath(capsulePath(r)); c.clip()
                    c.drawRadialGradient(grad, startCenter: p, startRadius: 0, endCenter: p, endRadius: rad, options: [])
                    c.restoreGState()
                }
            }
            if k != 1 { c.restoreGState() }
        }
    }
    static func scaled(_ r: CGRect, _ k: CGFloat) -> CGRect {
        CGRect(x: r.midX - r.width * k / 2, y: r.midY - r.height * k / 2, width: r.width * k, height: r.height * k)
    }

    /// 玻璃膠囊按鈕（可帶 SF Symbol）；回傳框
    /// busy：動作不是即時完成時（HIG Buttons）——符號換成轉圈，標籤換成 busyTitle（進行式「打開中…」；nil＝標籤不變，例如「停止」）
    @discardableResult
    static func glassButton(_ g: CGContext, _ face: Face, _ r: CGRect, _ title: String, symbol: String? = nil,
                            size: CGFloat = 36, ink: NSColor? = nil, dark: Bool = true, busy: Bool = false, busyTitle: String? = nil) -> CGRect {
        let ink = ink ?? label
        HPAX.note(g, r, .button, busy ? (busyTitle ?? title) : title)   // 2.0 P05
        glassCapsule(g, r) { c in drawLabel(c, face, r, title, symbol: symbol, size: size, ink: ink, busy: busy, busyTitle: busyTitle) }
        return r
    }

    /// 主要動作的膠囊：App 色染色玻璃、白字（每個畫面最多一到兩顆）；busy 同 glassButton
    @discardableResult
    static func filledButton(_ g: CGContext, _ face: Face, _ r: CGRect, _ title: String, tint: NSColor, symbol: String? = nil,
                             size: CGFloat = 36, ink: NSColor = .white, busy: Bool = false, busyTitle: String? = nil) -> CGRect {
        HPAX.note(g, r, .button, busy ? (busyTitle ?? title) : title)   // 2.0 P05
        glassCapsule(g, r, tint: tint) { c in drawLabel(c, face, r, title, symbol: symbol, size: size, ink: ink, busy: busy, busyTitle: busyTitle) }
        return r
    }

    static func drawLabel(_ g: CGContext, _ face: Face, _ r: CGRect, _ title: String, symbol: String?, size: CGFloat, ink: NSColor,
                          busy: Bool = false, busyTitle: String? = nil) {
        let title = busy ? (busyTitle ?? title) : title
        let lead = busy || symbol != nil
        let sym: CGFloat = lead ? size * 1.1 : 0, gap: CGFloat = lead ? 16 : 0
        // 2.0 glass：字重照官方食譜圖（recipe-overview 的「Ingredients／Start Cooking」）——Regular，符號跟字同一個字重
        let f = fitted(title, size: size, weight: .regular, maxWidth: r.width - 56 - sym - gap)
        let t = Face.clipped(title, f, r.width - 56 - sym - gap)
        let total = sym + gap + Typo.width(t, f)
        let x = r.midX - total / 2
        let lr = CGRect(x: x, y: r.midY - sym / 2, width: sym, height: sym)
        if busy { spinner(g, in: lr, ink: ink) }
        else if let symbol { face.drawSymbol(g, symbol, in: lr, color: ink, weight: .regular) }
        face.drawLeft(g, t, font: f, x: x + sym + gap, y: r.midY + f.capHeight / 2, color: ink)
    }

    // MARK: 忙碌（P04）

    /// 最近一次畫出轉圈的時刻：needsFrame 靠它在忙碌期間持續要畫面（停畫 0.25 s 後自動停）
    nonisolated(unsafe) private static var spinnerDrawnAt = -1.0
    /// 轉圈：四分之三圓弧，每 0.9 s 轉一圈。HOMEPLAY_ANIM=busy:t 快照時凍結在第 t 秒
    static func spinner(_ g: CGContext, in r: CGRect, ink: NSColor, now: Double = CACurrentMediaTime()) {
        let frozen = HPMotion.frozen("busy")
        if frozen == nil { spinnerDrawnAt = now }
        let t = frozen ?? now
        let lw = max(4, r.width * 0.13), rad = (min(r.width, r.height) - lw) / 2
        let a0 = -CGFloat(t / 0.9 * 2 * Double.pi)   // CG 座標 y 向下：負號＝順時針
        g.saveGState()
        g.setStrokeColor(ink.cgColor); g.setLineWidth(lw); g.setLineCap(.round)
        g.addArc(center: CGPoint(x: r.midX, y: r.midY), radius: rad, startAngle: a0, endAngle: a0 - .pi * 1.5, clockwise: true)
        g.strokePath()
        g.restoreGState()
    }

    /// 玻璃圓鈕（傳正方形框）＋符號；tint 給了就是染色玻璃
    static func glassCircle(_ g: CGContext, _ face: Face, _ r: CGRect, symbol: String, ink: NSColor? = nil, scale: CGFloat = 0.38,
                            dark: Bool = true, tint: NSColor? = nil) {
        let ink = ink ?? label
        if let name = HPAX.symbolLabel(symbol, rect: r) { HPAX.note(g, r, .button, name, shape: .circle) }   // 2.0 P05
        glassCapsule(g, r, tint: tint) { c in
            let s = r.width * scale
            face.drawSymbol(c, symbol, in: CGRect(x: r.midX - s / 2, y: r.midY - s / 2, width: s, height: s), color: ink, weight: .semibold)
        }
    }

    // MARK: 主要動作圓鈕（R6）

    enum Role { case stop, mic, start, glass, primary(NSColor) }
    static let actionSize: CGFloat = 150
    static func actionRect(cx: CGFloat, cy: CGFloat, size: CGFloat = actionSize) -> CGRect {
        CGRect(x: cx - size / 2, y: cy - size / 2, width: size, height: size)
    }
    /// 150 px 圓鈕：紅＝停止／結束、黃＝麥克風（黑符號）、綠＝開始、玻璃＝導覽或更多；label 給了就在圓鈕底下寫一行
    static func actionButton(_ g: CGContext, _ face: Face, _ r: CGRect, symbol: String, role: Role, label text: String? = nil,
                             labelColor: NSColor? = nil, enabled: Bool = true) {
        var tint: NSColor?, ink: NSColor = .white
        switch role {
        case .stop: tint = red
        case .mic: tint = yellow; ink = .black
        case .start: tint = green
        case .primary(let c): tint = c
        case .glass: tint = nil; ink = label
        }
        if !enabled { tint = tint?.withAlphaComponent(0.35); ink = ink.withAlphaComponent(0.45) }
        // 2.0 P05：有字就用字；紅色的 ✕ 是「停止」
        var isStop = false
        if case .stop = role { isStop = true }
        if let name = text ?? (isStop && symbol == "xmark" ? L("a11y.stop", "停止") : HPAX.symbolLabel(symbol, rect: r)) { HPAX.note(g, r, .button, name, shape: .circle) }
        glassCircle(g, face, r, symbol: symbol, ink: ink, scale: 0.36, tint: tint)
        if let text {
            let f = fitted(text, size: 28, weight: .medium, maxWidth: r.width + 60)
            center(g, face, text, f, cx: r.midX, y: r.maxY + 42, labelColor ?? secondary)
        }
    }

    // MARK: 分段控制（玻璃軌道＋會滑的選中膠囊）

    /// 分段控制：玻璃軌道，選中段＝白色膠囊（淺色）／白 0.24（深色），用彈簧滑到新的一段。回傳每段的框
    @discardableResult
    static func segmented(_ g: CGContext, _ face: Face, _ track: CGRect, _ items: [String], selected: Int, size: CGFloat = 32, key: String = "seg") -> [CGRect] {
        guard !items.isEmpty else { return [] }
        let inset: CGFloat = 6, w = (track.width - inset * 2) / CGFloat(items.count)
        let rects = items.indices.map { CGRect(x: track.minX + inset + CGFloat($0) * w, y: track.minY + inset, width: w, height: track.height - inset * 2) }
        // 影片沒有拍到分段控制；頻繁的小互動用 Apple 的 interactiveSpring（damping 0.86、response 0.15）滑過去
        let x = Anim.track("\(key)", to: CGFloat(selected), spring: AppMotion.interactive)
        let pos = rects[0].offsetBy(dx: x * w, dy: 0)
        for (i, s) in items.enumerated() { HPAX.note(g, rects[i], .radio(i == selected), s) }   // 2.0 P05
        glass(g, capsulePath(track), interactive: true) { c in
            c.addPath(capsulePath(pos)); c.setFillColor((HPTokens.dark ? NSColor(white: 1, alpha: 0.24) : NSColor.white).cgColor)
            if !HPTokens.dark { c.saveGState(); HPTokens.Shadow.segment.apply(c) }
            c.fillPath()
            if !HPTokens.dark { c.restoreGState() }
            for (i, s) in items.enumerated() {
                let r = rects[i], on = i == selected
                let f = fitted(s, size: size, weight: on ? .semibold : .medium, maxWidth: r.width - 28)
                let t = Face.clipped(s, f, r.width - 28)
                face.drawLeft(c, t, font: f, x: r.midX - Typo.width(t, f) / 2, y: r.midY + f.capHeight / 2, color: on ? label : secondary)
            }
        }
        return rects
    }

    // MARK: 開關（iOS 26：長膠囊軌道、比圓略寬的白色膠囊旋鈕）

    /// key：同一顆開關（切換時旋鈕用 interactiveSpring 滑過去、軌道顏色跟著淡換；影片沒拍到開關，照 UISwitch）
    /// label：VoiceOver／語音控制念的名字（2.0 P05；畫面上的字由呼叫端畫在旁邊）
    static func toggle(_ g: CGContext, _ r: CGRect, on: Bool, key: String? = nil, label name: String? = nil) {
        if let name { HPAX.note(g, r, .toggle(on), name) }
        let t = key.map { Anim.track("toggle.\($0)", to: on ? 1 : 0, spring: AppMotion.interactive) } ?? (on ? 1 : 0)
        let off = HPTokens.dark ? NSColor(srgbRed: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: 0.36) : NSColor(srgbRed: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: 0.16)
        AppUI.fillPill(g, r, color: off.blended(withFraction: max(0, min(1, t)), of: green) ?? (on ? green : off))
        let kh = r.height - 8, kw = kh * 1.3
        let x = r.minX + 4 + (r.width - 8 - kw) * t
        let k = CGRect(x: x, y: r.minY + 4, width: kw, height: kh)
        // 2.0 glass（P04）：按著或滑動中旋鈕變成 Regular 玻璃（Adopting Liquid Glass：knob transforms into Liquid Glass during interaction），
        // 放開回實心白。HOMEPLAY_ANIM=toggle.press:t 快照用：當成按下 t 秒
        let pressed = HPMotion.frozen("toggle.press").map { Press.spring.value(from: 0, to: 1, velocity: 0, t: CGFloat($0)).x } ?? Press.amount(r)
        let sliding = key == nil ? 0 : max(0, 1 - abs(2 * t - 1)) * (t > 0.001 && t < 0.999 ? 1 : 0)
        let moving = min(1, max(pressed, sliding))
        let glass = HPGlass.addKnob(k, moving: moving)
        g.saveGState()
        if glass { g.setAlpha(max(0, 1 - 2 * moving)) }
        HPTokens.Shadow.knob.apply(g)
        AppUI.fillPill(g, k, color: .white)
        g.restoreGState()
    }

    /// 上一次 textTabs 畫出來的每個字的框（家庭 App 點分頁用）
    nonisolated(unsafe) static var tabRects: [CGRect] = []

    /// 文字分頁（R8 家庭的房間）：標題下的一排小字，選中＝label 色 semibold＋底線，其餘 secondary；回傳每個字的框
    @discardableResult
    static func textTabs(_ g: CGContext, _ face: Face, _ items: [String], selected: Int, x: CGFloat, baseline y: CGFloat, maxX: CGFloat,
                         size: CGFloat = 32, key: String = "tabs") -> [CGRect] {
        var out: [CGRect] = [], cx = x
        let gap: CGFloat = 40
        var widths: [CGFloat] = []
        for (i, s) in items.enumerated() {
            let f = sf(size, weight: i == selected ? .semibold : .medium)
            widths.append(Typo.width(s, f))
        }
        // 放不下：從選中的那一個往左捲
        var shift: CGFloat = 0
        let selMax = x + widths.prefix(selected + 1).reduce(0, +) + gap * CGFloat(selected)
        if selMax > maxX { shift = selMax - maxX }
        cx -= shift
        for (i, s) in items.enumerated() {
            let on = i == selected
            let f = sf(size, weight: on ? .semibold : .medium)
            let r = CGRect(x: cx - gap / 2, y: y - f.ascender - 22, width: widths[i] + gap, height: f.ascender + 44)
            if cx + widths[i] > x - 1, cx < maxX {
                face.drawLeft(g, s, font: f, x: cx, y: y, color: on ? label : secondary)
            }
            out.append(r); cx += widths[i] + gap
        }
        // 底線滑過去（interactiveSpring）
        if selected < out.count {
            let target = out[selected]
            let ux = Anim.track("\(key).x", to: target.minX + gap / 2, spring: AppMotion.interactive)
            let uw = Anim.track("\(key).w", to: widths[selected], spring: AppMotion.interactive)
            g.setFillColor(label.cgColor)
            g.addPath(capsulePath(CGRect(x: ux, y: y + 14, width: uw, height: 5))); g.fillPath()
        }
        return out
    }

    /// 一般的膠囊晶片：選中＝白（淺色）／白 0.34（深色），未選＝玻璃
    static func chip(_ g: CGContext, _ face: Face, _ r: CGRect, _ title: String, selected: Bool, symbol: String? = nil, symbolTint: NSColor? = nil, size: CGFloat = 32) {
        HPAX.note(g, r, .radio(selected), title)   // 2.0 P05
        glassCapsule(g, r) { c in
            if selected { c.addPath(capsulePath(r.insetBy(dx: 3, dy: 3))); c.setFillColor((HPTokens.dark ? NSColor(white: 1, alpha: 0.34) : NSColor.white).cgColor); c.fillPath() }
            let sym: CGFloat = symbol == nil ? 0 : size * 0.8, gap: CGFloat = symbol == nil ? 0 : 12
            let f = sf(size, weight: .semibold)
            let t = Face.clipped(title, f, r.width - 48 - sym - gap)
            let total = sym + gap + Typo.width(t, f)
            let x = r.midX - total / 2
            if let symbol { face.drawSymbol(c, symbol, in: CGRect(x: x, y: r.midY - sym / 2, width: sym, height: sym), color: symbolTint ?? label, weight: .semibold) }
            face.drawLeft(c, t, font: f, x: x + sym + gap, y: r.midY + f.capHeight / 2, color: label)
        }
    }

    // MARK: 內容

    /// 分區標題（SF Pro bold，後面可加 chevron）；回傳整列可點的框
    @discardableResult
    static func sectionHeader(_ g: CGContext, _ face: Face, _ s: String, x: CGFloat, baseline y: CGFloat, size: CGFloat = 38,
                              chevron: Bool = false, color: NSColor? = nil) -> CGRect {
        let f = sf(size, weight: .bold)
        face.drawLeft(g, s, font: f, x: x, y: y, color: color ?? label)
        let w = Typo.width(s, f)
        HPAX.note(g, CGRect(x: x, y: y - f.ascender - 12, width: w + (chevron ? 40 : 0), height: f.ascender + 24), chevron ? .button : .heading, s)   // 2.0 P05
        if chevron {
            let h = size * 0.62
            face.drawSymbol(g, "chevron.right", in: CGRect(x: x + w + 10, y: y - f.capHeight / 2 - h / 2, width: h * 0.6, height: h), color: secondary, weight: .bold)
        }
        return CGRect(x: x, y: y - f.ascender - 12, width: w + (chevron ? 40 : 0), height: f.ascender + 24)
    }

    /// inset grouped 的整組卡片
    static func groupCard(_ g: CGContext, _ r: CGRect, radius: CGFloat = 52, color: NSColor? = nil) {
        g.addPath(continuousRoundedRect(r, radius: radius)); g.setFillColor((color ?? grouped).cgColor); g.fillPath()
    }
    /// 列間 1 px 分隔線（縮排到文字起點）
    static func separatorLine(_ g: CGContext, x: CGFloat, maxX: CGFloat, y: CGFloat) {
        g.setFillColor(separator.cgColor); g.fill(CGRect(x: x, y: y - 1, width: maxX - x, height: 2))
    }

    /// 頂端列底下的柔和淡出：bg 從 top 往下到 top + height 漸漸透明（內容捲到標題底下時看不到硬邊）
    static func topFade(_ g: CGContext, _ bg: NSColor, solidTo: CGFloat, height: CGFloat = 70) {
        g.setFillColor(bg.cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: solidTo))
        let stops: [(CGFloat, CGFloat)] = [(0, 1), (0.35, 0.82), (0.7, 0.35), (1, 0)]
        guard let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                    colors: stops.map { bg.withAlphaComponent($0.1).cgColor } as CFArray, locations: stops.map(\.0)) else { return }
        g.saveGState(); g.clip(to: CGRect(x: 0, y: solidTo, width: 1024, height: height))
        g.drawLinearGradient(grad, start: CGPoint(x: 0, y: solidTo), end: CGPoint(x: 0, y: solidTo + height), options: [])
        g.restoreGState()
    }

    /// 置中畫一行（y 是基線）
    static func center(_ g: CGContext, _ face: Face, _ s: String, _ f: NSFont, cx: CGFloat = 512, y: CGFloat, _ color: NSColor) {
        face.drawLeft(g, s, font: f, x: cx - Typo.width(s, f) / 2, y: y, color: color)
    }

    /// 空狀態／說明：大符號（App 色）＋標題＋說明（置中，SF Pro）；回傳說明最後一行的基線
    @discardableResult
    static func emptyState(_ g: CGContext, _ face: Face, symbol: String, tint: NSColor, title: String, body: String?, top: CGFloat = 250,
                           titleColor: NSColor? = nil, bodyColor: NSColor? = nil) -> CGFloat {
        HPAX.note(g, CGRect(x: 112, y: top, width: 800, height: 128 + 84 + 60 + (body == nil ? 0 : 150)), .text, [title, body].compactMap { $0 }.joined(separator: "\n"))   // 2.0 P05
        face.drawSymbol(g, symbol, in: CGRect(x: 512 - 64, y: top, width: 128, height: 128), color: tint)
        let tf = fitted(title, size: 48, weight: .bold, maxWidth: 860)
        var y = top + 128 + 84
        for l in MediaUI.wrap(title, tf, 860, maxLines: 2) { center(g, face, l, tf, y: y, titleColor ?? label); y += 60 }
        if let body {
            let bf = sf(34, weight: .regular)
            y += 4
            for l in MediaUI.wrap(body, bf, 800, maxLines: 4) { center(g, face, l, bf, y: y, bodyColor ?? secondary); y += 46 }
        }
        return y - 46
    }

    // MARK: 家庭磚（R8：3×3 正方磚、開＝不透明白、關＝灰色半透明；磚是內容層，不進玻璃）

    /// 磚的形狀與底：fill 給了＝開（不透明＋卡片陰影），nil＝關（半透明灰）；按下放大 1.08 並變亮。content 畫圖示與標籤
    static func homeTile(_ g: CGContext, _ r: CGRect, radius: CGFloat = HPTokens.Radius.tile, fill: NSColor?, content: @escaping (CGContext) -> Void) {
        let k = Press.scale(r), rr = k == 1 ? r : scaled(r, k)
        let path = continuousRoundedRect(rr, radius: radius * k)
        if let fill {
            g.saveGState()
            HPTokens.Shadow.card.apply(g)
            g.addPath(path); g.setFillColor(fill.cgColor); g.fillPath()
            g.restoreGState()
            if Press.amount(r) > 0.01 { g.addPath(path); g.setFillColor(NSColor(white: 1, alpha: 0.2 * Press.amount(r)).cgColor); g.fillPath() }
            content(g)
        } else {
            // 關著：半透明灰（影片 O-61 #736A63 的霧感）；磚是內容層，不進 GlassPass（chan-notes G1）
            g.addPath(path); g.setFillColor((HPTokens.dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0.32, alpha: 0.32)).cgColor); g.fillPath()
            if Press.amount(r) > 0.01 { g.addPath(path); g.setFillColor(NSColor(white: 1, alpha: 0.18 * Press.amount(r)).cgColor); g.fillPath() }
            content(g)
        }
    }
    /// 磚底部的兩行標籤（名稱 semibold 30、狀態 regular 26，置中）
    static func homeTileLabels(_ g: CGContext, _ face: Face, _ r: CGRect, _ name: String, _ sub: String, ink: NSColor, subInk: NSColor) {
        HPAX.note(g, r, .button, name, value: sub, shape: .rounded(HPTokens.Radius.tile))   // 2.0 P05：磚＝按鈕，狀態是值
        let nf = fitted(name, size: 30, weight: .semibold, maxWidth: r.width - 36)
        center(g, face, Face.clipped(name, nf, r.width - 36), nf, cx: r.midX, y: r.maxY - 74, ink)
        let sf = fitted(sub, size: 26, weight: .regular, maxWidth: r.width - 36)
        center(g, face, Face.clipped(sub, sf, r.width - 36), sf, cx: r.midX, y: r.maxY - 36, subInk)
    }

    // MARK: 小工具框（主畫面 small 小工具：連續圓角 58、上下漸層底；內容由小工具自己畫）

    static func widgetFrame(_ g: CGContext, _ r: CGRect, top: CGColor, bottom: CGColor, radius: CGFloat = HPTokens.Radius.widget) {
        let wpath = continuousRoundedRect(r, radius: radius)
        g.saveGState(); g.addPath(wpath); g.clip()
        let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(grad, start: CGPoint(x: r.midX, y: r.minY), end: CGPoint(x: r.midX, y: r.maxY), options: [])
        g.restoreGState()
    }

    // MARK: 膠囊列（第三輪：ClioTalk 回答裡的行程列——整條膠囊、半徑＝高 ÷ 2；量自官方 siri-calendar：
    // 單行高 113、兩行高 135、左右內縮 46；全天＝淡橘底＋橘圓（d＝0.46 高，圓心離左緣半個高）＋棕字；有時間＝淡藍底＋14 px 藍豎條＋深藍字）

    struct CapsuleRowStyle {
        var fill: NSColor
        var title: NSColor
        var detail: NSColor
        /// 左邊的標記：圓形符號（全天）或圓角豎條（有時間）
        enum Lead { case symbol(String, NSColor), bar(NSColor), none }
        var lead: Lead
        /// 全天：淡橘底 #FFF0DB、橘色行事曆圓 #FF9500、棕字 #845008（官方字實心部分的中位數，對過我們畫出來的同一量法）
        static var allDay: CapsuleRowStyle {
            HPTokens.dark ? CapsuleRowStyle(fill: srgb(0x3A2A12), title: srgb(0xFFC56B), detail: srgb(0xE7B060), lead: .symbol("calendar", srgb(0xFF9F0A)))
                : CapsuleRowStyle(fill: srgb(0xFFF0DB), title: srgb(0x845008), detail: srgb(0x7C4D12), lead: .symbol("calendar", srgb(0xFF9500)))
        }
        /// 有時間：淡藍底 #DAEDFE、藍色豎條 #0088FE、深藍標題 #0A4378、時間 #1A5FA0
        static var timed: CapsuleRowStyle {
            HPTokens.dark ? CapsuleRowStyle(fill: srgb(0x10283F), title: srgb(0xA9D3FF), detail: srgb(0x6FB6FF), lead: .bar(srgb(0x0091FF)))
                : CapsuleRowStyle(fill: srgb(0xDAEDFE), title: srgb(0x0A4378), detail: srgb(0x1A5FA0), lead: .bar(srgb(0x0088FE)))
        }
        /// 一般資料（不是行程）：淺灰底、主文字色
        static var plain: CapsuleRowStyle {
            CapsuleRowStyle(fill: HPTokens.dark ? HPTokens.card : srgb(0xF2F2F7), title: HPTokens.label, detail: HPTokens.secondary, lead: .none)
        }
    }
    static var capsuleRowHeight: CGFloat { HPTokens.Assistant.rowHeight }
    static var capsuleRowInset: CGFloat { HPTokens.Assistant.rowInset }
    /// 2.0 P05：膠囊列要多高——預設字級照官方（113／135）；大字時照換行後的行數長高
    static func capsuleRowHeight(title: String, subtitle: String?, trailing: String?, width: CGFloat) -> CGFloat {
        let base = subtitle == nil ? HPTokens.Assistant.rowHeight : HPTokens.Assistant.rowHeight2
        let k = HPType.textScale
        guard k > 1 else { return base }
        let tf = sf(HPType.Size.rowTitle, weight: .semibold), df = sf(HPType.Size.rowTrailing, weight: .regular)
        let maxW = width - base * k * 0.5 * 0.86 - 33 - 70 - (trailing.map { Typo.width($0, df) + 24 } ?? 0)
        let lines = CGFloat(Face.wrap(title, tf, maxW, maxLines: 3).count)
        let need = lines * (tf.pointSize * 1.2).rounded() + (subtitle == nil ? 0 : (HPType.Size.rowTime * 1.25).rounded()) + 44
        return max(base * k, need.rounded())
    }

    /// 一條膠囊列：標題 semibold 33.8；trailing（例如「all-day」）靠右 regular 29.5；subtitle 給了就是兩行（時間行前面加時鐘符號）
    @discardableResult
    static func capsuleRow(_ g: CGContext, _ face: Face, _ r: CGRect, title: String, subtitle: String? = nil, trailing: String? = nil,
                           style: CapsuleRowStyle) -> CGRect {
        g.addPath(capsulePath(r)); g.setFillColor(style.fill.cgColor); g.fillPath()
        let half = r.height / 2
        var x = r.minX + half * 0.86
        switch style.lead {
        case .symbol(let sym, let color):
            // 圓心離左緣半個高（官方 d 52 @ 高 113，圓心 x＝左緣 + 56）
            let d = (r.height * 0.46).rounded(), c = CGRect(x: r.minX + half - d / 2, y: r.midY - d / 2, width: d, height: d)
            g.setFillColor(color.cgColor); g.fillEllipse(in: c)
            face.drawSymbol(g, sym, in: c.insetBy(dx: d * 0.27, dy: d * 0.27), color: .white, weight: .semibold)
            x = c.maxX + 22
        case .bar(let color):
            // 豎條：離左緣 30、寬 14、高 0.54 × 列高（官方 73 @ 135），上下置中
            let bh = (r.height * 0.54).rounded()
            let bar = CGRect(x: r.minX + 30, y: r.midY - bh / 2, width: 14, height: bh)
            g.addPath(capsulePath(bar)); g.setFillColor(color.cgColor); g.fillPath()
            x = bar.maxX + 24
        case .none: break
        }
        let tf = sf(HPType.Size.rowTitle, weight: .semibold), df = sf(HPType.Size.rowTrailing, weight: .regular), timeF = sf(HPType.Size.rowTime, weight: .regular)
        let right = r.maxX - 33
        var trailW: CGFloat = 0
        if let trailing {
            trailW = Typo.width(trailing, df) + 24
            face.drawLeft(g, trailing, font: df, x: right - Typo.width(trailing, df), y: r.midY + df.capHeight / 2, color: style.detail)
        }
        let maxW = right - trailW - x
        HPAX.note(g, r, .text, [title, subtitle, trailing].compactMap { $0 }.joined(separator: ", "))   // 2.0 P05
        if HPType.textScale > 1 {
            // 2.0 P05 大字：標題放不下就換行（最多三行），不截斷；列高由 capsuleRowHeight 先算好
            let lines = Face.wrap(title, tf, maxW, maxLines: 3), lh = (tf.pointSize * 1.2).rounded()
            let sub = subtitle.map { _ in (timeF.pointSize * 1.25).rounded() } ?? 0
            var yy = r.midY - (CGFloat(lines.count) * lh + sub) / 2 + lh * 0.78
            for l in lines { face.drawLeft(g, l, font: tf, x: x, y: yy, color: style.title); yy += lh }
            if let subtitle {
                let s = timeF.capHeight * 1.05
                face.drawSymbol(g, "clock", in: CGRect(x: x, y: yy - lh * 0.78 + sub * 0.5 - s / 2, width: s, height: s), color: style.detail, weight: .regular)
                face.drawLeft(g, Face.clipped(subtitle, timeF, maxW - s - 8), font: timeF, x: x + s + 8, y: yy - lh * 0.78 + sub * 0.5 + timeF.capHeight / 2, color: style.detail)
            }
            return r
        }
        if let subtitle {
            // 兩行：標題基線＝中線 − 4、時間基線＝中線 + 33（官方 704／741 @ 中線 708）
            face.drawLeft(g, Face.clipped(title, tf, maxW), font: tf, x: x - 2, y: r.midY - 4, color: style.title)
            let s = timeF.capHeight * 1.05
            face.drawSymbol(g, "clock", in: CGRect(x: x, y: r.midY + 33 - timeF.capHeight / 2 - s / 2, width: s, height: s), color: style.detail, weight: .regular)
            face.drawLeft(g, Face.clipped(subtitle, timeF, maxW - s - 8), font: timeF, x: x + s + 8, y: r.midY + 33, color: style.detail)
        } else {
            face.drawLeft(g, Face.clipped(title, tf, maxW), font: tf, x: x, y: r.midY + tf.capHeight / 2, color: style.title)
        }
        return r
    }

    /// 回答裡的來源小晶片（「Wikipedia」「+3」）：淺灰實心膠囊、深灰字；高 40，只有一兩個字時是正圓。回傳框
    @discardableResult
    static func sourceChip(_ g: CGContext, _ face: Face, x: CGFloat, y: CGFloat, _ title: String) -> CGRect {
        let f = sf(HPType.Size.sourceChip, weight: .regular), h = HPTokens.Assistant.chipHeight
        let w = max(h, Typo.width(title, f) + 26)   // 官方「Wikipedia」字 94、晶片 120
        let r = CGRect(x: x, y: y, width: w, height: h)
        g.addPath(capsulePath(r)); g.setFillColor((HPTokens.dark ? NSColor(white: 1, alpha: 0.12) : srgb(0xF5F5F5)).cgColor); g.fillPath()
        center(g, face, title, f, cx: r.midX, y: r.midY + f.capHeight / 2, HPTokens.dark ? NSColor(white: 1, alpha: 0.7) : srgb(0x6E6E73))
        return r
    }

    /// 一行帶重點詞的字（HPType.richWrap 排好的一行）；x 是起點、y 是基線
    static func drawRich(_ g: CGContext, _ face: Face, _ line: [HPType.Run], size: CGFloat, x: CGFloat, y: CGFloat, color: NSColor,
                         weight: NSFont.Weight = .regular, boldWeight: NSFont.Weight = .bold) {
        let reg = sf(size, weight: weight), bf = sf(size, weight: boldWeight)
        var cx = x
        for r in line {
            let f = r.bold ? bf : reg
            face.drawLeft(g, r.text, font: f, x: cx, y: y, color: color)
            cx += Typo.width(r.text, f)
        }
    }

    /// 助理的珠（👀 膠囊在 ClioTalk 裡變成的那顆）：黑色玻璃球——上半近黑、中間一道折射的亮帶（暖→白→冷）、下半透出底色漸亮，
    /// 底下一圈柔影。只畫珠本身；眼睛由呼叫的人畫在上面（不改眼睛的樣子）。shape 給了就照它裁（膠囊正在變成圓）
    static func assistantOrb(_ g: CGContext, _ r: CGRect, shape: CGPath? = nil, alpha: CGFloat = 1) {
        guard alpha > 0.003 else { return }
        let path = shape ?? CGPath(ellipseIn: r, transform: nil)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)
        g.saveGState()
        g.setAlpha(alpha)
        g.beginTransparencyLayer(auxiliaryInfo: nil)
        // 柔影（官方珠下緣外 10–14 px 還有一圈淡灰）。CG 的陰影位移在裝置座標（y 往上），往下要給負值
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: -r.height * 0.08), blur: r.height * 0.24, color: NSColor(white: 0, alpha: 0.2).cgColor)
        g.addPath(path); g.setFillColor(NSColor(white: 0.08, alpha: 1).cgColor); g.fillPath()
        g.restoreGState()
        g.addPath(path); g.clip()
        func lin(_ stops: [(CGFloat, UInt32, CGFloat)], _ a: CGPoint, _ b: CGPoint) {
            let grad = CGGradient(colorsSpace: cs, colors: stops.map { srgb($0.1, $0.2).cgColor } as CFArray, locations: stops.map(\.0))!
            g.drawLinearGradient(grad, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        func at(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: r.minX + r.width * fx, y: r.minY + r.height * fy) }
        // 1. 上半：近黑的玻璃（官方中線取樣 #1A1714 → #110F0D → #27241F）
        lin([(0, 0x1A1714, 1), (0.16, 0x110F0D, 1), (0.34, 0x26231F, 1), (0.46, 0x4A3F34, 1)], at(0.5, 0), at(0.5, 0.5))
        // 2. 下半：一團透出白底的「液面」——上緣是一道微微拱起的弧（官方：左低、中間偏右最高、右邊落下）
        let liquid = CGMutablePath()
        liquid.move(to: at(-0.05, 0.50))
        liquid.addCurve(to: at(1.05, 0.56), control1: at(0.30, 0.40), control2: at(0.72, 0.42))
        liquid.addLine(to: at(1.05, 1.1)); liquid.addLine(to: at(-0.05, 1.1)); liquid.closeSubpath()
        g.saveGState(); g.addPath(liquid); g.clip()
        lin([(0.44, 0x8F95A3, 1), (0.56, 0x7C7F87, 1), (0.72, 0x9C9DA0, 1), (0.86, 0xC8C8CA, 1), (1, 0xEFEFF1, 1)], at(0.5, 0.42), at(0.5, 1))
        // 下半右邊亮、左下暗一點（球面）
        lin([(0, 0x000000, 0.16), (0.55, 0x000000, 0), (1, 0xFFFFFF, 0.22)], at(0.05, 0.95), at(0.95, 0.55))
        g.restoreGState()
        // 3. 液面上緣的折射亮帶：暖 → 白 → 冷，柔一點
        g.saveGState()
        g.addPath(liquid); g.setLineWidth(r.height * 0.07); g.replacePathWithStrokedPath(); g.clip()
        lin([(0, 0xC9925A, 0.0), (0.18, 0xD9A26A, 0.9), (0.42, 0xFFFDF6, 1), (0.66, 0xF2F6FF, 0.95), (0.84, 0x7C93C8, 0.85), (1, 0x5A6FA8, 0.0)], at(0, 0.5), at(1, 0.5))
        g.restoreGState()
        // 4. 邊緣：上半一圈更暗（玻璃的厚度），下半一圈細亮邊
        let c = CGPoint(x: r.midX, y: r.midY)
        let edge = CGGradient(colorsSpace: cs, colors: [NSColor(white: 0, alpha: 0).cgColor, NSColor(white: 0, alpha: 0.3).cgColor] as CFArray, locations: [0.7, 1])!
        g.drawRadialGradient(edge, startCenter: c, startRadius: 0, endCenter: c, endRadius: max(r.width, r.height) / 2, options: [])
        g.saveGState()
        g.addPath(path); g.setLineWidth(r.height * 0.05); g.replacePathWithStrokedPath(); g.clip()
        lin([(0.5, 0xFFFFFF, 0), (0.8, 0xFFFFFF, 0.55), (1, 0xFFFFFF, 0.8)], at(0.5, 0), at(0.5, 1))
        g.restoreGState()
        g.endTransparencyLayer()
        g.restoreGState()
    }

    /// 動畫或按下進行中：App 的 tick 要回 true（每個 App 的 tick 開頭都問一次）
    static func needsFrame(_ now: Double) -> Bool { Press.update() || Anim.active || CACurrentMediaTime() - spinnerDrawnAt < 0.25 }
}
