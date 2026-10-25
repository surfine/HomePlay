// 2.0 promo（HomeView 宣傳片第 2 拍「Or maybe you're trying a new recipe」）：iPhone 上 Safari 開著的網頁，拿到桌寵上。
//
// 官方 HomeView 用 Handoff（NSUserActivityTypeBrowsingWeb）：手機一靠近，網頁就跳過去。Mac 上這條路只交給「預設瀏覽器」
// （Dock 上那顆 Handoff 圖示），一般 App 不能宣告接 browsing-web，也不能讀 iCloud 分頁（沒有公開 API，私有資料庫不碰）。
// 所以我們走兩條公開、真的能用的路，介面上照實說是怎麼觸發的：
//   1. 通用剪貼板（Universal Clipboard）：在 iPhone 上「拷貝」網址 → 同一個 Apple 帳號、藍牙與 Wi‑Fi 開著、手機在附近時，
//      Mac 的剪貼板會收到一筆帶 com.apple.is-remote-clipboard 標記的內容（Maccy 也用這個標記分辨）。
//      我們只看 changeCount 與類型（不讀內容、不會跳系統的貼上提示）；是遠端來的、而且 detectedPatterns 說像網址，才讀那一筆。
//   2. 「傳到 HomePlay」捷徑：iPhone 的分享表單 → 捷徑用「取得 URL 內容」POST 到這台 Mac（區網、Bonjour），
//      帶一組只存在鑰匙圈的配對碼（HandoffServer.swift）。
// 兩條路最後都走 PhoneHandoff.receive：舊畫面放大 5%＋模糊淡出（Shell.beginTakeover，影片 1.17–1.83 s），Safari 開那一頁；
// 是食譜就停一下自動進封面（SafariApp.openHandoff）。網址不進日誌（只記網域）。

import AppKit

enum HandoffRoute: String { case universalClipboard, shortcut, demo }

extension Shell {
    /// 2.0 promo：接管先停住（PhoneHandoff 等網頁出圖才放開）；外殼看到它就不收掉 takeover
    nonisolated(unsafe) static var takeoverHeld = false
}

// MARK: - 純邏輯（--selftest 驗）

enum HandoffLogic {
    /// 只收 http／https、有網域、不太長的網址
    static func webURL(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.utf8.count <= 4096, let u = URL(string: t), let sc = u.scheme?.lowercased(), sc == "http" || sc == "https",
              let h = u.host, !h.isEmpty else { return nil }
        return u
    }

    /// 同一個網址短時間內又來一次（剪貼板與捷徑同時到、或重複拷貝）：不要再接管一次
    static func isRepeat(_ u: URL, last: (url: URL, at: Double)?, now: Double, window: Double = 8) -> Bool {
        guard let last else { return false }
        return last.url.absoluteString == u.absoluteString && now - last.at < window
    }

    // MARK: 區網 HTTP（捷徑送來的那一則，最多 16 KB）

    struct Request: Equatable {
        var method: String
        var path: String
        var headers: [String: String]   // 小寫的名字
        var body: Data
    }
    enum Parse: Equatable { case incomplete, bad, tooLarge, ok(Request) }
    static let maxRequest = 16 * 1024

