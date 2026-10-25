import Accelerate
// HomeView 桌宠（自用，不分发）——RealityKit 版（USDZ 原生几何/材质）。
//
// 身体直接用 Apple 的 apple-homeview.usdz（Quick Look 的同一份资产）：几何、材质、网罩、
// 铰链原生；USB-C 母座按 iPhone 18 Pro 的开口比例重建成独立几何。RealityKit 的默认 IBL 就是官图那套高调棚拍光，另补一盏背光托住侧面/背板。
// 屏幕换成我们的脸或 CarPlay 直播；触控 UV 用屏幕平面的单应变换；拆解、配色、追人都保留。
// 屏幕平时是「岛的表情」的脸：黑胶囊里两颗贴在一起的白椭圆，约 4 秒眨一次、偶尔瞄一下；
// 十个表情照「HomeView 表情稿」，被拖、被摸、拆开、深夜、断线都有反应。接上 CarPlay 接收器时屏幕换成直播画面。
//
// 用法：
//   swift build -c release --product homeplay-pet
//   .build/release/homeplay-pet                              # 只有脸
//   .build/release/homeplay-pet --endpoint ws://127.0.0.1:8788  # 屏幕接 CarPlay 接收器
//   .build/release/homeplay-pet --size 260                   # 初始宽度（点）
//   .build/release/homeplay-pet --face happy --snapshot a.png  # 锁定一张脸存快照
// 操作：拖＝转动；⌘拖＝移动窗口；双击＝拆开／组回（直播时双击屏幕算点按，双击身体才拆）；
// 拖右下角＝缩放（锁比例）；空格＝脸／直播切换；Esc 或右键＝退出。
// 触控板：捏合＝放大缩小；两指旋转＝转身体；两指滑＝转动／俯仰；两指轻点两下＝拆开／组回。
// Magic Mouse：单指滑＝转动／俯仰；单指轻点两下＝拆开／组回。普通滚轮＝缩放。

import AppKit
import ApplicationServices
import AVFoundation
import Metal
import RealityKit
import Combine
import simd
import VideoToolbox
import CoreMedia
import CoreImage
import ImageIO
import IOKit.ps
import IOKit.hid
import Carbon.HIToolbox
import Network
import EventKit
import ServiceManagement
import Security

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

/// 診斷日誌的落地點。`appendDiag` 會被事件 tap、相機佇列這些不能等磁碟的地方呼叫，
/// 所以一律丟進這條序列佇列非同步寫；每支檔案超過 1 MB 就輪轉成 `<name>.1`，只留一份舊檔。
private let diagQueue = DispatchQueue(label: "homeplay.diag", qos: .utility)
private let diagDir: URL = HomePlayState.directory
private let diagLimit: UInt64 = 1 << 20
private var diagHandles: [String: FileHandle] = [:]   // 只在 diagQueue 上存取

private func diagHandle(_ name: String) -> FileHandle? {
    if let h = diagHandles[name] { return h }
    try? FileManager.default.createDirectory(at: diagDir, withIntermediateDirectories: true)
    let url = diagDir.appendingPathComponent(name)
    // 日誌只給自己讀寫（0600）：新建就是 0600，舊版留下的 0644 第一次打開時修正
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    } else {
        chmod(url.path, 0o600)
    }
    guard let h = try? FileHandle(forWritingTo: url) else { return nil }
    h.seekToEndOfFile()
    diagHandles[name] = h
    return h
}

private func diagWrite(_ name: String, _ text: String) {
    guard let data = text.data(using: .utf8), let h = diagHandle(name) else { return }
    let size = h.offsetInFile
    if size > diagLimit {
        // 先關檔再搬：留著的 handle 會指到舊 inode，之後的寫入就丟了。
        try? h.close(); diagHandles[name] = nil
        let url = diagDir.appendingPathComponent(name)
        let old = diagDir.appendingPathComponent(name + ".1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
        guard let fresh = diagHandle(name) else { return }
        _ = try? fresh.write(contentsOf: data)
        return
    }
    _ = try? h.write(contentsOf: data)
}

/// 舊版（0.4 之前）把每個按鍵寫進 keys.log：只刪這兩個確切檔名，其他檔不碰。回傳刪了幾個。
@discardableResult
func removeLegacyKeyLogs(in dir: URL) -> Int {
    var removed = 0
    for name in ["keys.log", "keys.log.1"] {
        let url = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path), (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
    }
    return removed
}
let legacyKeyLogsKey = "HomePlayLegacyKeyLogsRemoved"

/// 啟動時把 HomePlay 資料夾裡所有日誌（含輪轉的 .1、舊版留下的）收成 0600：
/// receiver.log 有 Wi-Fi 名稱與手機位址，舊版的 keys.log 有按鍵紀錄，都不該給同機其他帳號讀。不刪、不改內容。
func tightenLogPermissions() {
    diagQueue.async {
        // 一次性：刪掉舊版留下的按鍵紀錄（只記一行，不讀內容）
        if !UserDefaults.standard.bool(forKey: legacyKeyLogsKey) {
            if removeLegacyKeyLogs(in: diagDir) > 0 { log("removed legacy keys.log") }
            UserDefaults.standard.set(true, forKey: legacyKeyLogsKey)
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: diagDir.path) else { return }
        for n in names where n.hasSuffix(".log") || n.hasSuffix(".log.1") {
            let path = diagDir.appendingPathComponent(n).path
            if let mode = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int, mode & 0o077 != 0 {
                chmod(path, 0o600)
            }
        }
    }
}
/// 诊断日志：异步追加一行到 Application Support/HomePlay/<name>。
func appendDiag(_ name: String, _ line: String) {
    let text = "[\(Date())] \(line)\n"
    diagQueue.async { diagWrite(name, text) }
}
func srgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// MARK: - 窗口比例

enum Pet {
    static let standAspect: CGFloat = 0.82   // 宽 / 高：整机（底座＋屏幕）
    static let wallAspect: CGFloat = 1 / 1.06 // 挂墙：只有屏幕模组，近正方，高＝宽＋一点边
    /// 目前的窗口比例：跟着朝向模式换（启动时、切换挂墙时设）
    nonisolated(unsafe) static var aspect: CGFloat = standAspect
    static func aspect(for mode: ViewMode) -> CGFloat { mode == .wall ? wallAspect : standAspect }
    static let defaultWidth: CGFloat = 220
    static let minWidth: CGFloat = 130
    static let maxWidth: CGFloat = 900
}

/// 记住窗口位置与宽度（UserDefaults HomePlayWindowFrame＝[x, y, 宽]）；高度由宽度和比例算出
enum WindowFrameStore {
    static let key = "HomePlayWindowFrame"
    static func save(_ f: NSRect) {
        UserDefaults.standard.set([f.minX, f.minY, f.width].map(Double.init), forKey: key)
    }
    static func load() -> [Double]? { UserDefaults.standard.array(forKey: key) as? [Double] }
    /// 存的框和某块屏的可见区有交集才还原，并钳进那块屏；完全在屏外（拔了外接显示器）就放弃，走默认位置
    static func restore(_ saved: [Double]?, visible: [CGRect]) -> NSRect? {
        guard let s = saved, s.count == 3, s.allSatisfy(\.isFinite) else { return nil }
        let w = max(Pet.minWidth, min(Pet.maxWidth, CGFloat(s[2]))), h = w / Pet.aspect
        let r = NSRect(x: s[0], y: s[1], width: w, height: h)
        func area(_ v: CGRect) -> CGFloat { let i = r.intersection(v); return i.isNull ? 0 : i.width * i.height }
        guard let vf = visible.max(by: { area($0) < area($1) }), area(vf) > 0 else { return nil }
        return NSRect(x: max(vf.minX, min(r.minX, vf.maxX - w)), y: max(vf.minY, min(r.minY, vf.maxY - h)), width: w, height: h)
    }
}

// MARK: - 画布小工具

func makeImage(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // 左上原点，跟稿里的 canvas 一样
    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
    draw(ctx)
    return ctx.makeImage()!
}

// MARK: - 法线贴图：表面细节（噴砂铝的颗粒、网孔的凹陷），让灯光在表面上碎开，才不像 CG

/// 由高度场做切线空间法线贴图（可平铺：边界绕回去取样）。strength 越大越凹凸。
func normalMap(_ w: Int, _ h: Int, strength: CGFloat, height: [CGFloat]) -> CGImage {
    var px = [UInt8](repeating: 255, count: w * h * 4)
    func hh(_ x: Int, _ y: Int) -> CGFloat { height[((y + h) % h) * w + (x + w) % w] }
    for y in 0..<h { for x in 0..<w {
        let dx = (hh(x + 1, y) - hh(x - 1, y)) * strength, dy = (hh(x, y + 1) - hh(x, y - 1)) * strength
        let l = sqrt(dx * dx + dy * dy + 1)
        let i = (y * w + x) * 4
        px[i] = UInt8(max(0, min(255, (-dx / l * 0.5 + 0.5) * 255)))
        px[i + 1] = UInt8(max(0, min(255, (dy / l * 0.5 + 0.5) * 255)))
        px[i + 2] = UInt8(max(0, min(255, (1 / l * 0.5 + 0.5) * 255)))
    } }
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    return ctx.makeImage()!
}

enum Surface {
    /// 噴砂铝：细密的随机颗粒（3×3 平滑过的白噪声）
    static let beadBlast: CGImage = {
        let n = 256
        var g = SystemRandomNumberGenerator()
        let raw = (0..<(n * n)).map { _ in CGFloat(Double.random(in: 0...1, using: &g)) }
        var sm = raw
        for y in 0..<n { for x in 0..<n {
            var a: CGFloat = 0
            for j in -1...1 { for i in -1...1 { a += raw[((y + j + n) % n) * n + (x + i + n) % n] } }
            sm[y * n + x] = a / 9
        } }
        return normalMap(n, n, strength: 2.2, height: sm)
    }()
    /// 网孔：和 grilleImg 同一套错位孔阵，孔里凹下去、孔边是圆的
    static let grilleHoles: CGImage = {
        let w = 1024, h = 128
        var hgt = [CGFloat](repeating: 1, count: w * h)
        for row in 0..<11 { for col in 0..<62 {
            let cx = 16 + CGFloat(col) * 16 + (row % 2 == 1 ? 8 : 0), cy = 9 + CGFloat(row) * 11.2
            for y in max(0, Int(cy) - 5)...min(h - 1, Int(cy) + 5) { for x in Int(cx) - 5...Int(cx) + 5 {
                let d = hypot(CGFloat(x) - cx, CGFloat(y) - cy)
                let v = max(0, min(1, (d - 1.8) / 1.8))
                let xi = (x + w) % w
                hgt[y * w + xi] = min(hgt[y * w + xi], v)
            } }
        } }
        return normalMap(w, h, strength: 1.8, height: hgt)
    }()
    // MARK: 高清冲孔网罩（覆盖 USDZ 的低模孔）
    // 官方图的孔是干净圆孔、深黑内腔、细亮孔缘。USDZ 的孔是低模多边形，近看会发灰、锯齿。
    // 这里在 USDZ 网罩外叠一层 2048×512 的冲孔面：孔透明→露出黑腔；孔缘用 normal 做倒角高光。
    static let perfW = 2048, perfH = 512
    static let perfCols = 128, perfRows = 16
    static let perfBandH: CGFloat = 2.52
    static let perfCircum: CGFloat = 2 * .pi * 4.16
    static let perfHoleD: CGFloat = 0.07          // cm，真实孔径
    private static let perfCenters: [(CGFloat, CGFloat)] = {
        (0..<perfRows).flatMap { row in
            (0..<perfCols).map { col in
                let x = (CGFloat(col) + 0.5) * CGFloat(perfW) / CGFloat(perfCols)
                    + (row % 2 == 1 ? CGFloat(perfW) / CGFloat(perfCols) / 2 : 0)
                let y = CGFloat(perfH) * (0.05 + 0.90 * CGFloat(row) / CGFloat(perfRows - 1))
                return (x, y)
            }
        }
    }()
    private static var perfRx: CGFloat { (perfHoleD / 2) / perfCircum * CGFloat(perfW) }
    private static var perfRy: CGFloat { (perfHoleD / 2) / perfBandH * CGFloat(perfH) }
    /// 白底 + 透明孔（乘配色）、黑腔（带 USB-C 开孔）、孔缘倒角法线
    static let perforatedGrille: (diffuse: CGImage, backing: CGImage, normal: CGImage) = {
        let W = perfW, H = perfH, rx = perfRx, ry = perfRy
        func drawHoles(_ g: CGContext, clear: Bool) {
            if clear { g.setBlendMode(.clear) }
            for (cx0, cy) in perfCenters {
                for dx: CGFloat in [0, -CGFloat(W), CGFloat(W)] {
                    let cx = cx0 + dx
                    g.fillEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
                }
            }
            if clear { g.setBlendMode(.normal) }
        }
        let diffuse = makeImage(W, H) { g in
            g.setFillColor(NSColor.white.cgColor); g.fill(CGRect(x: 0, y: 0, width: W, height: H))
            drawHoles(g, clear: true)
            // 上下分模线
            g.setFillColor(srgb(0x4a4a4a).cgColor)
            g.fill(CGRect(x: 0, y: 2, width: W, height: 3))
            g.fill(CGRect(x: 0, y: H - 5, width: W, height: 3))
        }
        let backing = makeImage(W, H) { g in
            g.setFillColor(NSColor.black.cgColor); g.fill(CGRect(x: 0, y: 0, width: W, height: H))
        }
        var hgt = [CGFloat](repeating: 1, count: W * H)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<hgt.count { hgt[i] = 1 + CGFloat.random(in: -0.012...0.012, using: &rng) }
        for (cx0, cy) in perfCenters {
            for dx: CGFloat in [0, -CGFloat(W), CGFloat(W)] {
                let cx = cx0 + dx
                let x0 = max(0, Int(cx - rx * 1.5)), x1 = min(W - 1, Int(cx + rx * 1.5))
                let y0 = max(0, Int(cy - ry * 1.5)), y1 = min(H - 1, Int(cy + ry * 1.5))
                if x0 > x1 || y0 > y1 { continue }
                for y in y0...y1 { for x in x0...x1 {
                    let q = hypot((CGFloat(x) - cx) / rx, (CGFloat(y) - cy) / ry)
                    guard q > 1 else { hgt[y * W + x] = 0; continue }
                    guard q < 1.45 else { continue }
                    let v = (q - 1) / 0.45
                    let i = y * W + x
                    hgt[i] = min(hgt[i], v)
                } }
            }
        }
        let normal = normalMap(W, H, strength: 1.25, height: hgt)
        return (diffuse, backing, normal)
    }()

    /// 背部 USB-C：镀铬小胶囊 + 深色内槽，画在贴合弧面的曲面上（背景透明，网面从四周透出来）
    static let usbcPort: CGImage = {
        let w = 512, h = 224
        return makeImage(w, h) { g in
            let outer = CGRect(x: 68, y: 54, width: 376, height: 116)
            let outerPath = CGPath(roundedRect: outer, cornerWidth: 44, cornerHeight: 44, transform: nil)
            // 柔和的落地阴影：让它读起来是凹进去的，而不是贴纸
            g.saveGState()
            g.setShadow(offset: CGSize(width: 0, height: 4), blur: 8,
                        color: NSColor.black.withAlphaComponent(0.30).cgColor)
            g.addPath(outerPath)
            g.setFillColor(NSColor(white: 0.82, alpha: 1).cgColor)
            g.fillPath()
            g.restoreGState()
            // 镀铬边：上亮、中暗、下再提亮，像一圈抛光金属
            g.saveGState()
            g.addPath(outerPath); g.clip()
            let chrome = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                NSColor(white: 0.90, alpha: 1).cgColor,
                NSColor(white: 0.60, alpha: 1).cgColor,
                NSColor(white: 0.82, alpha: 1).cgColor,
            ] as CFArray, locations: [0, 0.60, 1])!
            g.drawLinearGradient(chrome, start: CGPoint(x: 0, y: outer.minY),
                                 end: CGPoint(x: 0, y: outer.maxY), options: [])
            g.restoreGState()
            // 外圈一道细暗边，把镀铬边和网面分开
            g.saveGState()
            g.addPath(outerPath)
            g.setStrokeColor(NSColor(white: 0.18, alpha: 0.55).cgColor)
            g.setLineWidth(2); g.strokePath()
            g.restoreGState()
            // 内槽：USB-C 的 8.4×2.6 mm 比例，圆角接近胶囊
            let slot = CGRect(x: 104, y: 64, width: 304, height: 95)
            let slotPath = CGPath(roundedRect: slot, cornerWidth: 46, cornerHeight: 46, transform: nil)
            g.saveGState()
            g.addPath(slotPath); g.clip()
            let inner = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                NSColor(white: 0.02, alpha: 1).cgColor,
                NSColor(white: 0.10, alpha: 1).cgColor,
                NSColor(white: 0.05, alpha: 1).cgColor,
            ] as CFArray, locations: [0, 0.72, 1])!
            g.drawLinearGradient(inner, start: CGPoint(x: 0, y: slot.minY),
                                 end: CGPoint(x: 0, y: slot.maxY), options: [])
            g.restoreGState()
            // 内槽边缘：上沿压暗、下沿留一条细高光，深度就出来了
            g.saveGState()
            g.addPath(slotPath)
            g.setStrokeColor(NSColor(white: 0.22, alpha: 0.9).cgColor)
            g.setLineWidth(2.5); g.strokePath()
            g.setStrokeColor(NSColor(white: 0.55, alpha: 0.45).cgColor)
            g.setLineWidth(1.5)
            g.move(to: CGPoint(x: slot.minX + 34, y: slot.minY + 7))
            g.addLine(to: CGPoint(x: slot.maxX - 34, y: slot.minY + 7))
            g.strokePath()
            g.restoreGState()
            // 镀铬边顶部一道锐高光
            g.saveGState()
            let glint = CGRect(x: outer.minX + 30, y: outer.minY + 4, width: outer.width - 60, height: 3)
            g.addPath(CGPath(roundedRect: glint, cornerWidth: 2, cornerHeight: 2, transform: nil))
            g.setFillColor(NSColor(white: 1, alpha: 0.55).cgColor)
            g.fillPath()
            g.restoreGState()
        }
    }()
}

// MARK: - 脸（岛的表情）：十个表情都是同一套几何的变形
//
// 参数照设计稿「HomeView 表情稿」（docs/design-drafts/桌寵表情與行為.html）：1024 画布、×1.4 之前的原值。
// 只动眼睛：眼白半径、上下眼皮遮住的比例、眼皮斜角、笑眼弯月、眼珠位移与缩放、胶囊宽高；不加嘴、不换画风。

enum Expression: String, CaseIterable {
    case idle, happy, love, wink, thinking, annoyed, surprised, worried, sleepy, asleep
    /// 舊名（快照腳本、官網素材）：好奇併進待機（靠近時眼珠本來就跟著游標）；專注拆成「思考」（等待）與「不耐煩」（連點）
    init?(name: String) {
        switch name {
        case "curious": self = .idle
        case "focus": self = .annoyed
        default: self.init(rawValue: name)
        }
    }
}

struct FaceParams: Equatable {
    var cw: CGFloat = 420, ch: CGFloat = 156                    // 胶囊
    var rx: CGFloat = 31, ry: CGFloat = 45, sep: CGFloat = 36   // 眼白半径、两眼中心离中线（照 👀 emoji：高寬比 1.45、微微分开）
    var top: CGFloat = 0, bot: CGFloat = 0, tilt: CGFloat = 0   // 上下眼皮遮住的比例、眼皮往外斜（弧度；正＝內角往上、難過，負＝內角往下、不耐煩）
    var ltop: CGFloat = 0                                       // 只壓左眼的上眼皮（思考時一高一低，像挑起一邊眉）
    var smile: CGFloat = 0                                      // 笑眼：眼白下缘切成弯月
    var pdx: CGFloat = -13, pdy: CGFloat = 6, ps: CGFloat = 1   // 眼珠位移、缩放
    var blush: CGFloat = 0, dim: CGFloat = 0                    // 脸颊红晕、屏幕变暗

    static func of(_ e: Expression) -> FaceParams {
        var p = FaceParams()
        switch e {
        // 十種剪影各不相同：只看外形（眼白輪廓＋眼珠位置）也分得出來
        case .idle, .wink: break                                                         // 👀 原樣；靠近時眼珠跟著游標
        case .happy: p.smile = 1; p.ps = 0; p.blush = 0.6                                 // ^^ 彎月
        case .love: p.ps = 1.25; p.pdx = 0; p.pdy = 2; p.blush = 1                        // 心形瞳孔＋紅暈
        case .thinking: p.ltop = 0.34; p.pdx = 15; p.pdy = -11; p.ps = 0.92               // 眼珠飄到右上、左眼皮壓低：「嗯……」
        case .annoyed: p.top = 0.42; p.tilt = -0.42; p.ry = 42; p.pdx = 0; p.pdy = 6; p.ps = 0.9   // 上眼皮往內壓成 V，扁一點
        case .surprised: p.rx = 34; p.ry = 56; p.sep = 40; p.ps = 0.5; p.pdx = 0; p.pdy = 0; p.cw = 470; p.ch = 184   // 瞪大、眼珠縮小、膠囊撐大
        case .worried: p.top = 0.26; p.tilt = 0.42; p.pdx = 0; p.pdy = 16                 // 內角往上的八字眉，眼珠往下
        case .sleepy: p.top = 0.6; p.bot = 0.08; p.pdx = 0; p.pdy = 12; p.ps = 0.95        // 眼皮平平地垂到一半多
        case .asleep: p.top = 0; p.pdx = 0; p.pdy = 14; p.dim = 0.45
        }
        return p
    }

    private static let keys: [WritableKeyPath<FaceParams, CGFloat>] =
        [\.cw, \.ch, \.rx, \.ry, \.sep, \.top, \.bot, \.tilt, \.ltop, \.smile, \.pdx, \.pdy, \.ps, \.blush, \.dim]

    /// 每个参数往 t 靠近 a（0..1），差得够小就直接贴上。返回有没有变。
    mutating func approach(_ t: FaceParams, _ a: CGFloat) -> Bool {
        var changed = false
        for k in Self.keys where self[keyPath: k] != t[keyPath: k] {
            let d = t[keyPath: k] - self[keyPath: k]
            self[keyPath: k] = abs(d) < 0.01 ? t[keyPath: k] : self[keyPath: k] + d * a
            changed = true
        }
        return changed
    }
}

// MARK: - 錶面样式、电量、照片（照「HomePlay 屏幕介面稿」）

/// 錶面样式：滚轮或 ← → 换，像 Apple Watch 的数字表冠
enum FaceStyle: String, CaseIterable {
    // 順序＝滾輪換錶面的順序（稿：docs/design-drafts/faces-v3/artifact）
    case island, photos, modular, analog, flow, weather, calendar, homeModular, embossed, growth, black, bedside, system6, alarmClock, about, pocket
    var title: String {
        switch self {
        case .island: return L("face.style.island", "岛")
        case .photos: return L("face.style.photos", "照片")
        case .modular: return L("face.style.modular", "模块")
        case .analog: return L("face.style.analog", "Typograph")
        case .flow: return "Flow"
        case .pocket: return L("face.style.pocket", "岛的口袋")
        case .growth: return L("face.style.growth", "陪伴的痕迹")
        case .system6: return "System 6"
        case .bedside: return L("face.style.bedside", "床头夜灯")
        case .weather: return L("face.style.weather", "天气")
        case .calendar: return L("face.style.calendar", "日历")
        case .homeModular: return L("face.style.homeModular", "家庭模块")
        case .embossed: return L("face.style.embossed", "浮雕指针")
        case .black: return L("face.style.black", "黑色")
        case .alarmClock: return "System 6 · Alarm Clock"   // 復古系列維持英文（史實），名稱前綴分組
        case .about: return "System 6 · About"
        }
    }
    /// 陣容（滾輪、總覽、選單、設定都用這份）：十款。Pocket 併進 Modular、床頭夜燈併進「黑」的夜間（稿：faces-v3），
    /// 浮雕指針成了 Typograph 的「材質」、Alarm Clock／About 成了 System 6 的「版式」，Home Modular 不再列出（要開發簽名的小幫手）；
    /// 程式都還留著，舊的偏好讀進來時換成新的那款（見 inLineup、migratedOptions）
    static var lineup: [FaceStyle] {
        allCases.filter { ![.pocket, .bedside, .homeModular, .embossed, .alarmClock, .about].contains($0) }
    }
    var inLineup: FaceStyle {
        switch self {
        case .pocket, .homeModular: return .modular
        case .bedside: return .black
        case .embossed: return .analog
        case .alarmClock, .about: return .system6
        default: return self
        }
    }
    /// 舊錶面搬進新選項：回傳要一併設成的材質／版式
    var migratedOptions: (material: TypographMaterial?, layout: System6Layout?) {
        switch self {
        case .embossed: return (.embossed, nil)
        case .alarmClock: return (nil, .alarmClock)
        case .about: return (nil, .about)
        default: return (nil, nil)
        }
    }
    /// 往后（d > 0）或往前换一个，头尾相接
    func next(_ d: Int) -> FaceStyle {
        let all = Self.lineup, i = all.firstIndex(of: inLineup)!
        return all[((i + d) % all.count + all.count) % all.count]
    }
    static let defaultsKey = "HomePlayFaceStyle"
}

/// Typograph 的材質：平面（原樣）或浮雕（原「浮雕指針」錶面）
enum TypographMaterial: String, CaseIterable {
    case flat, embossed
    static let defaultsKey = "HomePlayTypographMaterial"
    var title: String {
        switch self {
        case .flat: return L("typograph.material.flat", "平面")
        case .embossed: return L("typograph.material.embossed", "浮雕")
        }
    }
}

/// System 6 的版式：Finder 桌面（原樣）、Alarm Clock、About This Macintosh
enum System6Layout: String, CaseIterable {
    case finder, alarmClock, about
    static let defaultsKey = "HomePlaySystem6Layout"
    var title: String {
        switch self {
        case .finder: return "Finder"
        case .alarmClock: return "Alarm Clock"   // 復古系列維持英文（史實）
        case .about: return "About"
        }
    }
}

/// 快照專用：命令行強行指定材質／版式（不寫 UserDefaults）
nonisolated(unsafe) var faceOptionSnapshotOverride: (material: TypographMaterial?, layout: System6Layout?) = (nil, nil)

/// 本机电量（IOKit）。台式机没有电池时回 nil。
enum Battery {
    struct Reading: Equatable { let percent: Int; let charging: Bool; let onAC: Bool }
    static func read() -> Reading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return Reading(percent: Int((Double(cur) / Double(max) * 100).rounded()),
                           charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                           onAC: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
        }
        return nil
    }
}

/// 照片錶面的照片：读一个文件夹（默认「图片 › HomePlay」）里的照片轮播，一分钟换一张；
/// 30 秒重新扫一次文件夹，加了新照片不用重开。拍摄日期从 EXIF 读，没有就不显示。
final class PhotoShelf {
    let folder: URL
    private var files: [URL] = []
    private var index = -1
    private(set) var current: CGImage?
    private(set) var captionDate: Date?
    /// 拍摄日期，按目前語言在畫面上現排（切換語言不用重新載入照片）
    var caption: String? {
        guard let d = captionDate else { return nil }
        // 这张卡每帧都可能重画，DateFormatter 不能每次都新建（建一次约几十微秒）。
        let lang = L10n.language
        if captionFormatterLocale != lang {
            let f = DateFormatter(); f.locale = lang.locale
            f.dateFormat = DateFormatter.dateFormat(fromTemplate: "yMMMMd", options: 0, locale: lang.locale)
            captionFormatter = f; captionFormatterLocale = lang
        }
        return captionFormatter?.string(from: d)
    }
    private var captionFormatter: DateFormatter?
    private var captionFormatterLocale: PetLanguage?
    private var lastScan = -1e9, lastSwap = -1e9
    static let exts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"]

    init(folder: URL) { self.folder = folder }
    static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/HomePlay", isDirectory: true)
    }

    /// 有换图（或文件夹从有变无）就回 true
    func tick(_ now: Double) -> Bool {
        var changed = false
        if now - lastScan > 30 {
            lastScan = now
            let found = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { Self.exts.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if found != files {
                files = found
                if files.isEmpty { if current != nil { current = nil; captionDate = nil; changed = true } }
                else { lastSwap = -1e9 }
            }
        }
        if !files.isEmpty, current == nil || (files.count > 1 && now - lastSwap > 60) {
            lastSwap = now
            index = (index + 1) % files.count
            load(files[index]); changed = true
        }
        return changed
    }

    private func load(_ url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { current = nil; return }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 1400,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        current = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        captionDate = nil
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let p = DateFormatter(); p.dateFormat = "yyyy:MM:dd HH:mm:ss"
            captionDate = p.date(from: raw)
        }
    }
}

/// 倒数显示：4:59、12:05、1:02:03（无条件进位，最后一秒显示 0:01 不显示 0:00）
func timerClock(_ seconds: Double) -> String {
    let s = Int(seconds.rounded(.up)), h = s / 3600, m = (s % 3600) / 60, r = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
}

final class Face {
    private(set) var expression: Expression = .idle
    /// 游標在附近：待機的眼珠跟著游標（以前的「好奇」），不自己東張西望
    var followPointer = false
    /// 快照用：不眨、不瞄
    var frozen = false
    /// 好奇时眼珠看的方向（-1..1，x 往右、y 往下）
    var pointer: CGPoint?
    /// 整点（分钟走到 00）时叫一下
    var onHour: (() -> Void)?

    private(set) var cur = FaceParams.of(.idle), target = FaceParams.of(.idle)
    /// 表情正在往目標過渡：這幾幀要用 30fps 以上畫，否則 6 Hz 下過場一格一格跳
    private(set) var approaching = false
    var forceDirty = false
    /// 錶面要眼睛看哪裡（App 原始單位，同 FaceParams.pdx/pdy）；只在平常表情時生效。錶面在 drawIsland 前設、畫完清掉
    var faceEyeLook: CGPoint?
    static var renderCount = 0
    static var ambientPaused = false      // 過熱／低電量時停掉 Flow 氛圍動畫
    /// 貼圖解析度倍率（0.5…1）：按視窗大小選，預設視窗只畫 512²，省 4 倍光柵與上傳
    var renderScale: CGFloat = 0.5
    /// 靜態層快取（背景＋壓暗＋日期＋時間）：眨眼、瞄一眼不必重畫大號時間字
    var staticCache: (key: String, image: CGImage)?       // pocket：背景＋卡片＋玻璃
    var textLayerCache: (key: String, image: CGImage)?    // island：透明文字層
    var renderPixelScale: CGFloat = 0.5
    var wallpaperGeneration = 0
    static var cacheHits = 0, cacheMisses = 0
    static var dbgBlink = 0, dbgApproach = 0, dbgScreen = 0, dbgLive = 0, dbgOther = 0
    static var dbgPal = 0, dbgReveal = 0, dbgFlow = 0, dbgHello = 0, dbgExpr = 0
    /// 官網素材用：在同一格畫面強制眨眼／瞄一眼，第二張與第一張只差眼睛
    static var blinkOverride: CGFloat?
    static var glanceOverride = false
    /// 官網素材用：固定好奇時的眼珠方向，不受拍照時滑鼠在哪影響
    static var pointerOverride: CGPoint?
    static var renderSeconds = 0.0
    static var bgSeconds = 0.0, textSeconds = 0.0, islandSeconds = 0.0
    static var pocketA = 0.0, pocketC = 0.0, pocketD = 0.0
    /// 這段時間很值得用 60fps 畫（眨眼／hello／引導）——環境漂動不算
    func needsSmooth(_ now: Double) -> Bool {
        blinkEnd > 0 || helloStart >= 0 && now - helloStart < Self.helloDuration || onboardingActive
            || PermissionPrimer.visible || approaching
    }      // 效能基準用：臉部軟體重繪次數
    private var lastTick = CACurrentMediaTime()
    private var nextBlink = CACurrentMediaTime() + 2.5, blinkEnd = 0.0, doubleBlink = false
    private var nextGlance = CACurrentMediaTime() + 6, glanceEnd = 0.0
    private var lastMinute = -1, lastSecond = -1
    private var lastMinuteCheck: Double = 0

    func set(_ e: Expression, snap: Bool = false) {
        guard e != expression || snap else { return }
        Face.dbgExpr += 1
        expression = e; target = .of(e); forceDirty = true
        if snap { cur = target }
    }
    /// 让下一次 tick 眨一下（可延迟）：转头落定、刚看到人时用来收尾。
    func blinkSoon(after delay: Double = 0) {
        guard !frozen, expression != .asleep else { return }
        nextBlink = CACurrentMediaTime() + max(0, delay)
    }

    /// 有变化才重画；返回 nil 表示不用换贴图。
    func tick(_ now: Double) -> CGImage? {
        let dt = min(0.1, max(0, now - lastTick)); lastTick = now
        var dirty = forceDirty; forceDirty = false

        // 眨眼：约 4 s ± 0.6 一次，八分之一机率连眨两下；困倦时眨得慢、隔得久；睡着不眨
        let slow = expression == .sleepy
        if !frozen && expression != .asleep {
            if blinkEnd == 0 && now > nextBlink { blinkEnd = now + (slow ? 0.38 : 0.13); dirty = true; Face.dbgBlink += 1 }
            if blinkEnd > 0 {
                if slow { dirty = true }
                if now > blinkEnd {
                    blinkEnd = 0; dirty = true
                    if !doubleBlink && Double.random(in: 0..<1) < 0.125 { doubleBlink = true; nextBlink = now + 0.16 }
                    else { doubleBlink = false; nextBlink = now + (slow ? 6 : 4) + Double.random(in: -0.6...0.6) }
                }
            }
        } else if blinkEnd > 0 { blinkEnd = 0; dirty = true }

        // 瞄：只在待机，每 7–11 s 往右上看 1.4 s
        if !frozen && expression == .idle && !followPointer {
            if glanceEnd == 0 && now > nextGlance { glanceEnd = now + 1.4 }
            if glanceEnd > 0 && now > glanceEnd { glanceEnd = 0; nextGlance = now + 7 + Double.random(in: 0...4) }
        } else { glanceEnd = 0 }

        var t = target
        if expression == .idle, followPointer || Face.pointerOverride != nil, let p = Face.pointerOverride ?? pointer {
            t.pdx = max(-1, min(1, p.x)) * 15; t.pdy = max(-1, min(1, p.y)) * 18
        }
        if glanceEnd > 0 || Face.glanceOverride { t.pdx = 13; t.pdy = -14 }
        if Face.glanceOverride {
            if cur != t { cur = t; dirty = true; Face.dbgApproach += 1 }   // 快照：一步到位
        } else if animateDetails {
            approaching = cur.approach(t, CGFloat(1 - exp(-dt * 14)))
            if approaching { dirty = true; Face.dbgApproach += 1 }
        } else if cur != t {
            cur = t; dirty = true; Face.dbgApproach += 1
        }

        // 睡着的 z 一秒换一次位置（这时整个视图也降到 1 fps）
        if expression == .asleep {
            let s = Int(now)
            if s != lastSecond { lastSecond = s; dirty = true }
        }
        if tickScreen(now, dt) { dirty = true; Face.dbgScreen += 1 }
        if tickLive(now, dt) { dirty = true; Face.dbgLive += 1 }
        // 分鐘只決定錶面/壁紙換不換，每秒查一次就夠；Calendar 查詢不便宜，不該每幀做。
        if now - lastMinuteCheck >= 1 {
            lastMinuteCheck = now
            let minute = Calendar.current.component(.minute, from: Date())
            if minute != lastMinute {
                if minute == 0 && lastMinute != -1 { onHour?() }
                lastMinute = minute; dirty = true
            }
        }
        return dirty ? render(now) : nil
    }

    func blinkFactor(_ now: Double) -> CGFloat {
        if let b = Face.blinkOverride { return b }
        guard blinkEnd > 0 else { return 1 }
        guard expression == .sleepy else { return 0.1 }
        let k = 1 - (blinkEnd - now) / 0.38
        return max(0.08, abs(1 - 2 * CGFloat(k)))
    }

    // MARK: 屏幕里的液态玻璃
    // 壁纸随一天变（清晨暖、白天青绿、黄昏琥珀紫、夜里深蓝，相邻两组插值）；G4 白外观的白天换成 Aqua 蓝。
    // 壁纸是柔边色块，画在 256 px 上再放大就够；色块跟着游标慢慢漂（Flow）。模糊版跟着一起重算。

    struct RGB { var r, g, b: CGFloat
        init(_ hex: UInt32) { r = CGFloat(hex >> 16 & 0xff) / 255; g = CGFloat(hex >> 8 & 0xff) / 255; b = CGFloat(hex & 0xff) / 255 }
        init(r: CGFloat, g: CGFloat, b: CGFloat) { self.r = r; self.g = g; self.b = b }
        func mix(_ o: RGB, _ t: CGFloat) -> RGB { RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t) }
        func color(_ a: CGFloat = 1) -> CGColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a).cgColor }
    }
    struct Palette {
        var top: RGB, bottom: RGB, blobs: [(RGB, CGFloat)]
        init(_ top: UInt32, _ bottom: UInt32, _ blobs: [(UInt32, CGFloat)]) {
            self.top = RGB(top); self.bottom = RGB(bottom); self.blobs = blobs.map { (RGB($0.0), $0.1) }
        }
        init(top: RGB, bottom: RGB, blobs: [(RGB, CGFloat)]) { self.top = top; self.bottom = bottom; self.blobs = blobs }
        func mix(_ o: Palette, _ t: CGFloat) -> Palette {
            Palette(top: top.mix(o.top, t), bottom: bottom.mix(o.bottom, t),
                    blobs: zip(blobs, o.blobs).map { ($0.0.mix($1.0, t), $0.1 + ($1.1 - $0.1) * t) })
        }
    }
    static let dawn = Palette(0x3a4f7a, 0xd3957c, [(0xffc49b, 0.55), (0xb9a6f0, 0.45), (0xffd98a, 0.35), (0x9fd8ff, 0.2)])
    static let day = Palette(0x1d4a57, 0x2f6a63, [(0x74e3c4, 0.55), (0x3f82d8, 0.55), (0xf2c27c, 0.38), (0x9fe8ff, 0.18)])
    static let aquaDay = Palette(0x1b4f9c, 0x58a8e6, [(0x9fe2ff, 0.55), (0x2b6fd6, 0.5), (0xe9f6ff, 0.35), (0x7fd0ff, 0.25)])
    static let dusk = Palette(0x2b2350, 0x8a4a5e, [(0xffae6b, 0.5), (0x8f6bdc, 0.5), (0xff7f9e, 0.35), (0xffd98a, 0.2)])
    static let night = Palette(0x070d1f, 0x152447, [(0x2e5bbd, 0.5), (0x4b3fa8, 0.45), (0x2a8f8a, 0.25), (0x9fb8ff, 0.12)])

    /// 钟点（0..<24，可带小数）→ 色票：7 点清晨、12 点白天、18 点黄昏、23 点夜里，之间平滑插值，绕一圈
    static func palette(hour h0: Double, aqua: Bool) -> Palette {
        let keys: [(Double, Palette)] = [(7, dawn), (12, aqua ? aquaDay : day), (18, dusk), (23, night), (31, dawn)]
        let h = h0 < 7 ? h0 + 24 : h0
        for i in 0..<(keys.count - 1) where h >= keys[i].0 && h < keys[i + 1].0 {
            let t = (h - keys[i].0) / (keys[i + 1].0 - keys[i].0)
            let s = t * t * (3 - 2 * t)
            return keys[i].1.mix(keys[i + 1].1, CGFloat(s))
        }
        return dawn
    }

    /// G4 白外观：屏幕走 Aqua（细条纹、凝胶高光），游标靠近时转头幅度更大（向日葵）
    var aqua = false { didSet { if aqua != oldValue { paletteKey = -1; forceDirty = true } } }
    /// 只给快照用：假装现在是几点（只影响壁纸色票）
    var hourOverride: Double?
    /// 游标离多近（0 远 … 1 近）：近了玻璃卡展开，多显示日期和 CarPlay 状态
    var revealTarget: CGFloat = 0
    /// 遠距離省電：沒人靠近時表情/視線直接到位，不做過場動畫（省下每幾秒十幾幀重繪）
    var animateDetails = true
    private(set) var reveal: CGFloat = 0
    /// 色块要不要跟着游标漂（游标在附近、醒着时）
    var flowActive = false
    /// 玻璃卡最下面一行：CarPlay 的真实状态
    var status: CarPlayStatus = .notConnected { didSet { if status != oldValue { forceDirty = true } } }
    /// 磁貼用：把「CarPlay xxx · 提示」拆成大字和小字（去掉開頭的 CarPlay，英文首字母大寫）
    var statusParts: (title: String, hint: String?) {
        let parts = status.text.replacingOccurrences(of: "CarPlay ", with: "").components(separatedBy: " · ")
        let t = parts.first ?? status.text
        return (t.prefix(1).uppercased() + t.dropFirst(), parts.count > 1 ? parts[1] : nil)
    }
    private var helloStart = -1.0
    static let helloDuration = 2.6

    private(set) var wallpaper: CGImage?, frosted: CGImage?
    private var paletteKey = -1
    private(set) var flow = CGPoint.zero, flowV = CGPoint.zero, builtFlow = CGPoint(x: 9, y: 9)
    private var lastWall = 0.0
    /// 輕量模糊（兩次 tent ≈ 高斯）：不經過 GPU／Core Image
    static func cpuBlur(_ img: CGImage, radius: Int) -> CGImage? {
        let w = img.width, h = img.height, rb = w * 4
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: rb, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue), let src = ctx.data else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let tmp = malloc(rb * h) else { return nil }
        defer { free(tmp) }
        var a = vImage_Buffer(data: src, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: rb)
        var b = vImage_Buffer(data: tmp, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: rb)
        let k = UInt32(radius * 2 + 1)
        guard vImageTentConvolve_ARGB8888(&a, &b, nil, 0, 0, k, k, nil, vImage_Flags(kvImageEdgeExtend)) == kvImageNoError,
              vImageTentConvolve_ARGB8888(&b, &a, nil, 0, 0, k, k, nil, vImage_Flags(kvImageEdgeExtend)) == kvImageNoError else { return nil }
        return ctx.makeImage()
    }
    private static let blobSpots: [(CGPoint, CGFloat, CGFloat)] =   // 位置、半径、视差（跟游标漂的比例）
        [(CGPoint(x: 780, y: 230), 360, 1.0), (CGPoint(x: 170, y: 840), 420, -0.7),
         (CGPoint(x: 900, y: 930), 300, 0.5), (CGPoint(x: 330, y: 470), 260, -1.2)]

    /// 只會用到 15 分鐘一格的色票，沒必要每幀算一次；半分鐘更新一次足夠。
    private var cachedHour: Double = -1
    private var cachedHourAt: Double = -1
    var hourNow: Double {
        if let hourOverride { return hourOverride }
        let now = CACurrentMediaTime()
        if cachedHour < 0 || now - cachedHourAt > 30 {
            let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
            cachedHour = Double(c.hour ?? 12) + Double(c.minute ?? 0) / 60
            cachedHourAt = now
        }
        return cachedHour
    }

    func rebuildWallpaper() {
        wallpaperGeneration &+= 1
        let pal = Self.palette(hour: hourNow, aqua: aqua), fl = flow, isAqua = aqua
        let img = makeImage(256, 256) { g in
            g.scaleBy(x: 0.25, y: 0.25)
            let cs = CGColorSpace(name: CGColorSpace.sRGB)
            let grad = CGGradient(colorsSpace: cs, colors: [pal.top.color(), pal.bottom.color()] as CFArray, locations: [0, 1])!
            g.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: 1024), options: [])
            for (i, spot) in Self.blobSpots.enumerated() {
                let (c0, r, par) = spot, (col, a) = pal.blobs[i]
                let c = CGPoint(x: c0.x + fl.x * 70 * par, y: c0.y + fl.y * 70 * par)
                let b = CGGradient(colorsSpace: cs, colors: [col.color(a), col.color(0)] as CFArray, locations: [0, 1])!
                g.drawRadialGradient(b, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
            }
            if isAqua {
                // Aqua 那种大弧线光带（自己画的，不是任何官方壁纸）
                g.setLineCap(.round)
                for (k, w, a) in [(0.0, 90.0, 0.10), (1.0, 46.0, 0.14), (2.0, 20.0, 0.18)] as [(CGFloat, CGFloat, CGFloat)] {
                    g.setStrokeColor(NSColor(white: 1, alpha: a).cgColor); g.setLineWidth(w)
                    g.addEllipse(in: CGRect(x: -380 + k * 60 + fl.x * 40, y: 420 - k * 40 + fl.y * 30, width: 1700, height: 900))
                    g.strokePath()
                }
            }
            g.setFillColor(NSColor.white.withAlphaComponent(0.07).cgColor)
            g.fillEllipse(in: CGRect(x: 820 - 260, y: 180 - 260, width: 520, height: 520))
        }
        wallpaper = img
        // 用 CPU（Accelerate）模糊：真機 2026-10-25 首次設定時 Core Image 在這裡 GPU 段錯誤閃退
        frosted = Self.cpuBlur(img, radius: 7) ?? img
        builtFlow = flow
    }

    /// 启动时的彩蛋：屏幕先用手写体写一个 hello，再换成脸（G4 白外观才有）
    func sayHello(_ now: Double) { helloStart = now; forceDirty = true }
    func cancelHello() { helloStart = -1; forceDirty = true }
    var sayingHello: Bool { helloStart >= 0 && CACurrentMediaTime() - helloStart < Self.helloDuration }

    /// 每帧推进壁纸、展开、Flow；有变化返回 true
    private func tickScreen(_ now: Double, _ dt: Double) -> Bool {
        var dirty = false
        let key = Int(hourNow * 4) + (aqua ? 1000 : 0)
        if key != paletteKey || wallpaper == nil { paletteKey = key; rebuildWallpaper(); dirty = true; Face.dbgPal += 1 }

        let r0 = reveal
        reveal += (revealTarget - reveal) * CGFloat(1 - exp(-dt / 0.18))
        if abs(revealTarget - reveal) < 0.002 { reveal = revealTarget }
        if reveal != r0 { dirty = true; Face.dbgReveal += 1 }

        // Flow：临界阻尼弹簧，响应 1.2 s；漂动时最多每秒重画 20 次
        var goal = CGPoint.zero
        if flowActive || style == .flow, let p = pointer { goal = CGPoint(x: max(-1, min(1, p.x)), y: max(-1, min(1, p.y))) }
        let k = pow(2 * Double.pi / 1.2, 2), c = 2 * sqrt(k)
        flowV.x += CGFloat((Double(goal.x - flow.x) * k - Double(flowV.x) * c) * dt); flow.x += flowV.x * CGFloat(dt)
        flowV.y += CGFloat((Double(goal.y - flow.y) * k - Double(flowV.y) * c) * dt); flow.y += flowV.y * CGFloat(dt)
        if hypot(flow.x - builtFlow.x, flow.y - builtFlow.y) > 0.004, now - lastWall > 0.16 {
            lastWall = now; rebuildWallpaper(); dirty = true; Face.dbgFlow += 1
        }
        if helloStart >= 0 {
            if now - helloStart < Self.helloDuration { dirty = true } else { helloStart = -1; dirty = true }
            Face.dbgHello += 1
        }
        return dirty
    }

    /// 画布已翻成左上原点，直接画 CGImage 会上下颠倒；这里翻回来画，r 是左上原点的目标框
    func drawUpright(_ g: CGContext, _ img: CGImage, in r: CGRect) {
        g.saveGState(); g.translateBy(x: 0, y: r.minY + r.maxY); g.scaleBy(x: 1, y: -1)
        g.interpolationQuality = .high
        g.draw(img, in: r); g.restoreGState()
    }
    /// 以 c 为中心放大 s 倍画一张整屏图（玻璃的「透镜」：中间轻放大，边缘一圈放大得更多＝折射）
    func lens(_ g: CGContext, _ img: CGImage, around c: CGPoint, _ s: CGFloat) {
        drawUpright(g, img, in: CGRect(x: c.x - c.x * s, y: c.y - c.y * s, width: 1024 * s, height: 1024 * s))
    }

    /// 一块液态玻璃：底下一圈软阴影；里面透出模糊并轻放大的壁纸，边缘 band 宽的一圈折射更强；
    /// 上一层染色和顶部内光；Aqua 时再加细横条纹和上半部的凝胶高光；最后是左上亮、右下次亮的镜面细边。
    func glass(_ g: CGContext, _ r: CGRect, radius: CGFloat, tint: NSColor, band: CGFloat = 16) {
        guard let frosted else { return }
        let pill = radius >= r.height / 2 - 0.5   // 膠囊維持半圓兩端；卡片用跟螢幕同一種連續圓角
        func shape(_ rr: CGRect, _ rad: CGFloat) -> CGPath {
            pill ? CGPath(roundedRect: rr, cornerWidth: min(rad, rr.height / 2), cornerHeight: min(rad, rr.height / 2), transform: nil) : continuousRoundedRect(rr, radius: rad)
        }
        let path = shape(r, radius)
        let c = CGPoint(x: r.midX, y: r.midY)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: 18), blur: 44, color: NSColor(white: 0, alpha: 0.32).cgColor)
        g.addPath(path); g.setFillColor(NSColor.black.cgColor); g.fillPath()
        g.restoreGState()

        g.saveGState()
        g.addPath(path); g.clip()
        lens(g, frosted, around: c, 1.05)
        let ir = r.insetBy(dx: band, dy: band), irad = max(1, radius - band)
        g.addPath(path); g.addPath(shape(ir, irad))
        g.clip(using: .evenOdd)
        lens(g, frosted, around: c, 1.16)
        g.restoreGState()

        g.saveGState()
        g.addPath(path); g.clip()
        g.setFillColor(tint.cgColor); g.fill(r)
        if aqua {
            g.setFillColor(NSColor(white: 1, alpha: 0.045).cgColor)
            var y = r.minY; while y < r.maxY { g.fill(CGRect(x: r.minX, y: y, width: r.width, height: 2)); y += 6 }
            let hr = CGRect(x: r.minX + 10, y: r.minY + 6, width: r.width - 20, height: r.height * 0.48)
            let hrad = min(radius - 6, hr.height / 2)
            g.addPath(shape(hr, max(1, hrad))); g.clip()
            let gel = CGGradient(colorsSpace: cs, colors: [NSColor(white: 1, alpha: 0.55).cgColor, NSColor(white: 1, alpha: 0.06).cgColor] as CFArray,
                                 locations: [0, 1])!
            g.drawLinearGradient(gel, start: CGPoint(x: 0, y: hr.minY), end: CGPoint(x: 0, y: hr.maxY), options: [])
        } else {
            let glow = CGGradient(colorsSpace: cs, colors: [NSColor(white: 1, alpha: 0.20).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                                  locations: [0, 1])!
            g.drawLinearGradient(glow, start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.minY + r.height * 0.45), options: [])
        }
        g.restoreGState()

        g.saveGState()
        g.addPath(path); g.setLineWidth(5); g.replacePathWithStrokedPath(); g.clip()
        let rim = CGGradient(colorsSpace: cs, colors: [NSColor(white: 1, alpha: 0.95).cgColor, NSColor(white: 1, alpha: 0.12).cgColor,
                                                       NSColor(white: 1, alpha: 0.12).cgColor, NSColor(white: 1, alpha: 0.55).cgColor] as CFArray,
                             locations: [0, 0.35, 0.65, 1])!
        g.drawLinearGradient(rim, start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
        g.restoreGState()
    }

    // MARK: 錶面与即时动态

    /// 现在用哪个錶面
    var style: FaceStyle = .island { didSet { if style != oldValue { beginFaceTransition(); forceDirty = true } } }
    /// 換錶面的過場：舊的一張（清楚版＋霧化版）與開始時刻（Faces/ScreenGeometry.swift 的 drawFaceTransition）
    var lastFrame: CGImage?
    /// 這一幀膠囊（眼睛）佔的範圍（1024 畫布）：海報補丁只補這裡面的變化（眨眼、瞄一眼）
    var islandRect: CGRect?
    private var islandRectBuilding: CGRect?
    var faceTransition: (sharp: CGImage, frosted: CGImage, start: Double)?
    /// 島錶面的自由组合（见 IslandOptions.swift）
    var clockStyle: ClockStyle = .bold { didSet { if clockStyle != oldValue { forceDirty = true } } }
    var background: IslandBackground = .daytime { didSet { if background != oldValue { forceDirty = true } } }
    var era: Era = .y2026 { didSet { if era != oldValue { forceDirty = true } } }
    var typographMaterial: TypographMaterial = .flat { didSet { if typographMaterial != oldValue { forceDirty = true } } }
    var system6Layout: System6Layout = .finder { didSet { if system6Layout != oldValue { forceDirty = true } } }
    /// 正在播放（NowPlaying.swift 的轮询写入；计时器优先）
    var nowPlaying = NowPlayingState()
    /// 电量（PetView 每分钟读一次）；nil＝没有电池
    var battery: Battery.Reading? { didSet { if battery != oldValue { forceDirty = true } } }
    var photos = PhotoShelf(folder: PhotoShelf.defaultFolder)
    /// 模組錶面「下一个行程」那一格（CalendarSource.swift 写入；真数据）
    var calendarTile: CalendarTile = .notConnected { didSet { if calendarTile != oldValue { forceDirty = true } } }
    /// 计时器到点时叫一下（PetView 让岛惊讶、甩头）
    var onTimerDone: (() -> Void)?
    private(set) var timerEnd: Double?
    private(set) var timerTotal = 1.0
    /// 番茄鐘在跑時，計時器的標題與到點橫幅改成番茄鐘的說法
    var pomodoro = Pomodoro() { didSet { if pomodoro != oldValue { forceDirty = true } } }
    /// 計時器這一格的標題：一般「計時器」；番茄鐘「專注 2/4」「休息一下」「長休息」
    var timerLabel: String {
        switch pomodoro.phase {
        case .focus: return String(format: L("pomodoro.focusRound", "专注 %d/%d"), pomodoro.displayRound, Pomodoro.roundsPerSet)
        case .shortBreak: return L("pomodoro.break", "休息一下")
        case .longBreak: return L("pomodoro.longBreak", "长休息")
        case nil: return L("timer.title", "计时器")
        }
    }
    /// 到點橫幅（剛結束的那一段）：標題與大字
    private(set) var bannerTexts: (title: String, big: String)?
    private var lastTimerSecond = -1
    private(set) var liveT: CGFloat = 0          // 岛长成即时动态的进度（0 岛 … 1 计时器胶囊）
    private var bannerUntil = 0.0
    var timerActive: Bool { timerEnd != nil }
    /// 这些錶面自己有计时器那一格/那张卡，岛不用长成胶囊
    static let timerInTile: Set<FaceStyle> = [.modular, .pocket]
    var bannerShowing: Bool { CACurrentMediaTime() < bannerUntil }

    func startTimer(seconds: Double, now: Double = CACurrentMediaTime()) {
        timerTotal = max(1, seconds); timerEnd = now + timerTotal; bannerUntil = 0; forceDirty = true
        timerEndWall = Date().timeIntervalSinceReferenceDate + timerTotal
    }
    /// Mac 睡眠时 CACurrentMediaTime 不走：醒来按墙上时间把到点时刻对回来
    private var timerEndWall: Double?
    func resyncTimer(now: Double = CACurrentMediaTime()) {
        guard timerEnd != nil, let w = timerEndWall else { return }
        timerEnd = now + (w - Date().timeIntervalSinceReferenceDate); forceDirty = true
    }
    func cancelTimer() { timerEnd = nil; timerEndWall = nil; forceDirty = true }
    func showBanner(now: Double = CACurrentMediaTime(), texts: (title: String, big: String)? = nil) {
        bannerTexts = texts; bannerUntil = now + 12; forceDirty = true
    }
    func dismissBanner() { bannerUntil = 0; forceDirty = true }

    /// 计时器、展开动画、横幅、照片：有变化回 true
    private func tickLive(_ now: Double, _ dt: Double) -> Bool {
        var dirty = false
        if let end = timerEnd {
            if now >= end {
                timerEnd = nil; showBanner(now: now); onTimerDone?(); dirty = true
            } else {
                let s = Int((end - now).rounded(.up))
                if s != lastTimerSecond { lastTimerSecond = s; dirty = true }
            }
        }
        if tickMusic(now) { dirty = true }
        if siriOrb.active(now) || (siriOrb.upAt > 0 && now - siriOrb.upAt < SiriOrbState.think + SiriOrbState.settle + 0.1) { dirty = true }
        let goal: CGFloat = (timerActive || musicActive(now)) && !Self.timerInTile.contains(style) ? 1 : 0
        if liveT != goal {
            liveT += (goal - liveT) * CGFloat(1 - exp(-dt / 0.12))
            if abs(goal - liveT) < 0.003 { liveT = goal }
            dirty = true
        }
        if bannerUntil > 0, now >= bannerUntil { bannerUntil = 0; dirty = true }
        if tickOnboarding(now) { dirty = true }   // 第一次打开的操作提示（Onboarding.swift）
        if style == .photos || (style == .island && background == .photo) || FaceOverview.active, photos.tick(now) { dirty = true }
        if tickCarPlayOverlay(now, dt) { dirty = true }   // 连线中过场的淡入淡出与转圈
        if tickPermissionPrimer(now, dt) { dirty = true }   // 权限说明卡（PermissionPrimer.swift）
        // 各錶面自己要不要重画（秒针、轮替、漂动…），实现在 Faces/ 里
        switch style {
        case .analog: if (typographMaterial == .embossed ? tickEmbossedFace(now) : tickAnalogFace(now)) { dirty = true }
        case .flow: if tickFlowFace(now) { dirty = true }
        case .pocket: if tickPocketFace(now) { dirty = true }
        case .growth: if tickGrowthFace(now) { dirty = true }
        case .system6:
            switch system6Layout {
            case .finder: if tickSystem6Face(now) { dirty = true }
            case .alarmClock: if tickAlarmClockFace(now) { dirty = true }
            case .about: if tickAboutFace(now) { dirty = true }
            }
        case .weather: if tickWeatherFace(now) { dirty = true }
        case .modular: if tickModularFace(now) { dirty = true }
        case .calendar: if tickCalendarFace(now) { dirty = true }
        case .homeModular: if tickHomeModularFace(now) { dirty = true }
        case .embossed: if tickEmbossedFace(now) { dirty = true }
        case .black: if tickBlackFace(now) { dirty = true }
        case .alarmClock: if tickAlarmClockFace(now) { dirty = true }
        case .about: if tickAboutFace(now) { dirty = true }
        case .island: if tickIslandOptions(now) { dirty = true }
        default: break
        }
        if tickOverview(now, dt) { dirty = true }   // 长按换錶面总览（FaceOverview.swift）
        if faceTransition != nil { dirty = true }  // 換錶面的過場還在跑
        return dirty
    }

    func render(_ now: Double = CACurrentMediaTime()) -> CGImage {
        Face.renderCount += 1
        let t0 = CACurrentMediaTime()
        defer { Face.renderSeconds += CACurrentMediaTime() - t0 }
        if wallpaper == nil { rebuildWallpaper() }
        let sc = max(0.25, min(2, renderScale))
        renderPixelScale = sc
        let px = Int((1024 * sc).rounded())
        let tr = faceTransitionProgress(now)
        islandRectBuilding = nil
        defer { islandRect = islandRectBuilding }
        let frame = makeImage(px, px) { g in
            if sc != 1 { g.scaleBy(x: sc, y: sc) }
            if let tr { beginFaceTransitionFrame(g, tr) }
            if helloStart >= 0, now - helloStart < Self.helloDuration {
                if let wallpaper { drawUpright(g, wallpaper, in: CGRect(x: 0, y: 0, width: 1024, height: 1024)) }
                drawHello(g, CGFloat((now - helloStart) / Self.helloDuration)); return
            }
            switch style {
            case .island: renderIslandFace(g, now)
            case .photos: renderPhotosFace(g, now)
            case .modular: renderModularFace(g, now)
            case .bedside: renderBedsideFace(g, now)
            // 下面几个各在 Faces/ 里自己的文件
            case .analog: if typographMaterial == .embossed { renderEmbossedFace(g, now) } else { renderAnalogFace(g, now) }   // 材質：Faces/EmbossedFace.swift
            case .flow: renderFlowFace(g, now)
            case .pocket: renderPocketFace(g, now)
            case .growth: renderGrowthFace(g, now)
            case .system6:
                switch system6Layout {   // 版式：Faces/System6Series.swift
                case .finder: renderSystem6Face(g, now)
                case .alarmClock: renderAlarmClockFace(g, now)
                case .about: renderAboutFace(g, now)
                }
            case .weather: renderWeatherFace(g, now)          // Faces/WeatherFace.swift
            case .calendar: renderCalendarFace(g, now)        // Faces/CalendarFace.swift
            case .homeModular: renderHomeModularFace(g, now)  // Faces/HomeModularFace.swift
            case .embossed: renderEmbossedFace(g, now)        // Faces/EmbossedFace.swift
            case .black: renderBlackFace(g, now)              // Faces/BlackFace.swift
            case .alarmClock: renderAlarmClockFace(g, now)    // Faces/System6Series.swift
            case .about: renderAboutFace(g, now)              // Faces/System6Series.swift
            }
            if let tr { endFaceTransitionFrame(g, tr) }   // 舊錶面像起霧的玻璃一樣化開
            drawCarPlayOverlay(g, now)   // 连线中过场（CarPlayOverlay.swift）
            if FaceOverview.active { drawOverview(g, now) }   // 长按换錶面总览盖在最上面
            if Onboarding.active { drawOnboarding(g, now) }   // 第一次打开的操作提示
            drawPermissionPrimer(g, now)                       // 权限说明卡盖在最上面（要点按钮）
            if bannerUntil > now { drawBanner(g, red: style == .bedside) }
            if cur.dim > 0.005 && style != .bedside {
                g.setFillColor(NSColor.black.withAlphaComponent(cur.dim).cgColor)
                g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
            }
        }
        lastFrame = frame
        return frame
    }

    /// 島：上方一行小字日期，中间巨大的圆体时间，岛站在数字前面（像 Portraits 的景深）。
    /// 远处是恒亮的省电样子（整面暗一点、数字细一点），游标靠近才亮起来、数字变粗，底部浮出 CarPlay 状态。
    private func renderIslandFace(_ g: CGContext, _ now: Double) { renderIslandOptions(g, now) }   // 实现在 IslandOptions.swift

    /// 照片：照片铺满，左上是星期与大时间，右下一只小岛；拍摄日期在左下。
    private func renderPhotosFace(_ g: CGContext, _ now: Double) { renderPhotosV2(g, now) }   // Faces/PhotosFace.swift

    /// 模組：照 HomeView 的 Modular 重做（Faces/ModularFace.swift）
    private func renderModularFace(_ g: CGContext, _ now: Double) { renderModularV2(g, now) }

    /// 床头夜灯：全黑底、暗紅的窄高細字大時間（不刺眼、看得清），島閉著眼；不吃壁紙、不跟游標亮起來。
    private func renderBedsideFace(_ g: CGContext, _ now: Double) {
        g.setFillColor(NSColor.black.cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let date = Self.displayDate, red = srgb(0xa8241c)
        drawCentered(g, Self.dateLine(date), font: FaceType.sf(36, .semibold), kern: 0.6, y: 150, color: srgb(0x5e1712))
        let (hh, mm) = Self.hourMinute(date)
        let (a, b) = GlyphShape.centeredPair(GlyphShape.adaptive(hh, height: 470, maxWidth: 400, at: CGPoint(x: 492, y: 210), anchorX: 1, weight: 220),
                                             GlyphShape.adaptive(mm, height: 470, maxWidth: 400, at: CGPoint(x: 532, y: 210), anchorX: 0, weight: 220))
        // 一點點同色的光暈，像夜裡的 LED，不是平面貼字
        g.saveGState()
        g.setShadow(offset: .zero, blur: 26, color: red.withAlphaComponent(0.45).cgColor)
        fillShape(g, a, red); fillShape(g, b, red)
        g.restoreGState()
        drawIsland(g, at: CGPoint(x: 512, y: 820), scale: 0.62, liveAt: CGPoint(x: 512, y: 820), now: now, red: true)
    }

    // 錶面每次重畫都會叫：DateFormatter 建一次約幾十微秒，用 FaceKit 的快取（依語言分開）
    static func clock(_ d: Date) -> String { formatter("H:mm", raw: true).string(from: d) }
    static func dateLine(_ d: Date) -> String { formatter("MMMMdEEEE").string(from: d) }
    /// 電量狀態一行字（模組、口袋共用）
    static func batteryState(_ b: Battery.Reading) -> String {
        b.charging ? L("battery.charging", "充电中") : (b.onAC ? L("battery.pluggedIn", "已接电源") : L("battery.onBattery", "使用电池"))
    }

    /// 岛：深色液态玻璃胶囊 + 两颗贴在一起的白眼。at/scale 是平常的位置和大小；
    /// 计时器在跑时长成一条宽胶囊（liveAt 是长大后的中心）：眼睛缩到左边，右边是倒数与圆环。red＝床头夜灯的暗红版。
    func drawIsland(_ g: CGContext, at c0: CGPoint, scale s0: CGFloat, liveAt lc: CGPoint, now: Double, red: Bool = false) {
        if capsuleLook() == .system && isSystem6Era && !red && liveT < 0.02 && !siriOrb.active(now) {   // 1988：1-bit 預設按鈕（Faces/System6Series.swift）
            drawPixelIsland(g, center: c0, scale: s0, now: now); return
        }
        let p = cur, lt = Self.timerInTile.contains(style) ? 0 : liveT
        let k0 = 1.4 * s0
        let cw0 = p.cw * k0, ch0 = p.ch * k0
        let cw = cw0 + (880 - cw0) * lt, ch = ch0 + (230 - ch0) * lt
        let c = CGPoint(x: c0.x + (lc.x - c0.x) * lt, y: c0.y + (lc.y - c0.y) * lt)
        let rect = CGRect(x: c.x - cw / 2, y: c.y - ch / 2, width: cw, height: ch)
        let eyesArea = rect.insetBy(dx: -ch * 0.6, dy: -ch * 0.45)   // 臉頰紅暈、睡著的 z 會畫到膠囊外面一點
        islandRectBuilding = islandRectBuilding.map { $0.union(eyesArea) } ?? eyesArea
        let orb = red || lt > 0.02 ? nil : siriOrbGeometry(rect, now: now)   // 按住 F5：Siri 球（Faces/Capsule.swift）
        if red {
            g.setFillColor((style == .black ? NSColor.black : srgb(0x140403)).cgColor)   // 黑錶面夜裡膠囊融進全黑，只剩眼瞼線
            g.addPath(CGPath(roundedRect: rect, cornerWidth: ch / 2, cornerHeight: ch / 2, transform: nil)); g.fillPath()
        } else if let orb {
            drawSiriOrb(g, orb.rect, listen: orb.listen, think: orb.think, now: now)
        } else if aqua && style != .island {
            glass(g, rect, radius: ch / 2, tint: NSColor(srgbRed: 0.04, green: 0.08, blue: 0.16, alpha: 0.8), band: 20 * s0)
        } else {
            drawCapsuleBody(g, rect, look: lt > 0.02 ? .smoke : capsuleLook(), animating: false)   // 長成計時器／音樂時一律黑透，字才看得清
        }
        let ke = k0 + (1.4 * 0.62 - k0) * lt
        let ex = c.x + (-cw / 2 + 150) * lt
        if red {
            // 闭着眼：两道暗红的眼皮
            g.setFillColor(srgb(0xa3271f).cgColor)
            for s: CGFloat in [-1, 1] {
                let r = CGRect(x: ex + s * p.sep * ke - 30 * ke, y: c.y - 5 * ke, width: 60 * ke, height: 10 * ke)
                g.addPath(CGPath(roundedRect: r, cornerWidth: 5 * ke, cornerHeight: 5 * ke, transform: nil)); g.fillPath()
            }
        } else {
            if p.blush > 0.01 && lt < 0.5 {
                g.setFillColor(NSColor(srgbRed: 1, green: 150 / 255, blue: 170 / 255, alpha: 0.55 * p.blush * (1 - lt * 2)).cgColor)
                for s: CGFloat in [-1, 1] {   // 收在膠囊裡、眼睛外下方
                    let bx = c.x + s * (p.sep * k0 + p.rx * k0 * 1.55), by = c.y + p.ry * k0 * 0.62
                    g.fillEllipse(in: CGRect(x: bx - 30 * s0, y: by - 16 * s0, width: 60 * s0, height: 32 * s0))
                }
            }
            let bf = blinkFactor(now)
            if let orb {   // Siri 球：眼睛跟著球往下、略往上讓出波形；思考時淡出
                g.saveGState(); g.setAlpha(1 - orb.think)
                let ey = orb.rect.midY - orb.rect.height * 0.13 * orb.listen
                for s: CGFloat in [-1, 1] { drawEye(g, cx: orb.rect.midX + s * p.sep * ke, cy: ey, side: s, blinkF: bf, k: ke) }
                g.restoreGState()
            } else {
                for s: CGFloat in [-1, 1] { drawEye(g, cx: ex + s * p.sep * ke, cy: c.y, side: s, blinkF: bf, k: ke) }
            }
        }
        if lt > 0.02, timerEnd == nil { drawMusicCapsule(g, rect: rect, c: c, lt: lt, now: now, red: red) }
        if lt > 0.02, let end = timerEnd {
            let left = max(0, end - now), frac = CGFloat(left / timerTotal)
            let accent = red ? srgb(0xb3261e) : srgb(0xffb340)
            g.saveGState(); g.setAlpha(min(1, (lt - 0.3) / 0.7))
            drawLeft(g, timerLabel, font: Self.rounded(34, weight: .bold), x: rect.minX + 300, y: c.y - 14, color: accent)
            drawLeft(g, L("timer.left", "还剩"), font: Self.rounded(30, weight: .semibold), x: rect.minX + 300, y: c.y + 36,
                     color: NSColor.white.withAlphaComponent(red ? 0.35 : 0.6))
            let font = Self.rounded(118, weight: .semibold), txt = timerClock(left)
            let tw = Typo.width(txt, font)
            drawLeft(g, txt, font: font, x: rect.maxX - 200 - tw, y: c.y + 42, color: accent)
            let rc = CGPoint(x: rect.maxX - 104, y: c.y)
            g.setLineWidth(15); g.setLineCap(.round)
            g.setStrokeColor(accent.withAlphaComponent(0.25).cgColor)
            g.addArc(center: rc, radius: 52, startAngle: 0, endAngle: .pi * 2, clockwise: false); g.strokePath()
            g.setStrokeColor(accent.cgColor)
            g.addArc(center: rc, radius: 52, startAngle: -.pi / 2, endAngle: -.pi / 2 + .pi * 2 * frac, clockwise: false); g.strokePath()
            g.restoreGState()
        }
        if expression == .asleep && lt < 0.1 && !red {
            let up = Int(now) % 2 == 0
            drawText(g, "z", at: CGPoint(x: c.x + cw / 2 + 18 * s0, y: c.y + (up ? 6 : 18) * s0), size: 58 * s0, weight: .semibold,
                     color: NSColor.white.withAlphaComponent(0.8))
            drawText(g, "z", at: CGPoint(x: c.x + cw / 2 + 64 * s0, y: c.y - (up ? 46 : 30) * s0), size: 80 * s0, weight: .semibold,
                     color: NSColor.white.withAlphaComponent(0.55))
        }
    }

    /// 计时器到点的横幅：顶上一块液态玻璃（夜灯时是暗红），点一下屏幕收起，12 秒后自己收
    private func drawBanner(_ g: CGContext, red: Bool) {
        let r = CGRect(x: 56, y: 56, width: 912, height: 230), rad = Screen.concentric(inset: 56)   // 跟螢幕圓角同心
        if red {
            g.setFillColor(srgb(0x1a0504).cgColor)
            g.addPath(continuousRoundedRect(r, radius: rad)); g.fillPath()
        } else {
            glass(g, r, radius: rad, tint: NSColor(white: 1, alpha: 0.18), band: 14)
        }
        let accent = red ? srgb(0xb3261e) : srgb(0xff9f0a)
        let icon = CGRect(x: r.minX + 44, y: r.midY - 60, width: 120, height: 120)
        g.setFillColor(accent.cgColor)
        g.addPath(continuousRoundedRect(icon, radius: icon.width * 0.2237)); g.fillPath()   // App 圖示的連續圓角比例
        g.setStrokeColor((red ? NSColor.black : NSColor.white).cgColor); g.setLineWidth(9); g.setLineCap(.round)
        g.addArc(center: CGPoint(x: icon.midX, y: icon.midY + 6), radius: 34, startAngle: 0, endAngle: .pi * 2, clockwise: false); g.strokePath()
        g.move(to: CGPoint(x: icon.midX, y: icon.midY + 6)); g.addLine(to: CGPoint(x: icon.midX, y: icon.midY - 16)); g.strokePath()
        let fg = red ? srgb(0xb3261e) : NSColor.white
        drawLeft(g, bannerTexts?.title ?? L("timer.banner.title", "计时器 · 现在"), font: Self.rounded(32, weight: .bold), x: icon.maxX + 34, y: r.minY + 92, color: fg.withAlphaComponent(0.7))
        drawLeft(g, bannerTexts?.big ?? L("timer.banner.done", "时间到了"), font: Self.rounded(64, weight: .bold), x: icon.maxX + 34, y: r.minY + 168, color: fg)
        let df = Self.rounded(30, weight: .semibold), dismiss = L("timer.banner.dismiss", "点一下收起")
        drawLeft(g, dismiss, font: df, x: r.maxX - 44 - Typo.width(dismiss, df), y: r.minY + 168, color: fg.withAlphaComponent(0.6))
    }


    /// 左对齐画一行字，y 是基线（画布左上原点）
    /// kern 為 nil＝照螢幕上的實際字級套 SF 的 trak 字距（Typography.swift）；亮字自動加一點 GRAD
    func drawLeft(_ g: CGContext, _ s: String, font: NSFont, x: CGFloat, y: CGFloat, color: NSColor, kern: CGFloat? = nil) {
        let f = color.isLightInk ? FaceType.graded(font, 440) : font
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: Typo.attributes(f, color: color, kern: kern)))
        g.saveGState(); g.translateBy(x: x, y: y); g.scaleBy(x: 1, y: -1)
        g.textPosition = .zero; CTLineDraw(line, g); g.restoreGState()
    }

    /// hello：手写体从左到右「写」出来（裁切框跟着长），写完停一下，再淡出
    private func drawHello(_ g: CGContext, _ t: CGFloat) {
        // 字体：Macintosh Skeletal Filled（npwitk/Macintosh-Skeletal-Filled，个人非商业使用，装在 ~/Library/Fonts，不进仓库）；
        // 没装就退回 Snell Roundhand
        func line(_ size: CGFloat) -> CTLine {
            let font = NSFont(name: "MacintoshSkeletalFilled-Regular", size: size)
                ?? NSFont(name: "SnellRoundhand-Bold", size: size) ?? NSFont.systemFont(ofSize: size, weight: .light)
            return CTLineCreateWithAttributedString(NSAttributedString(string: "hello", attributes: [.font: font, .foregroundColor: NSColor.white]))
        }
        let probe = CTLineGetBoundsWithOptions(line(200), .useGlyphPathBounds)
        let line = line(200 * 700 / max(1, probe.width))          // 写满屏宽的约 70%
        let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let x0 = 512 - b.width / 2 - b.minX, base: CGFloat = 512 + (b.minY + b.maxY) / 2
        let write = min(1, t / 0.55), fade = t > 0.8 ? (1 - (t - 0.8) / 0.2) : 1
        g.saveGState()
        g.setAlpha(fade)
        g.clip(to: CGRect(x: x0 + b.minX - 20, y: 0, width: (b.width + 40) * write, height: 1024))
        g.setShadow(offset: .zero, blur: 24, color: NSColor(white: 1, alpha: 0.45).cgColor)
        g.translateBy(x: x0, y: base); g.scaleBy(x: 1, y: -1)
        g.textPosition = .zero; CTLineDraw(line, g)
        g.restoreGState()
    }

    func drawEye(_ g: CGContext, cx: CGFloat, cy: CGFloat, side: CGFloat, blinkF: CGFloat, k: CGFloat = 1.4) {
        let p = cur
        let rx = p.rx * k, ry = p.ry * k
        guard ry >= 1 else { return }
        let winkEye = expression == .wink && side < 0         // 眨单眼：左眼也画成闭眼
        let lidA: CGFloat = winkEye || expression == .asleep ? 1 : max(0, min(1, (0.6 - blinkF) / 0.35))
        let irisA: CGFloat = winkEye || expression == .asleep ? 0 : max(0, min(1, (blinkF - 0.5) / 0.2))
        let smile = p.smile, ps = winkEye ? 0 : p.ps
        g.saveGState()
        let eye = CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)
        g.addEllipse(in: eye); g.clip()
        g.beginTransparencyLayer(auxiliaryInfo: nil)   // 眼皮在這層裡「切掉」形狀，玻璃／漸層膠囊上才不會露出黑塊
        // 眼白照 Apple Color Emoji 的 👀 取樣：中間純白，沿橢圓邊一圈約 15% 寬的內陰影，
        // 邊上落到 0.58 灰（像枕頭的鼓面），沒有描邊。用縮放過的徑向漸層做成「橢圓等距」的暈。
        let cs = CGColorSpaceCreateDeviceRGB()
        g.setFillColor(NSColor.white.cgColor); g.fill(eye)
        let pillow = CGGradient(colorsSpace: cs, colors: [
            NSColor(white: 1, alpha: 0).cgColor,
            NSColor(white: 0.985, alpha: 0.6).cgColor,
            NSColor(white: 0.90, alpha: 1).cgColor,
            NSColor(white: 0.76, alpha: 1).cgColor,
            NSColor(white: 0.58, alpha: 1).cgColor,
        ] as CFArray, locations: [0, 0.80, 0.89, 0.955, 1])!
        g.saveGState()
        g.translateBy(x: cx, y: cy); g.scaleBy(x: 1, y: ry / rx)
        g.drawRadialGradient(pillow, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: rx * 1.002, options: [.drawsAfterEndLocation])
        g.restoreGState()

        g.setFillColor(NSColor.black.cgColor)
        if ps > 0.02 && irisA > 0.01 {                        // 闭眼时眼珠淡出，换成眼睑线
            g.saveGState()
            g.setAlpha(irisA)
            let look = expression == .idle && glanceEnd == 0 ? faceEyeLook : nil
            let qx = cx + (look?.x ?? p.pdx) * k, qy = cy + (look?.y ?? p.pdy) * k
            if expression == .love {
                g.addPath(heart(qx, qy, 18 * k * ps)); g.fillPath()
                // 心形瞳孔也保留一点眼神光，和别的表情共用同一个「光点」脊柱
                let hr = 3.2 * k * max(0.6, min(1.2, ps))
                g.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
                g.fillEllipse(in: CGRect(x: qx - 6 * k * ps - hr, y: qy - 7 * k * ps - hr,
                                         width: hr * 2, height: hr * 2))
                g.setFillColor(NSColor.black.cgColor)
            } else {
                // 👀（照 emoji 取樣）：大瞳孔深棕 #291201 佔虹膜半徑 64%；虹膜環上半是棕、下三分之一轉金（底光），
                // 外緣一圈極細的深棕；只有一顆左上的大高光。
                let ir = max(4, rx * 0.54 * ps)
                let iris = CGRect(x: qx - ir, y: qy - ir, width: ir * 2, height: ir * 2)
                g.saveGState()
                g.addEllipse(in: iris); g.clip()
                let ring = CGGradient(colorsSpace: cs, colors: [
                    srgb(0x5a2a00).cgColor, srgb(0x683900).cgColor, srgb(0x7a4800).cgColor,
                    srgb(0xb78600).cgColor, srgb(0xe2ab00).cgColor, srgb(0xd9a400).cgColor,
                ] as CFArray, locations: [0, 0.42, 0.62, 0.80, 0.92, 1])!
                g.drawLinearGradient(ring, start: CGPoint(x: qx, y: qy - ir), end: CGPoint(x: qx, y: qy + ir), options: [])
                // 環與瞳孔之間有一道更深的棕，瞳孔邊緣微微柔開
                let pr = ir * 0.64
                let pupil = CGGradient(colorsSpace: cs, colors: [
                    srgb(0x291201).cgColor, srgb(0x2b1301).cgColor, srgb(0x3a1a00, 0.95).cgColor, srgb(0x3a1a00, 0).cgColor,
                ] as CFArray, locations: [0, 0.86, 0.94, 1])!
                g.drawRadialGradient(pupil, startCenter: CGPoint(x: qx, y: qy), startRadius: 0,
                                     endCenter: CGPoint(x: qx, y: qy), endRadius: pr * 1.12, options: [])
                g.restoreGState()
                g.setStrokeColor(srgb(0x3c1b00, 0.9).cgColor)
                g.setLineWidth(max(0.8, ir * 0.06))
                g.strokeEllipse(in: iris.insetBy(dx: ir * 0.03, dy: ir * 0.03))
                let hr = ir * 0.30
                let hx = qx - ir * 0.375, hy = qy - ir * 0.56
                g.setFillColor(NSColor.white.cgColor)
                g.fillEllipse(in: CGRect(x: hx - hr, y: hy - hr, width: hr * 2, height: hr * 2))
                g.setFillColor(NSColor.black.cgColor)
            }
            g.restoreGState()
        }
        // 眼皮：绕眼睛中心往外斜（左眼外侧在左），上下各切掉一部分；笑眼用一个椭圆把下缘切成弯月
        // （以前是塗黑，只在黑膠囊上成立；現在用 .clear 把眼睛形狀本身切掉）
        g.translateBy(x: cx, y: cy); g.rotate(by: p.tilt * side)
        g.setBlendMode(.clear)
        let top = p.top + (side < 0 ? p.ltop : 0)
        if top > 0.005 {
            // 上眼睑用一条弯的边（中间低、两侧高），比直切片更像唐老鸭的眼皮；
            // 闭到 85% 以上就退回矩形，免得两侧漏白。
            if top >= 0.85 {
                g.fill(CGRect(x: -rx * 2, y: -ry * 3, width: rx * 4, height: ry * 2 + ry * 2 * top))
            } else {
                let line = -ry + 2 * ry * top
                let w = rx * 2.5, h = max(ry * 0.6, 6)
                g.fillEllipse(in: CGRect(x: -w / 2, y: line - h, width: w, height: h))
                g.fill(CGRect(x: -rx * 2, y: -ry * 3, width: rx * 4, height: line - h / 2 + ry * 3))   // 弧線以上整片切掉，頂端不留白邊
            }
        }
        if p.bot > 0.005 { g.fill(CGRect(x: -rx * 2, y: ry - ry * 2 * p.bot, width: rx * 4, height: ry * 3)) }
        if smile > 0.01 {
            let c = ry * (1.95 - 0.9 * smile)
            g.fillEllipse(in: CGRect(x: -rx * 1.35, y: c - ry * 1.1, width: rx * 2.7, height: ry * 2.2))
        }
        g.setBlendMode(.normal)
        if lidA > 0.01 {
            // 唐老鸭式闭眼：保留白色眼白，只画一条短的下弯眼睑线（和网站同一套比例）。
            g.saveGState()
            g.setAlpha(lidA)
            g.setStrokeColor(NSColor(srgbRed: 0.082, green: 0.094, blue: 0.110, alpha: 1).cgColor)
            g.setLineWidth(max(2, ry * 0.09))
            g.setLineCap(.round)
            let lid = CGMutablePath()
            lid.move(to: CGPoint(x: -rx * 0.667, y: ry * 0.192))
            lid.addQuadCurve(to: CGPoint(x: rx * 0.667, y: ry * 0.192), control: CGPoint(x: 0, y: ry * 0.5))
            g.addPath(lid); g.strokePath()
            g.restoreGState()
        }
        g.endTransparencyLayer()
        g.restoreGState()
    }

    func heart(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat) -> CGPath {
        let b = CGMutablePath()
        b.move(to: CGPoint(x: x, y: y + s * 0.9))
        b.addCurve(to: CGPoint(x: x, y: y - s * 0.45), control1: CGPoint(x: x - s * 1.5, y: y - s * 0.1),
                   control2: CGPoint(x: x - s * 0.75, y: y - s * 1.25))
        b.addCurve(to: CGPoint(x: x, y: y + s * 0.9), control1: CGPoint(x: x + s * 0.75, y: y - s * 1.25),
                   control2: CGPoint(x: x + s * 1.5, y: y - s * 0.1))
        b.closeSubpath()
        return b
    }

    /// 圆体（SF Pro Rounded）、等宽数字：錶面数字跳动时不会左右晃
    static func rounded(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
        FaceType.rounded(size, weight)   // 可變軸、中文退回同粗細的蘋方（Faces/Typography.swift）
    }
    /// 放得下就用 size，放不下就缩小（最小到 size × minScale）：卡片上的字要大，换成英文也不能出框
    static func fitted(_ s: String, size: CGFloat, weight: NSFont.Weight, maxWidth: CGFloat, minScale: CGFloat = 0.7) -> NSFont {
        let f = rounded(size, weight: weight)
        let w = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: Typo.attributes(f))), nil, nil, nil))
        guard w > maxWidth, w > 0 else { return f }
        return rounded(max(size * minScale, (size * maxWidth / w).rounded(.down)), weight: weight)
    }
    static let safeWidth: CGFloat = 944
    /// 水平置中画一行字，y 是基线（画布左上原点）
    func drawCentered(_ g: CGContext, _ s: String, font: NSFont, kern: CGFloat? = nil, y: CGFloat, color: NSColor) {
        let f = color.isLightInk ? FaceType.graded(font, 440) : font
        let a = Typo.attributes(f, color: color, kern: kern == 0 ? nil : kern)   // 0＝舊呼叫的「不加」：改成照實際字級
        let attr = NSAttributedString(string: s, attributes: a)
        let line = CTLineCreateWithAttributedString(attr)
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - ((a[.kern] as? CGFloat) ?? 0)   // 最後一字後面的字距不算
        // 太寬（大字號時鐘、德文日期）就以基線中點等比縮進螢幕安全寬度，不會被圓角裁掉
        let k = w > Self.safeWidth ? Self.safeWidth / w : 1
        g.saveGState()
        g.translateBy(x: 512, y: y); g.scaleBy(x: k, y: -k); g.translateBy(x: -w / 2, y: 0)
        g.textPosition = .zero; CTLineDraw(line, g)
        g.restoreGState()
    }

    func drawText(_ g: CGContext, _ s: String, at p: CGPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let attr = NSAttributedString(string: s, attributes: Typo.attributes(FaceType.sf(size, weight, mono: false), color: color))
        let line = CTLineCreateWithAttributedString(attr)
        g.saveGState()
        // 坐标系已翻成左上原点；文字要再翻回来，基线在 p.y
        g.translateBy(x: p.x, y: p.y); g.scaleBy(x: 1, y: -1)
        g.textPosition = .zero
        CTLineDraw(line, g)
        g.restoreGState()
    }
}

// MARK: - 心情：什么时候换哪张脸（照设计稿「触发对照」）
// 纯逻辑，时间和钟点都由调用方给，selftest 直接测。优先级：短暂反应 > 拆开 > 断线 > 睡意 > 摸头 > 靠近 > 待机。

final class Mood {
    enum Sleep { case awake, drowsy, asleep }
    static let drowsyAfter = 180.0, asleepAfter = 480.0     // 夜里闲置 3 分钟困倦，再 5 分钟睡着

    var apart = false
    var disconnected = false        // CarPlay 连上过、后来断了
    var near = false                // 游标在机身 120 pt 内
    private(set) var petSince: Double?
    private var flash: (Expression, Double)?
    private var lastActivity: Double
    private var pokes: [Double] = []

    init(now: Double) { lastActivity = now }

    static func isNight(_ hour: Int) -> Bool { hour >= 22 || hour < 6 }

    /// 短暂反应：d 秒后回到按状态算出来的脸
    func show(_ e: Expression, for d: Double, now: Double) { flash = (e, now + d) }

    /// 有人碰它（游标靠近、点、拖）。困倦或睡着时被叫醒，先惊讶 0.4 s。
    func activity(now: Double, hour: Int) {
        if sleepStage(now: now, hour: hour) != .awake { show(.surprised, for: 0.4, now: now) }
        lastActivity = now
    }

    /// 游标停在底座上（摸头）。离开时如果已经笑了，再笑 0.6 s 才回去。
    func petting(_ on: Bool, now: Double) {
        if on { if petSince == nil { petSince = now }; return }
        guard let s = petSince else { return }
        petSince = nil
        if now - s >= 1.5 { show(.happy, for: 0.6, now: now) }
    }

    /// 点身体：1.5 s 内第 5 下＝不耐烦（专注脸 1.5 s），返回 true 让调用方顺便摇头。
    func poke(now: Double) -> Bool {
        pokes = pokes.filter { now - $0 < 1.5 } + [now]
        guard pokes.count >= 5 else { return false }
        pokes = []; show(.annoyed, for: 1.5, now: now)
        return true
    }

    func sleepStage(now: Double, hour: Int) -> Sleep {
        guard Self.isNight(hour) else { return .awake }
        let idle = now - lastActivity
        return idle >= Self.asleepAfter ? .asleep : (idle >= Self.drowsyAfter ? .drowsy : .awake)
    }

    func current(now: Double, hour: Int) -> Expression {
        if let f = flash { if now < f.1 { return f.0 }; flash = nil }
        if apart { return .surprised }
        if disconnected { return .worried }
        switch sleepStage(now: now, hour: hour) {
        case .asleep: return .asleep
        case .drowsy: return .sleepy
        case .awake: break
        }
        if let s = petSince { if now - s >= 4 { return .love }; if now - s >= 1.5 { return .happy } }
        return .idle
    }
}

// MARK: - 模型（照「HomeView 拆解」稿：单位、位置、偏移都从稿里搬）

/// 外观：G4 白（白色亮面塑料，屏幕走 Aqua）或真机四色铝。铝色是照产品图估的近似值，不是官方色码。
enum Finish: String, CaseIterable {
    case g4, silver, starlight, rose, gray
    var title: String {
        switch self {
        case .g4: return L("finish.g4", "G4 白")
        case .silver: return L("finish.silver", "银色")
        case .starlight: return L("finish.starlight", "星光色")
        case .rose: return L("finish.rose", "玫瑰粉")
        case .gray: return L("finish.gray", "深空灰")
        }
    }
    var aluminum: UInt32? {
        switch self {
        case .g4: return nil
        case .silver: return 0xc0c2c6
        case .starlight: return 0xd0c3ae
        case .rose: return 0xd6bab3
        case .gray: return 0x5d5f64
        }
    }
    static let defaultsKey = "HomePlayFinish"
}

/// RealityKit 版机身：直接载入 Apple 的 USDZ，几何和材质原生。
/// 换铝色时网罩仍用原生孔洞遮罩，只替换成同色 PBR，孔洞和孔后的深色衬里都保留。
/// 相机、铰链、表情贴图、拆解、配色都保持原来的语义。
final class HomeViewModel {
    // 实测（cm）：屏幕面中心 y=10.46，铰链 y=7.20，屏幕后仰 20°
    static let tilt: CGFloat = 0.35
    static let rigY: CGFloat = 10.46
    static let hingeY: CGFloat = 7.20
    static let rigHome = SIMD3<Float>(0, 7.20, 3.80)
    /// 拆開時螢幕組整個離開底座的位移
    static let screenLift = SIMD3<Float>(0, 9.5, 3.0)
    static let screenSize: Float = 12.54

    /// 世界单位是厘米：USDZ 根节点自带 0.01（米），再乘 100 回到厘米。
    let holder = Entity()
    /// 屏幕组绕真实铰链转（追人/点头/摇头）
    let screenPivot = Entity()
    /// 隐藏的屏幕平面：只有变换，用来算触控 UV / 投影
    let screenAnchor = Entity()

    private(set) var finish: Finish = .starlight
    private var usdzRoot: Entity?
    private var baseGroup: Entity?
    private var screenGroup: Entity?
    private var screenBack: Entity?
    private var displayNode: ModelEntity?
    private var displayLoaded = false

    /// 屏幕贴图：脸的 CGImage 或直播的 MTLTexture。
    private var screenTexture: TextureResource?
    private var screenMaterial = HomeViewModel.makeScreenMaterial()
    /// 場景「看得見的變化」計數：貼圖、材質換了就加一。PetView 以此決定要不要讓 RealityKit 出幀。
    private(set) var generation = 0

    private struct BodyPart {
        let entity: ModelEntity
        let materials: [any Material]
    }
    private var bodyParts: [BodyPart] = []

    /// 三层网罩：外层冲孔板、内层孔衬、最里面的实心衬底。
    /// 孔洞来自 USDZ 自带的 opacity 遮罩，换材质时仍然保留。
    private var grilleParts: [BodyPart] = []
    private var screenGrillePart: BodyPart?
    private var grilleInnerParts: [BodyPart] = []
    private var grilleBackingParts: [BodyPart] = []
    private var grilleMask: TextureResource?
    private var usbPort: USBCPortAssembly?

    /// 拆解時逐件位移：九層（見 Anatomy.swift）各自一個時間窗，外層先動。只平移，不轉。
    private struct ExplodeMover {
        let entity: Entity
        let origin: SIMD3<Float>
        let offset: SIMD3<Float>
        let layer: AnatomyLayer
    }
    private var explodeMovers: [ExplodeMover] = []
    /// 生成的內部件與 USB‑C 母座：實體 → 哪一件（USDZ 零件用節點名查 AnatomyPart.usdz）
    private var anatomyParts: [ObjectIdentifier: AnatomyPart] = [:]
    /// 螢幕座標容器：原點＝顯示面中心，+z＝螢幕法線（後仰 20°）。生成的螢幕內部件放這裡。
    private let anatomyScreen = Entity()
    private var anatomyFrame: Entity?
    private var anatomyRadiators: [(Entity, Float)] = []
    private var anatomyWoofer: Entity?
    private var anatomyPower: Entity?
    private(set) var anatomyGenerated: [ModelEntity] = []
    private var picker: AnatomyPicker?

    /// 给 ARView.hitTest 用的不可见碰触盒（包住整机）
    private(set) var hitBody = Entity()

    private static func makeScreenMaterial() -> UnlitMaterial {
        if #available(macOS 15.0, *) {
            // 脸是自发光 UI，不要再过一遍场景的色调映射
            return UnlitMaterial(applyPostProcessToneMap: false)
        }
        return UnlitMaterial()
    }

    init() {
        holder.name = "homeview"
        holder.scale = SIMD3<Float>(repeating: 100)
        screenPivot.name = "screenPivot"
        screenPivot.position = Self.rigHome
        screenAnchor.name = "screenAnchor"
        screenAnchor.position = SIMD3<Float>(0, Float(Self.rigY - Self.hingeY), 4.28 - Self.rigHome.z)
        screenAnchor.orientation = simd_quatf(angle: -Float(Self.tilt), axis: SIMD3<Float>(1, 0, 0))

        guard let url = Bundle.module.url(forResource: "apple-homeview", withExtension: "usdz") else {
            log("USDZ 不在资源包里：apple-homeview.usdz")
            return
        }
        do {
            let root = try Entity.load(contentsOf: url)
            usdzRoot = root
            root.name = "usdz"
            // 只要机器本体：USB-C 线整组隐藏，旧的米色端口占位由新的母座取代。
            root.findEntity(named: "tLEDFVYGwydBKWm")?.isEnabled = false
            root.findEntity(named: "FotmOZuSlJsjcoC")?.isEnabled = false
            holder.addChild(root)
            guard let base = root.findEntity(named: "NJhDUJBxvaEheAQ"),
                  let screen = root.findEntity(named: "CnqMXaudxjxUchB"),
                  let display = root.findEntity(named: "RFkcSjAtJLGqwDA") as? ModelEntity,
                  let parent = base.parent else {
                log("USDZ 结构不符：找不到底座 / 屏幕组 / 显示面")
                return
            }
            baseGroup = base
            screenGroup = screen
            displayNode = display
            screenBack = root.findEntity(named: "YGumwFJYyjNDAsM")

            // 屏幕和它的背板一起绕铰链转；背板在 RealityKit 的层级里是屏幕组的兄弟。
            parent.addChild(screenPivot)
            let hingeOffset = SIMD3<Float>(-Self.rigHome.x, -Self.rigHome.y, -Self.rigHome.z)
            screen.removeFromParent()
            screen.position = hingeOffset
            screenPivot.addChild(screen)
            if let back = screenBack {
                back.removeFromParent()
                back.position = hingeOffset
                screenPivot.addChild(back)
            }
            screenPivot.addChild(screenAnchor)

            // 拆解：底座向下，屏幕组沿铰链向上/向前，和旧版一致。
            // （apply(apart:) 里做）

            // 需要随配色变的外壳件：圆顶、屏幕背板、脚圈。
            for name in ["SZbxWWDrhdKpHNV", "YGumwFJYyjNDAsM", "nLuFOBqijsErMHq"] {
                guard let e = root.findEntity(named: name) as? ModelEntity,
                      let mats = e.model?.materials else { continue }
                bodyParts.append(BodyPart(entity: e, materials: mats))
            }

            // 两层冲孔网罩：外层跟机身色，内层是孔后的衬里。
            if let url = Bundle.module.url(forResource: "grille-opacity", withExtension: "png"),
               let mask = try? TextureResource.load(
                   contentsOf: url, withName: "grille-opacity",
                   options: .init(semantic: .raw, mipmapsMode: .allocateAndGenerateAll)) {
                grilleMask = mask
            } else {
                log("网罩遮罩缺失：grille-opacity.png")
            }
            for name in ["UQXoGTWKtdzyKWe", "XVYJNqpXsKfyxeD"] {
                guard let e = root.findEntity(named: name) as? ModelEntity,
                      let mats = e.model?.materials else { continue }
                let part = BodyPart(entity: e, materials: mats)
                grilleParts.append(part)
                if name == "XVYJNqpXsKfyxeD" { screenGrillePart = part }
            }
            for name in ["MuiTShOwADSblaI", "abNOzwnQJCCmxBx", "XYBCaNnSjiUiVLG",
                         "hrvrGcFkksrqTSI", "UrfQEzgVYVBUcSJ", "bcOVqgjhplwbkKv",
                         "OcZtYhDfBEBtfeO", "flbFkoPfVvSJBeb", "dKHDPuhaFtUISBz",
                         "tCgJhsEVvDMYgwY", "uKjHAcdgWcDXweZ", "HbOtaaAKzfYczkG",
                         "ChgAKgifeVFuTFO", "VqHunENsfOpXgiN", "lzRnsDzlWFniRdS",
                         "ZLAybMqalONgsGI", "FaPQPfblXqKHgfB", "wLRregyQoxWPJXL",
                         "vpysVCdjxGIfzju", "XTKeTnQSfyVvXZA", "fSuRFdZlyZrdMsV",
                         "rGBGcYiyQwpYdtT", "pcAsQphSQfzGjTz", "NWYWxqlRejAmgQs",
                         "PfAHaXCVHUTzQAm", "JPTNGKSjPowVptr", "uudmqgTXWDqUCES",
                         "bxiioNiAJxmpQhR"] {
                guard let e = root.findEntity(named: name) as? ModelEntity,
                      let mats = e.model?.materials else { continue }
                grilleInnerParts.append(BodyPart(entity: e, materials: mats))
            }
            for name in ["GkdQECEsVboLhOs", "iKNLnLHtbywYoYi"] {
                guard let e = root.findEntity(named: name) as? ModelEntity,
                      let mats = e.model?.materials else { continue }
                grilleBackingParts.append(BodyPart(entity: e, materials: mats))
            }

            // 背面 USB-C：母座沉在原生凹槽底部。
            let port = USBCPortAssembly()
            port.root.position = SIMD3<Float>(0, 1.537, -4.100)
            base.addChild(port.root)
            usbPort = port
            buildAnatomy(base: base, screen: screen)




            // 触控/拖动的机身命中：每个网格零件各自一个碰撞盒（跟着拆解位移走），
            // 取代以前的整机 AABB——那个盒子把底座两侧、屏幕上方的透明区都算成「机身」，
            // 双指滑动在空白处也会转身体（2026-10-22 手势冲突）。
            var collisionParts = 0
            func addCollisions(_ e: Entity) {
                if let m = e as? ModelEntity, m.model != nil, m.isEnabled, !m.name.hasPrefix("anatomy.") {
                    m.generateCollisionShapes(recursive: false); collisionParts += 1
                }
                for c in e.children { addCollisions(c) }
            }
            addCollisions(root)
            hitBody.name = "hitBody"
            if collisionParts == 0 {   // 万一模型结构变了：退回整机盒，至少能点到
                let b = root.visualBounds(relativeTo: nil)
                hitBody.position = b.center
                hitBody.components.set(CollisionComponent(shapes: [.generateBox(size: b.extents)]))
            }
            holder.addChild(hitBody)
            // 生成的內部件另外加：組好時它們都包在外殼裡，不改變原本 87 件的命中；拆開後也點得到
            for m in anatomyGenerated { m.generateCollisionShapes(recursive: false) }
            log("hit test: \(collisionParts) part collision shapes (+\(anatomyGenerated.count) anatomy)")

            // 初始屏幕：先放一块黑，等 PetView 把第一帧脸接进来。
            makeScreenBlack()
            displayLoaded = true
            apply(finish: .starlight)
            log("USDZ loaded (RealityKit)")
        } catch {
            log("USDZ 加载失败：\(error)")
        }
    }

    /// 生成 USDZ 沒有的內部件，再把全部零件分進九層（Anatomy.swift）。
    private func buildAnatomy(base: Entity, screen: Entity) {
        anatomyScreen.name = "anatomy.screen"
        anatomyScreen.position = SIMD3<Float>(0, Float(Self.rigY), 4.28)
        anatomyScreen.orientation = simd_quatf(angle: -Float(Self.tilt), axis: SIMD3<Float>(1, 0, 0))
        screen.addChild(anatomyScreen)
        let f = AnatomyInternals.screenFrame()
        anatomyScreen.addChild(f.root)
        anatomyFrame = f.root
        let b = AnatomyInternals.base()
        for (r, _) in b.radiators { base.addChild(r) }
        base.addChild(b.woofer); base.addChild(b.power)
        anatomyRadiators = b.radiators; anatomyWoofer = b.woofer; anatomyPower = b.power
        for p in f.pieces + b.pieces {
            anatomyParts[ObjectIdentifier(p.entity)] = p.part
            if let m = p.entity as? ModelEntity {
                if !m.name.hasPrefix("anatomy.") { m.name = "anatomy.\(p.part.rawValue)" }
                anatomyGenerated.append(m)
            }
        }
        if let port = usbPort { anatomyParts[ObjectIdentifier(port.root)] = .power }
        buildExplodeMovers()
    }

    /// 這個實體屬於哪一件：自己或祖先在表裡就用它，否則螢幕組歸托盤、底座歸揚聲器模組
    func anatomyPart(of e: Entity) -> AnatomyPart {
        var cur: Entity? = e
        while let c = cur {
            if let p = anatomyParts[ObjectIdentifier(c)] ?? AnatomyPart.usdz[c.name] { return p }
            if c === screenPivot { return .tray }
            if c === baseGroup { return .baseModule }
            cur = c.parent
        }
        return .baseModule
    }

    /// 九層的位移（e=1 時）。螢幕側沿螢幕法線 n 拉開：玻璃最前、托盤往後；底座側：鉸鏈往上、
    /// 輻射器往左右、電源從背面抽出、低音和腳座往下。
    private func buildExplodeMovers() {
        explodeMovers.removeAll()
        guard let screen = screenGroup, let base = baseGroup else { return }
        let n = SIMD3<Float>(0, sinf(Float(Self.tilt)), cosf(Float(Self.tilt)))
        // 鉸鏈上下兩半在拆開後會合：底座那半往上 (0, 4.2, 1.2)，螢幕那半扣掉螢幕組的整體位移
        let hingeBase = SIMD3<Float>(0, 4.2, 1.2)
        let hingeScreen = hingeBase - Self.screenLift
        var seen = Set<ObjectIdentifier>()

        func add(_ e: Entity, _ offset: SIMD3<Float>, _ layer: AnatomyLayer) {
            let key = ObjectIdentifier(e)
            guard !seen.contains(key), e.isEnabled else { return }
            seen.insert(key)
            explodeMovers.append(ExplodeMover(entity: e, origin: e.position, offset: offset, layer: layer))
        }
        func walk(_ e: Entity, _ offset: (AnatomyPart) -> SIMD3<Float>?) {
            if e === anatomyScreen { return }
            if let m = e as? ModelEntity, m.model != nil {
                let part = anatomyPart(of: m)
                if let o = offset(part) { add(e, o, part.layer) }
            }
            for c in e.children { walk(c, offset) }
        }

        walk(screen) { part in
            switch part {
            case .coverGlass: return n * 9.5
            case .display: return n * 6.4
            case .hinge: return hingeScreen
            case .tray: return n * -2.2
            default: return n * 3.0          // 相機等電子框架上的件
            }
        }
        if let frame = anatomyFrame { add(frame, SIMD3<Float>(0, 0, 3.0), .frame) }   // 容器座標的 +z 就是 n
        if let back = screenBack { add(back, n * -2.2, .tray) }

        for child in base.children where child !== usbPort?.root && child !== anatomyPower && child !== anatomyWoofer
            && !anatomyRadiators.contains(where: { $0.0 === child }) {
            walk(child) { part in
                switch part {
                case .hinge: return hingeBase
                case .foot: return SIMD3<Float>(0, -6.0, 0)
                default: return nil          // 圓頂、網罩：底座揚聲器模組，原地不動
                }
            }
        }
        for (r, side) in anatomyRadiators { add(r, SIMD3<Float>(4.6 * side, 0.4, 0), .radiators) }
        let powerOut = SIMD3<Float>(0, -0.8, -3.2)   // 電源從背面抽出來
        if let p = anatomyPower { add(p, powerOut, .baseModule) }
        if let port = usbPort { add(port.root, powerOut, .baseModule) }
        if let w = anatomyWoofer { add(w, SIMD3<Float>(0, -3.6, 0), .woofer) }
    }

    /// 挑零件用的緊貼盒子；第一次用才建（要讀網格頂點）
    private func anatomyPicker() -> AnatomyPicker {
        if let picker { return picker }
        var items: [(entity: ModelEntity, frame: Entity, part: AnatomyPart)] = []
        func walk(_ e: Entity, _ frame: Entity) {
            if let m = e as? ModelEntity, m.model != nil, m.isEnabledInHierarchy {
                items.append((m, frame, anatomyPart(of: m)))
            }
            for c in e.children { walk(c, frame) }
        }
        walk(screenPivot, screenAnchor)
        if let base = baseGroup { walk(base, base) }
        let p = AnatomyPicker(items)
        picker = p
        return p
    }
    /// 射線（世界座標）打到的零件
    func pickAnatomy(origin: SIMD3<Float>, direction: SIMD3<Float>) -> (AnatomyPart, SIMD3<Float>)? {
        anatomyPicker().pick(origin: origin, direction: direction)
    }
    /// 標籤指的位置（世界座標）
    func anatomyAnchor(_ part: AnatomyPart, eye: SIMD3<Float> = SIMD3<Float>(0, 10, 100)) -> SIMD3<Float>? {
        anatomyPicker().anchor(part, eye: eye)
    }
    var selftestPickTargets: Int { anatomyPicker().count }

    private func makeScreenBlack() {
        guard let tex = try? TextureResource.generate(from: Self.blackImage(), withName: "screen",
                                                      options: .init(semantic: .color, mipmapsMode: .none)) else { return }
        screenTexture = tex
        screenMaterial.color.texture = MaterialParameters.Texture(tex)
        displayNode?.model?.materials = [screenMaterial]
    }

    private static func blackImage() -> CGImage {
        makeImage(64, 64) { g in
            g.setFillColor(NSColor.black.cgColor)
            g.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }

    /// 脸的 CGImage。尺寸不变时原地替换，避免每帧新建 GPU 纹理。
    /// 只算錶面貼圖的換新次數（材質、外觀換了不算）：海報補丁用來判斷「只有螢幕內容變了」
    private(set) var screenGeneration = 0
    /// 目前螢幕上那張錶面（直播時是 nil）
    private(set) var lastScreenImage: CGImage?
    func setScreen(_ image: CGImage) {
        guard displayLoaded else { return }
        generation += 1
        screenGeneration += 1
        lastScreenImage = image
        if let tex = screenTexture, tex.width == image.width, tex.height == image.height {
            do {
                try tex.replace(withImage: image, options: .init(semantic: .color, mipmapsMode: .none))
                return
            } catch {
                // 尺寸/格式变化时重建
            }
        }
        guard let tex = try? TextureResource.generate(from: image, withName: "screen",
                                                      options: .init(semantic: .color, mipmapsMode: .none)) else { return }
        screenTexture = tex
        screenMaterial.color.texture = MaterialParameters.Texture(tex)
        displayNode?.model?.materials = [screenMaterial]
    }

    /// 直播帧：MTLTexture 零拷贝包成 TextureResource（不经过 CPU）。
    func setScreen(texture: MTLTexture) {
        guard displayLoaded else { return }
        generation += 1
        lastScreenImage = nil
        let tex = TextureResource.__texture(from: texture)
        screenTexture = tex
        screenMaterial.color.texture = MaterialParameters.Texture(tex)
        displayNode?.model?.materials = [screenMaterial]
    }

    /// 铰链：点头/摇头 + 追人的小幅度俯仰/偏航。
    func setRig(pitch: Float, yaw: Float) {
        // 挂墙：没有铰链，屏幕扶正（抵消 USDZ 自带的后仰）后固定不动
        if wall { screenPivot.orientation = simd_quatf(angle: Float(Self.tilt), axis: SIMD3<Float>(1, 0, 0)); return }
        screenPivot.orientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
            * simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
    }

    /// 挂墙模式：藏起底座（圆顶、网罩、脚圈、USB‑C 都在里面）和铰链，只留屏幕模组，直立正对前方。
    private(set) var wall = false
    func setWall(_ on: Bool) {
        wall = on
        baseGroup?.isEnabled = !on
        for name in ["TlTyQAuZSZnkfBS", "UHiMdHobqyuoBpP"] { usdzRoot?.findEntity(named: name)?.isEnabled = !on }   // 铰链上下两半
        setRig(pitch: 0, yaw: 0)
        generation += 1
    }
    /// 挂墙时显示面中心（世界座标，cm）：绕铰链转回直立后的位置，镜头对准这里
    static var wallScreenCenter: SIMD3<Float> {
        let t = Float(tilt), dy = Float(rigY - hingeY), dz = 4.28 - rigHome.z
        return rigHome + SIMD3<Float>(0, dy * cosf(t) - dz * sinf(t), dy * sinf(t) + dz * cosf(t))
    }

    /// 按下时的 2.5% 缩放和 4.5 秒一次的轻微浮动（都以底座底面为原点）。
    func setIdle(press: CGFloat, bob: CGFloat) {
        holder.scale = SIMD3<Float>(repeating: Float(100 * press))
        holder.position.y = Float(bob)
    }

    /// 整机在底座上转向（见 Aim.swift）：窗口位置倾斜＋DockKit 式跟随。值没变就不写 transform。
    private(set) var aimYaw: Float = .nan
    func setAim(yaw: Float) {
        guard aimYaw.isNaN || abs(yaw - aimYaw) > 0.0002 else { return }
        aimYaw = yaw
        holder.orientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
    }

    /// 拆开进度 t（0 组好 … 1 拆开）。
    /// 九層錯開：外層先動、組回時內層先回（AnatomyLayer.progress）。
    func apply(_ t: CGFloat) {
        screenPivot.position = Self.rigHome + Self.screenLift * Float(AnatomyLayer.liftProgress(t))
        for m in explodeMovers { m.entity.position = m.origin + m.offset * Float(m.layer.progress(t)) }
    }

    /// 自检用：当前圆顶材质的金属度（星光/银＝1，G4 白＝0）。
    var selftestMetalness: Double {
        guard let p = bodyParts.first?.entity.model?.materials.first as? PhysicallyBasedMaterial else { return -1 }
        return Double(p.metallic.scale)
    }

    /// 屏幕下沿是一块朝下的平面，和周围曲面的受光不同：
    /// G4 白塑料偏暗，补一点同色环境光；铝色先压暗底色，再用同色微补光收掉接缝处的阴影。
    private static func screenGrille(_ shell: PhysicallyBasedMaterial, for f: Finish) -> PhysicallyBasedMaterial {
        var m = shell
        if f == .g4 {
            m.emissiveColor.__color = NSColor(calibratedWhite: 0.10, alpha: 1).cgColor
        } else if let hex = f.aluminum,
                  let c = srgb(hex).usingColorSpace(.sRGB) {
            let k: CGFloat = 0.95
            m.baseColor.tint = NSColor(srgbRed: c.redComponent * k, green: c.greenComponent * k,
                                       blue: c.blueComponent * k, alpha: 1)
            let e: CGFloat = 0.04
            m.emissiveColor.__color = NSColor(srgbRed: c.redComponent * e, green: c.greenComponent * e,
                                              blue: c.blueComponent * e, alpha: 1).cgColor
        }
        return m
    }

    /// 外观：星光色完全用 USDZ 原材质；其余颜色改外壳 baseColor，保留各件原有金属度/粗糙度/法线。
    /// 网罩用原生 opacity 遮罩切成同色冲孔板，孔后的暖色衬里同时换成中性深色。
    /// G4 白是致敬款：白色亮面塑料。
    func apply(finish f: Finish) {
        finish = f
        generation += 1
        usbPort?.apply(finish: f)
        for part in bodyParts {
            if f == .starlight {
                part.entity.model?.materials = part.materials
                continue
            }
            var mats = part.materials
            for i in mats.indices {
                guard var p = mats[i] as? PhysicallyBasedMaterial else { continue }
                if f == .g4 {
                    p.baseColor.tint = NSColor(calibratedWhite: 0.93, alpha: 1)
                    p.metallic.scale = 0
                    p.roughness.scale = 0.34
                    p.normal.texture = nil
                    p.ambientOcclusion.texture = nil
                    p.clearcoat.scale = 1.0
                    p.clearcoatRoughness.scale = 0.04
                } else if let hex = f.aluminum {
                    p.baseColor.tint = srgb(hex)
                }
                mats[i] = p
            }
            part.entity.model?.materials = mats
        }

        guard f != .starlight else {
            for part in grilleParts { part.entity.model?.materials = part.materials }
            for part in grilleInnerParts { part.entity.model?.materials = part.materials }
            for part in grilleBackingParts { part.entity.model?.materials = part.materials }
            return
        }
        guard let mask = grilleMask else { return }
        let maskTexture = MaterialParameters.Texture(mask)
        let opacity = PhysicallyBasedMaterial.Opacity(scale: 1, texture: maskTexture)

        // 外层：机身的同色金属/塑料，孔洞仍用原生遮罩切出。
        var shell = PhysicallyBasedMaterial()
        if f == .g4 {
            shell.baseColor.tint = NSColor(calibratedWhite: 0.93, alpha: 1)
            shell.metallic.scale = 0
            shell.roughness.scale = 0.34
            shell.clearcoat.scale = 1.0
            shell.clearcoatRoughness.scale = 0.04
        } else if let hex = f.aluminum {
            shell.baseColor.tint = srgb(hex)
            shell.metallic.scale = f == .gray ? 0.75 : 1
            shell.roughness.scale = f == .gray ? 0.78 : 0.70
        } else {
            return
        }
        shell.blending = .transparent(opacity: opacity)
        shell.opacityThreshold = 0.5
        for part in grilleParts {
            if let sg = screenGrillePart, part.entity === sg.entity {
                part.entity.model?.materials = [Self.screenGrille(shell, for: f)]
            } else {
                part.entity.model?.materials = [shell]
            }
        }

        // 内层：孔后的衬里。星光色是暖棕，深色机身下改成中性深灰，避免孔里透出棕色。
        var lining = PhysicallyBasedMaterial()
        lining.baseColor.tint = NSColor(calibratedWhite: 0.04, alpha: 1)
        lining.metallic.scale = 0
        lining.roughness.scale = 1.0
        lining.blending = .transparent(opacity: opacity)
        lining.opacityThreshold = 0.5
        for part in grilleInnerParts { part.entity.model?.materials = [lining] }

        // 再后面是实心衬底：不改的话，孔里会透出 USDZ 的暖灰色，深色机身下像一圈铜色。
        var backing = PhysicallyBasedMaterial()
        backing.baseColor.tint = NSColor(calibratedWhite: 0.055, alpha: 1)
        backing.metallic.scale = 0
        backing.roughness.scale = 1.0
        for part in grilleBackingParts { part.entity.model?.materials = [backing] }
    }
}


/// 四点单应变换（src -> dst），返回 8 个自由度的 3x3 矩阵（h8 固定为 1）。
func homography(from src: [CGPoint], to dst: [CGPoint]) -> [Double]? {
    guard src.count == 4, dst.count == 4 else { return nil }
    var a = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
    for i in 0..<4 {
        let x = Double(src[i].x), y = Double(src[i].y)
        let u = Double(dst[i].x), v = Double(dst[i].y)
        a[i * 2] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
        a[i * 2 + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
    }
    for col in 0..<8 {
        var pivot = col
        for r in col..<8 where abs(a[r][col]) > abs(a[pivot][col]) { pivot = r }
        guard abs(a[pivot][col]) > 1e-12 else { return nil }
        if pivot != col { a.swapAt(pivot, col) }
        let pv = a[col][col]
        for j in col...8 { a[col][j] /= pv }
        for r in 0..<8 where r != col {
            let f = a[r][col]
            if abs(f) > 1e-15 { for j in col...8 { a[r][j] -= f * a[col][j] } }
        }
    }
    return (0..<8).map { a[$0][8] } + [1]
}
func applyHomography(_ h: [Double], _ p: CGPoint) -> CGPoint {
    let x = Double(p.x), y = Double(p.y)
    let w = h[6] * x + h[7] * y + h[8]
    guard abs(w) > 1e-12 else { return CGPoint(x: -1, y: -1) }
    return CGPoint(x: (h[0] * x + h[1] * y + h[2]) / w,
                   y: (h[3] * x + h[4] * y + h[5]) / w)
}

func clamp01(_ x: CGFloat) -> CGFloat { max(0, min(1, x)) }
func ease(_ x: CGFloat) -> CGFloat { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }

/// 方屏 uv（0..1，左上原点）→ 画面 0..1。画面等比放进方屏，留黑的地方回 nil。
func screenToVideo(u: Double, v: Double, videoW: Double, videoH: Double) -> (Double, Double)? {
    guard videoW > 0, videoH > 0 else { return nil }
    var x = u, y = v
    if videoW >= videoH {
        let h = videoH / videoW; y = (v - (1 - h) / 2) / h
    } else {
        let w = videoW / videoH; x = (u - (1 - w) / 2) / w
    }
    guard (0...1).contains(x), (0...1).contains(y) else { return nil }
    return (x, y)
}

struct AxisLock {
    enum Axis { case pending, horizontal, vertical }
    private(set) var axis: Axis = .pending

    mutating func pass(dx: CGFloat, dy: CGFloat, threshold: CGFloat = 3) -> (dx: CGFloat, dy: CGFloat) {
        if axis == .pending {
            guard abs(dx) > threshold || abs(dy) > threshold else { return (0, 0) }
            axis = abs(dx) >= abs(dy) ? .horizontal : .vertical
        }
        switch axis {
        case .horizontal: return (dx, 0)
        case .vertical: return (0, dy)
        case .pending: return (0, 0)
        }
    }
    mutating func reset() { axis = .pending }
}

/// 视频健康（照 MacPlay videoHealth 的规则）：收到≥3 帧却 2.5 s 没解出一帧 → 重建解码并要关键帧；
/// 重建后每 0.9 s 最多要一次关键帧，8 s 仍没出帧再重建；60 s 内最多重建 3 次、总共 6 次，超过就放弃（断开重连）。
/// 没有新帧进来（静止画面）不算停滞。所有调用都在主线程。
final class VideoHealth {
    enum Action: Equatable { case none, requestKeyframe, rebuild, giveUp }
    private(set) var received = 0, decoded = 0, totalRebuilds = 0
    private var receivedAtLastDecode = 0
    private var lastDecodeAt: Double
    private var lastReceiveAt = -1e9
    private var lastKeyframeAsk = -1e9
    private var lastRebuildAt = -1e9
    private var rebuildTimes: [Double] = []
    private var recovering = false

    init(now: Double) { lastDecodeAt = now }
    func reset(now: Double) {
        received = 0; decoded = 0; receivedAtLastDecode = 0; lastDecodeAt = now
        recovering = false; lastKeyframeAsk = -1e9
        // 新的一次直播是新的恢复预算：否则一次坏网络用完整 6 次后，后续每次重连都会立刻放弃
        rebuildTimes.removeAll(); totalRebuilds = 0
    }
    func frameReceived(now: Double) { received += 1; lastReceiveAt = now }
    func frameDecoded(now: Double) {
        decoded += 1; receivedAtLastDecode = received; lastDecodeAt = now; recovering = false
    }
    /// 解码报错：不等 2.5 s，直接按停滞处理
    func decodeError(now: Double) -> Action { (!recovering || now - lastRebuildAt > 8) ? rebuild(now) : keyframeOrNone(now) }

    func check(now: Double) -> Action {
        // 还在进帧（最近 2.5 s 有）才算停滞；流停了＝静止画面
        guard received - receivedAtLastDecode >= 3, now - lastDecodeAt > 2.5, now - lastReceiveAt < 2.5 else { return .none }
        if !recovering || now - lastRebuildAt > 8 { return rebuild(now) }
        return keyframeOrNone(now)
    }
    private func keyframeOrNone(_ now: Double) -> Action {
        guard now - lastKeyframeAsk >= 0.9 else { return .none }
        lastKeyframeAsk = now; return .requestKeyframe
    }
    private func rebuild(_ now: Double) -> Action {
        rebuildTimes = rebuildTimes.filter { now - $0 < 60 }
        guard rebuildTimes.count < 3, totalRebuilds < 6 else { return .giveUp }
        rebuildTimes.append(now); totalRebuilds += 1
        recovering = true; lastRebuildAt = now; lastKeyframeAsk = now
        return .rebuild
    }
}

final class VideoDecoder {
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private let queue = DispatchQueue(label: "pet.decode")
    /// `busy` 在解碼回呼執行緒上讀、在主執行緒上清；`size` 在解碼佇列上寫、在主執行緒上讀。
    /// 兩者都不能裸露。
    private let stateLock = NSLock()
    private var busy = false
    private var _size = CGSize.zero
    var size: CGSize { stateLock.lock(); defer { stateLock.unlock() }; return _size }
    var onImage: ((CGImage) -> Void)?
    /// 零拷贝路：VT 解到 IOSurface 像素缓冲，CVMetalTextureCache 直接包成 MTLTexture（不経 CPU 拷貝）
    var onTexture: ((MTLTexture, Int, Int) -> Void)?
    var onDecoded: (() -> Void)?        // 主线程
    var onDecodeError: (() -> Void)?    // 主线程
    var frames = 0
    private var lastConfig: (UInt8, Data, Int, Int)?
    private var texCache: CVMetalTextureCache?
    private var framesSinceFlush = 0
    private let metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()
    private var held: CVMetalTexture?   // 保持映射到下一帧，渲染期间缓冲不被回收

    /// 贴图路一次只压一帧：主执行绪还没消费完就丢这一帧（P 帧照样解码，不会花屏）
    private func claimPresent() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        if busy { return false }
        busy = true
        return true
    }
    private func releasePresent() { stateLock.lock(); busy = false; stateLock.unlock() }

    /// 用上一份 config 重建解码会话（停滞恢复用）。lastConfig 只在解碼佇列上读写。
    func rebuild() {
        queue.async { [self] in
            guard let c = lastConfig else { return }
            configure(codec: c.0, record: c.1, width: c.2, height: c.3)
        }
    }

    func configure(codec: UInt8, record: Data, width: Int, height: Int) {
        queue.async { [self] in
            lastConfig = (codec, record, width, height)
            var fmt: CMVideoFormatDescription?
            var st: OSStatus = noErr
            if codec == 2 {
                let sets = Self.hevcParameterSets(record)
                guard sets.count >= 3 else { log("HEVC 參數集不足（\(sets.count)）"); return }
                st = sets[0].withUnsafeBufferPointer { a in
                    sets[1].withUnsafeBufferPointer { b in
                        sets[2].withUnsafeBufferPointer { c in
                            let p = [a.baseAddress!, b.baseAddress!, c.baseAddress!]
                            let sz = [sets[0].count, sets[1].count, sets[2].count]
                            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                allocator: nil, parameterSetCount: 3, parameterSetPointers: p,
                                parameterSetSizes: sz, nalUnitHeaderLength: 4, extensions: nil,
                                formatDescriptionOut: &fmt)
                        }
                    }
                }
                if st != noErr { log("hvcC 解析失敗 \(st)"); return }
            } else {
                st = CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264,
                    width: Int32(width), height: Int32(height),
                    extensions: [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["avcC": record]] as CFDictionary,
                    formatDescriptionOut: &fmt)
            }
            guard st == noErr, let fmt else { log("解碼器設定失敗（codec \(codec)）\(st)"); return }
            if let s = session { VTDecompressionSessionInvalidate(s); session = nil }
            format = fmt
            stateLock.lock(); _size = CGSize(width: width, height: height); stateLock.unlock()
            var s: VTDecompressionSession?
            // Metal 兼容＋IOSurface 背襯：VideoToolbox 解出來的緩衝能直接給 Metal 取用（零拷貝前提）
            let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                         kCVPixelBufferMetalCompatibilityKey: true,
                         kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
            let cst = VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: nil,
                                                   imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &s)
            // 失敗時 session 是 nil，之後每幀都會被靜默丟掉；至少要留一行痕跡。
            guard cst == noErr, let created = s else {
                log("解碼會話建立失敗（codec \(codec)）\(cst)")
                return
            }
            session = created
        }
    }

    /// `from` 允许直接传整条 wire 消息（前 11 字节是头），省一次 Array 切片拷贝。
    func decode(annexB: [UInt8], from offset: Int = 0) {
        queue.async { [self] in
            guard let format, let session, let block = Self.avcc(annexB, from: offset) else { return }
            var sample: CMSampleBuffer?
            var size = block.dataLength
            guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
                sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return }
            // 解码一定要每帧都做（P 帧依赖前一帧）；转贴图在忙时跳过
            VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] st, _, img, _, _ in
                guard let self else { return }
                guard st == noErr, let img else {
                    if st != noErr { DispatchQueue.main.async { self.onDecodeError?() } }
                    return
                }
                DispatchQueue.main.async { self.onDecoded?() }
                self.present(img)
            }
        }
    }

    /// 接收器自家參數集包：count u8 + 每個 len u16 + NAL
    private static func hevcParameterSets(_ blob: Data) -> [[UInt8]] {
        let b = [UInt8](blob)
        guard let count = b.first else { return [] }
        var out: [[UInt8]] = []; var i = 1
        for _ in 0..<Int(count) {
            guard i + 2 <= b.count else { break }
            let len = Int(b[i]) << 8 | Int(b[i + 1]); i += 2
            guard len > 0, i + len <= b.count else { break }
            out.append(Array(b[i..<(i + len)])); i += len
        }
        return out
    }

    private func present(_ img: CVImageBuffer) {
        stateLock.lock(); frames += 1; framesSinceFlush += 1; stateLock.unlock()
        guard claimPresent() else { return }
        // 定期清掉纹理缓存里没人用的条目（分辨率切换、长时间直播后不再膨胀）。
        if framesSinceFlush >= 120, let texCache {
            CVMetalTextureCacheFlush(texCache, 0)
            stateLock.lock(); framesSinceFlush = 0; stateLock.unlock()
        }
        // 快路：直接包成 MTLTexture 交給 RealityKit 採樣，每幀不碰像素、不建 CGImage（實測 0.01 ms vs 2.8-5.4 ms）
        // 只限方形畫面：非方來源走 CI 合成方圖的慢路
        let pw = CVPixelBufferGetWidth(img), ph = CVPixelBufferGetHeight(img)
        let isSquare = abs(pw - ph) <= max(4, Int(Double(max(pw, ph)) * 0.01))
        if onTexture != nil, isSquare {
            if texCache == nil, let dev = metalDevice {
                CVMetalTextureCacheCreate(nil, nil, dev, nil, &texCache)
            }
            let w = pw, h = ph
            var cv: CVMetalTexture?
            if let texCache,
               // 一定要 sRGB：解碼器交出來的是 gamma 編碼的 BGRA，用 .bgra8Unorm 會被當線性
               // 再輸出，中間調整體提亮（128→0.74），畫面看起來灰蒙蒙。
               CVMetalTextureCacheCreateTextureFromImage(nil, texCache, img, nil, .bgra8Unorm_srgb, w, h, 0, &cv) == kCVReturnSuccess,
               let cv, let tex = CVMetalTextureGetTexture(cv) {
                DispatchQueue.main.async { [weak self] in
                    self?.releasePresent()
                    self?.held = cv          // 留到下一幀；被替換時緩衝才回收
                    self?.onTexture?(tex, w, h)
                }
                return
            }
        }
        // 慢路（像素緩衝不支援 Metal 時）：CIImage 合成方圖再轉 CGImage
        let src = CIImage(cvImageBuffer: img)
        let w = src.extent.width, h = src.extent.height, side = max(w, h)
        let placed = src.transformed(by: CGAffineTransform(translationX: (side - w) / 2, y: (side - h) / 2))
        let square = placed.composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: side, height: side)))
        let cg = ci.createCGImage(square, from: square.extent)
        DispatchQueue.main.async { [weak self] in
            self?.releasePresent()
            if let cg { self?.onImage?(cg) }
        }
    }

    func reset() { queue.async { [self] in
        if let s = session { VTDecompressionSessionInvalidate(s) }; session = nil; format = nil
    } }

    /// Annex B → AVCC（4 字节大端长度前缀）。一次预分配、一遍走完：
    /// 原来是先切出 NAL 切片数组、再逐段 `+=`，帧越大越多余拷贝。
    static func avcc(_ a: [UInt8], from offset: Int = 0) -> CMBlockBuffer? {
        guard a.count > offset else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(a.count - offset)
        var nalStart = -1
        func flush(_ end: Int) {
            guard nalStart >= 0, end > nalStart else { return }
            let len = UInt32(end - nalStart)
            out.append(UInt8(len >> 24 & 0xff)); out.append(UInt8(len >> 16 & 0xff))
            out.append(UInt8(len >> 8 & 0xff)); out.append(UInt8(len & 0xff))
            out.append(contentsOf: a[nalStart..<end])
        }
        var i = offset
        while i + 2 < a.count {
            guard a[i] == 0, a[i + 1] == 0 else { i += 1; continue }
            var scLen = 0
            if a[i + 2] == 1 { scLen = 3 }
            else if i + 3 < a.count, a[i + 2] == 0, a[i + 3] == 1 { scLen = 4 }
            guard scLen > 0 else { i += 1; continue }
            flush(i)
            i += scLen
            nalStart = i
        }
        flush(a.count)
        guard !out.isEmpty else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: out.count,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: out.count, flags: 0,
            blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return nil }
        _ = out.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: out.count) }
        return block
    }
}

// MARK: - 接收器 client（wire 解析，和 WS2CarPlayReceiverWire 对齐）

/// 每條 WS 的「首幀／結束只報一次」標記。接收器換手機時同一條 WS 上會送
/// session ended → started，之後的第一幀要再報一次 live，桌寵才會從「正在連線」切回畫面。
/// 純值型別，不帶鎖；ReceiverClient 在自己的鎖裡用它，selftest 直接測。
struct FirstFrameLatch {
    private(set) var gotFrame = false
    private(set) var ended = false
    mutating func open() { gotFrame = false; ended = false }
    /// 首幀只報一次；返回 true 表示這次是第一次。
    mutating func takeFirstFrame() -> Bool {
        if gotFrame { return false }
        gotFrame = true; return true
    }
    /// 結束只報一次；返回 true 表示這次是第一次。
    mutating func markEnded() -> Bool {
        if ended { return false }
        ended = true; gotFrame = false; return true
    }
    mutating func resetFirstFrame() { gotFrame = false }
    /// 接收器的會話邊界（換手機／手機自己 TEARDOWN）：之後的第一幀要重新報 live。
    static func isSessionBoundary(_ s: String) -> Bool {
        s.contains("\"type\":\"session\"") && (s.contains("\"state\":\"ended\"") || s.contains("\"state\":\"started\""))
    }
    /// 依序餵入文字與幀（nil 代表一幀），回傳每一幀是否觸發 live。selftest 用。
    static func replay(_ events: [String?]) -> [Bool] {
        var l = FirstFrameLatch(); l.open()
        return events.compactMap { e in
            if let s = e { if isSessionBoundary(s) { l.resetFirstFrame() }; return nil }
            return l.takeFirstFrame()
        }
    }
}

final class ReceiverClient: NSObject, URLSessionWebSocketDelegate {
    private let endpoint: URL
    private let decoder: VideoDecoder
    var onLive: ((Bool) -> Void)?
    var onText: ((String) -> Void)?   // 接收器的狀態文字（例如未配對）
    var onOpen: (() -> Void)?         // WS 真的开了：补发掉线前排队的切换命令
    var onFrameReceived: (() -> Void)?   // 主线程
    /// 主动换线时旧连接的回调必须作废；否则旧 socket 的迟到结束会把新会话打回“重连中”。
    /// task / session / 首帧标记都收在这把锁下：写入在 main，读取在 URLSession 的回调线程。
    private let stateLock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var latch = FirstFrameLatch()
    private var closedByUs = false

    init?(endpoint: String, decoder: VideoDecoder) {
        guard let url = URL(string: endpoint), ["ws", "wss"].contains(url.scheme?.lowercased()) else { return nil }
        self.endpoint = url; self.decoder = decoder
    }
    private func isClosedByUs() -> Bool { stateLock.lock(); defer { stateLock.unlock() }; return closedByUs }
    private func currentTask() -> URLSessionWebSocketTask? {
        stateLock.lock(); defer { stateLock.unlock() }; return task
    }
    /// 首帧只报一次；返回 true 表示这次是第一次。
    private func takeFirstFrame() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return latch.takeFirstFrame()
    }
    /// 结束只报一次；返回 true 表示这次是第一次。
    private func markEnded() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return latch.markEnded()
    }
    /// 同一條 WS 上接收器換了會話：下一幀再報一次 onLive(true)。
    func resetFirstFrame() {
        stateLock.lock(); latch.resetFirstFrame(); stateLock.unlock()
    }
    /// URLSession 會強引用它的 delegate（就是本物件），沒有 invalidate 就永遠不釋放：
    /// 斷線重連每建一條 WS 就漏一個 session 加一個 client。
    /// graceful=true 時讓已取消的 task 收完再失效，保留 close frame 的機會。
    private func releaseSession(graceful: Bool = false) {
        stateLock.lock(); let s = session; session = nil; stateLock.unlock()
        if graceful { s?.finishTasksAndInvalidate() } else { s?.invalidateAndCancel() }
    }

    func open() {
        releaseSession()   // 防禦：同一個物件重開時先收掉上一條
        stateLock.lock(); closedByUs = false; latch.open(); stateLock.unlock()
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let t = s.webSocketTask(with: endpoint)
        t.maximumMessageSize = 8 * 1024 * 1024   // 專輯封面 base64 可能超過預設 1 MB
        stateLock.lock(); session = s; task = t; stateLock.unlock()
        t.resume()
        receive()
    }
    func close() {
        stateLock.lock(); closedByUs = true; let t = task; task = nil; stateLock.unlock()
        t?.cancel(with: .goingAway, reason: nil)
        releaseSession(graceful: true)
    }

    func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol p: String?) {
        guard !isClosedByUs() else { return }
        onOpen?()
        send(#"{"type":"keyframe"}"#)
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError e: Error?) { end() }
    /// 连接结束只报一次（完成回调和收包失败都会走到这里）
    private func end() {
        guard !isClosedByUs() else { releaseSession(); return }
        releaseSession()
        guard markEnded() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isClosedByUs() else { return }
            self.onLive?(false)
        }
    }
    func requestKeyframe() { send(#"{"type":"keyframe"}"#) }
    /// 真正断开：先請接收器 TEARDOWN 手機會話，再關本地 WS。接收器收到後會結束並退出。
    func requestTeardown() {
        guard let t = currentTask() else { close(); return }
        t.send(.string(#"{"type":"stop"}"#)) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.close() }
        }
    }
    private func send(_ s: String) { currentTask()?.send(.string(s)) { _ in } }
    /// 送一則現成的 JSON 給接收器（CarPlay 影片的狀態回報用）
    func sendRaw(_ s: String) { send(s) }
    private func receive() {
        currentTask()?.receive { [weak self] r in
            guard let self, !self.isClosedByUs() else { return }
            if case .success(let m) = r {
                if case .data(let d) = m { self.handle([UInt8](d)) }
                if case .string(let s) = m {
                    // 在收包線程上就重置：保證排在這則訊息之後的幀一定看得到
                    if FirstFrameLatch.isSessionBoundary(s) { self.resetFirstFrame() }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.isClosedByUs() else { return }
                        self.onText?(s)
                    }
                }
                self.receive()
            } else {
                self.end()
            }
        }
    }
    private func u32(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o+1]) << 8 | Int(b[o+2]) << 16 | Int(b[o+3]) << 24 }
    private func handle(_ b: [UInt8]) {
        guard !isClosedByUs(), b.count >= 2 else { return }
        if b[0] == 1, b.count >= 12, b[2] == 1 || b[2] == 2 {
            let w = u32(b, 3), h = u32(b, 7)
            log("VIDEO_CONFIG \(w)x\(h) codec=\(b[2] == 2 ? "HEVC" : "H.264")")
            decoder.configure(codec: b[2], record: Data(b[11...]), width: w, height: h)
        } else if b[0] == 2, b.count >= 11 {
            decoder.decode(annexB: b, from: 11)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isClosedByUs() else { return }
                self.onFrameReceived?()
            }
            if takeFirstFrame() {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isClosedByUs() else { return }
                    self.onLive?(true)
                }
            }
        }
    }
    func sendTouch(x: Double, y: Double, down: Bool) {
        send(#"{"type":"touch","contacts":[{"id":0,"x":\#(String(format: "%.5f", x)),"y":\#(String(format: "%.5f", y)),"down":\#(down ? "true" : "false")}]}"#)
    }
    func sendMedia(_ command: String) {
        send(#"{"type":"media","command":"\#(command)"}"#)
    }
    /// 叫手机 Siri（接收器转成 CarPlay 的 requestSiri 事件）
    func sendSiri() { send(#"{"type":"siri"}"#) }
    /// F5 按住說話：按下送 down、放開送 up（接收器轉成 requestSiri siriAction 2／3）
    func sendSiri(down: Bool) { send(down ? #"{"type":"siri","action":"down"}"# : #"{"type":"siri","action":"up"}"#) }
    /// 來電卡的按鍵（接收器轉成 CarPlay 電話 HID）
    func sendTelephony(_ action: PhoneCallAction) { send(#"{"type":"telephony","command":"\#(action.rawValue)"}"#) }
    func sendUsePhone(address: String) {
        let d: [String: Any] = ["type": "usePhone", "address": address]
        if let data = try? JSONSerialization.data(withJSONObject: d), let text = String(data: data, encoding: .utf8) {
            send(text)
        }
    }
    func sendPairNewPhone() {
        send(#"{"type":"pairNewPhone"}"#)
    }
    func sendPassphrase(_ value: String) {
        let d: [String: Any] = ["type": "setPassphrase", "value": value]
        if let data = try? JSONSerialization.data(withJSONObject: d), let text = String(data: data, encoding: .utf8) {
            send(text)
        }
    }
    func sendWiFi(ssid: String, passphrase: String) {
        let d: [String: Any] = ["type": "setWiFi", "ssid": ssid, "passphrase": passphrase]
        if let data = try? JSONSerialization.data(withJSONObject: d), let text = String(data: data, encoding: .utf8) {
            send(text)
        }
    }
    func sendForgetPhone(address: String) {
        let d: [String: Any] = ["type": "forgetPhone", "address": address]
        if let data = try? JSONSerialization.data(withJSONObject: d), let text = String(data: data, encoding: .utf8) {
            send(text)
        }
    }
    func sendRestorePhones() {
        send(#"{"type":"restorePhones"}"#)
    }
    /// 只送 Wi-Fi 名稱（自動讀到的）：接收器保留原本的密碼；不寫 wireless.json
    func sendSSID(_ ssid: String) {
        if let data = try? JSONSerialization.data(withJSONObject: ["type": "setWiFi", "ssid": ssid]),
           let text = String(data: data, encoding: .utf8) { send(text) }
    }
    /// 「拷貝診斷報告」：接收器回 {"type":"diagnostics","report":…}（只有次數、秒數、狀態）
    func requestDiagnostics() { send(#"{"type":"diagnostics"}"#) }
    /// 告诉 receiver 桌宠现在是在前台看引导，还是只在后台等画面。
    /// 后台挂接时 receiver 不要为配对自己弹系统设置。
    func sendEngaged(_ engaged: Bool) {
        send(engaged ? #"{"type":"foreground"}"# : #"{"type":"background"}"#)
    }
    func sendSeek(positionMs: UInt32, trackId: String?) {
        var d: [String: Any] = ["type": "seek", "positionMs": Int(positionMs)]
        if let trackId { d["trackId"] = trackId }
        if let data = try? JSONSerialization.data(withJSONObject: d), let text = String(data: data, encoding: .utf8) {
            send(text)
        }
    }
}

// MARK: - 3D 视图：转动、拆开、缩放、触控

/// 主循環的時鐘：60 Hz（手勢、直播、彈簧）用 NSView 的 display link（跟螢幕刷新同步，動畫不抖）；
/// 低幀率或視窗不在任何螢幕上（快照放在螢幕外）時退回 Timer，低幀率允許系統合併喚醒。
final class LoopClock: NSObject {
    private var timer: Timer?
    private var link: CADisplayLink?
    private let tick: () -> Void
    init(view: NSView, hz: Int, tick: @escaping () -> Void) {
        self.tick = tick
        super.init()
        if hz >= 60, view.window?.screen != nil {
            let l = view.displayLink(target: self, selector: #selector(fire(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: Float(hz) / 2, maximum: Float(hz), preferred: Float(hz))
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            let t = Timer(timeInterval: 1.0 / Double(max(1, hz)), repeats: true) { [weak self] _ in self?.tick() }
            if hz <= 30 { t.tolerance = min(0.05, 0.25 / Double(max(1, hz))) }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }
    @objc private func fire(_ l: CADisplayLink) { tick() }
    func invalidate() { timer?.invalidate(); timer = nil; link?.invalidate(); link = nil }
}

/// 闲置海报层：盖在 ARView 上的最后一帧；点击/靠近时让位给实时渲染。
/// 海報層：直接把凍結幀的 CGImage 當 layer contents（走 Core Animation 的 GPU 合成與色彩匹配，和 CAMetalLayer 同一條路）。
private final class PosterImageView: NSView {
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func show(_ cg: CGImage, scale: CGFloat) {
        guard let l = layer else { return }
        l.contentsScale = scale
        l.contentsGravity = .resize
        // 縮放視窗時海報會被拉伸：用線性取樣，別出鋸齒和馬賽克
        l.magnificationFilter = .linear
        l.minificationFilter = .trilinear
        l.contents = cg
    }
    func clear() { layer?.contents = nil }
}

final class PetView: NSView {
    let model = HomeViewModel()
    let face = Face()
    let mood = Mood(now: CACurrentMediaTime())
    /// --face 指定时锁定这张脸（快照对照用），不跟心情走
    private var lockedFace: Expression?
    let decoder = VideoDecoder()
    /// RealityKit 渲染视图。事件全部由外层 PetView 处理，ARView 不接触鼠标。
    let render = ARView(frame: .zero)
    private var cameraEntity: Entity!
    private var bodyAnchor: AnchorEntity!
    private var backLight: DirectionalLight!
    private var roomKey: DirectionalLight!
    private var roomEnv: RoomEnvironment?
    /// 房间光线开关（AppDelegate 设；摄像头暂停条件要用）
    var roomLightEnabled = false
    private(set) var showingVideo = false
    /// CarPlay 影片（停車時播影片）：播著的時候螢幕給它，CarPlay 畫面讓位（CarVideo.swift）
    let carVideo = CarVideoPlayer()
    var onTouch: ((Double, Double, Bool) -> Void)?
    var onToggleLive: (() -> Void)?
    var onCancelConnect: (() -> Void)?   // 菜单「取消连线」
    /// 重按（Force Touch）＝进入 CarPlay；AppDelegate 负责拉起 receiver 并连接
    var onForceEnter: (() -> Void)?
    /// 右键「使用 iPhone」/「配对新 iPhone…」：AppDelegate 负责保存并通知 receiver
    var onSelectPhone: ((String) -> Void)?
    var onPairNewPhone: (() -> Void)?
    var onSetWiFi: ((String, String) -> Void)?
    var onForgetPhone: ((String) -> Void)?
    var onRestorePhones: (() -> Void)?
    var onCopyDiagnostics: (() -> Void)?   // 右鍵 › iPhone › 拷貝診斷報告：AppDelegate 向接收器要現場
    var onVideoState: ((Bool) -> Void)?   // 直播开始/结束：AppDelegate 据此启停健康检查与统计
    private var forceStage = 0

    // 稿里的弹簧：拆开 k=16，镜头 k=42，都是临界阻尼
    private var apartTarget: CGFloat = 0, apartT: CGFloat = 0, apartV: CGFloat = 0
    private var yaw: CGFloat = 0.52, pitch: CGFloat = 0.26, vy: CGFloat = 0, vp: CGFloat = 0
    private var ty: CGFloat = 0.52, tp: CGFloat = 0.26
    private var lastStep = CACurrentMediaTime()
    private(set) var stepFrames = 0
    func resetStepCount() { stepFrames = 0 }
    // lastNear 在 init 里设成「刚开始」；见 targetHz 的远距省电
    private var timer: LoopClock?
    /// 闲置 90 秒后把 ARView 换成静态海报：RealityKit 的每帧固定开销是待机最大单项。
    /// 海报每 2 秒重新拍一张，时间/眨眼不会完全停；鼠标靠近或任何点击立刻恢复实时渲染。
    private let poster = PosterImageView()
    private var posterActive = false
    private var posterTimer: Timer?

    // MARK: 按需 3D（ARView 只在畫面會變的那幾幀掛在視窗裡）
    /// Darwin 27 實測（docs/performance.md「按需 3D」）：`__preferredFrameRate`、`isHidden`、甚至從未掛進層級的
    /// ARView 都照樣每秒 60 次場景更新（約 18% CPU）；只有「掛進視窗後 removeFromSuperview」會讓它歸零，
    /// 而卸下期間 `snapshot` 不會完成，所以沒有真正的「按需出一幀」。做法：場景一變就掛回去（海報蓋著，
    /// 等第 3 次 SceneEvents.Update 確定第一幀已上屏才收掉），靜止超過 stillDelay 就把上屏那幀凍結成海報、卸下。
    /// HOMEPLAY_RENDER_MODE=always 退回常駐渲染（量測對照用）。
    private let onDemand3D = ProcessInfo.processInfo.environment["HOMEPLAY_RENDER_MODE"] != "always"
    private var attached3D = true
    private var updates3D = 0                 // 這次掛上後收到的 SceneEvents.Update 次數
    private(set) var frames3D = 0             // 統計：RealityKit 實際出的幀（bench 用）
    private(set) var cycles3D = 0             // 統計：卸下次數（bench 用）
    private var lastSceneChange = CACurrentMediaTime()
    private var detachShotAt: Double?         // 正在為卸下等凍結幀（開始時間）；中途場景再變就取消
    private var pendingSnapshots: [(CGImage?) -> Void] = []   // 卸下期間要求的快照，掛回去出幀後再拍
    private var snapshotsInFlight = 0
    /// 海報補丁：卸下時記下凍結幀、當時的錶面與螢幕四角；之後只有錶面變（眨眼、瞄一眼、換分鐘）就把
    /// 「新錶面 − 舊錶面」透視投影到螢幕四邊形、加回海報，不必為一次眨眼把 RealityKit 掛回來（一次約 30–40 ms）。
    /// 螢幕是 UnlitMaterial、沒有色調映射，蓋板玻璃的反光是加上去的，所以「加差值」和真的重繪幾乎一樣。
    private var frozenPatch: (poster: CIImage, posterCG: CGImage?, face: CIImage, corners: [CGPoint], scale: CGFloat, cs: CGColorSpace)?
    private var renderedScreenGeneration = -1
    private(set) var patches3D = 0
    /// 凍結時錶面的 48×48 縮圖：補丁前先量「新錶面變了多大一塊」
    private var frozenThumb: [UInt8]?
    /// 補丁只適合小範圍的變化（眨眼、瞄一眼）。差值法的前提是「舊錶面的透視投影＝RealityKit 當時畫上去的樣子」，
    /// 但兩者在取樣與邊緣上總差一兩個像素：變化小時殘差只落在變的那一小塊、看不出來；整面都變（連線過場、
    /// 換錶面、大數字換分鐘）時，舊錶面每一道邊的殘差會同時浮出來＝殘影。超過這個比例就掛回 3D 重畫。
    static let patchMaxChange = 0.04
    static func faceThumb(_ img: CGImage) -> [UInt8] {
        let n = 48
        var buf = [UInt8](repeating: 0, count: n * n * 4)
        buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: n, height: n))
        }
        return buf
    }
    /// 兩張縮圖有多少比例的像素明顯不同（任一色版差 > 20/255），以及有沒有變化落在 allowed（1024 畫布）之外
    static func changedFraction(_ a: [UInt8], _ b: [UInt8], allowed: CGRect? = nil) -> (fraction: Double, outside: Bool) {
        guard a.count == b.count, !a.isEmpty else { return (1, true) }
        let n = 48, k = CGFloat(n) / 1024
        let box = allowed.map { CGRect(x: $0.minX * k, y: $0.minY * k, width: $0.width * k, height: $0.height * k).insetBy(dx: -1, dy: -1) }
        var changed = 0, outside = false
        for i in stride(from: 0, to: a.count, by: 4) {
            let d = max(abs(Int(a[i]) - Int(b[i])), abs(Int(a[i + 1]) - Int(b[i + 1])), abs(Int(a[i + 2]) - Int(b[i + 2])))
            guard d > 20 else { continue }
            changed += 1
            let px = (i / 4) % n, py = (i / 4) / n
            if !(box?.contains(CGPoint(x: CGFloat(px) + 0.5, y: CGFloat(py) + 0.5)) ?? false) { outside = true }
        }
        return (Double(changed) / Double(a.count / 4), outside)
    }
    var debugDetached: Bool { !attached3D && !poster.isHidden }
    /// 海報補丁專用的 Core Image context（跟錶面的分開，補完就清快取）
    /// 補丁＝「有變化的那一小塊直接換成新內容」，不是 p + n − o：
    /// 3D 畫出來的螢幕和平面錶面的投影銳利度、明暗都不完全一樣，加減法會讓舊內容的每道邊留下一圈殘差（殘影）。
    /// 做法：|n − o| 超過門檻的像素＝變化區，往外擴 3 px 再羽化成遮罩 M；在變化區周圍沒變的像素上，
    /// 逐色版用最小平方擬合 p ≈ a·o + b（螢幕的明暗、反光近似成仿射），變化區填 a·n + b。舊內容在 M 裡完全不出現。
    /// 擬合用的乾淨像素不夠（整塊都在變）就回 nil，交給 3D 重畫。
    static func replacePatch(p: [Float], n: [Float], o: [Float], w: Int, h: Int) -> [Float]? {
        let count = w * h
        var changed = [Float](repeating: 0, count: count)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for i in 0..<count where o[i * 4 + 3] > 0.99 && n[i * 4 + 3] > 0.99 {
            let d = max(abs(n[i * 4] - o[i * 4]), abs(n[i * 4 + 1] - o[i * 4 + 1]), abs(n[i * 4 + 2] - o[i * 4 + 2]))
            if d > 0.012 { changed[i] = 1; let x = i % w, y = i / w; minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
        }
        guard maxX >= 0 else { return p }   // 沒有變化
        // 擴張（可分離的方框最大值）再羽化（方框平均），各自兩趟
        func boxPass(_ src: [Float], radius r: Int, horizontal: Bool, maxOp: Bool) -> [Float] {
            var dst = src
            for y in 0..<h { for x in 0..<w {
                var acc: Float = 0, k: Float = 0
                for t in -r...r {
                    let xx = horizontal ? x + t : x, yy = horizontal ? y : y + t
                    guard xx >= 0, xx < w, yy >= 0, yy < h else { continue }
                    let v = src[yy * w + xx]
                    if maxOp { acc = max(acc, v) } else { acc += v; k += 1 }
                }
                dst[y * w + x] = maxOp ? acc : acc / max(1, k)
            } }
            return dst
        }
        var m = boxPass(boxPass(changed, radius: 3, horizontal: true, maxOp: true), radius: 3, horizontal: false, maxOp: true)
        m = boxPass(boxPass(m, radius: 2, horizontal: true, maxOp: false), radius: 2, horizontal: false, maxOp: false)
        // 擬合範圍：變化區外擴 28 px 的方框裡、遮罩為 0、在螢幕內的像素
        let pad = 28
        let x0 = max(0, minX - pad), x1 = min(w - 1, maxX + pad), y0 = max(0, minY - pad), y1 = min(h - 1, maxY + pad)
        var a = [Float](repeating: 1, count: 3), b = [Float](repeating: 0, count: 3)
        for c in 0..<3 {
            var so: Double = 0, sp: Double = 0, soo: Double = 0, sop: Double = 0, k: Double = 0
            for y in y0...y1 { for x in x0...x1 {
                let i = y * w + x
                guard m[i] == 0, o[i * 4 + 3] > 0.99 else { continue }
                let ov = Double(o[i * 4 + c]), pv = Double(p[i * 4 + c])
                so += ov; sp += pv; soo += ov * ov; sop += ov * pv; k += 1
            } }
            guard k > 200 else { return nil }
            let den = k * soo - so * so
            let ac = abs(den) < 1e-9 ? 1 : (k * sop - so * sp) / den
            a[c] = Float(ac); b[c] = Float((sp - ac * so) / k)
        }
        var out = p
        for i in 0..<count where m[i] > 0 {
            for c in 0..<3 {
                let v = a[c] * n[i * 4 + c] + b[c]
                out[i * 4 + c] = min(1, max(0, p[i * 4 + c] * (1 - m[i]) + v * m[i]))
            }
        }
        return out
    }
    private static let patchCI = CIContext(options: [.cacheIntermediates: false, .workingFormat: CIFormat.RGBAh])
    private let posterPatching = ProcessInfo.processInfo.environment["HOMEPLAY_POSTER_PATCH"] != "0"
    private var updateSub: (any Cancellable)?
    private var renderedGeneration = -1
    private var renderedPose = ScenePose()
    private var bob: CGFloat = 0              // 4.5 秒一次的輕微浮動（世界座標 y）
    private var posterBob: CGFloat = 0        // 凍結幀那一刻的浮動值；卸下期間浮動改成海報層位移
    private var sceneDirty = false
    private var changeGaps: (last: Double, prev: Double) = (1, 1)   // 最近兩次場景變化的間隔
    private var lastDirtyAt: Double = -1                             // 上一次 syncRenderer 判定有變化的時刻
    private let renderLog = ProcessInfo.processInfo.environment["HOMEPLAY_RENDER_LOG"] != nil
    /// 靜止多久才卸下。一次卸下＋掛回約 30–40 ms CPU（掛回後至少 3 幀、靜止等待那幾幀、凍結幀讀回），
    /// 常駐則是每秒約 200 ms，所以空檔超過 0.2 s 就值得卸：眨眼（0.13 s）結束後 0.12 s 卸下。
    /// 連續兩次變化間隔都短於 0.35 s（Flow 錶面 4 Hz 壁紙、眼睛平滑過場）＝持續的小變化，
    /// 反覆掛卸只會比常駐更貴，這時等 0.4 s 再卸，讓它留在線上直到變化真的停下。
    /// 游標還停在桌寵上就再撐 2 s：手勢多半接著來，反覆掛卸正是「有點卡」的來源。
    private var stillDelay: Double {
        if CACurrentMediaTime() - pointerInsideAt < 0.5 { return 2 }
        return changeGaps.last < 0.35 && changeGaps.prev < 0.35 ? 0.4 : 0.12
    }
    private var pointerInsideAt: Double = -10
    /// 送去渲染的姿態；差異小於約 0.1 px 就不算變化（彈簧落定後的無限小位移不值得出幀）。
    /// 全用 Double 比：Float 四元數的點積在 1e-7 以下沒有解析度，拿它判「沒變」會一直誤報。
    private struct ScenePose {
        var yaw = Double.nan, pitch = 0.0, rigPitch = 0.0, rigYaw = 0.0, apart = 0.0, press = 0.0, aim = 0.0
        func differs(from o: ScenePose) -> Bool {
            if yaw.isNaN || o.yaw.isNaN { return true }
            return abs(yaw - o.yaw) > 4e-4 || abs(pitch - o.pitch) > 4e-4          // 機身半徑約 8 單位：約 0.1 px
                || abs(rigPitch - o.rigPitch) > 4e-4 || abs(rigYaw - o.rigYaw) > 4e-4
                || abs(apart - o.apart) > 1e-4 || abs(press - o.press) > 5e-5
                || abs(aim - o.aim) > 4e-4                                              // 整机朝向（Aim）
        }
    }
    private let posterIdle = ProcessInfo.processInfo.environment["HOMEPLAY_POSTER_AFTER"].flatMap(Double.init) ?? 90
    /// 診斷用：HOMEPLAY_IDLE_HZ 可改閒置幀率（能效量測）。每幀都去讀一次環境字典太浪費，啟動時讀一次。
    private let idleHzOverride = ProcessInfo.processInfo.environment["HOMEPLAY_IDLE_HZ"].flatMap { Int($0) }
    /// 每幀都會用到的「慢狀態」（整點小時、系統減弱動態）每秒才更新一次。
    private var slowStateAt: Double = -1
    private var cachedHour = 12
    private var cachedReduceMotion = false

    private weak var liveTimerItem: NSMenuItem?   // 打开的菜单里的「计时器」父项
    private var menuTicker: Timer?                // 菜单打开期间逐秒刷新倒计时
    private var gazePitchValueLabel: NSTextField? // 俯仰角度弹窗里的数值
    private enum Drag { case none, rotate, resize, touch, move }
    private var drag: Drag = .none
    private var threeFinger: [CGPoint]?   // 三指拖移的上一帧归一化位置
    private var limitHaptic: CGFloat?      // 缩放碰界时只震一次
    private var last = NSPoint.zero
    private var winStart = NSRect.zero
    private var mouseStart = NSPoint.zero

    init(frame: NSRect, initialApart: Bool = false, yaw y0: CGFloat? = nil, pitch p0: CGFloat? = nil) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
        allowedTouchTypes = [.indirect]    // 三指拖移窗口要收到触控板触摸
        // 輔助功能：VoiceOver 至少知道這是什麼、能做什麼
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(L("a11y.pet", "HomePlay 桌宠"))
        setAccessibilityHelp(L("a11y.help", "重按屏幕进入 CarPlay，右键打开菜单"))

        render.frame = bounds
        render.autoresizingMask = [.width, .height]
        render.environment.background = .color(.clear)
        if let studio = QuickLookIBL.studio {
            render.environment.lighting.resource = studio
            log("Quick Look object-mode IBL loaded")
        }
        render.__enableAutomaticFrameRate = false
        render.__preferredFrameRate = 60
        // 这不是 AR 场景：走 RealityKit 的非 ARKit 设备路径，别让 ARView 维持 ARKit 的
        // 相机/合成相关固定开销。桌面小窗用不到相机背景合成。
        render.__nonARKitDevices = true
        render.__disableComposition = true
        addSubview(render)
        // 每一幀 RealityKit 都會發 Update（主執行緒）：拿它數幀、判斷「第一幀已上屏」與「靜止夠久可以卸下」。
        updateSub = render.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in self?.sceneDidUpdate() }

        poster.frame = bounds
        poster.autoresizingMask = [.width, .height]
        poster.wantsLayer = true
        poster.layer?.backgroundColor = NSColor.clear.cgColor
        poster.isHidden = true
        poster.setAccessibilityElement(false)
        addSubview(poster, positioned: .above, relativeTo: render)
        if onDemand3D { installFreeze() }
        // 拆開看看的零件標籤：蓋在 3D、海報之上，不接滑鼠
        callout.frame = bounds
        callout.autoresizingMask = [.width, .height]
        callout.isHidden = true
        callout.setAccessibilityElement(false)
        addSubview(callout, positioned: .above, relativeTo: nil)

        // RealityKit 场景：USDZ 原样放进来，相机由 __defaultCamera 控制（24° 长焦）。
        bodyAnchor = AnchorEntity(world: .zero)
        bodyAnchor.addChild(model.holder)
        render.scene.addAnchor(bodyAnchor)
        setFinish(Finish(rawValue: UserDefaults.standard.string(forKey: Finish.defaultsKey) ?? "") ?? .starlight)
        if model.finish == .g4 { face.sayHello(CACurrentMediaTime()) }   // G4 白：开机先写一个 hello
        let savedStyle = FaceStyle(rawValue: UserDefaults.standard.string(forKey: FaceStyle.defaultsKey) ?? "") ?? .island
        face.style = savedStyle.inLineup
        face.restoreFaceOptions(migrating: savedStyle)   // Typograph 材質／System 6 版式（舊的浮雕、Alarm Clock、About 在這裡搬進來）
        face.restoreIslandOptions()   // 島錶面：时钟样式 / 背景 / 年代
        CompanionLog.markToday()   // 陪伴的痕跡：今天打开过
        // 电量每分钟读一次（IOKit，读不到＝没有电池）
        face.battery = Battery.read()
        batteryTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.face.battery = Battery.read() }
        batteryTimer?.tolerance = 10
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.face.resyncTimer(); self?.face.battery = Battery.read()
        }
        // 螢幕休眠＝沒人看：連定時器和 3D 渲染一起停，醒來再照視窗實際可見性恢復
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setOccluded(true)
            NowPlayingPoller.shared.paused = true
            // 屏幕睡了就关摄像头：不给「人不在电脑前」留一个亮着的绿点。
            if self?.gazeEnabled == true || self?.roomLightEnabled == true { GazeTracker.shared.setPaused(true) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let visible = self.window?.occlusionState.contains(.visible) ?? true
            self.setOccluded(!visible)
            NowPlayingPoller.shared.paused = !visible
            if (self.gazeEnabled || self.roomLightEnabled), !self.occluded, !self.screenLocked {
                GazeTracker.shared.setPaused(false)
            }
        }
        // 锁屏/解锁：显示器不一定马上睡，单独收系统通知（这两个名字是 AppKit 之外的通知，长期稳定）。
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.screenLocked = true
            guard self.gazeEnabled || self.roomLightEnabled else { return }
            GazeTracker.shared.setPaused(true)
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.screenLocked = false
            guard self.gazeEnabled || self.roomLightEnabled, !self.occluded else { return }
            GazeTracker.shared.setPaused(false)
        }
        RunLoop.main.add(batteryTimer!, forMode: .common)
        if NowPlayingPoller.enabled { NowPlayingPoller.shared.start(face: face) }   // 只在 Music/Spotify 已在跑时才问
        CalendarSource.shared.start(face: face)   // 已授权才读，没授权只更新状态
        // 计时器到点：岛吓一跳、甩头，横幅从上面出来；之后笑一下
        face.onTimerDone = { [weak self] in
            guard let self else { return }
            let now = CACurrentMediaTime()
            self.mood.activity(now: now, hour: Calendar.current.component(.hour, from: Date()))
            if self.pomodoroAdvance(now) { return }
            self.mood.show(.surprised, for: 0.8, now: now); self.shake(now)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.mood.show(.happy, for: 1.2, now: CACurrentMediaTime()) }
            log("timer done")
        }
        // 相机：用 RealityKit 默认相机，但改成产品摄影的 24° 长焦，位置在 step() 里绕机身转。
        cameraEntity = render.scene.__defaultCamera
        if let cameraEntity {
            var pc = cameraEntity.components[PerspectiveCameraComponent.self] ?? PerspectiveCameraComponent()
            pc.fieldOfViewInDegrees = 24
            pc.near = 1
            pc.far = 600
            cameraEntity.components.set(pc)
        } else {
            log("RealityKit 默认相机不可用")
        }

        // 默认 IBL 就是 Quick Look 的棚拍环境（高调暖白、大面积柔光），不再自己造环境。
        // 只补一盏背后的柔光，让侧面/屏幕背板也像官图一样被托亮。
        let fill = DirectionalLight()
        fill.light.intensity = 2000
        fill.light.color = NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.92, alpha: 1)
        fill.look(at: SIMD3<Float>(0, 9, 2), from: SIMD3<Float>(0, 30, -100), relativeTo: nil)
        bodyAnchor.addChild(fill)
        backLight = fill

        // 房间主光：方向/颜色/强度由摄像头估计（RoomLightEstimator）驱动；没开灯时强度 0。
        let key = DirectionalLight()
        key.light.intensity = 0
        key.light.color = NSColor(calibratedRed: 1, green: 0.97, blue: 0.92, alpha: 1)
        key.look(at: SIMD3<Float>(0, 9, 0), from: SIMD3<Float>(0, 30, 120), relativeTo: nil)
        bodyAnchor.addChild(key)
        roomKey = key
        roomEnv = RoomEnvironment()
        roomEnv?.onEnvironment = { [weak self] env in
            self?.render.environment.lighting.resource = env
            self?.requestFrame()
        }

        model.setScreen(face.render())
        face.onHour = { [weak self] in self?.mood.show(.wink, for: 0.6, now: CACurrentMediaTime()) }
        // 每 0.25 s 看一次游标：靠近、摸头、好奇时眼珠的方向。用轮询，不要辅助功能权限。
        let envT = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.thermal = ProcessInfo.processInfo.thermalState
            self.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        RunLoop.main.add(envT, forMode: .common)
        startHoverTimer()
        decoder.onImage = { [weak self] img in
            guard let self, self.showingVideo, !self.carVideo.active else { return }
            self.model.setScreen(img)
            self.videoFrameArrived()
        }
        // 零拷貝路（方畫面）：MTLTexture 直接當材質，不經任何像素轉換
        decoder.onTexture = { [weak self] tex, _, _ in
            guard let self, self.showingVideo, !self.carVideo.active else { return }
            self.model.setScreen(texture: CornerFit.shared.apply(tex))   // 學圓角那一次連線才會縮放補黑，平常原樣
            self.videoFrameArrived()
        }
        carVideo.onTexture = { [weak self] tex in
            guard let self else { return }
            self.model.setScreen(texture: tex)
            self.videoFrameArrived()
        }
        if let y0 { yaw = y0; ty = y0 }
        if let p0 { pitch = p0; tp = p0 }
        if viewMode == .wall { model.setWall(true); yaw = 0; ty = 0; pitch = 0; tp = 0 }
        if initialApart { apartTarget = 1; apartT = 1; if y0 == nil { yaw = Self.apartYaw; ty = yaw } }
        // 驗證用：HOMEPLAY_CAR_VIDEO=<網址> 不接 iPhone 直接走 CarPlay 影片播放器（同一條貼圖路徑、控制列）
        if let u = ProcessInfo.processInfo.environment["HOMEPLAY_CAR_VIDEO"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.showVideo(true)
                self.carVideo.handle(["op": "play", "url": u, "startMs": 0, "uuid": "test"])
                self.carVideo.handle(["op": "rate", "rate": 1])
            }
        }
        // 量測用：HOMEPLAY_FAKE_LIVE=<fps> 不接 iPhone 也能進直播路徑，餵 1088² 的合成畫面（0＝只餵一張＝直播靜止）。
        if let fps = ProcessInfo.processInfo.environment["HOMEPLAY_FAKE_LIVE"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                var n = 0
                func frame() -> CGImage {
                    n += 1
                    return makeImage(1088, 1088) { g in
                        g.setFillColor(NSColor(calibratedRed: 0.08, green: 0.1, blue: 0.14, alpha: 1).cgColor)
                        g.fill(CGRect(x: 0, y: 0, width: 1088, height: 1088))
                        g.setFillColor(NSColor.systemOrange.cgColor)
                        g.fill(CGRect(x: 80 + (n * 7) % 900, y: 480, width: 120, height: 120))
                    }
                }
                self.showVideo(true)
                self.model.setScreen(frame()); self.videoFrameArrived()
                if fps > 0 {
                    let t = Timer(timeInterval: 1 / fps, repeats: true) { [weak self] _ in self?.model.setScreen(frame()); self?.videoFrameArrived() }
                    RunLoop.main.add(t, forMode: .common)
                }
                log("fake live \(fps) fps")
            }
        }
        // step() 里的 setLoopHz 会按当下需要的帧率建好定时器；只兜底一次，别再建第二个。
        loopHz = 0
        step()
        if timer == nil {
            timer = LoopClock(view: self, hz: 60) { [weak self] in self?.step() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 窗口缩放后 ARView 始终铺满内容区（RealityKit 的相机投影按 bounds 算）。
    override func layout() {
        super.layout()
        if render.frame != bounds { render.frame = bounds; requestFrame(); updateFaceScale() }
    }
    /// 換到不同解析度的螢幕（Retina ↔ 外接 1x）：貼圖跟著重算
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateFaceScale()
    }

    // 每帧：弹簧、镜头、脸
    /// 窗口被完全遮住（全屏 App、别的桌面）时停渲染；快照不停
    private(set) var occluded = false
    /// 除錯：印出當下姿態（yaw/pitch/look/rig）
    func logPose() {
        log(String(format: "pose yaw=%.3f ty=%.3f pitch=%.3f tp=%.3f lookX=%.3f lookY=%.3f",
                   yaw, ty, pitch, tp, lookX, lookY))
        if let c = cameraEntity {
            let p = c.position(relativeTo: nil)
            log(String(format: "pose cam pos=(%.1f,%.1f,%.1f) rot=(%.3f,%.3f,%.3f,%.3f)",
                       p.x, p.y, p.z, c.orientation.vector.x, c.orientation.vector.y,
                       c.orientation.vector.z, c.orientation.vector.w))
        }
    }

    /// 臉部貼圖只用「畫到螢幕上實際需要的像素」：省 CPU 光柵與每幀紋理上傳
    func updateFaceScale() {
        // 螢幕佔視窗寬約 0.71（USDZ 量的）：貼圖像素要 ≥ 螢幕上實際像素，否則放大後發糊；上限 2048
        let need = bounds.width * (window?.backingScaleFactor ?? 2) * 0.72
        Typo.pointsPerUnit = max(80, bounds.width) * 0.72 / 1024   // 字體的光學尺寸與字距照螢幕上的實際大小（Typography.swift）
        let sc = max(0.25, min(2, need / 1024))
        if abs(sc - face.renderScale) > 0.02 { face.renderScale = sc; face.forceDirty = true }
    }

    /// RealityKit 快照（透明底）。ARView 与 PetView 同尺寸，直接取整张。
    func captureSnapshot(_ completion: @escaping (CGImage?) -> Void) {
        // 卸下期間 snapshot 不會完成：先掛回去、跑一拍把待處理的臉／姿態套上，出過幀再拍。
        if !attached3D || updates3D < 3 {
            pendingSnapshots.append(completion)
            if !attached3D { step(); attach3D() }
            return
        }
        snapshotsInFlight += 1   // 拍到一半不能卸下：卸下期間 snapshot 永遠不會完成
        render.snapshot(saveToHDR: false) { [weak self] img in
            self?.snapshotsInFlight -= 1
            guard let img, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                completion(nil); return
            }
            completion(cg)
        }
    }

    /// 場景有看得見的變化（光、環境貼圖、視窗尺寸）：下一拍一定要出幀。貼圖／材質走 model.generation。
    func requestFrame() {
        sceneDirty = true
        if onDemand3D, !attached3D, !occluded { attach3D() }
    }

    /// 直播進了一幀：不等主循環那拍，立刻掛回去出幀；主循環若已降到靜止的 12 Hz 也馬上回 60。
    private var lastVideoFrame: Double = -1
    private func videoFrameArrived() {
        lastVideoFrame = CACurrentMediaTime()
        requestFrame()
        if loopHz != 0, loopHz < 30, !posterActive { step() }
    }

    /// 把 ARView 掛回視窗：RealityKit 從這一刻起每秒 60 幀；海報留著蓋到第 3 次 Update。
    private func attach3D() {
        guard !attached3D else { return }
        attached3D = true
        frozenPatch = nil
        updates3D = 0
        detachShotAt = nil
        lastSceneChange = CACurrentMediaTime()
        if render.superview == nil {
            addSubview(render, positioned: .below, relativeTo: poster)
            render.frame = bounds
            render.autoresizingMask = [.width, .height]
        }
        render.isHidden = false
        if renderLog {
            log(String(format: "3d: attach t=%.3f", CACurrentMediaTime()))
            if let l = render.layer {
                var desc = "layer \(type(of: l)) sublayers=\((l.sublayers ?? []).map { String(describing: type(of: $0)) })"
                for m in ([l] + (l.sublayers ?? [])).compactMap({ $0 as? CAMetalLayer }) {
                    desc += String(format: " metal fmt=%d cs=%@ edr=%d scale=%.2f", m.pixelFormat.rawValue, m.colorspace.map { "\($0)" } ?? "nil", m.wantsExtendedDynamicRangeContent ? 1 : 0, m.contentsScale)
                }
                log(desc)
            }
        }
    }

    // 凍結幀：`snapshot()` 是另一條離線渲染，和上屏那幀在貼圖取樣與輪廓有 1–30 階差（切換會微閃）；
    // 改在 renderCallbacks.postProcess 裡把 sourceColorTexture（就是要上屏的那幀）blit 一份出來，
    // 命令完成後讀回主執行緒當海報：逐位相同，且不用多渲染一幀。
    private var freezeTex: MTLTexture?
    private let freezeLock = NSLock()
    private var freezeRequest = false        // 主執行緒設、渲染執行緒取
    private var freezeSerial = 0
    private func installFreeze() {
        render.renderCallbacks.postProcess = { [weak self] ctx in
            guard let self, let blit = ctx.commandBuffer.makeBlitCommandEncoder() else { return }
            let src = ctx.sourceColorTexture
            blit.copy(from: src, to: ctx.targetColorTexture)
            self.freezeLock.lock(); let want = self.freezeRequest; self.freezeRequest = false; self.freezeLock.unlock()
            guard want else { blit.endEncoding(); return }
            if let f = self.freezeTex, f.width == src.width, f.height == src.height, f.pixelFormat == src.pixelFormat {
            } else {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: src.pixelFormat, width: src.width, height: src.height, mipmapped: false)
                d.usage = [.shaderRead]; d.storageMode = .shared
                self.freezeTex = ctx.device.makeTexture(descriptor: d)
            }
            guard let f = self.freezeTex else { blit.endEncoding(); return }
            blit.copy(from: src, to: f)
            blit.endEncoding()
            let serial = self.freezeSerial
            ctx.commandBuffer.addCompletedHandler { [weak self] _ in
                DispatchQueue.main.async { self?.freezeCompleted(serial) }
            }
        }
    }

    /// 凍結幀讀回：BGRA 預乘、和 CAMetalLayer 同一個色彩空間，CA 合成時走同樣的匹配。
    private func freezeImage() -> CGImage? {
        guard let f = freezeTex, f.pixelFormat == .bgra8Unorm_srgb || f.pixelFormat == .bgra8Unorm else { return nil }
        let w = f.width, h = f.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        f.getBytes(&buf, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let cs = (render.layer as? CAMetalLayer)?.colorspace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bi = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs, bitmapInfo: bi) else { return nil }
        return ctx.makeImage()
    }

    /// 卸下 ARView：先要一幀凍結幀，拿到後確認中途沒再變才真的移出層級。snapshot=false（被遮住）直接卸。
    private func detach3D(snapshot: Bool = true) {
        guard attached3D, detachShotAt == nil else { return }
        if !snapshot {
            attached3D = false
            render.removeFromSuperview()
            cycles3D += 1
            return
        }
        let at = CACurrentMediaTime()
        detachShotAt = at
        freezeSerial += 1
        freezeLock.lock(); freezeRequest = true; freezeLock.unlock()
    }

    private func freezeCompleted(_ serial: Int) {
        guard serial == freezeSerial, let at = detachShotAt else { return }   // 中途取消過
        detachShotAt = nil
        guard attached3D, lastSceneChange <= at, pendingSnapshots.isEmpty, snapshotsInFlight == 0, !occluded, !sceneDirty,
              let cg = freezeImage() else { return }
        poster.show(cg, scale: window?.backingScaleFactor ?? 2)
        if posterPatching, let face = model.lastScreenImage, screenFacingCamera() {
            let c = screenCorners()
            frozenPatch = c.count == 4 ? (CIImage(cgImage: cg), cg, CIImage(cgImage: face), c, window?.backingScaleFactor ?? 2,
                                          cg.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!) : nil
            frozenThumb = frozenPatch == nil ? nil : Self.faceThumb(face)
        } else { frozenPatch = nil; frozenThumb = nil }
        posterBob = bob
        poster.frame = bounds
        poster.isHidden = false
        render.removeFromSuperview()      // 與顯示海報同一個 transaction：畫面不閃
        attached3D = false
        cycles3D += 1
        if renderLog { log(String(format: "3d: detach after %d frames (gaps %.3f/%.3f gen %d) t=%.3f", updates3D, changeGaps.last, changeGaps.prev, model.generation, CACurrentMediaTime())) }
    }

    /// RealityKit 每幀回呼（主執行緒）。
    private func sceneDidUpdate() {
        frames3D += 1
        guard attached3D else { return }
        updates3D += 1
        if updates3D == 3 {
            // 第 1 次 Update 的那幀在下一個 vsync 才上屏；到第 3 次才能確定 ARView 已經有畫面，再把海報收掉。
            if !poster.isHidden { poster.isHidden = true; poster.clear() }
            if !pendingSnapshots.isEmpty {
                let waiting = pendingSnapshots; pendingSnapshots = []
                for c in waiting { captureSnapshot(c) }
            }
        }
        guard onDemand3D, updates3D >= 3, pendingSnapshots.isEmpty, snapshotsInFlight == 0, !sceneDirty else { return }
        let now = CACurrentMediaTime()
        if let at = detachShotAt, now - at > 1 { detachShotAt = nil }   // 凍結幀沒回來（不該發生）：放棄這次，下一幀再試
        if now - lastSceneChange > stillDelay { detach3D() }
    }

    /// 每拍結束：姿態／貼圖有沒有變；卸下期間把浮動換成海報層的整像素位移。
    private func syncRenderer(_ now: Double) {
        guard onDemand3D else { return }
        let pose = ScenePose(yaw: Double(yaw), pitch: Double(pitch), rigPitch: Double(rigPitch), rigYaw: Double(rigYaw),
                             apart: Double(apartT), press: Double(press),
                             aim: model.aimYaw.isNaN ? 0 : Double(model.aimYaw))
        // 只有錶面貼圖變了、機身沒動、而且 3D 已卸下：補海報就好
        if !sceneDirty, !attached3D, model.generation != renderedGeneration, !pose.differs(from: renderedPose),
           model.generation - renderedGeneration == model.screenGeneration - renderedScreenGeneration, patchPoster() {
            renderedGeneration = model.generation
            renderedScreenGeneration = model.screenGeneration
        }
        if model.generation != renderedGeneration || pose.differs(from: renderedPose) { sceneDirty = true }
        if sceneDirty {
            sceneDirty = false
            renderedGeneration = model.generation
            renderedScreenGeneration = model.screenGeneration
            renderedPose = pose
            if lastDirtyAt > 0 { changeGaps = (now - lastDirtyAt, changeGaps.last) }
            lastDirtyAt = now
            lastSceneChange = now
            detachShotAt = nil          // 等凍結幀途中又變了：那張不用了
            if !occluded { attach3D() }
        } else if !attached3D, !poster.isHidden {
            // 浮動是整台機身的上下平移：海報期間用層位移呈現，吸到整個裝置像素，不重採樣。
            let scale = window?.backingScaleFactor ?? 2
            var dy: CGFloat = 0
            if let a = render.project(SIMD3<Float>(0, 9 + Float(bob), 0)),
               let b = render.project(SIMD3<Float>(0, 9 + Float(posterBob), 0)) {
                dy = ((a.y - b.y) * scale).rounded() / scale
            }
            let f = bounds.offsetBy(dx: 0, dy: dy)
            if poster.frame != f { poster.frame = f }
        }
    }

    /// 把「目前錶面 − 凍結時錶面」投影到螢幕四邊形，加回凍結幀。成功回 true。
    /// Core Image 的合成會把負值夾成 0（變暗的地方加不回去），所以加減在 CPU 上用浮點做，只算螢幕那一塊：
    /// 三張圖（海報、新錶面投影、舊錶面投影）在線性色彩裡渲染成 Float 緩衝，p + n − o 夾回 0…1 再貼回海報。
    private func patchPoster() -> Bool {
        guard let fp = frozenPatch, let img = model.lastScreenImage,
              CGFloat(img.width) == fp.face.extent.width, CGFloat(img.height) == fp.face.extent.height else {
            if renderLog { log("3d: patch skipped (frozen \(frozenPatch != nil), image \(model.lastScreenImage != nil))") }
            return false
        }
        // 變太多就不補：交給 3D 重畫（見 patchMaxChange 的說明）
        // 只補「膠囊裡」的短暫變化（眨眼、瞄一眼，等一下會回到凍結時的樣子）；指針、換分鐘、過場這些
        // 會留下來或整面變的，補了會在舊內容的每道邊留下殘差＝殘影，一律掛回 3D 重畫
        let ch = frozenThumb.map { Self.changedFraction($0, Self.faceThumb(img), allowed: face.islandRect) } ?? (fraction: 1, outside: true)
        if ch.fraction > Self.patchMaxChange || ch.outside {
            if renderLog { log("3d: patch skipped, \(Int(ch.fraction * 100))% changed\(ch.outside ? " outside the capsule" : "") → re-render") }
            return false
        }
        let pts = fp.corners.map { CGPoint(x: $0.x * fp.scale, y: $0.y * fp.scale) }
        let c = pts.map { CIVector(x: $0.x, y: $0.y) }
        func proj(_ im: CIImage) -> CIImage {
            im.applyingFilter("CIPerspectiveTransform", parameters: ["inputTopLeft": c[0], "inputTopRight": c[1], "inputBottomRight": c[2], "inputBottomLeft": c[3]])
        }
        // 螢幕四邊形的外框（像素、整數），夾在海報裡
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let quad = CGRect(x: floor(xs.min()!) - 2, y: floor(ys.min()!) - 2, width: ceil(xs.max()! - xs.min()!) + 4, height: ceil(ys.max()! - ys.min()!) + 4)
            .intersection(fp.poster.extent)
        guard !quad.isNull, quad.width >= 2, quad.height >= 2 else { return false }
        let w = Int(quad.width), h = Int(quad.height)
        let lin = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        func floats(_ im: CIImage) -> [Float] {
            var buf = [Float](repeating: 0, count: w * h * 4)
            buf.withUnsafeMutableBytes { Self.patchCI.render(im, toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: quad, format: .RGBAf, colorSpace: lin) }
            return buf
        }
        // 投影後輕輕模糊半個像素：3D 取樣（mipmap＋多重取樣）比 Core Image 的投影柔，兩邊銳利度才接近
        func soft(_ im: CIImage) -> CIImage { im.clampedToExtent().applyingGaussianBlur(sigma: 0.55).cropped(to: im.extent) }
        let pBuf = floats(fp.poster), nBuf = floats(soft(proj(CIImage(cgImage: img)))), oBuf = floats(soft(proj(fp.face)))
        Self.patchCI.clearCaches()   // 補丁之間不需要留中間圖（實測 footprint 只多約 4 MB）
        guard let out = Self.replacePatch(p: pBuf, n: nBuf, o: oBuf, w: w, h: h) else {
            if renderLog { log("3d: patch skipped, no clean pixels to match the screen's shading → re-render") }
            return false
        }
        // 浮點緩衝 → CGImage（線性色彩），蓋回凍結幀的那一塊
        let data = out.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let patch = CGImage(width: w, height: h, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: w * 16, space: lin,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let base = fp.posterCG,
              let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0, space: fp.cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        ctx.setBlendMode(.copy)
        ctx.draw(patch, in: quad)   // CIImage 與 CGContext 都是左下原點，座標直接對上
        guard let cg = ctx.makeImage() else { return false }
        poster.show(cg, scale: fp.scale)
        patches3D += 1
        if let p = ProcessInfo.processInfo.environment["HOMEPLAY_PATCH_TEST"] {
            try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: p + "/patched.png"))
        }
        return true
    }

    /// 深度閒置（90 秒沒人看）：主循環停掉，改成每 5 秒跑一拍；掛載／卸下由按需 3D 閘門處理
    /// （靜止時本來就已卸下，跑一拍若有變化會掛回去出幀、再卸下）。房間光/摄像头也暂停，绿点灭掉。
    private func startPoster() {
        guard !posterActive, !showingVideo, !occluded else { return }
        posterActive = true
        timer?.invalidate(); timer = nil; loopHz = 0
        if roomLightEnabled || gazeEnabled { GazeTracker.shared.setPaused(true) }
        startPosterTimer()
        log("poster: idle, 5 s cadence")
    }

    private func startPosterTimer() {
        posterTimer?.invalidate()
        let t = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in self?.posterTick() }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        posterTimer = t
    }

    /// 深度閒置期間時間/眨眼仍要走：每 5 秒讓主循環跑一拍，有變化就由閘門掛回去出一輪幀再卸下。
    private func posterTick() {
        guard posterActive, !occluded else { return }
        step()
    }

    private func endPoster() {
        guard posterActive else { return }
        posterActive = false
        posterTimer?.invalidate(); posterTimer = nil
        if (roomLightEnabled || gazeEnabled), !occluded, !screenLocked {
            GazeTracker.shared.setPaused(false)
        }
        lastNear = CACurrentMediaTime()
        lastStep = lastNear
        face.forceDirty = true
        step()
        log("poster: resume")
    }

    /// 引导/配对卡出现时让海报让位；海报只在 PetView 内，AppDelegate 通过这个方法唤醒。
    func wakeFromPosterForGuide() {
        if posterActive { endPoster() }
    }

    func setOccluded(_ o: Bool) {
        guard o != occluded else { return }
        occluded = o
        if o {
            // 完全被遮住／螢幕休眠：連主循環和懸停輪詢一起停掉，不再每 1/12 秒叫醒 CPU；
            // ARView 也直接卸下（isHidden 停不掉它的 display link），露出來時第一拍會掛回去。
            if onDemand3D { detach3D(snapshot: false) } else { render.isHidden = true }
            timer?.invalidate(); timer = nil; loopHz = 0
            posterTimer?.invalidate(); posterTimer = nil
            hoverTimer?.invalidate(); hoverTimer = nil
            NowPlayingPoller.shared.paused = true
            onVideoState?(false)          // 健康檢查/統計也停
        } else {
            if posterActive { endPoster() }
            render.isHidden = false
            sceneDirty = true
            lastStep = CACurrentMediaTime(); face.forceDirty = true
            NowPlayingPoller.shared.paused = false
            startHoverTimer()
            if showingVideo { onVideoState?(true) }
            step()   // 立刻補一幀並恢復幀率
        }
        log("occluded \(o)")
    }
    private func startHoverTimer() {
        guard hoverTimer == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.watchPointer() }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
    }
    private func step() {
        if occluded { return }
        stepFrames += 1
        let now = CACurrentMediaTime()
        refreshSlowState(now)
        // 低幀率醒來那一拍 dt 可能到 0.25 s：彈簧拆成 ≤1/60 s 的小步積分，時間照實走，不會慢動作也不會發散
        let realDt = CGFloat(min(0.25, max(0, now - lastStep))); lastStep = now
        let subSteps = max(1, Int((realDt * 60).rounded(.up)))
        let dt = realDt / CGFloat(subSteps)
        // 自动环绕：目标角速度匀速走（弹簧自然跟不上就变成平滑的慢转），俯仰缓缓回到 3/4 高度
        if touring {
            ty += realDt * 0.45
            tp += (0.32 - tp) * min(1, realDt * 1.5)
        }
        // 挂墙：机身贴在墙上不转——拖转、滑动、转一圈、视角预设都不动镜头，永远正对屏幕
        let wall = viewMode == .wall && !isApart
        if wall {
            touring = false
            let full = 2 * CGFloat.pi
            ty = (yaw / full).rounded() * full; tp = 0
        }
        let k1: CGFloat = 26, c1 = 2 * sqrt(k1)      // 拆开：临界阻尼，不回弹（双击不是甩出去的手势）
        // 转动：Apple 的旋转弹簧（阻尼比 0.8、响应 0.4 s），放手带惯性时会轻轻过冲再停
        let k2: CGFloat = (2 * .pi / 0.4) * (2 * .pi / 0.4), c2: CGFloat = 2 * 0.8 * sqrt(k2)
        for _ in 0..<subSteps {
            apartV += ((apartTarget - apartT) * k1 - apartV * c1) * dt
            apartT += apartV * dt
            vy += ((ty - yaw) * k2 - vy * c2) * dt; yaw += vy * dt
            vp += ((tp - pitch) * k2 - vp * c2) * dt; pitch += vp * dt
        }
        model.apply(apartT)
        idleMotion(now, min(0.05, realDt))   // 頭部與 Aim 的顯式積分沿用舊上限

        // 镜头：围着身体转；拆开时退远一点、抬一点，九件都在画面里。
        // RealityKit 默认相机朝 -Z，绕 Y 转 yaw、绕 X 转 -pitch 就正对目标，滚转恒 0。
        let e = AnatomyLayer.liftProgress(apartT)   // 跟螢幕組抬升同步：半拆時也已經在框內
        // 挂墙只框屏幕模组：对准扶正后的显示面中心
        let target = wall ? HomeViewModel.wallScreenCenter : SIMD3<Float>(0, Float(8.6 + 3.6 * e), Float(1.8 + 3.0 * e))
        let fitH: Float = wall ? Self.wallFitH : Float(22 + 22 * e)
        let d = (fitH / 2) / tanf(12 * .pi / 180) * max(1, 0.86 / Float(Pet.aspect))
        let sy = sinf(Float(yaw)), cy = cosf(Float(yaw))
        let sp = sinf(Float(pitch)), cp = cosf(Float(pitch))
        if let cameraEntity {
            cameraEntity.position = target + SIMD3<Float>(sy * cp * d, sp * d, cy * cp * d)
            cameraEntity.orientation = simd_quatf(angle: Float(yaw), axis: SIMD3<Float>(0, 1, 0))
                * simd_quatf(angle: -Float(pitch), axis: SIMD3<Float>(1, 0, 0))
        }
        updateAnatomyCallout(now)

        // 转太快会吓一跳；拆开组回后甩头、眨单眼
        if abs(vy) > 6 { mood.show(.surprised, for: 0.4, now: now) }
        if reassembling, apartT < 0.15 {
            // 组回来了：甩头那 0.6 s 还是惊讶，之后眨单眼
            reassembling = false; mood.apart = false; shake(now)
            mood.show(.surprised, for: 0.6, now: now); pendingWink = now + 0.6
        }
        if let w = pendingWink, now >= w { pendingWink = nil; mood.show(.wink, for: 0.6, now: now) }
        rigMotion(now)

        let expr = lockedFace ?? mood.current(now: now, hour: cachedHour)
        face.set(expr)
        face.followPointer = mood.near && lockedFace == nil
        // 遠距（一分鐘沒靠近）不做表情過場動畫：直接到位，省十幾幀
        face.animateDetails = mood.near || now - lastNear <= 60 || face.needsSmooth(now)
        // 自適應幀率：有動作／直播跑 60，閒著 12（省 GPU 與電），睡著 1。
        // 臉上有變化（眨眼、瞄一眼、換錶面）時把 hot 窗口往後推，讓那幾幀仍以 60 跑順。
        if !showingVideo, !carVideo.active, let img = face.tick(now) {
            model.setScreen(img)
            // 只有眨眼、hello、引導、過場這種「要順」的動畫才維持 60fps；
            // 環境漂動（Flow 背景、壁紙）不抬頻，免得閒著也一直 60。
            if face.needsSmooth(now) { smoothUntil = now + 0.18 }
        }
        // 氛围动画停用的三种情况：过热、低电量、系统「减弱动态效果」（辅助功能）
        Face.ambientPaused = thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue || lowPower
            || cachedReduceMotion
        let moving = isAnimating(now)
        let hz = targetHz(now, asleep: expr == .asleep, moving: moving)
        setLoopHz(hz)
        syncRenderer(now)
        // 这么久没人看，而且没有任何动画/引导/直播：换成静态海报，停掉 RealityKit 的常驻渲染。
        if !posterActive, timer != nil, !showingVideo, !occluded, !screenLocked, !gazeEnabled,
           now - lastNear > posterIdle, !moving,
           CarPlayOverlayState.alpha <= 0.003, !face.inOverview, FaceOverview.pressAt == nil,
           let win = window, win.isVisible, win.occlusionState.contains(.visible) {
            startPoster()
        }
    }

    /// 整点小时 / 系统「减弱动态效果」这类变化很慢的状态：每秒更新一次就够，
    /// Calendar 与 NSWorkspace 的属性都不该出现在每帧路径上。
    private func refreshSlowState(_ now: Double) {
        guard now - slowStateAt >= 1 else { return }
        slowStateAt = now
        cachedHour = Calendar.current.component(.hour, from: Date())
        cachedReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// 現在是否在動：手勢、彈簧、過場都算（直播另外看有沒有進幀，見 targetHz）
    private func isAnimating(_ now: Double) -> Bool {
        return drag != .none || touring || now < hotUntil
            || abs(vy) > 0.02 || abs(ty - yaw) > 0.002
            || abs(vp) > 0.02 || abs(tp - pitch) > 0.002
            || abs(apartV) > 0.002 || abs(apartT - apartTarget) > 0.001
            || abs(pressTarget - 1) > 0.002
            || face.inOverview || FaceOverview.pressAt != nil
            || CarPlayOverlayState.alpha > 0.002
            || !aim.settled
            || PermissionPrimer.visible
    }

    /// 現在該用幾 fps：直播有進幀 60（畫面靜止半秒沒進幀就 12，進幀立刻回 60）；
    /// 有彈簧／手勢／過場／剛動過 60；否則 6；睡著 1
    private func targetHz(_ now: Double, asleep: Bool, moving: Bool) -> Int {
        // 無風扇機器：過熱或低電量時主動降載（WWDC25「Turbocharge your app for CarPlay」的建議）
        if thermal == .critical { return asleep ? 1 : 6 }
        let throttled = thermal == .serious || lowPower
        if showingVideo {
            if moving || now - lastVideoFrame < 0.5 { return throttled ? 30 : 60 }
            return 12
        }
        if asleep { return 1 }
        if throttled { return moving ? 30 : 8 }
        if moving { return 60 }
        // 沒人靠近超過一分鐘：降到 6fps（眨眼仍走 30fps 窗口，看不出差別）
        let far = now - lastNear > 60
        let idle = idleHzOverride ?? (far ? 4 : 6)
        // 眨眼、hello 這類小動畫 30fps 就夠順（60 的一半渲染、幾乎看不出差別）
        if now < smoothUntil { return max(30, idle) }
        return max(1, idle)
    }
    /// 主循環定時器跟著幀率走，閒著不再每秒叫醒 60 次
    private func setLoopHz(_ hz: Int) {
        if posterActive { loopHz = 0; return }
        guard hz != loopHz else { return }
        timer?.invalidate()
        loopHz = hz
        // Darwin 27 上這個值對 RealityKit 的出幀節奏無效（實測恆 60），真正省下來的是上面的按需掛載；
        // 仍照 targetHz 寫，保留語意給未來能生效的系統。
        render.__preferredFrameRate = Float(hz)
        timer = LoopClock(view: self, hz: hz) { [weak self] in self?.step() }
    }

    // MARK: 表情与小动作

    private var hoverTimer: Timer?
    private var reassembling = false
    private var hotUntil: Double = 0        // 這段時間內視為「有動作」，維持 60fps
    private var lastNear = CACurrentMediaTime()   // 最近一次游標靠近／互動：長時間沒人看就降到 6fps
    private var smoothUntil: Double = 0     // 眨眼這類小動畫只要 30fps（省一半渲染）
    private var loopHz = 60
    private var thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var pendingWink: Double?
    private var nodStart: Double?, shakeStart: Double?
    private var rotateMoved = false
    private var rotateTravel: CGFloat = 0          // 這次轉身體拖了多遠（點）：搬位置提示用
    private var moveHint = MoveHintDetector()
    /// 拖它就搬窗口的部位：底座那一截（螢幕、鉸鏈仍是轉身體）
    private static let standAnatomy: Set<AnatomyPart> = [.radiators, .baseModule, .power, .climate, .woofer, .foot]
    static var standAnatomyForTest: Set<AnatomyPart> { standAnatomy }
    private static let standParts: Set<String> = ["hinge", "dome", "grille", "driver", "foot"]

    /// 换外观：模型换材质；G4 白的屏幕走 Aqua，转头幅度也大一点（向日葵）
    func setFinish(_ f: Finish) { model.apply(finish: f); face.aqua = f == .g4 }

    /// 摄像头房间光的样本：亮度/色温/主光方向 → 主光、环境贴图。
    func apply(roomLight s: RoomLightSample) {
        let active = s.confidence > 0.02
        if active {
            let k = max(0, min(1.5, s.intensity))
            let t = max(0, min(1, (k - 0.4) / 1.1))
            roomKey.light.intensity = Float(250 + 1150 * t)
            let w = max(-1, min(1, s.warmth))
            roomKey.light.color = NSColor(calibratedRed: 1 + 0.055 * CGFloat(w),
                                          green: 1,
                                          blue: 1 - 0.055 * CGFloat(w), alpha: 1)
            let pos = s.direction * 100
            roomKey.look(at: SIMD3<Float>(0, 9, 0), from: pos, relativeTo: nil)
            backLight.light.intensity = Float(max(900, 2000 - 700 * t))
            roomEnv?.update(s)
        } else {
            roomKey.light.intensity = 0
            backLight.light.intensity = 2000
            render.environment.lighting.resource = roomEnv?.neutral() ?? QuickLookIBL.studio
        }
        requestFrame()
    }

    // MARK: 錶面与计时器

    private var batteryTimer: Timer?
    private var system6Pending = false, system6Token = 0
    private var wheelAcc: CGFloat = 0, lastFaceSwitch = 0.0
    /// 换錶面（滚轮、← →、菜单）：记住选择，岛眨一下眼
    func setFaceStyle(_ st: FaceStyle, remember: Bool = true) {
        face.textLayerCache = nil; face.staticCache = nil   // 换表盘后旧缓存不会再命中，直接放掉
        guard st != face.style else { return }
        face.style = st
        if remember { UserDefaults.standard.set(st.rawValue, forKey: FaceStyle.defaultsKey) }
        if !showingVideo { model.setScreen(face.render()) }
        mood.show(.wink, for: 0.5, now: CACurrentMediaTime())
        log("face style \(st.rawValue)")
    }
    // MARK: 番茄鐘

    func startPomodoro() {
        let phase = face.pomodoro.start()
        face.startTimer(seconds: phase.seconds)
        mood.show(.happy, for: 0.8, now: CACurrentMediaTime())
        log("pomodoro start")
    }
    func stopPomodoro() {
        face.pomodoro.stop(); face.cancelTimer()
        log("pomodoro stop")
    }
    /// 番茄鐘的一段到點：自動接下一段、出橫幅、換表情。不是番茄鐘就回 false（照一般計時器處理）
    private func pomodoroAdvance(_ now: Double) -> Bool {
        guard let (next, completed) = face.pomodoro.advance() else { return false }
        if completed { Pomodoro.recordCompleted() }
        face.startTimer(seconds: next.seconds, now: now)
        let today = Pomodoro.todayCount
        if next.isBreak {
            // 專注完成：笑一下，告訴你休息
            face.showBanner(now: now, texts: (String(format: L("pomodoro.doneToday", "专注完成 · 今天第 %d 个"), today),
                                              next == .longBreak ? L("pomodoro.longBreakNow", "休息 15 分钟") : L("pomodoro.breakNow", "休息一下")))
            mood.show(.happy, for: 2.4, now: now)
        } else {
            // 休息結束：眨一下眼，回來專注
            face.showBanner(now: now, texts: (L("pomodoro.breakOver", "休息结束"), L("pomodoro.backToFocus", "回来专注")))
            mood.show(.wink, for: 0.8, now: now)
        }
        log("pomodoro → \(next) (today \(today))")
        return true
    }

    func startTimer(minutes: Double) {
        face.pomodoro.stop()   // 手動開一般計時器：番茄鐘讓位
        face.startTimer(seconds: minutes * 60)
        mood.show(.happy, for: 0.8, now: CACurrentMediaTime())
        log("timer start \(Int(minutes * 60))s")
    }
    /// 只给快照用：当作游标就在旁边（玻璃卡展开）
    var forceNear = false { didSet { face.revealTarget = forceNear ? 1 : face.revealTarget } }

    func lockFace(_ e: Expression) {
        lockedFace = e; face.frozen = true; face.set(e, snap: true); face.cancelHello()
        if !showingVideo { model.setScreen(face.render()) }
    }
    /// 连上 CarPlay 出第一帧：往前点头 6°，0.35 s
    func nod() { nodStart = CACurrentMediaTime() }
    private func shake(_ now: Double) { shakeStart = now }
    private func rigMotion(_ now: Double) {
        var nodA: CGFloat = 0, shakeA: CGFloat = 0
        if let s = nodStart {
            let t = (now - s) / 0.35
            if t >= 1 { nodStart = nil } else { nodA = 0.105 * CGFloat(sin(.pi * t)) }
        }
        if let s = shakeStart {
            let t = (now - s) / 0.6
            if t >= 1 { shakeStart = nil } else { shakeA = 0.14 * CGFloat(sin(t * 3 * 2 * .pi) * (1 - t)) }
        }
        // USDZ 的屏幕几何已经带 20° 后仰，这里只叠加点头/摇头/追人的小幅偏移
        rigPitch = Float(nodA + lookY); rigYaw = Float(shakeA + lookX)
        model.setRig(pitch: rigPitch, yaw: rigYaw)
    }
    private var rigPitch: Float = 0, rigYaw: Float = 0

    // 待机的生命感：屏幕慢慢转向靠近的游标（最多偏航 ±0.1、俯仰 ±0.06 弧度，临界阻尼、响应 0.6 s）；
    // 按下时整台立刻缩 2.5%，放手弹回；整台 4.5 s 一次、极小幅度的浮动。
    private var lookX: CGFloat = 0, lookY: CGFloat = 0, lookVX: CGFloat = 0, lookVY: CGFloat = 0
    /// 整机朝向（Aim.swift）：窗口位置当基准、看到人就转向人；「正面固定」时恒为 0。
    private var aim = Aim()
    var viewMode = ViewMode.saved
    var followDegrees = Aim.savedFollowDegrees
    /// 快照用：假装窗口在显示器横向的哪里（0 左 … 1 右）
    static var windowXOverride: Double?
    private var lastDragEndAt: Double = 0
    // 追人（摄像头）：人脸框 → 转头/歪头；没人时做待机扫视。
    var gazeEnabled = false
    var gazePresent = false
    var gazeX: CGFloat = 0, gazeY: CGFloat = 0, gazeRoll: CGFloat = 0, gazeSize: CGFloat = 0
    private var gazeLastSeen: Double = 0
    private var gazeWasPresent = false
    private var gazeHeadOn = false    // 头部 yaw 的迟滞：小侧移只动眼睛，明显侧移才转头
    static let gazePitchKey = "HomePlayGazePitch"
    private(set) var gazePitchDegrees: CGFloat = {
        let v = (UserDefaults.standard.object(forKey: "HomePlayGazePitch") as? Double) ?? 2.5
        return CGFloat(min(8, max(0, v.isFinite ? v : 2.5)))
    }()
    private var screenLocked = false  // 锁屏期间不因为「重新可见」把摄像头拉起来
    private var press: CGFloat = 1, pressTarget: CGFloat = 1
    private var dragVel: CGFloat = 0, lastDragT: Double = 0
    /// 单轴锁：拖拽／滚轮转动共用（一次手势只走左右或上下）；滚轮手势没有明确边界，用时间隔断
    private var rotLock = AxisLock()
    private var lastRotScroll: Double = 0
    private func idleMotion(_ now: Double, _ dt: CGFloat) {
        let calm = !showingVideo && !isApart && drag == .none && lockedFace == nil
        var gx: CGFloat = 0, gy: CGFloat = 0
        // G4 白：像当年 G4 广告里跟着路人动作的那台，转头幅度大一倍
        let sunflower: CGFloat = model.finish == .g4 ? 2.2 : 1
        if calm, gazeEnabled, gazePresent {
            // 左右摇是主戏（G4 约 11.5°，其它约 7.5°）；俯仰只加一点点：
            // 以 0.65 当作「正常坐姿」的中位（摄像头通常比脸高），只回应明显起身/凑近，
            // 非 G4 最多约 2°，G4 最多约 3.7°——Mac 是效率工具，桌宠只做轻微回应。
            // 头部有 0.08–0.14 的迟滞：小幅侧移只动眼睛，明显侧移才转头，避免一直微调。
            let g4 = model.finish == .g4
            let ax = abs(gazeX)
            if ax > 0.14 { gazeHeadOn = true } else if ax < 0.08 { gazeHeadOn = false }
            // 左右转交给整机（aim，±25° DockKit 式）；铰链只留俯仰
            _ = ax
            gx = 0
            // 俯仰上限由菜单里的「跟随我俯仰角度」控制（0–8°，默认 2.5°，G4 略大）。
            let maxPitch = gazePitchDegrees * (g4 ? 1.25 : 1.0) * .pi / 180
            let normalized = max(-1, min(1, (gazeY - 0.65) / 0.35))
            let pitch = normalized * maxPitch
            gy = abs(pitch) < 0.006 ? 0 : pitch
        } else if calm, gazeEnabled {
            let recent = CACurrentMediaTime() - gazeLastSeen < 3
            if recent {
                // 刚走开：慢慢回正，头还在回味
                gx = 0; gy = 0
            } else if mood.near, let p = face.pointer {
                // 摄像头一段时间没看到人（走出视野）：退回鼠标跟随，俯仰同样受滑杆限制
                let pitchScale = gazePitchDegrees / 2.5
                gx = max(-1, min(1, p.x)) * 0.1 * sunflower
                gy = max(-1, min(1, p.y)) * 0.06 * sunflower * pitchScale
            } else {
                // 一个人待着：头保持安静，偶尔的一瞥交给眼睛（Face.nextGlance）。
                // Mark View 的原则：弹簧落定后就停，不在稳态继续晃。
                gx = 0; gy = 0
            }
        } else if calm, mood.near, let p = face.pointer {
            gx = max(-1, min(1, p.x)) * 0.1 * sunflower; gy = max(-1, min(1, p.y)) * 0.06 * sunflower
        }
        let k: CGFloat = (2 * .pi / 0.6) * (2 * .pi / 0.6), c: CGFloat = 2 * sqrt(k)
        lookVX += ((gx - lookX) * k - lookVX * c) * dt; lookX += lookVX * dt
        // 整机朝向：窗口在显示器哪边就朝中央；看到人就转向人（扣掉摄像头与桌宠之间的视差）
        var baseline = 0.0
        if let ox = Self.windowXOverride {
            baseline = Aim.baseline(windowMidX: ox, screenMidX: 0.5, screenHalfWidth: 0.5)
        } else if let w = window, let vis = (w.screen ?? NSScreen.main)?.visibleFrame {
            baseline = Aim.baseline(windowMidX: Double(w.frame.midX), screenMidX: Double(vis.midX),
                                    screenHalfWidth: Double(vis.width / 2))
        }
        let aimMode: ViewMode = isApart ? .front : viewMode
        let following = gazeEnabled && gazeShouldRun && !isApart && lockedFace == nil
        let ay = aim.step(now: now, dt: Double(dt), mode: aimMode, following: following, present: gazePresent,
                          gazeX: Double(gazeX), baseline: baseline, maxDegrees: followDegrees)
        model.setAim(yaw: Float(ay))
        // 正面固定：拖转、滑动都可以，放手 0.6 s 后弹回正面
        if viewMode == .front, !touring, !isApart, drag == .none,
           now - lastRotScroll > 0.6, now - lastDragEndAt > 0.6 {
            let full = 2 * CGFloat.pi
            let home = (yaw / full).rounded() * full
            if abs(ty - home) > 0.0005 || abs(tp - 0.12) > 0.0005 { ty = home; tp = 0.12 }
        }
        lookVY += ((gy - lookY) * k - lookVY * c) * dt; lookY += lookVY * dt
        // 机身不歪头；俯仰只保留上面那一点点（明显起身/凑近才动），
        // 大部分上下和表情交给眼睛——Mac 是效率工具，不做云台式抢注意力。
        press += (pressTarget - press) * (1 - exp(-dt / 0.05))
        bob = lockedFace == nil ? 0.05 * CGFloat(sin(now * 2 * .pi / 4.5)) : 0
        model.setIdle(press: press, bob: bob)
    }

    /// 菜单开关：关掉时把追人状态清干净，让机器回正。
    func setGazeEnabled(_ on: Bool) {
        gazeEnabled = on
        gazeHeadOn = false
        if !on {
            gazePresent = false
            gazeWasPresent = false
            gazeX = 0; gazeY = 0; gazeRoll = 0; gazeSize = 0
        }
        log("gaze follow \(on ? "on" : "off")")
    }

    /// 追人现在是否该让摄像头跑着：开关开着、不在直播、机身没被遮住、没锁屏。
    /// 2026-10-22 起 CarPlay 直播时也跟随（Aaron 定案）；锁屏、屏幕睡眠、被完全挡住时照旧暂停。
    var gazeShouldRun: Bool { gazeEnabled && !occluded && !screenLocked }
    var isScreenLocked: Bool { screenLocked }

    /// 摄像头的人脸样本（主线程）。第一次看到人时点一下头，像注意到你。
    func applyGaze(_ s: GazeTracker.Sample) {
        if s.present {
            gazePresent = true
            gazeX = s.x; gazeY = s.y; gazeRoll = s.roll; gazeSize = s.size
            gazeLastSeen = CACurrentMediaTime()
            if !gazeWasPresent {
                gazeWasPresent = true
                gazeHeadOn = false
                // 错峰：眼睛先到（Face.pointer 每帧更新、14/s 追过去），
                // 头随后（0.6 s 弹簧），落定前再点一下头、补一个眨眼。
                mood.show(.surprised, for: 0.3, now: CACurrentMediaTime())
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) { [weak self] in
                    guard let self, self.gazePresent else { return }
                    self.nod()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.58) { [weak self] in
                    guard let self, self.gazePresent else { return }
                    self.face.blinkSoon()
                }
                log(String(format: "gaze acquired x=%.2f y=%.2f roll=%.2f", s.x, s.y, s.roll))
            }
        } else if gazeWasPresent {
            gazeWasPresent = false
            gazePresent = false
            gazeHeadOn = false
            face.blinkSoon(after: 0.12)
            log("gaze lost")
        }
    }

    private func watchPointer() {
        guard !occluded, let win = window, win.isVisible else { return }
        let now = CACurrentMediaTime(), hour = Calendar.current.component(.hour, from: Date())
        let m = NSEvent.mouseLocation, f = win.frame
        let dx = max(f.minX - m.x, 0, m.x - f.maxX), dy = max(f.minY - m.y, 0, m.y - f.maxY)
        let dist = hypot(dx, dy)
        let gazeHere = gazeEnabled && gazePresent
        let gazeRecent = gazeEnabled && CACurrentMediaTime() - gazeLastSeen < 3
        mood.near = gazeHere || gazeRecent || dist <= 120
        if mood.near { lastNear = now }
        if carVideo.active, dist <= 0 {   // 游標在桌寵上：影片控制列浮出
            carVideo.controlsUntil = max(carVideo.controlsUntil, now + 1.5)
        }
        // 游標進到視窗裡＝馬上可能要拖／捏：先把 3D 掛上，第一下手勢就不用等 30–40 ms 的掛載
        if dist <= 4 {
            pointerInsideAt = now
            if onDemand3D, !attached3D, !posterActive { attach3D() }
        }
        if posterActive, mood.near || gazeEnabled { endPoster() }
        // 靠近就多显示：240 pt 外收起，20 pt 内全展开；摄像头看到人时直接全开
        face.revealTarget = gazeHere ? 1
            : (gazeRecent ? max(face.revealTarget, 0.65)
               : (forceNear ? 1 : max(0, min(1, 1 - (dist - 20) / 220))))
        face.flowActive = mood.near && face.expression != .asleep
        if mood.near { mood.activity(now: now, hour: hour) }
        if gazeHere {
            face.pointer = CGPoint(x: max(-1, min(1, gazeX)), y: max(-1, min(1, gazeY)))
        } else if dist > 120, let v = AirPlayWatch.videoCenter {
            // Mac 正在用 AirPlay 播影片：游標不在身邊時，眼睛看著那個影片視窗
            face.pointer = CGPoint(x: max(-1, min(1, (v.x - f.midX) / (f.width * 1.6))), y: max(-1, min(1, -(v.y - f.midY) / (f.height * 1.6))))
        } else {
            face.pointer = CGPoint(x: (m.x - f.midX) / (f.width * 0.6), y: -(m.y - f.midY) / (f.height * 0.6))
        }
        var onStand = false
        if f.contains(m), drag == .none {
            let p = convert(win.convertPoint(fromScreen: m), from: nil)
            onStand = hitsModel(p) && screenUV(p) == nil
        }
        mood.petting(onStand, now: now)
    }

    // 稿里的两个默认角度：组好时 0.52，拆开时转到 1.08 侧看，九件才不会叠在一条视线上。
    // 用户自己转过就不再替他转。
    private var atHome = true
    private static let homeYaw: CGFloat = 0.52, apartYaw: CGFloat = 1.0, homePitch: CGFloat = 0.26
    /// 挂墙时镜头的竖直取景（cm）：屏幕模组外框约 14.4 cm，四周各留约 5% 的边
    static let wallFitH: Float = 16.6
    func setApart(_ on: Bool) {
        if on, viewMode == .wall { return }   // 挂墙没有底座可拆
        apartTarget = on ? 1 : 0
        if on { mood.apart = true }      // 组回到位才放下（见 step）
        else { pinnedPart = nil; hoverPart = nil }
        reassembling = !on
        mood.activity(now: CACurrentMediaTime(), hour: Calendar.current.component(.hour, from: Date()))
        if atHome {
            var y = on ? Self.apartYaw : Self.homeYaw
            while y - yaw > .pi { y -= 2 * .pi }
            while y - yaw < -.pi { y += 2 * .pi }
            ty = y; tp = Self.homePitch
        }
        log("explode \(on ? "on" : "off")")
    }
    var isApart: Bool { apartTarget > 0.5 }

    func showVideo(_ on: Bool) {
        if on, posterActive { endPoster() }
        guard on != showingVideo else { return }
        showingVideo = on
        onVideoState?(on)
        // 直播时摄像头照常跑（跟随我在 CarPlay 里也转向你）；只有确实可见、没锁屏才恢复
        if gazeEnabled || roomLightEnabled, !occluded, !screenLocked {
            GazeTracker.shared.setPaused(false)
        }
        log("screen \(on ? "live" : "face")")
        // 直播期间 face.tick 停着：先收掉总览和待触发的长按，连线盖板按当下状态重设，免得切回来闪一下旧状态
        if on { if face.inOverview { _ = face.endOverview(confirm: false) }; FaceOverview.pressToken += 1; FaceOverview.swallowUp = false; face.dismissOnboarding() }
        CarPlayOverlayState.alpha = face.carPlayConnecting && !on ? 1 : 0
        if !on {
            decoder.reset()
            model.setScreen(face.render())
        }
    }

    // MARK: 命中

    /// 屏幕四个角在视图里的投影（左下原点），顺序：左上、右上、右下、左下。
    /// 用单应变换把点击映射回屏幕 UV；比 raycast 更稳，也不会被边框挡住。
    private func screenCorners() -> [CGPoint] {
        let a = model.screenAnchor
        let pts = [SIMD3<Float>(-6.27, 6.27, 0), SIMD3<Float>(6.27, 6.27, 0),
                   SIMD3<Float>(6.27, -6.27, 0), SIMD3<Float>(-6.27, -6.27, 0)]
        return pts.compactMap { render.project(a.convert(position: $0, to: nil)) }
    }
    /// 屏幕正面是否朝向相机（背面不接触控）
    private func screenFacingCamera() -> Bool {
        let m = model.screenAnchor.transformMatrix(relativeTo: nil)
        let n = simd_normalize(SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        guard let cam = cameraEntity else { return true }
        let eye = cam.position(relativeTo: nil)
        let center = model.screenAnchor.position(relativeTo: nil)
        return simd_dot(n, eye - center) > 0
    }
    /// 点到的屏幕 uv（0..1，左上原点）
    private func screenUV(_ p: NSPoint) -> CGPoint? {
        guard screenFacingCamera() else { return nil }
        let c = screenCorners()
        let unit = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        guard c.count == 4, let inv = homography(from: c, to: unit) else { return nil }
        let q = applyHomography(inv, p)
        guard q.x >= 0, q.x <= 1, q.y >= 0, q.y <= 1 else { return nil }
        return CGPoint(x: q.x, y: q.y)
    }
    /// 机身碰触（RealityKit 的不可见碰撞盒）
    private func hitsModel(_ p: NSPoint) -> Bool {
        !render.hitTest(p, query: .nearest, mask: .all).isEmpty
    }
    private func local(_ e: NSEvent) -> NSPoint { convert(e.locationInWindow, from: nil) }
    private func inResizeCorner(_ p: NSPoint) -> Bool {
        let g = max(16, bounds.width * 0.09)
        return p.x > bounds.width - g && p.y < g    // NSView 不翻转：右下角 y 小
    }

    /// 屏幕上的点 → 发给接收器的 0..1（扣掉留黑）
    private func videoPoint(_ p: NSPoint) -> (Double, Double)? {
        guard let uv = screenUV(p), let (u, v) = CornerFit.shared.toVideo(u: Double(uv.x), v: Double(uv.y)) else { return nil }
        let s = decoder.size
        return screenToVideo(u: u, v: v, videoW: Double(s.width), videoH: Double(s.height))
    }
    /// 「正在播放」胶囊带：屏幕下缘约三分之一（uv.y>0.68）；胶囊活跃时点／滚在这里＝媒体控制
    private func capsuleHit(_ p: NSPoint) -> Bool {
        guard let uv = screenUV(p) else { return false }
        return uv.y > 0.68 && uv.x > 0.04 && uv.x < 0.96
    }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        endPoster()
        // 非激活面板收不到捏合/旋转这类手势事件：点一下就把 App 激活并把窗口立为 key
        // （makeKey 而不是只激活 App——面板只有成为 key window 才开始收手势）。
        // 之后双指张合、三指拖移、键盘快捷键都能用；点别的 App 就自然让出焦点。
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        if window?.isKeyWindow == false { window?.makeKey() }
        lastNear = CACurrentMediaTime()
        hotUntil = CACurrentMediaTime() + 0.4
        if ProcessInfo.processInfo.environment["PET_PROBE"] != nil {
            let probePoint = local(event)
            if let uv = screenUV(probePoint) { log(String(format: "click uv=(%.3f,%.3f)", uv.x, uv.y)) }
            else { log("click body hit=\(hitsModel(probePoint))") }
        }
        // 权限说明卡在屏幕上时，屏幕上的点击都归卡片（按钮：继续／以后／打开系统设置）
        if PermissionPrimer.visible, !showingVideo {
            if let uv = screenUV(local(event)) { drag = .none; PermissionPrimer.press(x: uv.x * 1024, y: uv.y * 1024); face.forceDirty = true; return }
        }
        if overviewMouseDown(event, uv: screenUV(local(event))) { return }   // 长按换錶面总览
        if face.onboardingActive {   // 第一次的操作提示：点一下收起（并取消刚排上的长按）
            face.dismissOnboarding(); FaceOverview.pressToken += 1; FaceOverview.pressAt = nil; return
        }
        let p = local(event)
        if face.bannerShowing && !showingVideo { face.dismissBanner(); return }   // 点一下收起「时间到了」
        // System 6 錶面：单击屏幕（没拖、也不是双击）才打开 AI System 6，放手后等过双击间隔再开
        system6Pending = face.style == .system6 && face.system6Layout == .finder && !showingVideo && event.clickCount == 1 && screenUV(p) != nil
        if event.clickCount >= 2 { system6Token += 1 }
        if event.modifierFlags.contains(.command) {
            let before = window?.frame.origin
            window?.performDrag(with: event)   // 拖完才回來
            if let before, window?.frame.origin != before { MoveHint.noteMoved() }
            return
        }
        if inResizeCorner(p) {
            drag = .resize; winStart = window?.frame ?? .zero; mouseStart = NSEvent.mouseLocation; return
        }
        // 系統三指拖動合成的滑鼠拖拽：觸控板上真的有三指時，整個桌寵都是搬視窗（直播屏幕也一樣）。
        // 拿不到觸控幀（私有框架不可用）就退回舊判斷：開了三指拖動就把拖拽當搬視窗。
        let threeFingers = Self.systemThreeFingerDrag
            && (TrackpadPinch.shared.available ? TrackpadPinch.shared.fingerCount >= 3 : true)
        if threeFingers {
            if !showingVideo, hitsModel(p) { pressTarget = 0.975 }
            drag = .move; winStart = window?.frame ?? .zero; mouseStart = NSEvent.mouseLocation
            rotateMoved = false
            appendDiag("gesture.log", "three-finger drag (system) start")
            return
        }
        // CarPlay 影片在播：螢幕上的點擊給影片控制列（不送到手機）；雙擊放大／收回
        if carVideo.active, let uv = screenUV(p) {
            if event.clickCount == 2 { carVideo.toggleBig(near: window?.frame) }
            else { _ = carVideo.click(u: uv.x, v: uv.y, windowFrame: window?.frame) }
            drag = .none
            return
        }
        // 直播時只有屏幕平面屬於 CarPlay；邊框／機身仍然可以搬窗口
        if showingVideo, let uv = screenUV(p) {
            drag = .touch
            if let (x, y) = videoPoint(p) {
                log(String(format: "touch down uv=(%.3f,%.3f) → video=(%.4f,%.4f)", uv.x, uv.y, x, y))
                onTouch?(x, y, true)
            }
            return
        }
        let now = CACurrentMediaTime()
        mood.activity(now: now, hour: Calendar.current.component(.hour, from: Date()))
        let onStand = hitsStand(p)
        if hitsModel(p) { pressTarget = 0.975; if !onStand, mood.poke(now: now) { shake(now) } }
        dragVel = 0; lastDragT = event.timestamp
        if event.clickCount == 2, hitsModel(p) { resetOrientation(); drag = .none; return }
        // 拖底座＝搬窗口（不用按 ⌘）；螢幕和鉸鏈以上照舊轉身體
        if onStand {
            touring = false
            drag = .move; winStart = window?.frame ?? .zero; mouseStart = NSEvent.mouseLocation
            rotateMoved = false
            appendDiag("gesture.log", "stand drag start")
            return
        }
        drag = .rotate; last = p; rotateMoved = false; rotateTravel = 0; rotLock.reset(); touring = false
    }

    override func mouseDragged(with event: NSEvent) {
        lastNear = CACurrentMediaTime()
        hotUntil = CACurrentMediaTime() + 0.4
        if overviewMouseDragged(event) { return }   // 总览里不转身体
        let p = local(event)
        switch drag {
        case .resize:
            let now = NSEvent.mouseLocation
            let w = max(Pet.minWidth, min(Pet.maxWidth, winStart.width + (now.x - mouseStart.x)))
            let h = w / Pet.aspect
            window?.setFrame(NSRect(x: winStart.minX, y: winStart.maxY - h, width: w, height: h), display: true)
            updateFaceScale()
        case .rotate:
            let dx = p.x - last.x, dy = p.y - last.y; last = p
            rotateTravel += abs(dx) + abs(dy)
            // 单轴锁：起手判主轴（左右＝偏航、上下＝俯仰），被锁的轴不动
            let (lx, ly) = rotLock.pass(dx: dx, dy: dy)
            atHome = false
            // 记下转动速度（低通），放手时用来投射惯性（锁在俯仰上就没有偏航惯性）
            let dtt = max(0.004, event.timestamp - lastDragT); lastDragT = event.timestamp
            dragVel = dragVel * 0.6 + (-lx * 0.009 / CGFloat(dtt)) * 0.4
            // 被抓起来的那一下：惊讶 0.4 s
            if !rotateMoved { rotateMoved = true; mood.show(.surprised, for: 0.4, now: CACurrentMediaTime()) }
            ty -= lx * 0.009
            tp = max(-0.15, min(1.42, tp - ly * 0.006))
        case .touch:
            if let (x, y) = videoPoint(p) { onTouch?(x, y, true) }
        case .move:
            let now = NSEvent.mouseLocation
            let dx = now.x - mouseStart.x, dy = now.y - mouseStart.y
            if abs(dx) > 2 || abs(dy) > 2 { rotateMoved = true }
            guard let win = window else { return }
            // 搬窗口允許跨屏（x/y 都不夾），鬆手後只把「完全跑出所有屏幕」的情況救回來
            win.setFrameOrigin(NSPoint(x: winStart.minX + dx, y: winStart.minY + dy))
        case .none: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        lastDragEndAt = CACurrentMediaTime()
        if PermissionPrimer.tracking {
            let uv = screenUV(local(event))
            PermissionPrimer.release(x: uv.map { $0.x * 1024 }, y: uv.map { $0.y * 1024 })
            face.forceDirty = true
            return
        }
        if overviewMouseUp(event, uv: screenUV(local(event))) { drag = .none; pressTarget = 1; system6Pending = false; return }
        let p = local(event)
        switch drag {
        case .resize:
            endResize()
        case .touch:
            if let (x, y) = videoPoint(p) {
                log(String(format: "touch up video=(%.4f,%.4f)", x, y))
                onTouch?(x, y, false)
            } else { onTouch?(-1, -1, false) }
        case .rotate where !rotateMoved && anatomyActive:
            // 拆開時點一下零件＝釘住它的標籤；點同一件或空白處＝放開
            system6Pending = false; system6Token += 1
            let hit = pickAnatomy(p)?.0
            pinnedPart = hit == pinnedPart ? nil : hit
            updateAnatomyCallout(CACurrentMediaTime())
            log("anatomy pin \(pinnedPart?.rawValue ?? "none")")
        case .rotate where !rotateMoved && !showingVideo && capsuleHit(p):
            // 「正在播放」胶囊上点一下＝播放／暂停（控正在显示的那家：Music 或 Spotify）
            NowPlayingPoller.shared.control(.playPause)
        case .rotate where !rotateMoved && system6Pending:
            system6Pending = false; system6Token += 1
            let token = system6Token
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval) { [weak self] in
                guard let self, self.system6Token == token, let url = URL(string: "https://system6.aaronlau.me") else { return }
                NSWorkspace.shared.open(url); log("open AI System 6")
            }
        case .move:
            if !rotateMoved {
                // 三指拖移机器上的「点一下」：保留摸头等点击语义（直播中不打扰）
                if !showingVideo, hitsModel(p) { mood.show(.happy, for: 1.0, now: CACurrentMediaTime()) }
            } else if let w = window {
                MoveHint.noteMoved()
                log("moved \(Int(w.frame.minX)),\(Int(w.frame.minY))")
                if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(w.frame) }) {
                // 整个拖出屏幕：拉回主屏
                if let vf = NSScreen.main?.visibleFrame {
                    w.setFrameOrigin(NSPoint(x: vf.maxX - w.frame.width - 24, y: vf.minY + 24))
                }
                }
            }
        case .rotate where rotateMoved:
            mood.show(.happy, for: 1.2, now: CACurrentMediaTime())   // 放下：笑一下
            // 拖機身是轉身體；一路拖到窗外（或拖很遠）兩次，多半其實想搬走它：提示一次怎麼搬
            if MoveHint.shouldOffer, let w = window,
               moveHint.rotateDragEnded(now: CACurrentMediaTime(), leftWindow: !w.frame.contains(NSEvent.mouseLocation),
                                        travel: Double(rotateTravel), width: Double(w.frame.width)) {
                MoveHint.show(near: w)
                appendDiag("gesture.log", "move hint shown")
            }
            // 甩出去：照 Apple 的动量投射（减速率 0.995），目标往前推，弹簧接着当前速度转过去
            if event.timestamp - lastDragT < 0.08 { ty += max(-.pi, min(.pi, dragVel * 0.2)) }
            rotLock.reset()        default: break
        }
        drag = .none; pressTarget = 1
    }

    // MARK: 触控板 / Magic Mouse 手势
    // 捏合＝放大缩小（像 PiP，锁比例，以窗口中心为锚）；两指旋转＝偏航转身体；
    // 两指滑（触控板）／单指滑（Magic Mouse）＝转动身体，单轴锁：起手判主轴，只走左右或上下，带系统惯性；
    // 智能缩放（触控板两指轻点两下）＝拆开／组回；轻扫（MM 双指／触控板三指）＝左右转一圈、上回正、下拆组；
    // 普通滚轮＝一格一格缩放。

    func resizeWindow(toWidth w0: CGFloat, anchorCenter: Bool) {
        guard let win = window else { return }
        let f = win.frame
        let w = max(Pet.minWidth, min(Pet.maxWidth, w0)), h = w / Pet.aspect
        let origin = anchorCenter ? NSPoint(x: f.midX - w / 2, y: f.midY - h / 2) : NSPoint(x: f.minX, y: f.maxY - h)
        win.setFrame(clampToScreen(NSRect(origin: origin, size: NSSize(width: w, height: h))), display: true)
        // 捏合到最小/最大时给一次对齐反馈（只在刚碰界那一下，不连发）
        let limit: CGFloat? = w == Pet.minWidth ? Pet.minWidth : (w == Pet.maxWidth ? Pet.maxWidth : nil)
        if limit != nil, limit != limitHaptic {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        limitHaptic = limit
    }

    /// 缩放动画版（菜单/快捷键走这条）：0.18s 缓出，窗口保持在屏幕内
    func resizeWindowAnimated(toWidth w0: CGFloat) {
        guard let win = window else { return }
        let f = win.frame
        let w = max(Pet.minWidth, min(Pet.maxWidth, w0)), h = w / Pet.aspect
        let target = clampToScreen(NSRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h))
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            win.animator().setFrame(target, display: true)
        })
    }

    /// 把窗口钳回屏幕（找中心所在的屏，没有就用主屏）
    private func clampToScreen(_ r: NSRect) -> NSRect {
        let screens = NSScreen.screens
        let containing = screens.first { NSMouseInRect(NSPoint(x: r.midX, y: r.midY), $0.frame, false) }
            ?? screens.first { NSIntersectsRect(r, $0.frame) }
            ?? NSScreen.main
        guard let visible = containing?.visibleFrame else { return r }
        var out = r
        if out.maxX > visible.maxX { out.origin.x = visible.maxX - out.width }
        if out.minX < visible.minX { out.origin.x = visible.minX }
        if out.maxY > visible.maxY { out.origin.y = visible.maxY - out.height }
        if out.minY < visible.minY { out.origin.y = visible.minY }
        return out
    }

    // MARK: 缩放与回正（菜单/快捷键/双击共用）

    func zoom(by factor: CGFloat) { resizeWindowAnimated(toWidth: bounds.width * factor) }
    func setZoom(width: CGFloat) { resizeWindowAnimated(toWidth: width) }
    /// 一键最大：屏高的 85%（锁比例），不超过上限
    func zoomMax() {
        let vh = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 900
        setZoom(width: min(Pet.maxWidth, vh * 0.85 * Pet.aspect))
    }

    /// 双击：转正回主视角（走最短路径的弹簧动画），拆开状态先组回来
    func resetOrientation() {
        touring = false
        if isApart { setApart(false) }
        atHome = true
        var y = Self.homeYaw
        while y - yaw > .pi { y -= 2 * .pi }
        while y - yaw < -.pi { y += 2 * .pi }
        ty = y; tp = Self.homePitch
        mood.show(.wink, for: 0.6, now: CACurrentMediaTime())
        log("gesture reset-orientation")
    }

    // MARK: 拆開看看：零件標籤（滑過顯示、點一下釘住、自動環繞時依序介紹）

    private let callout = AnatomyCallout()
    private var hoverPart: AnatomyPart?
    private var pinnedPart: AnatomyPart?
    private var tourIndex = -1, tourNext = 0.0
    /// 拆得夠開（外面幾層已經到位）才接受挑零件
    private var anatomyActive: Bool { apartT > 0.4 && !showingVideo }

    /// 這個點（視圖座標）底下是哪一件
    /// 點在底座那一截（不在螢幕上、真的打到機身、拆開看看時不算）
    private func hitsStand(_ p: NSPoint) -> Bool {
        guard !anatomyActive, screenUV(p) == nil, hitsModel(p), let part = pickAnatomy(p)?.0 else { return false }
        return Self.standAnatomy.contains(part)
    }
    private func pickAnatomy(_ p: NSPoint) -> (AnatomyPart, SIMD3<Float>)? {
        guard let ray = render.ray(through: p) else { return nil }
        return model.pickAnatomy(origin: ray.origin, direction: ray.direction)
    }

    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a); hoverArea = a
    }
    override func mouseMoved(with event: NSEvent) {
        guard anatomyActive, drag == .none else { return }
        let hit = pickAnatomy(local(event))?.0
        if hit != hoverPart { hoverPart = hit; updateAnatomyCallout(CACurrentMediaTime()) }
    }
    override func mouseExited(with event: NSEvent) {
        if hoverPart != nil { hoverPart = nil; updateAnatomyCallout(CACurrentMediaTime()) }
    }

    /// 每拍跟著模型更新標籤：釘住的 > 滑過的 > 自動環繞輪到的
    private func updateAnatomyCallout(_ now: Double) {
        var part: AnatomyPart?
        if anatomyActive {
            if touring, now >= tourNext {
                tourIndex = (tourIndex + 1) % AnatomyPart.tourOrder.count
                tourNext = now + 2.6
            }
            part = pinnedPart ?? hoverPart ?? (touring && tourIndex >= 0 ? AnatomyPart.tourOrder[tourIndex] : nil)
        }
        let eye = cameraEntity?.position(relativeTo: nil) ?? SIMD3<Float>(0, 10, 100)
        guard let part, let w = model.anatomyAnchor(part, eye: eye), let pt = render.project(w) else {
            if !callout.isHidden { callout.isHidden = true; callout.part = nil }
            return
        }
        callout.part = part
        callout.anchor = pt
        callout.opacity = clamp01((apartT - 0.4) / 0.12)
        callout.isHidden = false
    }

    /// 快照用：拆開程度直接到位（--apart-t），不走彈簧
    func setInitialApart(_ t: CGFloat) {
        apartTarget = t; apartT = t; apartV = 0
        mood.apart = t > 0.5
        if atHome { yaw = Self.apartYaw; ty = yaw }
        model.apply(t)
    }
    /// 快照／除錯用：直接釘住一件的標籤
    func pinAnatomy(_ part: AnatomyPart) { pinnedPart = part }

    /// 快照疊上零件標籤（RealityKit 快照只有 3D）
    func compositeOverlays(_ img: CGImage) -> CGImage {
        guard !callout.isHidden, callout.part != nil,
              let rep = callout.bitmapImageRepForCachingDisplay(in: callout.bounds) else { return img }
        callout.cacheDisplay(in: callout.bounds, to: rep)
        guard let over = rep.cgImage else { return img }
        // 不用 makeImage：它翻成左上原點，CGImage 會畫倒
        guard let g = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        let r = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        g.draw(img, in: r); g.draw(over, in: r)
        return g.makeImage() ?? img
    }

    // MARK: 预设机位（照 homeview-anatomy.vercel.app 的 Front/Side/Back/Above）＋自动环绕

    /// 预设机位：走最短路径的弹簧转向。yaw 传 nil＝保持现在的朝向只改俯仰。
    func setView(yaw targetYaw: CGFloat?, pitch targetPitch: CGFloat, label: String) {
        touring = false
        atHome = false
        if let targetYaw {
            var y = targetYaw
            while y - yaw > .pi { y -= 2 * .pi }
            while y - yaw < -.pi { y += 2 * .pi }
            ty = y
        }
        tp = max(-0.15, min(1.42, targetPitch))
        log("view \(label)")
    }
    /// 除錯／CLI 用：走和選單完全相同的預設機位
    func applyViewPreset(_ name: String) {
        switch name {
        case "front": menuViewFront()
        case "side": menuViewSide()
        case "back": menuViewBack()
        case "above": menuViewAbove()
        default: break
        }
    }

    @objc func menuViewFront() { setView(yaw: 0, pitch: 0.12, label: "front") }
    @objc func menuViewMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = ViewMode(rawValue: raw) else { return }
        setViewMode(mode)
    }
    func setViewMode(_ mode: ViewMode) {
        let wasWall = viewMode == .wall
        viewMode = mode
        ViewMode.saved = mode
        if mode == .wall, isApart { setApart(false) }
        if (mode == .wall) != wasWall {
            // 进出挂墙：换掉底座/铰链、窗口比例跟着换（宽度不变），离开时镜头回原本的主视角
            model.setWall(mode == .wall)
            Pet.aspect = Pet.aspect(for: mode)
            if let w = window { resizeWindowAnimated(toWidth: w.frame.width) }
            if wasWall { atHome = true; ty = Self.homeYaw; tp = Self.homePitch }
        }
        if mode == .front { menuViewFront() }
        hotUntil = CACurrentMediaTime() + 0.4
        log("view mode \(mode.rawValue)")
    }
    @objc func menuViewSide() { setView(yaw: .pi / 2, pitch: 0.18, label: "side") }
    @objc func menuViewBack() { setView(yaw: .pi, pitch: 0.15, label: "back") }
    @objc func menuViewAbove() { setView(yaw: nil, pitch: 1.3, label: "above") }

    /// 自动环绕（网站的 auto tour）：慢慢转给人看，任何转动操作都会停下
    private var touring = false
    @objc func menuTour() {
        touring.toggle()
        if touring { atHome = false; tourIndex = -1; tourNext = 0 }
        log("tour \(touring ? "on" : "off")")
    }
    private func endResize() {
        updateFaceScale()
        if let f = window?.frame { log("resize \(Int(f.width))x\(Int(f.height))") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.logProbes() }
    }

    override func magnify(with e: NSEvent) {
        endPoster()
        appendDiag("gesture.log", "local magnify mag=\(e.magnification) phase=\(e.phase.rawValue)")
        // 全局接触帧（TrackpadPinch）已经处理同一次捏合时别双倍缩放
        if CACurrentMediaTime() - TrackpadPinch.shared.lastPinchAt < 0.25 { return }
        // 触控板判定这次不是捏合（是双指滑动或扭转）：不缩放
        if TrackpadPinch.shared.available, TrackpadPinch.shared.twoFingerKind != .pinch { return }
        // 收尾事件常带一段残余值，别在松手时再跳一下
        if e.phase == .ended || e.phase == .cancelled { endResize(); return }
        guard abs(e.magnification) > 0.0001 else { return }
        hotUntil = CACurrentMediaTime() + 0.4
        // 增量语义（Chromium：incremental change values），单帧限幅防大跳
        let factor = min(1.06, max(0.94, 1 + e.magnification))
        resizeWindow(toWidth: bounds.width * factor, anchorCenter: true)
    }
    override func rotate(with e: NSEvent) {
        // 两指旋转手势不再转身体：捏合时手指总会带一点扭转，系统就同时发旋转事件，
        // 结果缩放时身体也跟着转（2026-10-22）。转身体只用双指滑动／拖动。
        return
    }
    override func smartMagnify(with e: NSEvent) { setApart(!isApart) }
    // 三指手势统一给「拖移窗口」（见 touchesBegan/Moved）。轻扫不再占用三指：
    // 转一圈用菜单「外观 › 自动环绕」，回正双击，拆开双指轻点两下。

    // MARK: 三指拖移窗口
    // 触控板只给归一化坐标（0..1，铺满整块触控板），按屏宽比例换算成点：
    // 横跨一次触控板约等于横跨一次屏幕，手感接近直接搬动。
    override func touchesBegan(with event: NSEvent) {
        let t = event.touches(matching: .touching, in: self)
        guard t.count == 3 else { threeFinger = nil; return }
        threeFinger = t.map(\.normalizedPosition)
        pressTarget = 0.98                  // 抓起：轻轻一抬
        log("three-finger drag start")
    }
    override func touchesMoved(with event: NSEvent) {
        guard var base = threeFinger, let w = window else { return }
        let t = event.touches(matching: .touching, in: self)
        guard t.count == 3 else { threeFinger = nil; return }   // 中途少一根手指：结束这次拖移，避免跳
        let p = t.map(\.normalizedPosition)
        var dx: CGFloat = 0, dy: CGFloat = 0
        for (a, b) in zip(p, base) { dx += a.x - b.x; dy += a.y - b.y }
        dx /= 3; dy /= 3
        let scale = (NSScreen.main?.frame.width ?? w.frame.width) * 0.85   // 一次完整横拖 ≈ 0.85 屏宽
        var f = w.frame
        f.origin.x += dx * scale
        f.origin.y += dy * scale                     // 触控板 y 向上＝窗口向上（直接操纵）
        w.setFrameOrigin(clampToScreen(f).origin)
        if abs(dx) + abs(dy) > 0.002 { MoveHint.noteMoved() }
        base = p; threeFinger = base
    }
    override func touchesEnded(with event: NSEvent) { threeFinger = nil; pressTarget = 1 }
    override func touchesCancelled(with event: NSEvent) { threeFinger = nil; pressTarget = 1 }
    override func scrollWheel(with e: NSEvent) {
        endPoster()
        lastNear = CACurrentMediaTime()
        hotUntil = CACurrentMediaTime() + 0.4
        if overviewScroll(e) { return }   // 总览里滚轮／触控板挑錶面，不转身体
        // 「正在播放」胶囊上滚＝上一首／下一首；只在胶囊活跃时占用这条带，其余照旧（转身体／换錶面）
        if !showingVideo, abs(e.scrollingDeltaY) > 0.05, capsuleHit(local(e)), face.musicActive(CACurrentMediaTime()) {
            NowPlayingPoller.shared.control(e.scrollingDeltaY > 0 ? .next : .previous)
            return
        }
        guard e.hasPreciseScrollingDeltas else {
            if e.modifierFlags.contains(.option) {
                // ⌥＋普通滚轮：一格放大／缩小 8%
                let step: CGFloat = e.scrollingDeltaY > 0 ? 1.08 : (e.scrollingDeltaY < 0 ? 1 / 1.08 : 1)
                resizeWindow(toWidth: bounds.width * step, anchorCenter: true); endResize(); return
            }
            // 普通滚轮＝数字表冠：一格换一个錶面（直播时不换）；连续滚太快只算一次
            guard !showingVideo else { return }
            wheelAcc += e.scrollingDeltaY
            let now = CACurrentMediaTime()
            if abs(wheelAcc) >= 1, now - lastFaceSwitch > 0.25 {
                setFaceStyle(face.style.next(wheelAcc > 0 ? -1 : 1))
                lastFaceSwitch = now; wheelAcc = 0
            } else if now - lastFaceSwitch > 0.6 { wheelAcc = max(-1, min(1, wheelAcc)) }
            return
        }
        // ⌥＋雙指滾動（精確滾動）：按比例縮放。滾輪事件只投遞給指針下的窗口，
        // 桌寵自己的窗口先收到，所以縮放必須在這裡做，全局監視等不到這條事件。
        if e.modifierFlags.contains(.option), abs(e.scrollingDeltaY) > 0.01 {
            appendDiag("gesture.log", "local opt-scroll dy=\(e.scrollingDeltaY)")
            resizeWindow(toWidth: bounds.width * (1 + CGFloat(e.scrollingDeltaY) * 0.01), anchorCenter: true)
            return
        }
        // 换成「手指往哪走」，不管自然滚动开没开
        let fx = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
        let fy = e.isDirectionInvertedFromDevice ? -e.scrollingDeltaY : e.scrollingDeltaY
        // 手势在起手时决定归谁，整个手势（含惯性）都锁定：
        // 直播屏幕上起手＝CarPlay 拖；机身上起手＝转身体；透明边＝什么都不做。捏合已确认时滑动让位。
        // 触控板上两指的类型由接触帧判定：还没判定、是捏合或扭转时，这些滚动事件不转身体也不拖 CarPlay。
        //（以前滚动事件一来就转，捏合要等指距变了 2.5% 才确认——捏合开头总会先把身体转一下。）
        if e.momentumPhase.isEmpty, TrackpadPinch.shared.available, TrackpadPinch.shared.holdScroll { return }
        let now = CACurrentMediaTime()
        let began = e.phase == .began
        let target = scrollArb.route(
            now: now, began: began, momentum: !e.momentumPhase.isEmpty,
            ended: e.phase == .ended || e.phase == .cancelled, momentumEnded: e.momentumPhase == .ended,
            dx: Double(fx), dy: Double(fy), pinching: TrackpadPinch.shared.pinching,
            classify: { [unowned self] in self.classifyGesturePoint(self.local(e)) })
        if began || (e.phase.isEmpty && e.momentumPhase.isEmpty && scrollArb.startedAt == now) {
            appendDiag("gesture.log", "scroll begin target=\(target.rawValue)")
        }
        if e.momentumPhase == .ended {
            appendDiag("gesture.log", gestureLogLine("scroll", target: target, momentum: true, duration: now - scrollArb.startedAt))
        }
        switch target {
        case .none: return
        case .carplay: scrollDrag(e, fx: fx, fy: fy); return   // 丢惯性在 scrollDrag 里（CarPlay 自己会甩）
        case .rotate: break
        }
        // 滚轮转动也走单轴锁：phase 有 began 就是新手势；Magic Mouse 常没有 phase，用 0.25 s 时间隔断
        if e.phase == .began || now - lastRotScroll > 0.25 { rotLock.reset() }
        lastRotScroll = now
        let (lx, ly) = rotLock.pass(dx: fx, dy: fy, threshold: 4)
        touring = false
        atHome = false
        ty -= lx * 0.005
        tp = max(-0.15, min(1.42, tp - ly * 0.005))
        if e.phase == .began { log("gesture scroll-rotate") }
    }

    /// 双指滑动的仲裁状态（见 GestureArbiter.swift）
    private(set) var scrollArb = ScrollArbiter()
    /// 起手点归谁：直播屏幕＝CarPlay；机身（逐零件碰撞盒）＝转身体；其余透明区＝不处理。
    /// 不直播时屏幕也是机身的一部分。
    func classifyGesturePoint(_ p: NSPoint) -> GestureTarget {
        if showingVideo, screenUV(p) != nil { return .carplay }
        if hitsModel(p) || screenUV(p) != nil { return .rotate }
        return .none
    }

    // 两指滑拖动的状态：画面坐标里的当前触点 + 闲置抬起计时
    private var scrollTouch: (x: Double, y: Double)?
    private var scrollIdle: Timer?

    private func scrollDrag(_ e: NSEvent, fx: CGFloat, fy: CGFloat) {
        if !e.momentumPhase.isEmpty { return }
        if scrollTouch == nil {
            guard let (x, y) = videoPoint(local(e)) else { return }
            scrollTouch = (x, y); onTouch?(x, y, true)
            log(String(format: "scroll-drag down video=(%.4f,%.4f)", x, y))
        }
        // 手指位移（点）→ 画面 0..1：除以画面在屏幕上的显示宽高
        let span = screenSpanPoints()
        let s = decoder.size
        let fitW = s.width >= s.height ? 1 : s.width / max(1, s.height)
        let fitH = s.width >= s.height ? s.height / max(1, s.width) : 1
        if span > 1, var t = scrollTouch {
            t.x = min(1, max(0, t.x + Double(fx / (span * fitW))))
            t.y = min(1, max(0, t.y - Double(fy / (span * fitH))))
            scrollTouch = t; onTouch?(t.x, t.y, true)
        }
        scrollIdle?.invalidate()
        if e.phase == .ended || e.phase == .cancelled { endScrollDrag() }
        else {
            scrollIdle = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in self?.endScrollDrag() }
        }
    }
    private func endScrollDrag() {
        scrollIdle?.invalidate(); scrollIdle = nil
        guard let t = scrollTouch else { return }
        scrollTouch = nil; onTouch?(t.x, t.y, false)
        log(String(format: "scroll-drag up video=(%.4f,%.4f)", t.x, t.y))
    }
    /// 方屏在视图里的显示边长（点）：把左右两边中点投影出来量距离
    private func screenSpanPoints() -> CGFloat {
        guard let a = render.project(model.screenAnchor.convert(position: SIMD3<Float>(-6.27, 0, 0), to: nil)),
              let b = render.project(model.screenAnchor.convert(position: SIMD3<Float>(6.27, 0, 0), to: nil)) else { return 1 }
        return hypot(b.x - a.x, b.y - a.y)
    }

    /// 方屏 uv → 全局坐标（左上原点，点）。只给验收脚本用（PET_PROBE=1）。
    func logProbes() {
        guard ProcessInfo.processInfo.environment["PET_PROBE"] != nil, let win = window,
              let mainH = NSScreen.screens.first?.frame.height else { return }
        let uvs: [(CGFloat, CGFloat)] = [(0.5, 0.5), (0.25, 0.75), (0.8, 0.3)]
        for (u, v) in uvs {
            let lx = (u - 0.5) * 12.54, ly = (0.5 - v) * 12.54
            guard let p = render.project(model.screenAnchor.convert(position: SIMD3<Float>(Float(lx), Float(ly), 0), to: nil)) else { continue }
            let g = win.convertPoint(toScreen: convert(NSPoint(x: p.x, y: p.y), to: nil))
            let gy: CGFloat = mainH - g.y
            log(String(format: "probe uv=(%.2f,%.2f) at %.1f %.1f", Double(u), Double(v), Double(g.x), Double(gy)))
        }
    }

    // 右键菜单：三组结构——状态动作｜宠物本身（表盘·计时器·拆装·外观）｜收尾（偏好·关于·结束）。
    // 长得快的放外面，难得碰的收子菜单；标题动态反映当前状态；菜单每次打开都重建。
    override func rightMouseDown(with event: NSEvent) {
        endPoster()
        let menu = buildContextMenu()
        var at = convert(event.locationInWindow, from: nil)
        // 菜单只在当前屏幕内展开：贴着屏幕底边时 macOS 会把后面几项折叠起来。
        // 下方放不下、上方放得下就向上展开（Mac 菜单的通常行为）。
        if let screen = window?.screen {
            let mouse = NSEvent.mouseLocation
            let below = mouse.y - screen.visibleFrame.minY
            let above = screen.visibleFrame.maxY - mouse.y
            let h = menu.size.height
            if below < h + 12, above > below { at.y += h }
        }
        startMenuTicker()
        menu.popUp(positioning: nil, at: at, in: self)
        stopMenuTicker()
    }

    private func timerMenuTitle(_ now: Double) -> String {
        var s = face.pomodoro.active ? face.timerLabel : L("timer.title", "计时器")
        if let end = face.timerEnd { s += " · " + timerClock(max(0, end - now)) }
        return s
    }

    /// 菜单打开期间每 0.5 秒刷新倒计时。Timer 放 common + eventTracking 两种模式，
    /// NSMenu 的嵌套 tracking loop 里也能跑；状态栏菜单在桌宠隐藏时同样有效。
    func startMenuTicker() {
        guard menuTicker == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.refreshMenuTimer() }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        RunLoop.main.add(t, forMode: .eventTracking)
        menuTicker = t
        refreshMenuTimer()
    }

    func stopMenuTicker() {
        menuTicker?.invalidate(); menuTicker = nil
    }

    private func refreshMenuTimer() {
        guard let item = liveTimerItem else { return }
        let title = timerMenuTitle(CACurrentMediaTime())
        if item.title != title { item.title = title }
    }

    /// CarPlay 那一項：按真實狀態給動詞（直播中＝退出；已暫停＝繼續；重連中＝重新連接；連線中＝取消）。
    /// 右鍵選單與選單列共用這一份，兩處永遠一致
    var carPlayAction: (title: String, action: Selector, hint: String?, symbol: String) {
        if showingVideo { return (L("menu.exitCarPlay", "退出 CarPlay"), #selector(menuToggleLive), L("menu.hint.liveToggle", "重按或空格"), "car.fill") }
        switch face.status {
        case .connecting: return (L("menu.cancelConnect", "取消连接"), #selector(menuCancelConnect), nil, "xmark.circle")
        case .pausedResume, .paused: return (L("menu.resumeCarPlay", "继续 CarPlay"), #selector(menuToggleLive), L("menu.hint.space", "空格"), "play.fill")
        case .reconnecting: return (L("menu.reconnectCarPlay", "重新连接 CarPlay"), #selector(menuEnterCarPlay), nil, "arrow.clockwise")
        default: return (L("menu.enterCarPlay", "进入 CarPlay"), #selector(menuEnterCarPlay), L("menu.hint.forceClick", "重按"), "car")
        }
    }

    /// 右键菜单（状态栏图标的菜单也復用它，兩处永远一致）
    func buildContextMenu() -> NSMenu {
        CalendarSource.shared.refresh()   // 授权状态可能在系统设置里改过
        let menu = NSMenu()
        // 状态项：按真实状态给动词，而不是一个含糊的「暂停」。
        // 直播中＝退出（同一手势可再进）；已暂停＝继续；重连中＝重新连接；连线中＝取消。
        let cp = carPlayAction
        menu.addItem(menuItem(cp.title, cp.action, hint: cp.hint, symbol: cp.symbol))
        // 配对过两台以上：手机直接列在第一层，打勾的是现在这台，点一下就换（不用进偏好设定）
        let phones = CarPlayPhoneBook.menuEntries()
        if phones.count > 1 {
            for entry in phones {
                let item = menuItem(entry.title, #selector(menuUsePhone(_:)), symbol: "iphone")
                item.representedObject = entry.address
                item.state = entry.current ? .on : .off
                menu.addItem(item)
            }
        }
        // iPhone：連接步驟、Wi-Fi 設定、配對新的、拷貝診斷報告（連線卡上的「右鍵 → iPhone → …」都指這裡）
        let iphone = NSMenu()
        iphone.addItem(menuItem(L("menu.connectSteps", "连接步骤…"), #selector(menuConnectSteps), symbol: "list.number"))
        iphone.addItem(menuItem(L("menu.wifiPassword", "Wi-Fi 设置…"), #selector(menuWiFiPassword), symbol: "wifi"))
        iphone.addItem(menuItem(L("menu.pairNewPhone", "配对新 iPhone…"), #selector(menuPairNewPhone), symbol: "plus.circle"))
        iphone.addItem(.separator())
        iphone.addItem(menuItem(L("menu.copyDiagnostics", "拷贝诊断报告"), #selector(menuCopyDiagnostics), symbol: "doc.on.clipboard"))
        menu.addItem(submenuItem(L("menu.iphone", "iPhone"), iphone, symbol: "iphone"))
        menu.addItem(.separator())

        // 表盘：全部表盘（打勾）、岛表盘样式、表盘总览
        let styles = NSMenu()
        for st in FaceStyle.lineup {
            let item = menuItem(st.title, #selector(menuStyle(_:)), hint: face.style == st ? L("menu.hint.scrollArrows", "滚轮 / ← →") : nil,
                                symbol: Self.faceSymbols[st])
            item.representedObject = st.rawValue; item.state = face.style == st ? .on : .off
            styles.addItem(item)
        }
        styles.addItem(.separator())
        styles.addItem(menuItem(L("prefs.photoFolder", "照片文件夹…"), #selector(menuPhotoFolder),
                                hint: face.photos.folder.lastPathComponent, symbol: "folder"))
        styles.addItem(.separator())
        let islandOptItem = submenuItem(L("menu.islandFace", "岛表盘样式"), islandOptionsMenu(), symbol: "slider.horizontal.3")
        styles.addItem(islandOptItem)
        for i in faceOptionMenuItems() { styles.addItem(i) }   // Typograph 材质／System 6 版式（FaceOptions.swift）
        styles.addItem(menuItem(L("clockLook.menu", "字体与颜色…"), #selector(menuClockLook(_:)), symbol: "textformat.size"))
        styles.addItem(menuItem(L("menu.faceOverview", "表盘总览…"), #selector(menuFaceOverview), hint: L("menu.hint.longPress", "长按屏幕"),
                                symbol: "square.grid.3x3"))
        menu.addItem(submenuItem(L("menu.faces", "表盘"), styles, symbol: "clock"))

        // 计时器：跑的时候标题显示剩余时间，多一项取消
        let timers = NSMenu()
        if face.pomodoro.active {
            timers.addItem(menuItem(L("pomodoro.stop", "停止番茄钟"), #selector(menuPomodoroStop), symbol: "stop.circle"))
        } else {
            timers.addItem(menuItem(L("pomodoro.start", "番茄钟（25 + 5 分钟）"), #selector(menuPomodoroStart), symbol: "leaf"))
        }
        let today = Pomodoro.todayCount
        if today > 0 {
            let done = NSMenuItem(title: String(format: L("pomodoro.today", "今天完成 %d 个"), today), action: nil, keyEquivalent: "")
            done.isEnabled = false; timers.addItem(done)
        }
        timers.addItem(.separator())
        for m in [1.0, 3, 5, 10, 25] {
            let item = menuItem(String(format: L("timer.minutes", "%d 分钟"), Int(m)), #selector(menuTimer(_:)), symbol: "timer")
            item.representedObject = m
            if face.timerEnd != nil, !face.pomodoro.active, abs(face.timerTotal - m * 60) < 0.5 { item.state = .on }
            timers.addItem(item)
        }
        if face.timerEnd != nil {
            timers.addItem(.separator())
            timers.addItem(menuItem(L("timer.cancel", "取消计时器"), #selector(menuTimerCancel), symbol: "xmark.circle"))
        }
        let timerItem = submenuItem(timerMenuTitle(CACurrentMediaTime()), timers, symbol: "timer")
        liveTimerItem = timerItem
        menu.addItem(timerItem)

        menu.addItem(menuItem(isApart ? L("menu.apart.putBack", "组回来") : L("menu.apart.takeApart", "拆开看看"),
                              viewMode == .wall ? nil : #selector(menuApart),   // 挂墙没有底座可拆：灰掉
                              hint: L("menu.hint.twoFingerTap", "两指轻点两下"), symbol: isApart ? "cube" : "cube.transparent"))
        // 跟随我：最常开关的一项放在第一层（设置里有完整说明）
        let follow = menuItem(L("prefs.gaze", "跟随我（相机）"), #selector(menuGazeToggle), symbol: "viewfinder")
        follow.state = gazeEnabled ? .on : .off
        menu.addItem(follow)

        // 外观：机身配色 · 视角 · 大小——都关「长什么样」，收进同一个子菜单
        let looks = NSMenu()
        looks.addItem(NSMenuItem.sectionHeader(title: L("settings.finish", "配色")))
        for f in Finish.allCases {
            let item = menuItem(f.title, #selector(menuFinish(_:)))
            item.image = finishSwatch(f)
            item.representedObject = f.rawValue
            item.state = model.finish == f ? .on : .off
            looks.addItem(item)
        }
        looks.addItem(.separator())
        looks.addItem(NSMenuItem.sectionHeader(title: L("settings.facing", "朝向")))
        // 朝向：自动（窗口在哪边就朝中央、开了跟随就转向人）／正面固定（永远正对、不倾斜）
        for mode in ViewMode.allCases {
            let title: String, symbol: String
            switch mode {
            case .auto: title = L("menu.view.auto", "自动朝向（窗口位置 + 跟随）"); symbol = "arrow.left.arrow.right"
            case .front: title = L("menu.view.fixedFront", "正面固定（不倾斜）"); symbol = "rectangle"
            case .wall: title = L("menu.view.wall", "挂墙（只有屏幕）"); symbol = "photo.artframe"
            }
            let item = menuItem(title, #selector(menuViewMode(_:)), symbol: symbol)
            item.representedObject = mode.rawValue
            item.state = viewMode == mode ? .on : .off
            looks.addItem(item)
        }
        looks.addItem(.separator())
        looks.addItem(NSMenuItem.sectionHeader(title: L("settings.angle", "视角")))
        // 视角：当前机位打勾（拖过之后就不勾任何一项）
        let viewPresets: [(String, Selector, String, CGFloat, CGFloat)] = [
            (L("menu.view.front", "正面"), #selector(menuViewFront), "1", 0, 0.12),
            (L("menu.view.side", "侧面"), #selector(menuViewSide), "2", .pi / 2, 0.18),
            (L("menu.view.back", "背面"), #selector(menuViewBack), "3", .pi, 0.15),
            (L("menu.view.top", "俯视"), #selector(menuViewAbove), "4", .nan, 1.3),
        ]
        let presetSymbols = ["square", "square.lefthalf.filled", "square.dashed", "square.tophalf.filled"]
        for (i, (title, sel, key, vy, vpitch)) in viewPresets.enumerated() {
            let item = menuItem(title, viewMode == .wall ? nil : sel, key: key, symbol: presetSymbols[i])   // 挂墙不转：灰掉
            let yawMatches = vy.isNaN || abs(ty - vy) < 0.02
            if !touring, yawMatches, abs(tp - vpitch) < 0.02 { item.state = .on }
            looks.addItem(item)
        }
        let tour = menuItem(L("menu.view.tour", "自动环绕"), viewMode == .wall ? nil : #selector(menuTour), symbol: "rotate.3d")
        tour.state = touring ? .on : .off
        looks.addItem(tour)
        looks.addItem(menuItem(L("menu.resetAngle", "回正"), #selector(menuResetOrientation), hint: L("menu.hint.doubleClick", "双击机身"),
                               symbol: "arrow.counterclockwise"))
        looks.addItem(.separator())
        looks.addItem(NSMenuItem.sectionHeader(title: L("settings.size", "大小")))
        looks.addItem(menuItem(L("menu.zoomIn", "放大"), #selector(menuZoomIn), key: "+", mods: .command, symbol: "plus.magnifyingglass"))
        looks.addItem(menuItem(L("menu.zoomOut", "缩小"), #selector(menuZoomOut), key: "-", mods: .command, symbol: "minus.magnifyingglass"))
        looks.addItem(menuItem(L("menu.zoomDefault", "默认"), #selector(menuZoomDefault), key: "0", mods: .command, symbol: "1.magnifyingglass"))
        looks.addItem(menuItem(L("menu.zoomMax", "最大"), #selector(menuZoomMax), symbol: "arrow.up.left.and.arrow.down.right"))
        menu.addItem(submenuItem(L("menu.finish", "外观"), looks, symbol: "paintpalette"))

        menu.addItem(.separator())

        menu.addItem(menuItem(L("menu.settings", "设置…"), #selector(menuSettings), key: ",", mods: .command, symbol: "gearshape"))
        menu.addItem(menuItem(L("prefs.about", "关于 HomePlay"), #selector(menuAbout), symbol: "info.circle"))
        menu.addItem(.separator())
        menu.addItem(menuItem(L("menu.quit", "退出 HomePlay"), #selector(menuQuit), key: "q", mods: .command, symbol: "power"))
        return menu
    }

    /// 菜单项：key＝真快捷键（系统画在右边）；hint＝没有快捷键的手势提示，灰字靠右；
    /// symbol＝左边的 SF Symbol（WindowShade 的规则：每一项都带符号）
    private func menuItem(_ title: String, _ sel: Selector?, key: String = "", mods: NSEvent.ModifierFlags = [], hint: String? = nil,
                          symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
        item.keyEquivalentModifierMask = mods
        item.target = self
        if let hint {
            let ps = NSMutableParagraphStyle()
            ps.tabStops = [NSTextTab(textAlignment: .right, location: 250)]
            let font = NSFont.menuFont(ofSize: 0)
            let s = NSMutableAttributedString(string: title + "\t", attributes: [.font: font, .paragraphStyle: ps])
            s.append(NSAttributedString(string: hint, attributes: [.font: NSFont.menuFont(ofSize: font.pointSize - 2),
                                                                  .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: ps]))
            item.attributedTitle = s
        }
        return item
    }
    func submenuItem(_ title: String, _ sub: NSMenu, hint: String? = nil, symbol: String? = nil) -> NSMenuItem {
        let item = hint.map { menuItem(title, nil, hint: $0, symbol: symbol) }
            ?? menuItem(title, nil, symbol: symbol)
        item.submenu = sub
        return item
    }
    /// 配色的色票圆点（菜单里比文字好认）
    private func finishSwatch(_ f: Finish) -> NSImage {
        let hex: UInt32
        switch f {
        case .g4: hex = 0xF4F5F4
        case .silver: hex = 0xD8DADB
        case .starlight: hex = 0xE9E1D3
        case .rose: hex = 0xE8C9C2
        case .gray: hex = 0x6E7073
        }
        let img = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
            let p = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
            srgb(hex).setFill(); p.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke(); p.lineWidth = 0.5; p.stroke()
            return true
        }
        return img
    }
    private static let faceSymbols: [FaceStyle: String] = [
        .island: "capsule", .photos: "photo", .modular: "square.grid.2x2", .analog: "clock",
        .flow: "wind", .growth: "leaf", .system6: "desktopcomputer",
        .weather: "cloud.sun", .calendar: "calendar", .black: "circle.fill",
    ]

    // MARK: 偏好设定（菜单里的子菜单，不另开窗口）

    static let photoFolderKey = "HomePlayPhotoFolder"
    @objc private func menuSettings() {
        if let app = NSApp.delegate as? AppDelegate { SettingsWindowController.show(app: app) }
    }
    @objc private func menuLoginItem() {
        let svc = SMAppService.mainApp
        do {
            switch svc.status {
            case .enabled: try svc.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default: try svc.register()
            }
        } catch { log("login item 失败：\(error.localizedDescription)") }
        log("login item \(svc.status == .enabled ? "on" : "off")")
    }
    @objc private func menuPhotoFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = face.photos.folder
        panel.message = L("prefs.photoFolder.message", "选一个放照片的文件夹，照片表盘会轮播里面的照片")
        panel.prompt = L("prefs.photoFolder.choose", "选择")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: Self.photoFolderKey)
        face.photos = PhotoShelf(folder: url); face.forceDirty = true
        log("photo folder \(url.path)")
    }
    @objc private func menuCalendarAllow() {
        (NSApp.delegate as? AppDelegate)?.withPermission(.calendar) { ok in
            if ok { CalendarSource.shared.requestAccess() }   // 已授权：只是同步状态、开始读
        }
    }
    @objc private func menuCalendarToggle() { CalendarSource.enabled.toggle(); CalendarSource.shared.refresh() }
    @objc private func menuCalendarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") { NSWorkspace.shared.open(url) }
    }
    @objc private func menuNowPlaying() {
        if NowPlayingPoller.enabled {
            NowPlayingPoller.enabled = false; NowPlayingPoller.shared.stop(); return
        }
        (NSApp.delegate as? AppDelegate)?.withPermission(.automation) { [weak self] ok in
            guard let self, ok else { return }
            NowPlayingPoller.enabled = true
            NowPlayingPoller.shared.start(face: self.face)
        }
    }
    @objc private func menuGazeToggle() {
        (NSApp.delegate as? AppDelegate)?.toggleGazeFollow()
    }
    @objc private func menuMicPermission() {
        (NSApp.delegate as? AppDelegate)?.showMicrophonePermission()
    }
    @objc private func menuGazePitch() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("gaze.pitch.title", "跟随我：俯仰角度")
        alert.informativeText = L("gaze.pitch.body", "拖动滑块调整抬头/低头的最大角度；0° 只转头不点头。设置会记住。")
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 48))
        let slider = NSSlider(value: Double(gazePitchDegrees), minValue: 0, maxValue: 8,
                              target: self, action: #selector(gazePitchSliderChanged(_:)))
        slider.frame = NSRect(x: 0, y: 8, width: 300, height: 26)
        slider.numberOfTickMarks = 5
        slider.allowsTickMarkValuesOnly = false
        let value = NSTextField(labelWithString: String(format: "%.1f°", Double(gazePitchDegrees)))
        value.frame = NSRect(x: 308, y: 11, width: 52, height: 20)
        value.alignment = .right
        gazePitchValueLabel = value
        box.addSubview(slider); box.addSubview(value)
        alert.accessoryView = box
        alert.addButton(withTitle: L("wifi.save", "保存"))
        alert.addButton(withTitle: L("wifi.cancel", "取消"))
        let response = alert.runModal()
        gazePitchValueLabel = nil
        if response == .alertFirstButtonReturn {
            setGazePitch(CGFloat(slider.doubleValue))
        }
    }
    @objc private func gazePitchSliderChanged(_ sender: NSSlider) {
        gazePitchValueLabel?.stringValue = String(format: "%.1f°", sender.doubleValue)
    }
    func setGazePitch(_ degrees: CGFloat) {
        gazePitchDegrees = min(8, max(0, degrees))
        UserDefaults.standard.set(Double(gazePitchDegrees), forKey: Self.gazePitchKey)
        log(String(format: "gaze pitch %.1f°", Double(gazePitchDegrees)))
    }
    @objc private func menuRoomLightToggle() {
        (NSApp.delegate as? AppDelegate)?.toggleRoomLight()
    }
    @objc private func menuShowHints() { Onboarding.armed = false; Onboarding.active = false; face.armOnboarding() }
    @objc private func menuAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
    @objc func menuFaceOverview() {
        guard !showingVideo, !face.inOverview else { return }
        face.beginOverview()
        mood.show(.wink, for: 0.5, now: CACurrentMediaTime())
    }
    @objc private func menuCancelConnect() { onCancelConnect?() }

    // 重按（Force Touch，stage 2）＝进入 CarPlay。直播时按在屏幕上不抢：那一按本来就是 CarPlay 长按。
    override func pressureChange(with event: NSEvent) {
        endPoster()
        defer { forceStage = event.stage }
        // 直播時點在屏幕上會是 .touch；這正是要退出的時候，不能把重按擋掉。
        // 同一個手勢進出：沒畫面就進 CarPlay，有畫面就退出（空格仍是備用）。
        guard event.stage == 2, forceStage < 2, !face.inOverview, !FaceOverview.swallowUp else { return }
        onForceEnter?()
    }

    @objc func menuEnterCarPlay() { onForceEnter?() }
    @objc func menuPairPhone() {
        guard !showingVideo else { return }
        CarPlayOverlayState.needsPairing = true      // 立即显示配对卡片
        CarPlayOverlayState.needsTrust = false       // 同一时间只亮一张引导卡
        CarPlayOverlayState.needsCable = false
        CarPlayOverlayState.bluetoothPairing = false
        CarPlayOverlayState.bluetoothPairFailed = false
        onForceEnter?()                              // 拉起 receiver，等 USB
    }
    @objc private func menuUsePhone(_ sender: NSMenuItem) {
        guard let address = sender.representedObject as? String, !address.isEmpty else { return }
        onSelectPhone?(address)
    }
    @objc private func menuPairNewPhone() { onPairNewPhone?() }
    @objc func menuConnectSteps() { ConnectHelp.showSteps() }
    @objc func menuCopyDiagnostics() { onCopyDiagnostics?() }
    @objc private func menuForgetPhone(_ sender: NSMenuItem) {
        guard let address = sender.representedObject as? String, !address.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("forget.title", "忘记这台 iPhone？")
        alert.informativeText = L("forget.body", "HomePlay 会停止使用它，并删除这台 Mac 上的蓝牙配对。之后会告诉你 iPhone 上还要做哪一步。")
        alert.addButton(withTitle: L("forget.confirm", "忘记"))
        alert.addButton(withTitle: L("wifi.cancel", "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onForgetPhone?(address)
    }
    /// 「忘記 iPhone」之後：列出還要使用者自己做的步驟（HomePlay 動不了 iPhone 的設定；Mac 的系統配對有時也刪不掉）
    func showForgetSteps(name: String?, macRemoved: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = name.map { String(format: L("forget.doneTitle", "已忘记「%@」"), $0) }
            ?? L("forget.doneTitleNoName", "已忘记这台 iPhone")
        var steps = [L("forget.stepPhone", "在 iPhone 上：设置 › 通用 › CarPlay › HomePlay › 忘记此车辆（蓝牙配对会一起删除）")]
        if !macRemoved {
            steps.append(L("forget.stepMac", "在这台 Mac 上：系统设置 › 蓝牙 › 这台 iPhone 旁边的 ⓘ › 忘记此设备"))
        }
        let numbered = steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        alert.informativeText = L("forget.doneBody", "要重新配对，还差这几步：") + "\n\n" + numbered
        if !macRemoved { alert.addButton(withTitle: L("forget.openBluetooth", "打开蓝牙设置")) }
        alert.addButton(withTitle: L("gaze.denied.ok", "好"))
        if alert.runModal() == .alertFirstButtonReturn, !macRemoved,
           let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func menuRestorePhones() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("restore.title", "恢复已忘记的 iPhone？")
        alert.informativeText = L("restore.body", "HomePlay 会重新把这些 iPhone 列入可用设备；系统蓝牙配对不会自动恢复。")
        alert.addButton(withTitle: L("restore.confirm", "恢复"))
        alert.addButton(withTitle: L("wifi.cancel", "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onRestorePhones?()
    }
    @objc private func menuWiFiPassword() {
        NSApp.activate(ignoringOtherApps: true)
        // 优先用已保存的「iPhone 所连 Wi-Fi」；没有才用 Mac 当前 Wi-Fi 作提示。
        // Mac 与 iPhone 连不同 SSID（同网段）是常见情况，不能默认填 Mac 自己的。
        var ssid = ReceiverLauncher.loadConfig().ssid
        if ssid.isEmpty { ssid = CarPlayWiFi.ssid }
        let hasSavedPassword = !ReceiverLauncher.loadConfig().passphrase.isEmpty
        var password = ""
        var note: String?
        while true {
            let alert = NSAlert()
            alert.messageText = L("wifi.title", "Wi-Fi 设置")
            var body = L("wifi.body", "这里填 iPhone 所连的 Wi-Fi（不一定是 Mac 自己连的那个）。Mac 用网线、或两者连不同 SSID 时，请填 iPhone 那个网络的名称和密码。iPhone 已在该网络上时密码可留空。macOS 26 不再允许 App 读取钥匙串密码，需要时请在系统设置里查看后手填（仅存在本机）。")
            if let note { body += "\n\n" + note }
            alert.informativeText = body
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 96))
            let l1 = NSTextField(labelWithString: L("wifi.ssid", "iPhone 所连 Wi-Fi（SSID）"))
            l1.frame = NSRect(x: 0, y: 76, width: 360, height: 17)
            l1.font = .systemFont(ofSize: 11); l1.textColor = .secondaryLabelColor
            let ssidField = NSTextField(frame: NSRect(x: 0, y: 50, width: 360, height: 24))
            ssidField.stringValue = ssid
            ssidField.placeholderString = L("wifi.ssidPlaceholder", "留空＝用 Mac 当前 Wi-Fi（仅当 iPhone 也连它）")
            let l2 = NSTextField(labelWithString: L("wifi.password", "Wi-Fi 密码"))
            l2.frame = NSRect(x: 0, y: 28, width: 360, height: 17)
            l2.font = .systemFont(ofSize: 11); l2.textColor = .secondaryLabelColor
            let pwField = NSSecureTextField(frame: NSRect(x: 0, y: 2, width: 360, height: 24))
            pwField.stringValue = password
            pwField.placeholderString = hasSavedPassword
                ? L("wifi.placeholder.keep", "留空＝保持已保存的密码")
                : L("wifi.placeholder", "Wi-Fi 密码（留空＝开放网络）")
            for v in [l1, ssidField, l2, pwField] { container.addSubview(v) }
            alert.accessoryView = container
            alert.addButton(withTitle: L("wifi.save", "保存"))
            alert.addButton(withTitle: L("wifi.openSettings", "在系统设置里查看…"))
            alert.addButton(withTitle: L("wifi.cancel", "取消"))
            alert.window.initialFirstResponder = pwField
            let response = alert.runModal()
            let enteredSSID = ssidField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let enteredPassword = pwField.stringValue
            if response == .alertFirstButtonReturn {
                // macOS 在无定位权限时把 SSID 显示成 "<redacted>"，曾有人把它当真名保存，
                // 结果 0x5703 让 iPhone 去连一个不存在的网络。这里直接挡住。
                if enteredSSID.caseInsensitiveCompare("<redacted>") == .orderedSame {
                    note = L("wifi.rejectedRedacted", "「<redacted>」是 macOS 隐藏网络名后显示的占位文字，不是真实网络名。请填 iPhone 所连 Wi-Fi 的实际名称（可在 iPhone 的「设置 › Wi-Fi」里看到）。")
                    continue
                }
                onSetWiFi?(enteredSSID, enteredPassword)
                return
            }
            if response == .alertThirdButtonReturn { return }
            ssid = enteredSSID
            // 第二颗按钮：macOS 26 不再向 App 提供 Wi-Fi 密码，只能到系统设置里查看后手填。
            openWiFiSettings()
            password = enteredPassword
            note = L("wifi.openedSettings", "已在「系统设置 › Wi-Fi › 详细信息」显示密码；抄下后填到上面，再点保存。")
        }
    }

    private func openWiFiSettings() {
        for text in ["x-apple.systempreferences:com.apple.wifi-settings-extension",
                     "x-apple.systempreferences:com.apple.preference.network"] {
            if let url = URL(string: text), NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    @objc private func menuToggleLive() { onToggleLive?() }
    /// 转一圈：目标偏航加一整圈，弹簧缓动转完正好回原朝向。direction = 1 往左、-1 往右（跟拖拽方向一致）。
    private func spinBody(direction: Int) {
        touring = false
        atHome = false
        ty += CGFloat(direction) * 2 * .pi
        mood.show(.surprised, for: 0.4, now: CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.mood.show(.happy, for: 1.2, now: CACurrentMediaTime())
        }
        log("gesture spin \(direction > 0 ? "left" : "right")")
    }
    @objc private func menuApart() { setApart(!isApart) }
    /// 选「跟随系统」清掉偏好；选某种语言就记住它。右键菜单每次打开都重建，所以只需重画表盘。
    @objc private func menuLanguage(_ sender: NSMenuItem) {
        let picked = (sender.representedObject as? String).flatMap(PetLanguage.init(rawValue:))
        PetLanguage.chosen = picked
        L10n.language = picked ?? .fromSystem()
        face.forceDirty = true
    }

    @objc private func menuFinish(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let f = Finish(rawValue: raw) else { return }
        setFinish(f)
        UserDefaults.standard.set(f.rawValue, forKey: Finish.defaultsKey)
        mood.show(.happy, for: 1.0, now: CACurrentMediaTime())
        log("menu finish \(raw)")
    }
    @objc private func menuStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let st = FaceStyle(rawValue: raw) else { return }
        setFaceStyle(st)
    }
    @objc private func menuTimer(_ sender: NSMenuItem) {
        guard let m = sender.representedObject as? Double else { return }
        startTimer(minutes: m)
    }
    @objc private func menuTimerCancel() { face.pomodoro.stop(); face.cancelTimer(); log("timer cancel") }
    @objc private func menuPomodoroStart() { startPomodoro() }
    @objc private func menuPomodoroStop() { stopPomodoro() }
    @objc private func menuQuit() { NSApp.terminate(nil) }
    @objc func menuZoomIn() { zoom(by: 1.25) }
    @objc func menuZoomOut() { zoom(by: 0.8) }
    @objc private func menuZoomMax() { zoomMax() }
    @objc func menuZoomDefault() { setZoom(width: Pet.defaultWidth) }
    @objc private func menuResetOrientation() { resetOrientation() }
    @objc private func menuAgentToggle() {
        let result = ReceiverAgent.toggle()
        log("agent \(result.message)")
        mood.show(result.installed ? .happy : .wink, for: 1.2, now: CACurrentMediaTime())
    }
    override var acceptsFirstResponder: Bool { true }
    /// 系統「三指拖動」開啟時（預設常見），macOS 會把三指手勢合成成滑鼠拖拽，不再送 touches。
    /// 這種機器上把「拖拽」解釋成搬視窗（直播時除外），三指拖移就取代 ⌘-拖動。
    static var systemThreeFingerDrag: Bool {
        let domains = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
        return domains.contains { UserDefaults(suiteName: $0)?.bool(forKey: "TrackpadThreeFingerDrag") ?? false }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// VoiceOver 用户「按下」＝进入/退出 CarPlay（和重按同一条路）
    override func accessibilityPerformPress() -> Bool { onForceEnter?(); return true }

    override func keyDown(with event: NSEvent) {
        endPoster()
        if overviewKeyDown(event) { return }   // 总览里 Esc 只收起、Return 套用、← → 挑
        if event.modifierFlags.contains(.command) {
            switch event.keyCode {
            case 12: NSApp.terminate(nil)                  // ⌘Q
            case 43: menuSettings()                        // ⌘,
            case 24, 69: zoom(by: 1.25)                    // ⌘+ （主键区/小键盘）
            case 27, 78: zoom(by: 0.8)                     // ⌘−
            case 29: setZoom(width: Pet.defaultWidth)      // ⌘0
            default: break
            }
            return
        }
        switch event.keyCode {
        // Esc 只做「取消」，不再退出 App（退出是 ⌘Q／菜单）：先收提示，直播中就退出直播
        case 53:
            if event.isARepeat { return }
            if PermissionPrimer.active { PermissionPrimer.dismiss() }
            else if face.onboardingActive { face.dismissOnboarding(); FaceOverview.pressToken += 1 }
            else if showingVideo { onToggleLive?() }
        case 49: onToggleLive?()                      // 空格
        case 18: setView(yaw: 0, pitch: 0.12, label: "front")      // 1 正面
        case 19: setView(yaw: .pi / 2, pitch: 0.18, label: "side") // 2 侧面
        case 20: setView(yaw: .pi, pitch: 0.15, label: "back")     // 3 背面
        case 21: setView(yaw: nil, pitch: 1.3, label: "above")     // 4 俯视
        case 123: if !showingVideo { setFaceStyle(face.style.next(-1)) }   // ← 上一个錶面
        case 124: if !showingVideo { setFaceStyle(face.style.next(1)) }    // → 下一个錶面
        default: super.keyDown(with: event)
        }
    }
}

// MARK: - 窗口

final class PetWindow: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = AppDelegate.alwaysOnTop ? .floating : .normal
        isMovableByWindowBackground = false
        // 不加 .fullScreenAuxiliary：全螢幕 App 在前景时自动不出现，回到桌面再出来
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { true }
}

// MARK: - App

// MARK: - 拉起 receiver（重按进 CarPlay 用）
/// 参数读 ~/Library/Application Support/HomePlay/wireless.json（phone、ssid、size、port）；
/// Wi-Fi 密码不需要：iPhone 与 Mac 同网时直接连；特殊网络用 HOMEPLAY_WIFI_PASSPHRASE 显式提供。
/// pet 退出时一并结束自己拉起的 receiver；端口探测避免重复起。
enum ReceiverLauncher {
    enum Result { case ok; case noBinary(String) }

    struct Config: Codable {
        /// 留空＝蓝牙自动匹配（扫已配对设备的 iAP2 服务，iPhone 的签名）
        var phone: String = ""
        var ssid: String = ""
        /// iPhone 所连 Wi-Fi 的密码；只在本地 wireless.json（0600），不进命令行/日志
        var passphrase: String = ""
        var size: String = "1088x1088"
        var port: Int = 8788
        /// wireless | usb | auto（默认 auto：插着线走有线，没插走无线）
        var source: String = "auto"
        /// 用户按「忘记 iPhone」后要忽略的地址；系统配对删不掉时至少让 HomePlay 不再尝试
        var ignoredPhones: [String] = []
    }

    private static nonisolated(unsafe) var process: Process?
    private static nonisolated(unsafe) var launching = false
    private static nonisolated(unsafe) var lastLaunch: Date?

    /// 配置里的 WS 口（默认 8788）；拉起、探测、连接都用它，避免配置改了端口却还连旧口
    static func port() -> Int {
        (try? JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL())))?.port ?? 8788
    }

    /// 桌宠退出时把自己拉起的 receiver 一起结束；launchd 拉起的（process 为 nil）不动
    static func stop() {
        guard let p = process, p.isRunning else { process = nil; return }
        p.terminate()
        process = nil
    }

    static func configURL() -> URL {
        HomePlayState.directory.appendingPathComponent("wireless.json")
    }

    static func loadConfig() -> Config {
        guard let data = try? Data(contentsOf: configURL()),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return cfg
    }

    /// 后台 LaunchAgent 先于桌宠拉起 receiver 时也要有一份配置（receiver 学到的手机才能落盘）。
    static func ensureConfigFile() {
        let url = configURL()
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(Config()).write(to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// 配置里有 Wi-Fi 密码：只写本机文件、权限 0600；receiver 启动时直接读，不进命令行/日志。
    static func writeConfig(_ cfg: Config) {
        let url = configURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try enc.encode(cfg).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            log("写 wireless.json 失败（\(error.localizedDescription)）")
        }
    }

    /// 记住用户选定的 iPhone：下次拉起/登录用同一台（空串＝自动匹配）。
    static func savePhone(_ address: String) {
        var cfg = loadConfig()
        cfg.phone = address
        writeConfig(cfg)
    }

    static func savePassphrase(_ value: String) {
        var cfg = loadConfig()
        cfg.passphrase = value
        writeConfig(cfg)
    }

    static func saveWiFi(ssid: String, passphrase: String) {
        var cfg = loadConfig()
        cfg.ssid = ssid
        // 密码框留空＝保持已保存的密码（macOS 26 读不到钥匙串，别因为只改 SSID 就把密码擦掉）。
        if !passphrase.isEmpty { cfg.passphrase = passphrase }
        writeConfig(cfg)
    }

    static func forgetPhone(_ address: String) {
        var cfg = loadConfig()
        let normalized = CarPlayPhoneBook.normalize(address)
        if !cfg.ignoredPhones.contains(where: { CarPlayPhoneBook.normalize($0) == normalized }) {
            cfg.ignoredPhones.append(normalized)
        }
        if CarPlayPhoneBook.normalize(cfg.phone) == normalized { cfg.phone = "" }
        writeConfig(cfg)
    }

    static func restoreIgnoredPhones() {
        var cfg = loadConfig()
        cfg.ignoredPhones = []
        writeConfig(cfg)
    }

    /// receiver 可执行文件的候选位置（按优先级）。
    /// 打包后的 App 把接收器放在 Contents/Resources，而不是 Contents/MacOS：LaunchServices 会把
    /// Contents/MacOS 里的进程登记成整个 App（同一个 bundle id）。接收器由 launchd 常驻时，
    /// `open HomePlay.app` 就会以为“HomePlay 已在运行”而返回 -600，桌宠再也打不开。
    /// Resources 里的可执行文件不参与 App 登记（已用 lsappinfo 实测对照）。
    static func receiverBinaryCandidates() -> [URL] {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let dir = exe.deletingLastPathComponent()
        return [
            dir.deletingLastPathComponent().appendingPathComponent("Resources/homeplay-receiver"),
            dir.appendingPathComponent("homeplay-receiver"),   // .build/release 与桌宠同目录
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/release/homeplay-receiver"),
        ]
    }

    static func receiverBinary() -> URL? {
        receiverBinaryCandidates().first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func launch() -> Result {
        if launching { return .ok }          // 连按两下重压：只拉起一个 receiver
        if let last = lastLaunch, Date().timeIntervalSince(last) < 3, process?.isRunning == true { return .ok }
        lastLaunch = Date()
        launching = true
        defer { launching = false }
        guard let bin = receiverBinary() else {
            lastLaunch = nil
            return .noBinary(receiverBinaryCandidates().map(\.path).joined(separator: "、"))
        }
        let url = configURL()
        var cfg = Config()
        if let data = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(Config.self, from: data) {
            cfg = c
        } else {   // 第一次：写一份模板。全部字段可留空＝自动（SSID 接收器自己取当前 Wi-Fi）
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(cfg).write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let source = ["wireless", "usb", "auto"].contains(cfg.source) ? cfg.source : "auto"
        var args = ["--source", source, "--port", String(cfg.port), "--size", cfg.size,
                    "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
        if !cfg.ssid.isEmpty { args += ["--ssid", cfg.ssid] }   // 留空＝自动取当前 Wi-Fi
        if !cfg.phone.isEmpty { args += ["--address", cfg.phone] }
        let p = Process()
        p.executableURL = bin
        p.arguments = args
        let env = ProcessInfo.processInfo.environment
        // 不自動讀系統鑰匙圈（Wi-Fi 密碼在「系統」鑰匙圈，會彈管理員授權）。
        // CarPlay 無線交接需要 Wi-Fi 憑據；由用戶在右鍵「Wi-Fi 密碼…」填一次，存本地 0600。
        p.environment = env
        let logURL = url.deletingLastPathComponent().appendingPathComponent("receiver.log")
        // 控制日志体积：超过 2 MB 就清空（receiver 每条会话都会追写）
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
           let size = attrs[.size] as? Int, size > 2_000_000 {
            try? FileManager.default.removeItem(at: logURL)
        }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])   // 有 Wi-Fi 名稱與手機位址
        } else {
            chmod(logURL.path, 0o600)
        }
        var logHandle: FileHandle?
        if let h = FileHandle(forWritingAtPath: logURL.path) {
            h.seekToEndOfFile()
            p.standardOutput = h; p.standardError = h
            logHandle = h
        }
        do {
            try p.run()
            // 子进程已经 dup 了这条 fd：父进程这份要关掉，否则每拉起一次漏一个 fd。
            try? logHandle?.close()
            process = p
            return .ok
        } catch {
            try? logHandle?.close()
            log("receiver 拉起失败：\(error)")
            return .noBinary(bin.path)
        }
    }


}

/// 开机自启的 LaunchAgent：receiver 以 --source auto 常驻（RunAtLoad），
/// 参数读 wireless.json；装/卸都是一条 launchctl。妙控体验的最后一块——桌面常在，插线即连。
enum ReceiverAgent {
    /// 首次配對演練（HOMEPLAY_STATE_NAME）用另一個標籤：不覆蓋、不卸載使用者平常的 LaunchAgent
    static let label = HomePlayState.isolated ? "me.aaron.homeplay.receiver.rehearsal" : "me.aaron.homeplay.receiver"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// 用户在菜单里明确关过：自动开启要尊重这个选择，不每次启动又装回来。
    static let autoOffKey = "HomePlayBackgroundReceiverOff"

    /// installed：這次是不是裝上了；message 是給人看的結果（目前只進日誌）
    static func toggle() -> (installed: Bool, message: String) {
        if isInstalled {
            let message = remove()
            UserDefaults.standard.set(true, forKey: autoOffKey)
            return (false, message)
        }
        let result = install()
        if result.installed { UserDefaults.standard.set(false, forKey: autoOffKey) }
        return result
    }

    /// 首次配对/已有手机时自动开启后台常驻：像妙控配件一样，桌宠退出后手机仍有东西可回连。
    @discardableResult
    static func autoEnableIfNeeded(reason: String) -> Bool {
        if isInstalled { return true }
        if UserDefaults.standard.bool(forKey: autoOffKey) { return false }
        let result = install()
        if result.installed {
            UserDefaults.standard.set(false, forKey: autoOffKey)
            log("后台自动连接已开启（\(reason)）")
        } else {
            log("后台自动连接没开成（\(reason)）：\(result.message)")
        }
        return result.installed
    }

    private static func install() -> (installed: Bool, message: String) {
        // 读 receiver 的当前路径（打包后在 Contents/Resources）+ wireless.json 的配置
        guard let bin = ReceiverLauncher.receiverBinary() else { return (false, L("install.noReceiver", "找不到 homeplay-receiver（先 swift build）")) }
        ReceiverLauncher.ensureConfigFile()
        let cfg = (try? JSONDecoder().decode(ReceiverLauncher.Config.self, from: Data(contentsOf: ReceiverLauncher.configURL()))) ?? .init()
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try plistText(cfg: cfg, bin: bin).data(using: .utf8)?.write(to: plistURL) }
        catch { return (false, String(format: L("install.writeFailed", "写 plist 失败：%@"), error.localizedDescription)) }
        let loaded = launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        return (loaded, loaded ? L("install.done", "已设为登录时打开（登录即待命）")
                           : L("install.partial", "plist 已写好，但 launchctl 没成功（下次登录也会生效）"))
    }

    private static func remove() -> String {
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
        return L("install.removed", "已取消登录时打开")
    }

    /// 升级迁移：旧版 LaunchAgent 指向 Contents/MacOS/homeplay-receiver（占用 App 的
    /// LaunchServices 身份，导致 `open` 打不开桌宠）。发现 plist 路径与当前版本不符就重写并重载。
    /// 重载会重启接收器（一次性），换掉旧布局里那个还在跑的进程。
    static func migrateIfNeeded() {
        guard isInstalled,
              let text = try? String(contentsOf: plistURL, encoding: .utf8),
              let bin = ReceiverLauncher.receiverBinary() else { return }
        guard !text.contains("<string>\(bin.path)</string>") else { return }
        let cfg = (try? JSONDecoder().decode(ReceiverLauncher.Config.self, from: Data(contentsOf: ReceiverLauncher.configURL()))) ?? .init()
        do { try plistText(cfg: cfg, bin: bin).data(using: .utf8)?.write(to: plistURL, options: .atomic) }
        catch { log("LaunchAgent 迁移失败：\(error.localizedDescription)"); return }
        log("LaunchAgent 迁移：接收器改到 \(bin.path)，重载让新布局生效")
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        for attempt in 0..<5 {
            if launchctl(["bootstrap", "gui/\(getuid())", plistURL.path]) { return }
            Thread.sleep(forTimeInterval: 0.2)   // bootout 尚未收尾时 bootstrap 会失败，稍等重试
            if attempt == 4 { log("LaunchAgent 重载失败（plist 已更新，下次登录生效）") }
        }
    }

    /// 用户换了手机：更新已安装的 LaunchAgent 参数（不 bootout，避免打断正在跑的 receiver）。
    /// 已加载的 launchd job 仍用旧参数，但下次登录会读新 plist；当前进程靠 WS 命令切换。
    static func syncPhone() {
        guard isInstalled else { return }
        guard let bin = ReceiverLauncher.receiverBinary(),
              let data = try? Data(contentsOf: ReceiverLauncher.configURL()),
              let cfg = try? JSONDecoder().decode(ReceiverLauncher.Config.self, from: data) else { return }
        try? plistText(cfg: cfg, bin: bin).data(using: .utf8)?.write(to: plistURL, options: .atomic)
    }

    private static func plistText(cfg: ReceiverLauncher.Config, bin: URL) -> String {
        // 不把 SSID/手机地址写进 launchd 参数：这两个值会随用户操作变化，而 launchd 只在
        // bootstrap 时读一次参数——写死就会出现「配置已改、重启后仍用旧 SSID/旧手机」的故障
        // （曾导致 0x5703 发出 <redacted>）。receiver 启动时会自己读 wireless.json。
        let args = ["--source", "auto", "--port", String(cfg.port), "--size", cfg.size]
        let logPath = ReceiverLauncher.configURL().deletingLastPathComponent().appendingPathComponent("receiver.log")
        return """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>\(label)</string>
  <key>ProgramArguments</key><array>
    <string>\(bin.path)</string>
    \(args.map { "<string>\($0)</string>" }.joined(separator: "\n    "))
  </array>
  <key>RunAtLoad</key><true/>
  <!-- 只在异常退出（接收器自愈 exit(1)）时由 launchd 重新拉起；用户主动停止是 exit(0)，不会重启。 -->
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>10</integer>\(HomePlayState.isolated ? "\n  <key>EnvironmentVariables</key><dict><key>HOMEPLAY_STATE_NAME</key><string>\(HomePlayState.name)</string></dict>" : "")
  <!-- Umask 077：launchd 建的 receiver.log 與接收器寫的檔都只給自己讀寫（日誌裡有 Wi-Fi 名稱與手機位址） -->
  <key>Umask</key><integer>63</integer>
  <key>StandardOutPath</key><string>\(logPath.path)</string>
  <key>StandardErrorPath</key><string>\(logPath.path)</string>
</dict></plist>
"""
    }

    /// 作业加载着但没在跑（例如曾因端口冲突 exit(0)）：让 launchd 再起一次。
    /// force=false 时只“没跑就起”，不会打断正在服务的接收器。
    static func kickstart(force: Bool = false) -> Bool {
        var args = ["kickstart"]
        if force { args.append("-k") }
        args.append("gui/\(getuid())/\(label)")
        return launchctl(args)
    }

    private static func launchctl(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        // launchd 不回应时不能无限等：这条路径在启动和配对时跑在主執行緒上。
        // 正常情况 launchctl 几十毫秒就退出，这里只是加个上限。
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning {
            if Date() >= deadline {
                p.terminate()
                return false
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return p.terminationStatus == 0
    }
}

/// F5（听写/Siri 那颗）在默认键盘模式下不是普通 keyDown：全局 keyDown 监听和 Carbon
/// 热键都看不到（早先的诊断里全局 keyDown 从未出现 96 或 176）。实证它走系统事件：keyDown keyCode
/// 176（Spillway 真机实测），或 NX_SYSDEFINED（type 14、subtype 8 的辅助键，data1
/// 高 16 位＝键值、0x0A/0x0B＝按下/抬起）。装一个会话级 CGEventTap（输入监控已授权）：
/// 176 按住＝对手机 Siri 说话、放开＝结束，并把按下/抬起都吞掉，免得 Mac 听写一起抢这颗键。辅助键只在
/// HOMEPLAY_DIAG_KEYS=1 时写 syskeys.log——键盘发的是别的键值时，按一次 F5 就能看到。
enum SystemKeyTap {
    /// 听写键（F5 印麦克风的那颗）。若与某块键盘不符，用 HOMEPLAY_DIAG_KEYS=1 看 syskeys.log 改这里。
    static let siriKeyCode: Int64 = 176
    /// NX_SUBTYPE_AUX_CONTROL_BUTTONS：媒体/听写这类辅助键在 NX_SYSDEFINED 里的 subtype
    static let auxSubtype: Int16 = 8
    /// NX_SYSDEFINED：CGEventType 没公开这个枚举值，只在这里用裸数字
    static let sysDefinedType: UInt32 = 14

    /// 只給「換了鍵盤、要知道它發哪個鍵碼」的除錯用；平常不記錄系統按鍵。
    static let logAllAuxKeys = ProcessInfo.processInfo.environment["HOMEPLAY_DIAG_KEYS"] != nil

    /// tap 掛在專用執行緒的 run loop 上，不佔主執行緒：主執行緒一忙（畫臉、重建環境光），
    /// 掛在主 loop 的 tap 就把全系統鍵盤一起拖慢，還會被系統當成超時停掉。
    private static let lock = NSLock()
    private static var tap: CFMachPort?
    private static var runLoop: CFRunLoop?
    private static var started = false
    private static var siriHandler: ((Bool) -> Void)?
    private static let retryLimit = 12          // 5 秒一次，約一分鐘

    /// down：true＝按下、false＝放開（按住說話）
    static func setSiriHandler(_ h: @escaping (Bool) -> Void) {
        lock.lock(); siriHandler = h; lock.unlock()
    }

    private static func fireSiri(down: Bool) {
        lock.lock(); let h = siriHandler; lock.unlock()
        DispatchQueue.main.async { h?(down) }
    }

    /// 可重复调用：已经装好就直接返回；还没好的话由后台线程继续重试
    /// （输入监控授权往往是在 App 启动之后才给的，只试一次会一直没反应）。
    /// F5 现在真的被我们接住了（tap 装好了）
    static var isActive: Bool { lock.lock(); defer { lock.unlock() }; return tap != nil }
    private static var threadAlive = false
    /// 用户刚在「输入监控」里勾上 HomePlay：如果之前的重试已经放弃，重新装一次
    static func retryAfterGrant() {
        lock.lock()
        let again = tap == nil && !threadAlive
        if again { started = false }
        lock.unlock()
        if again { _ = install() }
    }

    static func install() -> Bool {
        lock.lock()
        if started { let ok = tap != nil; lock.unlock(); return ok }
        started = true
        lock.unlock()
        return startThread()
    }

    private static func makePort() -> (CFMachPort, CFRunLoopSource)? {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << sysDefinedType)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: callback, userInfo: nil),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { return nil }
        return (port, source)
    }

    /// 起专用线程并把 tap 挂上去。返回时能确定「这一秒内装好了没有」。
    private static func startThread() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        var created = false
        let t = Thread {
            lock.lock(); threadAlive = true; lock.unlock()
            defer { lock.lock(); threadAlive = false; lock.unlock() }
            var signalled = false
            for attempt in 1...retryLimit {
                guard let (port, source) = makePort() else {
                    if !signalled { signalled = true; ready.signal() }
                    if attempt == retryLimit { break }
                    Thread.sleep(forTimeInterval: 5)
                    continue
                }
                created = true
                if !signalled { signalled = true; ready.signal() }
                lock.lock(); tap = port; runLoop = CFRunLoopGetCurrent(); lock.unlock()
                CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
                CGEvent.tapEnable(tap: port, enable: true)
                appendDiag("syskeys.log", "tap installed on own thread (attempt \(attempt))")
                CFRunLoopRun()
                return
            }
            appendDiag("syskeys.log", "tap create failed after \(retryLimit) attempts (need Input Monitoring)")
        }
        t.name = "homeplay.keytap"
        t.qualityOfService = .userInteractive
        t.start()
        _ = ready.wait(timeout: .now() + 0.5)
        return created
    }

    /// 端口失效（系统回收了 tap）时，把旧 loop 收掉再重新装一颗。
    private static func reinstall() {
        lock.lock()
        let oldLoop = runLoop
        tap = nil; runLoop = nil; started = false
        lock.unlock()
        if let oldLoop { CFRunLoopStop(oldLoop) }
        _ = install()
    }

    private static let callback: CGEventTapCallBack = { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); let port = tap; lock.unlock()
            if let port, CFMachPortIsValid(port) {
                CGEvent.tapEnable(tap: port, enable: true)
                appendDiag("syskeys.log", "tap re-enabled after \(type.rawValue)")
            } else {
                appendDiag("syskeys.log", "tap invalid (\(type.rawValue)); reinstalling")
                DispatchQueue.main.async { reinstall() }
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown || type == .keyUp {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == SystemKeyTap.siriKeyCode {
                if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    fireSiri(down: true)
                } else if type == .keyUp {
                    fireSiri(down: false)
                }
                return nil   // 吞掉按下/抬起：Mac 听写别和手机 Siri 抢这颗键
            }
            return Unmanaged.passUnretained(event)
        }
        if type.rawValue == SystemKeyTap.sysDefinedType, let ns = NSEvent(cgEvent: event),
           ns.subtype.rawValue == SystemKeyTap.auxSubtype {
            let data1 = ns.data1
            let key = (data1 & 0xFFFF0000) >> 16
            let state = (data1 & 0xFF00) >> 8
            // 換鍵盤後要確認它發哪個鍵碼時才開 HOMEPLAY_DIAG_KEYS=1；平時不落地按鍵。
            if SystemKeyTap.logAllAuxKeys { appendDiag("syskeys.log", "aux key=\(key) state=\(state)") }
            if key == Int(SystemKeyTap.siriKeyCode) {
                if state == 0x0A, data1 & 0x1 == 0 { fireSiri(down: true) }   // 低位＝自動重複
                else if state == 0x0B { fireSiri(down: false) }
                return nil
            }
        }
        return Unmanaged.passUnretained(event)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var healthTimer: Timer?
    private var statsTimer: Timer?
    private var globalMagnify: Any?
    private var globalKeys: Any?
    private var globalScroll: Any?
    private var lastSiriAt = Date.distantPast
    private var siriHotKey: EventHotKeyRef?
    private var siriHotKeyAlt: EventHotKeyRef?
    private var siriHotKeyHandler: EventHandlerRef?
    var initialWidth: CGFloat = Pet.defaultWidth
    var endpoint: String?
    var initialApart = false
    var initialApartT: CGFloat?       // 快照：拆開到一半（0…1）
    var initialPart: AnatomyPart?     // 快照：釘住這一件的標籤
    var initialYaw: CGFloat?
    var origin: NSPoint?
    var initialPitch: CGFloat?
    var snapshotPath: String?
    var snapshotGlancePath: String?   // 官網素材：同一格畫面的「瞄一眼」版本
    var snapshotBlinkPath: String?    // 官網素材：同一格畫面的「閉眼」版本
    var forceHello = false            // 官網素材：不管偏好裡存的是什麼外觀，都寫一次 hello
    var benchSeconds: Double = 0
    var initialView: String?          // >0：跑 N 秒後印出渲染/CPU 統計並結束（效能基準）
    var lockedFace: Expression?
    var faceStyle: FaceStyle?
    var timerSeconds: Double?
    var musicTest: String?
    var showBanner = false
    var photosDir: String?
    var finish: Finish?
    var hourOverride: Double?
    var gazeTest: (x: CGFloat, y: CGFloat)?   // 快照用：模拟一个人脸样本，验证追人姿态
    var forceNear = false
    var sizeGiven = false
    var eventTest: String?
    var snapshotDelay = 2.5
    var window: PetWindow!
    var view: PetView!
    var client: ReceiverClient?
    private var pendingUsePhone: String?   // 还没连上 receiver 时先记住，WS 打开后补发
    private var pendingPairNew = false
    private var diagnosticsWaiter: ((String?) -> Void)?   // 等接收器回診斷報告（2 秒沒回就只交桌寵這邊的）
    private var diagnosticsTimeout: DispatchWorkItem?
    private var ssidDialogShown = false                    // 「Wi-Fi 名稱未知」時自動開一次 Wi-Fi 設定（自動讀不到才用）
    private var locationAsked = false                      // 這次執行已為 Wi-Fi 名稱出過定位說明卡
    private var pendingSiri = false
    /// F5 按住說話：按下是否已送出（沒送出就放開＝改送一次「按一下」）
    private var siriHold = SiriHoldKey()
    private var siriDownSent = false
    private var siriHoldWatch: Timer?
    /// 來電卡與這通電話是否已經把 CarPlay 叫到前面過（每通只叫一次）
    let callCard = PhoneCallCard()
    private var ringFrontedFor: String?
    private var receiverKickstarted = false
    private var switchingPhone = false     // 切换手机期间保持「连接中」，不要切成担心脸
    let health = VideoHealth(now: CACurrentMediaTime())
    private var userStopped = false
    private var isLive = false
    /// 手机上点了 HomePlay 图标（requestUI）：会话还在，只是画面让回给表面；重按／空格立刻回到 CarPlay
    private var carPlayInBackground = false
    private var quietAttach = false   // 启动时后台挂到 receiver：没画面就不弹连接卡，出画面自动显示
    private var handoffFreeze = false    // 插线稳定后切无线：冻住最后一帧，别把「会话结束」当断线
    private var handoffTimeoutWork: DispatchWorkItem?
    private var gazeFollow = UserDefaults.standard.bool(forKey: AppDelegate.gazeFollowKey)
    private var gazeOccludeWork: DispatchWorkItem?   // 被完全遮住后延迟关摄像头，避免切换全屏/Space 时反复启停
    private var micPrompted = false   // 本次进程只弹一次麦克风授权
    private var micWaiters: [(Bool) -> Void] = []
    private static let gazeFollowKey = "HomePlayGazeFollow"
    private static let roomLightKey = "HomePlayRoomLight"
    private let roomLight = RoomLightEstimator()
    private var roomLightStored = UserDefaults.standard.object(forKey: "HomePlayRoomLight") as? Bool
    var roomLightOn: Bool { roomLightStored ?? false }

    private func startRoomLight(announce: Bool) {
        if announce { NSApp.activate(ignoringOtherApps: true) }
        // 启动恢复不主动弹摄像头权限：只有用户之前明确开启且权限仍在才恢复。
        if !announce, AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
            roomLightStored = false
            UserDefaults.standard.set(false, forKey: Self.roomLightKey)
            view.roomLightEnabled = false
            view.apply(roomLight: .neutral)
            log("room light not restored (camera not authorized)")
            return
        }
        view.roomLightEnabled = true
        roomLight.onSample = { [weak self] s in self?.view.apply(roomLight: s) }
        GazeTracker.shared.onLightFrame = { [weak self] buf, now in self?.roomLight.ingest(buf, at: now) }
        GazeTracker.shared.setTrackFaces(gazeFollow)
        if GazeTracker.shared.isRunning {
            log("room light shares camera")
            return
        }
        GazeTracker.shared.start { [weak self] ok, reason in
            guard let self else { return }
            if ok {
                log("room light started")
            } else {
                self.view.apply(roomLight: .neutral)
                self.roomLightStored = false
                UserDefaults.standard.set(false, forKey: Self.roomLightKey)
                self.view.roomLightEnabled = false
                log("room light camera failed: \(reason ?? "?")")
                if announce { self.showGazeDenied(reason) }
            }
        }
    }

    private func stopRoomLight() {
        view.roomLightEnabled = false
        roomLight.onSample = nil
        GazeTracker.shared.onLightFrame = nil
        view.apply(roomLight: .neutral)
        if gazeFollow {
            GazeTracker.shared.setTrackFaces(true)
        } else {
            GazeTracker.shared.stop()
        }
    }

    func toggleRoomLight() {
        roomLightStored = !roomLightOn
        UserDefaults.standard.set(roomLightStored!, forKey: Self.roomLightKey)
        if roomLightOn {
            withPermission(.camera) { [weak self] ok in
                guard let self else { return }
                if ok { self.startRoomLight(announce: true) }
                else {
                    self.roomLightStored = false
                    UserDefaults.standard.set(false, forKey: Self.roomLightKey)
                    self.rebuildMainMenu()
                }
            }
        } else {
            stopRoomLight()
        }
        rebuildMainMenu()
        log("room light \(roomLightOn ? "on" : "off")")
    }
    private var reconnectStep = 0
    private var reconnectTimer: Timer?
    private static let backoff: [Double] = [5, 10, 20, 30, 60]   // 照 MacPlay，之后一直 60
    /// WS 断开后先快探：接收器重启 1–3 s 就绪，别让桌宠干等 5 s 退避
    private static let fastProbeWindow: Double = 15, fastProbeInterval: Double = 0.3
    private var disconnectedAt: CFTimeInterval?   // 这一轮断线从何时起；出画面归零
    private var reconnectProbing = false
    private var lastStats = (t: CACurrentMediaTime(), recv: 0, dec: 0)
    private var rememberFrame = false

    /// --music "歌名|演出者|进度0..1"：快照测试用的固定状态
    static func testMusic(_ s: String) -> NowPlayingInfo {
        let f = s.components(separatedBy: "|")
        let p = f.count > 2 ? Double(f[2]) ?? 0 : 0
        return NowPlayingInfo(title: f[0], artist: f.count > 1 ? f[1] : "", duration: 100, position: max(0, min(1, p)) * 100,
                              playing: true, stamp: CACurrentMediaTime(), fixed: true)
    }

    /// 狀態列圖示：一個帶眼睛的圓角方塊（template，自動適應深色選單列）
    private static func statusIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let screen = NSBezierPath(roundedRect: NSRect(x: 2.5, y: 4, width: 13, height: 10.5),
                                      xRadius: 3, yRadius: 3)
            screen.lineWidth = 1.4; screen.stroke()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 6, y: 8.2, width: 2.3, height: 2.3)).fill()
            NSBezierPath(ovalIn: NSRect(x: 9.7, y: 8.2, width: 2.3, height: 2.3)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }

    /// 激活时要有主菜单栏（否则菜单栏空白）。命令本体仍在右键/状态栏菜单里；
    /// 这里按 Mac 惯例放「关于 / 隐藏 / 结束」和两个最常用动作。
    func rebuildMainMenu() { installMainMenu() }

    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("menu.about", "关于 HomePlay"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: L("menu.settings", "设置…"), action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let hide = NSMenuItem(title: L("menu.hidePet", "隐藏桌宠"), action: #selector(hidePet), keyEquivalent: "h")
        hide.target = self
        appMenu.addItem(hide)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("menu.quit", "退出 HomePlay"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let petItem = NSMenuItem(); main.addItem(petItem)
        let petMenu = NSMenu(title: L("menu.pet", "桌宠"))
        if let view {
            for (title, sel, key, mods) in [
                (view.carPlayAction.title, view.carPlayAction.action, "", NSEvent.ModifierFlags()),
                (L("menu.faceOverview", "表盘总览…"), #selector(PetView.menuFaceOverview), "", NSEvent.ModifierFlags()),
                (L("menu.zoomIn", "放大"), #selector(PetView.menuZoomIn), "+", .command),
                (L("menu.zoomOut", "缩小"), #selector(PetView.menuZoomOut), "-", .command),
                (L("menu.zoomDefault", "默认"), #selector(PetView.menuZoomDefault), "0", .command),
            ] as [(String, Selector, String, NSEvent.ModifierFlags)] {
                let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
                item.keyEquivalentModifierMask = mods
                item.target = view
                petMenu.addItem(item)
            }
        }
        let siri = NSMenuItem(title: L("menu.siri", "叫 Siri（F5）"), action: #selector(menuSiri), keyEquivalent: "")
        siri.target = self
        petMenu.addItem(.separator())
        petMenu.addItem(siri)
        petItem.submenu = petMenu
        NSApp.mainMenu = main
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = item.button {
            b.image = Self.statusIcon()
            b.imageScaling = .scaleProportionallyDown
            b.toolTip = "HomePlay"
            b.target = self
            b.action = #selector(showStatusMenu)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        log("status item installed visible=\(item.isVisible) button=\(item.button != nil)")
    }

    @objc private func hidePet() {
        view.setOccluded(true)              // 隐藏期间停掉主循环与轮询；也在结束直播前拦住摄像头恢复
        if view.showingVideo { toggle() }   // 看不见就不该继续直播/解码
        NowPlayingPoller.shared.paused = true
        window?.orderOut(nil)               // 不结束 App：状态栏图标还在，随时显示回来
        // 明确隐藏＝马上关摄像头，不等遮挡防抖；用户看不见它时不该亮绿点。
        if gazeFollow {
            gazeOccludeWork?.cancel(); gazeOccludeWork = nil
            if GazeTracker.shared.setPaused(true) {
                appendDiag("gaze.log", "camera pause: pet hidden")
            }
        }
    }

    @objc private func showPet() {
        NSApp.unhide(nil)
        guard let w = window else { return }
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(w.frame) }), let vf = NSScreen.main?.visibleFrame {
            w.setFrameOrigin(NSPoint(x: vf.maxX - w.frame.width - 24, y: vf.minY + 24))
        }
        w.makeKeyAndOrderFront(nil)
        view.setOccluded(false)             // 恢复主循环；实际遮挡状态下一次通知会校正
        gazeOccludeWork?.cancel(); gazeOccludeWork = nil
        resumeGazeIfPossible("pet shown")
    }

    @objc private func showStatusMenu() {
        guard let view, let b = statusItem?.button else { return }
        let menu = view.buildContextMenu()
        // 桌宠被隐藏或拖出所有屏幕时，右键已经够不着；状态栏给显示/隐藏开关
        let offscreen = !(window?.frame.intersects(NSScreen.screens.reduce(CGRect.null) { $0.union($1.visibleFrame) }) ?? false)
        let visible = (window?.isVisible ?? false) && !offscreen
        let toggle: NSMenuItem
        if visible {
            toggle = NSMenuItem(title: L("menu.hidePet", "隐藏桌宠"), action: #selector(hidePet), keyEquivalent: "")
        } else {
            toggle = NSMenuItem(title: L("menu.showPet", "显示桌宠"), action: #selector(showPet), keyEquivalent: "")
        }
        toggle.target = self
        menu.insertItem(toggle, at: 0)
        menu.insertItem(.separator(), at: 1)
        // 用螢幕座標在圖示下方展開：按鈕內部座標（非翻轉）指向上方會把選單彈出螢幕
        let anchor = NSPoint(x: b.window?.frame.midX ?? NSEvent.mouseLocation.x,
                             y: (b.window?.frame.minY ?? NSEvent.mouseLocation.y) - 4)
        view.startMenuTicker()
        menu.popUp(positioning: nil, at: anchor, in: nil)
        view.stopMenuTicker()
    }

    private func sendPhoneMedia(_ c: MediaCommand) {
        let cmd: String
        switch c {
        case .play: cmd = "play"
        case .pause: cmd = "pause"
        case .playPause: cmd = "playPause"
        case .next: cmd = "next"
        case .previous: cmd = "previous"
        }
        client?.sendMedia(cmd)
    }

    /// F5 → 叫手机 Siri。Carbon 全局热键不需要「输入监控」权限（NSEvent 全局监听才需要）。
    /// 注意 macOS 默认把 F5 绑给听写：注册不会失败，按 F5 可能同时起系统听写；可在
    /// 系统设置 › 键盘 › 听写 里把快捷键换掉。注册结果写到 hotkey.txt 方便排查。
    private func installSiriHotKey() {
        // 按下與放開都要：F5 按住說話
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            let down = event.map { GetEventKind($0) == UInt32(kEventHotKeyPressed) } ?? true
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .homePlaySiriHotKey, object: nil, userInfo: ["down": down])
            }
            return noErr
        }, 2, &types, nil, &siriHotKeyHandler)
        let id = EventHotKeyID(signature: OSType(0x48504C59), id: 1)   // 'HPLY'
        let reg = RegisterEventHotKey(UInt32(kVK_F5), 0, id, GetApplicationEventTarget(), 0, &siriHotKey)
        // 听写键位的 F5 可能吞掉普通热键；⌥F5 作为无冲突的保底
        let id2 = EventHotKeyID(signature: OSType(0x48504C59), id: 2)
        let reg2 = RegisterEventHotKey(UInt32(kVK_F5), UInt32(optionKey), id2, GetApplicationEventTarget(), 0, &siriHotKeyAlt)
        let url = ReceiverLauncher.configURL().deletingLastPathComponent().appendingPathComponent("hotkey.txt")
        let text = "F5 handler=\(handlerStatus) register=\(reg) optionF5=\(reg2)\n"
        try? text.data(using: .utf8)?.write(to: url)
        log(text.trimmingCharacters(in: .newlines))
        NotificationCenter.default.addObserver(forName: .homePlaySiriHotKey, object: nil, queue: .main) { [weak self] note in
            self?.siriKey(down: note.userInfo?["down"] as? Bool ?? true)
        }
    }

    /// F5 按住說話：按下＝requestSiri 按下（開始聽）、放開＝按鍵放開（結束）。
    /// 還沒直播時先進 CarPlay，連上後依當時是否還按著補送按下或按一下（接收器在 RECORD 前也會先記著）。
    func siriKey(down: Bool) {
        let now = CACurrentMediaTime()
        if down {
            guard siriHold.press(now: now) else { return }
            siriOrb.downAt = now; view?.face.forceDirty = true   // 錶面上的 Siri 球（Faces/Capsule.swift）
            siriDownSent = false
            appendDiag("siri.log", "Siri key down")
            siriHoldWatch?.invalidate()
            siriHoldWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, self.siriHold.overdue(now: CACurrentMediaTime()) else { return }
                log("F5 按住超过 \(Int(SiriHoldKey.maxHold)) 秒：自动放开")
                self.siriKey(down: false)
            }
            requestMicrophoneIfNeeded(announce: true, reason: "Siri") { [weak self] ok in
                guard let self else { return }
                guard ok else { _ = self.siriHold.release(); self.showMicDenied(); return }
                if self.client == nil || !self.isLive {
                    self.pendingSiri = true
                    log("叫 Siri：还没在直播，先进入 CarPlay")
                    self.enterCarPlay()
                } else if self.siriHold.held {
                    self.client?.sendSiri(down: true)
                    self.siriDownSent = true
                } else {
                    self.client?.sendSiri()   // 授權框期間就放開了：當成按一下
                }
            }
        } else {
            guard siriHold.release() else { return }
            siriOrb.upAt = now; view?.face.forceDirty = true
            siriHoldWatch?.invalidate(); siriHoldWatch = nil
            appendDiag("siri.log", "Siri key up")
            if siriDownSent {
                siriDownSent = false
                client?.sendSiri(down: false)
            }
        }
    }

    /// 接收器轉來的通話狀態：通話中顯示來電卡；響鈴時把 CarPlay 叫到前面（每通一次）
    private func applyCall(_ call: PhoneCallInfo) {
        callCard.model.call = call
        if call.showsCard, let window {
            callCard.show(attachedTo: window)
        } else {
            callCard.hide()
        }
        guard call.isIncomingRing else {
            if !call.showsCard { ringFrontedFor = nil }
            return
        }
        let key = call.uuid ?? "ringing"
        guard ringFrontedFor != key else { return }
        ringFrontedFor = key
        log("来电响铃：把 CarPlay 叫到前面")
        if view.showingVideo || resumeFromBackground() { return }
        enterCarPlay()
    }

    @objc private func menuSiri() {
        let now = Date()
        guard now.timeIntervalSince(lastSiriAt) > 0.5 else { return }   // Carbon 与全局监听可能同时触发
        lastSiriAt = now
        // 诊断：F5/菜单每次触发都留一行，方便确认热键到底有没有到
        appendDiag("siri.log", "Siri trigger")
        requestMicrophoneIfNeeded(announce: true, reason: "Siri") { [weak self] ok in
            guard let self else { return }
            guard ok else { self.showMicDenied(); return }
            if self.client == nil || !self.isLive {
                self.pendingSiri = true
                log("叫 Siri：还没在直播，先进入 CarPlay")
                self.enterCarPlay()
            } else {
                self.client?.sendSiri()
            }
        }
    }

    // MARK: 跟随我（摄像头）

    private func startGazeFollow(announce: Bool) {
        // 用户从菜单打开时激活一下 App，摄像头授权框才不会落在后台看不见。
        if announce { NSApp.activate(ignoringOtherApps: true) }
        // 登录恢复不主动弹摄像头权限。
        if !announce, AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
            gazeFollow = false
            UserDefaults.standard.set(false, forKey: Self.gazeFollowKey)
            view.setGazeEnabled(false)
            log("gaze follow not restored (camera not authorized)")
            return
        }
        GazeTracker.shared.onSample = { [weak self] s in self?.view.applyGaze(s) }
        GazeTracker.shared.setTrackFaces(true)
        GazeTracker.shared.start { [weak self] ok, reason in
            guard let self else { return }
            if ok {
                self.gazeFollow = true
                UserDefaults.standard.set(true, forKey: Self.gazeFollowKey)
                self.view.setGazeEnabled(true)
                log("gaze follow started")
                // 打开时如果正在直播、锁屏、或桌宠被遮住，先别让摄像头亮着；
                // 条件解除后由 showVideo/解锁/遮挡观察者恢复。
                if !self.view.gazeShouldRun, GazeTracker.shared.setPaused(true) {
                    let why = self.view.occluded ? "pet occluded" : "screen locked"
                    appendDiag("gaze.log", "camera pause: \(why)")
                }
            } else {
                self.gazeFollow = false
                UserDefaults.standard.set(false, forKey: Self.gazeFollowKey)
                self.view.setGazeEnabled(false)
                log("gaze follow failed: \(reason ?? "?")")
                if announce { self.showGazeDenied(reason) }
            }
        }
    }

    // MARK: 设置窗口（Settings/）用的桥：读状态、走菜单同一条路

    static let alwaysOnTopKey = "HomePlayAlwaysOnTop"
    static var alwaysOnTop: Bool { UserDefaults.standard.object(forKey: alwaysOnTopKey) as? Bool ?? true }

    struct SettingsSnapshot {
        var loginItem: Bool, loginAvailable: Bool, autoConnect: Bool, alwaysOnTop: Bool
        var finish: Finish, faceStyle: FaceStyle, viewMode: ViewMode
        var gazeFollow: Bool, followDegrees: Double, gazePitch: Double, roomLight: Bool
        var petWidth: Double
    }
    func settingsSnapshot() -> SettingsSnapshot {
        let bundled = Bundle.main.bundleIdentifier != nil
        return SettingsSnapshot(
            loginItem: bundled && SMAppService.mainApp.status == .enabled, loginAvailable: bundled,
            autoConnect: ReceiverAgent.isInstalled, alwaysOnTop: Self.alwaysOnTop,
            finish: view.model.finish, faceStyle: view.face.style, viewMode: view.viewMode,
            gazeFollow: gazeFollow, followDegrees: view.followDegrees, gazePitch: Double(view.gazePitchDegrees),
            roomLight: roomLightOn, petWidth: Double(view.window?.frame.width ?? Pet.defaultWidth))
    }
    /// 设置里的「大小」滑杆：拖动时即时缩放（以窗口中心为准，不跑出屏幕）
    func setPetWidth(_ w: Double) { view.resizeWindow(toWidth: CGFloat(w), anchorCenter: true) }
    /// 调 PetView 的菜单动作（同一份实现）；represented 放进 NSMenuItem.representedObject
    func settingsPerform(_ selector: String, _ represented: Any?) {
        let item = NSMenuItem()
        item.representedObject = represented
        let sel = NSSelectorFromString(selector)
        if view.responds(to: sel) { view.perform(sel, with: item) } else { log("settings: no action \(selector)") }
        rebuildMainMenu()
    }
    func setAlwaysOnTop(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.alwaysOnTopKey)
        window.level = on ? .floating : .normal
        log("always on top \(on)")
    }
    func setFollowDegrees(_ d: Double) {
        Aim.savedFollowDegrees = d
        view.followDegrees = Aim.savedFollowDegrees
    }
    @objc func showSettings(_ sender: Any?) { SettingsWindowController.show(app: self) }

    /// 权限闸门：已允许直接放行；桌宠看得见就先出说明卡（PermissionPrimer），用户点「继续」才弹系统框；
    /// 看不见（隐藏、被遮住、直播中）就直接走系统框。被拒时卡片给「打开系统设置」，不再弹 NSAlert。
    func withPermission(_ k: PermissionKind, then: @escaping (Bool) -> Void) {
        let st = PermissionCenter.status(k)
        if st == .granted { then(true); return }
        let canShow = window?.isVisible == true && !view.occluded && !view.showingVideo
        if canShow {
            view.wakeFromPosterForGuide()
            PermissionPrimer.present(k) { [weak self] ok in
                if ok, k == .inputMonitoring { SystemKeyTap.retryAfterGrant() }
                self?.rebuildMainMenu()
                then(ok)
            }
            log("permission primer \(k.rawValue) (\(st == .denied ? "denied" : "intro"))")
            return
        }
        guard st == .notDetermined else { then(false); return }
        NSApp.activate(ignoringOtherApps: true)
        PermissionCenter.request(k) { ok in
            if ok, k == .inputMonitoring { SystemKeyTap.retryAfterGrant() }
            then(ok)
        }
    }

    /// 卡片换阶段时给表情：说明＝好奇，等系统框＝专注，允许＝笑，拒绝＝担心
    private func wirePermissionMoods() {
        PermissionPrimer.onPhase = { [weak self] p in
            guard let self else { return }
            let now = CACurrentMediaTime()
            switch p {
            case .intro: self.view.mood.show(.idle, for: 2.5, now: now)
            case .waiting: self.view.mood.show(.thinking, for: 1.5, now: now)
            case .granted: self.view.mood.show(.happy, for: 1.6, now: now)
            case .denied: self.view.mood.show(.worried, for: 2.0, now: now)
            }
        }
        // 第一次的操作提示收起后：F5 还接不住、也没问过「输入监控」，就接着说明一次
        Onboarding.onDismiss = { [weak self] in
            guard let self, !SystemKeyTap.isActive,
                  PermissionCenter.status(.inputMonitoring) == .notDetermined else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.withPermission(.inputMonitoring) { _ in } }
        }
    }

    func toggleGazeFollow() {
        if gazeFollow {
            gazeFollow = false
            UserDefaults.standard.set(false, forKey: Self.gazeFollowKey)
            GazeTracker.shared.setTrackFaces(false)
            if !roomLightOn { GazeTracker.shared.stop() }
            view.setGazeEnabled(false)
        } else {
            withPermission(.camera) { [weak self] ok in
                guard let self else { return }
                if ok { self.startGazeFollow(announce: true) } else { self.rebuildMainMenu() }
            }
        }
    }

    static func micStatusText(_ s: AVAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "granted"
        case .notDetermined: return "not-requested"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }

    private func writeMicStatus(_ text: String) {
        let url = ReceiverLauncher.configURL().deletingLastPathComponent().appendingPathComponent("mic-permission.txt")
        try? text.data(using: .utf8)?.write(to: url)
    }

    /// 最小权限：只在用户真正进入 CarPlay（非后台挂接）或主动叫 Siri 时才申请麦克风。
    private func requestMicrophoneIfNeeded(announce: Bool, reason: String, then: ((Bool) -> Void)? = nil) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            writeMicStatus("granted")
            then?(true)
        case .denied, .restricted:
            writeMicStatus(Self.micStatusText(status))
            then?(false)
        case .notDetermined:
            if let then { micWaiters.append(then) }
            guard !micPrompted else { return }   // 同一轮授权框还在：等它的结果一起回调
            micPrompted = true
            if announce, window?.isVisible == true, !view.occluded, !view.showingVideo {
                // 先在屏幕上说明，用户点「继续」才弹系统框（PermissionPrimer）
                withPermission(.microphone) { [weak self] ok in
                    guard let self else { return }
                    self.micPrompted = false
                    self.writeMicStatus(ok ? "granted" : "denied")
                    log("microphone permission \(ok ? "granted" : "denied") for \(reason) (primer)")
                    let waiters = self.micWaiters
                    self.micWaiters.removeAll()
                    waiters.forEach { $0(ok) }
                }
                return
            }
            if announce { NSApp.activate(ignoringOtherApps: true) }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] ok in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.writeMicStatus(ok ? "granted" : "denied")
                    log("microphone permission \(ok ? "granted" : "denied") for \(reason)")
                    let waiters = self.micWaiters
                    self.micWaiters.removeAll()
                    waiters.forEach { $0(ok) }
                }
            }
        @unknown default:
            writeMicStatus("unknown")
            then?(false)
        }
    }

    var micStatusLabel: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return L("mic.status.on", "已允许")
        case .notDetermined: return L("mic.status.ask", "首次进入 CarPlay 时询问")
        case .denied, .restricted: return L("mic.status.off", "已关闭")
        @unknown default: return L("mic.status.off", "已关闭")
        }
    }

    private func showMicDenied() {
        if window?.isVisible == true, !view.occluded, !view.showingVideo {
            withPermission(.microphone) { _ in }; return    // 拒绝卡：给「打开系统设置」
        }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = L("mic.denied.title", "麦克风权限未开启")
        a.informativeText = L("mic.denied.body", "CarPlay 画面不受影响；Siri 和电话通话需要麦克风。请在系统设置 › 隐私与安全性 › 麦克风里允许 HomePlay。")
        a.addButton(withTitle: L("mic.openSettings", "打开系统设置"))
        a.addButton(withTitle: L("gaze.denied.ok", "好"))
        if a.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func showMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            requestMicrophoneIfNeeded(announce: true, reason: "menu") { [weak self] ok in
                if !ok { self?.showMicDenied() }
            }
        case .denied, .restricted:
            showMicDenied()
        case .authorized:
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = L("mic.allowed.title", "麦克风已允许")
            a.informativeText = L("mic.allowed.body", "CarPlay 通话和 Siri 可以使用麦克风；屏幕画面与本地播放不受影响。")
            a.addButton(withTitle: L("gaze.denied.ok", "好"))
            a.runModal()
        @unknown default:
            showMicDenied()
        }
    }

    private func showGazeDenied(_ reason: String?) {
        if (reason == nil || reason == "camera permission denied"),
           window?.isVisible == true, !view.occluded, !view.showingVideo {
            withPermission(.camera) { _ in }; return         // 拒绝卡：给「打开系统设置」
        }
        let a = NSAlert()
        a.messageText = L("gaze.denied.title", "需要相机权限")
        a.informativeText = (reason == nil || reason == "camera permission denied")
            ? L("gaze.denied.body", "在系统设置 › 隐私与安全性 › 相机里允许 HomePlay，跟随我或房间光线才能使用相机。画面只在本机处理，不保存。")
            : (reason ?? "")
        a.addButton(withTitle: L("gaze.denied.ok", "好"))
        a.runModal()
    }

    func applicationWillTerminate(_ note: Notification) {
        PhoneNowPlayingBridge.shared.clear()
        // 先把手機會話收乾淨（receiver 收到 stop 會結束 CarPlay 並退出），再關本地進程。
        // applicationWillTerminate 之後主隊列不再跑，所以這裡短暫等 receiver 收下命令。
        reconnectTimer?.invalidate(); reconnectTimer = nil
        healthTimer?.invalidate(); statsTimer?.invalidate()
        GazeTracker.shared.stop()   // 退出时立刻关摄像头（绿点灭掉）
        // 只有真的在直播時才向 receiver 發 stop；閒置退出不要誤殺 login item 的常駐 receiver
        if !Self.isDiagnosticRun, isLive || view.showingVideo, let c = client {
            c.onLive = nil; c.onFrameReceived = nil; c.onText = nil
            c.requestTeardown()
            Thread.sleep(forTimeInterval: 0.45)
        }
        ReceiverLauncher.stop()
        if rememberFrame, let f = window?.frame { WindowFrameStore.save(f) }   // 刚拖完就退出也不丢位置
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        wirePermissionMoods()
        if HomePlayState.isolated { log("rehearsal state: Application Support/\(HomePlayState.name), agent \(ReceiverAgent.label)") }
        tightenLogPermissions()
        // 除錯／截图：开机 3 秒后在桌宠上弹出右键菜单（--show-menu）
        if CommandLine.arguments.contains("--show-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, let v = self.view else { return }
                if let w = self.window, let main = NSScreen.screens.first {
                    w.setFrameOrigin(NSPoint(x: main.frame.midX - w.frame.width / 2, y: main.frame.midY - w.frame.height / 2))
                }
                v.buildContextMenu().popUp(positioning: nil, at: NSPoint(x: v.bounds.midX, y: v.bounds.midY), in: v)
            }
        }
        // 除錯／截图：开机直接打开设置的某一页（--open-settings general|appearance|carplay|camera|permissions）
        if CommandLine.arguments.contains("--clock-look-panel") {   // 截图：打开「字体与颜色」面板
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.view.menuClockLook(nil) }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--open-settings") {
            let name = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "general"
            let pane = SettingsSection(rawValue: name) ?? .general
            if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }   // 截图：深色外观
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { SettingsWindowController.show(app: self, pane: pane) }
        }
        if CommandLine.arguments.contains("--nowplaying-selftest") {
            let ok = PhoneNowPlayingBridge.shared.selftest()
            log(ok ? "nowplaying selftest OK" : "nowplaying selftest FAIL")
            exit(ok ? 0 : 1)
        }
        // 基准/截图不碰真实 LaunchAgent、配置和麦克风权限：它们是诊断进程，不能改用户的常驻接收器。
        let diagnosticRun = benchSeconds > 0 || snapshotPath != nil || Self.isDiagnosticRun
        if !diagnosticRun {
            ReceiverAgent.migrateIfNeeded()   // 升级：把 LaunchAgent 指到新布局的接收器路径
            ReceiverLauncher.ensureConfigFile()   // 后台接收器先起时也要有配置
            // 已配过手机：把后台接收器补成开机常驻（老用户升级后也自动进入「一次配好、以后自动」）。
            // 用户明确在菜单里关过就不装，尊重选择。
            let startupCfg = ReceiverLauncher.loadConfig()
            if !startupCfg.phone.isEmpty {
                _ = ReceiverAgent.autoEnableIfNeeded(reason: "saved iPhone")
            }
            // 作业曾因端口冲突 exit(0) 会一直停着；开机/启动时轻轻催一下（已在跑则无操作）。
            if ReceiverAgent.isInstalled { _ = ReceiverAgent.kickstart() }
        }
        // 麦克风不再在启动时索取：只在用户第一次真正进入 CarPlay / 主动叫 Siri 时申请。
        // 这里只把当前状态写给接收器做诊断，不触发系统授权框。
        if !diagnosticRun {
            writeMicStatus(Self.micStatusText(AVCaptureDevice.authorizationStatus(for: .audio)))
        }
        // 上次的位置与大小（给了 --at / --size / --snapshot 就不动它，也不写回）
        let remember = origin == nil && !sizeGiven && snapshotPath == nil
        Pet.aspect = Pet.aspect(for: ViewMode.saved)   // 挂墙时窗口只框屏幕模组
        rememberFrame = remember
        let restored = remember ? WindowFrameStore.restore(WindowFrameStore.load(), visible: NSScreen.screens.map(\.visibleFrame)) : nil
        // 第一次打開（沒有記住的大小）：開大一點（380 pt），設定引導的字才清楚好讀；之後照使用者調的大小
        let firstWidth = (restored == nil && !sizeGiven) ? max(initialWidth, 380) : initialWidth
        let size = restored?.size ?? NSSize(width: firstWidth, height: firstWidth / Pet.aspect)
        window = PetWindow(size: size)
        view = PetView(frame: NSRect(origin: .zero, size: size), initialApart: initialApart, yaw: initialYaw, pitch: initialPitch)
        if let t = initialApartT { view.setInitialApart(t) }
        if let p = initialPart { view.pinAnatomy(p) }
        window.contentView = view
        view.updateFaceScale()
        if let lockedFace { view.lockFace(lockedFace) }
        if let finish { view.setFinish(finish) }   // 只给这次用，不写进偏好
        if let photosDir { view.face.photos = PhotoShelf(folder: URL(fileURLWithPath: photosDir, isDirectory: true)) }
        else if let saved = UserDefaults.standard.string(forKey: PetView.photoFolderKey), FileManager.default.fileExists(atPath: saved) {
            view.face.photos = PhotoShelf(folder: URL(fileURLWithPath: saved, isDirectory: true))   // 偏好设定里选的照片资料夹
        }
        if let eventTest { view.face.calendarTile = Self.testEvent(eventTest) }
        if Onboarding.forced || (snapshotPath == nil && !Onboarding.done) { view.face.armOnboarding() }   // hello 写完再出
        if let faceStyle { view.setFaceStyle(faceStyle, remember: false) }
        if forceHello { view.face.sayHello(CACurrentMediaTime()) }   // 官網素材：從這裡重新計時，逐格才穩定
        if let timerSeconds { view.face.startTimer(seconds: timerSeconds) }
        if let musicTest { view.face.setNowPlaying(Self.testMusic(musicTest)) }
        if showBanner { view.face.showBanner() }
        if let hourOverride { view.face.hourOverride = hourOverride }
        if forceNear { view.forceNear = true }
        view.onTouch = { [weak self] x, y, down in self?.client?.sendTouch(x: x, y: y, down: down) }
        view.carVideo.send = { [weak self] s in self?.client?.sendRaw(s) }
        // Mac 內建 AirPlay 接收器在播影片：桌寵好奇地看著那個視窗（只讀視窗清單，不錄畫面）
        if snapshotPath == nil, benchSeconds == 0 {
            AirPlayWatch.onChange = { [weak self] on in
                guard let self else { return }
                let now = CACurrentMediaTime()
                if on { self.view.mood.show(.thinking, for: 6 * 3600, now: now) } else { self.view.mood.show(.happy, for: 1.2, now: now) }
                log("AirPlay video on this Mac: \(on)")
            }
            AirPlayWatch.start()
        }
        view.carVideo.onStarted = { [weak self] in
            guard let self else { return }
            _ = self.resumeFromBackground()   // CarPlay 在後台時，影片一來就把它叫回前面
            log("car video started")
        }
        view.carVideo.onEnded = { [weak self] in
            self?.client?.requestKeyframe()   // 回到 CarPlay：要一張關鍵幀，畫面馬上回來
            log("car video ended")
        }
        view.onToggleLive = { [weak self] in self?.toggle() }
        view.onCancelConnect = { [weak self] in self?.cancelConnect() }
        view.onForceEnter = { [weak self] in self?.enterCarPlay() }
        view.onSelectPhone = { [weak self] address in self?.switchPhone(to: address) }
        view.onPairNewPhone = { [weak self] in self?.pairNewPhone() }
        view.onCopyDiagnostics = { [weak self] in self?.copyDiagnostics() }
        view.onSetWiFi = { [weak self] ssid, password in
            ReceiverLauncher.saveWiFi(ssid: ssid, passphrase: password)
            CarPlayWiFi.ssid = ssid
            CarPlayOverlayState.wifiHelp = false       // 密码刚存过：排障卡片收起，给连接一次机会
            CarPlayOverlayState.wifiNeedsPassword = false
            self?.client?.sendWiFi(ssid: ssid, passphrase: password)
            log("Wi-Fi settings updated (values not logged)")
        }
        view.onForgetPhone = { [weak self] address in
            ReceiverLauncher.forgetPhone(address)
            if let self {
                self.switchingPhone = true
                CarPlayOverlayState.wifiHelp = false
                CarPlayOverlayState.wifiNeedsPassword = false
                CarPlayOverlayState.needsTrust = false
                CarPlayPhoneBook.phones.removeAll {
                    CarPlayPhoneBook.normalize($0.address) == CarPlayPhoneBook.normalize(address)
                }
                if CarPlayPhoneBook.isCurrent(address) { CarPlayPhoneBook.current = nil }
                self.client?.sendForgetPhone(address: address)
            }
            log("forgot iPhone (address not logged)")
        }
        view.onRestorePhones = { [weak self] in
            ReceiverLauncher.restoreIgnoredPhones()
            self?.client?.sendRestorePhones()
            log("restored ignored iPhones")
        }
        view.decoder.onDecoded = { [weak self] in self?.health.frameDecoded(now: CACurrentMediaTime()) }
        view.decoder.onDecodeError = { [weak self] in
            guard let self else { return }
            self.act(self.health.decodeError(now: CACurrentMediaTime()), why: "解码报错")
        }
        // 健康检查与统计只在直播时跑：不在直播就不该每 250 ms 叫醒一次
        PhoneNowPlayingBridge.shared.configure()
        PhoneNowPlayingBridge.shared.onUpdate = { [weak self] info in self?.view.face.setNowPlaying(info) }
        PhoneNowPlayingBridge.shared.onCommand = { [weak self] cmd in self?.sendPhoneMedia(cmd) }
        PhoneNowPlayingBridge.shared.onSeek = { [weak self] ms, track in self?.client?.sendSeek(positionMs: ms, trackId: track) }
        view.onVideoState = { [weak self] on in
            guard let self else { return }
            if on { self.startLiveTimers() } else { self.stopLiveTimers() }
            self.rebuildMainMenu()   // 主菜单的「进入/退出 CarPlay」跟着状态走
        }
        if let origin { window.setFrameOrigin(origin) }
        else if let restored { window.setFrameOrigin(restored.origin) }
        else if let vf = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 24, y: vf.minY + 24))
        }
        installMainMenu()

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        if remember { watchWindowFrame() }
        if snapshotPath == nil && benchSeconds == 0 { watchOcclusion() }
        // 換螢幕／拔掉外接螢幕後，如果桌寵整個跑到可見區域外，把它拉回來
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let w = self.window else { return }
            let visible = NSScreen.screens.map(\.visibleFrame)
            guard !visible.contains(where: { $0.intersects(w.frame) }) else { return }
            guard let vf = NSScreen.main?.visibleFrame else { return }
            w.setFrameOrigin(NSPoint(x: vf.maxX - w.frame.width - 24, y: vf.minY + 24))
            log("window rescued to visible screen")
        }
        // 狀態列常駐入口：桌寵被全螢幕蓋住或拖丟時，選單／關於／結束仍找得到（accessory App 沒有主選單列）
        if snapshotPath == nil && benchSeconds == 0 { installStatusItem() }
        // 全局 .magnify 监听在架构上收不到非激活面板的手势（magnify=30 是 AppKit 给目标 App
        // 合成的）；真正的全局捏合是下面的 MultitouchSupport 接触帧（TrackpadPinch），
        // 本地 magnify 只在 App 已激活时作为后备，⌥＋双指滚动仍然可用。
        if snapshotPath == nil && benchSeconds == 0 {
            globalMagnify = NSEvent.addGlobalMonitorForEvents(matching: [.magnify]) { [weak self] e in
                guard let self, let w = self.window else { return }
                let inside = w.frame.contains(NSEvent.mouseLocation)
                appendDiag("gesture.log", "global magnify mag=\(e.magnification) inside=\(inside) mouse=\(NSEvent.mouseLocation) frame=\(w.frame)")
                guard inside else { return }
                DispatchQueue.main.async { self.view.magnify(with: e) }
            }
            if globalMagnify == nil { log("global magnify monitor unavailable (need click-to-focus)") }
            installSiriHotKey()
            callCard.model.onAction = { [weak self] action in
                log("来电卡：\(action.rawValue)")
                self?.client?.sendTelephony(action)
            }
            // F5（聽寫鍵）：普通 keyDown/Carbon 熱鍵都看不到（實證），用會話級 CGEventTap
            // 抓 keyDown 176 ／ NX_SYSDEFINED 輔助鍵。輸入監控授權過了才裝得上；裝不上就
            // 退回 ⌥F5（Carbon）。要確認鍵盤發的是哪個鍵碼時，用 HOMEPLAY_DIAG_KEYS=1 啟動。
            SystemKeyTap.setSiriHandler { [weak self] down in self?.siriKey(down: down) }
            if SystemKeyTap.install() {
                appendDiag("syskeys.log", "tap installed (dictation key=\(SystemKeyTap.siriKeyCode))")
            } else {
                // 授权可能是启动后才给的：装不上时后台线程会继续重试一分钟。
                appendDiag("syskeys.log", "tap create failed (need Input Monitoring; retrying)")
                log("F5 系统键 tap 暂时装不上（缺输入监控）；⌥F5 仍可用")
            }
            // 輸入監控拿到后，普通 F5（keyDown 96）也會走到這裡。只認這一顆，其餘按鍵不落地。
            appendDiag("monitors.txt", "AXTrusted=\(AXIsProcessTrusted()) magnify=\(globalMagnify != nil) tcc")
            globalKeys = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] e in
                guard e.keyCode == 96, e.type == .keyUp || !e.isARepeat else { return }
                let down = e.type == .keyDown
                DispatchQueue.main.async { self?.siriKey(down: down) }
            }
            appendDiag("monitors.txt", "keys=\(globalKeys != nil) AXTrusted=\(AXIsProcessTrusted())")
            // ⌥＋雙指滾動＝縮放（不點桌寵也能用）：滾輪事件按指針所在窗口投遞，全局監視攔
            // 「鼠標在桌寵上＋按著 option」的縱向滾動。App 自己收到時 scrollWheel 已處理。
            globalScroll = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] e in
                guard let self, let w = self.window else { return }
                guard e.modifierFlags.contains(.option) else { return }
                guard w.frame.contains(NSEvent.mouseLocation) else { return }
                let dy = e.scrollingDeltaY
                guard dy != 0 else { return }
                appendDiag("gesture.log", "global opt-scroll dy=\(dy) precise=\(e.hasPreciseScrollingDeltas)")
                DispatchQueue.main.async {
                    self.view.resizeWindow(toWidth: self.view.bounds.width * (1 + CGFloat(dy) * 0.01),
                                           anchorCenter: true)
                }
            }
            appendDiag("monitors.txt", "scroll=\(globalScroll != nil)")
            // 真正的全局双指捏合：NSEvent.magnify 只投递给已激活的 App，桌宠是
            // .nonactivatingPanel 收不到。MultitouchSupport 直接读接触帧，不用点、
            // 不抢焦点；指针在桌宠上才缩放，失败就继续用 ⌥＋双指滚动。
            let mtDevices = TrackpadPinch.shared.start()
            if mtDevices > 0 {
                TrackpadPinch.shared.onMagnify = { [weak self] factor in
                    guard let self, let w = self.window else { return }
                    guard w.frame.contains(NSEvent.mouseLocation) else { return }
                    TrackpadPinch.shared.markApplied()
                    self.view.resizeWindow(toWidth: self.view.bounds.width * factor, anchorCenter: true)
                }
                appendDiag("gesture.log", "MT pinch monitor started devices=\(mtDevices)")
            } else {
                appendDiag("gesture.log", "MT pinch unavailable (fallback: option+scroll)")
                log("触控板捏合监视装不上（MultitouchSupport 不可用）；⌥＋双指滚动仍可用")
            }
        }
        // 房间光线：默认开；快照/基准不碰摄像头，保持可复现的棚拍环境。
        if snapshotPath == nil, benchSeconds == 0, roomLightOn {
            startRoomLight(announce: false)
        }
        // 上次打开过「跟随我」：登录后自动恢复（权限已授权时不会再弹窗）
        if snapshotPath == nil, benchSeconds == 0, gazeFollow {
            startGazeFollow(announce: false)
        }
        if let v = initialView {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.view.applyViewPreset(v) }
        }
        if let g = gazeTest {
            view.setGazeEnabled(true)
            view.applyGaze(GazeTracker.Sample(x: g.x, y: g.y, roll: 0, size: 0.3, present: true))
        }
        if benchSeconds > 0 {
            view.face.cancelHello()            // 基準不量啟動的 hello 動畫
            view.face.dismissOnboarding()
            startBench()
        }
        // 给截图与合成事件用：窗口在全局坐标（左上原点）的位置
        if let mainH = NSScreen.screens.first?.frame.height {
            let f = window.frame
            log("window \(Int(f.minX)) \(Int(mainH - f.maxY)) \(Int(f.width)) \(Int(f.height))")
        }
        if let endpoint { connect(endpoint) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.view.logProbes() }
        // 首次使用（没配过手机）：hello 提示收起后自动进一次 CarPlay，让接收器的首连
        // 引导卡（插线点信任 / 蓝牙配对 / 等待 iPhone）自然出现——新用户不用知道
        // 「重按」这个手势。已配过手机的不打扰（想看画面随时重按）；用户主动「忘记」
        // 过手机（ignoredPhones 非空）也不自动进场，避免每次启动都弹配对。
        let cfg = ReceiverLauncher.loadConfig()
        let freshInstall = !FileManager.default.fileExists(atPath: ReceiverLauncher.configURL().path)
        if snapshotPath == nil, benchSeconds == 0, endpoint == nil,
           freshInstall || (cfg.phone.isEmpty && cfg.ignoredPhones.isEmpty) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) { [weak self] in
                guard let self, !self.view.showingVideo, self.client == nil else { return }
                log("first-run: auto-entering CarPlay for pairing guide")
                self.enterCarPlay()
            }
        }
        // 已经配过手机：安静地挂到后台 receiver 上。没画面就不弹「连接中」，
        // iPhone 一旦连上就自动出画面——打开桌宠即可用，不用再重按。
        if snapshotPath == nil, benchSeconds == 0, endpoint == nil, !cfg.phone.isEmpty, Onboarding.done {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, !self.view.showingVideo, self.client == nil, !self.userStopped else { return }
                let target = "ws://127.0.0.1:\(ReceiverLauncher.port())"
                self.endpoint = target
                log("auto-attach: waiting for iPhone in background")
                self.ensureReceiver { [weak self] in
                    guard let self, !self.view.showingVideo, self.client == nil else { return }
                    self.connect(target, quiet: true)
                }
            }
        }
        // 驗證海報補丁：等 3D 真的卸下後只換眼睛（瞄一眼）；補丁上去後掛回 3D 拍一張真的，兩張比對
        if let dir = ProcessInfo.processInfo.environment["HOMEPLAY_PATCH_TEST"] {
            var phase = 0, patchesAt = 0
            let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] tm in
                guard let self else { return }
                if phase == 0, CACurrentMediaTime() > 4, self.view.debugDetached {
                    phase = 1; patchesAt = self.view.patches3D
                    if ProcessInfo.processInfo.environment["HOMEPLAY_PATCH_TEST_BIG"] != nil {
                        // 大範圍變化（連線過場蓋滿整面）：不該補丁，要掛回 3D 重畫；1.5 秒後記錄結果並拍一張
                        CarPlayOverlayState.forced = true; self.view.face.forceDirty = true
                        tm.invalidate()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            log("patch-test big: patches +\(self.view.patches3D - patchesAt), detached \(self.view.debugDetached)")
                            self.view.captureSnapshot { img in
                                if let img { try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/big.png")) }
                                exit(0)
                            }
                        }
                        return
                    }
                    Face.glanceOverride = true; self.view.face.forceDirty = true
                } else if phase == 1, self.view.patches3D > patchesAt {
                    phase = 2; tm.invalidate()
                    self.view.captureSnapshot { img in
                        if let img { try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/real.png")) }
                        exit(0)
                    }
                } else if phase == 1, !self.view.debugDetached { phase = 0; Face.glanceOverride = false }   // 中途掛回去了：重來
            }
            RunLoop.main.add(t, forMode: .common)
        }
        if let snapshotPath {
            // 自检出图：等弹簧停稳，存一张 RealityKit 快照（透明底）就退出。
            // --snapshot-glance／--snapshot-blink：同一格畫面再拍「瞄一眼」「閉眼」，
            // 三個狀態共用同一台相機與同一幀時鐘，官網疊圖時機身不會跳。
            DispatchQueue.main.asyncAfter(deadline: .now() + snapshotDelay) { [weak self] in
                guard let self else { exit(2) }
                self.view.logPose()
                var steps: [(path: String, note: String, prepare: () -> Void)] = [(snapshotPath, "open", {})]
                if let p = self.snapshotGlancePath { steps.append((p, "glance", { Face.glanceOverride = true })) }
                if let p = self.snapshotBlinkPath {
                    steps.append((p, "blink", { Face.glanceOverride = false; Face.blinkOverride = 0.1 }))
                }
                func shoot(_ i: Int) {
                    if i == steps.count { exit(0) }
                    let step = steps[i]; step.prepare()
                    if i > 0 { self.view.face.forceDirty = true }   // 第一張就是當下畫面，不重繪
                    DispatchQueue.main.asyncAfter(deadline: .now() + (i == 0 ? 0 : 0.12)) {
                        self.view.captureSnapshot { img in
                            guard let img else { exit(2) }
                            let rep = NSBitmapImageRep(cgImage: self.view.compositeOverlays(img))
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: step.path))
                            log("snapshot \(step.note) \(img.width)x\(img.height) -> \(step.path)")
                            shoot(i + 1)
                        }
                    }
                }
                // HOMEPLAY_FACE_PNG=路徑：另存平面的錶面貼圖（1024²，不經 3D），錶面設計對照用
                if let p = ProcessInfo.processInfo.environment["HOMEPLAY_FACE_PNG"] {
                    let f = self.view.face
                    f.renderScale = CGFloat(Double(ProcessInfo.processInfo.environment["HOMEPLAY_FACE_SCALE"] ?? "1") ?? 1)
                    var img = f.render()
                    // HOMEPLAY_FACE_TRANSITION=modular:0.3：換到 modular、拍過場進行到 30% 的那一格
                    if let spec = ProcessInfo.processInfo.environment["HOMEPLAY_FACE_TRANSITION"]?.split(separator: ":"), spec.count == 2,
                       let to = FaceStyle(rawValue: String(spec[0])), let x = Double(spec[1]) {
                        f.style = to
                        if let t = f.faceTransition { f.faceTransition = (t.sharp, t.frosted, CACurrentMediaTime() - x * Face.transitionDuration) }
                        img = f.render()
                    }
                    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: p))
                    log("face png \(img.width)x\(img.height) -> \(p)")
                }
                shoot(0)
            }
        }
    }

    /// 移动 / 缩放停下 0.5 s 后存一次
    private var frameSaveWork: DispatchWorkItem?
    private func watchWindowFrame() {
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.frameSaveWork?.cancel()
                let w = DispatchWorkItem { [weak self] in if let f = self?.window.frame { WindowFrameStore.save(f) } }
                self?.frameSaveWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
            }
        }
    }
    /// 被完全遮住就停渲染，露出来再继续
    /// 效能基準：數實際渲染幀數 + 讀 process CPU 時間，跑 N 秒後印一行並結束。
    private func startBench() {
        Face.renderCount = 0
        Face.dbgBlink = 0; Face.dbgApproach = 0; Face.dbgScreen = 0; Face.dbgLive = 0; Face.dbgOther = 0
        Face.dbgPal = 0; Face.dbgReveal = 0; Face.dbgFlow = 0; Face.dbgHello = 0; Face.dbgExpr = 0
        Face.renderSeconds = 0; Face.bgSeconds = 0; Face.textSeconds = 0; Face.islandSeconds = 0
        Face.cacheHits = 0; Face.cacheMisses = 0
        Face.pocketA = 0; Face.pocketC = 0; Face.pocketD = 0
        // 以 step() 的实际更新帧数计（RealityKit 的内部渲染帧没有公开回调）
        view.resetStepCount()
        let frames3D0 = view.frames3D, cycles3D0 = view.cycles3D
        let t0 = CACurrentMediaTime()
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        let cpu0 = Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
            + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
        DispatchQueue.main.asyncAfter(deadline: .now() + benchSeconds) { [weak self] in
            guard let self else { return }
            let wall = CACurrentMediaTime() - t0
            getrusage(RUSAGE_SELF, &ru)
            let cpu1 = Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
                + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
            let mb = Double(ru.ru_maxrss) / 1_048_576
            log(String(format: "bench frames=%d wall=%.1fs fps=%.1f cpu=%.2fs cpu%%=%.1f rss=%.0fMB faceRenders=%d prefFPS=%d frames3D=%d (%.1f/s) detaches=%d patches=%d dirty(blink=%d approach=%d screen=%d live=%d expr=%d)",
                       self.view.stepFrames, wall, Double(self.view.stepFrames) / wall, cpu1 - cpu0, (cpu1 - cpu0) / wall * 100, mb,
                       Face.renderCount, Int(self.view.render.__preferredFrameRate),
                       self.view.frames3D - frames3D0, Double(self.view.frames3D - frames3D0) / wall, self.view.cycles3D - cycles3D0, self.view.patches3D,
                       Face.dbgBlink, Face.dbgApproach, Face.dbgScreen, Face.dbgLive, Face.dbgExpr))
            log("dirty screen: pal=\(Face.dbgPal) reveal=\(Face.dbgReveal) flow=\(Face.dbgFlow) hello=\(Face.dbgHello) faceMs=\(String(format: "%.2f", Face.renderSeconds / Double(max(1, Face.renderCount)) * 1000)) bgMs=\(String(format: "%.2f", Face.bgSeconds / Double(max(1, Face.renderCount)) * 1000)) textMs=\(String(format: "%.2f", Face.textSeconds / Double(max(1, Face.renderCount)) * 1000)) islandMs=\(String(format: "%.2f", Face.islandSeconds / Double(max(1, Face.renderCount)) * 1000)) cache=\(Face.cacheHits)/\(Face.cacheHits + Face.cacheMisses) pocket=\(String(format: "%.2f/%.2f/%.2f", Face.pocketA / Double(max(1, Face.renderCount)) * 1000, Face.pocketC / Double(max(1, Face.renderCount)) * 1000, Face.pocketD / Double(max(1, Face.renderCount)) * 1000))")
            log(String(format: "state reveal %.3f target %.3f near %d style %@ mouse %.0f,%.0f frame %@",
                       Double(self.view.face.reveal), Double(self.view.face.revealTarget), self.view.mood.near ? 1 : 0,
                       self.view.face.style.rawValue, NSEvent.mouseLocation.x, NSEvent.mouseLocation.y,
                       NSStringFromRect(self.window.frame)))
            exit(0)
        }
    }

    private func startLiveTimers() {
        guard healthTimer == nil else { return }
        lastStats = (CACurrentMediaTime(), health.received, health.decoded)   // 清掉暂停期间的间隔，首行 fps 不偏低
        let h = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.view.showingVideo else { return }
            self.act(self.health.check(now: CACurrentMediaTime()), why: "停滞")
        }
        h.tolerance = 0.05
        RunLoop.main.add(h, forMode: .common)
        healthTimer = h
        let s = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.stats() }
        s.tolerance = 0.2
        RunLoop.main.add(s, forMode: .common)
        statsTimer = s
    }

    private func stopLiveTimers() {
        healthTimer?.invalidate(); healthTimer = nil
        statsTimer?.invalidate(); statsTimer = nil
        view.toolTip = nil
    }

    private func watchOcclusion() {
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            guard let self else { return }
            let visible = self.window.occlusionState.contains(.visible)
            self.view.setOccluded(!visible)
            NowPlayingPoller.shared.paused = !visible
            if visible {
                self.gazeOccludeWork?.cancel(); self.gazeOccludeWork = nil
                self.resumeGazeIfPossible("pet visible")
            } else {
                self.scheduleGazePauseIfCovered()
            }
        }
    }

    /// 被完全遮住 4 秒后才关摄像头：切一次全屏或 Space 不至于立刻停掉再重启。
    /// 手动隐藏走 hidePet 的立即暂停，不受这个宽限影响。
    private func scheduleGazePauseIfCovered() {
        gazeOccludeWork?.cancel(); gazeOccludeWork = nil
        guard gazeFollow || roomLightOn else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.gazeFollow || self.roomLightOn, self.view.occluded else { return }
            if GazeTracker.shared.setPaused(true) {
                appendDiag("gaze.log", "camera pause: pet occluded 4s")
            }
        }
        gazeOccludeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    /// 只在「追人开着、不在直播、没锁屏、窗口确实可见」时恢复摄像头。
    private func resumeGazeIfPossible(_ why: String) {
        guard gazeFollow || roomLightOn, !view.occluded, !view.isScreenLocked,
              let w = view.window, w.isVisible, w.occlusionState.contains(.visible) else { return }
        if GazeTracker.shared.setPaused(false) {
            appendDiag("gaze.log", "camera resume: \(why)")
        }
    }

    /// 菜单「取消连线」：停掉这次连接，不再自动重连，直到下次「进入 CarPlay」
    func cancelConnect() {
        userStopped = true; reconnectTimer?.invalidate(); reconnectTimer = nil
        switchingPhone = false
        PhoneNowPlayingBridge.shared.clear()
        client?.onLive = nil; client?.close(); client = nil
        view.face.status = .notConnected
        CarPlayOverlayState.needsPairing = false
        CarPlayOverlayState.pairingHost = nil
        CarPlayOverlayState.pairingStale = false
        CarPlayOverlayState.pairingSucceededAt = nil
        CarPlayOverlayState.wifiHelp = false
        CarPlayOverlayState.wifiNeedsPassword = false
        CarPlayOverlayState.needsTrust = false
        CarPlayOverlayState.needsCable = false
        CarPlayOverlayState.bluetoothPairing = false
        CarPlayOverlayState.bluetoothPairFailed = false
        quietAttach = false
        handoffFreeze = false
        handoffTimeoutWork?.cancel(); handoffTimeoutWork = nil
        view.mood.show(.wink, for: 0.6, now: CACurrentMediaTime())
        log("connect cancelled")
    }

    /// 右键「使用 iPhone」：写回配置（下次启动/登录也用它），已连着的 receiver 立刻切换。
    func switchPhone(to address: String) {
        guard !(CarPlayPhoneBook.isCurrent(address) && isLive) else { return }   // 正在直播时点当前那台：不动
        switchingPhone = true
        CarPlayOverlayState.wifiHelp = false
        CarPlayOverlayState.wifiNeedsPassword = false
        CarPlayOverlayState.needsTrust = false
        CarPlayOverlayState.needsCable = false
        CarPlayOverlayState.bluetoothPairing = false
        CarPlayOverlayState.bluetoothPairFailed = false
        quietAttach = false
        handoffFreeze = false
        handoffTimeoutWork?.cancel(); handoffTimeoutWork = nil
        view.face.status = .connecting
        ReceiverLauncher.savePhone(address)
        ReceiverAgent.syncPhone()
        CarPlayOverlayState.needsPairing = false
        CarPlayOverlayState.pairingHost = nil
        if let c = client {
            c.sendUsePhone(address: address)
        } else {
            if view.showingVideo { view.showVideo(false) }
            pendingUsePhone = address
            enterCarPlay()
        }
    }

    /// 右键「配对新 iPhone…」：即使已经有一台在用，也让 receiver 打开蓝牙设置等新配对。
    /// Wi-Fi 名稱：讀得到就送；卡住且沒問過就說明卡 → 定位權限；被拒／讀不到就開 Wi-Fi 設定手填（WiFiName.decide）
    func autoFillSSID(receiverKnows: Bool, stuck: Bool) {
        let action = WiFiName.decide(receiverKnows: receiverKnows, readable: WiFiName.current(), auth: WiFiName.auth,
                                     stuck: stuck, quiet: quietAttach, alreadyAsked: locationAsked)
        switch action {
        case .send(let name):
            client?.sendSSID(name)
            CarPlayWiFi.ssid = name
            if CarPlayOverlayState.connectReason == "ssidUnknown" { CarPlayOverlayState.wifiHelp = false }   // 接收器會馬上重叫手機
            log("Wi-Fi name filled from CoreWLAN (value not logged)")
        case .askPermission:
            locationAsked = true
            log("Wi-Fi name unknown: asking for Location to read it")
            withPermission(.location) { [weak self] ok in
                guard let self else { return }
                guard CarPlayWiFi.ssid.isEmpty else { return }   // 等定位的時候 iPhone 已經分享了 Wi-Fi：什麼都不用做
                guard ok else { self.openWiFiDialogOnce(); return }
                // 剛允許時 macOS 要過幾秒才把 SSID 交給 App：每 0.5 秒再讀，最多 10 秒，讀不到才開手填
                log("Location granted: waiting for macOS to reveal the Wi-Fi name")
                func poll(_ n: Int) {
                    if WiFiName.current() != nil { self.autoFillSSID(receiverKnows: false, stuck: true); return }
                    if n >= 20 { log("Wi-Fi name still hidden 10 s after Location was granted"); self.openWiFiDialogOnce(); return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { poll(n + 1) }
                }
                poll(0)
            }
        case .manual:
            openWiFiDialogOnce()
        case .nothing:
            break
        }
    }
    private func openWiFiDialogOnce() {
        guard !ssidDialogShown, !quietAttach, !isLive else { return }
        ssidDialogShown = true
        settingsPerform("menuWiFiPassword", nil)
    }

    /// 第一次進配對引導（桌寵在前台）時自動出一次「連接步驟」：先講清楚哪條路對，免得在 iPhone 藍牙裡亂點
    private func showConnectStepsOnce() {
        guard !quietAttach, !UserDefaults.standard.bool(forKey: ConnectHelp.stepsShownKey) else { return }
        UserDefaults.standard.set(true, forKey: ConnectHelp.stepsShownKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { ConnectHelp.showSteps() }
    }

    /// 右鍵 › iPhone › 拷貝診斷報告：桌寵這邊的狀態＋接收器的現場＋日誌里程碑次數，放進剪貼簿。
    /// 不含 Wi-Fi 名稱、密碼、位址、裝置名稱（接收器那段見 ConnectDiagnostics.reportLines）。
    func copyDiagnostics() {
        let started = CACurrentMediaTime()
        func finish(_ receiver: String?) {
            diagnosticsWaiter = nil
            diagnosticsTimeout?.cancel(); diagnosticsTimeout = nil
            let info = Bundle.main.infoDictionary
            let v = ProcessInfo.processInfo.operatingSystemVersion
            #if arch(arm64)
            let arch = "arm64"
            #else
            let arch = "x86_64"
            #endif
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm ZZZZZ"
            let reason = CarPlayOverlayState.connectReason ?? "-"
            let helpFor = CarPlayOverlayState.helpSince.map { " for \(Int(CACurrentMediaTime() - $0)) s" } ?? ""
            var card = "none"
            if CarPlayOverlayState.needsCable { card = "needCable" }
            else if CarPlayOverlayState.needsTrust { card = "needTrust" }
            else if CarPlayOverlayState.bluetoothPairing { card = "bluetoothPairing(\(CarPlayOverlayState.pairPhase ?? "-"))" }
            else if CarPlayOverlayState.bluetoothPairFailed { card = "bluetoothPairFailed(\(CarPlayOverlayState.pairFailReason ?? "-"))" }
            else if CarPlayOverlayState.needsPairing { card = "needPairing" }
            else if CarPlayOverlayState.wifiHelp { card = "connectHelp(\(reason))\(helpFor)" }
            let pet = [
                "HomePlay \(info?["CFBundleShortVersionString"] as? String ?? "dev") (\(info?["CFBundleVersion"] as? String ?? "-"))"
                    + " · macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion) · \(arch) · \(L10n.language.rawValue)",
                "Created: \(f.string(from: Date()))",
                "Pet: receiver connected \(client != nil ? "yes" : "no") · status \(view.face.status) · video \(view.showingVideo ? "yes" : "no")"
                    + " · card \(card) · iPhones known \(CarPlayPhoneBook.phones.count)"
                    + (HomePlayState.isolated ? " · rehearsal state" : ""),
            ]
            let text = ConnectHelp.compose(petLines: pet, receiver: receiver, log: ConnectHelp.logSummary())
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            log("diagnostic report copied (\(text.count) chars, receiver \(receiver == nil ? "silent" : "answered") in \(Int((CACurrentMediaTime() - started) * 1000)) ms)")
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = L("diag.copiedTitle", "诊断报告已拷贝")
            alert.informativeText = L("diag.copiedBody", "直接粘贴给帮你看的人。里面只有次数、时间和状态，不含 Wi-Fi 名称、密码、地址或设备名称。")
            alert.addButton(withTitle: L("gaze.denied.ok", "好"))
            alert.runModal()
        }
        guard diagnosticsWaiter == nil else { return }   // 上一次還在等接收器
        guard let c = client else { finish(nil); return }
        diagnosticsWaiter = { report in finish(report) }
        c.requestDiagnostics()
        let timeout = DispatchWorkItem { [weak self] in self?.diagnosticsWaiter?(nil) }
        diagnosticsTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
    }

    func pairNewPhone() {
        switchingPhone = true
        handoffFreeze = false
        handoffTimeoutWork?.cancel(); handoffTimeoutWork = nil
        CarPlayOverlayState.wifiHelp = false
        CarPlayOverlayState.wifiNeedsPassword = false
        CarPlayOverlayState.needsTrust = false
        CarPlayOverlayState.needsCable = false
        CarPlayOverlayState.bluetoothPairing = false
        CarPlayOverlayState.bluetoothPairFailed = false
        CarPlayOverlayState.needsPairing = true
        CarPlayOverlayState.pairingHost = nil
        if let c = client {
            c.sendPairNewPhone()
        } else {
            if view.showingVideo { view.showVideo(false); view.face.status = .notConnected }
            pendingPairNew = true
            enterCarPlay()
        }
    }

    /// --event "标题|开始 HH:mm|结束 HH:mm"：快照测试用的固定行程
    static func testEvent(_ s: String) -> CalendarTile {
        let f = s.components(separatedBy: "|")
        func at(_ hm: String) -> Date {
            let p = hm.split(separator: ":").compactMap { Int($0) }
            return Calendar.current.date(bySettingHour: p.first ?? 9, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
        }
        return .event(NextEvent(title: f[0], start: at(f.count > 1 ? f[1] : "10:30"), end: at(f.count > 2 ? f[2] : "11:00")))
    }

    /// 后台挂接时如果 receiver 真的需要配对/信任，自动转为前台引导：
    /// 让用户看到该点哪里，同时让 receiver 可以打开蓝牙设置。
    private func engageQuietAttach() {
        view.wakeFromPosterForGuide()
        guard quietAttach, !userStopped, !isLive else { return }
        quietAttach = false
        view.face.status = .connecting
        client?.sendEngaged(true)
        log("background attach engaged for pairing guide")
    }

    /// 接收器把有线会话切成无线时，桌宠冻住最后一帧：不要收起画面、不要弹「连接中」，
    /// 也不要让健康检查把这次正常切换当成断流去关 WebSocket。
    private func beginHandoffFreeze(seconds: Double = 25) {
        view.wakeFromPosterForGuide()
        handoffFreeze = true
        handoffTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.handoffFreeze else { return }
            self.handoffFreeze = false
            log("handoff: timeout waiting for wireless")
            if !self.isLive {
                self.view.showVideo(false)
                self.view.face.status = .reconnecting
            }
        }
        handoffTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        log("handoff: holding last frame")
    }

    private func endHandoffFreeze(_ state: String) {
        handoffFreeze = false
        handoffTimeoutWork?.cancel(); handoffTimeoutWork = nil
        log("handoff: \(state)")
        if state == "failed", !isLive {
            view.showVideo(false)
            view.face.status = .reconnecting
        }
    }

    /// 插线换新 iPhone：USB 已结束、手机蓝牙恢复；给用户看配对卡，等 BondAssist/系统配对完成。
    private func beginPairingHandoffView() {
        view.wakeFromPosterForGuide()
        beginHandoffFreeze(seconds: 200)
        quietAttach = false
        client?.sendEngaged(true)
        view.showVideo(false)
        view.face.status = .connecting
        CarPlayOverlayState.needsPairing = false
        CarPlayOverlayState.pairingHost = nil
        CarPlayOverlayState.needsCable = false
        CarPlayOverlayState.needsTrust = false
        CarPlayOverlayState.bluetoothPairing = true
        CarPlayOverlayState.bluetoothPairFailed = false
        CarPlayOverlayState.wifiHelp = false
        CarPlayOverlayState.pairingSucceededAt = nil
    }

    /// 截图／基准／设置预览这类诊断进程：不挂接收器、退出时也不发 stop，绝不碰用户正在用的 CarPlay
    static var isDiagnosticRun: Bool {
        let a = CommandLine.arguments
        return ["--snapshot", "--bench", "--open-settings", "--show-menu", "--clock-look-panel"].contains { a.contains($0) }
    }
    private func connect(_ endpoint: String, quiet: Bool = false) {
        guard !Self.isDiagnosticRun else { log("diagnostic run: not attaching to receiver"); return }
        guard let c = ReceiverClient(endpoint: endpoint, decoder: view.decoder) else {
            log("无效 endpoint：\(endpoint)"); return
        }
        quietAttach = quiet
        c.onLive = { [weak self] live in
            guard let self else { return }
            // 畫面出來了：設定流程裡還掛著的定位說明卡一律收掉（它只是為了 Wi-Fi 名稱，已經不需要了）
            if live, PermissionPrimer.kind == .location { PermissionPrimer.dismiss() }
            if !live, self.handoffFreeze {
                self.isLive = false
                log("handoff: wired session ended; holding last frame")
                return
            }
            if live, self.handoffFreeze {
                self.handoffFreeze = false
                self.handoffTimeoutWork?.cancel(); self.handoffTimeoutWork = nil
                log("handoff: wireless frame arrived")
            }
            let wasQuiet = self.quietAttach
            self.isLive = live
            if !live { self.carPlayInBackground = false }
            if live { self.quietAttach = false }
            if !wasQuiet || live {
                self.view.face.status = live ? .live : (self.userStopped ? .pausedResume : .reconnecting)
            }
            let now = CACurrentMediaTime()
            if live {
                // 出第一帧：点一下头。断过线的同时笑一下（它回来了），画面不等表情。
                if !wasQuiet { self.requestMicrophoneIfNeeded(announce: false, reason: "CarPlay live") }
                self.reconnectStep = 0; self.disconnectedAt = nil; self.health.reset(now: now)
                self.switchingPhone = false
                CarPlayOverlayState.needsPairing = false
                CarPlayOverlayState.pairingHost = nil
                CarPlayOverlayState.pairingStale = false
                CarPlayOverlayState.pairingSucceededAt = nil
                CarPlayOverlayState.wifiHelp = false
                CarPlayOverlayState.wifiNeedsPassword = false
                CarPlayOverlayState.needsTrust = false
                CarPlayOverlayState.needsCable = false
                CarPlayOverlayState.bluetoothPairing = false
                CarPlayOverlayState.bluetoothPairFailed = false
                self.view.nod()
                if self.view.mood.disconnected {
                    self.view.mood.disconnected = false
                    self.view.mood.show(.happy, for: 0.8, now: now)
                }
                self.view.showVideo(true)
                if self.gazeFollow { GazeTracker.shared.setPaused(true) }   // 看 CarPlay 时关摄像头
            } else {
                // 直播中断（不是用户按空格停的）：屏幕回到擔心臉，直到重连成功
                PhoneNowPlayingBridge.shared.clear()
                if self.view.showingVideo { self.view.mood.disconnected = true }
                if !wasQuiet { self.view.showVideo(false) }   // 安静挂接时不要打扰桌宠
                self.scheduleReconnect(quiet: wasQuiet)
            }
        }
        c.onFrameReceived = { [weak self] in self?.health.frameReceived(now: CACurrentMediaTime()) }
        c.onText = { s in
            if s.contains("\"type\":\"cornerMask\"") {   // 學圓角的那一次連線：桌寵暫時縮放補黑
                if let data = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let w = Int(self.view.decoder.size.width)
                    CornerFit.shared.handle(obj, videoWidth: w > 0 ? w : 1088, device: MTLCreateSystemDefaultDevice())
                }
                return
            }
            if s.contains("\"type\":\"carVideo\"") {
                if let data = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.view.carVideo.handle(obj)
                }
                return
            }
            if s.contains("\"type\":\"call\"") {
                if let call = PhoneCallInfo.parse(s) { self.applyCall(call) }
                return
            }
            if s.contains("\"type\":\"cellular\"") {
                if let info = CellularInfo.parse(s) { self.callCard.model.carrier = info.carrier }
                return
            }
            if s.contains("\"type\":\"nowplaying\"") {
                if s.contains("\"clear\":true") { PhoneNowPlayingBridge.shared.clear() }
                else if let data = s.data(using: .utf8),
                        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    PhoneNowPlayingBridge.shared.apply(obj)
                }
                return
            }
            if s.contains("\"type\":\"artwork\"") {
                if let data = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = (obj["id"] as? NSNumber)?.uint8Value,
                   let b64 = obj["data"] as? String,
                   let bytes = Data(base64Encoded: b64) {
                    PhoneNowPlayingBridge.shared.applyArtwork(id: id, data: bytes)
                }
                return
            }
            if s.contains("\"type\":\"handoff\"") {
                if s.contains("\"state\":\"start\"") { self.beginHandoffFreeze() }
                else if s.contains("\"state\":\"pairing\"") { self.beginPairingHandoffView() }
                else if s.contains("\"state\":\"done\"") { self.endHandoffFreeze("wireless") }
                else if s.contains("\"state\":\"failed\"") { self.endHandoffFreeze("failed") }
                return
            }
            if s.contains("\"type\":\"session\"") {
                if self.handoffFreeze { return }
                // receiver 的会话状态：切换手机/手机自己 TEARDOWN 时收起旧画面，等下一帧。
                let started = s.contains("\"state\":\"started\"")
                if started {
                    if !self.userStopped, !self.quietAttach, !self.isLive, !self.view.showingVideo {
                        self.view.face.status = .connecting
                    }
                } else if !self.userStopped, !self.quietAttach {
                    self.isLive = false
                    self.view.carVideo.stop(notify: false)
                    PhoneNowPlayingBridge.shared.clear()
                    self.view.showVideo(false)
                    self.view.face.status = self.switchingPhone ? .connecting : .reconnecting
                }
                return
            }
            if s.contains("\"type\":\"currentPhone\"") {
                if let data = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let address = obj["address"] as? String, !address.isEmpty {
                    ReceiverLauncher.savePhone(address)   // 下次启动优先这台，不再被别的已配对手机顶替
                    CarPlayPhoneBook.current = address
                    CarPlayOverlayState.needsCable = false
                    _ = ReceiverAgent.autoEnableIfNeeded(reason: "paired iPhone")
                    log("current iPhone saved")
                }
                return
            }
            if s.contains("\"type\":\"diagnostics\"") {
                if let data = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let report = obj["report"] as? String {
                    self.diagnosticsWaiter?(report)
                }
                return
            }
            if s.contains("\"type\":\"wifiHelp\"") {
                self.engageQuietAttach()
                if !CarPlayOverlayState.wifiHelp { CarPlayOverlayState.helpSince = CACurrentMediaTime() }
                CarPlayOverlayState.wifiHelp = true
                if let data = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    CarPlayOverlayState.wifiNeedsPassword = (obj["passphraseMissing"] as? Bool) ?? false
                    let reason = obj["reason"] as? String
                    if reason != CarPlayOverlayState.connectReason { CarPlayOverlayState.helpSince = CACurrentMediaTime() }
                    CarPlayOverlayState.connectReason = reason
                    CarPlayOverlayState.helpSSID = obj["ssid"] as? String ?? ""
                    log("connect help: \(reason ?? "wifi")")
                    // Wi-Fi 名稱未知（macOS 對 App 隱藏）：有定位權限就自己讀；沒問過先出說明卡；被拒才打開 Wi-Fi 設定手填
                    if reason == "ssidUnknown", !self.isLive {
                        DispatchQueue.main.async { self.autoFillSSID(receiverKnows: false, stuck: true) }
                    }
                }
                return
            }
            if s.contains("\"type\":\"wifiInfo\"") {
                if let data = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let value = obj["ssid"] as? String {
                    CarPlayWiFi.ssid = value
                    // 接收器不知道名稱：已有定位權限就悄悄補上。不在這裡問定位——接收器一連上 iPhone 就先請它
                    // 分享 Wi-Fi（一次點按、連密碼一起來）；iPhone 拒絕而真的卡住時才走定位／手填
                    if value.isEmpty { DispatchQueue.main.async { self.autoFillSSID(receiverKnows: false, stuck: false) } }
                    // iPhone 已經分享（或使用者手填）了：還掛著的定位說明卡就收掉，不要蓋在 CarPlay 畫面上
                    else if PermissionPrimer.kind == .location { DispatchQueue.main.async { PermissionPrimer.dismiss() } }
                }
                return
            }
            if s.contains("\"type\":\"phones\"") {
                CarPlayPhoneBook.apply(json: s)
                return
            }
            if s.contains("\"type\":\"needCable\"") {
                self.engageQuietAttach()
                CarPlayOverlayState.needsCable = true
                CarPlayOverlayState.needsPairing = false
                CarPlayOverlayState.needsTrust = false
                CarPlayOverlayState.bluetoothPairing = false
                CarPlayOverlayState.bluetoothPairFailed = false
                CarPlayOverlayState.wifiHelp = false
                if !self.isLive, !self.view.showingVideo, !self.userStopped, !self.quietAttach {
                    self.view.face.status = .connecting
                }
                log("first pairing: waiting for a cable")
                self.showConnectStepsOnce()
                return
            }
            if s.contains("\"type\":\"requestUI\"") {
                // 手机上点了 HomePlay 图标：回到表面，CarPlay 留在后台（和「重按进入 CarPlay」形成闭环）
                if self.view.showingVideo {
                    self.carPlayInBackground = true
                    self.view.showVideo(false)
                    self.view.face.status = .background
                    self.view.mood.show(.happy, for: 0.8, now: CACurrentMediaTime())
                    log("requestUI: back to the face; CarPlay stays in the background")
                }
                return
            }
            if s.contains("\"type\":\"bluetoothPairing\"") {
                self.engageQuietAttach()
                CarPlayOverlayState.needsCable = false
                CarPlayOverlayState.needsPairing = false
                CarPlayOverlayState.needsTrust = false
                CarPlayOverlayState.bluetoothPairing = true
                CarPlayOverlayState.bluetoothPairFailed = false
                CarPlayOverlayState.pairFailReason = nil
                CarPlayOverlayState.wifiHelp = false
                // 階段、配對碼、倒數、這台 Mac 在 iPhone 上的名字（舊 receiver 沒有這些欄位就照舊顯示）
                if let data = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    CarPlayOverlayState.pairPhase = obj["phase"] as? String
                    CarPlayOverlayState.pairCode = obj["code"] as? String
                    CarPlayOverlayState.pairDeadline = (obj["timeout"] as? Int).map { CACurrentMediaTime() + Double($0) }
                    if let host = obj["host"] as? String, !host.isEmpty { CarPlayOverlayState.pairingHost = host }
                }
                if !self.isLive, !self.view.showingVideo, !self.userStopped, !self.quietAttach {
                    self.view.face.status = .connecting
                }
                log("bluetooth pairing \(CarPlayOverlayState.pairPhase ?? "requested") on iPhone")
                return
            }
            if s.contains("\"type\":\"bluetoothPairFailed\"") {
                self.engageQuietAttach()
                CarPlayOverlayState.bluetoothPairing = false
                CarPlayOverlayState.bluetoothPairFailed = true
                CarPlayOverlayState.pairPhase = nil
                CarPlayOverlayState.pairCode = nil
                CarPlayOverlayState.pairDeadline = nil
                CarPlayOverlayState.pairFailReason = s.data(using: .utf8)
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["reason"] as? String
                CarPlayOverlayState.needsCable = false
                if !self.isLive, !self.view.showingVideo, !self.userStopped, !self.quietAttach {
                    self.view.face.status = .connecting
                }
                log("bluetooth pairing not confirmed; replug to retry")
                return
            }
            if s.contains("needPairing") {
                self.engageQuietAttach()
                CarPlayOverlayState.needsPairing = true
                CarPlayOverlayState.needsCable = false
                CarPlayOverlayState.bluetoothPairing = false
                CarPlayOverlayState.bluetoothPairFailed = false
                CarPlayOverlayState.pairingSucceededAt = nil
                CarPlayOverlayState.wifiHelp = false
                CarPlayOverlayState.needsTrust = false   // 蓝牙配对卡优先于 USB 信任卡
                if let data = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let host = obj["host"] as? String, !host.isEmpty {
                    CarPlayOverlayState.pairingHost = host
                }
                if let data = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    CarPlayOverlayState.pairingStale = (obj["stale"] as? Bool) ?? false
                    CarPlayOverlayState.pairingViaCable = (obj["cable"] as? Bool) ?? false
                }
                if !self.isLive, !self.view.showingVideo, !self.userStopped, !self.quietAttach {
                    self.view.face.status = .connecting
                }
                log("needs pairing")
                self.showConnectStepsOnce()
            }
            if s.contains("\"type\":\"phoneForgotten\"") {
                // 忘記之後還要使用者做的步驟：iPhone 上忘記這台車；Mac 刪不掉系統配對時再加一步
                if let data = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let name = obj["name"] as? String
                    let macRemoved = obj["macRemoved"] as? Bool ?? true
                    DispatchQueue.main.async { self.view.showForgetSteps(name: name, macRemoved: macRemoved) }
                }
                return
            }
            if s.contains("pairingDone") {
                CarPlayOverlayState.pairPhase = nil
                CarPlayOverlayState.pairCode = nil
                CarPlayOverlayState.pairDeadline = nil
                CarPlayOverlayState.pairFailReason = nil
                CarPlayOverlayState.needsPairing = false
                CarPlayOverlayState.needsCable = false
                CarPlayOverlayState.bluetoothPairing = false
                CarPlayOverlayState.bluetoothPairFailed = false
                CarPlayOverlayState.pairingHost = nil
                CarPlayOverlayState.pairingStale = false
                if self.handoffFreeze { self.endHandoffFreeze("pairing done") }
                CarPlayOverlayState.pairingSucceededAt = CACurrentMediaTime()
                _ = ReceiverAgent.autoEnableIfNeeded(reason: "pairing done")
                log("bluetooth pairing done")
            }
            if s.contains("\"type\":\"needTrust\"") {
                self.engageQuietAttach()
                CarPlayOverlayState.needsTrust = true
                CarPlayOverlayState.needsCable = false
                CarPlayOverlayState.bluetoothPairing = false
                CarPlayOverlayState.bluetoothPairFailed = false
                // 桌宠闲置时插线也可能走到这里：把表盘切到引导状态，信任卡才画得出来
                if !self.isLive, !self.view.showingVideo, !self.userStopped, !self.quietAttach {
                    self.view.face.status = .connecting
                }
                log("USB needs trust")
            }
            if s.contains("\"type\":\"trustDone\"") {
                // 有线排障卡（usb 开头的原因）也跟着收：解锁了、信任了、或拔线了
                if CarPlayOverlayState.connectReason?.hasPrefix("usb") == true { CarPlayOverlayState.wifiHelp = false }
                if CarPlayOverlayState.needsTrust, !self.isLive {
                    self.view.face.status = .notConnected
                }
                CarPlayOverlayState.needsTrust = false
                CarPlayOverlayState.needsCable = false
            }
        }
        c.onOpen = { [weak self, weak c] in
            guard let self, let c else { return }
            self.receiverKickstarted = false   // 这一轮已成功连上；下次 receiver 掉了还能再 kickstart
            c.sendEngaged(!self.quietAttach)
            if let address = self.pendingUsePhone {
                self.pendingUsePhone = nil
                c.sendUsePhone(address: address)
            }
            if self.pendingPairNew {
                self.pendingPairNew = false
                c.sendPairNewPhone()
            }
            if self.pendingSiri {
                self.pendingSiri = false
                // F5 還按著：補送按下，放開時照常送放開；已經放開了就按一下
                if self.siriHold.held { c.sendSiri(down: true); self.siriDownSent = true }
                else { c.sendSiri() }
            }
        }
        client = c
        if !quiet { view.face.status = .connecting }
        c.open()
    }
    /// 設定「在 CarPlay 播放影片」：寫檔（接收器下次回 /info 用），也即時告訴接收器（它會通知手機）
    func setCarVideoAllowed(_ on: Bool) {
        CarVideoSetting.allowed = on
        client?.sendRaw(CarVideoPlayer.json(["type": "carVideoAllowed", "allowed": on]))
        if !on { view.carVideo.stop(notify: true) }
        log("car video allowed \(on)")
    }
    /// CarPlay 在后台（点过 HomePlay 图标）：直接把画面切回来，要一张关键帧让画面马上出来
    private func resumeFromBackground() -> Bool {
        guard carPlayInBackground, isLive, !view.showingVideo else { return false }
        carPlayInBackground = false
        view.showVideo(true)
        view.face.status = .live
        client?.requestKeyframe()
        log("CarPlay back to the front")
        return true
    }
    private func toggle() {
        if !view.showingVideo, resumeFromBackground() { return }
        handoffFreeze = false
        handoffTimeoutWork?.cancel(); handoffTimeoutWork = nil
        if view.showingVideo {
            userStopped = true; reconnectTimer?.invalidate()
            PhoneNowPlayingBridge.shared.clear()
            client?.requestTeardown()          // 讓 iPhone 端也結束 CarPlay，而不是只關畫面
            view.showVideo(false); view.face.status = .pausedResume
        } else if let endpoint {
            userStopped = false; client?.close(); client = nil
            ensureReceiver { [weak self] in self?.connect(endpoint) }   // receiver 已退出時重新拉起
        }
    }

    // MARK: 重按进入 CarPlay（照 MacPlay「启动接收」的定位，但做成一键：receiver 不在就拉起，然后连；
    // 连不上靠既有的 5/10/20/30/60s 退避一直等，receiver 侧自己也会退避重试手机——两边都不用管）
    @objc func enterCarPlay() {
        // 同一個手勢進出：已經在直播就退出（等同空格／選單的暫停直播）
        if view.showingVideo { toggle(); return }
        if resumeFromBackground() { return }
        view.mood.show(.surprised, for: 0.35, now: CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.view.mood.show(.thinking, for: 12, now: CACurrentMediaTime())
        }
        let target = endpoint ?? "ws://127.0.0.1:\(ReceiverLauncher.port())"
        endpoint = target
        userStopped = false
        quietAttach = false
        reconnectTimer?.invalidate(); reconnectTimer = nil   // 立即连，不等旧的退避
        ensureReceiver { [weak self] in
            self?.client?.close()
            self?.connect(target)
        }
    }

    /// receiver 不在（8788 没人听）就拉起一个；在的话直接用，不重复起。
    private func ensureReceiver(_ then: @escaping () -> Void) {
        // 想做到「一次配好、以后自动」：第一次进 CarPlay 就把 receiver 交给 launchd 常驻。
        // 这样桌宠退出/重启后手机仍有东西可回连；用户明确关过「后台自动连接」则尊重选择。
        if !ReceiverAgent.isInstalled, ReceiverAgent.autoEnableIfNeeded(reason: "receiver needed") {
            log("后台自动连接已开启：接收器会在登录后常驻")
        }
        // 已装开机自启（launchd）时，接收器由 launchd 负责：登录瞬间它可能还没就绪，
        // 先等它起来，不要另起一个实例抢端口（2026-10-20 重启实测：桌宠先起会让
        // launchd 实例每 10 秒 Address already in use）。
        if ReceiverAgent.isInstalled {
            waitForReceiver(attempts: 20, then)
            return
        }
        portOpen("127.0.0.1", UInt16(clamping: ReceiverLauncher.port())) { [weak self] open in
            DispatchQueue.main.async { [weak self] in
                if !open, let self {
                    switch ReceiverLauncher.launch() {
                    case .ok: log("receiver 已拉起（日志：~/Library/Application Support/HomePlay/receiver.log）")
                    case .noBinary(let path):
                        log("找不到 homeplay-receiver（找过 \(path)）；先 swift build，或自己跑 receiver 再连")
                        self.view.mood.show(.worried, for: 2.5, now: CACurrentMediaTime())
                    }
                }
                then()
            }
        }
    }

    /// 已装自启时轮询等待 launchd 的接收器；它始终没来就退回自己拉起。
    /// 探测一轮没到就先 kickstart（用户停播后接收器 exit(0)，launchd 的 KeepAlive
    /// 不会重启它——别等满 10 秒，0.5 秒后就催一次），再等 10 秒，最后才自起子进程。
    private func waitForReceiver(attempts: Int, _ then: @escaping () -> Void) {
        portOpen("127.0.0.1", UInt16(clamping: ReceiverLauncher.port())) { [weak self] open in
            DispatchQueue.main.async { [weak self] in
                if open { then(); return }
                guard attempts > 1 else {
                    if let self {
                        switch ReceiverLauncher.launch() {
                        case .ok: log("launchd 的 receiver 未就绪，已自行拉起")
                        case .noBinary(let path):
                            log("找不到 homeplay-receiver（找过 \(path)）；先 swift build，或自己跑 receiver 再连")
                            self.view.mood.show(.worried, for: 2.5, now: CACurrentMediaTime())
                        }
                    }
                    then()
                    return
                }
                if let self, ReceiverAgent.isInstalled, !self.receiverKickstarted {
                    // 首探就失败：大概率是上一次「停播」让接收器 exit(0) 了。立即 kickstart，
                    // 不再等满整轮（旧逻辑要 10 秒后才催，用户重进 CarPlay 会卡半拍）。
                    self.receiverKickstarted = true
                    if ReceiverAgent.kickstart() {
                        log("receiver 不在跑：已 kickstart launchd 作业，继续等")
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.waitForReceiver(attempts: attempts - 1, then)
                }
            }
        }
    }

    /// 0.6s 内 TCP 连不连得上（判断 receiver 是否已在跑）
    private func portOpen(_ host: String, _ port: UInt16, _ done: @escaping (Bool) -> Void) {
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        var answered = false
        func finish(_ ok: Bool) {
            guard !answered else { return }
            answered = true; conn.cancel(); done(ok)
        }
        conn.stateUpdateHandler = { state in
            switch state { case .ready: finish(true); case .failed, .cancelled: finish(false); default: break }
        }
        conn.start(queue: .global(qos: .userInitiated))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { finish(false) }
    }

    // 断线重连：前 15 s 每 0.3 s 探一次端口，通了就连；之后 5、10、20、30、60 s 退避，
    // 出画面归零；用户按空格停的不重连
    private func scheduleReconnect(quiet: Bool = false) {
        guard let endpoint, !userStopped, reconnectTimer == nil, !reconnectProbing else { return }
        let now = CACurrentMediaTime()
        if disconnectedAt == nil { disconnectedAt = now }
        // 没装 launchd 自启时接收器要桌宠自己拉起，快探只到原本第一次退避（5 s）就交给 ensureReceiver
        let window = ReceiverAgent.isInstalled ? Self.fastProbeWindow : Self.backoff[0]
        if now - (disconnectedAt ?? now) < window {
            reconnectTimer = Timer.scheduledTimer(withTimeInterval: Self.fastProbeInterval, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.reconnectTimer = nil
                self.reconnectProbing = true
                let failed = self.client
                self.portOpen("127.0.0.1", UInt16(clamping: ReceiverLauncher.port())) { [weak self] open in
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.reconnectProbing = false
                        // 探测期间用户停了或手动换了连线：这条探测作废
                        guard !self.userStopped, self.client === failed, !self.isLive else { return }
                        if open {
                            self.client?.close()
                            self.connect(endpoint, quiet: quiet)
                        } else {
                            self.scheduleReconnect(quiet: quiet)
                        }
                    }
                }
            }
            return
        }
        let wait = Self.backoff[min(reconnectStep, Self.backoff.count - 1)]
        reconnectStep += 1
        log("reconnect in \(Int(wait))s")
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.reconnectTimer = nil
            // 只重连 WS 不够：receiver 可能已被 launchd 停掉/自己退出。先确保它在跑，
            // 再连；这样桌宠放着不管也能自己恢复，不用用户再重按一次。
            self.ensureReceiver { [weak self] in
                guard let self else { return }
                self.client?.close()
                self.connect(endpoint, quiet: quiet)
            }
        }
    }

    private func act(_ a: VideoHealth.Action, why: String) {
        if handoffFreeze { return }   // 正常的有线→无线切换：别让健康检查把冻结当成断流
        switch a {
        case .none: return
        case .requestKeyframe:
            log("health \(why)：要关键帧"); client?.requestKeyframe()
        case .rebuild:
            log("health \(why)：重建解码（第 \(health.totalRebuilds) 次）并要关键帧")
            view.decoder.rebuild(); client?.requestKeyframe()
        case .giveUp:
            log("health 视频恢复失败：断开重连")
            client?.close()   // 走 onLive(false) → 重连
        }
    }

    private func stats() {
        let now = CACurrentMediaTime(), dt = max(0.001, now - lastStats.t)
        let rf = Double(health.received - lastStats.recv) / dt, df = Double(health.decoded - lastStats.dec) / dt
        if health.received < lastStats.recv { lastStats = (now, 0, 0); return }   // 新连接计数归零
        lastStats = (now, health.received, health.decoded)
        guard view.showingVideo else { view.toolTip = nil; return }
        let s = view.decoder.size
        log(String(format: "stats recv %.1f fps decoded %.1f fps %dx%d rebuilds %d", rf, df, Int(s.width), Int(s.height), health.totalRebuilds))
        if ProcessInfo.processInfo.environment["HOMEPLAY_DEBUG_STATS"] != nil {   // 除錯用：游標停在桌寵上看收／解碼幀率
            view.toolTip = String(format: L("debug.stats", "接收 %.0f fps · 解码 %.0f fps · %d×%d"), rf, df, Int(s.width), Int(s.height))
        }
    }
}

func arg(_ n: String) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: n), i + 1 < a.count { return a[i + 1] }; return nil
}

if CommandLine.arguments.contains("--home-dump") { runHomeDump() }   // 連 HomePlay Home 幫手，印摘要就結束

if CommandLine.arguments.contains("--selftest") {
    // 纯函数自检：方屏 uv → 画面坐标（留黑扣掉）
    func near(_ a: (Double, Double)?, _ b: (Double, Double)) -> Bool {
        guard let a else { return false }; return abs(a.0 - b.0) < 1e-9 && abs(a.1 - b.1) < 1e-9
    }
    var ok = true
    func check(_ c: Bool, _ m: String) { if !c { ok = false; log("FAIL \(m)") } }
    check(near(screenToVideo(u: 0.5, v: 0.5, videoW: 1800, videoH: 1360), (0.5, 0.5)), "中心")
    check(near(screenToVideo(u: 0, v: 0.5 - 0.5 * 1360 / 1800, videoW: 1800, videoH: 1360), (0, 0)), "宽画面左上角")
    check(screenToVideo(u: 0.5, v: 0.05, videoW: 1800, videoH: 1360) == nil, "宽画面上方留黑")
    check(near(screenToVideo(u: 1, v: 0.5 + 0.5 * 1360 / 1800, videoW: 1800, videoH: 1360), (1, 1)), "宽画面右下角")
    check(near(screenToVideo(u: 0.5 + 0.5 * 900 / 1200, v: 1, videoW: 900, videoH: 1200), (1, 1)), "直式右下角")
    check(screenToVideo(u: 0.02, v: 0.5, videoW: 900, videoH: 1200) == nil, "直式左边留黑")
    check(near(screenToVideo(u: 0.25, v: 0.75, videoW: 1200, videoH: 1200), (0.25, 0.75)), "正方形原样")
    // 单轴手势锁：起手阈值内不动；判主轴后只走一根轴；重置后重新判
    do {
        var lock = AxisLock()
        check(lock.pass(dx: 2, dy: 1) == (0, 0), "单轴锁：起手抖动不生效")
        check(lock.pass(dx: 10, dy: 3).dx == 10 && lock.pass(dx: 10, dy: 3).dy == 0, "单轴锁：水平主导锁偏航")
        check(lock.pass(dx: 0, dy: 50) == (0, 0), "单轴锁：锁水平后俯仰不动")
        lock.reset()
        check(lock.pass(dx: 2, dy: 30) == (0, 30), "单轴锁：重置后竖直主导锁俯仰")
        check(lock.pass(dx: 40, dy: 0) == (0, 0), "单轴锁：锁竖直后偏航不动")
        lock.reset()
        check(lock.pass(dx: 5, dy: 5).dx == 5 && lock.pass(dx: 5, dy: 5).dy == 0, "单轴锁：平手判水平")
    }
    // 已配对手机清单（右键「使用 iPhone」）：解析、当前勾选、空列表
    do {
        CarPlayPhoneBook.phones = []; CarPlayPhoneBook.current = nil
        let json = #"{"type":"phones","current":"50:3B:70:CB:AE:56","items":[{"address":"50:3B:70:CB:AE:56","name":"Aaron’s iPhone"},{"address":"AA:BB:CC:DD:EE:FF","name":"iPhone 15"}]}"#
        check(CarPlayPhoneBook.apply(json: json), "phones JSON parses")
        check(CarPlayPhoneBook.phones.count == 2, "two paired phones listed")
        check(CarPlayPhoneBook.isCurrent("50-3b-70-cb-ae-56"), "current phone matches across address formats")
        check(!CarPlayPhoneBook.isCurrent("AA:BB:CC:DD:EE:FF"), "other phone is not marked current")
        let entries = CarPlayPhoneBook.menuEntries()
        check(entries.count == 2 && entries[0].title == "Aaron’s iPhone" && entries[0].current
              && !entries[1].current, "menu entries use names and check the current phone")
        check(CarPlayPhoneBook.apply(json: #"{"type":"phones","current":"","items":[]}"#), "empty phone list parses")
        check(CarPlayPhoneBook.phones.isEmpty && CarPlayPhoneBook.current == nil, "empty list clears current")
        check(!CarPlayPhoneBook.apply(json: "not json"), "malformed phones message is ignored")
    }
    // 视频健康
    let h = VideoHealth(now: 0)
    check(h.check(now: 10) == .none, "没收到帧＝静止画面，不算停滞")
    for t in [0.5, 1.0, 1.5] { h.frameReceived(now: t) }
    check(h.check(now: 2) == .none, "2.5 s 内不动作")
    check(h.check(now: 3) == .rebuild, "收 3 帧 2.5 s 没解出 → 重建")
    check(h.check(now: 3.5) == .none && h.check(now: 3.95) == .requestKeyframe, "重建后 0.9 s 才再要关键帧")
    check(h.check(now: 4.2) == .none, "要关键帧限速")
    h.frameDecoded(now: 5)
    check(h.check(now: 20) == .none, "解出帧就恢复正常")
    for t in [28.0, 28.5, 29.0] { h.frameReceived(now: t) }
    check(h.check(now: 30) == .rebuild, "又停滞 → 重建")
    check(h.check(now: 35) == .none, "流停了（5 s 没进帧）＝静止画面，不再动作")
    h.frameReceived(now: 38.5)
    check(h.check(now: 39) == .rebuild, "8 s 仍没出帧、还在进帧 → 再重建")
    h.frameReceived(now: 47.5)
    check(h.check(now: 48) == .giveUp, "60 s 内第 4 次 → 放弃")
    let h2 = VideoHealth(now: 0)
    var acts: [VideoHealth.Action] = []
    for i in 0..<8 { acts.append(h2.decodeError(now: Double(i) * 61)) }
    check(acts.filter { $0 == .rebuild }.count == 6 && acts.last == .giveUp, "总共最多重建 6 次")
    h2.reset(now: 500)
    check(h2.decodeError(now: 501) == .rebuild, "重连后是新的恢复预算，不会立刻又放弃")
    // 主线程被拖动/缩放占住 30 s：判活只认实际收帧/解码时间，不认检查定时器的到达时间
    let h3 = VideoHealth(now: 0)
    for t in stride(from: 0.5, through: 30.0, by: 1.0) {
        h3.frameReceived(now: t); h3.frameDecoded(now: t + 0.08)
    }
    check(h3.check(now: 31) == .none, "主线程卡 30 s、帧仍在解 → 不误判停滞")
    let h4 = VideoHealth(now: 0)
    for t in [29.5, 29.8, 30.0] { h4.frameReceived(now: t) }
    check(h4.check(now: 30.2) == .rebuild, "检查晚到，但最近确有进帧且没解出 → 该重建")
    // 心情：触发对照
    let m = Mood(now: 0)
    check(m.current(now: 1, hour: 14) == .idle, "白天没人碰＝待机")
    check(m.current(now: 10_000, hour: 14) == .idle, "白天闲置再久也不睡")
    check(m.current(now: 179, hour: 23) == .idle && m.current(now: 181, hour: 23) == .sleepy, "夜里闲置 3 分钟困倦")
    check(m.current(now: 481, hour: 2) == .asleep, "再 5 分钟睡着")
    m.activity(now: 500, hour: 2)
    check(m.current(now: 500.2, hour: 2) == .surprised && m.current(now: 500.5, hour: 2) == .idle, "被叫醒：惊讶 0.4 s 再待机")
    m.near = true
    check(m.current(now: 501, hour: 2) == .idle, "游标靠近＝待机（眼珠跟着游标）")
    m.petting(true, now: 510)
    check(m.current(now: 511, hour: 14) == .idle && m.current(now: 511.6, hour: 14) == .happy, "摸头 1.5 s 笑")
    check(m.current(now: 514.1, hour: 14) == .love, "摸满 4 s 爱心")
    m.petting(false, now: 515)
    check(m.current(now: 515.5, hour: 14) == .happy && m.current(now: 515.7, hour: 14) == .idle, "离开再笑 0.6 s")
    check(!(0..<4).map { m.poke(now: 520 + Double($0) * 0.2) }.contains(true) && m.poke(now: 520.9), "1.5 s 内第 5 下＝不耐烦")
    check(m.current(now: 521, hour: 14) == .annoyed, "连点＝不耐烦")
    m.apart = true
    check(m.current(now: 530, hour: 14) == .surprised, "拆开＝惊讶")
    m.apart = false; m.disconnected = true
    check(m.current(now: 530, hour: 23) == .worried, "断线＝担心，优先于睡意")
    m.disconnected = false
    // 脸的参数：插值会收敛到目标
    var fp = FaceParams.of(.idle)
    for _ in 0..<200 { _ = fp.approach(.of(.surprised), 0.2) }
    check(fp == .of(.surprised) && !fp.approach(.of(.surprised), 0.2), "表情插值收敛并停止重画")
    // 錶面切换与倒数显示
    check(FaceStyle.island.next(1) == .photos && FaceStyle.island.next(-1) == FaceStyle.lineup.last! && FaceStyle.lineup.last!.next(1) == .island, "錶面头尾相接")
    check(FaceStyle.lineup.map(\.rawValue) == ["island", "photos", "modular", "analog", "flow", "weather", "calendar", "growth", "black", "system6"], "錶面陣容十款")
    check(FaceStyle.embossed.inLineup == .analog && FaceStyle.alarmClock.inLineup == .system6 && FaceStyle.about.inLineup == .system6 && FaceStyle.homeModular.inLineup == .modular, "舊錶面搬進新款")
    check(timerClock(299.2) == "5:00" && timerClock(59) == "0:59" && timerClock(0.3) == "0:01" && timerClock(3725) == "1:02:05", "倒数显示")
    let fct = Face(); fct.frozen = true; fct.startTimer(seconds: 2, now: 100)
    var fired = false; fct.onTimerDone = { fired = true }
    _ = fct.tick(101); check(fct.timerActive && !fired, "计时器还没到")
    _ = fct.tick(102.1); check(!fct.timerActive && fired, "计时器到点叫一下")
    // 壁纸色票：整点对上、之间插值、绕过午夜
    let noon = Face.palette(hour: 12, aqua: false), dayTop = Face.RGB(0x1d4a57)
    check(abs(noon.top.r - dayTop.r) < 1e-6 && abs(noon.top.b - dayTop.b) < 1e-6, "12 点＝白天色票")
    check(abs(Face.palette(hour: 12, aqua: true).top.b - Face.RGB(0x1b4f9c).b) < 1e-6, "G4 白的白天＝Aqua 蓝")
    let mid = Face.palette(hour: 9.5, aqua: false).top.r
    check(mid > min(Face.RGB(0x3a4f7a).r, dayTop.r) && mid < max(Face.RGB(0x3a4f7a).r, dayTop.r), "清晨到白天之间插值")
    let midnight = Face.palette(hour: 3, aqua: false).top.b
    check(midnight > Face.RGB(0x152447).b - 1 && midnight >= min(Face.RGB(0x152447).b, Face.RGB(0x3a4f7a).b) - 1e-6, "午夜后在夜里与清晨之间")
    // 靠近就多显示：展开会收敛
    let fc = Face(); fc.frozen = true; fc.revealTarget = 1
    for i in 0..<120 { _ = fc.tick(1000 + Double(i) / 60) }
    check(fc.reveal == 1, "游标靠近时玻璃卡展开到底")
    // 外观：五种都换得了，铝色是金属、G4 白不是
    let mdl = HomeViewModel()
    for f in Finish.allCases {
        mdl.apply(finish: f)
        let metal = mdl.selftestMetalness
        check(mdl.finish == f && (f == .g4 ? abs(metal) < 1e-6 : abs(metal - 1) < 1e-6), "外观 \(f.rawValue)")
    }
    // 拆開看看：九層錯開（外層先動、兩端到位）、每一件都有網格可挑、正面射進去先打到蓋板玻璃
    let layers = AnatomyLayer.allCases
    check(layers.allSatisfy { $0.progress(0) == 0 && $0.progress(1) == 1 }, "九层组好为 0、拆开为 1")
    check(zip(layers, layers.dropFirst()).allSatisfy { $0.progress(0.5) > $1.progress(0.5) }, "九层外层先动")
    check(AnatomyPart.allCases.allSatisfy { mdl.anatomyAnchor($0) != nil }, "每个零件都挑得到")
    let frontHit = mdl.pickAnatomy(origin: SIMD3<Float>(0, 10.5, 60), direction: SIMD3<Float>(0, 0, -1))?.0
    check(frontHit == .coverGlass, "正面先打到盖板玻璃（\(frontHit?.rawValue ?? "nil")）")
    // 拖底座＝搬窗口：组好时从正面打底座那一截，挑到的是底座零件；打屏幕不算
    let standYs: [Float] = [-1, 0, 1, 2, 3, 4, 5, 6, 7, 8]
    let standHits = standYs.map { mdl.pickAnatomy(origin: SIMD3<Float>(0, $0, 60), direction: SIMD3<Float>(0, 0, -1))?.0 }
    log("selftest stand picks \(zip(standYs, standHits).map { "\($0)=\($1?.rawValue ?? "nil")" }.joined(separator: " "))")
    check(standHits.contains { $0.map { PetView.standAnatomyForTest.contains($0) } ?? false }, "正面打底座挑到底座零件")
    check(!PetView.standAnatomyForTest.contains(frontHit ?? .coverGlass), "屏幕不是底座")
    // 搬位置提示：拖到窗外两次（30 秒内）才提示；拖一点点、隔太久都不算
    do {
        var d = MoveHintDetector()
        check(!d.rotateDragEnded(now: 0, leftWindow: true, travel: 50, width: 220), "搬位置提示：第一次不提示")
        check(!d.rotateDragEnded(now: 5, leftWindow: false, travel: 40, width: 220), "搬位置提示：小幅转动不算")
        check(d.rotateDragEnded(now: 10, leftWindow: false, travel: 400, width: 220), "搬位置提示：30 秒内第二次拖很远就提示")
        check(!d.rotateDragEnded(now: 11, leftWindow: true, travel: 0, width: 220), "搬位置提示：提示后重新计数")
        check(!d.rotateDragEnded(now: 60, leftWindow: true, travel: 0, width: 220), "搬位置提示：隔太久不累计")
    }
    // 舊版按鍵紀錄：只刪 keys.log／keys.log.1，同資料夾其他檔（含名字相近的）都留著
    do {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("homeplay-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for n in ["keys.log", "keys.log.1", "keys.log.bak", "syskeys.log", "receiver.log"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(n).path, contents: Data("x".utf8))
        }
        let removed = removeLegacyKeyLogs(in: dir)
        let left = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        check(removed == 2 && left == ["keys.log.bak", "syskeys.log", "receiver.log"], "旧按键纪录：只删 keys.log 与 keys.log.1")
        check(removeLegacyKeyLogs(in: dir) == 0, "旧按键纪录：再跑一次什么都不删")
        try? FileManager.default.removeItem(at: dir)
    }
    // Wi-Fi 名称自动补：读得到就送；没卡住不打扰；卡住且没问过才问定位；被拒或问过才手填
    do {
        typealias W = WiFiName
        check(W.decide(receiverKnows: true, readable: "Home", auth: .granted, stuck: true, quiet: false, alreadyAsked: false) == .nothing, "Wi-Fi 名称：接收器已知就不动")
        check(W.decide(receiverKnows: false, readable: "Home", auth: .granted, stuck: false, quiet: true, alreadyAsked: false) == .send("Home"), "Wi-Fi 名称：有权限就悄悄补上")
        check(W.decide(receiverKnows: false, readable: "<redacted>", auth: .denied, stuck: false, quiet: false, alreadyAsked: false) == .nothing, "Wi-Fi 名称：没卡住不弹东西")
        check(W.decide(receiverKnows: false, readable: nil, auth: .notDetermined, stuck: true, quiet: false, alreadyAsked: false) == .askPermission, "Wi-Fi 名称：卡住且没问过才问定位")
        check(W.decide(receiverKnows: false, readable: nil, auth: .notDetermined, stuck: true, quiet: false, alreadyAsked: true) == .manual, "Wi-Fi 名称：问过（选了以后）就手填")
        check(W.decide(receiverKnows: false, readable: nil, auth: .denied, stuck: true, quiet: false, alreadyAsked: false) == .manual, "Wi-Fi 名称：被拒就手填")
        check(W.decide(receiverKnows: false, readable: nil, auth: .granted, stuck: true, quiet: false, alreadyAsked: false) == .manual, "Wi-Fi 名称：允许了却读不到（没连 Wi-Fi）就手填")
        check(W.decide(receiverKnows: false, readable: nil, auth: .notDetermined, stuck: true, quiet: true, alreadyAsked: false) == .nothing, "Wi-Fi 名称：背景挂着不打扰")
        check(W.usable(" Home ") == "Home" && W.usable("<redacted>") == nil && W.usable("") == nil, "Wi-Fi 名称：脱敏占位不算")
    }
    // 连不上的排障卡：每个原因各有标题；40 秒后给插线退路；网络名带进句子；日志只数次数
    do {
        let reasons = ["macFirewall", "localNetwork", "carPlayConsent", "ssidUnknown", "inboundBlocked", "wifiNoConnectBack",
                       "usbNoData", "usbLocked", "usbTrustExpired", "usbNoNetwork"]
        let titles = Set(reasons.map { ConnectHelp.card(reason: $0, ssid: "Home", needsPassword: false, helpElapsed: 0).title })
        check(titles.count == reasons.count, "排障卡：每个原因（无线六个、有线四个）各有标题")
        let early = ConnectHelp.card(reason: "wifiNoConnectBack", ssid: "Home", needsPassword: false, helpElapsed: 5)
        let late = ConnectHelp.card(reason: "wifiNoConnectBack", ssid: "Home", needsPassword: false, helpElapsed: 45)
        check(early.subtitle.contains("Home") && early.hint == nil && late.hint != nil && late.chip != early.chip, "排障卡：40 秒后改给插线与诊断报告")
        check(ConnectHelp.card(reason: nil, ssid: "", needsPassword: true, helpElapsed: 0).hint != nil, "排障卡：旧接收器没给原因也有提示")
        let selftestLog = Substring("[1] 无线：身份自检通过\n[2] 无线：送 0x4301：无线 10.0.0.2\n[3] 无线：手机连入控制口 10.0.0.3\n[4] 无线：会话开始，等画面\n")
        let sum = ConnectHelp.summarizeLog(selftestLog)
        check(sum.contains("start sent 1") && sum.contains("sessions 1") && !sum.contains("10.0.0"), "诊断报告：日志只数次数、不抄地址")
    }
    mdl.apply(1)
    let baseHit = mdl.pickAnatomy(origin: SIMD3<Float>(0, -5.9, 60), direction: SIMD3<Float>(0, 0, -1))?.0
    check(baseHit == .foot, "拆开后最下面是底脚（\(baseHit?.rawValue ?? "nil")）")
    mdl.apply(0)
    // 島錶面选项：坏值退回默认、没照片退回随时段、直排两位数
    check(ClockStyle(rawValue: "bogus") == nil && IslandBackground.photo.effective(hasPhoto: false) == .daytime
          && IslandBackground.solid.effective(hasPhoto: false) == .solid && IslandBackground.photo.effective(hasPhoto: true) == .photo, "島錶面背景：没照片退回随时段")
    let part = Face.clockParts(Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 9, minute: 5))!)
    check(part.h == "09" && part.m == "05", "直排时钟两位小时分钟")
    // 换錶面总览：到头不绕回；弹簧 0.3 s 内到位、不冲过头
    check(FaceOverview.step(0, -1, count: 9) == 0 && FaceOverview.step(8, 1, count: 9) == 8 && FaceOverview.step(3, 1, count: 9) == 4, "总览挪格到头停")
    var sx: CGFloat = 0, sv: CGFloat = 0, over = false
    for _ in 0..<18 { (sx, sv) = FaceOverview.spring(sx, sv, to: 1, dt: 1.0 / 60); if sx > 1.0001 { over = true } }
    check(abs(sx - 1) < 0.03 && !over, "总览弹簧临界阻尼")

    // 正在播放：解析、进度、暂停 30 秒后收起
    let np0 = NowPlayingLogic.parse("playing\t歌\t人\t200,5\t50", durationScale: 1, now: 0)
    check(np0?.title == "歌" && np0?.duration == 200.5 && np0?.playing == true, "正在播放：解析含小数逗号")
    check(NowPlayingLogic.parse("stopped", durationScale: 1, now: 0) == nil, "正在播放：停止＝没有")
    if var np = np0 {
        check(NowPlayingLogic.progress(np, now: 50.25).map { abs($0 - 0.5) < 1e-9 } == true, "正在播放：进度随时间走")
        np.playing = false
        check(NowPlayingLogic.active(np, lastPlayingAt: 0, now: 29) && !NowPlayingLogic.active(np, lastPlayingAt: 0, now: 31), "正在播放：暂停 30 秒后收起")
    }
    // 窗口位置记忆：屏外放弃；部分在屏外钳回；宽度钳进范围
    let scr = [CGRect(x: 0, y: 0, width: 1440, height: 860), CGRect(x: 1440, y: 100, width: 1920, height: 1080)]
    let offScreen = WindowFrameStore.restore([5000, 5000, 300], visible: scr) == nil && WindowFrameStore.restore(nil, visible: scr) == nil && WindowFrameStore.restore([1, 2], visible: scr) == nil
    check(offScreen, "窗口位置：屏外/坏数据放弃")
    let wr = WindowFrameStore.restore([1400, -50, 300], visible: scr)!
    check(wr.width == 300 && abs(wr.height - 300 / Pet.aspect) < 1e-9 && scr[1].contains(wr), "窗口位置：跨屏时钳进重叠最多的那块")
    check(WindowFrameStore.restore([100, 100, 5], visible: scr)!.width == Pet.minWidth && WindowFrameStore.restore([100, 100, 9999], visible: scr)!.width == Pet.maxWidth, "窗口位置：宽度钳进范围")
    // 行事历：挑下一个（定时的优先、已结束的不要、全天垫底）与时间段写法
    let t0 = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 10, minute: 0))!
    func ev(_ n: String, _ h: Int, _ m: Int, _ eh: Int, _ em: Int, allDay: Bool = false) -> NextEvent {
        NextEvent(title: n, start: Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: t0)!,
                  end: Calendar.current.date(bySettingHour: eh, minute: em, second: 0, of: t0)!, allDay: allDay)
    }
    let evs = [ev("allday", 0, 0, 23, 59, allDay: true), ev("late", 15, 0, 16, 0), ev("past", 8, 0, 9, 0), ev("early", 10, 30, 11, 0)]
    let picked = CalendarLogic.pick(evs, now: t0)?.title == "early" && CalendarLogic.pick([evs[0], evs[2]], now: t0)?.title == "allday" && CalendarLogic.pick([evs[2]], now: t0) == nil
    check(picked, "行事历：挑下一个行程")
    check(CalendarLogic.range(evs[3]) == "10:30–11:00" && CalendarLogic.range(ev("x", 9, 5, 18, 0)) == "09:05–18:00", "行事历：时间段写法")
    let tiles4 = CalendarLogic.tile(auth: .notDetermined, on: true, event: nil) == .notConnected && CalendarLogic.tile(auth: .denied, on: true, event: nil) == .denied
        && CalendarLogic.tile(auth: .fullAccess, on: true, event: nil) == .empty && CalendarLogic.tile(auth: .fullAccess, on: false, event: evs[3]) == .notConnected
        && CalendarLogic.tile(auth: .fullAccess, on: true, event: evs[3]) == .event(evs[3])
    check(tiles4, "行事历：四种状态")
    // 连线过场：0.3 秒淡入到 1、淡出到 0
    var oa: CGFloat = 0
    for _ in 0..<18 { oa = CarPlayOverlayState.nextAlpha(oa, target: 1, dt: 1.0 / 60) }
    check(oa == 1, "连线过场 0.3 秒淡入")
    for _ in 0..<18 { oa = CarPlayOverlayState.nextAlpha(oa, target: 0, dt: 1.0 / 60) }
    check(oa == 0, "连线过场 0.3 秒淡出")
    // 手势仲裁：起手决定、整个手势含惯性锁定、捏合让位
    do {
        var a = ScrollArbiter()
        var calls = 0
        let body: () -> GestureTarget = { calls += 1; return .rotate }
        let screen: () -> GestureTarget = { calls += 1; return .carplay }
        var t = a.route(now: 0, began: true, momentum: false, ended: false, momentumEnded: false, dx: 5, dy: 0, pinching: false, classify: body)
        check(t == .rotate && calls == 1, "仲裁：机身起手＝转身体")
        t = a.route(now: 0.02, began: false, momentum: false, ended: false, momentumEnded: false, dx: 5, dy: 0, pinching: false, classify: screen)
        check(t == .rotate && calls == 1, "仲裁：手势中途滑进屏幕仍是转身体（不重判）")
        t = a.route(now: 0.05, began: false, momentum: false, ended: true, momentumEnded: false, dx: 0, dy: 0, pinching: false, classify: screen)
        t = a.route(now: 0.07, began: false, momentum: true, ended: false, momentumEnded: false, dx: 9, dy: 0, pinching: false, classify: screen)
        check(t == .rotate && calls == 1, "仲裁：惯性沿用起手的目标")
        t = a.route(now: 0.09, began: false, momentum: true, ended: false, momentumEnded: true, dx: 0, dy: 0, pinching: false, classify: screen)
        check(t == .rotate && a.target == nil, "仲裁：惯性结束后清锁定")
        t = a.route(now: 0.5, began: false, momentum: true, ended: false, momentumEnded: false, dx: 3, dy: 0, pinching: false, classify: screen)
        check(t == .none, "仲裁：孤立的惯性不开启新手势")
        t = a.route(now: 1.0, began: true, momentum: false, ended: false, momentumEnded: false, dx: 2, dy: 0, pinching: false, classify: screen)
        check(t == .carplay, "仲裁：直播屏幕起手＝CarPlay")
        t = a.route(now: 1.02, began: false, momentum: false, ended: false, momentumEnded: false, dx: 2, dy: 0, pinching: true, classify: body)
        check(t == .none, "仲裁：捏合确认后滑动让位")
        var w = ScrollArbiter()   // 无 phase 的滚轮：间隔 >0.25 s 算新手势
        _ = w.route(now: 0, began: false, momentum: false, ended: false, momentumEnded: false, dx: 1, dy: 0, pinching: false, classify: body)
        t = w.route(now: 0.4, began: false, momentum: false, ended: false, momentumEnded: false, dx: 1, dy: 0, pinching: false, classify: { .none })
        check(t == .none, "仲裁：无 phase 滚轮停顿后重新判定")
        var c = ScrollArbiter()
        _ = c.route(now: 0, began: true, momentum: false, ended: false, momentumEnded: false, dx: 4, dy: 0, pinching: false, classify: body)
        check(!c.committed, "仲裁：小于 12 pt 不算确定在滑")
        _ = c.route(now: 0.02, began: false, momentum: false, ended: false, momentumEnded: false, dx: 10, dy: 0, pinching: false, classify: body)
        check(c.committed, "仲裁：累计超过 12 pt 算确定在滑")
    }
    // 机身朝向：窗口在右朝左、在左朝右；跟随有视差、有 ±25° 夹限；死区不抖；正面固定恒 0；走开 2 s 后回基准
    do {
        let d = Aim.deg
        let right = Aim.baseline(windowMidX: 1.0, screenMidX: 0.5, screenHalfWidth: 0.5)
        let left = Aim.baseline(windowMidX: 0.0, screenMidX: 0.5, screenHalfWidth: 0.5)
        check(right < -17 * d && right > -19 * d && abs(left + right) < 1e-9, "朝向：贴右边约 -18°、左右对称")
        check(Aim.baseline(windowMidX: 0.5, screenMidX: 0.5, screenHalfWidth: 0.5) == 0, "朝向：居中不倾斜")
        check(ViewMode(rawValue: "wall") == .wall && ViewMode.wall.rawValue == "wall" && ViewMode.allCases.count == 3, "朝向：挂墙存取来回一致")
        check(Pet.aspect(for: .wall) < 1 && Pet.aspect(for: .wall) > 0.9 && Pet.aspect(for: .auto) == Pet.standAspect, "挂墙窗口近正方，其它照旧")
        let wc = HomeViewModel.wallScreenCenter
        check(abs(wc.x) < 1e-6 && wc.y > 9.5 && wc.y < 10.6 && wc.z > 4.28, "挂墙：扶正后的屏幕中心在铰链上方、往前")
        check(abs(Aim.followTarget(gazeX: 1, baseline: 0, maxDegrees: 25) - 25 * d) < 1e-9, "朝向：跟随夹在 25°")
        check(Aim.followTarget(gazeX: 0, baseline: right, maxDegrees: 25) < 0, "朝向：人在镜头正前、桌宠在右 → 朝左（视差）")
        var a = Aim(); var t = 0.0
        for _ in 0..<240 { t += 1.0 / 60; _ = a.step(now: t, dt: 1.0 / 60, mode: .auto, following: true, present: true, gazeX: 0.6, baseline: 0, maxDegrees: 25) }
        let settledAt = a.angle
        check(a.settled && settledAt > 15 * d, "朝向：4 秒内落定到人的方向")
        for _ in 0..<60 { t += 1.0 / 60; _ = a.step(now: t, dt: 1.0 / 60, mode: .auto, following: true, present: true, gazeX: 0.63, baseline: 0, maxDegrees: 25) }
        check(abs(a.angle - settledAt) < 1e-6, "朝向：小于 3° 的移动不跟（不抖）")
        var maxV = 0.0, prev = a.angle
        for _ in 0..<60 { t += 1.0 / 60; let x = a.step(now: t, dt: 1.0 / 60, mode: .auto, following: true, present: false, gazeX: 0, baseline: 0, maxDegrees: 25); maxV = max(maxV, abs(x - prev) * 60); prev = x }
        check(abs(a.angle - settledAt) < 0.5 * d, "朝向：人走开先停 2 s")
        for _ in 0..<360 { t += 1.0 / 60; let x = a.step(now: t, dt: 1.0 / 60, mode: .auto, following: true, present: false, gazeX: 0, baseline: 0, maxDegrees: 25); maxV = max(maxV, abs(x - prev) * 60); prev = x }
        check(abs(a.angle) < 0.5 * d, "朝向：之后回到基准")
        check(maxV <= Aim.maxSpeed + 1e-6, "朝向：角速度不超过 70°/s")
        var f = Aim()
        for _ in 0..<120 { t += 1.0 / 60; _ = f.step(now: t, dt: 1.0 / 60, mode: .front, following: true, present: true, gazeX: 1, baseline: right, maxDegrees: 25) }
        check(f.angle == 0, "朝向：正面固定恒为 0")
    }
    // 番茄鐘：專注 → 短休息 ×3，第 4 個專注後長休息，休息後回專注；停止後不再前進
    do {
        var p = Pomodoro()
        check(p.start() == .focus && p.displayRound == 1, "番茄钟：开始＝第 1 轮专注")
        var seq: [PomodoroPhase] = []
        for _ in 0..<8 { if let a = p.advance() { seq.append(a.next) } }
        check(seq == [.shortBreak, .focus, .shortBreak, .focus, .shortBreak, .focus, .longBreak, .focus], "番茄钟：四轮后长休息，再回专注")
        check(p.displayRound == 1, "番茄钟：长休息后轮数归零")
        p.stop()
        check(p.advance() == nil && !p.active, "番茄钟：停止后不再前进")
        check(PomodoroPhase.focus.seconds == 1500 && PomodoroPhase.shortBreak.seconds == 300 && PomodoroPhase.longBreak.seconds == 900, "番茄钟：25／5／15 分钟")
    }
    // 两指类型：同向平移＝滑动；沿连线相向／相背＝捏合（一指不动也算）；扭转＝都不做；没走够＝未定；换手指重来
    do {
        func run(_ a: [(Double, Double)], _ b: [(Double, Double)]) -> TwoFingerKind {
            var c = TwoFingerClassifier(); var k = TwoFingerKind.undecided
            for (p, q) in zip(a, b) { k = c.feed(id0: 7, x0: p.0, y0: p.1, id1: 9, x1: q.0, y1: q.1) }
            return k
        }
        check(run([(0.40, 0.50), (0.40, 0.47)], [(0.55, 0.50), (0.55, 0.47)]) == .scroll, "两指：一起往下＝滑动")
        check(run([(0.40, 0.50), (0.43, 0.505)], [(0.55, 0.50), (0.575, 0.497)]) == .scroll, "两指：一起往右（一指略慢）＝滑动")
        check(run([(0.40, 0.50), (0.385, 0.50)], [(0.55, 0.50), (0.565, 0.50)]) == .pinch, "两指：相背张开＝捏合")
        check(run([(0.40, 0.50), (0.40, 0.50)], [(0.55, 0.50), (0.535, 0.50)]) == .pinch, "两指：一指不动另一指靠近＝捏合")
        check(run([(0.40, 0.50), (0.40, 0.488)], [(0.55, 0.50), (0.55, 0.512)]) == .twist, "两指：扭转＝都不做")
        check(run([(0.40, 0.50), (0.403, 0.50)], [(0.55, 0.50), (0.553, 0.50)]) == .undecided, "两指：没走够 1.5 mm 先不判")
        var c = TwoFingerClassifier()
        _ = c.feed(id0: 1, x0: 0.4, y0: 0.5, id1: 2, x1: 0.55, y1: 0.5)
        _ = c.feed(id0: 2, x0: 0.565, y0: 0.5, id1: 1, x1: 0.385, y1: 0.5)   // 数组里换位：按 id 配对
        check(c.kind == .pinch, "两指：按手指 id 配对，换位不影响")
        _ = c.feed(id0: 3, x0: 0.4, y0: 0.5, id1: 4, x1: 0.55, y1: 0.5)
        check(c.kind == .undecided, "两指：换了手指就重新判定")
    }
    // 來電卡：接收器 JSON → 卡片狀態與按鍵；F5 按住說話吸收重複的按下／放開
    do {
        let ring = PhoneCallInfo.parse(#"{"incoming":true,"name":"Alice","number":"+491701234567","state":"ringing","type":"call","uuid":"uuid-1"}"#)
        check(ring?.isIncomingRing == true && ring?.title == "Alice" && ring?.actions == [.decline, .answer], "来电：响铃给拒接＋接听")
        check(ring?.subtitle(carrier: "o2").contains("+491701234567") == true, "来电：有名字时小字带号码")
        let active = PhoneCallInfo.parse(#"{"state":"active","type":"call","number":"110"}"#)
        check(active?.actions == [.hangUp] && active?.title == "110" && active?.isIncomingRing == false, "来电：通话中只给挂断")
        let idle = PhoneCallInfo.parse(#"{"state":"idle","type":"call"}"#)
        check(idle?.showsCard == false && idle?.actions.isEmpty == true, "来电：idle 收卡")
        check(PhoneCallInfo.parse(#"{"type":"nowplaying"}"#) == nil, "来电：别的消息不解析")
        check(PhoneCallInfo(state: .ringing).title.isEmpty == false, "来电：没名字没号码也有标题")
        check(CellularInfo.parse(#"{"carrier":"o2","signal":4,"type":"cellular"}"#) == CellularInfo(carrier: "o2", signal: 4), "电信商与讯号")
        var k = SiriHoldKey()
        check(k.press(now: 0) && !k.press(now: 0.01), "F5：重复的按下只算一次")
        check(!k.overdue(now: 29) && k.overdue(now: 30), "F5：按住 30 秒自动放开")
        check(k.release() && !k.release(), "F5：重复的放开只算一次")
    }
    // CarPlay 圓角：平常的連線原樣直通；學圓角那一次（learning）收到遮罩才縮放
    do {
        let side = 64, r = 40.0
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 1,
                                   hasAlpha: false, isPlanar: false, colorSpaceName: .deviceWhite, bytesPerRow: side, bitsPerPixel: 8)!
        for y in 0..<side { for x in 0..<side {
            let dx = max(0, r - (Double(x) + 0.5)), dy = max(0, r - (Double(y) + 0.5))
            rep.bitmapData![y * side + x] = UInt8((max(0, min(1, r - (dx * dx + dy * dy).squareRoot() + 0.5)) * 255).rounded())
        } }
        let png = rep.representation(using: .png, properties: [:])!.base64EncodedString()
        let dev = MTLCreateSystemDefaultDevice()!
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: 64, height: 64, mipmapped: false)
        d.usage = [.shaderRead]; d.storageMode = .shared
        let src = dev.makeTexture(descriptor: d)!
        let fit = CornerFit.shared
        fit.handle(["type": "cornerMask", "negotiated": false, "learning": false], videoWidth: 1088, device: dev)
        check(fit.apply(src) === src && fit.toVideo(u: 0.01, v: 0.5) != nil, "圆角：平常的连线原样直通")
        fit.handle(["type": "cornerMask", "negotiated": true, "learning": true, "png": png], videoWidth: 1088, device: dev)
        check(fit.scale < 0.95 && fit.apply(src) !== src && fit.toVideo(u: 0.01, v: 0.5) == nil, "圆角：学圆角那一次缩放补黑（k=\(String(format: "%.3f", fit.scale))）")
        fit.handle(["type": "cornerMask", "negotiated": false, "learning": false], videoWidth: 1088, device: dev)
        check(fit.apply(src) === src, "圆角：下一次平常的连线又原样直通")
    }
    do {   // 換手機：同一條 WS 上 ended → started → 幀，要再報一次 live
        let ended = #"{"type":"session","state":"ended"}"#, started = #"{"type":"session","state":"started"}"#
        check(FirstFrameLatch.replay([nil, nil]) == [true, false], "首幀：同一會話只報一次 live")
        check(FirstFrameLatch.replay([nil, ended, started, nil, nil]) == [true, true, false], "首幀：換手機 ended→started 之後的第一幀再報 live")
        check(FirstFrameLatch.replay([nil, started, nil]) == [true, true], "首幀：只收到 started 也重新報 live")
        check(FirstFrameLatch.replay([nil, #"{"type":"nowplaying"}"#, nil]) == [true, false], "首幀：別的文字不重置")
    }
    log(ok ? "selftest OK" : "selftest FAIL"); exit(ok ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
delegate.endpoint = arg("--endpoint")
if let s = arg("--size"), let w = Double(s) { delegate.initialWidth = max(Pet.minWidth, min(Pet.maxWidth, CGFloat(w))); delegate.sizeGiven = true }
if CommandLine.arguments.contains("--apart") { delegate.initialApart = true }
if let s = arg("--apart-t"), let t = Double(s) { delegate.initialApartT = CGFloat(max(0, min(1, t))) }
if let s = arg("--part") { delegate.initialPart = AnatomyPart(rawValue: s) }   // 例：--part logicBoard
if CommandLine.arguments.contains("--dark") { NSApplication.shared.appearance = NSAppearance(named: .darkAqua) }   // 快照：深色外观
if let s = arg("--yaw"), let y = Double(s) { delegate.initialYaw = CGFloat(y) }
if let s = arg("--pitch"), let y = Double(s) { delegate.initialPitch = CGFloat(y) }
delegate.snapshotPath = arg("--snapshot")
delegate.snapshotGlancePath = arg("--snapshot-glance")
delegate.snapshotBlinkPath = arg("--snapshot-blink")
if let s = arg("--snapshot-at"), let t = Double(s) { delegate.snapshotDelay = max(0.3, t) }   // 拍开机 hello 用
if let s = arg("--bench"), let t = Double(s) { delegate.benchSeconds = max(1, t) }
if let s = arg("--view") { delegate.initialView = s }   // 除錯：front|side|back|above，走選單同一條路   // 效能基準：跑 N 秒後印統計並結束
if let s = arg("--style") {
    guard let st = FaceStyle(rawValue: s) else {
        log("--style 只认：\(FaceStyle.allCases.map(\.rawValue).joined(separator: " "))"); exit(2)
    }
    // 舊腳本的 --style embossed／alarmClock／about：換成併進去的那款，並設好對應的選項
    let mig = st.migratedOptions
    if let m = mig.material { faceOptionSnapshotOverride.material = m }
    if let l = mig.layout { faceOptionSnapshotOverride.layout = l }
    delegate.faceStyle = st.inLineup
}
if let s = arg("--typograph-material") {   // 快照用：flat embossed
    guard let m = TypographMaterial(rawValue: s) else { log("--typograph-material 只认：flat embossed"); exit(2) }
    faceOptionSnapshotOverride.material = m
}
if let s = arg("--system6-layout") {   // 快照用：finder alarmClock about
    guard let l = System6Layout(rawValue: s) else { log("--system6-layout 只认：finder alarmClock about"); exit(2) }
    faceOptionSnapshotOverride.layout = l
}
if let s = arg("--clock") { islandSnapshotOverride.clock = ClockStyle(rawValue: s) }
if let s = arg("--clock-look") { ClockLook.snapshotOverride = ClockLook.parse(s) }   // 快照用：字体与颜色   // 快照用：島錶面时钟样式 bold thin stacked compact
if let s = arg("--bg") { islandSnapshotOverride.bg = IslandBackground(rawValue: s) }     // daytime flow photo solid black
if let s = arg("--era") { islandSnapshotOverride.era = ["1988": Era.y1988, "2002": .y2002, "2026": .y2026][s] }
if let s = arg("--capsule"), let m = CapsuleMaterial(rawValue: s) { capsuleMaterialSetting = m }   // 快照用：auto black smoke glass
if let s = arg("--siri") { SiriOrbState.snapshotPhase = s }   // 快照用：listen | think
if arg("--snapshot") != nil || ProcessInfo.processInfo.environment["HOMEPLAY_DEMO"] != nil { Face.demoData = true }   // 快照：Home Modular 用示範資料
if let s = arg("--timer"), let t = Double(s) { delegate.timerSeconds = t }   // 快照用：开一个 t 秒的计时器
if let s = arg("--music") { delegate.musicTest = s; NowPlayingPoller.disabled = true }   // 快照用：固定一个「正在播放」
if CommandLine.arguments.contains("--connecting") { CarPlayOverlayState.forced = true }
if CommandLine.arguments.contains("--pairing-code") {   // 快照用：插線配對的數字比對那一格
    CarPlayOverlayState.bluetoothPairing = true; CarPlayOverlayState.pairPhase = "confirm"; CarPlayOverlayState.pairCode = "482913"
    CarPlayOverlayState.pairDeadline = CACurrentMediaTime() + 27; CarPlayOverlayState.forced = true
}
if CommandLine.arguments.contains("--wifi-help") {   // 快照用：手機報了可用卻沒從 Wi-Fi 連回
    CarPlayOverlayState.wifiHelp = true; CarPlayOverlayState.forced = true
}
if let r = arg("--connect-reason") {   // 快照用：排障卡（macFirewall localNetwork carPlayConsent ssidUnknown inboundBlocked wifiNoConnectBack）
    CarPlayOverlayState.wifiHelp = true; CarPlayOverlayState.forced = true
    CarPlayOverlayState.connectReason = r; CarPlayOverlayState.helpSSID = arg("--help-ssid") ?? ""
    CarPlayOverlayState.helpSince = CACurrentMediaTime() - (arg("--help-age").flatMap(Double.init) ?? 0)   // --help-age 45：40 秒後的那一格
}
if CommandLine.arguments.contains("--pairing-no-response") {   // 快照用：叫不到手機
    CarPlayOverlayState.bluetoothPairFailed = true; CarPlayOverlayState.pairFailReason = "noResponse"; CarPlayOverlayState.forced = true
}
if CommandLine.arguments.contains("--pairing-success") {   // 快照用：配對成功那一格（綠色滿環）
    CarPlayOverlayState.forced = true; CarPlayOverlayState.snapshotPaired = true
}
if CommandLine.arguments.contains("--pairing") { CarPlayOverlayState.needsPairing = true; CarPlayOverlayState.forced = true }   // 快照用：强制显示连线中过场
if CommandLine.arguments.contains("--pairing-success") { CarPlayOverlayState.pairingSucceededAt = CACurrentMediaTime(); CarPlayOverlayState.forced = true }   // 快照用：刚配对成功
if let s = arg("--pair-host") { CarPlayOverlayState.pairingHost = s }   // 快照用：蓝牙配对卡上的 Mac 名称
if CommandLine.arguments.contains("--onboarding") { Onboarding.forced = true }   // 快照用：强制显示第一次的操作提示
if let s = arg("--event") { delegate.eventTest = s; CalendarSource.disabled = true }   // 快照用：固定一个「下一个行程」
if CommandLine.arguments.contains("--banner") { delegate.showBanner = true }   // 快照用：显示「时间到了」横幅
if CommandLine.arguments.contains("--hello") { delegate.forceHello = true }     // 快照用：强制开机写 hello
if CommandLine.arguments.contains("--overview") { FaceOverview.forced = true }   // 快照用：长按换錶面总览
delegate.photosDir = arg("--photos")
if let s = arg("--hour"), let h = Double(s) { delegate.hourOverride = max(0, min(23.99, h)) }
if let s = arg("--pointer") {   // 快照用：固定好奇时眼珠方向，例如 0,0
    let v = s.split(separator: ",").compactMap { Double($0) }
    if v.count == 2 { Face.pointerOverride = CGPoint(x: max(-1, min(1, v[0])), y: max(-1, min(1, v[1]))) }
}
if let s = arg("--permission"), let k = PermissionKind(rawValue: s) {   // 快照：权限说明卡（--perm-state intro|waiting|granted|denied）
    PermissionPrimer.forced = true; PermissionPrimer.kind = k
    switch arg("--perm-state") ?? "intro" {
    case "waiting": PermissionPrimer.phase = .waiting
    case "granted": PermissionPrimer.phase = .granted
    case "denied": PermissionPrimer.phase = .denied
    default: PermissionPrimer.phase = .intro
    }
}
if let s = arg("--window-x"), let v = Double(s) { PetView.windowXOverride = max(0, min(1, v)) }   // 快照：窗口横向位置 0…1
// 快照／基准默认当作窗口居中：官网和文档的产品图不该因为拍照时窗口落在哪而歪
else if arg("--snapshot") != nil || arg("--bench") != nil { PetView.windowXOverride = 0.5 }
if let s = arg("--view-mode"), let m = ViewMode(rawValue: s) { ViewMode.override = m }
if let s = arg("--gaze") {      // 快照用：模拟追人样本，例如 1,0（右）或 -1,0（左）
    let v = s.split(separator: ",").compactMap { Double($0) }
    if v.count == 2 { delegate.gazeTest = (CGFloat(max(-1, min(1, v[0]))), CGFloat(max(-1, min(1, v[1])))) }
}
if let s = arg("--time") {      // 快照用：固定屏幕上的时间，例如 23:12（夜里的氛围图才合理）
    let v = s.split(separator: ":").compactMap { Int($0) }
    if v.count == 2 { snapshotDateOverride = Calendar.current.date(bySettingHour: v[0], minute: v[1], second: 0, of: Date()) }
}
if CommandLine.arguments.contains("--near") { delegate.forceNear = true }
if let s = arg("--finish") {
    guard let f = Finish(rawValue: s) else {
        log("--finish 只认：\(Finish.allCases.map(\.rawValue).joined(separator: " "))"); exit(2)
    }
    delegate.finish = f
}
if let s = arg("--face") {
    guard let e = Expression(name: s) else {
        log("--face 只认：\(Expression.allCases.map(\.rawValue).joined(separator: " "))"); exit(2)
    }
    delegate.lockedFace = e
}
if let s = arg("--at") {
    let c = s.split(separator: ",").compactMap { Double($0) }
    if c.count == 2 { delegate.origin = NSPoint(x: c[0], y: c[1]) }
}
app.delegate = delegate
app.run()

extension Notification.Name {
    static let homePlaySiriHotKey = Notification.Name("HomePlaySiriHotKey")
}
