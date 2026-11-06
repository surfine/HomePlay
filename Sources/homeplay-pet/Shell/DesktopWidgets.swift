// 主畫面的「桌面小工具」：擷取 Mac 桌面上系統畫好的小工具（含從 iPhone 加到 Mac 的），放進一格小工具。
// 拍板：寄宿別的 App 的小工具第三方做不到，所以不做山寨版，直接拍系統畫好的那幾個視窗（ScreenCaptureKit，要螢幕錄製權限）。
//
// - 找視窗：通知中心（com.apple.notificationcenterui）擁有、層級在桌面那一帶（比一般視窗低）、大小像小工具的視窗；
//   視窗標題是小工具的名字。2026-11-06 本機實測：small 180×180 pt、medium 360×180 pt，層級 -2147483601。
// - macOS 在桌面被視窗擋住時把桌面小工具畫成單色（淡灰）；擷取到的就是當下畫面上的樣子，所以平常拍到的多半是單色版。
// - 只在這一格畫在畫面上時才拍：每 15 秒一次、最多 4 個；30 秒沒畫就停。
// - 點：照點到的那一個小工具的名字推對應的 Mac App（App 的在地名稱、常見小工具名稱）；推不出就打開「桌面」資料夾。
// - 沒權限：畫說明＋「打開設置」，點了先請系統問一次，再打開「隱私權與安全性 › 螢幕錄製」。
// - 快照（SnapshotPrivacy）、--demo-desktop-widgets ok|denied|none：用畫出來的假小工具，不拍真的螢幕。
// - --probe-desktop-widgets [--probe-out 資料夾]：印出找到的視窗（擁有者、大小、層級）就結束；有權限時順便拍下來量飽和度。

import AppKit
import ScreenCaptureKit

struct DesktopWidgetWindow: Equatable {
    var id: UInt32
    var title: String
    var frame: CGRect          // 螢幕 pt
    var layer: Int
}

enum DesktopWidgets {
    static let ownerBundle = "com.apple.notificationcenterui"

    /// 這個視窗是不是桌面小工具（純函數，自檢直接驗）
    static func isWidget(bundle: String?, layer: Int, frame: CGRect) -> Bool {
        guard bundle == ownerBundle else { return false }
        // 桌面那一帶：比一般視窗（0）低、比桌布（kCGDesktopWindowLevel）高
        guard layer < 0, layer > Int(CGWindowLevelForKey(.desktopWindow)) else { return false }
        return frame.width >= 100 && frame.height >= 100 && frame.width <= 900 && frame.height <= 900
    }

    /// 擷取到的幾個小工具在這一格裡怎麼排：照桌面上的相對位置縮放後置中（保持原本的排列，看起來就是「我的桌面」）
    static func layout(_ frames: [CGRect], in box: CGRect) -> [CGRect] {
        guard let first = frames.first else { return [] }
        let u = frames.dropFirst().reduce(first) { $0.union($1) }
        guard u.width > 0, u.height > 0 else { return frames.map { _ in .zero } }
        let k = min(box.width / u.width, box.height / u.height)
        let ox = box.midX - u.width * k / 2, oy = box.midY - u.height * k / 2
        return frames.map { CGRect(x: ox + ($0.minX - u.minX) * k, y: oy + ($0.minY - u.minY) * k, width: $0.width * k, height: $0.height * k) }
    }

