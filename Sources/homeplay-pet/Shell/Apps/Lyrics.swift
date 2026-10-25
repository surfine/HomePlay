// 2.0 第四輪 #8：歌詞（LRCLIB，https://lrclib.net，免金鑰）。
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
    private var queue: [(Key, String, String, Double)] = []
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
        queue.append((k, title, artist, duration))
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
        let (k, title, artist, duration) = next
        guard let url = Self.requestURL(title: title, artist: artist, duration: duration) else { finish(k, .notFound, cache: false); return }
        inFlight = k
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let http = resp as? HTTPURLResponse
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = nil
                let code = http?.statusCode ?? 0
                switch code {
                case 200:
                    let isJSON = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").contains("json")
                    if isJSON, let d = data, let l = Self.decode(d) { self.finish(k, l.isEmpty ? .notFound : .ready(l), cache: true) }
                    else { self.finish(k, .failed, cache: false) }
                case 404:
                    self.finish(k, .notFound, cache: true)
                case 429, 503:
                    // 文件：一定照 Retry-After 等，再加最多 30% 隨機，免得大家同時重試
                    let s = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5
                    self.retryAfter = Date().addingTimeInterval(s * Double.random(in: 1...1.3))
                    self.queue.insert((k, title, artist, duration), at: 0)
                default:
                    self.finish(k, .failed, cache: false)
                }
                self.pump()
            }
        }.resume()
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
