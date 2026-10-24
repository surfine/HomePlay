// 圓角遮罩（iOS 26 起）：車機在 /info 的螢幕描述宣告 cornerMasks，手機在 SETUP 提議 "cornerMasks"，
// 車機在 enabledFeatures 回同意；手機接著用 SET_PARAMETER（或屏幕的 SETUP）送 topLeftCornerMask：
// 一張方形 8 位元灰階 PNG，亮＝保留畫面，是它這一版 iOS 的螢幕圓角輪廓。做法參考 DiPlay（GPL，只取事實）。
import Foundation
import CoreGraphics
import ImageIO

package enum CornerMaskProtocol {
    package static let feature = "cornerMasks"
    /// 在 bplist 裡找 topLeftCornerMask（可能包在 update／streams 裡；最多 4 層，只收 PNG、≤512 KB）
    package static func find(_ v: Any?, depth: Int = 0) -> Data? {
        guard depth <= 4 else { return nil }
        if let d = v as? [String: Any] {
            if let png = d["topLeftCornerMask"] as? Data, png.count >= 45, png.count <= 512 * 1024,
               png.starts(with: [0x89, 0x50, 0x4e, 0x47]) { return png }
            for x in d.values { if let r = find(x, depth: depth + 1) { return r } }
        } else if let a = v as? [Any] {
            for x in a { if let r = find(x, depth: depth + 1) { return r } }
        }
        return nil
    }

    /// 對角線內縮 → 等效圓角半徑：t = r·(1 − 1/√2)
    package static let diagPerRadius = 1 - 1 / 2.0.squareRoot()

    /// 量遮罩：對角線上覆蓋率第一次過半的位置（像素，含內插）。照 DiPlay 看四角哪個最暗，翻成 (0,0) 是被裁的角。
    package static func diagonalInset(png: Data) -> Double? {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let side = img.width
        guard side >= 2, side <= 512, img.height == side else { return nil }
        var px = [UInt8](repeating: 0, count: side * side)
        guard let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: side, height: side))
        let tl = px[0], tr = px[side - 1], bl = px[(side - 1) * side], br = px[side * side - 1]
        let flipX = min(tr, br) < min(tl, bl), flipY = min(bl, br) < min(tl, tr)
        func at(_ i: Int) -> Double {
            let x = flipX ? side - 1 - i : i, y = flipY ? side - 1 - i : i
            return Double(px[y * side + x])
        }
        for i in 0..<side where at(i) >= 128 {
            if i == 0 { return 0 }
            let a = at(i - 1), b = at(i)
            return Double(i - 1) + (128 - a) / max(1, b - a) + 0.5
        }
        return nil
    }

    /// 同心的安全區內縮：iOS 把 UI 排成跟它自己的螢幕圓角（等效半徑 m）同心；把那個圓角放到內縮 s 的安全區上，
    /// 要跟機身螢幕的圓角（等效半徑 R）同心就得 m = R − s ⇒ s = R − m。iOS 的圓角比機身還大就只內縮最少的量。
    /// bodyDiag、maskDiag 都是「對角線內縮 ÷ 畫面寬度」。
    package static func concentricInset(widthPx: Int, bodyDiag: Double, maskDiag: Double) -> Int {
        let R = bodyDiag / diagPerRadius, m = maskDiag / diagPerRadius
        let minimum = bodyDiag   // 至少要躲開圓角：最大內接矩形
        return Int((max(minimum, R - m) * Double(widthPx)).rounded())
    }

    /// 產生一張左上角遮罩（8 位元灰階 PNG，亮＝保留）：圓角半徑 r（像素），邊長 side
    package static func makeMask(radius r: Double, side: Int) -> Data? {
        var px = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side { for x in 0..<side {
            let dx = max(0, r - (Double(x) + 0.5)), dy = max(0, r - (Double(y) + 0.5))
            px[y * side + x] = UInt8((max(0, min(1, r - (dx * dx + dy * dy).squareRoot() + 0.5)) * 255).rounded())
        } }
        guard let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let img = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, nil)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }
}

/// 圓角策略（設定 › CarPlay › 圓角）
package enum CornerStyle: String, CaseIterable, Sendable {
    /// 同心：安全區＝機身圓角 − iOS 圓角，桌布鋪滿、介面內收（預設）
    case concentric
    /// 折衷：同心與最大畫面的中間
    case balanced
    /// 最大畫面：只躲開機身圓角（最大內接矩形）
    case maximize
}

/// 每一台手機（iOS 版本）量到的圓角，以及這次連線要怎麼宣告
package struct CornerMemory: Equatable, Sendable {
    /// iOS 版本 → 遮罩對角內縮 ÷ 畫面寬度；0＝這一版不送遮罩（舊 iOS），照最大畫面處理
    package var masks: [String: Double] = [:]
    /// 最近連上的手機版本（/info 照它宣告）
    package var lastBuild: String?

    package init(masks: [String: Double] = [:], lastBuild: String? = nil) { self.masks = masks; self.lastBuild = lastBuild }

    /// 讀 carplay-corner.json；舊格式（單一 maskDiag／build）轉成新格式
    package init(json o: [String: Any]) {
        if let m = o["masks"] as? [String: Any] {
            for (k, v) in m { if let d = (v as? NSNumber)?.doubleValue, d >= 0, d < 0.2 { masks[k] = d } }
        } else if let d = (o["maskDiag"] as? NSNumber)?.doubleValue, d > 0, d < 0.2 {
            masks[(o["build"] as? String) ?? "unknown"] = d
        }
        lastBuild = (o["lastBuild"] as? String) ?? (o["build"] as? String)
    }
    package var json: [String: Any] {
        var o: [String: Any] = ["masks": masks]
        if let lastBuild { o["lastBuild"] = lastBuild }
        return o
    }

    /// 這次連線的手機版本的圓角；nil＝沒量過
    package var current: Double? { lastBuild.flatMap { masks[$0] } }

    /// 這次連線要宣告什麼：學圓角（cornerMasks、不帶安全區），或安全區內縮多少
    package enum Plan: Equatable, Sendable { case learn, inset(Int) }
    package func plan(style: CornerStyle, widthPx: Int, bodyDiag: Double) -> Plan {
        let minimal = Int((Double(widthPx) * bodyDiag).rounded(.up))
        if style == .maximize { return .inset(minimal) }
        guard let m = current else { return .learn }
        guard m > 0 else { return .inset(minimal) }   // 這一版不送遮罩
        let concentric = CornerMaskProtocol.concentricInset(widthPx: widthPx, bodyDiag: bodyDiag, maskDiag: m)
        return .inset(style == .concentric ? concentric : (concentric + minimal + 1) / 2)
    }
}