    /// 常見小工具名稱 → App（三語；比對用詞，不是介面文字）
    static let aliases: [(words: [String], bundle: String?)] = [
        (["Calendar", "Up Next", "日历", "月历", "行事曆", "月曆", "下一個", "下一个"], "com.apple.iCal"),   // l10n-ignore
        (["Weather", "Sunrise", "天气", "天氣", "日出日落"], "com.apple.weather"),   // l10n-ignore
        (["Clock", "World Clock", "时钟", "時鐘", "世界时钟", "世界時鐘"], "com.apple.clock"),   // l10n-ignore
        (["Reminders", "提醒事项", "提醒事項"], "com.apple.reminders"),   // l10n-ignore
        (["Photos", "照片"], "com.apple.Photos"),   // l10n-ignore
        (["Notes", "备忘录", "備忘錄"], "com.apple.Notes"),   // l10n-ignore
        (["Stocks", "股市"], "com.apple.stocks"),   // l10n-ignore
        (["Find My", "查找", "尋找"], "com.apple.findmy"),   // l10n-ignore
        (["Home", "家庭"], "com.apple.Home"),   // l10n-ignore
        (["Podcasts", "播客", "Podcast"], "com.apple.podcasts"),   // l10n-ignore
        (["Music", "音乐", "音樂"], "com.apple.Music"),   // l10n-ignore
        (["Screen Time", "屏幕使用时间", "螢幕使用時間"], "com.apple.ScreenTimeAgent"),   // l10n-ignore
        (["Batteries", "电池", "電池", "狀態", "状态"], nil),   // 電池沒有 App   // l10n-ignore
    ]

    /// 小工具名字 → 要開的 App（bundle id）。apps：這台 Mac 上 App 的在地名稱 → bundle id。
    /// 先比 App 名字（完全一樣，再來包含），再查常見名稱；都沒有回 nil（＝打開桌面）
    static func bundle(forTitle title: String, apps: [String: String]) -> String? {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if let b = apps[t] { return b }
        if let hit = apps.filter({ $0.key.count >= 2 && t.localizedCaseInsensitiveContains($0.key) }).max(by: { $0.key.count < $1.key.count }) { return hit.value }
        for a in aliases where a.words.contains(where: { t.localizedCaseInsensitiveContains($0) }) { return a.bundle }
        return nil
    }

    /// 這台 Mac 上的 App：在地名稱 → bundle id（第一次用到才掃）
    nonisolated(unsafe) private static var appIndex: [String: String]?
    static func installedApps() -> [String: String] {
        if let a = appIndex { return a }
        var out: [String: String] = [:]
        let fm = FileManager.default
        let dirs = ["/System/Applications", "/System/Applications/Utilities", "/Applications", fm.homeDirectoryForCurrentUser.path + "/Applications"]
        for d in dirs {
            for n in (try? fm.contentsOfDirectory(atPath: d)) ?? [] where n.hasSuffix(".app") {
                let p = d + "/" + n
                guard let b = Bundle(path: p)?.bundleIdentifier else { continue }
                let shown = (fm.displayName(atPath: p) as NSString).deletingPathExtension
                out[shown] = out[shown] ?? b
                out[(n as NSString).deletingPathExtension] = out[(n as NSString).deletingPathExtension] ?? b
            }
        }
        appIndex = out
        return out
    }

    /// 打開小工具對應的 App；推不出就打開「桌面」資料夾
    static func open(title: String) {
        if let b = bundle(forTitle: title, apps: installedApps()), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            log("desktop widgets: open app for widget")
            return
        }
        let desk = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Desktop")
        NSWorkspace.shared.open(desk)
        log("desktop widgets: no matching app, opened Desktop")
    }

    static func openPrivacySettings() {
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(u) }
    }

    /// 平均飽和度（0＝完全單色）：探測時看桌面小工具是不是被畫成單色
    static func meanSaturation(_ img: CGImage) -> Double {
        let w = 64, h = max(1, 64 * img.height / max(1, img.width))
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
        c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let d = c.data?.assumingMemoryBound(to: UInt8.self) else { return -1 }
        var s = 0.0, n = 0.0
        for i in 0..<(w * h) {
            let r = Double(d[i * 4]), g = Double(d[i * 4 + 1]), b = Double(d[i * 4 + 2]), a = Double(d[i * 4 + 3])
            guard a > 128 else { continue }
            let mx = max(r, g, b), mn = min(r, g, b)
            s += mx > 0 ? (mx - mn) / mx : 0; n += 1
        }
        return n > 0 ? s / n : -1
    }
}

// MARK: - 擷取

final class DesktopWidgetSource {
    static let shared = DesktopWidgetSource()

