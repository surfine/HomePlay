// 2.0 cc：控制中心的畫法（照本機 macOS 27 截圖量的尺寸；字級照 HPType 放大到 HomeView 的觀看距離）。
//
// 一幀的順序：霧化壓暗的底（iOS 的 platter）→ 所有模組的形狀進同一個 HPGlass.container（Regular 玻璃，flush 一次；
// 玻璃上的符號、字、滑桿水位、開著的白圓都是填色，不再疊玻璃）→ 拖著的滑桿旋鈕變玻璃（HPDS 4）。
// 截圖量到的（128 格）：膠囊左邊 28 放 72 的圓；標題基線離頂 44、副標 24 一行；2×2 圖示 80 在 (28, 28)、標題基線 171、
// 控制列中心 221；寬滑桿標題基線 48、軌道高 8 在中線 +20（83.5）、左右 73／77；AirPlay 圓鈕 49、右 30；
// 模組底色在黑底上 (31,31,31)、緣 (48–52)；關著的圓 (90,90,90)＝白 30%；軌道沒滿的部分 (52,52,52)。

import AppKit
import CoreImage

/// 畫的時候記下來的可點區域（點按、輔助使用都用這份）
struct CCHit {
    enum Action: Equatable {
        case module(ControlCenter.Tile), slider(ControlCenter.Tile), airplay
        case edit, add, done, page(Int)
        case remove(ControlCenter.Tile), resize(ControlCenter.Tile)
        case galleryAdd(ControlCenter.Tile), galleryClose
        case header(ControlCenter.Tile), settings(ControlCenter.Tile)
        case wifiRow, btDevice(String), focusMode(String), output(UInt32)
        case homeTile(String), scene(String), homeOpen
        case npPrev, npPlay, npNext
        case darkRow, nightRow
    }
    var rect: CGRect
    var action: Action
    var label: String
    var value: String? = nil
    var toggle: Bool? = nil
    var level: Double? = nil
}

extension ControlCenter {
    nonisolated(unsafe) static var hits: [CCHit] = []
    nonisolated(unsafe) private static var dimmedCache: (src: ObjectIdentifier, dark: Bool, image: CGImage)?
    /// 圖庫捲動（畫布 px）
    nonisolated(unsafe) static var galleryScroll: CGFloat = 0
    nonisolated(unsafe) static var galleryContentH: CGFloat = 0

    /// iOS 的 platter：暗色壓 38% 黑；淺色洗 28% 白（兩種都先霧化 σ30）
    static func platter(dark: Bool) -> NSColor { dark ? NSColor.black.withAlphaComponent(0.38) : NSColor.white.withAlphaComponent(0.28) }

    static func draw(_ g: CGContext, face: Face, now: Double) {
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let a = max(0, min(1, Shell.ccT))   // 2.0 R14：ccT 已經是彈簧（或跟手）的值，不再套曲線
        let dark = HPTokens.dark
        // 底下的畫面：打開那一刻拍下來霧化（之後不必每幀模糊整面）
        if Shell.ccBackdrop == nil, let shot = g.makeImage() {
            let ci = CIImage(cgImage: shot)
            let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: Double(shot.width) / 1024 * 30).cropped(to: ci.extent)
            Shell.ccBackdrop = Face.ciContext.createCGImage(blurred, from: ci.extent)
            dimmedCache = nil
        }
        g.saveGState()
        g.setAlpha(a)
        if let b = Shell.ccBackdrop { face.drawUpright(g, b, in: full) }
        g.setFillColor(platter(dark: dark).cgColor); g.fill(full)
        g.restoreGState()
        // 玻璃取樣的背景＝霧化＋壓暗的底（玻璃不取樣玻璃；模組跟著位移時背景不動）
        if let b = Shell.ccBackdrop, dimmedCache?.src != ObjectIdentifier(b) || dimmedCache?.dark != dark {
            dimmedCache = (ObjectIdentifier(b), dark, makeImage(b.width, b.height) { c in
                c.scaleBy(x: CGFloat(b.width) / 1024, y: CGFloat(b.height) / 1024)
                face.drawUpright(c, b, in: full)
                c.setFillColor(platter(dark: dark).cgColor); c.fill(full)
            })
        }

