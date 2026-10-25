// 鬧鐘、計時器、世界時鐘、對講：Mac 上沒有這四個 App 自己的圖示（2.0 P10：尋找、Safari 也收，Mac 上沒有那兩個 App 時當退路）（Mac 的「時鐘」只有一個總圖示），
// 使用者 2026-10-25 決定讀 HomeView 官網規格頁「Built-in Apps」上的官方圖示。
// 第一次用到時從 apple.com 抓下來，快取在 ~/Library/Caches/HomePlay/official-icons/（只在這台 Mac，不打包、不進倉庫、不上官網）；
// 抓不到就退回 HPIcons（照官網畫的版本）。網址帶版本雜湊：先讀規格頁找最新的，找不到才用寫死的那組。

import AppKit

enum OfficialIcons {
    /// App id → 官網圖檔名裡的名字
    /// 2.0 P10：尋找、Safari 也在規格頁上（Mac 上有這兩個 App 時先用系統圖示，這裡是退路）
    static let names: [String: String] = ["alarms": "alarms", "timers": "timers", "worldclock": "worldclock", "intercom": "intercom", "findmy": "findmy", "safari": "safari"]
    static let specsPage = URL(string: "https://www.apple.com/apple-homeview/specs/")!
    static let fallback: [String: String] = [
        "alarms": "https://www.apple.com/v/apple-homeview/a/images/specs/icon_alarms__dg6iltnuxis2_large_2x.png",
        "timers": "https://www.apple.com/v/apple-homeview/a/images/specs/icon_timers__e9gaxy1pzsia_large_2x.png",
        "worldclock": "https://www.apple.com/v/apple-homeview/a/images/specs/icon_worldclock__gku1l2korqqa_large_2x.png",
        "intercom": "https://www.apple.com/v/apple-homeview/a/images/specs/icon_intercom__s146w8zplwii_large_2x.png",
        "findmy": "https://www.apple.com/v/apple-homeview/a/images/specs/icon_findmy__fl5phjid7rue_large_2x.png",
        "safari": "https://www.apple.com/v/apple-homeview/a/images/specs/icon_safari__bh90x9wg9faq_large_2x.png",
    ]
    static var dir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("HomePlay/official-icons", isDirectory: true)
    }
    nonisolated(unsafe) private static var images: [String: CGImage] = [:]
    nonisolated(unsafe) private static var scaled: [String: CGImage] = [:]
    nonisolated(unsafe) private static var started = false
    /// 抓好之後叫這個重畫（主畫面靜態層要丟掉快取）
    nonisolated(unsafe) static var onLoaded: (() -> Void)?

    /// 這個 App 有官網圖示可用嗎（有就回裁好、縮好的圖）
    static func icon(_ appID: String?, px: Int) -> CGImage? {
        guard let id = appID, let name = names[id] else { return nil }
        let key = "\(id)|\(px)"
        if let c = scaled[key] { return c }
        if images[id] == nil, let img = load(name) { images[id] = img }
        guard let full = images[id] else { start(); return nil }
        let body = AppIconArt.opaqueBounds(full) ?? CGRect(x: 0, y: 0, width: full.width, height: full.height)
        guard let crop = full.cropping(to: body) else { return nil }
        let out = makeImage(px, px) { g in
            g.interpolationQuality = .high
            let r = CGRect(x: 0, y: 0, width: px, height: px)
            g.addPath(continuousRoundedRect(r, radius: CGFloat(px) * 0.2237)); g.clip()
            g.draw(crop, in: r.insetBy(dx: -CGFloat(px) * 0.004, dy: -CGFloat(px) * 0.004))
        }
        scaled[key] = out
        return out
    }

    private static func file(_ name: String) -> URL { dir.appendingPathComponent("\(name).png") }
    private static func load(_ name: String) -> CGImage? {
        guard let data = try? Data(contentsOf: file(name)), let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// 背景抓一次（這次執行只試一次；失敗就一直用 HPIcons）
    static func start() {
        guard !started, !Face.demoData || ProcessInfo.processInfo.environment["HOMEPLAY_OFFICIAL_ICONS"] != nil else { return }
        started = true
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var req = URLRequest(url: specsPage); req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let html = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let group = DispatchGroup()
            for (id, name) in names {
                let url = latest(name, in: html) ?? fallback[id].flatMap(URL.init(string:))
                guard let url else { continue }
                group.enter()
                URLSession.shared.dataTask(with: url) { d, resp, _ in
                    defer { group.leave() }
                    guard let d, (resp as? HTTPURLResponse)?.statusCode == 200, CGImageSourceCreateWithData(d as CFData, nil) != nil else { return }
                    try? d.write(to: file(name), options: .atomic)
                }.resume()
            }
            group.notify(queue: .main) {
                images.removeAll(); scaled.removeAll()
                log("official icons: \(names.values.filter { FileManager.default.fileExists(atPath: file($0).path) }.count)/\(names.count)")
                onLoaded?()
            }
        }.resume()
    }

    /// 規格頁 HTML 裡最新的 icon_<name>__<雜湊>_large_2x.png
    static func latest(_ name: String, in html: String) -> URL? {
        let pattern = "/v/apple-homeview/[^\"' ,]*?/images/specs/icon_\(name)__[a-z0-9]+_large_2x\\.png"
        guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let r = Range(m.range, in: html) else { return nil }
        return URL(string: "https://www.apple.com" + html[r])
    }
}

/// `homeplay-pet --fetch-official-icons`：抓一次官網圖示、等它抓完、印出結果就結束（驗證用）
func runFetchOfficialIcons() -> Never {
    var done = false
    OfficialIcons.onLoaded = { done = true }
    setenv("HOMEPLAY_OFFICIAL_ICONS", "1", 1)
    OfficialIcons.start()
    let end = Date().addingTimeInterval(40)
    while !done, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    for (_, n) in OfficialIcons.names.sorted(by: { $0.key < $1.key }) {
        let p = OfficialIcons.dir.appendingPathComponent("\(n).png").path
        let size = (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int) ?? nil
        print("official icon \(n): \(size.map { "\($0) bytes" } ?? "missing")")
    }
    exit(done ? 0 : 1)
}
