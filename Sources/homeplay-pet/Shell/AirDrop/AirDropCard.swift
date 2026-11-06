// AirDrop 收到東西的卡片：疊在最上層（畫在 drawShellOverlays，錶面、主畫面、App 上都看得到），頂端藥丸底下滑出，幾秒後自己收、點卡片空白處收掉。
//   照片 → 縮圖＋「放進照片錶面」（複製進照片錶面看的資料夾，下載項目裡的原檔不動）；
//   連結（.webloc、.url、純文字網址）→「用 Safari 打開」；其他 → 「預覽」（Quick Look）與「在 Finder 顯示」。
// 訪客模式、認不出主人、遠端訪客在用：只顯示「收到一个文件」，不露檔名、縮圖與網址，也不給按鈕（PersonalGate）。
// 材質：Regular 玻璃（HPGlass materialize 淡入；減少動態效果時不滑動）；按鈕用填色不再疊玻璃；增加對比多一圈描邊。

import AppKit
import Quartz

enum AirDropCard {
    enum Act: Equatable { case addPhoto, openLink, preview, reveal, dismiss }

    /// 停留秒數；做完動作後的確認字停短一點
    static let lifetime: Double = 8, doneLifetime: Double = 2.5
    static let rect = CGRect(x: 64, y: 136, width: 896, height: 224)
    /// 圓角跟螢幕同心（左右離螢幕 64 → 138 − 64；EdgeContainers 登記、selftest 驗）
    static var radius: CGFloat { HPTokens.Radius.concentric(rect: rect) }
    /// 左邊縮圖貼著卡片左上角（內距 32）：半徑＝卡片實際畫出的半徑 − 32
    static var thumbRadius: CGFloat { HPTokens.Radius.concentric(parent: HPTokens.Radius.drawn(radius, in: rect), padding: 32) }

    nonisolated(unsafe) static var queue: [AirDropItem] = []   // 第一個是正在顯示（或正在收起）的
    nonisolated(unsafe) static var shown = false
    nonisolated(unsafe) static var since = 0.0
    nonisolated(unsafe) static var done: String?
    nonisolated(unsafe) static var hits: [(CGRect, Act)] = []
    nonisolated(unsafe) static var pressed = false   // 滑鼠按在卡片上（ShellInput）
    nonisolated(unsafe) static var thumbCache: (url: URL, image: CGImage?)?
    /// 示範／自檢：指定當成訪客（nil＝照 PersonalGate）
    nonisolated(unsafe) static var redactedOverride: Bool?

    static var current: AirDropItem? { queue.first }
    static var redacted: Bool { redactedOverride ?? !PersonalGate.allowed(PersonalGate.inputs) }
    static func presence(_ now: Double = CACurrentMediaTime()) -> CGFloat { HPPresence.value("airdrop.card", shown: shown, HPMotion.T.sheet, now: now) }
    static var visible: Bool { current != nil && (shown || presence() > 0.001) }

    // MARK: 規則（純函數，selftest 驗）

    /// 這個種類有哪些動作鈕（照規格：照片 1 顆、連結 1 顆、其他 2 顆；訪客不給）
    static func actions(_ kind: AirDropKind, redacted: Bool) -> [Act] {
        if redacted { return [] }
        switch kind {
        case .photo: return [.addPhoto]
        case .link: return [.openLink]
        case .other: return [.preview, .reveal]
        }
    }
    static func title(_ item: AirDropItem, redacted: Bool) -> String {
        if redacted { return L("airdrop.guest.title", "收到一个文件") }
        if item.kind == .link, let h = item.link?.host { return h }
        return item.name
    }
    static func subtitle(_ item: AirDropItem, redacted: Bool) -> String {
        if redacted { return L("airdrop.guest.sub", "来自 AirDrop") }
        switch item.kind {
        case .photo: return L("airdrop.sub.photo", "AirDrop · 照片")
        case .link: return L("airdrop.sub.link", "AirDrop · 链接")
        case .other: return L("airdrop.sub.file", "AirDrop · 文件")
        }
    }
    static func label(_ a: Act) -> String {
        switch a {
        case .addPhoto: return L("airdrop.act.addPhoto", "放进照片表盘")
        case .openLink: return L("airdrop.act.openLink", "用 Safari 打开")
        case .preview: return L("airdrop.act.preview", "预览")
        case .reveal: return L("airdrop.act.reveal", "在访达中显示")
        case .dismiss: return L("airdrop.act.dismiss", "关闭")
        }
    }
    static func symbol(_ a: Act) -> String {
        switch a {
        case .addPhoto: return "photo.on.rectangle"
        case .openLink: return "safari"
        case .preview: return "eye"
        case .reveal: return "folder"
        case .dismiss: return "xmark"
        }
    }

    // MARK: 狀態

