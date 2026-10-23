// 錶面大時間的「字體與顏色」：照 iOS 27 鎖定畫面的編輯面板——一排字體、粗細滑桿、一排色票、色調滑桿、玻璃／實線。
// 字體都取自系統時鐘字型 ADTNumeric.ttc；SF、柔圓、New York 有 HGHT 軸，能像鎖定畫面那樣長高，其他的照原比例放大。
// 設定存 UserDefaults；島錶面（粗、直排、島數字）與照片錶面都照這組畫。

import AppKit
import SwiftUI

struct ClockLook: Equatable, Codable {
    enum Font: String, CaseIterable, Codable {
        case sf, soft, newYork, stencil, rail, slab
        /// 能長高（HGHT 軸）的字體：窄高大時間；其他的照原比例
        var adaptive: Bool { self == .sf || self == .soft || self == .newYork }
        /// 滑桿 0…1 對到這套字的 wght 範圍
        func weight(_ t: Double) -> CGFloat {
            let (lo, hi): (Double, Double)
            switch self {
            case .sf, .soft: (lo, hi) = (100, 900)
            case .newYork, .slab: (lo, hi) = (300, 1000)
            case .stencil: (lo, hi) = (100, 1000)
            case .rail: (lo, hi) = (1, 400)
            }
            return CGFloat(lo + (hi - lo) * max(0, min(1, t)))
        }
        func nsFont(_ size: CGFloat, weight t: Double) -> NSFont {
            let w = weight(t)
            switch self {
            case .sf: return FaceType.numeric(.adaptive, size, ["wght": w])
            case .soft: return FaceType.numeric(.adaptiveSoft, size, ["wght": w, "SOFT": 100])
            case .newYork: return FaceType.numeric(.newYork, size, ["wght": w])
            case .stencil: return FaceType.numeric(.stencil, size, ["wght": w])
            case .rail: return FaceType.numeric(.rail, size, ["wght": w])
            case .slab: return FaceType.numeric(.slab, size, ["wght": w])
            }
        }
        /// 面板裡的「12」：一般字寬的同一家族（能長高的字體預設字形是窄高的，預覽不好認）
        func previewFont(_ size: CGFloat, weight t: Double) -> NSFont {
            let w = weight(t)
            switch self {
            case .sf: return FaceType.numeric(.sf, size, ["wght": w, "wdth": 100])
            case .soft: return FaceType.numeric(.soft, size, ["wght": w, "wdth": 100, "SOFT": 100])
            case .newYork: return FaceType.numeric(.newYork, size, ["wght": w, "wdth": 100, "opsz": 60])
            default: return nsFont(size, weight: t)
            }
        }
        var title: String {
            switch self {
            case .sf: return "SF"
            case .soft: return L("clockLook.font.soft", "柔圆")
            case .newYork: return "New York"
            case .stencil: return L("clockLook.font.stencil", "镂空")
            case .rail: return L("clockLook.font.rail", "细轨")
            case .slab: return L("clockLook.font.slab", "粗衬线")
            }
        }
    }

    enum Swatch: String, CaseIterable, Codable {
        case auto, white, cyan, blue, lavender, purple, pink, orange, yellow, green
        /// 色相（0…1）；auto 跟著壁紙、white 沒有色相
        var hue: CGFloat? {
            switch self {
            case .auto, .white: return nil
            case .cyan: return 0.53
            case .blue: return 0.62
            case .lavender: return 0.70
            case .purple: return 0.79
            case .pink: return 0.95
            case .orange: return 0.07
            case .yellow: return 0.14
            case .green: return 0.36
            }
        }
        var title: String {
            switch self {
            case .auto: return L("clockLook.color.auto", "跟随壁纸")
            case .white: return L("clockLook.color.white", "白色")
            case .cyan: return L("clockLook.color.cyan", "青色")
            case .blue: return L("clockLook.color.blue", "蓝色")
            case .lavender: return L("clockLook.color.lavender", "薰衣草")
            case .purple: return L("clockLook.color.purple", "紫色")
            case .pink: return L("clockLook.color.pink", "粉色")
            case .orange: return L("clockLook.color.orange", "橙色")
            case .yellow: return L("clockLook.color.yellow", "黄色")
            case .green: return L("clockLook.color.green", "绿色")
            }
        }
    }

    var font: Font = .sf
    var weight: Double = 0.48      // 預設 ≈ wght 480（原本的玻璃大數字）
    var swatch: Swatch = .white
    var tone: Double = 0.5         // 色調滑桿：0 淡、1 濃（白色：0 偏灰、1 純白）
    var glass = true

    static let defaultsKey = "HomePlayClockLook"
    nonisolated(unsafe) static var current: ClockLook = {
        guard let d = UserDefaults.standard.data(forKey: defaultsKey), let v = try? JSONDecoder().decode(ClockLook.self, from: d) else { return ClockLook() }
        return v
    }() {
        didSet { if let d = try? JSONEncoder().encode(current) { UserDefaults.standard.set(d, forKey: defaultsKey) } }
    }