        hits = []
        g.saveGState()
        g.setAlpha(a)
        // 2.0 depth：減少動態效果＝沒有出場位移，整層照上面的 alpha 交叉淡化（HIG：大的位移動畫改成淡入淡出）
        if !HPMotion.reduceMotion { g.translateBy(x: 0, y: -HPMotion.T.ccTravel * (1 - Shell.ccT)) }   // 動效包：手指拉多少磚就走多少（1:1）；拉過頭（rubber band）時再往下一點
        let ek = max(0, min(1.2, expandAnim.value(now)))
        let gk = max(0, min(1, galleryAnim.value(now)))
        let editK = max(0, min(1, editAnim.value(now)))
        let pagePos = pageAnim.value(now)
        var shown: [Tile: CGRect] = [:]
        HPGlass.container("cc") {
            // 模組（展開或圖庫打開時其他模組 materialize 退場：形狀與光學一起收，不是改透明度）
            let others = max(0, 1 - 2.2 * max(min(1, ek), gk))   // 卡長到四成多時其他模組已經收完，不跟大卡疊在一起
            for p in layout.pages.indices where abs(CGFloat(p) - pagePos) < 1 {
                let dy = (CGFloat(p) - pagePos) * 1024
                for pl in placed(page: p) {
                    let t = pl.slot.tile
                    if t == expanded || (expanded == nil && ek > 0.001 && expandFrom != .zero && t == lastExpanded) { continue }
                    if drag?.tile == t { continue }
                    var r = p == page ? shownRect(t, now: now) : frame(col: pl.col, row: pl.row, size: pl.slot.size)
                    r = r.offsetBy(dx: 0, dy: dy)
                    if p == page { shown[t] = r }
                    addModule(t, r, pl.slot.size, face: face, now: now, presence: others, editK: editK, live: p == page && others > 0.99)
                }
            }
            // 拖著排序的模組：跟著手指，略放大
            if let d = drag {
                let s = size(d.tile), base = frame(col: 0, row: 0, size: s)
                let r = CGRect(x: d.at.x - d.grab.x, y: d.at.y - d.grab.y, width: base.width, height: base.height)
                let big = CGRect(x: r.midX - r.width * 0.53, y: r.midY - r.height * 0.53, width: r.width * 1.06, height: r.height * 1.06)
                addModule(d.tile, big, s, face: face, now: now, presence: 1, editK: editK, live: false)
            }
            // 展開的大卡：從模組原本的位置長出來
            if let t = expanded ?? (ek > 0.001 ? lastExpanded : nil), expandFrom != .zero {
                drawExpanded(t, k: ek, face: face, now: now)
            }
            // 底下的膠囊：編輯控制項目／加入控制項目＋完成；右緣頁點
            if gk < 0.999 { addBottomBar(face: face, editK: editK, presence: max(0, 1 - max(min(1, ek), gk))) }
            if gk > 0.001 { drawGallery(face: face, k: gk, now: now) }
        }
        if !shown.isEmpty { lastShown = shown }
        drawPageDots(g, pagePos: pagePos, alpha: max(0, 1 - max(min(1, ek), gk)))
        HPGlass.flush(g, face: face, backdrop: dimmedCache?.image, now: now)   // Regular（底下暗，小模組自己翻成深版）
        g.restoreGState()
    }
    nonisolated(unsafe) static var lastExpanded: Tile?

    // MARK: 模組

    private static func addModule(_ t: Tile, _ r: CGRect, _ s: CCSize, face: Face, now: Double, presence: CGFloat, editK: CGFloat, live: Bool) {
        guard presence > 0.001, r.maxY > -40, r.minY < 1064 else { return }
        let path = shape(r, s)
        let lock = locked(t)
        HPGlass.add(path, interactive: live && editK < 0.01, union: nil, presence: presence) { c in
            c.saveGState()
            if lock { c.setAlpha(0.5) }
            drawModule(c, t, r, s, face: face, now: now)
            c.restoreGState()
            if lock {   // 鎖著：右上一顆小鎖（不只靠變淡）
                let b = s == .s1x1 ? CGRect(x: r.maxX - 40, y: r.minY + 4, width: 34, height: 34) : CGRect(x: r.maxX - 52, y: r.minY + 18, width: 30, height: 30)
                face.drawSymbol(c, "lock.fill", in: b, color: HPGlass.ink.withAlphaComponent(0.85))
            }
            if editK > 0.001 { drawEditBadges(c, t, r, s, face: face, k: editK) }
        }
        if t.isSlider, presence > 0.99 { addSliderKnob(t, r, s, big: false) }
        guard live else { return }
        hits += moduleHits(t, r, s, face: face, now: now, editing: editK > 0.5)
    }

    /// 一個模組的可點區域（畫的時候記；輔助使用在還沒畫過時也用它算）
    static func moduleHits(_ t: Tile, _ r: CGRect, _ s: CCSize, face: Face, now: Double, editing: Bool) -> [CCHit] {
        var hits: [CCHit] = []
        let on = t.isToggle ? isOn(t, face: face) : nil
        let label = title(t)
        if editing {
            hits.append(CCHit(rect: r, action: .module(t), label: label))
            hits.append(CCHit(rect: CGRect(x: r.minX - 16, y: r.minY - 16, width: 64, height: 64), action: .remove(t),
                              label: String(format: L("cc.a11y.remove", "移除“%@”"), label)))
            if t.sizes.count > 1 {
                hits.append(CCHit(rect: CGRect(x: r.maxX - 56, y: r.maxY - 56, width: 72, height: 72), action: .resize(t),
                                  label: String(format: L("cc.a11y.resize", "更改“%@”的大小"), label)))
            }
            return hits
        }
        if t.isSlider {
            let v = Double(t == .volume ? volume : Float(Shell.brightness))
            hits.append(CCHit(rect: r, action: .slider(t), label: label, value: "\(Int((v * 100).rounded()))%", level: v))
            if t == .volume, s == .s4x1, !outputsLocked { hits.append(CCHit(rect: airplayRect(r).insetBy(dx: -16, dy: -16), action: .airplay, label: "AirPlay")) }
            return hits
        }
        if t == .nowPlaying {
            let info = locked(.nowPlaying) ? nil : nowInfo(face, now)
            if locked(.nowPlaying) { hits.append(CCHit(rect: r, action: .module(t), label: label, value: L("guest.needsOwner", "需要主人"))); return hits }
            if let c = npControls(r, s) {
                if !c.prev.isNull { hits.append(CCHit(rect: c.prev, action: .npPrev, label: L("cc.np.previous", "上一首"))) }
                hits.append(CCHit(rect: c.play, action: .npPlay, label: info?.playing == true ? L("cc.np.pause", "暂停") : L("cc.np.play", "播放")))
                if !c.next.isNull { hits.append(CCHit(rect: c.next, action: .npNext, label: L("cc.np.next", "下一首"))) }
            }
            hits.append(CCHit(rect: r, action: .module(t), label: info.map { String(format: L("a11y.nowPlaying", "正在播放：%@"), $0.title) } ?? L("cc.notPlaying", "未在播放")))
            return hits
        }
        hits.append(CCHit(rect: r, action: .module(t), label: label, value: subtitle(t, face: face), toggle: locked(t) ? nil : on))
        return hits
    }
    /// 還沒畫過時（自檢、剛打開）：照版面算目前這頁的
    static func moduleHits(face: Face) -> [CCHit] {
        let now = CACurrentMediaTime()
        return placed(page: page).flatMap { moduleHits($0.slot.tile, frame(col: $0.col, row: $0.row, size: $0.slot.size), $0.slot.size, face: face, now: now, editing: editing) }
            + bottomButtons(editing: editing).map { CCHit(rect: $0.0, action: $0.1, label: $0.2) }
    }

    /// 白圓（開著）或淡圓（關著）上的符號：膠囊左邊那顆、圓鈕整顆
    private static func glyphDisc(_ c: CGContext, _ face: Face, _ d: CGRect, _ t: Tile, on: Bool, whole: Bool) {
        let ink = HPGlass.ink
        let lightGlass = !HPGlass.inkIsLight
        let fill: NSColor, sym: NSColor
        if on {
            // 深玻璃：白圓＋彩色符號（macOS 27 的 Wi‑Fi）；淺玻璃：彩色圓＋白符號（iOS 淺色）
            fill = lightGlass ? accent(t) : .white
            sym = lightGlass ? .white : accent(t)
        } else {
            fill = whole ? .clear : ink.withAlphaComponent(lightGlass ? 0.10 : 0.30)
            sym = ink
        }
        if fill != .clear { c.setFillColor(fill.cgColor); c.fillEllipse(in: d) }
        let k: CGFloat = whole ? 0.40 : 0.44
        drawGlyph(c, face, symbol(t), in: d.insetBy(dx: d.width * (1 - k) / 2, dy: d.height * (1 - k) / 2), color: sym)
    }
    /// SF Symbols 沒有公開的藍牙符號：自己畫那個符文（兩個三角＋中線，圓角筆畫）
    static func drawGlyph(_ c: CGContext, _ face: Face, _ name: String, in r: CGRect, color: NSColor) {
        guard name == "bluetooth" else {
            // 系統檔裡讀到的符號名，這台 Mac 的 SF Symbols 沒有就退回月亮（專注模式的預設符號）
            face.drawSymbol(c, NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil ? "moon.fill" : name, in: r, color: color, weight: .semibold); return
        }
        let h = r.height, w = h * 0.56, x0 = r.midX - w / 2, y0 = r.minY
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x0 + w * x, y: y0 + h * y) }
        c.saveGState()
        c.setStrokeColor(color.cgColor); c.setLineWidth(h * 0.1); c.setLineCap(.round); c.setLineJoin(.round)
        c.addLines(between: [p(0, 0.28), p(1, 0.72), p(0.5, 1), p(0.5, 0), p(1, 0.28), p(0, 0.72)])
        c.strokePath()
        c.restoreGState()
    }

    static func drawModule(_ c: CGContext, _ t: Tile, _ r: CGRect, _ s: CCSize, face: Face, now: Double) {
        let ink = HPGlass.ink
        let sub = ink.withAlphaComponent(HPAccessibility.increaseContrast ? 0.8 : 0.62)
        let on = isOn(t, face: face)
        if t == .nowPlaying { drawNowPlaying(c, r, s, face: face, now: now); return }
        if t.isSlider { drawSlider(c, t, r, s, face: face, big: false); return }
        switch s {
        case .s1x1:
            glyphDisc(c, face, r, t, on: on && t.isToggle, whole: true)
        default:
            let d = CGRect(x: r.minX + 28, y: r.midY - 36, width: 72, height: 72)
            glyphDisc(c, face, d, t, on: on && (t.isToggle || t == .home), whole: false)
            let x = d.maxX + 14, w = r.maxX - x - 24
            let tf = Face.fitted(title(t), size: 30, weight: .semibold, maxWidth: w, minScale: 0.75)
            if let st = subtitle(t, face: face) {
                // 副標放不下一行就折兩行、標題往上讓（macOS 27 的 Wi‑Fi 網路名稱也是折行，不截斷）
                let sf = HPType.sf(26)
                let lines = Face.wrap(st, sf, w, maxLines: 2)
                let y0 = lines.count > 1 ? r.minY + 44 : r.midY - 6
                face.drawLeft(c, Face.clipped(title(t), tf, w), font: tf, x: x, y: y0, color: ink)
                for (i, l) in lines.enumerated() { face.drawLeft(c, l, font: sf, x: x, y: y0 + 34 + CGFloat(i) * 30, color: sub) }
            } else {
                face.drawLeft(c, Face.clipped(title(t), tf, w), font: tf, x: x, y: r.midY + 11, color: ink)
            }
        }
    }

    // MARK: 滑桿

    static func airplayRect(_ r: CGRect) -> CGRect { CGRect(x: r.maxX - 30 - 52, y: r.minY + 84 - 26, width: 52, height: 52) }
    /// 軌道（寬滑桿：截圖左 73、右 77，聲音右邊讓給喇叭符號與 AirPlay；2×1：沒有標題，軌道在中線）
    static func track(_ t: Tile, _ r: CGRect, _ s: CCSize, big: Bool) -> CGRect {
        if big { return CGRect(x: r.minX + 96, y: r.minY + 150, width: r.width - 192, height: 14) }
        if s == .s2x1 { return CGRect(x: r.minX + 72, y: r.midY - 4, width: r.width - 72 - 40, height: 8) }
        let right: CGFloat = t == .volume ? 156 : 77
        return CGRect(x: r.minX + 73, y: r.minY + 80, width: r.width - 73 - right, height: 8)
    }
    static func level(_ t: Tile) -> CGFloat { t == .volume ? CGFloat(volume) : Shell.brightness }

    private static func drawSlider(_ c: CGContext, _ t: Tile, _ r: CGRect, _ s: CCSize, face: Face, big: Bool) {
        let ink = HPGlass.ink, lightGlass = !HPGlass.inkIsLight
        let tr = track(t, r, s, big: big)
        if s == .s4x1 || big {
            let f = HPType.sf(big ? 40 : 28, .bold)
            face.drawLeft(c, title(t), font: f, x: r.minX + (big ? 40 : 32), y: r.minY + (big ? 76 : 48), color: ink)
        }
        let lv = max(0, min(1, level(t)))
        AppUI.fillPill(c, tr, color: ink.withAlphaComponent(lightGlass ? 0.12 : 0.14))
        if lv > 0.001 { AppUI.fillPill(c, CGRect(x: tr.minX, y: tr.minY, width: max(tr.height, tr.width * lv), height: tr.height), color: ink.withAlphaComponent(0.96)) }
        // 兩端的符號（顯示器：小太陽／大太陽；聲音：喇叭／喇叭有聲波）
        let ih: CGFloat = big ? 40 : 30
        let lo = t == .volume ? "speaker.fill" : "sun.min", hi = t == .volume ? "speaker.wave.3.fill" : "sun.max.fill"
        face.drawSymbol(c, lo, in: CGRect(x: tr.minX - (big ? 64 : 46), y: tr.midY - ih / 2, width: ih, height: ih), color: ink.withAlphaComponent(0.9))
        if s != .s2x1 || big {
            face.drawSymbol(c, hi, in: CGRect(x: tr.maxX + (big ? 20 : 12), y: tr.midY - ih / 2, width: ih * 1.2, height: ih), color: ink.withAlphaComponent(0.9))
        }
        if t == .volume, s == .s4x1, !big, !outputsLocked {
            let ar = airplayRect(r)
            c.setFillColor(ink.withAlphaComponent(lightGlass ? 0.10 : 0.30).cgColor); c.fillEllipse(in: ar)
            face.drawSymbol(c, "airplayaudio", in: ar.insetBy(dx: 13, dy: 13), color: ink)
        }
    }
    /// 拖著：旋鈕變成玻璃、略放大（Adopting Liquid Glass）；放開就收回成實心的水位。
    /// 要在模組的 content 之外加（content 是 flush 裡畫的，那時再加玻璃會漏到下一幀）
    static func addSliderKnob(_ t: Tile, _ r: CGRect, _ s: CCSize, big: Bool) {
        guard sliding == t else { return }
        let tr = track(t, r, s, big: big), lv = max(0, min(1, level(t)))
        let kh: CGFloat = big ? 46 : 30, kw = kh * 1.5
        HPGlass.addKnob(CGRect(x: tr.minX + tr.width * lv - kw / 2, y: tr.midY - kh / 2, width: kw, height: kh), moving: slideAnim.value(CACurrentMediaTime()))
    }

    // MARK: 播放中

    static func nowInfo(_ face: Face, _ now: Double) -> NowPlayingInfo? {
        NowPlayingPage.shared.demo?.info ?? (face.musicActive(now) ? (face.nowPlaying.info ?? face.nowPlaying.shown) : nil)   // v2-music：示範也一致
    }
    /// 專輯封面（跟「播放中」頁同一張，v2-music）；沒有封面才用播放器的 App 圖示
    static func drawArt(_ c: CGContext, _ face: Face, _ ir: CGRect, info: NowPlayingInfo?, ink: NSColor, lightGlass: Bool) {
        let rad = ir.width * 0.225
        if info != nil, let cover = NowPlayingPage.shared.artwork(face: face) {
            c.saveGState(); c.addPath(continuousRoundedRect(ir, radius: rad)); c.clip()
            MediaUI.drawCover(c, face: face, cover, in: ir)
            c.restoreGState(); return
        }
        AppUI.fillRound(c, ir, radius: rad, color: ink.withAlphaComponent(lightGlass ? 0.08 : 0.14))
        if let img = appIcon(info == nil ? nil : NowPlayingPoller.shared.activeBundle) { face.drawUpright(c, img, in: ir.insetBy(dx: ir.width * 0.12, dy: ir.width * 0.12)) }
        else { face.drawSymbol(c, "music.note", in: ir.insetBy(dx: ir.width * 0.3, dy: ir.width * 0.3), color: ink.withAlphaComponent(0.7)) }
    }
    /// 播放器的 App 圖示（macOS 控制中心「播放中」放的就是 App 圖示）
    nonisolated(unsafe) private static var iconCache: [String: CGImage] = [:]
    static func appIcon(_ bundle: String?) -> CGImage? {
        guard let b = bundle else { return nil }
        if let c = iconCache[b] { return c }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) else { return nil }
        var rect = CGRect(x: 0, y: 0, width: 160, height: 160)
        let img = NSWorkspace.shared.icon(forFile: url.path).cgImage(forProposedRect: &rect, context: nil, hints: nil)
        if let img { iconCache[b] = img }
        return img
    }
    static func npControls(_ r: CGRect, _ s: CCSize) -> (prev: CGRect, play: CGRect, next: CGRect)? {
        let sz: CGFloat = 88
        func at(_ x: CGFloat, _ y: CGFloat) -> CGRect { CGRect(x: x - sz / 2, y: y - sz / 2, width: sz, height: sz) }
        switch s {
        case .s2x2: return (at(r.minX + 58, r.minY + 221), at(r.minX + 140, r.minY + 221), at(r.minX + 222, r.minY + 221))
        case .s4x2: let x0 = r.minX + 280 + 24
            return (at(x0 + 70, r.minY + 221), at(x0 + 152, r.minY + 221), at(x0 + 234, r.minY + 221))
        case .s2x1: return (.null, at(r.maxX - 64, r.midY), .null)
        default: return nil
        }
    }

    private static func drawNowPlaying(_ c: CGContext, _ r: CGRect, _ s: CCSize, face: Face, now: Double) {
        let ink = HPGlass.ink, lightGlass = !HPGlass.inkIsLight
        let hidden = locked(.nowPlaying)   // 遠端訪客：不露曲名與 App
        let info = hidden ? nil : nowInfo(face, now)
        func icon(_ ir: CGRect) { drawArt(c, face, ir, info: info, ink: ink, lightGlass: lightGlass) }
        let tf = HPType.sf(30, .semibold), sf = HPType.sf(26)
        let title = hidden ? L("cc.nowPlaying", "播放中") : (info?.title ?? L("cc.notPlaying", "未在播放"))
        let ctlInk = info == nil ? ink.withAlphaComponent(0.4) : ink
        func controls() {
            guard let ctl = npControls(r, s) else { return }
            if !ctl.prev.isNull { face.drawSymbol(c, "backward.fill", in: ctl.prev.insetBy(dx: 22, dy: 30), color: ctlInk) }
            face.drawSymbol(c, info?.playing == true ? "pause.fill" : "play.fill", in: ctl.play.insetBy(dx: 24, dy: 22), color: ctlInk)
            if !ctl.next.isNull { face.drawSymbol(c, "forward.fill", in: ctl.next.insetBy(dx: 22, dy: 30), color: ctlInk) }
        }
        switch s {
        case .s2x2:
            icon(CGRect(x: r.minX + 28, y: r.minY + 28, width: 80, height: 80))
            let w = r.width - 56
            face.drawLeft(c, Face.clipped(title, tf, w), font: tf, x: r.minX + 30, y: r.minY + 156, color: ink)
            if let a = info?.artist, !a.isEmpty { face.drawLeft(c, Face.clipped(a, sf, w), font: sf, x: r.minX + 30, y: r.minY + 188, color: ink.withAlphaComponent(0.62)) }
            controls()
        case .s4x2:
            icon(CGRect(x: r.minX + 28, y: r.minY + 28, width: 224, height: 224))
            let x = r.minX + 280 + 24, w = r.maxX - x - 28
            face.drawLeft(c, Face.clipped(title, tf, w), font: tf, x: x, y: r.minY + 80, color: ink)
            if let a = info?.artist, !a.isEmpty { face.drawLeft(c, Face.clipped(a, sf, w), font: sf, x: x, y: r.minY + 114, color: ink.withAlphaComponent(0.62)) }
            controls()
        default:
            let d = CGRect(x: r.minX + 28, y: r.midY - 36, width: 72, height: 72)
            icon(d)
            let x = d.maxX + 14, w = r.maxX - x - 110
            face.drawLeft(c, Face.clipped(title, tf, w), font: tf, x: x, y: r.midY + 11, color: ink)
            controls()
        }
    }

    // MARK: 編輯模式的「−」與右下角的大小把手

    private static func drawEditBadges(_ c: CGContext, _ t: Tile, _ r: CGRect, _ s: CCSize, face: Face, k: CGFloat) {
        c.saveGState(); c.setAlpha(k)
        // 「−」：左上，iOS 是灰圓白槓（填色，不是另一塊玻璃）
        let b = CGRect(x: r.minX - 6, y: r.minY - 6, width: 40, height: 40)
        c.setFillColor(NSColor(white: HPGlass.inkIsLight ? 0.42 : 0.62, alpha: 1).cgColor); c.fillEllipse(in: b)
        face.drawSymbol(c, "minus", in: b.insetBy(dx: 11, dy: 11), color: .white, weight: .bold)
        // 換大小：右下角一段跟角同心的弧（iOS 18 的把手）
        if t.sizes.count > 1 {
            let rad: CGFloat = s == .s4x1 ? wideRadius : (s == .s2x2 || s == .s4x2 ? squareRadius : r.height / 2)
            let ctr = CGPoint(x: r.maxX - rad, y: r.maxY - rad)
            c.setStrokeColor(HPGlass.ink.withAlphaComponent(0.95).cgColor); c.setLineWidth(7); c.setLineCap(.round)
            c.addArc(center: ctr, radius: rad - 4, startAngle: .pi * 0.12, endAngle: .pi * 0.38, clockwise: false)
            c.strokePath()
        }
        c.restoreGState()
    }

    // MARK: 底下的膠囊、頁點

    static func bottomButtons(editing e: Bool) -> [(CGRect, CCHit.Action, String, String?)] {
        let y = editCapsuleY, h = capsuleH
        func w(_ s: String, _ sym: Bool) -> CGFloat { Typo.width(s, HPType.sf(28, .semibold)) + 64 + (sym ? 40 : 0) }
        if e {
            let a = L("cc.addControl", "添加控制"), d = L("home.done", "完成")
            let wa = w(a, true), wd = w(d, false), total = wa + 24 + wd
            let x0 = 512 - total / 2
            return [(CGRect(x: x0, y: y, width: wa, height: h), .add, a, "plus"),
                    (CGRect(x: x0 + wa + 24, y: y, width: wd, height: h), .done, d, nil)]
        }
        guard PersonCC.canEdit else { return [] }
        let s = L("cc.editControls", "编辑控制"), ww = w(s, false)
        return [(CGRect(x: 512 - ww / 2, y: y, width: ww, height: h), .edit, s, nil)]
    }

    private static func addBottomBar(face: Face, editK: CGFloat, presence: CGFloat) {
        guard presence > 0.001 else { return }
        for (r, act, label, sym) in bottomButtons(editing: editing) {
            HPGlass.addCapsule(r, interactive: true, presence: presence) { c in
                let f = HPType.sf(28, .semibold)
                let ink = HPGlass.ink.withAlphaComponent(act == .edit ? 0.72 : 1)
                var x = r.minX + 32
                if let sym { face.drawSymbol(c, sym, in: CGRect(x: x, y: r.midY - 15, width: 30, height: 30), color: ink); x += 40 }
                face.drawLeft(c, label, font: f, x: x, y: r.midY + 10, color: ink)
            }
            hits.append(CCHit(rect: r.insetBy(dx: -4, dy: -14), action: act, label: label))   // 點按區至少 88 高
        }
    }

    private static func drawPageDots(_ g: CGContext, pagePos: CGFloat, alpha: CGFloat) {
        let n = layout.pages.count + (editing ? 1 : 0)
        guard n > 1, alpha > 0.01 else { return }
        let gapY: CGFloat = 26, x: CGFloat = 1024 - 30
        let y0 = gridY + gridH / 2 - CGFloat(n - 1) * gapY / 2
        for i in 0..<n {
            let cur = max(0, 1 - abs(CGFloat(i) - pagePos))
            let d: CGFloat = 12
            let col = (HPTokens.dark ? NSColor.white : NSColor.black).withAlphaComponent((0.3 + 0.6 * cur) * alpha)
            g.setFillColor(col.cgColor)
            g.fillEllipse(in: CGRect(x: x - d / 2, y: y0 + CGFloat(i) * gapY - d / 2, width: d, height: d))
            hits.append(CCHit(rect: CGRect(x: x - 30, y: y0 + CGFloat(i) * gapY - 13, width: 60, height: 26), action: .page(i),
                              label: String(format: L("cc.a11y.page", "第 %d 页"), i + 1), value: i == page ? L("cc.a11y.current", "当前") : nil))
        }
    }
}
