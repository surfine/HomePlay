// 2.0 第六輪（使用者決定 #1）：主畫面右上 2×2 的「照片」小工具，照官方主畫面（home-screen-erica：一張照片鋪滿到圓角，沒有字，底下標籤「照片」）。
// 照片從使用者自己的「照片」圖庫挑（PhotoKit）：去年以前的今天（回憶）＞喜好項目＞最近的照片，截圖不算；每小時換一張，點一下換下一張。
// 只在本機：不連網（isNetworkAccessAllowed = false，iCloud 上還沒下載的那張就跳過）、不存檔、不寫日誌，只留在記憶體裡。
// 圖庫是主人的個人內容：訪客或認不出主人時只顯示「需要主人」，也不去讀（PersonalGate）。
// 權限走既有的權限卡（PermissionKind.photos → AppDelegate.withPermission）；沒授權時小工具本身是一張請求卡，點了才出權限卡。
// 快照（--screen-png／--snapshot）一律不讀圖庫：--demo-official 用我們自己畫的示範照片，其他照真的授權狀態畫請求卡（不會有私人照片落到磁碟）。
// --photos-card request|denied|empty 快照指定小工具的那一種；--photos-probe 只印筆數（驗證 PhotoKit 這條路，不出圖）。

import AppKit
import CoreImage
import Photos

// MARK: - 純邏輯（--selftest 直接驗）

struct PhotoCandidate: Equatable {
    var id: String
    var created: Date?
    var favorite: Bool
    var screenshot: Bool
}

enum PhotoPick {
    /// 精選：去年以前的今天（回憶，年份新的先）→ 喜好項目 → 最近的；截圖不算；最多 limit 張
    static func featured(_ all: [PhotoCandidate], now: Date, calendar: Calendar = .current, limit: Int = 60) -> [PhotoCandidate] {
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        var seen = Set<String>(), out: [PhotoCandidate] = []
        func add(_ xs: [PhotoCandidate]) { for x in xs where !seen.contains(x.id) && out.count < limit { seen.insert(x.id); out.append(x) } }
        let usable = all.filter { !$0.screenshot }
        let newest: (PhotoCandidate, PhotoCandidate) -> Bool = { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
        let onThisDay = usable.filter {
            guard let d = $0.created else { return false }
            let c = calendar.dateComponents([.year, .month, .day], from: d)
            return c.month == today.month && c.day == today.day && (c.year ?? 0) < (today.year ?? 0)
        }
        add(onThisDay.sorted(by: newest))
        add(usable.filter(\.favorite).sorted(by: newest))
        add(usable.sorted(by: newest))
        return out
    }
    /// 現在顯示第幾張：每小時換一張（一天換幾次，跟 iOS 的精選照片一樣），點過幾下就往後幾張
    static func index(count: Int, now: Date, taps: Int) -> Int? {
        guard count > 0 else { return nil }
        let slot = Int(floor(now.timeIntervalSince1970 / 3600))
        return ((slot + taps) % count + count) % count
    }
    /// 小工具要畫哪一種
    enum Card: Equatable { case photo, request, denied, empty, loading, hidden }
    /// owner＝個人內容的門開著（PersonalGate）：圖庫是主人的個人內容，訪客與認不出的人只看到「需要主人」
    static func card(status: PermissionStatus, demo: Bool, hasImage: Bool, candidates: Int?, owner: Bool = true) -> Card {
        if demo { return .photo }
        if !owner && status == .granted { return .hidden }
        switch status {
        case .notDetermined: return .request
        case .denied: return .denied
        case .granted:
            if hasImage { return .photo }
            if let n = candidates, n == 0 { return .empty }
            return .loading
        }
    }

    static func selftest(_ check: (Bool, String) -> Void) {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
        func d(_ y: Int, _ m: Int, _ dd: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: dd, hour: 12))! }
        let now = d(2026, 10, 25)
        let xs = [PhotoCandidate(id: "recent", created: d(2026, 10, 20), favorite: false, screenshot: false),
                  PhotoCandidate(id: "shot", created: d(2025, 10, 25), favorite: true, screenshot: true),
                  PhotoCandidate(id: "fav", created: d(2024, 3, 1), favorite: true, screenshot: false),
                  PhotoCandidate(id: "day2019", created: d(2019, 10, 25), favorite: false, screenshot: false),
                  PhotoCandidate(id: "day2023", created: d(2023, 10, 25), favorite: false, screenshot: false),
                  PhotoCandidate(id: "today", created: d(2026, 10, 25), favorite: false, screenshot: false)]
        let f = PhotoPick.featured(xs, now: now, calendar: cal).map(\.id)
        check(f == ["day2023", "day2019", "fav", "today", "recent"], "照片小工具：往年的今天＞喜好＞最近，截圖不算（\(f)）")
        check(PhotoPick.featured(xs, now: now, calendar: cal, limit: 2).count == 2, "照片小工具：最多幾張")
        let t0 = Date(timeIntervalSince1970: 3600 * 10)
        check(PhotoPick.index(count: 3, now: t0, taps: 0) == 1 && PhotoPick.index(count: 3, now: t0.addingTimeInterval(3600), taps: 0) == 2
              && PhotoPick.index(count: 3, now: t0, taps: 1) == 2 && PhotoPick.index(count: 0, now: t0, taps: 0) == nil,
              "照片小工具：每小時換一張、點一下換下一張")   // l10n-ignore：selftest 訊息
        check(PhotoPick.card(status: .notDetermined, demo: false, hasImage: false, candidates: nil) == .request
              && PhotoPick.card(status: .denied, demo: false, hasImage: false, candidates: nil) == .denied
              && PhotoPick.card(status: .granted, demo: false, hasImage: false, candidates: 0) == .empty
              && PhotoPick.card(status: .granted, demo: false, hasImage: false, candidates: 4) == .loading
              && PhotoPick.card(status: .granted, demo: false, hasImage: true, candidates: 4) == .photo
              && PhotoPick.card(status: .notDetermined, demo: true, hasImage: false, candidates: nil) == .photo
              && PhotoPick.card(status: .granted, demo: false, hasImage: true, candidates: 4, owner: false) == .hidden,
              "照片小工具：沒授權＝請求卡、拒絕＝去設定、沒照片＝空的、示範＝示範照片")   // l10n-ignore：selftest 訊息
        SharedAlbums.selftest(check)   // 2.0 P10：共享相簿（Shell/SharedAlbums.swift）
    }
}

