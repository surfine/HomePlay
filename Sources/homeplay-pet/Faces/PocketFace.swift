// 錶面「島的口袋」——照「HomePlay 屏幕介面稿」的 Pocket.dc.html 实现。
// 只放真的卡片：计时器（在跑才有）、电量、CarPlay、照片（文件夹里有图才有），每 8 秒轮替。

import AppKit

/// 口袋的轮替状态（extension 不能存属性，放在这里）
private enum PocketState {
    static var lastIndex = -1
    static var photoCount = 0
    static var photoScan = -1e9
}

private enum PocketCard { case timer, battery, carplay, photos }

extension Face {
    /// 现在有哪些真卡片
    private func pocketCards() -> [PocketCard] {
        var c: [PocketCard] = []
        if timerEnd != nil { c.append(.timer) }
        c.append(.battery); c.append(.carplay)
        if PocketState.photoCount > 0 { c.append(.photos) }
        return c
    }
    /// 照片数每分钟最多数一次
    private func pocketScanPhotos(_ now: Double) {
        guard now - PocketState.photoScan > 60 else { return }
        PocketState.photoScan = now
        let files = (try? FileManager.default.contentsOfDirectory(at: photos.folder, includingPropertiesForKeys: nil)) ?? []
        PocketState.photoCount = files.filter { PhotoShelf.exts.contains($0.pathExtension.lowercased()) }.count
    }
    /// 计时器在跑时从它起跑那刻起算轮替，所以一开始就停在计时器卡（它排第一）
    private func pocketIndex(_ now: Double, _ n: Int) -> Int {
        let t0 = timerEnd.map { $0 - timerTotal } ?? 0
        return n > 0 ? Int(max(0, now - t0) / 8) % n : 0
    }

    private func pocketContextWord() -> String {
        switch hourNow {
        case 5..<8: return L("pocket.context.dawn", "清晨")
        case 8..<12: return L("pocket.context.morning", "早上")
        case 12..<18: return L("pocket.context.afternoon", "下午")
        case 18..<23: return L("pocket.context.evening", "晚上")
        default: return L("pocket.context.night", "深夜")
        }
    }

    func renderPocketFace(_ g: CGContext, _ now: Double) {
        pocketScanPhotos(now)
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let date = Self.displayDate, tA = CACurrentMediaTime()
        let dl = Self.dateLine(date) + " · " + pocketContextWord()
        // 靜態層：壁紙＋日期＋大時鐘＋卡片堆＋玻璃卡。每分鐘／壁紙更新／視窗縮放時才重畫。
        let minute = Int(date.timeIntervalSince1970 / 60)
        let key = "pocket|\(minute)|\(wallpaperGeneration)|\(Int(renderPixelScale * 100))|\(dl)|\(Self.clock(date))"
        if let c = staticCache, c.key == key {
            drawUpright(g, c.image, in: full)
            Face.cacheHits += 1
        } else {
            let sc = renderPixelScale
            let px = Int((1024 * sc).rounded())
            func drawStatic(_ c: CGContext) {
                if let wallpaper { drawUpright(c, wallpaper, in: full) }
                drawCentered(c, dl, font: FaceType.sf(36, .semibold), kern: 0.4,
                             y: 118, color: NSColor.white.withAlphaComponent(0.9))
                // SF Pro 半粗的時間（和其他錶面同一套字），不再用圓體
                let t = GlyphShape(Self.clock(date), font: FaceType.sf(300, .semibold), kern: -4)
                    .tall(height: 138, stretch: 1.0, at: CGPoint(x: 512, y: 146), anchorX: 0.5, maxWidth: 800)
                fillShape(c, t, .white, shadow: 0.18)
                // 卡片堆：兩層錯位的底，再一張玻璃前卡
                for (r, a) in [(CGRect(x: 147, y: 528, width: 730, height: 314), 0.10), (CGRect(x: 112, y: 504, width: 800, height: 314), 0.14)] {
                    c.setFillColor(NSColor(white: 1, alpha: a).cgColor)
                    c.addPath(CGPath(roundedRect: r, cornerWidth: 64, cornerHeight: 64, transform: nil)); c.fillPath()
                }
                glass(c, CGRect(x: 80, y: 480, width: 864, height: 336), radius: 67, tint: NSColor(white: 1, alpha: 0.12), band: 16)
            }
            let img = makeImage(px, px) { c in
                if sc != 1 { c.scaleBy(x: sc, y: sc) }
                drawStatic(c)
            }
            staticCache = (key, img)
            drawUpright(g, img, in: full)
            Face.cacheMisses += 1
        }
        Face.pocketA += CACurrentMediaTime() - tA

        let tC = CACurrentMediaTime()
        let card = CGRect(x: 80, y: 480, width: 864, height: 336)
        let cards = pocketCards(), idx = pocketIndex(now, cards.count)
        drawPocketCard(g, cards[idx], card, now)
        Face.pocketC += CACurrentMediaTime() - tC
        let tD = CACurrentMediaTime()

        // 页点（跟着卡片索引变，不进静态层）
        let n = cards.count, gap: CGFloat = 26
        for i in 0..<n {
            g.setFillColor(NSColor(white: 1, alpha: i == idx ? 1 : 0.35).cgColor)
            g.fillEllipse(in: CGRect(x: 512 - CGFloat(n - 1) * gap / 2 + CGFloat(i) * gap - 6.5, y: 874, width: 13, height: 13))
        }
        drawIsland(g, at: CGPoint(x: 512, y: 400), scale: 0.72, liveAt: CGPoint(x: 512, y: 400), now: now)
        Face.pocketD += CACurrentMediaTime() - tD
    }