    enum State: Equatable { case unknown, denied, none, ok }
    private(set) var state: State = .unknown
    private(set) var shots: [(DesktopWidgetWindow, CGImage)] = []
    private var lastDrawn = 0.0, lastCapture = -1e9, busy = false
    private var onChange: (() -> Void)?
    private var timer: Timer?
    /// 上一次畫的時候每個小工具在這一格裡的框（點按用）
    var hitRects: [(CGRect, String)] = []

    static let demo: String? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--demo-desktop-widgets") else { return nil }
        return i + 1 < a.count && !a[i + 1].hasPrefix("--") ? a[i + 1] : "ok"
    }()

    /// 每次畫這一格時叫（主執行緒）
    func activate(_ changed: @escaping () -> Void) {
        onChange = changed
        lastDrawn = CACurrentMediaTime()
        if SnapshotPrivacy.active || Self.demo != nil {
            let d = Self.demo ?? "ok"
            state = d == "denied" ? .denied : d == "none" ? .none : .ok
            if state == .ok, shots.isEmpty { shots = DesktopWidgetDemo.shots() }
            return
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        }
        tick()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        if now - lastDrawn > 30 { timer?.invalidate(); timer = nil; return }   // 這一格不在畫面上了
        guard CGPreflightScreenCaptureAccess() else { set(.denied, []); return }
        guard !busy, now - lastCapture > 15 else { return }
        busy = true; lastCapture = now
        Task {
            let shots = await Self.capture(limit: 4)
            DispatchQueue.main.async { DesktopWidgetSource.shared.finish(shots) }
        }
    }

    private func finish(_ shots: [(DesktopWidgetWindow, CGImage)]) {
        busy = false
        set(shots.isEmpty ? .none : .ok, shots)
    }

    private func set(_ s: State, _ list: [(DesktopWidgetWindow, CGImage)]) {
        let changed = s != state || list.count != shots.count || zip(list, shots).contains { $0.0.0 != $0.1.0 } || s == .ok
        state = s; shots = list
        if changed { onChange?() }
    }

    /// 找桌面小工具的視窗並各拍一張（背景）
    static func capture(limit: Int) async -> [(DesktopWidgetWindow, CGImage)] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return [] }
        var out: [(DesktopWidgetWindow, CGImage)] = []
        for w in content.windows where DesktopWidgets.isWidget(bundle: w.owningApplication?.bundleIdentifier, layer: w.windowLayer, frame: w.frame) {
            guard out.count < limit else { break }
            let f = SCContentFilter(desktopIndependentWindow: w)
            let cfg = SCStreamConfiguration()
            cfg.width = Int(w.frame.width * 2); cfg.height = Int(w.frame.height * 2)
            cfg.showsCursor = false; cfg.ignoreShadowsSingleWindow = true
            guard let img = try? await SCScreenshotManager.captureImage(contentFilter: f, configuration: cfg) else { continue }
            out.append((DesktopWidgetWindow(id: w.windowID, title: w.title ?? "", frame: w.frame, layer: w.windowLayer), img))
        }
        // 照桌面上的閱讀順序（上到下、左到右）
        return out.sorted { ($0.0.frame.minY, $0.0.frame.minX) < ($1.0.frame.minY, $1.0.frame.minX) }
    }

    /// 點這一格：沒權限＝去設定；點到某個小工具＝開它的 App；點空白＝開桌面
    func tap(_ p: CGPoint, in r: CGRect) {
        switch state {
        case .denied: if !SnapshotPrivacy.active { DesktopWidgets.openPrivacySettings() }
        case .ok:
            guard !SnapshotPrivacy.active, Self.demo == nil else { return }
            DesktopWidgets.open(title: hitRects.first { $0.0.contains(p) }?.1 ?? "")
        default:
            guard !SnapshotPrivacy.active, Self.demo == nil else { return }
            DesktopWidgets.open(title: "")
        }
    }
}

// MARK: - 畫