    static func parse(_ data: Data) -> Parse {
        if data.count > maxRequest { return .tooLarge }
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return data.count > 8192 ? .bad : .incomplete }
        guard let head = String(data: data[data.startIndex..<headEnd.lowerBound], encoding: .utf8) else { return .bad }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard first.count == 3, first[2].hasPrefix("HTTP/1.") else { return .bad }
        var headers: [String: String] = [:]
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { return .bad }
            headers[l[..<c].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .bad }   // 捷徑送的是 Content-Length；chunked 不收
        let len = Int(headers["content-length"] ?? "0") ?? -1
        guard len >= 0 else { return .bad }
        if len > maxRequest { return .tooLarge }
        let bodyStart = headEnd.upperBound
        guard data.count - (bodyStart - data.startIndex) >= len else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + len)]
        return .ok(Request(method: String(first[0]).uppercased(), path: String(first[1]), headers: headers, body: Data(body)))
    }

    /// 配對碼：Authorization: Bearer <碼> 或 X-HomePlay-Token: <碼>；固定時間比對
    static func authorized(_ r: Request, token: String) -> Bool {
        guard !token.isEmpty else { return false }
        var given = r.headers["x-homeplay-token"] ?? ""
        if given.isEmpty, let a = r.headers["authorization"], a.lowercased().hasPrefix("bearer ") { given = String(a.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        func norm(_ s: String) -> [UInt8] { Array(s.uppercased().filter { $0 != "-" && $0 != " " }.utf8) }   // 顯示時每 4 字一組的「-」不算
        let a = norm(given), b = norm(token)
        guard !b.isEmpty else { return false }
        var diff = UInt8(a.count == b.count ? 0 : 1)
        for i in 0..<max(a.count, b.count) { diff |= (i < a.count ? a[i] : 0) ^ (i < b.count ? b[i] : 0) }
        return diff == 0
    }

    /// 本文裡的網址：JSON {"url": …}、表單 url=…、或純文字（分享表單常把標題和網址一起送）
    static func url(from r: Request) -> URL? {
        let text = String(data: r.body, encoding: .utf8) ?? ""
        if let o = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any] {
            for k in ["url", "URL", "link", "input"] { if let s = o[k] as? String, let u = webURL(s) ?? RecipesApp.url(fromText: s) { return u } }
        }
        if (r.headers["content-type"] ?? "").contains("x-www-form-urlencoded"), let c = URLComponents(string: "?" + text),
           let s = c.queryItems?.first(where: { $0.name == "url" })?.value, let u = webURL(s) { return u }
        return webURL(text) ?? RecipesApp.url(fromText: text)
    }

    /// 只收區網、本機來的連線（10/8、172.16/12、192.168/16、169.254/16、127/8、IPv6 的 fe80::/10、fc00::/7、::1）
    static func isLocal(_ host: String) -> Bool {
        var h = host.lowercased()
        if let p = h.firstIndex(of: "%") { h = String(h[..<p]) }   // fe80::1%en0
        if h.hasPrefix("::ffff:") { h = String(h.dropFirst(7)) }
        let v4 = h.split(separator: ".").compactMap { Int($0) }
        if v4.count == 4, h.split(separator: ".").count == 4 {
            switch (v4[0], v4[1]) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, let b): return (16...31).contains(b)
            default: return false
            }
        }
        if h == "::1" { return true }
        if h.hasPrefix("fe8") || h.hasPrefix("fe9") || h.hasPrefix("fea") || h.hasPrefix("feb") { return true }
        if h.hasPrefix("fc") || h.hasPrefix("fd") { return true }
        return false
    }

    static func response(_ code: Int, _ json: String) -> Data {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large", 429: "Too Many Requests", 503: "Service Unavailable"][code] ?? "Error"   // l10n-ignore：HTTP
        let body = Data(json.utf8)
        return Data("HTTP/1.1 \(code) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body   // l10n-ignore：HTTP
    }

    /// 配對碼：16 bytes 亂數 → Crockford base32 26 字（去掉 I L O U，抄碼不會看錯）
    static func newToken() -> String {
        var b = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, b.count, &b) != errSecSuccess { for i in b.indices { b[i] = UInt8.random(in: 0...255) } }
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var out = "", acc = 0, bits = 0
        for x in b { acc = (acc << 8) | Int(x); bits += 8; while bits >= 5 { bits -= 5; out.append(alphabet[(acc >> bits) & 31]) } }
        if bits > 0 { out.append(alphabet[(acc << (5 - bits)) & 31]) }
        return out
    }
}

// MARK: - 接進來

enum PhoneHandoff {
    /// 網頁排好後多久自動進食譜封面：放開接管 0.2 s＋淡出約 0.25 s＋停一下讓人看到是哪一頁（宣傳片：網頁清楚 1.83 s → 封面 2.33 s）
    static let coverDelay = 0.65
    nonisolated(unsafe) private static var last: (url: URL, at: Double)?
    nonisolated(unsafe) static var lastRoute: HandoffRoute?

