// iPhone 的 CarPlay App 進 HomeView（2026-11-06 使用者：像 iPhone 鏡像＋Spotlight，一鍵跳過去、兩邊無縫）。
// 照蘋果在 Mac 上處理 iPhone 鏡像 App 的方式：只在 App 資源庫的「iPhone」分類與搜尋裡，有開關，不自動放上主畫面。
//
// 清單：iPhone 鏡像的 appplaceholdersyncd 在這台 Mac 存了每個 iPhone App 的佔位
//   ~/Library/Daemon Containers/<它的容器>/Data/Library/Caches/Placeholders-v*.noindex/<bundle>-<版本>/<在地名稱>.app
//   裡面有 Info.plist（bundle id、URL scheme）、圖示（系統照樣畫得出來）、PlaceholderEntitlements.plist（com.apple.developer.carplay-*）。
//   有 CarPlay 權利的就是能上 CarPlay 的；系統的地圖／音樂／電話／Podcast 沒帶這些權利，另列。沒用過 iPhone 鏡像＝沒有清單，就什麼都不加。
// 跳過去：接收端在事件通道送 requestUI（不帶 uuid）＋URL——2026-11-06 真機：maps:／music:／mobilephone:／nowplaying:／podcasts: 直接開系統 App，
//   第三方用它自己的 URL scheme（iosamap://、cosmos://）也開得了；bundle id 形式不行。
import AppKit

/// 一個 iPhone 上的 CarPlay App（純資料，自檢用）
struct PhoneCarPlayEntry: Equatable {
    var bundleID: String
    var name: String
    var url: String
    var path: String
}

enum PhoneCarPlayCatalog {
    /// 系統 App：沒有 CarPlay 權利，但 CarPlay 主畫面一定有；URL 是真機驗過的那幾個
    static let systemURLs: [String: String] = [
        "com.apple.Maps": "maps:", "com.apple.Music": "music:", "com.apple.mobilephone": "mobilephone:", "com.apple.podcasts": "podcasts:",
    ]
    /// 從 App 的 URL scheme 挑一個「開 App 本身」的：排掉 Facebook／微博／微信分享、Google 登入、x-callback、看起來像金鑰的，
    /// 剩下的優先挑含 bundle id 末段或名字的，再挑最短的純字母
    static func pickScheme(_ schemes: [String], bundleID: String, name: String) -> String? {
        let bad = ["fb", "wb", "wx", "tencent", "qq", "db-", "pin", "com.googleusercontent", "com.google.sso", "x-callback", "xyzauthsdk"]
        let ok = schemes.filter { s in
            let l = s.lowercased()
            return !l.isEmpty && !l.contains(".") && !l.contains("x-callback") && !bad.contains { l.hasPrefix($0) }
                && l.count <= 16 && l.allSatisfy { $0.isLetter || $0 == "-" }
        }
        let tail = bundleID.split(separator: ".").last.map { $0.lowercased() } ?? ""
        let ascii = name.lowercased().filter { $0.isASCII && $0.isLetter }
        let hit = ok.filter { s in let l = s.lowercased(); return (tail.count >= 3 && l.contains(tail)) || (ascii.count >= 3 && l.contains(ascii)) }
        return (hit.isEmpty ? ok : hit).min { $0.count < $1.count }
    }
    static func entry(path: String, info: [String: Any], entitlements: [String: Any]) -> PhoneCarPlayEntry? {
        guard let bid = info["CFBundleIdentifier"] as? String else { return nil }
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        if let u = systemURLs[bid] { return PhoneCarPlayEntry(bundleID: bid, name: name, url: u, path: path) }
        guard entitlements.keys.contains(where: { $0.hasPrefix("com.apple.developer.carplay-") }) else { return nil }
        let schemes = (info["CFBundleURLTypes"] as? [[String: Any]] ?? []).flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        guard let s = pickScheme(schemes, bundleID: bid, name: name) else { return nil }
        return PhoneCarPlayEntry(bundleID: bid, name: name, url: s + "://", path: path)
    }

