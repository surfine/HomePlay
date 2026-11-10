// 錶面「照片」：照 HomeView 的 Portraits——照片滿版，極高窄體的玻璃大時間時在左、分在右，從上緣幾乎到下緣，沒有日期；
// 中間留一道縫給主角與膠囊（官方 faces 片尾幀：數字約佔 6%–94% 的高度，主角站在兩組數字中間、蓋在數字前面）；
// 用 Vision 把人物（前景）摳出來，再蓋回數字與島上面，數字和島都像在人物後面（景深）。沒有前景就整組在最上層。
// 摳圖在背景執行緒做、每張照片只做一次；做好前先照一般疊法畫，好了再重畫一次。
// 2.0 R10：換分鐘時數字翻動（影片 v1 02:57.76→02:58.26 量到：舊位數往上模糊淡出、新位數從下面模糊浮上來，
// 十位數比個位數早約 80 ms，每個位數出→入約 170 ms 重疊，整段約 500 ms；「7」與冒號不動）。快照：HOMEPLAY_ANIM=digits:0.12

import AppKit
import Vision

nonisolated(unsafe) private var subjectMask: (id: ObjectIdentifier, mask: CGImage?)?
nonisolated(unsafe) private var subjectPending: ObjectIdentifier?
nonisolated(unsafe) private var photoBackdrop: (id: ObjectIdentifier, image: CGImage)?
nonisolated(unsafe) private var photoClear: (id: ObjectIdentifier, image: CGImage)?
nonisolated(unsafe) private var subjectCoverCache: (id: ObjectIdentifier, cover: CGFloat)?
nonisolated(unsafe) private var emptyBackdrop: (clear: CGImage, frosted: CGImage)?
/// 換分鐘的翻動：舊的字（時、分）與開始時刻
nonisolated(unsafe) private var digitRoll: (old: (String, String), start: Double)?
nonisolated(unsafe) private var digitShown: (String, String)?
nonisolated(unsafe) private var photosStaticCache: (key: String, image: CGImage)?

extension GlyphShape {
    func offset(_ dx: CGFloat, _ dy: CGFloat) -> GlyphShape {
        var t = CGAffineTransform(translationX: dx, y: dy)
        return GlyphShape(path: path.copy(using: &t) ?? path)
    }
    /// 拆成一個一個字形（外框在 x 上重疊的子路徑算同一個字：0、8 的內圈跟著外圈）；拆不出 count 個回 nil
    func glyphs(_ count: Int) -> [GlyphShape]? {
        var subs: [CGMutablePath] = []
        path.applyWithBlock { e in
            let p = e.pointee.points
            switch e.pointee.type {
            case .moveToPoint: let m = CGMutablePath(); m.move(to: p[0]); subs.append(m)
            case .addLineToPoint: subs.last?.addLine(to: p[0])
            case .addQuadCurveToPoint: subs.last?.addQuadCurve(to: p[1], control: p[0])
            case .addCurveToPoint: subs.last?.addCurve(to: p[2], control1: p[0], control2: p[1])
            case .closeSubpath: subs.last?.closeSubpath()
            @unknown default: break
            }
        }
        var groups: [(x0: CGFloat, x1: CGFloat, path: CGMutablePath)] = []
        for sp in subs.sorted(by: { $0.boundingBoxOfPath.minX < $1.boundingBoxOfPath.minX }) {
            let b = sp.boundingBoxOfPath
            if let i = groups.indices.last, b.minX < groups[i].x1 - 1 { groups[i].path.addPath(sp); groups[i].x1 = max(groups[i].x1, b.maxX) }
            else { let m = CGMutablePath(); m.addPath(sp); groups.append((b.minX, b.maxX, m)) }
        }
        guard groups.count == count else { return nil }
        return groups.map { GlyphShape(path: $0.path) }
    }
}