// MARK: - PhotoKit（只在本機）

final class PhotosWidgetSource {
    static let shared = PhotosWidgetSource()
    static let usageKey = "NSPhotoLibraryUsageDescription"
    /// 沒有用途說明就去要權限，系統會讓進程直接崩掉：只在打包成 App 後才問（跟 CalendarSource 一樣）
    static var canRequest: Bool { Bundle.main.object(forInfoDictionaryKey: usageKey) != nil }
    /// 快照不讀圖庫（不讓私人照片落到磁碟）；--demo-official 用示範照片
    static var snapshotMode: Bool { Face.demoData }

    static var status: PermissionStatus {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    private(set) var image: CGImage?
    private(set) var candidates: [String]?
    private var shownKey: String?
    private var fetchedAt: Date?
    private var loading = false
    private var taps = 0
    var onChange: (() -> Void)?
    private let queue = DispatchQueue(label: "homeplay.photos", qos: .utility)

    /// 快照：--photos-card request|denied|empty 指定小工具畫哪一種（不管真的授權狀態）
    static let forcedCard: PhotoPick.Card? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--photos-card"), i + 1 < a.count else { return nil }
        return ["request": .request, "denied": .denied, "empty": .empty, "hidden": .hidden][a[i + 1]]
    }()

    /// 2.0：主人看全部；登記的家人只在勾了共享相簿時看到那幾本（個人圖庫仍只給主人）
    static var mayShow: Bool {
        switch PersonalGate.cachedAudience {
        case .owner: return true
        case .family: return !SharedAlbums.selected.isEmpty
        case .none: return false
        }
    }

    var card: PhotoPick.Card {
        if let f = Self.forcedCard { return f }
        return PhotoPick.card(status: Self.status, demo: OfficialDemo.on, hasImage: image != nil, candidates: candidates?.count, owner: Self.mayShow)
    }

