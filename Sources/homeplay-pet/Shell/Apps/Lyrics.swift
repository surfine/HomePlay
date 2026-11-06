// 2.0 第四輪 #8：歌詞。來源是一條鏈（2026-11-06 使用者：不要綁死在一個來源、以終為始）：
//   LRCLIB 精確 → LRCLIB 搜尋 → 酷狗 → QQ 音樂，誰先給到就用誰。LRCLIB 是開放資料庫，粵語／華語歌收得少；
//   酷狗、QQ 音樂的歌詞介面照 LyricsX／LyricsKit（MPL-2.0）的做法（只參考端點與參數，程式自己寫）；網易雲現在要綁手機，不用。
//   每個來源都只送歌名、歌手（酷狗再加長度）；酷狗與 QQ 只收長度差 5 秒內的（排掉現場版、Acoustic 版），長度不知道就要歌名一樣。
// LRCLIB（https://lrclib.net，免金鑰）：
// - 只送三項：歌名、歌手、長度（GET /api/get?track_name=&artist_name=&duration=；長度不知道就不送）。不送專輯、不送任何識別資料。
// - User-Agent 照 LRCLIB 文件「Client identification」要求帶 App 名、版本、專案網址。
// - 文件的「Rate Limiting」：一次只發一個請求；429／503 一定照 Retry-After 等（加最多 30% 隨機），等的期間不再發。
// - 快取在 ~/Library/Application Support/HomePlay/Lyrics/<雜湊>.json；找不到（404）也記下來，3 天後才再問（LRCLIB 會在背景補抓）。
// - 設定裡可關（預設開）；關了就不連線、不讀快取。歌詞內容絕不寫進日誌。

import AppKit
import CryptoKit

/// 一首歌的歌詞：同步（有時間）或純文字
struct Lyrics: Equatable {
    struct Line: Equatable { var time: Double; var text: String }
    var synced: [Line]          // 依時間排好；空＝沒有同步歌詞
    var plain: [String]         // 純文字（沒有同步時用）
    var instrumental: Bool
    var isEmpty: Bool { synced.isEmpty && plain.isEmpty && !instrumental }
}

enum LRC {
    /// 解析 LRC：一行可以有好幾個時間標籤（[00:12.00][00:45.10]副歌）；[offset:±毫秒] 整體平移；[ar:] [ti:] 這類標籤略過。
    /// 時間格式：[mm:ss]、[mm:ss.x]、[mm:ss.xx]、[mm:ss.xxx]、[mm:ss:xx]。空白歌詞行保留（間奏，畫成「• • •」）。
    static func parse(_ text: String) -> [Lyrics.Line] {
        var out: [Lyrics.Line] = []
        var offset = 0.0
        for raw in text.components(separatedBy: .newlines) {
            var rest = Substring(raw.trimmingCharacters(in: .whitespaces))
            var stamps: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
                if let t = time(tag) { stamps.append(t); continue }
                let lower = tag.lowercased()
                if lower.hasPrefix("offset:"), let ms = Double(lower.dropFirst(7).trimmingCharacters(in: .whitespaces)) { offset = ms / 1000 }
            }
            let line = rest.trimmingCharacters(in: .whitespaces)
            for t in stamps { out.append(Lyrics.Line(time: t, text: line)) }
        }
        // offset 正值＝歌詞提早出現（LRC 慣例）
        return out.map { Lyrics.Line(time: max(0, $0.time - offset), text: $0.text) }
            .enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
    }

    /// 「mm:ss.xx」→ 秒；不是時間回 nil
    static func time<S: StringProtocol>(_ tag: S) -> Double? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3, let m = Int(parts[0]), m >= 0 else { return nil }
        var secPart = String(parts[1]), frac = ""
        if parts.count == 3 { frac = String(parts[2]) }
        else if let dot = secPart.firstIndex(of: ".") { frac = String(secPart[secPart.index(after: dot)...]); secPart = String(secPart[..<dot]) }
        guard let s = Int(secPart), s >= 0, s < 60, frac.allSatisfy(\.isNumber) else { return nil }
        let f = frac.isEmpty ? 0 : (Double("0." + frac) ?? 0)
        return Double(m * 60 + s) + f
    }

    /// 目前唱到第幾句：時間 ≤ t 的最後一句；第一句之前回 -1（二分搜尋）
    static func index(_ lines: [Lyrics.Line], at t: Double) -> Int {
        var lo = 0, hi = lines.count
        while lo < hi { let mid = (lo + hi) / 2; if lines[mid].time <= t { lo = mid + 1 } else { hi = mid } }
        return lo - 1
    }
}