    /// 主執行緒：舊畫面模糊放大淡出，Safari 開這一頁（食譜就自動進封面）
    static func receive(_ url: URL, via route: HandoffRoute, demoHTML: String? = nil) {
        guard let u = HandoffLogic.webURL(url.absoluteString), let v = (NSApp.delegate as? AppDelegate)?.view else { return }
        let now = CACurrentMediaTime()
        guard !HandoffLogic.isRepeat(u, last: last, now: now) else { return }
        guard !v.showingVideo, !v.carVideo.active else { return }   // CarPlay 畫面優先，不搶
        last = (u, now); lastRoute = route
        log("handoff \(route.rawValue) \(u.host ?? "?")")   // 只記網域
        Shell.lastActive = now
        if ClioTalkController.shared.isOpen { ClioTalkController.shared.close() }
        Shell.beginTakeover(v.face, now: now)
        // 影片：舊畫面先糊成一片淡白（1.17–1.5 s），網頁好了才浮出來（1.67–1.83 s）——停在模糊、半透明，等 pageProgress 放開
        if var t = Shell.takeover {
            t.anim = MotionValue("takeover", spring: Shell.takeoverSpring, from: 0, to: holdLevel, now: now)
            Shell.takeover = t; Shell.takeoverHeld = true; heldAt = now; readyAt = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + holdMax + 0.1) { if heldAt == now { release(CACurrentMediaTime()) } }   // 保險：一定放開
        }
        SafariApp.shared.openHandoff(u, demoHTML: demoHTML)
        if Shell.nav.screen != .app("safari") { v.shellOpenApp("safari") }
        v.face.forceDirty = true
    }

    /// 接管停在哪裡：0.45＝已經全糊、還剩 55% 不透明（drawTakeover：模糊在 0.4 前長滿）
    static let holdLevel: CGFloat = 0.45
    /// 網頁出第一張「排好版」的圖後再等一下（第一張常常是白的），最多等 4 秒
    static let revealAfter = 0.12, holdMax = 4.0
    nonisolated(unsafe) private static var heldAt: Double?
    nonisolated(unsafe) private static var readyAt: Double?

    /// SafariApp 每幀叫：網頁好了（或等太久）就放開接管，舊畫面淡掉、網頁浮出來
    static func pageProgress(ready: Bool, now: Double) {
        guard Shell.takeoverHeld, let h = heldAt else { return }
        if ready, readyAt == nil { readyAt = now }
        guard (readyAt.map { now - $0 >= revealAfter } ?? false) || now - h >= holdMax else { return }
        release(now)
    }
    static func release(_ now: Double) {
        Shell.takeoverHeld = false; heldAt = nil; readyAt = nil
        if var t = Shell.takeover { t.anim.retarget(1, now: now, spring: Spring.settling(0.3)); Shell.takeover = t }   // 網頁浮出：0.3 s（影片 1.67→1.83）
    }

    /// 開機時叫：照設定開兩條路
    static func start() {
        if HandoffSettings.clipboard { UniversalClipboardWatch.shared.start() }
        if HandoffSettings.shortcut { HandoffServer.shared.start() }
        if HandoffSettings.clipboard || HandoffSettings.shortcut { DispatchQueue.main.asyncAfter(deadline: .now() + 5) { SafariApp.shared.prewarm() } }
    }
}

// MARK: - 設定（UserDefaults 只放開關；配對碼在鑰匙圈）

enum HandoffSettings {
    static let clipboardKey = "handoff.universalClipboard", shortcutKey = "handoff.shortcut"
    static var clipboard: Bool {
        get { UserDefaults.standard.bool(forKey: clipboardKey) }
        set { UserDefaults.standard.set(newValue, forKey: clipboardKey); newValue ? UniversalClipboardWatch.shared.start() : UniversalClipboardWatch.shared.stop() }
    }
    static var shortcut: Bool {
        get { UserDefaults.standard.bool(forKey: shortcutKey) }
        set { UserDefaults.standard.set(newValue, forKey: shortcutKey); newValue ? HandoffServer.shared.start() : HandoffServer.shared.stop() }
    }
}

// MARK: - 通用剪貼板

final class UniversalClipboardWatch {
    static let shared = UniversalClipboardWatch()
    static let remoteType = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")
    private var timer: Timer?
    private var lastCount = 0
    var running: Bool { timer != nil }

    func start() {
        guard timer == nil, !SnapshotPrivacy.active else { return }
        lastCount = NSPasteboard.general.changeCount   // 開的時候已經在剪貼板上的不算
        let t = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        log("handoff: universal clipboard watch on")
    }
    func stop() { timer?.invalidate(); timer = nil }

    /// 只看 changeCount 與類型：不讀內容，系統不會跳「要貼上嗎」
    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        guard pb.types?.contains(Self.remoteType) == true else { return }   // 這台 Mac 自己拷貝的不理
        if #available(macOS 15.4, *) {
            let count = lastCount
            Task { @MainActor in
                guard let found = try? await pb.detectedPatterns(for: [\.probableWebURL]), found.contains(\.probableWebURL), pb.changeCount == count else { return }
                self.read(pb)
            }
        } else {
            read(pb)
        }
    }
    private func read(_ pb: NSPasteboard) {
        guard let u = RecipesApp.url(from: pb) else { return }
        PhoneHandoff.receive(u, via: .universalClipboard)
    }
}

