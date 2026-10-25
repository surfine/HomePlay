// 2.0 Web App（docs/plans/webapps.md）：manifest 解析、範圍、圖示挑選、CSS 顏色（純邏輯，--selftest 驗）；
// WebApp 的存檔（每個 Web App 一份網站資料、一張圖示）與「誰能打開」的門。
//
// 解析規則照 W3C Web App Manifest（WD 2026-10）：
// - start_url：對 manifest 網址解析；壞掉或跟文件不同源＝文件網址。
// - scope：對 manifest 網址解析；缺、壞、不同源或不包含 start_url＝start_url 去掉檔名、query、fragment。
// - id：對 start_url 的 origin 解析、去 fragment；不同源或缺＝start_url。
// - display：小寫、去空白；不認得的退回 browser。icons：purpose 沒有認得的字就不要；sizes 只是挑圖的提示。
// 網址、manifest 內容都不進日誌。

import AppKit
import WebKit

// MARK: - Manifest

struct WebManifestIcon: Codable, Equatable {
    var src: URL
    var size: Int            // sizes 裡最大的邊；"any"（SVG）＝1024；沒寫＝0
    var purpose: Set<String>
    var type: String?
}

/// manifest 的 widgets[]（Microsoft PWA Widgets）：我們只用畫得出來的那幾個欄位
struct WebAppWidgetDef: Codable, Equatable {
    var tag: String
    var name: String
    var shortName: String?
    var summary: String?
    var template: URL?       // ms_ac_template：Adaptive Card 範本
    var data: URL?           // 範本要綁的 JSON
    var update: Double?      // 幾秒更新一次
}

struct WebManifest: Equatable {
    var name: String?
    var shortName: String?
    var startURL: URL
    var scope: URL
    var id: URL
    var display: String
    var themeColor: UInt32?
    var backgroundColor: UInt32?
    var icons: [WebManifestIcon]
    var widgets: [WebAppWidgetDef]
}

enum WebManifestParser {
    static let displays: Set<String> = ["fullscreen", "standalone", "minimal-ui", "browser"]
    static let purposes: Set<String> = ["any", "maskable", "monochrome"]

    /// 沒有 manifest 的網頁（iOS 26 一樣能加成 Web App）：start＝這一頁、scope＝它的資料夾
    static func fallback(document: URL) -> WebManifest {
        let start = stripFragment(document)
        return WebManifest(name: nil, shortName: nil, startURL: start, scope: defaultScope(start), id: start, display: "standalone",
                           themeColor: nil, backgroundColor: nil, icons: [], widgets: [])
    }