    /// 每次畫小工具時叫：授權了就照時間挑一張（換小時、點過、圖庫換過才重讀）
    func activate(px: Int, now: Date = Date(), onChange: @escaping () -> Void) {
        self.onChange = onChange
        guard !Self.snapshotMode, Self.status == .granted, Self.mayShow, !loading else { return }   // 訪客：不讀主人的圖庫
        if candidates == nil || fetchedAt.map({ now.timeIntervalSince($0) > 3600 }) ?? true {
            loading = true
            queue.async { [weak self] in
                let ids = Self.fetchCandidates(now: now)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.loading = false; self.candidates = ids; self.fetchedAt = now
                    if ids.isEmpty { self.image = nil; self.shownKey = nil }
                    self.onChange?()
                }
            }
            return
        }
        guard let ids = candidates, let i = PhotoPick.index(count: ids.count, now: now, taps: taps) else { return }
        let key = "\(ids[i])|\(px)"
        guard key != shownKey else { return }
        shownKey = key
        loadImage(ids[i], px: px, key: key)
    }

    /// 點一下：換下一張（交叉淡化由下一幀直接換圖，跟官方小工具一樣不做動畫）
    func next() { taps += 1; onChange?() }

    /// 授權剛拿到：清掉重讀
    func reset() { candidates = nil; fetchedAt = nil; image = nil; shownKey = nil; onChange?() }

    private static func fetchCandidates(now: Date) -> [String] {
        let shared = SharedAlbums.selected   // 2.0 P10：勾了共享相簿就只從那幾本挑（Shell/SharedAlbums.swift）
        if !shared.isEmpty { return SharedAlbums.candidates(shared) }
        var all: [PhotoCandidate] = []
        func collect(_ r: PHFetchResult<PHAsset>) {
            r.enumerateObjects { a, _, _ in
                all.append(PhotoCandidate(id: a.localIdentifier, created: a.creationDate, favorite: a.isFavorite,
                                          screenshot: a.mediaSubtypes.contains(.photoScreenshot)))
            }
        }
        // 最近 400 張＋喜好 200 張＋往年的今天（最多 20 年）
        let recent = PHFetchOptions()
        recent.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        recent.fetchLimit = 400
        collect(PHAsset.fetchAssets(with: .image, options: recent))
        let fav = PHFetchOptions()
        fav.sortDescriptors = recent.sortDescriptors
        fav.predicate = NSPredicate(format: "favorite == YES")
        fav.fetchLimit = 200
        collect(PHAsset.fetchAssets(with: .image, options: fav))
        let cal = Calendar.current
        var ranges: [NSPredicate] = []
        for back in 1...20 {
            guard let d = cal.date(byAdding: .year, value: -back, to: cal.startOfDay(for: now)),
                  let e = cal.date(byAdding: .day, value: 1, to: d) else { continue }
            ranges.append(NSPredicate(format: "creationDate >= %@ AND creationDate < %@", d as NSDate, e as NSDate))
        }
        let day = PHFetchOptions()
        day.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: ranges)
        day.fetchLimit = 200
        collect(PHAsset.fetchAssets(with: .image, options: day))
        return PhotoPick.featured(all, now: now).map(\.id)
    }

    private func loadImage(_ id: String, px: Int, key: String) {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: SharedAlbums.assetOptions).firstObject else { return }   // 2.0 P10：共享相簿的也拿得到
        let o = PHImageRequestOptions()
        o.isNetworkAccessAllowed = false          // 只在本機：iCloud 上還沒下載的就跳過
        o.deliveryMode = .highQualityFormat
        o.resizeMode = .fast
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: px, height: px), contentMode: .aspectFill, options: o) { [weak self] img, _ in
            DispatchQueue.main.async {
                guard let self, self.shownKey == key else { return }
                var r = NSRect(origin: .zero, size: img?.size ?? .zero)
                if let cg = img?.cgImage(forProposedRect: &r, context: nil, hints: nil) {
                    self.image = cg
                } else if let ids = self.candidates, ids.count > 1 {
                    self.taps += 1                   // 這張拿不到（例如只在 iCloud）：換下一張
                }
                self.onChange?()
            }
        }
    }

    /// --photos-probe：只印筆數，不出圖、不印名字或日期
    static func probe() {
        print("photos status: \(status)")
        guard status == .granted else { return }
        let ids = fetchCandidates(now: Date())
        print("photos featured candidates: \(ids.count)")
        let shared = SharedAlbums.list()   // 2.0 P10：共享相簿也只印數字
        print("shared albums: \(shared.count), photos: \(shared.reduce(0) { $0 + $1.count })")
    }
}

// MARK: - 示範照片（我們自己畫的，不是任何真實照片）

enum PhotosDemoArt {
    nonisolated(unsafe) private static var cache: (px: Int, image: CGImage)?

