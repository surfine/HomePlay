// 媒體類 App（音樂、播客、食譜）共用的小零件：玻璃按鈕群、封面圖載入／鋪滿／霧化、受限大小的下載。
// 玻璃只用在控制層（按鈕），做法跟控制中心一樣：拍下底下的畫面當背景，交給 SystemGlass 算折射，之後同一組按鈕不重算。

import AppKit
import CoreImage
import ImageIO

enum MediaUI {   // 音樂、播客、食譜共用的畫法（和 AppsKit 的 AppUI 分開）
    static let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    /// 最小點按範圍（1024 畫布上）
    static let minTap: CGFloat = 88

    // MARK: 玻璃

    nonisolated(unsafe) private static var glassCache: [String: (image: CGImage, rect: CGRect)] = [:]
    nonisolated(unsafe) private static var glassOrder: [String] = []

    static func capsule(_ r: CGRect) -> CGPath { CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil) }
    static func circle(_ r: CGRect) -> CGPath { CGPath(ellipseIn: r, transform: nil) }

    /// 把 shapes 畫成液態玻璃。画面此刻已經畫好的內容就是玻璃的背景；key 要包含「背景是什麼」（曲目、頁面、封面是否到了）
    /// 與形狀，同一個 key 只算一次。SystemGlass 不可用或失敗就退成半透明白＋細邊。
    static func glass(_ g: CGContext, face: Face, shapes: [CGPath], key: String, tint: NSColor? = nil) {
        let path = CGMutablePath()
        for s in shapes { path.addPath(s) }
        let full = "\(key)|\(Int(face.renderPixelScale * 100))"
        if glassCache[full] == nil, let shot = g.makeImage() {
            var p = SystemGlassParams.portrait
            p.refractionAmount = -1.6; p.blurRadius = 10; p.fill = 0.14; p.highlight = 0.45; p.ringShadow = 0.25
            if let tint { p.tint = tint.cgColor }
            if let out = SystemGlass.shared.render(path: path, key: full, scale: face.renderPixelScale, backdrop: shot, params: p) {
                glassCache[full] = (out.image, out.rect)
                glassOrder.append(full)
                if glassOrder.count > 24 { glassCache[glassOrder.removeFirst()] = nil }
            }
        }
        if let c = glassCache[full] {
            g.saveGState(); g.addPath(path); g.clip(); face.drawUpright(g, c.image, in: c.rect); g.restoreGState()
        } else {
            g.saveGState(); g.addPath(path); g.setFillColor(NSColor(white: 1, alpha: 0.18).cgColor); g.fillPath(); g.restoreGState()
            g.saveGState(); g.addPath(path); g.setStrokeColor(NSColor(white: 1, alpha: 0.32).cgColor); g.setLineWidth(2); g.strokePath(); g.restoreGState()
        }
    }

    /// 玻璃上的字（置中）；font 傳進來是為了讓呼叫端決定字級
    static func label(_ g: CGContext, face: Face, _ s: String, in r: CGRect, font: NSFont, color: NSColor = .white, dx: CGFloat = 0) {
        let t = Face.clipped(s, font, r.width - 36)
        face.drawLeft(g, t, font: font, x: r.midX - Typo.width(t, font) / 2 + dx, y: r.midY + font.pointSize * 0.34, color: color)
    }

    /// 由上往下漸漸變黑的遮罩（0 → maxAlpha，用緩入曲線，起點看不出一條邊）
    static func shade(_ maxAlpha: CGFloat) -> CGGradient? {
        let stops: [(CGFloat, CGFloat)] = [(0, 0), (0.25, 0.04), (0.5, 0.2), (0.75, 0.55), (1, 1)]
        return CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: stops.map { NSColor(srgbRed: 0, green: 0, blue: 0, alpha: $0.1 * maxAlpha).cgColor } as CFArray,
                          locations: stops.map(\.0))
    }

    // MARK: 折行

    /// 中英混排的折行：英文在空白處斷，中文逐字斷；逗號句號、右括號不放在行首；超過 maxLines 的尾巴縮成「…」
    static func wrap(_ s: String, _ font: NSFont, _ width: CGFloat, maxLines: Int) -> [String] {
        func w(_ t: String) -> CGFloat { Typo.width(t, font) }
        let noStart = Set("，。、；：！？）」』】》,.;:!?)]}…")   // l10n-ignore
        var lines: [String] = [], cur = ""
        var lastSpace: String.Index?
        for ch in s {
            if ch == "\n" { lines.append(cur); cur = ""; lastSpace = nil; continue }
            if cur.isEmpty && ch == " " { continue }
            let next = cur + String(ch)
            if w(next) <= width || cur.isEmpty || (noStart.contains(ch) && w(cur) <= width) {
                if ch == " " { lastSpace = cur.endIndex }
                cur = next
            } else if let sp = lastSpace, ch != " ", cur[sp...].count < 24 {
                lines.append(String(cur[..<sp]).trimmingCharacters(in: .whitespaces))
                cur = String(cur[sp...]).trimmingCharacters(in: .whitespaces) + String(ch); lastSpace = nil
            } else {
                lines.append(cur.trimmingCharacters(in: .whitespaces)); cur = ch == " " ? "" : String(ch); lastSpace = nil
            }
        }
        if !cur.isEmpty { lines.append(cur) }
        if lines.count > maxLines {
            let rest = lines[(maxLines - 1)...].joined(separator: " ")
            lines = Array(lines[..<(maxLines - 1)]) + [Face.clipped(rest, font, width)]
        }
        return lines
    }

    // MARK: 圖片

    /// 圖檔資料 → CGImage（最長邊縮到 maxSide；壞檔回 nil）
    static func cgImage(from data: Data, maxSide: Int = 1024) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxSide]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// 鋪滿 rect（等比放大、置中、多的裁掉）
    static func drawCover(_ g: CGContext, face: Face, _ img: CGImage, in r: CGRect) {
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let k = max(r.width / iw, r.height / ih)
        let w = iw * k, h = ih * k
        g.saveGState(); g.clip(to: r)
        face.drawUpright(g, img, in: CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h))
        g.restoreGState()
    }

    /// 高斯模糊（先縮小再糊，便宜）；用來做封面滿版底色
    static func blurred(_ img: CGImage, sigma: Double = 14, side: Int = 160) -> CGImage? {
        let small = makeImage(side, side) { c in
            c.interpolationQuality = .medium
            c.translateBy(x: 0, y: CGFloat(side)); c.scaleBy(x: 1, y: -1)   // makeImage 已翻轉，這裡翻回來讓圖正立
            let iw = CGFloat(img.width), ih = CGFloat(img.height), k = max(CGFloat(side) / iw, CGFloat(side) / ih)
            c.draw(img, in: CGRect(x: CGFloat(side) / 2 - iw * k / 2, y: CGFloat(side) / 2 - ih * k / 2, width: iw * k, height: ih * k))
        }
        let ci = CIImage(cgImage: small)
        let out = ci.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: ci.extent)
        return Face.ciContext.createCGImage(out, from: ci.extent)
    }

    /// 封面的代表色：平均色，太灰太暗的拉一點飽和與亮度，讓整面的 tint 不髒
    static func accent(of img: CGImage) -> NSColor {
        guard let c = Shell.averageColor(img)?.usingColorSpace(.sRGB) else { return srgb(0x5a5a64) }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(1, s * 1.15 + 0.06), brightness: max(0.42, min(0.95, b)), alpha: 1)
    }

    /// 2.0 r2（R7）：封面兩點取色——CIAreaAverage 取上半與下半的平均色，當 Now Playing 的底色漸層（影片 v2 O88：取色後壓暗，不是直接糊封面）
    static func twoTone(of img: CGImage) -> (top: NSColor, bottom: NSColor) {
        let ci = CIImage(cgImage: img), e = ci.extent
        func avg(_ r: CGRect) -> NSColor? {
            guard let f = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: r)]),
                  let out = f.outputImage else { return nil }
            var px = [UInt8](repeating: 0, count: 4)
            Face.ciContext.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8,
                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return NSColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        }
        // CIImage 原點在左下：上半＝y 大的那一半
        let top = avg(CGRect(x: e.minX, y: e.midY, width: e.width, height: e.height / 2)) ?? srgb(0x3a4a56)
        let bottom = avg(CGRect(x: e.minX, y: e.minY, width: e.width, height: e.height / 2)) ?? srgb(0x1c2329)
        return (top, bottom)
    }
    /// 取到的顏色壓到指定亮度（保留色相，飽和度略收），當深色底用
    static func darkened(_ c: NSColor, brightness b: CGFloat, saturation k: CGFloat = 0.85) -> NSColor {
        guard let s = c.usingColorSpace(.sRGB) else { return c }
        var h: CGFloat = 0, sat: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        s.getHue(&h, saturation: &sat, brightness: &v, alpha: &a)
        return NSColor(hue: h, saturation: min(1, sat * k), brightness: b, alpha: 1)
    }

    /// 沒有封面時，用標題算一個穩定的色相漸層（同一個名字永遠同一個顏色）
    static func hue(for s: String) -> CGFloat {
        var h: UInt32 = 5381
        for u in s.unicodeScalars { h = (h &* 33) &+ u.value }
        return CGFloat(h % 360) / 360
    }
    static func gradient(for s: String) -> (NSColor, NSColor) {
        let h = hue(for: s)
        return (NSColor(hue: h, saturation: 0.62, brightness: 0.92, alpha: 1), NSColor(hue: (h + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.78, brightness: 0.62, alpha: 1))
    }
    static func fillGradient(_ g: CGContext, _ r: CGRect, _ a: NSColor, _ b: NSColor) {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)
        guard let grad = CGGradient(colorsSpace: cs, colors: [a.cgColor, b.cgColor] as CFArray, locations: [0, 1]) else { return }
        g.saveGState(); g.clip(to: r)
        g.drawLinearGradient(grad, start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
        g.restoreGState()
    }

    // MARK: 受限大小的下載（10 秒、3 MB）

    static let fetchTimeout: TimeInterval = 10
    static let fetchCap = 3 * 1024 * 1024

    /// 抓一個 http(s) 網址：最多等 10 秒、最多收 3 MB（超過就截斷，前 3 MB 照樣交回去解析）。回呼在主執行緒。
    static func fetch(_ url: URL, accept: String, completion: @escaping (Result<(data: Data, finalURL: URL, truncated: Bool), Error>) -> Void) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            completion(.failure(URLError(.unsupportedURL))); return
        }
        let job = LimitedFetch(cap: fetchCap) { result in DispatchQueue.main.async { completion(result) } }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: fetchTimeout)
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        job.start(req)
    }

    private final class LimitedFetch: NSObject, URLSessionDataDelegate {
        private let cap: Int
        private var data = Data()
        private var capped = false
        private var response: URLResponse?
        private var session: URLSession?
        private var done: ((Result<(data: Data, finalURL: URL, truncated: Bool), Error>) -> Void)?
        private let request0 = NSLock()

        init(cap: Int, done: @escaping (Result<(data: Data, finalURL: URL, truncated: Bool), Error>) -> Void) { self.cap = cap; self.done = done }

        func start(_ req: URLRequest) {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = MediaUI.fetchTimeout
            cfg.timeoutIntervalForResource = MediaUI.fetchTimeout     // 整件事最多 10 秒，慢吞吞吐資料的網站也不會卡住
            cfg.httpCookieStorage = nil
            let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
            session = s
            s.dataTask(with: req).resume()
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            self.response = response; completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive d: Data) {
            data.append(d)
            if data.count >= cap { capped = true; data = data.prefix(cap); dataTask.cancel() }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            request0.lock(); let cb = done; done = nil; request0.unlock()
            session.finishTasksAndInvalidate()
            guard let cb else { return }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                cb(.failure(URLError(.badServerResponse))); return
            }
            if let error, !capped { cb(.failure(error)); return }
            guard let final = response?.url ?? task.originalRequest?.url else { cb(.failure(URLError(.badURL))); return }
            cb(.success((data, final, capped)))
        }
    }
}
