// 錶面「照片」：照 HomeView 的 Portraits——照片滿版，Compressed 玻璃大時間從上緣往下佔到約 59%，沒有日期；
// 用 Vision 把人物（前景）摳出來，再蓋回數字與島上面，數字和島都像在人物後面（景深）。沒有前景就整組在最上層。
// 摳圖在背景執行緒做、每張照片只做一次；做好前先照一般疊法畫，好了再重畫一次。

import AppKit
import Vision

nonisolated(unsafe) private var subjectMask: (id: ObjectIdentifier, mask: CGImage?)?
nonisolated(unsafe) private var subjectPending: ObjectIdentifier?
nonisolated(unsafe) private var photoBackdrop: (id: ObjectIdentifier, image: CGImage)?
nonisolated(unsafe) private var photoClear: (id: ObjectIdentifier, image: CGImage)?
nonisolated(unsafe) private var subjectCoverCache: (id: ObjectIdentifier, cover: CGFloat)?
nonisolated(unsafe) private var emptyBackdrop: (clear: CGImage, frosted: CGImage)?

extension SystemGlassParams {
    /// Portraits 的大時間：實心的霜玻璃——透出來的背景糊開、面上一層白，邊緣的折射與亮邊收斂
    static let portraitFrosted = SystemGlassParams(refractionHeight: 1.0, refractionAmount: -2.4, blurRadius: 14, highlight: 0.3,
                                                   white: 1.0, black: 0.04, saturation: 1.15, fill: 0.24, rim: 0.7,
                                                   keyAmount: 0.6, fillAmount: 0.35, ringShadow: 0.3)
}

extension Face {
    func renderPhotosV2(_ g: CGContext, _ now: Double) {
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let date = Self.displayDate
        guard let img = photos.current else { renderPhotosEmpty(g, date, now); return }
        let s = max(1024 / CGFloat(img.width), 1024 / CGFloat(img.height))
        let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
        let r = CGRect(x: (1024 - w) / 2, y: (1024 - h) / 2, width: w, height: h)
        g.saveGState(); g.clip(to: full); drawUpright(g, img, in: r); g.restoreGState()

        let id = ObjectIdentifier(img)
        let mask = subjectMaskFor(img, id)
        // 給玻璃的背景：同一張照片的模糊版（每張一次）
        if photoBackdrop?.id != id {
            let small = snapshotBackdrop(px: 256) { c in c.clip(to: full); self.drawUpright(c, img, in: r) }
            photoBackdrop = (id, blurredBackdrop(small, sigma: 14, key: "photoface|\(id.hashValue)"))
        }
        // 玻璃大時間：Portraits 的 Compressed 數字，從上緣往下佔到約 59%，時左分右貼著中縫；沒有日期
        let (a, b) = Self.portraitDigits(date)
        if photoClear?.id != id {   // 清楚的照片（畫成 1024² 一次）給玻璃邊緣折射出細節
            photoClear = (id, snapshotBackdrop(px: 1024) { c in c.clip(to: full); self.drawUpright(c, img, in: r) })
        }
        drawClockDigits(g, [a, b], look: ClockLook.active, clear: photoClear?.image, frosted: photoBackdrop?.image, alpha: 1, system: .portraitFrosted)
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
        let w = 290.0, h = w * 156 / 420
        let cap = CGRect(x: 512 - w / 2, y: 812 - h / 2, width: w, height: h)
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

    /// 島：數字下方置中，寬 ≈ 290（稿：face('Portraits') 寬 170／600、y 476／600）
    private func drawPhotosIsland(_ g: CGContext, _ now: Double) {
        drawIsland(g, at: CGPoint(x: 512, y: 812), scale: 290 / 588, liveAt: CGPoint(x: 512, y: 812), now: now)
    }

    /// Portraits 的兩組大數字：頂在 6%、底到 59%，左右各留 6%
    private static func portraitDigits(_ date: Date) -> (GlyphShape, GlyphShape) {
        let (hh, mm) = hourMinute(date)
        let look = ClockLook.active, top: CGFloat = 62, h: CGFloat = 542, gap: CGFloat = 52, w = 512 - gap / 2 - 58
        let a = GlyphShape.clock(hh, look: look, height: h, maxWidth: w, at: CGPoint(x: 512 - gap / 2, y: top), anchorX: 1, weightBoost: 0.1)
        let b = GlyphShape.clock(mm, look: look, height: h, maxWidth: w, at: CGPoint(x: 512 + gap / 2, y: top), anchorX: 0, weightBoost: 0.1)
        return GlyphShape.centeredPair(a, b)
    }

    /// 沒有照片：溫暖的漸層當底，同一套 Portraits 版面（玻璃大時間、島在下面），中間一行告訴人照片要放哪裡
    private func renderPhotosEmpty(_ g: CGContext, _ date: Date, _ now: Double) {
        func paint(_ c: CGContext) {
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let grad = CGGradient(colorsSpace: cs, colors: [srgb(0xf6c9a8).cgColor, srgb(0xe9a3a8).cgColor, srgb(0xb79ad6).cgColor] as CFArray,
                                  locations: [0, 0.55, 1])!
            c.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 1024, y: 1024), options: [])
        }
        paint(g)
        if emptyBackdrop == nil {
            let clear = snapshotBackdrop(px: 512) { c in paint(c) }
            emptyBackdrop = (clear, blurredBackdrop(clear, sigma: 14, key: "photosEmpty"))
        }
        let (a, b) = Self.portraitDigits(date)
        drawClockDigits(g, [a, b], look: ClockLook.active, clear: emptyBackdrop?.clear, frosted: emptyBackdrop?.frosted, alpha: 1, system: .portraitFrosted)
        drawSymbol(g, "photo.on.rectangle.angled", in: CGRect(x: 480, y: 622, width: 64, height: 54), color: NSColor.white.withAlphaComponent(0.95), weight: .medium)
        drawCentered(g, L("photos.empty.title", "放几张照片进来"), font: FaceType.sf(36, .bold, mono: false), kern: 0, y: 716, color: .white)
        drawCentered(g, String(format: L("photos.emptyIn", "把照片放进「%@」文件夹"), photos.folder.lastPathComponent), font: FaceType.sf(28, .medium, mono: false), kern: 0, y: 958,
                     color: NSColor.white.withAlphaComponent(0.85))
        drawPhotosIsland(g, now)
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