    /// 傍晚的海邊：暖橘的天、低低的太陽、海面上一道光、左邊一片暗的岬角；加上底片顆粒與一點暗角，像一張手機照片
    static func image(px: Int) -> CGImage {
        if let c = cache, c.px == px { return c.image }
        let s = CGFloat(px) / 392
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r / 255, g / 255, b / 255, a])! }
        let img = makeImage(px, px) { g in
            g.scaleBy(x: s, y: s)
            let horizon: CGFloat = 236
            // 天空：上面淺杏、往地平線越來越橘
            let sky = CGGradient(colorsSpace: cs, colors: [c(246, 188, 128), c(240, 142, 72), c(222, 98, 36)] as CFArray, locations: [0, 0.6, 1])!
            g.drawLinearGradient(sky, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: horizon), options: [])
            // 太陽：一圈大光暈＋亮的圓
            let sun = CGPoint(x: 250, y: horizon - 34)
            let glow = CGGradient(colorsSpace: cs, colors: [c(255, 236, 190, 0.95), c(255, 190, 110, 0.45), c(255, 160, 80, 0)] as CFArray, locations: [0, 0.35, 1])!
            g.drawRadialGradient(glow, startCenter: sun, startRadius: 0, endCenter: sun, endRadius: 170, options: [])
            g.setFillColor(c(255, 244, 214)); g.fillEllipse(in: CGRect(x: sun.x - 22, y: sun.y - 22, width: 44, height: 44))
            // 幾道薄雲
            g.setFillColor(c(250, 170, 120, 0.35))
            for (x, y, w) in [(30.0, 62.0, 150.0), (190, 92, 170), (90, 128, 120)] as [(CGFloat, CGFloat, CGFloat)] {
                g.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: 7), cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)); g.fillPath()
            }
            // 海：地平線那裡橘紫，往下變深
            let sea = CGGradient(colorsSpace: cs, colors: [c(196, 86, 44), c(120, 52, 40), c(58, 30, 34)] as CFArray, locations: [0, 0.45, 1])!
            g.drawLinearGradient(sea, start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: 392), options: [])
            // 海面上的光：一條條斷斷續續的亮線，越近越寬
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
            for i in 0..<46 {
                let t = CGFloat(i) / 46, y = horizon + 3 + t * t * 150
                let w = 14 + t * 110 * (0.5 + rnd())
                let x = sun.x - w / 2 + (rnd() - 0.5) * 30 * (0.3 + t)
                g.setFillColor(c(255, 214, 150, 0.55 * (1 - t) + 0.12))
                g.fill(CGRect(x: x, y: y, width: w, height: 1.6 + t * 2.4))
            }
            // 左邊的岬角與前景的沙
            g.setFillColor(c(64, 34, 34))
            let cape = CGMutablePath()
            cape.move(to: CGPoint(x: 0, y: horizon - 40)); cape.addCurve(to: CGPoint(x: 120, y: horizon), control1: CGPoint(x: 40, y: horizon - 52), control2: CGPoint(x: 80, y: horizon - 14))
            cape.addLine(to: CGPoint(x: 0, y: horizon + 6)); cape.closeSubpath()
            g.addPath(cape); g.fillPath()
            let sand = CGGradient(colorsSpace: cs, colors: [c(150, 82, 52), c(92, 50, 38)] as CFArray, locations: [0, 1])!
            g.saveGState()
            let shore = CGMutablePath()
            shore.move(to: CGPoint(x: 0, y: 330)); shore.addCurve(to: CGPoint(x: 392, y: 352), control1: CGPoint(x: 140, y: 312), control2: CGPoint(x: 260, y: 346))
            shore.addLine(to: CGPoint(x: 392, y: 392)); shore.addLine(to: CGPoint(x: 0, y: 392)); shore.closeSubpath()
            g.addPath(shore); g.clip()
            g.drawLinearGradient(sand, start: CGPoint(x: 0, y: 320), end: CGPoint(x: 0, y: 392), options: [])
            g.restoreGState()
            // 暗角
            let vig = CGGradient(colorsSpace: cs, colors: [c(0, 0, 0, 0), c(0, 0, 0, 0.28)] as CFArray, locations: [0.55, 1])!
            g.drawRadialGradient(vig, startCenter: CGPoint(x: 196, y: 190), startRadius: 0, endCenter: CGPoint(x: 196, y: 190), endRadius: 300, options: [.drawsAfterEndLocation])
        }
        // 底片顆粒＋一點點柔焦（手機照片不會是向量那種硬邊）
        let ci = CIImage(cgImage: img)
        let soft = ci.clampedToExtent().applyingGaussianBlur(sigma: Double(s) * 0.8).cropped(to: ci.extent)
        var out = soft
        if let noise = CIFilter(name: "CIRandomGenerator")?.outputImage?.cropped(to: ci.extent) {
            let grain = noise.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.012, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0.012, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0.012, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: -0.006, y: -0.006, z: -0.006, w: 0)])   // 線性光裡的 ±0.6%：暗處也只是細細的顆粒
            out = grain.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: soft]).cropped(to: ci.extent)
        }
        let final = Face.ciContext.createCGImage(out, from: ci.extent) ?? img
        cache = (px, final)
        return final
    }
}