    static func parse(json: Data, manifestURL: URL, documentURL: URL) -> WebManifest {
        guard let o = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return fallback(document: documentURL) }
        func str(_ k: String) -> String? {
            guard let s = o[k] as? String else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        // start_url
        var start = stripFragment(documentURL)
        if let s = str("start_url"), let u = URL(string: s, relativeTo: manifestURL)?.absoluteURL, allowedScheme(u), sameOrigin(u, documentURL) { start = stripFragment(u) }
        // scope
        var scope = defaultScope(start)
        if let s = str("scope"), let u = URL(string: s, relativeTo: manifestURL)?.absoluteURL, allowedScheme(u) {
            let cleaned = stripQueryAndFragment(u)
            if inScope(start, scope: cleaned) { scope = cleaned }
        }
        // id
        var id = start
        if let s = o["id"] as? String, let origin = originURL(start), let u = URL(string: s, relativeTo: origin)?.absoluteURL, sameOrigin(u, start) { id = stripFragment(u) }
        // display（display_override 第一個認得的優先）
        var display = (str("display") ?? "").lowercased()
        if !displays.contains(display) { display = "browser" }
        if let ov = o["display_override"] as? [String], let first = ov.map({ $0.lowercased().trimmingCharacters(in: .whitespaces) }).first(where: displays.contains) { display = first }
        // icons
        var icons: [WebManifestIcon] = []
        for i in (o["icons"] as? [[String: Any]]) ?? [] {
            guard let s = i["src"] as? String, let u = URL(string: s, relativeTo: manifestURL)?.absoluteURL, allowedScheme(u) else { continue }
            let ps = Set(((i["purpose"] as? String) ?? "any").lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
            let p = ps.intersection(purposes)
            guard !p.isEmpty else { continue }
            icons.append(WebManifestIcon(src: u, size: maxSize(i["sizes"] as? String), purpose: p, type: i["type"] as? String))
        }
        // widgets（Microsoft PWA Widgets）
        var widgets: [WebAppWidgetDef] = []
        for w in (o["widgets"] as? [[String: Any]]) ?? [] {
            guard let tag = (w["tag"] as? String)?.trimmingCharacters(in: .whitespaces), !tag.isEmpty,
                  let name = (w["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            func url(_ k: String) -> URL? {
                guard let s = w[k] as? String, let u = URL(string: s, relativeTo: manifestURL)?.absoluteURL, allowedScheme(u), sameOrigin(u, start) else { return nil }
                return u
            }
            widgets.append(WebAppWidgetDef(tag: tag, name: name, shortName: w["short_name"] as? String, summary: w["description"] as? String,
                                           template: url("ms_ac_template"), data: url("data"), update: (w["update"] as? NSNumber)?.doubleValue))
        }
        return WebManifest(name: str("name"), shortName: str("short_name"), startURL: start, scope: scope, id: id, display: display,
                           themeColor: str("theme_color").flatMap(CSSColor.parse), backgroundColor: str("background_color").flatMap(CSSColor.parse),
                           icons: icons, widgets: widgets)
    }

    // MARK: 網址

    static func allowedScheme(_ u: URL) -> Bool { ["http", "https"].contains(u.scheme?.lowercased() ?? "") && u.host?.isEmpty == false }
    static func originURL(_ u: URL) -> URL? {
        guard let s = u.scheme, let h = u.host else { return nil }
        return URL(string: "\(s)://\(h)\(u.port.map { ":\($0)" } ?? "")/")
    }
    static func port(_ u: URL) -> Int { u.port ?? (u.scheme?.lowercased() == "https" ? 443 : 80) }
    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased() && port(a) == port(b)
    }
    static func stripFragment(_ u: URL) -> URL {
        guard var c = URLComponents(url: u, resolvingAgainstBaseURL: true) else { return u }
        c.fragment = nil
        return c.url ?? u
    }
    static func stripQueryAndFragment(_ u: URL) -> URL {
        guard var c = URLComponents(url: u, resolvingAgainstBaseURL: true) else { return u }
        c.fragment = nil; c.query = nil
        return c.url ?? u
    }
    /// 預設 scope：start_url 去掉檔名（最後一個 / 之後）、query、fragment
    static func defaultScope(_ start: URL) -> URL {
        guard var c = URLComponents(url: start, resolvingAgainstBaseURL: true) else { return start }
        c.query = nil; c.fragment = nil
        let p = c.percentEncodedPath
        if let i = p.lastIndex(of: "/") { c.percentEncodedPath = String(p[...i]) } else { c.percentEncodedPath = "/" }
        return c.url ?? start
    }
    /// 在範圍裡：同源，而且路徑以 scope 的路徑開頭
    static func inScope(_ u: URL, scope: URL) -> Bool {
        guard allowedScheme(u), sameOrigin(u, scope) else { return false }
        let path = URLComponents(url: u, resolvingAgainstBaseURL: true)?.percentEncodedPath ?? ""
        let sp = URLComponents(url: scope, resolvingAgainstBaseURL: true)?.percentEncodedPath ?? ""
        return (path.isEmpty ? "/" : path).hasPrefix(sp.isEmpty ? "/" : sp)
    }
    static func maxSize(_ s: String?) -> Int {
        guard let s else { return 0 }
        var best = 0
        for tok in s.lowercased().split(whereSeparator: \.isWhitespace) {
            if tok == "any" { best = max(best, 1024); continue }
            let p = tok.split(separator: "x")
            if p.count == 2, let w = Int(p[0]), let h = Int(p[1]) { best = max(best, min(w, h)) }
        }
        return best
    }

    /// 挑主畫面圖示：apple-touch-icon 優先（iOS 的順序）；再來 maskable（滿版，裁成圓角方塊剛好）、any；
    /// 點陣圖優先於 SVG；同一種挑「≥ 192 裡最小的」，都不到就挑最大的
    static func pickIcon(touchIcons: [URL], icons: [WebManifestIcon]) -> URL? {
        if let t = touchIcons.first { return t }
        let raster = icons.filter { !($0.type ?? $0.src.pathExtension).lowercased().contains("svg") }
        let pool = raster.isEmpty ? icons : raster
        for want in ["maskable", "any"] {
            let c = pool.filter { $0.purpose.contains(want) }
            guard !c.isEmpty else { continue }
            if let ok = c.filter({ $0.size >= 192 }).min(by: { $0.size < $1.size }) { return ok.src }
            return c.max { $0.size < $1.size }?.src
        }
        return nil
    }
}

// MARK: - CSS 顏色（theme_color、background_color、<meta name=theme-color>）

enum CSSColor {
    static let named: [String: UInt32] = ["black": 0x000000, "white": 0xFFFFFF, "red": 0xFF0000, "green": 0x008000, "blue": 0x0000FF,
                                          "yellow": 0xFFFF00, "orange": 0xFFA500, "purple": 0x800080, "gray": 0x808080, "grey": 0x808080,
                                          "navy": 0x000080, "teal": 0x008080, "silver": 0xC0C0C0, "maroon": 0x800000, "olive": 0x808000,
                                          "lime": 0x00FF00, "aqua": 0x00FFFF, "fuchsia": 0xFF00FF, "pink": 0xFFC0CB, "brown": 0xA52A2A]
    /// #rgb、#rgba、#rrggbb、#rrggbbaa、rgb()／rgba()、常見色名 → 0xRRGGBB（透明度不要）
    static func parse(_ s: String) -> UInt32? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if let n = named[t] { return n }
        if t.hasPrefix("#") {
            var h = String(t.dropFirst())
            guard h.allSatisfy(\.isHexDigit) else { return nil }
            if h.count == 3 || h.count == 4 { h = String(h.prefix(3)).map { "\($0)\($0)" }.joined() }
            if h.count == 8 { h = String(h.prefix(6)) }
            return h.count == 6 ? UInt32(h, radix: 16) : nil
        }
        if t.hasPrefix("rgb"), let o = t.firstIndex(of: "("), let c = t.lastIndex(of: ")"), o < c {
            let parts = t[t.index(after: o)..<c].split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).map(String.init)
            guard parts.count >= 3 else { return nil }
            var v: UInt32 = 0
            for p in parts.prefix(3) {
                let x: Double
                if p.hasSuffix("%"), let d = Double(p.dropLast()) { x = d * 2.55 } else if let d = Double(p) { x = d } else { return nil }
                v = v << 8 | UInt32(max(0, min(255, x.rounded())))
            }
            return v
        }
        return nil
    }
    /// 這個底色上用白字還是黑字（相對亮度 > 0.5 用黑）
    static func isLight(_ rgb: UInt32) -> Bool {
        func lin(_ c: UInt32) -> Double { let x = Double(c) / 255; return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        let l = 0.2126 * lin(rgb >> 16 & 0xFF) + 0.7152 * lin(rgb >> 8 & 0xFF) + 0.0722 * lin(rgb & 0xFF)
        return l > 0.45
    }
}