extension Face {
    func renderPhotosV2(_ g: CGContext, _ now: Double) {
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let date = Self.displayDate
        // 2.0 P10：勾了共享相簿（而且是主人）就用相簿裡的照片，否則照舊用照片資料夾（Shell/SharedAlbums.swift）
        let shared = SharedAlbumFeed.shared.faceImage { [weak self] in self?.forceDirty = true }
        // 2.0：--demo-official 一律用我們自己的示範圖（不讀這台 Mac 的照片；官方對照圖的錶面是滿版照片）
        guard let img = OfficialDemo.on ? PhotosDemoArt.image(px: 1024) : (shared ?? photos.current) else { renderPhotosEmpty(g, date, now); return }
        let s = max(1024 / CGFloat(img.width), 1024 / CGFloat(img.height))
        let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
        let r = CGRect(x: (1024 - w) / 2, y: (1024 - h) / 2, width: w, height: h)
        let id = ObjectIdentifier(img)
        let mask = subjectMaskFor(img, id)
        // 給玻璃的背景：同一張照片的模糊版（每張一次）
        if photoBackdrop?.id != id {
            let small = snapshotBackdrop(px: 256) { c in c.clip(to: full); self.drawUpright(c, img, in: r) }
            photoBackdrop = (id, blurredBackdrop(small, sigma: 14, key: "photoface|\(id.hashValue)"))
        }
        // 玻璃大時間：Portraits 的 Compressed 數字，從上緣往下佔到約 59%，時左分右貼著中縫；沒有日期
        if photoClear?.id != id {   // 清楚的照片（畫成 1024² 一次）給玻璃邊緣折射出細節
            photoClear = (id, snapshotBackdrop(px: 1024) { c in c.clip(to: full); self.drawUpright(c, img, in: r) })
        }
        photosStatic(g, "\(id.hashValue)", date) { c in
            c.saveGState(); c.clip(to: full); self.drawUpright(c, img, in: r); c.restoreGState()
            self.drawPortraitClock(c, date, clear: photoClear?.image, frosted: photoBackdrop?.image, now: now)
        }
        // 島躲在人後面：先畫島，再把人物蓋回來（長成音樂／計時器時改到最上層，字才看得到）
        // 人物把島整個擋住（主角站在正中間）就不躲了，島站到人前面，免得看不到眼睛
        let live = liveT > 0.02 || (mask.map { subjectCover($0, id, photoRect: r) > 0.45 } ?? false)
        if !live { drawPhotosIsland(g, now) }
        // 人物蓋回來（景深）
        if let mask {
            g.saveGState()
            g.translateBy(x: 0, y: r.minY + r.maxY); g.scaleBy(x: 1, y: -1)
            g.clip(to: r, mask: mask)
            g.interpolationQuality = .high
            g.draw(img, in: r)
            g.restoreGState()
        }
        if live { drawPhotosIsland(g, now) }
    }

    /// 島的位置被人物蓋住的比例（0…1）：每張照片算一次
    private func subjectCover(_ mask: CGImage, _ id: ObjectIdentifier, photoRect r: CGRect) -> CGFloat {
        if let c = subjectCoverCache, c.id == id { return c.cover }
        var cover: CGFloat = 0
        let w = Self.islandWidth, h = w * 156 / 420
        let cap = CGRect(x: 512 - w / 2, y: Self.islandY - h / 2, width: w, height: h)
        if let data = mask.dataProvider?.data, let bytes = CFDataGetBytePtr(data), mask.bitsPerPixel == 8 {
            let bpr = mask.bytesPerRow, mw = CGFloat(mask.width), mh = CGFloat(mask.height)
            var sum = 0.0, n = 0.0
            for j in 0..<12 {
                for i in 0..<24 {
                    let x = cap.minX + (CGFloat(i) + 0.5) / 24 * cap.width, y = cap.minY + (CGFloat(j) + 0.5) / 12 * cap.height
                    let px = Int((x - r.minX) / r.width * mw), py = Int((y - r.minY) / r.height * mh)
                    guard px >= 0, py >= 0, px < mask.width, py < mask.height else { continue }
                    sum += Double(bytes[py * bpr + px]) / 255; n += 1
                }
            }
            if n > 0 { cover = CGFloat(sum / n) }
        }
        subjectCoverCache = (id, cover)
        return cover
    }

    /// 島：住在兩組數字中間那道縫的下段（數字長到下緣，島不再壓在數字下面）
    private static let islandWidth: CGFloat = 220, islandY: CGFloat = 846
    private func drawPhotosIsland(_ g: CGContext, _ now: Double) {
        let at = CGPoint(x: 512, y: Self.islandY)
        drawIsland(g, at: at, scale: Self.islandWidth / 588, liveAt: at, now: now)
    }