    /// appplaceholdersyncd 的佔位資料夾（找容器的 metadata 認名字，不寫死 UUID）
    static func placeholderRoot() -> URL? {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Daemon Containers", isDirectory: true)
        for d in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
            let meta = d.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
            guard let data = try? Data(contentsOf: meta),
                  let o = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  o["MCMMetadataIdentifier"] as? String == "com.apple.appplaceholdersyncd" else { continue }
            let caches = d.appendingPathComponent("Data/Library/Caches", isDirectory: true)
            let dirs = (try? fm.contentsOfDirectory(atPath: caches.path)) ?? []
            if let p = dirs.filter({ $0.hasPrefix("Placeholders-v") }).sorted().last { return caches.appendingPathComponent(p, isDirectory: true) }
        }
        return nil
    }
    static func scan() -> [PhoneCarPlayEntry] {
        guard let root = placeholderRoot() else { return [] }
        let fm = FileManager.default
        func plist(_ p: String) -> [String: Any] {
            (try? Data(contentsOf: URL(fileURLWithPath: p))).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        }
        var out: [PhoneCarPlayEntry] = []
        for d in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let dir = root.appendingPathComponent(d).path
            guard let app = (try? fm.contentsOfDirectory(atPath: dir))?.first(where: { $0.hasSuffix(".app") }) else { continue }
            let path = dir + "/" + app
            if let e = entry(path: path, info: plist(path + "/Info.plist"), entitlements: plist(path + "/PlaceholderEntitlements.plist")),
               !out.contains(where: { $0.bundleID == e.bundleID }) { out.append(e) }
        }
        // 系統的在前（地圖、音樂、電話、Podcast），其他照名字
        return out.sorted { a, b in
            let sa = systemURLs[a.bundleID] != nil, sb = systemURLs[b.bundleID] != nil
            return sa != sb ? sa : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

/// 主畫面／App 資源庫上的一格：點了＝切到 CarPlay 並在手機上開這個 App（不開桌寵自己的頁面）
final class PhoneCarPlayApp: PetApp {
    let entry: PhoneCarPlayEntry
    let id: String
    var title: String { entry.name }
    /// 系統畫的乾淨圖示＋右下的小車；背景還沒畫好時先用車的符號
    var icon: AppIcon { AppIcon(color: .darkGray, symbol: "car.fill", image: PhoneIconCache.badged(entry)) }
    static let idPrefix = "iphone:"
    init(_ e: PhoneCarPlayEntry) { entry = e; id = Self.idPrefix + e.bundleID }
    func render(into g: CGContext, face: Face, rect: CGRect, now: Double) {
        g.setFillColor(NSColor.black.cgColor); g.fill(rect)
    }
    func launch(face: Face) -> Bool {
        (NSApp.delegate as? AppDelegate)?.openCarPlayApp(entry.url, name: entry.name)
        return true
    }
}

/// iPhone App 的圖示。佔位 App 沒有可執行檔，直接請系統畫它的圖示會蓋上一個禁止符號；佔位裡的圖示是分層的新格式，
/// 用目錄或 bundle id 也畫不出來。做法：在快取資料夾搭一個暫存 .app——只放佔位的 Info.plist（拿掉 URL scheme 之類的宣告、
/// 換一個自己的 bundle id，免得被當成那個 App）、Assets.car 和一個空的可執行檔——再請系統畫它，就是乾淨的圖示。
/// 畫好存成 iphone-icons/<bundle>-<版本>.png（佔位資料夾的名字），版本變了才重畫；全在背景佇列做。
/// 畫不出來的記下來，retryAfter 秒內不再試（不然每次重畫主畫面都會再搭一次暫存 .app）；
/// 上次沒清掉的暫存 .app（build.noindex，例如畫到一半被結束）第一次載入前清掉。
enum PhoneIconCache {
    /// 自檢換成暫存資料夾
    nonisolated(unsafe) static var directoryOverride: URL?
    static var directory: URL { directoryOverride ?? HomePlayState.directory.appendingPathComponent("iphone-icons", isDirectory: true) }
    static var buildDirectory: URL { directory.appendingPathComponent("build.noindex", isDirectory: true) }
    private static let queue = DispatchQueue(label: "homeplay.iphone-icons", qos: .utility)
    /// 只在主執行緒讀寫
    nonisolated(unsafe) private static var memo: [String: CGImage] = [:]
    nonisolated(unsafe) private static var pending: Set<String> = []
    /// 畫失敗的 key → 失敗的時間（主執行緒讀寫）
    nonisolated(unsafe) private(set) static var failedAt: [String: Double] = [:]
    static let retryAfter: Double = 3600
    nonisolated(unsafe) private static var swept = false
    /// 真的去畫了幾次（自檢看有沒有一直重畫）
    nonisolated(unsafe) private(set) static var attempts = 0
    /// 時鐘（自檢換成假的）
    nonisolated(unsafe) static var clock: () -> Double = { CACurrentMediaTime() }
    /// 快照（--screen-png）：同步畫，不然拍下去還是車的符號；自檢也換成同步
    nonisolated(unsafe) static var synchronous = CommandLine.arguments.contains("--screen-png")

    /// 清掉上次留下的暫存 .app（只做一次；在畫圖示的序列佇列上，排在之後的畫圖前面）
    static func sweepLeftovers() {
        guard !swept else { return }
        swept = true
        let dir = buildDirectory
        let work: () -> Void = { try? FileManager.default.removeItem(at: dir) }
        if synchronous { queue.sync(execute: work) } else { queue.async(execute: work) }
    }
    /// 自檢用：重設記錄
    static func resetForTest() { memo = [:]; pending = []; failedAt = [:]; swept = false; attempts = 0 }

    /// 佔位資料夾名＝<bundle>-<版本>
    static func key(_ e: PhoneCarPlayEntry) -> String { ((e.path as NSString).deletingLastPathComponent as NSString).lastPathComponent }
    static func badged(_ e: PhoneCarPlayEntry) -> CGImage? {
        let k = key(e)
        if let m = memo[k] { return m }
        load(e)
        return memo[k]
    }
    static func load(_ e: PhoneCarPlayEntry) {
        let k = key(e)
        guard memo[k] == nil, !pending.contains(k) else { return }
        if let t = failedAt[k], clock() - t < retryAfter { return }   // 剛畫失敗過：先不重試
        sweepLeftovers()
        pending.insert(k)
        attempts += 1
        let sync = synchronous
        let work = {
            let img = cleanIcon(e, key: k).flatMap { badge($0) }
            let done = {
                pending.remove(k)
                guard let img else {
                    failedAt[k] = clock()
                    log("iphone icon: draw failed \(k), retry after \(Int(retryAfter)) s")
                    return
                }
                failedAt[k] = nil
                memo[k] = img
                Shell.homeLayer = nil; SB.pageCache.removeAll()
                (NSApp?.delegate as? AppDelegate)?.view?.face.forceDirty = true
            }
            if sync { done() } else { DispatchQueue.main.async(execute: done) }
        }
        if sync { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    /// 乾淨的圖示：有快取讀快取；沒有就搭暫存 .app 請系統畫，存檔、清掉同一個 App 的舊版本
    static func cleanIcon(_ e: PhoneCarPlayEntry, key k: String, px: Int = 256) -> CGImage? {
        let fm = FileManager.default
        let png = directory.appendingPathComponent(k + ".png")
        if let s = CGImageSourceCreateWithURL(png as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(s, 0, nil) { return img }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let src = URL(fileURLWithPath: e.path, isDirectory: true)
        let tmp = buildDirectory.appendingPathComponent("\(UUID().uuidString).app", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            if fm.fileExists(atPath: src.appendingPathComponent("Assets.car").path) {
                try fm.copyItem(at: src.appendingPathComponent("Assets.car"), to: tmp.appendingPathComponent("Assets.car"))
            }
            guard let info = NSMutableDictionary(contentsOf: src.appendingPathComponent("Info.plist")) else { return nil }
            for key in ["CFBundleURLTypes", "CFBundleDocumentTypes", "UTExportedTypeDeclarations", "UTImportedTypeDeclarations", "NSUserActivityTypes", "LSApplicationQueriesSchemes"] {
                info.removeObject(forKey: key)
            }
            info["CFBundleIdentifier"] = "app.homeplay.iphone-icon"
            let exe = (info["CFBundleExecutable"] as? String).flatMap { $0.isEmpty || $0.contains("/") ? nil : $0 } ?? "Executable"
            info["CFBundleExecutable"] = exe
            guard info.write(to: tmp.appendingPathComponent("Info.plist"), atomically: true) else { return nil }
            let exeURL = tmp.appendingPathComponent(exe)
            try Data("#!/bin/sh\n".utf8).write(to: exeURL)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exeURL.path)
        } catch {
            log("iphone icon: build failed \(k): \(error.localizedDescription)")
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: tmp.path)
        guard let img = draw(px, { r in icon.draw(in: r) }) else { return nil }
        if let d = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
        }
        // 同一個 App 的舊版本（<bundle>-<數字開頭的版本>.png）清掉
        let prefix = e.bundleID + "-"
        for f in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where f.hasPrefix(prefix) && f.hasSuffix(".png") && f != k + ".png" {
            if f.dropFirst(prefix.count).first?.isNumber == true { try? fm.removeItem(at: directory.appendingPathComponent(f)) }
        }
        return img
    }

    /// 乾淨圖示＋右下角小小的車（像 iPhone 鏡像的 App 角標：一眼看得出是開在 iPhone／CarPlay 上）
    static func badge(_ clean: CGImage, px: Int = 256) -> CGImage? {
        draw(px) { r in
            let s = r.width
            NSGraphicsContext.current?.cgContext.draw(clean, in: r)
            let d = s * 0.36, b = NSRect(x: s - d - s * 0.02, y: s * 0.02, width: d, height: d)
            NSColor.black.withAlphaComponent(0.85).setFill(); NSBezierPath(ovalIn: b).fill()
            NSColor.white.setStroke(); let ring = NSBezierPath(ovalIn: b.insetBy(dx: 1.5, dy: 1.5)); ring.lineWidth = s * 0.012; ring.stroke()
            if let car = NSImage(systemSymbolName: "car.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: d * 0.45, weight: .semibold).applying(.init(paletteColors: [.white]))) {
                let cs = car.size
                car.draw(in: NSRect(x: b.midX - cs.width / 2, y: b.midY - cs.height / 2, width: cs.width, height: cs.height))
            }
        }
    }

    /// 背景執行緒也能用的點陣畫布（左下原點，跟 NSImage 一樣）
    private static func draw(_ px: Int, _ body: (NSRect) -> Void) -> CGImage? {
        guard let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
        body(NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        return c.makeImage()
    }
}

/// iPhone 的 CarPlay App：照蘋果在 Mac 上處理 iPhone 鏡像 App 的方式（2026-11-06 拍板）——
/// 只出現在 App 資源庫的「iPhone」分類與搜尋裡，有「顯示 iPhone App」開關（預設開），不自動放到主畫面；
/// 想常駐就自己長按／拖到主畫面（放上去的照常顯示，開關關掉也不拿掉）。
final class PhoneAppProvider: AppProvider {
    static let shared = PhoneAppProvider()
    static let showKey = "shell.showPhoneApps"
    /// 設定 › 外觀「顯示 iPhone App」
    static var show: Bool { UserDefaults.standard.object(forKey: showKey) as? Bool ?? true }
    static func setShow(_ on: Bool) { UserDefaults.standard.set(on, forKey: showKey); Shell.homeLayer = nil; SB.pageCache.removeAll() }

    private var apps: [PhoneCarPlayApp] = []
    private var scannedAt = Date.distantPast
    private var scanned = false
    private var scanning = false
    private let queue = DispatchQueue(label: "homeplay.iphone-apps", qos: .utility)

    /// 啟動後在背景掃一次（不等打開資源庫）；之後每 600 秒最多一次
    func refreshInBackground() {
        guard !scanning, Date().timeIntervalSince(scannedAt) > 600 else { return }
        scanning = true; scannedAt = Date()
        queue.async { [weak self] in
            let entries = PhoneCarPlayCatalog.scan()
            DispatchQueue.main.async { self?.apply(entries); self?.scanning = false }
        }
    }
    /// 第一次有人要清單（存檔裡放在主畫面上的 iPhone App 要認得）而背景還沒掃完：等它（只讀幾個 plist，很快）
    private func ensureScanned() {
        guard !scanned else { refreshInBackground(); return }
        let entries = queue.sync { PhoneCarPlayCatalog.scan() }
        if !scanned { apply(entries); scannedAt = Date() }
    }
    func apply(_ entries: [PhoneCarPlayEntry]) {
        let old = apps
        apps = entries.map { e in old.first { $0.entry == e } ?? PhoneCarPlayApp(e) }
        if !scanned || old.map(\.entry) != entries {
            log("phone CarPlay apps: \(apps.count)")
            Shell.homeLayer = nil; SB.pageCache.removeAll()
            (NSApp?.delegate as? AppDelegate)?.view?.face.forceDirty = true
        }
        scanned = true; scannedAt = Date()
        if !CommandLine.arguments.contains("--selftest") { PhoneIconCache.sweepLeftovers(); for a in apps { PhoneIconCache.load(a.entry) } }   // 圖示在背景先畫好（有快取就讀快取）
    }

    /// 資源庫、搜尋、ClioTalk 看得到的：開關關掉就一個都沒有
    func apps(viewer: String?) -> [PetApp] { ensureScanned(); return Self.show ? apps : [] }
    /// 放在主畫面上的照常認得（開關只管資源庫與搜尋）
    func app(_ id: String) -> PetApp? {
        guard id.hasPrefix(PhoneCarPlayApp.idPrefix) else { return nil }
        ensureScanned(); return apps.first { $0.id == id }
    }
    func locks(_ id: String) -> Bool { false }   // 門在 PersonalGate.isPersonal（跟 CarPlay 一起鎖、遠端訪客照 RemotePrivacy），這裡不另外加
    func spokenNames(_ id: String) -> [String] { [] }
}

// MARK: - 自檢

enum PhoneAppsSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        typealias C = PhoneCarPlayCatalog
        check(C.pickScheme(["wexinVideoAPI", "weixin", "weixinapp", "fb290293790992170", "wechat"], bundleID: "com.tencent.xin", name: "微信") == "weixin"
              && C.pickScheme(["com.googleusercontent.apps.6747", "fb1947825072402628", "wb884965267", "iosamap", "amapuri"], bundleID: "com.autonavi.amap", name: "高德地图") == "iosamap"   // l10n-ignore
              && C.pickScheme(["comgooglemaps-x-callback", "comgooglemaps", "googlemaps"], bundleID: "com.google.Maps", name: "Google Maps") == "googlemaps"
              && C.pickScheme(["wx1839d4276a0c16df", "cosmos", "xyzauthsdk"], bundleID: "app.podcast.cosmos", name: "小宇宙") == "cosmos",   // l10n-ignore
              "iPhone App：挑開 App 本身的 URL scheme（排掉分享、登入、金鑰）")   // l10n-ignore
        let ent = ["com.apple.developer.carplay-maps": true]
        let amap = C.entry(path: "/x/com.autonavi.amap-1/高德地图.app", info: ["CFBundleIdentifier": "com.autonavi.amap",   // l10n-ignore
                                                                          "CFBundleURLTypes": [["CFBundleURLSchemes": ["iosamap"]]]], entitlements: ent)
        check(amap?.url == "iosamap://" && amap?.name == "高德地图"   // l10n-ignore
              && C.entry(path: "/x/a/Maps.app", info: ["CFBundleIdentifier": "com.apple.Maps"], entitlements: [:])?.url == "maps:"
              && C.entry(path: "/x/a/Notes.app", info: ["CFBundleIdentifier": "com.apple.mobilenotes"], entitlements: [:]) == nil,
              "iPhone App：有 CarPlay 權利或是系統四個才上；名字用佔位的在地名稱")   // l10n-ignore
        // 照 Mac：只在資源庫「iPhone」分類與搜尋；開關關掉就不見，放在主畫面上的照常認得
        let p = PhoneAppProvider()
        let eb = PhoneCarPlayEntry(bundleID: "com.b", name: "Bravo", url: "b://", path: "/x/com.b-2.0/Bravo.app")
        let ea = PhoneCarPlayEntry(bundleID: "com.a", name: "Alpha", url: "a://", path: "/x/com.a-1.0/Alpha.app")
        p.apply([eb, ea])
        let ud = UserDefaults.standard, old = ud.object(forKey: PhoneAppProvider.showKey)
        defer { if let old { ud.set(old, forKey: PhoneAppProvider.showKey) } else { ud.removeObject(forKey: PhoneAppProvider.showKey) } }
        ud.set(false, forKey: PhoneAppProvider.showKey)
        check(p.apps(viewer: nil).isEmpty && p.app("iphone:com.a") != nil, "iPhone App：「顯示 iPhone App」關掉就從資源庫與搜尋消失，主畫面上的照常認得")   // l10n-ignore
        ud.set(true, forKey: PhoneAppProvider.showKey)
        if let music = AppRegistry.app("music") {
            let secs = SBUI.librarySections(p.apps(viewer: nil) + [music])
            check(secs.count == 2 && secs[0].title == nil && secs[0].apps.map(\.id) == ["music"] && secs[1].title == L("sb.library.iphone", "iPhone")
                  && secs[1].apps.map(\.title) == ["Alpha", "Bravo"], "iPhone App：資源庫另一區「iPhone」，照名字排")   // l10n-ignore
            check(SBUI.librarySections([music]).count == 1, "iPhone App：沒有 iPhone App 時不出現分類")   // l10n-ignore
        }
        check(PhoneIconCache.key(eb) == "com.b-2.0" && SBAX.appLabel(p.apps(viewer: nil)[0]).hasSuffix(L("sb.ax.openInCarPlay", "（在 CarPlay 打开）")),
              "iPhone App：圖示快取照 <bundle>-<版本>；VoiceOver 念「在 CarPlay 打开」")   // l10n-ignore
        iconFailures(check)
    }

    /// 畫失敗的圖示記下來一段時間不重試；上次留下的暫存 .app 清掉。全在暫存資料夾，不碰真的快取
    static func iconFailures(_ check: (Bool, String) -> Void) {
        typealias I = PhoneIconCache
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("hp-iphone-icons-\(UUID().uuidString)", isDirectory: true)
        let saved = (I.directoryOverride, I.synchronous, I.clock)
        defer { I.directoryOverride = saved.0; I.synchronous = saved.1; I.clock = saved.2; I.resetForTest(); try? fm.removeItem(at: dir) }
        I.directoryOverride = dir; I.synchronous = true; I.resetForTest()
        var t = 1000.0
        I.clock = { t }
        let stale = I.buildDirectory.appendingPathComponent("LEFT-OVER.app", isDirectory: true)
        try? fm.createDirectory(at: stale, withIntermediateDirectories: true)
        let broken = PhoneCarPlayEntry(bundleID: "com.broken", name: "Broken", url: "b://", path: dir.appendingPathComponent("missing/com.broken-1.0/Broken.app").path)
        let first = I.badged(broken)
        let swept = !fm.fileExists(atPath: stale.path)
        _ = I.badged(broken); _ = I.badged(broken)
        let held = I.attempts == 1 && I.failedAt[I.key(broken)] == 1000
        t += I.retryAfter + 1
        _ = I.badged(broken)
        let leftovers = (try? fm.contentsOfDirectory(atPath: I.buildDirectory.path)) ?? []
        check(first == nil && swept && held && I.attempts == 2 && leftovers.isEmpty,
              "iPhone App：圖示畫失敗記下來，一小時內不重畫；上次留下的暫存 .app 清掉（\(I.attempts) 次、剩 \(leftovers.count)）")   // l10n-ignore
    }
}