    /// 快照用：命令行指定（--clock-look "font=stencil,weight=0.7,swatch=blue,tone=0.6,glass=0"），不寫 UserDefaults
    nonisolated(unsafe) static var snapshotOverride: ClockLook?
    static var active: ClockLook { snapshotOverride ?? current }
    static func parse(_ s: String) -> ClockLook {
        var l = ClockLook()
        for kv in s.split(separator: ",") {
            let p = kv.split(separator: "=").map(String.init)
            guard p.count == 2 else { continue }
            switch p[0] {
            case "font": l.font = Font(rawValue: p[1]) ?? l.font
            case "weight": l.weight = Double(p[1]) ?? l.weight
            case "swatch": l.swatch = Swatch(rawValue: p[1]) ?? l.swatch
            case "tone": l.tone = Double(p[1]) ?? l.tone
            case "glass": l.glass = p[1] != "0"
            default: break
            }
        }
        return l
    }

    var key: String { "\(font.rawValue)|\(Int(weight * 100))|\(swatch.rawValue)|\(Int(tone * 100))|\(glass)" }

    /// 實際顏色：auto 用壁紙的平均色（提亮、加一點飽和）
    func color(wallpaper: NSColor?) -> NSColor {
        let t = CGFloat(max(0, min(1, tone)))
        switch swatch {
        case .white: return NSColor(white: 0.78 + 0.22 * t, alpha: 1)
        case .auto:
            let c = (wallpaper ?? NSColor(calibratedHue: 0.62, saturation: 0.3, brightness: 0.8, alpha: 1)).usingColorSpace(.sRGB) ?? .white
            return NSColor(calibratedHue: c.hueComponent, saturation: min(1, max(0.12, c.saturationComponent) * (0.4 + 0.9 * t)),
                           brightness: 1 - 0.18 * t, alpha: 1)
        default:
            return NSColor(calibratedHue: swatch.hue ?? 0, saturation: 0.14 + 0.66 * t, brightness: 1 - 0.12 * t, alpha: 1)
        }
    }
    /// 玻璃要染多少色（0 = 不染）：白色不染，顏色越濃染越多
    var glassTint: CGFloat { swatch == .white ? 0 : CGFloat(0.12 + 0.30 * max(0, min(1, tone))) }
}

extension GlyphShape {
    /// 錶面大時間的字形：能長高的字體走 adaptive（HGHT 二分），其他的照原比例縮進 height × maxWidth
    static func clock(_ s: String, look: ClockLook, height h: CGFloat, maxWidth: CGFloat, at p: CGPoint, anchorX: CGFloat,
                      weightBoost: Double = 0) -> GlyphShape {
        let w = look.font.weight(look.weight + weightBoost)
        switch look.font {
        case .sf: return adaptive(s, height: h, maxWidth: maxWidth, at: p, anchorX: anchorX, weight: w)
        case .soft: return adaptive(s, height: h, maxWidth: maxWidth, at: p, anchorX: anchorX, weight: w, soft: 100)
        case .newYork: return adaptive(s, height: h, maxWidth: maxWidth, at: p, anchorX: anchorX, weight: w, family: .newYork)
        default:
            let g = GlyphShape(s, font: look.font.nsFont(200, weight: look.weight + weightBoost), kern: 0), b = g.ink
            guard b.width > 0, b.height > 0 else { return g }
            let k = min(h / b.height, maxWidth / b.width)
            // 不夠高時偏上放（下面是島），數字不會黏在上緣
            let dy = (h - b.height * k) * 0.2
            let t = CGAffineTransform(translationX: p.x - b.width * k * anchorX, y: p.y + dy)
                .scaledBy(x: k, y: k).translatedBy(x: -b.minX, y: -b.minY)
            return g.transformed(t)
        }
    }
}

extension Face {
    /// 照「字體與顏色」畫一組大時間：玻璃（系統 Liquid Glass，可染色）或實線
    func drawClockDigits(_ g: CGContext, _ shapes: [GlyphShape], look: ClockLook, clear: CGImage?, frosted: CGImage?, alpha: CGFloat) {
        let color = look.color(wallpaper: wallpaperTone(frosted))
        g.saveGState(); g.setAlpha(alpha)
        if look.glass {
            var sys = SystemGlassParams.portrait
            sys.tint = look.glassTint > 0 ? color.withAlphaComponent(look.glassTint).cgColor : nil
            drawLiquidGlass(g, shapes, clear: clear, frosted: frosted, system: sys)
        } else {
            for s in shapes { fillShape(g, s, color, shadow: 0.18) }
        }
        g.restoreGState()
    }

    /// 壁紙的平均色（給「跟隨壁紙」用）：模糊背景縮成 1×1
    func wallpaperTone(_ img: CGImage?) -> NSColor? {
        guard let img else { return nil }
        if let c = Self.toneCache, c.id == ObjectIdentifier(img) { return c.color }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let c = NSColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        Self.toneCache = (ObjectIdentifier(img), c)
        return c
    }
    nonisolated(unsafe) private static var toneCache: (id: ObjectIdentifier, color: NSColor)?
}