    /// Portraits 的兩組大數字：頂 58、底 966（官方片尾幀量到約 6%–94%），左右各留 58，中間的縫 248
    private static func portraitDigits(_ date: Date) -> (GlyphShape, GlyphShape) {
        let (hh, mm) = hourMinute(date)
        return portraitDigits(hh, mm)
    }
    private static func portraitDigits(_ hh: String, _ mm: String) -> (GlyphShape, GlyphShape) {
        let look = ClockLook.active, top: CGFloat = 58, h: CGFloat = 908, gap: CGFloat = 248, w = 512 - gap / 2 - 58
        let a = GlyphShape.clock(hh, look: look, height: h, maxWidth: w, at: CGPoint(x: 512 - gap / 2, y: top), anchorX: 1, weightBoost: 0.1)
        let b = GlyphShape.clock(mm, look: look, height: h, maxWidth: w, at: CGPoint(x: 512 + gap / 2, y: top), anchorX: 0, weightBoost: 0.1)
        // 不置中成一組：時貼左欄右緣、分貼右欄左緣，縫永遠在正中（主角與膠囊住在這裡）；字體長不到那麼高就上下置中
        let dy = (top + h / 2) - a.ink.union(b.ink).midY
        return (a.moved(0, dy), b.moved(0, dy))
    }

    /// 沒有照片：內建的抽象漸層桌布（深色底上幾團柔光），同一套 Portraits 版面。錶面上不寫字——
    /// 照片放哪裡由設定的「照片文件夹…」與共享相簿說明交代，不在錶面上教學
    private func renderPhotosEmpty(_ g: CGContext, _ date: Date, _ now: Double) {
        if emptyBackdrop == nil {
            let clear = snapshotBackdrop(px: 512) { c in Self.paintPhotosEmpty(c) }
            emptyBackdrop = (clear, blurredBackdrop(clear, sigma: 14, key: "photosEmpty2"))
        }
        photosStatic(g, "empty", date) { c in
            if let clear = emptyBackdrop?.clear { self.drawUpright(c, clear, in: CGRect(x: 0, y: 0, width: 1024, height: 1024)) }
            else { Self.paintPhotosEmpty(c) }
            self.drawPortraitClock(c, date, clear: emptyBackdrop?.clear, frosted: emptyBackdrop?.frosted, now: now)
        }
        drawPhotosIsland(g, now)
    }

