// 錶面「照片」：照 HomeView 的 Photos／Portraits——照片滿版，窄高的玻璃大時間站在照片「裡面」：
// 用 Vision 把人物（前景）摳出來，再蓋回數字上面，數字像在人物後面（景深）。沒有前景就整組數字在最上層。
// 摳圖在背景執行緒做、每張照片只做一次；做好前先照一般疊法畫，好了再重畫一次。

import AppKit
import Vision

nonisolated(unsafe) private var subjectMask: (id: ObjectIdentifier, mask: CGImage?)?
nonisolated(unsafe) private var subjectPending: ObjectIdentifier?
nonisolated(unsafe) private var photoBackdrop: (id: ObjectIdentifier, image: CGImage)?
nonisolated(unsafe) private var photoClear: (id: ObjectIdentifier, image: CGImage)?

extension Face {
    func renderPhotosV2(_ g: CGContext, _ now: Double) {
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let date = Self.displayDate
        guard let img = photos.current else { renderPhotosEmpty(g, date); return }
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
        // 上緣一層淡淡的暗，日期才讀得清楚
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let top = CGGradient(colorsSpace: cs, colors: [NSColor(white: 0, alpha: 0.30).cgColor, NSColor(white: 0, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(top, start: .zero, end: CGPoint(x: 0, y: 260), options: [])

        // 玻璃大時間：時左分右，貼著中縫
        let (hh, mm) = Self.hourMinute(date)
        let look = ClockLook.active
        let a = GlyphShape.clock(hh, look: look, height: 720, maxWidth: 420, at: CGPoint(x: 480, y: 150), anchorX: 1)
        let b = GlyphShape.clock(mm, look: look, height: 720, maxWidth: 420, at: CGPoint(x: 544, y: 150), anchorX: 0)
        if photoClear?.id != id {   // 清楚的照片（畫成 1024² 一次）給玻璃邊緣折射出細節
            photoClear = (id, snapshotBackdrop(px: 1024) { c in c.clip(to: full); self.drawUpright(c, img, in: r) })
        }
        drawClockDigits(g, [a, b], look: look, clear: photoClear?.image, frosted: photoBackdrop?.image, alpha: 1)
        // 人物蓋回來（景深）
        if let mask {
            g.saveGState()
            g.translateBy(x: 0, y: r.minY + r.maxY); g.scaleBy(x: 1, y: -1)
            g.clip(to: r, mask: mask)
            g.interpolationQuality = .high
            g.draw(img, in: r)
            g.restoreGState()
        }
        // 日期在最上面一行
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: -1), blur: 10, color: NSColor(white: 0, alpha: 0.35).cgColor)
        drawCentered(g, Self.dateLine(date), font: FaceType.sf(40, .semibold), kern: 0.4, y: 100, color: NSColor.white.withAlphaComponent(0.95))
        g.restoreGState()
        // 拍攝日期（像回憶的標題）在左下，島在右下
        let bottom = CGGradient(colorsSpace: cs, colors: [NSColor(white: 0, alpha: 0).cgColor, NSColor(white: 0, alpha: 0.32).cgColor] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(bottom, start: CGPoint(x: 0, y: 820), end: CGPoint(x: 0, y: 1024), options: [])
        if let caption = photos.caption {
            g.saveGState()
            g.setShadow(offset: CGSize(width: 0, height: -1), blur: 8, color: NSColor(white: 0, alpha: 0.4).cgColor)
            drawLeft(g, caption, font: FaceType.sf(36, .bold, mono: false), x: 72, y: 958, color: .white)
            g.restoreGState()
        }
        drawIsland(g, at: CGPoint(x: 846, y: 940), scale: 0.48, liveAt: CGPoint(x: 512, y: 880), now: now)
    }

    /// 沒有照片：溫暖的漸層＋一張照片的圖示，告訴人照片要放哪裡
    private func renderPhotosEmpty(_ g: CGContext, _ date: Date) {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let grad = CGGradient(colorsSpace: cs, colors: [srgb(0xf6c9a8).cgColor, srgb(0xe9a3a8).cgColor, srgb(0xb79ad6).cgColor] as CFArray,
                              locations: [0, 0.55, 1])!
        g.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 1024, y: 1024), options: [])
        drawCentered(g, Self.dateLine(date), font: FaceType.sf(40, .semibold), kern: 0.4, y: 100, color: NSColor.white.withAlphaComponent(0.95))
        drawSymbol(g, "photo.on.rectangle.angled", in: CGRect(x: 412, y: 330, width: 200, height: 170), color: NSColor.white.withAlphaComponent(0.95), weight: .medium)
        let tf = FaceType.sf(44, .bold, mono: false)
        drawCentered(g, L("photos.empty.title", "放几张照片进来"), font: tf, kern: 0, y: 610, color: .white)
        drawCentered(g, L("photos.empty", "把照片放进「图片 › HomePlay」"), font: FaceType.sf(34, .medium, mono: false), kern: 0, y: 664,
                     color: NSColor.white.withAlphaComponent(0.85))
        drawIsland(g, at: CGPoint(x: 512, y: 860), scale: 0.6, liveAt: CGPoint(x: 512, y: 860), now: CACurrentMediaTime())
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