// MARK: - 一個 Web App

struct WebApp: Codable, Equatable {
    static let idPrefix = "web."
    var uuid: String
    var manifestID: String
    var name: String
    var startURL: String
    var scope: String
    /// "standalone"＝以 Web App 開啟；"browser"＝「以 Web App 開啟」關掉：只是書籤，點了在 Safari 開（iOS 26 同款開關）
    var display: String
    var theme: UInt32?
    var background: UInt32?
    /// 加的那個人（PeopleRegistry 的 id）：只在他的主畫面與 App 資料庫
    var person: String?
    var added: Double
    var widgets: [WebAppWidgetDef] = []
    /// camera／microphone／location／notifications → allow／deny（沒有＝下次用到再問）
    var permissions: [String: String] = [:]
    var hasIcon = false
    /// 家人都能打開（設定裡開；預設只有加的那個人）。訪客、遠端訪客一律不行
    var shared = false

    var appID: String { Self.idPrefix + uuid }
    var start: URL? { URL(string: startURL) }
    var scopeURL: URL? { URL(string: scope) }
    var standalone: Bool { display != "browser" }
    var host: String { SafariLogic.displayHost(start) }

    static func uuid(fromAppID id: String) -> String? { id.hasPrefix(idPrefix) ? String(id.dropFirst(idPrefix.count)) : nil }
    func inScope(_ u: URL) -> Bool { scopeURL.map { WebManifestParser.inScope(u, scope: $0) } ?? false }
}