final class LyricsStore {
    static let shared = LyricsStore()

    /// 設定「歌詞」開關（預設開）
    static let defaultsKey = "HomePlayLyricsOn"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey); if !newValue { shared.memory.removeAll() } }
    }

    enum State: Equatable { case loading, ready(Lyrics), notFound, failed, off }

    /// 一首歌的身分（快取鍵）：歌名、歌手小寫去空白，長度取整秒
    struct Key: Hashable { var title: String; var artist: String; var duration: Int }
    static func key(title: String, artist: String, duration: Double) -> Key {
        func n(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return Key(title: n(title), artist: n(artist), duration: duration > 0 ? Int(duration.rounded()) : 0)
    }

    /// 請求網址（純函式，自檢用）：只有 track_name、artist_name、duration 三項
    static func requestURL(title: String, artist: String, duration: Double) -> URL? {
        // URLComponents.queryItems 不會編「&」「=」「+」：自己編（歌名裡常有 &）
        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "&=+?#")
        func e(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        var q = "track_name=\(e(title))&artist_name=\(e(artist))"
        let d = Int(duration.rounded())
        if d >= 1, d <= 3600 { q += "&duration=\(d)" }
        return URL(string: "https://lrclib.net/api/get?" + q)
    }
    /// 精確查不到（404）時的第二次：LRCLIB 的 /api/search（同樣只送歌名、歌手）——手機／CarPlay 給的長度常差幾秒、或歌名寫法不同
    static func searchURL(title: String, artist: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "&=+?#")
        func e(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return URL(string: "https://lrclib.net/api/search?track_name=\(e(title))&artist_name=\(e(artist))")
    }
    /// 搜尋結果挑一首：要有歌詞（或純音樂）；知道長度就只收 ±5 秒內、取最接近的（純函式，自檢用）
    static func pickSearch(_ data: Data, duration: Double) -> Lyrics? {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        let usable = arr.filter { o in
            (o["instrumental"] as? Bool) == true || !((o["syncedLyrics"] as? String) ?? "").isEmpty || !((o["plainLyrics"] as? String) ?? "").isEmpty
        }
        let pick: [String: Any]?
        if duration >= 1 {
            pick = usable.compactMap { o -> ([String: Any], Double)? in
                guard let d = o["duration"] as? Double, abs(d - duration) <= 5 else { return nil }
                return (o, abs(d - duration))
            }.min { $0.1 < $1.1 }?.0
        } else { pick = usable.first }
        guard let pick, let d = try? JSONSerialization.data(withJSONObject: pick) else { return nil }
        return decode(d)
    }

    /// LRCLIB 回應 → 歌詞（純函式，自檢用）
    static func decode(_ data: Data) -> Lyrics? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let synced = (o["syncedLyrics"] as? String).map(LRC.parse) ?? []
        let plain = (o["plainLyrics"] as? String)?.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        var trimmed = plain
        while trimmed.last?.isEmpty == true { trimmed.removeLast() }
        while trimmed.first?.isEmpty == true { trimmed.removeFirst() }
        return Lyrics(synced: synced, plain: trimmed, instrumental: o["instrumental"] as? Bool ?? false)
    }

    static var userAgent: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0"
        return "HomePlay/\(v) (https://github.com/surfine/HomePlay)"   // l10n-ignore
    }

    private var memory: [Key: State] = [:]
    private var inFlight: Key?
    /// 一首歌在來源鏈上走到哪一步
    enum Step: Equatable { case lrclibGet, lrclibSearch, kugouSearch, kugouDownload(id: String, key: String), qqSearch, qqLyric(mid: String) }
    private var queue: [(Key, String, String, Double, Step)] = []
    private var retryAfter = Date.distantPast
    /// 拿到結果（主執行緒）；畫面用它重畫
    var onUpdate: (() -> Void)?
    /// 自檢／快照：不連網、不寫碟
    nonisolated(unsafe) static var offline = false

    static let notFoundTTL: TimeInterval = 3 * 24 * 3600

    private static var dir: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("HomePlay/Lyrics", isDirectory: true)
    }
    private static func file(_ k: Key) -> URL? {
        let h = SHA256.hash(data: Data("\(k.title)\u{1f}\(k.artist)\u{1f}\(k.duration)".utf8)).map { String(format: "%02x", $0) }.joined()
        return dir?.appendingPathComponent(String(h.prefix(32)) + ".json")
    }

    /// 給快照用：直接放一份
    func inject(_ l: Lyrics?, title: String, artist: String, duration: Double) {
        memory[Self.key(title: title, artist: artist, duration: duration)] = l.map { .ready($0) } ?? .notFound
    }

    /// 這首歌的歌詞狀態；還沒有就排一個請求
    func state(title: String, artist: String, duration: Double) -> State {
        guard Self.enabled else { return .off }
        let k = Self.key(title: title, artist: artist, duration: duration)
        // 2.0 depth：網路斷一下而失敗的歌，過 60 秒再問一次（不然整個工作階段這首歌都沒歌詞）
        if let s = memory[k], s != .failed || Date().timeIntervalSince(failedAt[k] ?? .distantPast) < 60 { return s }
        if let cached = Self.readCache(k) { memory[k] = cached; return cached }
        guard !Self.offline, !title.isEmpty, !artist.isEmpty else { memory[k] = .notFound; return .notFound }
        memory[k] = .loading
        queue.append((k, title, artist, duration, .lrclibGet))
        pump()
        return .loading
    }

    private func pump() {
        guard inFlight == nil, let next = queue.first else { return }
        let wait = retryAfter.timeIntervalSinceNow
        if wait > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.pump() }
            return
        }
        queue.removeFirst()
        let (k, title, artist, duration, step) = next
        guard let req = Self.request(step, title: title, artist: artist, duration: duration) else { advance(k, title, artist, duration, after: step); return }
        inFlight = k
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let http = resp as? HTTPURLResponse
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = nil
                self.handle(k, title, artist, duration, step, code: http?.statusCode ?? 0, data: data,
                            retryAfter: http?.value(forHTTPHeaderField: "Retry-After"))
                self.pump()
            }
        }.resume()
    }

    /// 每一步的請求（純函式）：LRCLIB 帶 App 的 User-Agent；酷狗、QQ 照它們網頁播放器的寫法
    static func request(_ step: Step, title: String, artist: String, duration: Double) -> URLRequest? {
        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "&=+?#")
        func e(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let browser = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        let ms = duration >= 1 ? "&duration=\(Int(duration * 1000))" : ""
        let url: URL?, ua: String
        var referer: String?
        switch step {
        case .lrclibGet: url = requestURL(title: title, artist: artist, duration: duration); ua = userAgent
        case .lrclibSearch: url = searchURL(title: title, artist: artist); ua = userAgent
        case .kugouSearch: url = URL(string: "https://lyrics.kugou.com/search?ver=1&man=yes&client=pc&keyword=\(e("\(artist) - \(title)"))\(ms)"); ua = browser
        case .kugouDownload(let id, let key): url = URL(string: "https://lyrics.kugou.com/download?ver=1&client=pc&id=\(e(id))&accesskey=\(e(key))&fmt=lrc&charset=utf8"); ua = browser
        case .qqSearch: url = URL(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?format=json&p=1&n=10&w=\(e("\(title) \(artist)"))"); ua = browser
        case .qqLyric(let mid): url = URL(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?format=json&nobase64=1&g_tk=5381&songmid=\(e(mid))"); ua = browser
            referer = "https://y.qq.com/portal/player.html"
        }
        guard let url else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 12)
        r.setValue(ua, forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let referer { r.setValue(referer, forHTTPHeaderField: "Referer") }
        return r
    }

    private func handle(_ k: Key, _ title: String, _ artist: String, _ duration: Double, _ step: Step, code: Int, data: Data?, retryAfter: String?) {
        // 網路根本沒通：整首算失敗（60 秒後再問），不往下一個來源跑
        if code == 0 { return finish(k, .failed, cache: false) }
        if step == .lrclibGet || step == .lrclibSearch, code == 429 || code == 503 {
            // LRCLIB 文件：一定照 Retry-After 等，再加最多 30% 隨機，免得大家同時重試
            let s = Double(retryAfter ?? "") ?? 5
            self.retryAfter = Date().addingTimeInterval(s * Double.random(in: 1...1.3))
            queue.insert((k, title, artist, duration, step), at: 0)
            return
        }
        let d = code == 200 ? data : nil
        switch step {
        case .lrclibGet:
            if let d, let l = Self.decode(d), !l.isEmpty { return finish(k, .ready(l), cache: true) }
        case .lrclibSearch:
            if let d, let l = Self.pickSearch(d, duration: duration), !l.isEmpty { return finish(k, .ready(l), cache: true) }
        case .kugouSearch:
            if let d, let c = Self.kugouPick(d, title: title, duration: duration) { queue.insert((k, title, artist, duration, .kugouDownload(id: c.id, key: c.key)), at: 0); return }
        case .kugouDownload:
            if let d, let t = Self.kugouLRC(d) { let l = Lyrics(synced: LRC.parse(t), plain: [], instrumental: false); if !l.isEmpty { return finish(k, .ready(l), cache: true) } }
        case .qqSearch:
            if let d, let mid = Self.qqPick(d, title: title, duration: duration) { queue.insert((k, title, artist, duration, .qqLyric(mid: mid)), at: 0); return }
        case .qqLyric:
            if let d, let t = Self.qqLRC(d) { let l = Lyrics(synced: LRC.parse(t), plain: [], instrumental: false); if !l.isEmpty { return finish(k, .ready(l), cache: true) } }
        }
        advance(k, title, artist, duration, after: step)
    }

    /// 這個來源沒有：換下一個；全部問完才算沒有歌詞（記 3 天）
    private func advance(_ k: Key, _ title: String, _ artist: String, _ duration: Double, after step: Step) {
        let next: Step?
        switch step {
        case .lrclibGet: next = .lrclibSearch
        case .lrclibSearch: next = .kugouSearch
        case .kugouSearch, .kugouDownload: next = .qqSearch
        case .qqSearch, .qqLyric: next = nil
        }
        if let next { queue.insert((k, title, artist, duration, next), at: 0) } else { finish(k, .notFound, cache: true) }
    }

    // MARK: 酷狗、QQ 的回應（純函式，自檢用）

    /// 長度差 5 秒內（知道長度時）；不知道長度就要歌名一樣（不分大小寫、空白）
    static func matches(_ cand: String, _ candSeconds: Double, title: String, duration: Double) -> Bool {
        if duration >= 1 { return abs(candSeconds - duration) <= 5 }
        func n(_ s: String) -> String { s.lowercased().filter { !$0.isWhitespace } }
        return n(cand) == n(title)
    }
    static func kugouPick(_ data: Data, title: String, duration: Double) -> (id: String, key: String)? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let cs = o["candidates"] as? [[String: Any]] else { return nil }
        for c in cs {
            guard let key = c["accesskey"] as? String, let idAny = c["id"] else { continue }
            let id = "\(idAny)", ms = (c["duration"] as? Double) ?? Double("\(c["duration"] ?? 0)") ?? 0
            if matches(c["song"] as? String ?? "", ms / 1000, title: title, duration: duration) { return (id, key) }
        }
        return nil
    }
    static func kugouLRC(_ data: Data) -> String? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], (o["status"] as? Int) == 200,
              let b = o["content"] as? String, let raw = Data(base64Encoded: b), let t = String(data: raw, encoding: .utf8), !t.isEmpty else { return nil }
        return t
    }
    static func qqPick(_ data: Data, title: String, duration: Double) -> String? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = ((o["data"] as? [String: Any])?["song"] as? [String: Any])?["list"] as? [[String: Any]] else { return nil }
        for s in list {
            guard let mid = s["songmid"] as? String else { continue }
            let secs = (s["interval"] as? Double) ?? Double("\(s["interval"] ?? 0)") ?? 0
            if matches(s["songname"] as? String ?? "", secs, title: title, duration: duration) { return mid }
        }
        return nil
    }
    static func qqLRC(_ data: Data) -> String? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], (o["retcode"] as? Int) == 0,
              let t = o["lyric"] as? String, !t.isEmpty else { return nil }
        return htmlUnescape(t)
    }
    /// QQ 的歌詞夾著 HTML 實體（&#58; &#10; &apos; 之類）
    static func htmlUnescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = "", i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].firstIndex(of: ";"), s.distance(from: i, to: semi) <= 8 {
                let ent = String(s[s.index(after: i)..<semi])
                var ch: String?
                if ent.hasPrefix("#x") { ch = UInt32(ent.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } }
                else if ent.hasPrefix("#") { ch = UInt32(ent.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) } }
                else { ch = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "][ent] }
                if let ch { out += ch; i = s.index(after: semi); continue }
            }
            out.append(s[i]); i = s.index(after: i)
        }
        return out
    }

    private var failedAt: [Key: Date] = [:]
    private func finish(_ k: Key, _ s: State, cache: Bool) {
        memory[k] = s
        if s == .failed { failedAt[k] = Date() } else { failedAt[k] = nil }
        if cache { Self.writeCache(k, s) }
        onUpdate?()
    }

    // MARK: 快取（JSON：synced [[t, text]]、plain、instrumental、notFound、at）

    private static func readCache(_ k: Key) -> State? {
        guard !offline, let f = file(k), let d = try? Data(contentsOf: f),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        if o["notFound"] as? Bool == true {
            let at = o["at"] as? Double ?? 0
            return Date().timeIntervalSince1970 - at < notFoundTTL ? State.notFound : nil
        }
        let synced = (o["synced"] as? [[Any]] ?? []).compactMap { a -> Lyrics.Line? in
            guard a.count == 2, let t = a[0] as? Double, let s = a[1] as? String else { return nil }
            return Lyrics.Line(time: t, text: s)
        }
        return .ready(Lyrics(synced: synced, plain: o["plain"] as? [String] ?? [], instrumental: o["instrumental"] as? Bool ?? false))
    }

    private static func writeCache(_ k: Key, _ s: State) {
        guard !offline, let dir, let f = file(k) else { return }
        var o: [String: Any] = ["at": Date().timeIntervalSince1970]
        switch s {
        case .ready(let l):
            o["synced"] = l.synced.map { [$0.time, $0.text] as [Any] }; o["plain"] = l.plain; o["instrumental"] = l.instrumental
        case .notFound: o["notFound"] = true
        default: return
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: o) { try? d.write(to: f, options: .atomic) }
    }
}