// MARK: - 畫

extension Face {
    /// 主畫面右上的「照片」小工具（Shell.widgetRect）：照片鋪滿到圓角；沒授權時是一張請求卡
    func drawPhotosWidget(_ g: CGContext, _ wr: CGRect) {
        let src = PhotosWidgetSource.shared
        let px = Int((wr.width * renderPixelScale).rounded())
        src.activate(px: px) { [weak self] in self?.forceDirty = true }
        let path = continuousRoundedRect(wr, radius: Shell.widgetRadius)
        g.saveGState(); g.addPath(path); g.clip()
        defer { g.restoreGState() }
        let card = src.card
        let look = HomeAppearance.current   // P02：清透／染色＝照片去飽和（染色再乘所選色），疊在靜態層畫好的玻璃底上
        if card == .photo {
            g.setAlpha(WidgetImageTreatment.alpha(look))
            if OfficialDemo.on || src.image == nil {
                drawUpright(g, WidgetImageTreatment.accented(PhotosDemoArt.image(px: max(64, px)), appearance: look), in: wr)   // 經過 Core Image 出來是正的：照一般圖畫
            } else if let img = src.image {
                // 等比填滿、置中裁切
                let img = WidgetImageTreatment.accented(img, appearance: look)
                let iw = CGFloat(img.width), ih = CGFloat(img.height), k = max(wr.width / iw, wr.height / ih)
                drawUpright(g, img, in: CGRect(x: wr.midX - iw * k / 2, y: wr.midY - ih * k / 2, width: iw * k, height: ih * k))
            }
            return
        }
        // 請求卡／去設定／沒照片：系統小工具的底（淺色白、深色 #1C1C1E），左上「照片」的圖示，一句話＋一顆膠囊鈕
        let dark = look.widgetDark || look.glassBase   // P02：深色外觀用深色版；清透／染色拿掉背景（底下是玻璃），字用白
        if !look.glassBase { g.setFillColor(dark ? srgb(0x1C1C1E).cgColor : NSColor.white.cgColor); g.fill(wr) }
        let k = wr.width / 158   // iOS 小工具 158 pt → 這裡的像素
        let pad = 16 * k
        let ir = CGRect(x: wr.minX + pad, y: wr.minY + pad, width: 32 * k, height: 32 * k)
        if let icon = AppIconArt.systemIcon("/System/Applications/Photos.app", px: max(64, Int((ir.width * renderPixelScale).rounded()))) {
            g.saveGState(); g.interpolationQuality = .high; g.draw(icon, in: ir); g.restoreGState()
        } else {
            drawSymbol(g, "photo.on.rectangle", in: ir, color: srgb(0xFF9500))
        }
        let ink = look.glassBase ? WidgetInk.of(look).primary : dark ? NSColor.white : NSColor.black
        let sub = ink.withAlphaComponent(0.55)
        if card == .loading {   // P02：載入中＝佔位內容（靜態的圖示照畫，字換成不同寬的半透明條；HIG-WID-191／193）
            let ph = ink.withAlphaComponent(0.16)
            for (i, w) in [CGFloat(0.62), 0.86, 0.48].enumerated() {
                let y = ir.maxY + 14 * k + CGFloat(i) * 18 * k
                g.addPath(HPComponents.capsulePath(CGRect(x: wr.minX + pad, y: y, width: (wr.width - pad * 2) * w, height: (i == 0 ? 13 : 10) * k)))
                g.setFillColor(ph.cgColor); g.fillPath()
            }
            g.setFillColor(ph.cgColor); g.addPath(continuousRoundedRect(CGRect(x: wr.minX + pad, y: wr.maxY - pad - 44 * k, width: wr.width - pad * 2, height: 44 * k), radius: 10 * k)); g.fillPath()
            return
        }
        let tf = HPType.sf(15 * k, .semibold), bf = HPType.sf(12 * k, .regular)
        let title: String, body: String, button: String?
        switch card {
        case .request:
            title = L("shell.photos.ask.title", "精选照片")
            body = L("shell.photos.ask.body", "允许读取「照片」，只在这台 Mac 上显示。")
            button = L("settings.perm.allow", "允许…")
        case .denied:
            title = L("shell.photos.ask.title", "精选照片")
            body = L("shell.photos.denied.body", "到系统设置的「隐私与安全性 › 照片」打开。")
            button = L("perm.openSettings", "打开系统设置")
        case .hidden:
            title = L("shell.photos.ask.title", "精选照片")
            body = L("guest.needsOwner", "需要主人")
            button = nil
        case .empty:
            title = L("shell.photos.empty.title", "还没有照片")
            body = L("shell.photos.empty.body", "「照片」里有照片时，精选照片会显示在这里。")
            button = nil
        default:
            title = L("shell.photos.ask.title", "精选照片"); body = ""; button = nil
        }
        var y = ir.maxY + 10 * k + tf.ascender
        drawLeft(g, Face.clipped(title, tf, wr.width - pad * 2), font: tf, x: wr.minX + pad, y: y, color: ink)
        y += 4 * k
        for line in Self.photosWrap(body, bf, wr.width - pad * 2, maxLines: button == nil ? 4 : 2) {
            y += bf.ascender - bf.descender + 1 * k
            drawLeft(g, Face.clipped(line, bf, wr.width - pad * 2), font: bf, x: wr.minX + pad, y: y, color: sub)
        }
        if let button {
            let bfnt = HPType.sf(13 * k, .semibold)
            let bw = min(wr.width - pad * 2, Typo.width(button, bfnt) + 28 * k), bh = 30 * k
            let br = CGRect(x: wr.minX + pad, y: wr.maxY - pad - bh, width: bw, height: bh)
            g.setFillColor(srgb(0x0A84FF).cgColor); g.addPath(HPComponents.capsulePath(br)); g.fillPath()
            drawLeft(g, button, font: bfnt, x: br.midX - Typo.width(button, bfnt) / 2, y: br.midY + bfnt.capHeight / 2, color: .white)
        }
    }
}