enum WebAppPermission: String, CaseIterable {
    case camera, microphone, location, notifications
    var title: String {
        switch self {
        case .camera: return L("webapp.perm.camera", "相机")
        case .microphone: return L("webapp.perm.microphone", "麦克风")
        case .location: return L("webapp.perm.location", "位置")
        case .notifications: return L("webapp.perm.notifications", "通知")
        }
    }
    var symbol: String {
        switch self {
        case .camera: return "camera.fill"
        case .microphone: return "mic.fill"
        case .location: return "location.fill"
        case .notifications: return "bell.badge.fill"
        }
    }
    /// 系統式詢問的標題：「“名字”想要使用你的相機」
    func question(_ app: String) -> String {
        switch self {
        case .camera: return String(format: L("webapp.ask.camera", "“%@”想要使用你的相机"), app)
        case .microphone: return String(format: L("webapp.ask.microphone", "“%@”想要使用你的麦克风"), app)
        case .location: return String(format: L("webapp.ask.location", "“%@”想要使用你的大致位置"), app)
        case .notifications: return String(format: L("webapp.ask.notifications", "“%@”想要给你发送通知"), app)
        }
    }
}

// MARK: - 誰能打開（純函數）

enum WebAppGate {
    /// 訪客模式、遠端訪客一律不行；要「眼前就是加的那個人」：主人照 PersonalGate，家人要認人開著而且認出是他（提示不能替誰開門）
    static func canOpen(_ i: PersonalGate.Inputs, person: String?, viewer: String?, viewerIsOwner: Bool, shared: Bool = false) -> Bool {
        if i.guestMode || i.remoteGuest { return false }
        guard let viewer else { return false }
        if !shared, let person, person != viewer { return false }
        if viewerIsOwner { return PersonalGate.allowed(i) }
        return i.recognitionActive && i.viewer.personID == viewer
    }
    static func canOpen(_ app: WebApp) -> Bool {
        if SnapshotPrivacy.active, WebAppStore.shared.demoOnly { return !Shell.guestMode }
        let reg = PeopleRegistry.shared, v = PersonHome.viewerID
        return canOpen(PersonalGate.inputs, person: app.person ?? reg.owner?.id, viewer: v, viewerIsOwner: v != nil && v == reg.owner?.id, shared: app.shared)
    }
}

// MARK: - 存檔：~/Library/Application Support/HomePlay/WebApps/（webapps.json＋每個一張 PNG）

final class WebAppStore {
    static let shared = WebAppStore()
    private(set) var apps: [WebApp] = []
    private var icons: [String: CGImage] = [:]
    /// 快照、selftest：只放在記憶體（不讀也不寫磁碟）
    private(set) var demoOnly = false
    var onChange: (() -> Void)?