extension Face {
    func drawDesktopWidgets(_ g: CGContext, _ w: SBWidget, _ r: CGRect, _ a: HomeAppearance, _ preview: Bool) {
        let src = DesktopWidgetSource.shared
        if !preview { src.activate { [weak self] in self?.forceDirty = true } }
        let mode = a.renderMode(night: false)
        // 底：照系統小工具的深底（擷取到的多半是單色的淡灰小工具，深底上讀得清楚）
        let bg = srgb(0x1C1C1E)
        HPComponents.widgetFrame(g, r, top: bg.cgColor, bottom: bg.cgColor, mode: mode, appearance: a == .light ? .dark : a, standalone: preview, radius: Shell.widgetRadius)
        let ink: NSColor = mode == .accented ? WidgetInk.of(a).primary : .white
        let sec = ink.withAlphaComponent(0.6)
        let p = SBK.pad, K = SBK.K
        let shots = preview ? DesktopWidgetDemo.shots() : src.shots
        let state: DesktopWidgetSource.State = preview ? .ok : src.state
        func message(_ symbol: String, _ title: String, _ body: String, button: String?) {
            drawSymbol(g, symbol, in: CGRect(x: r.minX + p, y: r.minY + p, width: 20 * K, height: 20 * K), color: sec)
            let tf = HPType.sf(14 * K, .semibold), bf = HPType.sf(12 * K, .regular)
            var y = r.minY + p + 24 * K + tf.ascender
            drawLeft(g, Face.clipped(title, tf, r.width - 2 * p), font: tf, x: r.minX + p, y: y, color: ink)
            y += tf.ascender - tf.descender + 4
            let lines = Face.photosWrap(body, bf, r.width - 2 * p, maxLines: r.height > 300 ? 4 : 2)
            for l in lines { drawLeft(g, Face.clipped(l, bf, r.width - 2 * p), font: bf, x: r.minX + p, y: y, color: sec); y += bf.ascender - bf.descender + 2 }
            if let button {
                let f = HPType.sf(13 * K, .semibold), bw = Typo.width(button, f) + 28 * K, bh = 30 * K
                let br = CGRect(x: r.minX + p, y: r.maxY - p - bh, width: min(bw, r.width - 2 * p), height: bh)
                AppUI.fillPill(g, br, color: HPTokens.blue)
                drawLeft(g, Face.clipped(button, f, br.width - 20 * K), font: f, x: br.minX + 14 * K, y: br.midY + f.capHeight / 2, color: .white)
            }
            HPAX.note(g, r, .button, title, value: body)
        }
        switch state {
        case .denied:
            message("record.circle", w.kind.title, L("dw.denied", "需要“屏幕录制”权限，才能显示 Mac 桌面上的小组件。"), button: L("dw.openSettings", "打开设置"))
        case .none, .unknown:
            message("widget.small", w.kind.title, state == .unknown ? L("dw.loading", "正在查找桌面上的小组件…")
                    : L("dw.none", "Mac 桌面上还没有小组件。按住 Control 点按桌面，选“编辑小组件”添加。"), button: nil)
        case .ok:
            let box = r.insetBy(dx: p * 0.6, dy: p * 0.6)
            let rects = DesktopWidgets.layout(shots.map(\.0.frame), in: box)
            src.hitRects = []
            g.saveGState(); g.interpolationQuality = .high
            for ((win, img), wr) in zip(shots, rects) {
                g.saveGState()
                g.addPath(continuousRoundedRect(wr, radius: min(wr.width, wr.height) * 0.12)); g.clip()
                drawUpright(g, img, in: wr)
                g.restoreGState()
                if !preview { src.hitRects.append((wr, win.title)) }
                HPAX.note(g, wr, .button, win.title.isEmpty ? w.kind.title : win.title)
            }
            g.restoreGState()
        }
    }
}

// MARK: - 快照用的假小工具（單色，跟桌面被擋住時的樣子一樣）