// MARK: - 自檢

enum HandoffSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        check(HandoffLogic.webURL("https://www.example.com/recipes/loaf") != nil && HandoffLogic.webURL("file:///etc/hosts") == nil
              && HandoffLogic.webURL("javascript:alert(1)") == nil && HandoffLogic.webURL("https://") == nil, "Handoff：只收 http／https 網址")   // l10n-ignore：selftest 訊息
        let u = URL(string: "https://a.example/x")!
        check(HandoffLogic.isRepeat(u, last: (u, 10), now: 12) && !HandoffLogic.isRepeat(u, last: (u, 10), now: 30)
              && !HandoffLogic.isRepeat(URL(string: "https://a.example/y")!, last: (u, 10), now: 11), "Handoff：同一個網址 8 秒內只接管一次")   // l10n-ignore
        let body = #"{"url":"https://cooking.example.com/loaf-cake"}"#
        let raw = "POST /open HTTP/1.1\r\nHost: mac.local:47391\r\nAuthorization: Bearer abcd-1234\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"   // l10n-ignore
        guard case .ok(let r) = HandoffLogic.parse(Data(raw.utf8)) else { check(false, "Handoff：解析捷徑送來的 HTTP"); return }   // l10n-ignore
        check(r.method == "POST" && r.path == "/open" && HandoffLogic.url(from: r)?.host == "cooking.example.com", "Handoff：解析捷徑送來的 HTTP（JSON）")   // l10n-ignore
        check(HandoffLogic.authorized(r, token: "ABCD-1234") && !HandoffLogic.authorized(r, token: "ABCD-1235") && !HandoffLogic.authorized(r, token: "")
              && !HandoffLogic.authorized(r, token: "ABCD-12345"), "Handoff：配對碼（不分大小寫、長度不同不過、空碼不過）")   // l10n-ignore
        check(HandoffLogic.parse(Data(raw.utf8).prefix(raw.utf8.count - 5)) == .incomplete && HandoffLogic.parse(Data("GARBAGE\r\n\r\n".utf8)) == .bad
              && HandoffLogic.parse(Data(repeating: 65, count: HandoffLogic.maxRequest + 1)) == .tooLarge, "Handoff：半截等、亂的拒、太大拒")   // l10n-ignore
        let text = "Lemon-Blueberry Yogurt Loaf Cake https://cooking.example.com/loaf?ref=share"   // l10n-ignore
        let plain = "POST /open HTTP/1.1\r\nX-HomePlay-Token: T\r\nContent-Length: \(text.utf8.count)\r\n\r\n\(text)"   // l10n-ignore
        if case .ok(let p) = HandoffLogic.parse(Data(plain.utf8)) {
            check(HandoffLogic.authorized(p, token: "t") && HandoffLogic.url(from: p)?.path == "/loaf", "Handoff：分享表單的純文字裡找網址、X-HomePlay-Token")   // l10n-ignore
        } else { check(false, "Handoff：純文字本文") }   // l10n-ignore
        check(HandoffLogic.isLocal("192.168.1.20") && HandoffLogic.isLocal("10.0.0.5") && HandoffLogic.isLocal("172.20.1.1") && HandoffLogic.isLocal("fe80::1%en0")
              && HandoffLogic.isLocal("::ffff:192.168.0.9") && !HandoffLogic.isLocal("172.32.0.1") && !HandoffLogic.isLocal("8.8.8.8") && !HandoffLogic.isLocal("2001:db8::1"),
              "Handoff：只收區網來的連線")   // l10n-ignore
        let t1 = HandoffLogic.newToken(), t2 = HandoffLogic.newToken()
        check(t1.count == 26 && t1 != t2 && t1.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) }, "Handoff：配對碼 26 字 base32、每次不同")   // l10n-ignore
        let resp = String(data: HandoffLogic.response(401, #"{"ok":false}"#), encoding: .utf8) ?? ""
        check(resp.hasPrefix("HTTP/1.1 401 Unauthorized\r\n") && resp.hasSuffix("\r\n\r\n{\"ok\":false}"), "Handoff：HTTP 回應")   // l10n-ignore
    }
}