    static var directory: URL {
        if let d = ProcessInfo.processInfo.environment["HOMEPLAY_WEBAPPS_DIR"] { return URL(fileURLWithPath: d, isDirectory: true) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("HomePlay/WebApps", isDirectory: true)
    }
    private var file: URL { Self.directory.appendingPathComponent("webapps.json") }
    private func iconFile(_ uuid: String) -> URL { Self.directory.appendingPathComponent("\(uuid).png") }

    private init() {
        if SnapshotPrivacy.active { demoOnly = true; return }
        if let d = try? Data(contentsOf: file), let a = try? JSONDecoder().decode([WebApp].self, from: d) { apps = a }
    }
    /// selftest／快照：換成記憶體裡的一份（回傳原本的，好還原）
    @discardableResult
    func useMemory(_ list: [WebApp], icons ic: [String: CGImage] = [:]) -> (apps: [WebApp], icons: [String: CGImage], demo: Bool) {
        let old = (apps, icons, demoOnly)
        apps = list; icons = ic; demoOnly = true
        return old
    }
    func restore(_ s: (apps: [WebApp], icons: [String: CGImage], demo: Bool)) { apps = s.apps; icons = s.icons; demoOnly = s.demo }

    func app(uuid: String) -> WebApp? { apps.first { $0.uuid == uuid } }
    func app(id: String) -> WebApp? { WebApp.uuid(fromAppID: id).flatMap(app(uuid:)) }
    /// 這個人的 Web App（沒人登記時＝主人的）
    func apps(for person: String?) -> [WebApp] {
        if demoOnly, SnapshotPrivacy.active { return apps }   // 快照：示範的那一個誰都看得到（訪客照樣被門擋）
        guard let person else { return [] }
        let owner = PeopleRegistry.shared.owner?.id
        return apps.filter { $0.shared || ($0.person ?? owner) == person }
    }

    func icon(_ uuid: String) -> CGImage? {
        if let i = icons[uuid] { return i }
        guard !demoOnly, let d = try? Data(contentsOf: iconFile(uuid)), let src = CGImageSourceCreateWithData(d as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        icons[uuid] = img
        return img
    }

    func add(_ a: WebApp, icon: CGImage?) {
        var a = a
        if let icon {
            icons[a.uuid] = icon; a.hasIcon = true
            if !demoOnly, let png = NSBitmapImageRep(cgImage: icon).representation(using: .png, properties: [:]) {
                try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
                try? png.write(to: iconFile(a.uuid))
            }
        }
        apps.append(a)
        save()
    }
    func update(_ uuid: String, _ f: (inout WebApp) -> Void) {
        guard let i = apps.firstIndex(where: { $0.uuid == uuid }) else { return }
        f(&apps[i]); save()
    }
    /// 刪掉：圖示、存檔、這個 Web App 自己的網站資料（cookie、localStorage、service worker）
    func remove(_ uuid: String) {
        apps.removeAll { $0.uuid == uuid }
        icons[uuid] = nil
        if !demoOnly {
            try? FileManager.default.removeItem(at: iconFile(uuid))
            WebAppData.removeStore(uuid)
        }
        save()
    }
    func save() {
        onChange?()
        guard !demoOnly else { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(apps) { try? d.write(to: file, options: .atomic) }
    }
}

/// 每個 Web App 自己的網站資料：WKWebsiteDataStore(forIdentifier:)（macOS 14＋），跟 Safari（不存）與其他 Web App 都分開
enum WebAppData {
    /// WebApp.uuid 一律是 UUID().uuidString
    static func identifier(_ uuid: String) -> UUID { UUID(uuidString: uuid) ?? UUID() }
    /// 快照與 selftest：不碰磁碟（nonPersistent）；平常：這個 Web App 自己那一份
    static func store(_ uuid: String) -> WKWebsiteDataStore {
        WebAppStore.shared.demoOnly ? .nonPersistent() : WKWebsiteDataStore(forIdentifier: identifier(uuid))
    }
    /// 刪掉：先清空這個資料庫裡的一切（cookie、localStorage、IndexedDB、service worker、快取；開著也清得掉），
    /// 再試著刪掉整個資料夾——網路行程還握著這個 session 時 WebKit 回「in use」（實測關掉網頁十幾秒後仍然如此），留給下次啟動的 purgeOrphans
    static func removeStore(_ uuid: String) {
        WebAppRuntimes.drop(uuid); WebAppProvider.shared.forget(uuid)
        let id = identifier(uuid)
        WKWebsiteDataStore(forIdentifier: id).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { WKWebsiteDataStore.remove(forIdentifier: id) { _ in } }
        }
    }
    /// 第一次開 Web App 時：刪掉不屬於任何 Web App 的資料庫（上次刪除時沒刪掉的）。這個 App 只有 Web App 用 forIdentifier
    static func purgeOrphans(keeping uuids: [String]) {
        let keep = Set(uuids.compactMap(UUID.init(uuidString:)))
        WKWebsiteDataStore.fetchAllDataStoreIdentifiers { ids in
            for id in ids where !keep.contains(id) { WKWebsiteDataStore.remove(forIdentifier: id) { _ in } }
        }
    }
    /// 只清網站資料（設定裡的「清除網站資料」），Web App 留著
    static func clear(_ uuid: String, done: @escaping () -> Void) {
        let s = WKWebsiteDataStore(forIdentifier: identifier(uuid))
        s.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { done() }
    }
}