    static func receive(_ item: AirDropItem, now: Double) {
        queue.append(item)
        if queue.count == 1 { present(now) }
    }
    private static func present(_ now: Double) {
        shown = true; since = now; done = nil; hits = []
    }
    static func dismiss() { shown = false }
    static func clear() { queue = []; shown = false; done = nil; hits = []; thumbCache = nil }

    /// 每幀：逾時自己收、收完換下一張；回 true＝要重畫
    static func tick(_ now: Double) -> Bool {
        guard !queue.isEmpty else { return false }
        if shown, now - since > (done == nil ? lifetime : doneLifetime) { shown = false }
        let p = presence(now)
        if !shown, p <= 0.001 {
            queue.removeFirst(); thumbCache = nil; hits = []
            if !queue.isEmpty { present(now) }
        }
        return true
    }

    // MARK: 做事

    /// 複製到照片錶面的資料夾；回新檔的路徑（失敗回 nil）。fm／folder 可注入（自檢用暫存資料夾）
    @discardableResult
    static func addToPhotoFace(_ src: URL, folder: URL, fm: FileManager = .default) -> URL? {
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = AirDropRules.uniqueName(src.lastPathComponent) { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
            let dst = folder.appendingPathComponent(name)
            try fm.copyItem(at: src, to: dst)
            return dst
        } catch { return nil }
    }

    // MARK: 畫

    static func thumb(_ item: AirDropItem) -> CGImage? {
        if let c = thumbCache, c.url == item.url { return c.image }
        var img: CGImage?
        if item.kind == .photo, let src = CGImageSourceCreateWithURL(item.url as CFURL, nil) {
            img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                              kCGImageSourceThumbnailMaxPixelSize: 360,
                                                              kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        }
        thumbCache = (item.url, img)
        return img
    }
}

extension Face {
    /// 疊在最上層（drawShellOverlays 叫）
    func drawAirDropCard(_ g: CGContext, _ now: Double) {
        typealias C = AirDropCard
        guard let item = C.current else { C.hits = []; return }
        let p = C.presence(now)
        guard p > 0.001 else { C.hits = []; return }
        let red = C.redacted
        let slide: CGFloat = HPMotion.reduceMotion ? 0 : -(1 - p) * 48
        let r = C.rect.offsetBy(dx: 0, dy: slide)
        let path = continuousRoundedRect(r, radius: C.radius)
        let acts = C.actions(item.kind, redacted: red)
        var hits: [(CGRect, C.Act)] = []
        let title = C.title(item, redacted: red), sub = C.done ?? C.subtitle(item, redacted: red)
        let thumb = red ? nil : C.thumb(item)
        let icon: CGImage? = (red || item.kind != .other) ? nil : AirDropCardIcon.image(item.url)
        HPAX.note(g, r, .button, "\(title), \(sub)", shape: .rounded(C.radius))
        // 版面先在這裡排好（玻璃的內容延到幀尾才畫，命中區不能等它）
        let t = CGRect(x: r.minX + 32, y: r.minY + 32, width: 160, height: 160)
        let x = t.maxX + 32, w = r.maxX - 32 - x
        let bf = HPComponents.sf(28, weight: .medium)
        var buttons: [(CGRect, C.Act)] = []
        if C.done == nil {
            var bx = x
            for a in acts {
                let bw = min(w, Typo.width(C.label(a), bf) + 56 + 40)
                if bx + bw > r.maxX - 32 + 1 { break }
                let b = CGRect(x: bx, y: r.minY + 136, width: bw, height: 64)
                buttons.append((b, a)); hits.append((b.insetBy(dx: -8, dy: -8), a))
                HPAX.note(g, b, .button, C.label(a))
                bx = b.maxX + 16
            }
        }
        HPGlass.drawNowItems(g, face: self) {
            HPGlass.add(path, tint: nil, interactive: false, union: nil, presence: p) { [weak self] c in
                guard let self else { return }
                let ink = HPGlass.ink
                if HPAccessibility.increaseContrast {
                    c.addPath(path); c.setLineWidth(3); c.setStrokeColor(ink.withAlphaComponent(0.55).cgColor); c.strokePath()
                }
                // 左：縮圖／圖示（160 方塊，圓角跟卡片同心）
                let tp = continuousRoundedRect(t, radius: C.thumbRadius)
                c.saveGState(); c.addPath(tp); c.clip()
                if let thumb { MediaUI.drawCover(c, face: self, thumb, in: t) }
                else if let icon { self.drawUpright(c, icon, in: t.insetBy(dx: 16, dy: 16)) }
                else {
                    let tint: NSColor = red ? HPTokens.blue : (item.kind == .link ? HPTokens.teal : HPTokens.fill)
                    c.setFillColor(tint.cgColor); c.fill(t)
                    let sym = red ? AirDropShare.symbol : (item.kind == .link ? "link" : "doc.fill")
                    self.drawSymbol(c, sym, in: t.insetBy(dx: 44, dy: 44), color: red || item.kind == .link ? .white : ink, weight: .medium)
                }
                c.restoreGState()
                // 右：標題、說明、動作
                let tf = HPComponents.sf(36, weight: .semibold), sf = HPComponents.sf(28, weight: .regular)
                self.drawLeft(c, Face.clippedMiddle(title, tf, w), font: tf, x: x, y: r.minY + 68, color: ink)
                if C.done != nil {
                    self.drawSymbol(c, "checkmark.circle.fill", in: CGRect(x: x, y: r.minY + 100, width: 36, height: 36), color: HPTokens.green)
                    self.drawLeft(c, Face.clipped(sub, sf, w - 48), font: sf, x: x + 48, y: r.minY + 130, color: ink.withAlphaComponent(0.7))
                } else {
                    self.drawLeft(c, Face.clipped(sub, sf, w), font: sf, x: x, y: r.minY + 108, color: ink.withAlphaComponent(0.7))
                }
                for (b, a) in buttons {
                    c.addPath(HPComponents.capsulePath(b)); c.setFillColor(HPTokens.blue.cgColor); c.fillPath()
                    self.drawSymbol(c, C.symbol(a), in: CGRect(x: b.minX + 24, y: b.midY - 16, width: 32, height: 32), color: .white, weight: .semibold)
                    self.drawLeft(c, C.label(a), font: bf, x: b.minX + 24 + 32 + 8, y: b.midY + bf.capHeight / 2, color: .white)
                }
            }
        }
        hits.append((r, .dismiss))   // 空白處＝收掉（按鈕先比）
        C.hits = p > 0.9 && C.shown ? hits : []
    }
}