    private func drawPocketCard(_ g: CGContext, _ kind: PocketCard, _ r: CGRect, _ now: Double) {
        let x = r.minX + 52, label = Self.rounded(28, weight: .bold)
        let big = Self.rounded(64, weight: .bold), sub = Self.rounded(32, weight: .semibold)
        let dim = NSColor.white.withAlphaComponent(0.65)
        switch kind {
        case .timer:
            let orange = srgb(0xffb340)
            drawLeft(g, timerLabel, font: label, x: x, y: r.minY + 78, color: orange)
            guard let end = timerEnd else { return }
            let left = max(0, end - now), frac = CGFloat(left / max(1, timerTotal))
            let c = CGPoint(x: x + 90, y: r.minY + 212)
            g.setLineWidth(22); g.setLineCap(.round)
            g.setStrokeColor(orange.withAlphaComponent(0.22).cgColor)
            g.addArc(center: c, radius: 80, startAngle: 0, endAngle: .pi * 2, clockwise: false); g.strokePath()
            g.setStrokeColor(orange.cgColor)
            g.addArc(center: c, radius: 80, startAngle: -.pi / 2, endAngle: -.pi / 2 + .pi * 2 * frac, clockwise: false); g.strokePath()
            drawLeft(g, timerClock(left), font: Self.rounded(120, weight: .semibold), x: x + 220, y: r.minY + 250, color: .white)
        case .battery:
            let green = srgb(0x30d158)
            drawLeft(g, L("battery.title", "电量"), font: label, x: x, y: r.minY + 78, color: green)
            if let b = battery {
                let low = b.percent <= 20 && !b.charging
                drawLeft(g, "\(b.percent)%", font: Self.rounded(120, weight: .semibold), x: x, y: r.minY + 224, color: .white)
                let bar = CGRect(x: x + 300, y: r.minY + 164, width: r.width - 104 - 300, height: 40)
                g.setFillColor(green.withAlphaComponent(0.22).cgColor)
                g.addPath(CGPath(roundedRect: bar, cornerWidth: 20, cornerHeight: 20, transform: nil)); g.fillPath()
                g.setFillColor((low ? srgb(0xff453a) : green).cgColor)
                let fill = CGRect(x: bar.minX, y: bar.minY, width: max(40, bar.width * CGFloat(b.percent) / 100), height: bar.height)
                g.addPath(CGPath(roundedRect: fill, cornerWidth: 20, cornerHeight: 20, transform: nil)); g.fillPath()
                drawLeft(g, Self.batteryState(b), font: sub, x: x, y: r.minY + 288, color: dim)
            } else {
                drawLeft(g, L("battery.none", "没有电池"), font: big, x: x, y: r.minY + 190, color: .white)
                drawLeft(g, L("battery.macPlugged", "这台 Mac 接着电源"), font: sub, x: x, y: r.minY + 252, color: dim)
            }
        case .carplay:
            let blue = srgb(0x4a9bff)
            drawLeft(g, "CarPlay", font: label, x: x, y: r.minY + 78, color: blue)
            let sp = statusParts
            drawLeft(g, sp.title, font: Self.rounded(76, weight: .bold), x: x, y: r.minY + 200, color: .white)
            if let hint = sp.hint { drawLeft(g, hint, font: sub, x: x, y: r.minY + 262, color: dim) }
        case .photos:
            let pink = srgb(0xff7ab6)
            drawLeft(g, L("pocket.photos", "照片"), font: label, x: x, y: r.minY + 78, color: pink)
            drawLeft(g, PocketState.photoCount == 1 ? L("pocket.photos.one", "1 张照片") : String(format: L("pocket.photos.count", "%d 张照片"), PocketState.photoCount), font: Self.rounded(76, weight: .bold), x: x, y: r.minY + 200, color: .white)
            drawLeft(g, L("pocket.photos.folder", "图片 › HomePlay"), font: sub, x: x, y: r.minY + 262, color: dim)
        }
    }

    /// 卡片换页时才重画；计时器的秒数变化由 Face 自己标脏
    func tickPocketFace(_ now: Double) -> Bool {
        pocketScanPhotos(now)
        let n = pocketCards().count, i = pocketIndex(now, n)
        // 卡片数变了也要重画（页点、索引会跳）
        let key = i * 10 + n
        if key != PocketState.lastIndex { PocketState.lastIndex = key; return true }
        return false
    }
}