    /// 抽象漸層：深靛底，左上冷藍、右上珊瑚、左下洋紅三團柔光（像相片裡失焦的光），玻璃數字折射得出顏色
    private static func paintPhotosEmpty(_ c: CGContext) {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let base = CGGradient(colorsSpace: cs, colors: [srgb(0x1b2346).cgColor, srgb(0x2c2550).cgColor, srgb(0x3a2140).cgColor] as CFArray, locations: [0, 0.55, 1])!
        c.drawLinearGradient(base, start: .zero, end: CGPoint(x: 0, y: 1024), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        for (x, y, r, hex, a) in [(170.0, 150.0, 560.0, 0x4f7fe0 as UInt32, 0.62), (860, 300, 600, 0xff7d5c, 0.58), (230, 900, 640, 0xc0479c, 0.55), (760, 980, 420, 0xffb36b, 0.30)] {
            let col = srgb(hex)
            let grad = CGGradient(colorsSpace: cs, colors: [col.withAlphaComponent(a).cgColor, col.withAlphaComponent(a * 0.45).cgColor, col.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 0.45, 1])!
            c.drawRadialGradient(grad, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
        }
    }

    /// 靜態層（照片或內建底＋玻璃大數字）：一分鐘才變，存成一張圖，眨眼、瞄一眼只重畫膠囊與主角。
    /// 數字翻動中（digitRoll）不存，每幀照畫；翻完那一幀才存
    private func photosStatic(_ g: CGContext, _ id: String, _ date: Date, _ draw: @escaping (CGContext) -> Void) {
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let (hh, mm) = Self.hourMinute(date), env = HPNumeralGlass.current
        let key = "\(id)|\(hh):\(mm)|\(ClockLook.active.key)|\(HPLook.name)|\(env.reduceTransparency)\(env.reduceMotion)\(HPAccessibility.increaseContrast)|\(Int(renderPixelScale * 100))"
        if digitRoll == nil, Motion.frozen("digits") == nil, let c = photosStaticCache, c.key == key, digitShown.map({ $0 == (hh, mm) }) ?? false {
            drawUpright(g, c.image, in: full); Face.cacheHits += 1; return
        }
        let sc = renderPixelScale, px = Int((1024 * sc).rounded())
        let img = makeImage(px, px) { c in
            if sc != 1 { c.scaleBy(x: sc, y: sc) }
            draw(c)
        }
        photosStaticCache = digitRoll == nil && Motion.frozen("digits") == nil ? (key, img) : nil
        drawUpright(g, img, in: full); Face.cacheMisses += 1
    }

    /// 玻璃大時間；分鐘一變就翻動變了的位數（2.0 R10）
    private func drawPortraitClock(_ g: CGContext, _ date: Date, clear: CGImage?, frosted: CGImage?, now: Double) {
        let (hh, mm) = Self.hourMinute(date)
        let look = ClockLook.active
        if let f = Motion.frozen("digits") {   // 快照：從前一分鐘翻過來，凍結在第 f 秒
            let prev = Self.hourMinute(date.addingTimeInterval(-60))
            digitRoll = (prev, now - f)
        } else if let shown = digitShown, shown != (hh, mm), !Motion.reduceMotion {
            digitRoll = (shown, now)
        }
        digitShown = (hh, mm)
        let (a, b) = Self.portraitDigits(hh, mm)
        guard let roll = digitRoll else {
            drawPortraitDigits(g, [a, b], look: look, clear: clear, frosted: frosted, alpha: 1); return
        }
        let t = CGFloat(Motion.frozen("digits") ?? (now - roll.start))
        if t > 0.6 { digitRoll = nil; drawPortraitDigits(g, [a, b], look: look, clear: clear, frosted: frosted, alpha: 1); return }
        forceDirty = true   // 翻動中每幀重畫
        let (oa, ob) = Self.portraitDigits(roll.old.0, roll.old.1)
        // 每一組（時、分）：長度一樣就逐位比，不一樣（9→10）整組一起翻
        struct Slot { var new: GlyphShape?; var old: GlyphShape?; var changed: Bool; var delay: CGFloat }
        var slots: [Slot] = []
        for (n, o, ns, os) in [(a, oa, hh, roll.old.0), (b, ob, mm, roll.old.1)] {
            if ns == os { slots.append(Slot(new: n, old: nil, changed: false, delay: 0)); continue }
            if ns.count == os.count, let ng = n.glyphs(ns.count), let og = o.glyphs(os.count) {
                for (i, (nc, oc)) in zip(ns, os).enumerated() {
                    slots.append(Slot(new: ng[i], old: nc == oc ? nil : og[i], changed: nc != oc, delay: 0))
                }
            } else {
                slots.append(Slot(new: n, old: o, changed: true, delay: 0))
            }
        }
        // 十位數先動：最右邊那個變了的位數晚 80 ms（只有一個位數變就不晚）
        let changed = slots.indices.filter { slots[$0].changed }
        if changed.count > 1, let last = changed.last { slots[last].delay = 0.08 }
        let still = slots.filter { !$0.changed }.compactMap(\.new)
        if !still.isEmpty { drawPortraitDigits(g, still, look: look, clear: clear, frosted: frosted, alpha: 1) }
        let height = a.ink.height > 0 ? a.ink.height : 500
        let outS = HPMotion.T.digitOut.spring, inS = HPMotion.T.digitIn.spring   // 動效包：參數表
        for sl in slots where sl.changed {
            let lt = t - sl.delay
            let q = lt <= 0 ? 0 : max(0, min(1, outS.value(from: 0, to: 1, velocity: 0, t: lt).x))
            let n = lt <= 0.05 ? 0 : max(0, min(1, inS.value(from: 0, to: 1, velocity: 0, t: lt - 0.05).x))
            if let o = sl.old, q < 0.999 { drawMovingDigit(g, o.offset(0, -q * height * 0.1), blur: q * 26, alpha: 1 - q, look: look, clear: clear, frosted: frosted) }
            if let nw = sl.new, n > 0.001 { drawMovingDigit(g, nw.offset(0, (1 - n) * height * 0.1), blur: (1 - n) * 26, alpha: n, look: look, clear: clear, frosted: frosted) }
        }
    }

    /// 玻璃數字＋亮緣：官方 Portraits 的數字邊上有一圈細亮線（上緣最亮），在照片上一眼分得出字形。
    /// 減少透明度、減少動態效果時數字畫成實色（HPNumeralGlass），不加亮緣
    private func drawPortraitDigits(_ g: CGContext, _ shapes: [GlyphShape], look: ClockLook, clear: CGImage?, frosted: CGImage?, alpha: CGFloat) {
        drawClockDigits(g, shapes, look: look, clear: clear, frosted: frosted, alpha: alpha)
        let env = HPNumeralGlass.current
        guard HPNumeralGlass.usesGlass(look: look, materialLookLinked: HPNumeralGlass.materialLookLinked, reduceTransparency: env.reduceTransparency, reduceMotion: env.reduceMotion),
              !shapes.isEmpty else { return }
        let path = CGMutablePath()
        for s in shapes { path.addPath(s.path) }
        let ink = path.boundingBoxOfPath
        let strong = HPAccessibility.increaseContrast
        g.saveGState(); g.setAlpha(alpha)
        g.addPath(path); g.clip()
        // 亮緣：沿外框往內 2 單位的白線，上亮下淡（漸層裁在描邊裡）
        g.addPath(path.copy(strokingWithWidth: strong ? 6 : 4, lineCap: .round, lineJoin: .round, miterLimit: 1)); g.clip()
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let top = NSColor.white.withAlphaComponent(strong ? 0.95 : 0.8), low = NSColor.white.withAlphaComponent(strong ? 0.6 : 0.28)
        let grad = CGGradient(colorsSpace: cs, colors: [top.cgColor, low.cgColor] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(grad, start: CGPoint(x: 0, y: ink.minY), end: CGPoint(x: 0, y: ink.maxY), options: [])
        g.restoreGState()
    }

    /// 一個在動的玻璃位數：畫進透明的小畫布、糊開、帶透明度貼回去
    private func drawMovingDigit(_ g: CGContext, _ shape: GlyphShape, blur: CGFloat, alpha: CGFloat, look: ClockLook, clear: CGImage?, frosted: CGImage?) {
        guard alpha > 0.005 else { return }
        if blur < 0.3 { drawPortraitDigits(g, [shape], look: look, clear: clear, frosted: frosted, alpha: alpha); return }
        let sc = renderPixelScale, px = Int((1024 * sc).rounded())
        let pad = blur * 3 + 8
        let box = shape.ink.insetBy(dx: -pad, dy: -pad).intersection(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        guard !box.isNull, box.width > 2 else { return }
        let layer = makeImage(px, px) { c in
            c.scaleBy(x: sc, y: sc)
            drawPortraitDigits(c, [shape], look: look, clear: clear, frosted: frosted, alpha: 1)
        }
        let ci = CIImage(cgImage: layer)
        let k = CGFloat(layer.width) / 1024
        let crop = CGRect(x: box.minX * k, y: (1024 - box.maxY) * k, width: box.width * k, height: box.height * k)
        let out = ci.cropped(to: crop).clampedToExtent().applyingGaussianBlur(sigma: Double(blur * k)).cropped(to: crop)
        guard let img = Face.ciContext.createCGImage(out, from: crop) else { return }
        g.saveGState(); g.setAlpha(alpha)
        drawUpright(g, img, in: box)
        g.restoreGState()
    }

    /// 前景遮罩：有就回；沒有就排一個背景工作，做完要求重畫
    private func subjectMaskFor(_ img: CGImage, _ id: ObjectIdentifier) -> CGImage? {
        if let m = subjectMask, m.id == id { return m.mask }
        guard subjectPending != id else { return nil }
        subjectPending = id
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let mask = Self.makeSubjectMask(img)
            DispatchQueue.main.async {
                subjectMask = (id, mask); subjectPending = nil
                self?.forceDirty = true
            }
        }
        return nil
    }

    private static func makeSubjectMask(_ img: CGImage) -> CGImage? {
        let req = VNGenerateForegroundInstanceMaskRequest()
        let h = VNImageRequestHandler(cgImage: img, options: [:])
        guard (try? h.perform([req])) != nil, let obs = req.results?.first,
              let buf = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: h) else { return nil }
        let ci = CIImage(cvPixelBuffer: buf)
        return Face.ciContext.createCGImage(ci, from: ci.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }
}