enum DesktopWidgetDemo {
    nonisolated(unsafe) private static var cache: [(DesktopWidgetWindow, CGImage)]?
    static func shots() -> [(DesktopWidgetWindow, CGImage)] {
        if let c = cache { return c }
        let ink = CGColor(gray: 0.82, alpha: 1), dim = CGColor(gray: 0.45, alpha: 1), bg = CGColor(gray: 0.12, alpha: 1)
        func tile(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
            makeImage(w, h) { g in
                g.addPath(continuousRoundedRect(CGRect(x: 0, y: 0, width: w, height: h), radius: 44)); g.setFillColor(bg); g.fillPath()
                draw(g)
            }
        }
        // 日曆：大日期＋幾條行程條
        let cal = tile(360, 360) { g in
            g.setFillColor(ink); g.fill(CGRect(x: 36, y: 40, width: 120, height: 18))
            g.fill(CGRect(x: 36, y: 76, width: 160, height: 72))
            g.setFillColor(dim)
            for i in 0..<3 { g.fill(CGRect(x: 36, y: 200 + CGFloat(i) * 40, width: 260 - CGFloat(i) * 50, height: 18)) }
        }
        // 電池：三個圓環
        let bat = tile(720, 360) { g in
            for i in 0..<3 {
                let c = CGPoint(x: 120 + CGFloat(i) * 160, y: 150)
                g.setLineWidth(14); g.setStrokeColor(dim); g.strokeEllipse(in: CGRect(x: c.x - 60, y: c.y - 60, width: 120, height: 120))
                g.setStrokeColor(ink); g.addArc(center: c, radius: 60, startAngle: -.pi / 2, endAngle: -.pi / 2 + .pi * 2 * CGFloat(0.95 - Double(i) * 0.2), clockwise: false); g.strokePath()
                g.setFillColor(ink); g.fill(CGRect(x: c.x - 40, y: 250, width: 80, height: 22))
            }
        }
        let list = [(DesktopWidgetWindow(id: 1, title: "Calendar", frame: CGRect(x: 8, y: 42, width: 180, height: 180), layer: -2147483601), cal),
                    (DesktopWidgetWindow(id: 2, title: "Batteries", frame: CGRect(x: 8, y: 222, width: 360, height: 180), layer: -2147483601), bat)]
        cache = list
        return list
    }
}

// MARK: - 探測（--probe-desktop-widgets）

enum DesktopWidgetProbe {
    static func run() -> Never {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let allowed = CGPreflightScreenCaptureAccess()
        print("desktop-widgets probe: screen recording permission=\(allowed)")
        print("desktop-widgets probe: desktop level=\(CGWindowLevelForKey(.desktopWindow)) desktop icon level=\(CGWindowLevelForKey(.desktopIconWindow))")
        var found = 0
        for w in list {
            let pid = w[kCGWindowOwnerPID as String] as? pid_t ?? 0
            let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let frame = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
            let hit = DesktopWidgets.isWidget(bundle: bundle, layer: layer, frame: frame)
            guard hit || bundle == DesktopWidgets.ownerBundle else { continue }
            if hit { found += 1 }
            print("  \(hit ? "WIDGET" : "other ") owner=\(owner) bundle=\(bundle ?? "-") size=\(Int(frame.width))x\(Int(frame.height)) at=\(Int(frame.minX)),\(Int(frame.minY)) layer=\(layer) title=\(w[kCGWindowName as String] as? String ?? "(needs permission)")")
        }
        print("desktop-widgets probe: \(found) widget window(s)")
        guard allowed, found > 0 else {
            if found == 0 { print("desktop-widgets probe: none on the desktop (Control-click the desktop › Edit Widgets to add some)") }
            exit(0)
        }
        let out = arg("--probe-out")
        let sem = DispatchSemaphore(value: 0)
        Task {
            let shots = await DesktopWidgetSource.capture(limit: 8)
            for (w, img) in shots {
                print(String(format: "  captured \(w.id) \(img.width)x\(img.height)px saturation=%.4f", DesktopWidgets.meanSaturation(img)))
                if let out {
                    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
                    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + "/desktop-widget-\(w.id).png"))
                }
            }
            print("desktop-widgets probe: frontmost app=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-") (widgets turn monochrome while other windows cover the desktop)")
            sem.signal()
        }
        sem.wait()
        exit(0)
    }
}