/// 檔案圖示（NSWorkspace）的快取：一次一張
enum AirDropCardIcon {
    nonisolated(unsafe) private static var cache: (URL, CGImage?)?
    static func image(_ url: URL) -> CGImage? {
        if let c = cache, c.0 == url { return c.1 }
        let ns = NSWorkspace.shared.icon(forFile: url.path)
        var r = CGRect(x: 0, y: 0, width: 256, height: 256)
        let img = ns.cgImage(forProposedRect: &r, context: nil, hints: nil)
        cache = (url, img)
        return img
    }
}

// MARK: 點按與 Quick Look

extension PetView {
    /// 卡片在時，按在卡片上就由它吃（回 true）；按下與放開都走這裡的命中判斷
    func airDropCardContains(_ uv: CGPoint?) -> Bool {
        if carPlayAirDropCardContains(uv) { return true }   // CarPlay 連著時的卡（AirDropCarPlayCard.swift）貼在下緣，一起走這條路
        guard let uv, AirDropCard.shown, !AirDropCard.hits.isEmpty else { return false }
        return AirDropCard.rect.insetBy(dx: -8, dy: -8).contains(CGPoint(x: uv.x * 1024, y: uv.y * 1024))
    }

    func airDropCardTap(_ uv: CGPoint?) {
        if carPlayAirDropCardContains(uv) { carPlayAirDropCardTap(uv); return }
        guard let uv else { return }
        let p = CGPoint(x: uv.x * 1024, y: uv.y * 1024)
        guard let act = AirDropCard.hits.first(where: { $0.0.contains(p) })?.1, let item = AirDropCard.current else { return }
        airDropPerform(act, item)
        face.forceDirty = true
    }

    func airDropPerform(_ act: AirDropCard.Act, _ item: AirDropItem) {
        typealias C = AirDropCard
        switch act {
        case .dismiss: C.dismiss()
        case .addPhoto:
            if C.addToPhotoFace(item.url, folder: face.photos.folder) != nil {
                face.photos.rescanSoon()
                C.done = L("airdrop.done.photo", "已放进照片表盘"); C.since = CACurrentMediaTime()
            } else { C.done = L("airdrop.fail.photo", "没能放进照片表盘"); C.since = CACurrentMediaTime() }
        case .openLink:
            if let u = item.link {
                SafariApp.shared.open(u)
                shellOpenApp("safari")
            }
            C.dismiss()
        case .preview:
            AirDropPreview.show(item.url)
            C.dismiss()
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
            C.dismiss()
        }
    }
}

/// Quick Look 預覽面板（公開的 QLPreviewPanel；資料來源直接指定，不走回應鏈）
final class AirDropPreview: NSObject, QLPreviewPanelDataSource {
    nonisolated(unsafe) private static var current: AirDropPreview?
    private let url: URL
    private init(_ url: URL) { self.url = url }

    static func show(_ url: URL) {
        let s = AirDropPreview(url)
        current = s
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = s
        panel.reloadData()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { url as NSURL }
}