// MARK: - 面板

final class ClockLookModel: ObservableObject {
    @Published var look = ClockLook.current {
        didSet { if look != oldValue { ClockLook.current = look; onChange?() } }
    }
    var onChange: (() -> Void)?
    /// 「跟隨壁紙」色票的樣子
    var wallpaper: NSColor?
}

struct ClockLookView: View {
    @ObservedObject var m: ClockLookModel

    var body: some View {
        VStack(spacing: 0) {
            // 字體：一排「12」，選中的有一圈圓角框
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ClockLook.Font.allCases, id: \.self) { f in
                        Button { m.look.font = f } label: {
                            Text("12")
                                .font(Font(f.previewFont(36, weight: m.look.weight)))
                                .frame(width: 72, height: 58)
                                .background {
                                    if m.look.font == f {
                                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.10))
                                        RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 1.5)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(f.title)
                        .accessibilityLabel(f.title)
                        .accessibilityAddTraits(m.look.font == f ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 10)
            Slider(value: $m.look.weight, in: 0...1)
                .controlSize(.small)
                .padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 16)
                .accessibilityLabel(L("clockLook.weight", "粗细"))

            Divider().padding(.horizontal, 16)

            // 顏色：第一個跟隨壁紙，選中的外面一圈白環
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(ClockLook.Swatch.allCases, id: \.self) { s in
                        Button { m.look.swatch = s } label: {
                            swatchDot(s)
                                .frame(width: 34, height: 34)
                                .padding(4)
                                .overlay { if m.look.swatch == s { Circle().strokeBorder(.white, lineWidth: 2.5) } }
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(s.title)
                        .accessibilityLabel(s.title)
                        .accessibilityAddTraits(m.look.swatch == s ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 16)
            Slider(value: $m.look.tone, in: 0...1)
                .controlSize(.small)
                .tint(Color(nsColor: tonePreview(1)))
                .padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 16)
                .accessibilityLabel(L("clockLook.tone", "色调"))

            Picker("", selection: $m.look.glass) {
                Text(L("clockLook.glass", "玻璃")).tag(true)
                Text(L("clockLook.solid", "实线")).tag(false)
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 40).padding(.bottom, 18)
        }
        .frame(width: 360)
    }

    private func tonePreview(_ t: Double) -> NSColor {
        var l = m.look; l.tone = t
        return l.color(wallpaper: m.wallpaper)
    }

    @ViewBuilder private func swatchDot(_ s: ClockLook.Swatch) -> some View {
        var l = m.look
        let _ = (l.swatch = s, l.tone = 0.6)
        if s == .auto {
            Circle().fill(AngularGradient(colors: [Color(nsColor: l.color(wallpaper: m.wallpaper)), .white.opacity(0.7),
                                                   Color(nsColor: l.color(wallpaper: m.wallpaper))], center: .center))
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
        } else {
            Circle().fill(Color(nsColor: l.color(wallpaper: m.wallpaper)))
                .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 1))
        }
    }
}

/// 浮在桌寵旁邊的小面板：系統的玻璃底（macOS 26 起），標題列透明，關閉鈕在左上——像 iOS 編輯鎖定畫面，但是 Mac 的窗。
@MainActor final class ClockLookPanel {
    static let shared = ClockLookPanel()
    private var panel: NSPanel?
    let model = ClockLookModel()

    func show(near anchor: NSWindow?, wallpaper: NSColor?, onChange: @escaping () -> Void) {
        model.onChange = onChange
        model.wallpaper = wallpaper
        model.look = ClockLook.current
        let p = panel ?? make()
        panel = p
        if !p.isVisible, let a = anchor {
            // 放在桌寵左邊（左邊放不下就右邊），上緣對齊
            let f = a.frame, size = p.frame.size
            let vis = a.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? f
            var x = f.minX - size.width - 12
            if x < vis.minX { x = min(f.maxX + 12, vis.maxX - size.width) }
            let y = max(vis.minY, min(f.maxY - size.height, vis.maxY - size.height))
            p.setFrameOrigin(CGPoint(x: x, y: y))
        }
        p.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func make() -> NSPanel {
        let host = NSHostingView(rootView: ClockLookView(m: model).padding(.top, 28))
        host.frame.size = host.fittingSize
        let p = NSPanel(contentRect: CGRect(origin: .zero, size: host.fittingSize),
                        styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow], backing: .buffered, defer: false)
        p.title = L("clockLook.title", "字体与颜色")
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 26
            glass.contentView = host
            p.contentView = glass
        } else {
            let fx = NSVisualEffectView(); fx.material = .hudWindow; fx.blendingMode = .behindWindow; fx.state = .active
            fx.addSubview(host); host.frame = fx.bounds; host.autoresizingMask = [.width, .height]
            p.contentView = fx
        }
        p.appearance = NSAppearance(named: .darkAqua)   // 跟鎖定畫面一樣：深色玻璃、白字
        return p
    }
}