enum LyricsSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        let l = LRC.parse("[ar:Someone]\n[ti:Song]\n[00:01.50]first\n[00:10.00][01:00.25] chorus \n[00:05]second\n[00:07.123]third\n[00:08:50]\nnot a line\n[xx:yy]bad")
        check(l.map(\.text) == ["first", "second", "third", "", "chorus", "chorus"], "歌詞：LRC 依時間排、一行多個時間、空行保留、標籤略過")
        check(l.map(\.time) == [1.5, 5, 7.123, 8.5, 10, 60.25], "歌詞：mm:ss、.x、.xxx、:xx 四種寫法")
        let off = LRC.parse("[offset:+500]\n[00:02.00]a\n[00:00.20]b")
        check(off.map(\.time) == [0, 1.5], "歌詞：offset 正值提早出現、不小於 0")
        check(LRC.index(l, at: 0) == -1 && LRC.index(l, at: 1.5) == 0 && LRC.index(l, at: 9.99) == 3 && LRC.index(l, at: 10) == 4 && LRC.index(l, at: 999) == 5,
              "歌詞：目前那一句（第一句前 -1、剛好到點就換句）")   // l10n-ignore：自檢
        check(LRC.index([], at: 5) == -1, "歌詞：空的不崩")
        let u = LyricsStore.requestURL(title: "Song & Name", artist: "Ä Artist", duration: 213.6)?.absoluteString ?? ""
        let names = URLComponents(string: u)?.queryItems?.map(\.name) ?? []
        check(u.hasPrefix("https://lrclib.net/api/get?") && names == ["track_name", "artist_name", "duration"] && u.contains("duration=214") && u.contains("Song%20%26%20Name"), "歌詞：只送歌名、歌手、長度")
        check(!(LyricsStore.requestURL(title: "a", artist: "b", duration: 0)?.absoluteString ?? "").contains("duration"), "歌詞：長度不知道就不送")
        let body = #"{"id":1,"trackName":"x","instrumental":false,"plainLyrics":"\nA\nB\n\n","syncedLyrics":"[00:01.00]A\n[00:02.00]B"}"#
        let d = LyricsStore.decode(Data(body.utf8))
        check(d?.synced.count == 2 && d?.plain == ["A", "B"] && d?.instrumental == false, "歌詞：LRCLIB 回應解析")
        check(LyricsStore.decode(Data(#"{"instrumental":true,"plainLyrics":null,"syncedLyrics":null}"#.utf8))?.instrumental == true, "歌詞：純音樂")
        let found = #"[{"duration":200,"plainLyrics":"far"},{"duration":223.5,"plainLyrics":"near"},{"duration":222,"plainLyrics":null,"syncedLyrics":null}]"#
        check(LyricsStore.pickSearch(Data(found.utf8), duration: 222)?.plain == ["near"] && LyricsStore.pickSearch(Data(found.utf8), duration: 100) == nil
              && LyricsStore.searchURL(title: "a&b", artist: "c")?.absoluteString.contains("/api/search?track_name=a%26b&artist_name=c") == true,
              "歌詞：精確查不到再 search，只收 ±5 秒、有歌詞的")   // l10n-ignore
        let kg = #"{"candidates":[{"id":1,"accesskey":"A","song":"x","duration":90000},{"id":572264787,"accesskey":"E3CE","song":"黄言","duration":224000}]}"#   // l10n-ignore
        check(LyricsStore.kugouPick(Data(kg.utf8), title: "黄言", duration: 223)?.key == "E3CE" && LyricsStore.kugouPick(Data(kg.utf8), title: "黄言", duration: 400) == nil   // l10n-ignore
              && LyricsStore.kugouPick(Data(kg.utf8), title: "黄言", duration: 0)?.key == "E3CE",   // l10n-ignore
              "歌詞：酷狗只收長度差 5 秒內的")   // l10n-ignore
        let lrc = Data("[00:01.00]A".utf8).base64EncodedString()
        check(LyricsStore.kugouLRC(Data(#"{"status":200,"content":"\#(lrc)"}"#.utf8)) == "[00:01.00]A" && LyricsStore.kugouLRC(Data(#"{"status":403}"#.utf8)) == nil,
              "歌詞：酷狗歌詞 base64 解開")   // l10n-ignore
        let qq = #"{"data":{"song":{"list":[{"songmid":"live","songname":"黄言 (Acoustic Live)","interval":90},{"songmid":"002A","songname":"黄言","interval":224}]}}}"#   // l10n-ignore
        check(LyricsStore.qqPick(Data(qq.utf8), title: "黄言", duration: 223) == "002A" && LyricsStore.qqPick(Data(qq.utf8), title: "黄言", duration: 0) == "002A",   // l10n-ignore
              "歌詞：QQ 排掉現場版；不知道長度就比歌名")   // l10n-ignore
        check(LyricsStore.qqLRC(Data(#"{"retcode":0,"lyric":"[00&#58;01.00]A&apos;s"}"#.utf8)) == "[00:01.00]A's" && LyricsStore.htmlUnescape("a&amp;b&#x4E2D;") == "a&b中",
              "歌詞：QQ 歌詞的 HTML 實體還原")   // l10n-ignore
        check(LyricsStore.request(.qqLyric(mid: "m"), title: "t", artist: "a", duration: 0)?.value(forHTTPHeaderField: "Referer") != nil
              && LyricsStore.request(.kugouSearch, title: "t", artist: "a", duration: 0)?.url?.absoluteString.contains("duration") == false,
              "歌詞：QQ 帶 Referer；長度不知道酷狗就不送")   // l10n-ignore
        check(LyricsStore.key(title: " Hello ", artist: "ADELE", duration: 295.4) == LyricsStore.key(title: "hello", artist: "adele", duration: 295), "歌詞：快取鍵不分大小寫")
        // MediaRemote：解析 perl 迴圈的一行、倍速循環
        let np = MRNowPlaying.parse("NP\t1\tEp 12\tShow\tAlbum\t1800\t100\t1.5\t1\t1000\tcom.apple.podcasts\t42\tid1")
        check(np?.title == "Ep 12" && np?.rate == 1.5 && np?.bundle == "com.apple.podcasts" && np?.pid == 42, "MediaRemote：一行解析")
        let pos = np?.info(wallNow: 1010, now: 0).position ?? 0
        check(abs(pos - 115) < 0.001 && np?.info(wallNow: 1010, now: 0).rate == 1.5, "MediaRemote：位置照倍速推到現在")
        check(MRNowPlaying.parse("NONE") == nil && MRNowPlaying.parse("NP\t0\t\t\t\t0\t0\t0\t0\t0\t\t0\t") == nil, "MediaRemote：沒在播／沒歌名")
        check(MediaRemote.nextRate(after: 1) == 1.25 && MediaRemote.nextRate(after: 2) == 0.75 && MediaRemote.nextRate(after: 0.75) == 1 && MediaRemote.nextRate(after: 1.7) == 1,
              "MediaRemote：倍速 1 → 1.25 → 1.5 → 2 → 0.75 → 1")   // l10n-ignore：自檢
        check(MediaRemote.rateLabel(1) == "1×" && MediaRemote.rateLabel(1.25) == "1.25×" && MediaRemote.rateLabel(1.5) == "1.5×", "MediaRemote：倍速標籤")
    }
}