extension PhotosWidgetSource {
    /// 2.0 depth：VoiceOver——主畫面的小工具是快取的離屏圖，畫的時候記不到；所以由外殼直接問這張卡現在是什麼。
    /// 請求卡／去設定＝一句話＋按鈕名（按下去走既有的 tapPhotosWidget）；有照片、載入中是 nil（沿用大小）
    var axState: String? {
        let pair = { (a: String, b: String) in String(format: L("a11y.pair", "%1$@，%2$@"), a, b) }
        switch card {
        case .request: return pair(L("shell.photos.ask.body", "允许读取「照片」，只在这台 Mac 上显示。"), L("settings.perm.allow", "允许…"))
        case .denied: return pair(L("shell.photos.denied.body", "到系统设置的「隐私与安全性 › 照片」打开。"), L("perm.openSettings", "打开系统设置"))
        case .hidden: return L("guest.needsOwner", "需要主人")
        case .empty: return L("shell.photos.empty.body", "「照片」里有照片时，精选照片会显示在这里。")
        case .photo, .loading: return nil
        }
    }
}

extension Face {
    /// 折行（CTTypesetter：中文逐字、英文按詞）；放不下的最後一行由呼叫端截「…」
    static func photosWrap(_ s: String, _ font: NSFont, _ width: CGFloat, maxLines: Int) -> [String] {
        let ns = s as NSString
        let ts = CTTypesetterCreateWithAttributedString(NSAttributedString(string: s, attributes: Typo.attributes(font)))
        var out: [String] = [], start = 0
        while start < ns.length, out.count < maxLines {
            if out.count == maxLines - 1 { out.append(ns.substring(from: start)); break }
            let n = CTTypesetterSuggestLineBreak(ts, start, Double(width))
            guard n > 0 else { out.append(ns.substring(from: start)); break }
            out.append(ns.substring(with: NSRange(location: start, length: n)).trimmingCharacters(in: .whitespaces))
            start += n
        }
        return out
    }
}

extension PetView {
    /// 點「照片」小工具：沒授權＝出權限卡（既有的權限流程）；有照片＝換下一張
    func tapPhotosWidget() {
        let src = PhotosWidgetSource.shared
        switch src.card {
        case .photo: if !OfficialDemo.on { src.next() }
        case .request, .denied:
            (NSApp.delegate as? AppDelegate)?.withPermission(.photos) { [weak self] ok in
                if ok { src.reset() }
                Shell.homeLayer = nil; self?.face.forceDirty = true
            }
        case .empty, .loading, .hidden: break
        }
        face.forceDirty = true
    }
}
