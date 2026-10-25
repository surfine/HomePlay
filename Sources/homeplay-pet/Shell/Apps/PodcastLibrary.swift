// 2.0 v2-music：Mac 上「播客」的待播清單、節目、單集——macOS 沒有公開介面（Podcasts.app 沒有 AppleScript 字典：`sdef` 回 -192；
// MusicKit 不含播客），所以照 iLEAPP（MIT）等鑑識工具的做法讀「播客」自己的本機資料庫：
//   ~/Library/Group Containers/243LU875E5.groups.com.apple.podcasts/Documents/MTLibrary.sqlite（Core Data 的 SQLite）
// 規則：
// - 只在使用者在播客 App 裡按「顯示我的播客」之後才讀（記在 UserDefaults；資料庫頁最底下「停止读取」可收回）；快照與 --demo 一律不讀，用示範資料。
// - SQLITE_OPEN_READONLY 開啟、只下 SELECT，不寫、不複製檔案、不連網；讀到的節目與單集只在記憶體，不寫日誌。
// - 欄位是 Apple 的私有結構（ZMTEPISODE／ZMTPODCAST，這台 macOS 27 核對過欄位名）；查詢失敗就老實說「讀不到」，不猜。
// - 播一集：交給「播客」打開那一集的頁面（podcasts.apple.com 的 id 與 i= 參數），在那裡按播放——沒有公開的路能叫它直接播某一集。

import AppKit
import SQLite3

struct PodcastShow: Equatable {
    var id: Int64
    var title: String
    var author: String
    var storeID: Int64
}

struct PodcastEpisode: Equatable {
    var title: String
    var show: String
    var duration: Double
    var playhead: Double
    var published: Date?
    var storeTrackID: Int64
    var storeCollectionID: Int64
    var played: Bool

    /// 「还剩 12 分钟」「48 分钟」「已播放」
    var detail: String {
        if played { return L("podcasts.played", "已播放") }
        let left = max(0, duration - playhead)
        let m = Int((left / 60).rounded(.up))
        if playhead > 30, duration > 0 { return String(format: L("podcasts.minutesLeft", "还剩 %d 分钟"), max(1, m)) }
        return duration > 0 ? String(format: L("podcasts.minutes", "%d 分钟"), max(1, m)) : ""
    }
    var progress: Double? { duration > 0 && playhead > 30 && !played ? min(1, playhead / duration) : nil }
    /// 在「播客」裡打開這一集（沒有商店 id 就只打開 App）
    var url: URL? {
        guard storeCollectionID > 0 else { return nil }
        var s = "podcasts://podcasts.apple.com/podcast/id\(storeCollectionID)"
        if storeTrackID > 0 { s += "?i=\(storeTrackID)" }
        return URL(string: s)
    }
}

final class PodcastLibrary {
    static let shared = PodcastLibrary()
    enum State: Equatable { case off, loading, ready, missing, failed }
    static let consentKey = "HomePlayPodcastsLibraryOK"
    /// 快照與自檢用（快照一律當作沒同意，不讀使用者的設定）
    nonisolated(unsafe) static var allowedOverride: Bool?
    static var allowed: Bool {
        get { allowedOverride ?? (SnapshotPrivacy.active ? false : UserDefaults.standard.bool(forKey: consentKey)) }
        set { if SnapshotPrivacy.active { allowedOverride = newValue } else { UserDefaults.standard.set(newValue, forKey: consentKey) } }
    }
    static var path: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Group Containers/243LU875E5.groups.com.apple.podcasts/Documents/MTLibrary.sqlite")
    }

    private(set) var state: State = .off
    private(set) var upNext: [PodcastEpisode] = []
    private(set) var shows: [PodcastShow] = []
    private(set) var episodes: [Int64: [PodcastEpisode]] = [:]
    var demo = false
    private var loadedAt = -1e9
    private let queue = DispatchQueue(label: "homeplay.podcasts.library", qos: .utility)
    var onChange: (() -> Void)?

    func refresh(force: Bool = false) {
        if demo { return }
        guard Self.allowed, !SnapshotPrivacy.active else { state = .off; return }
        if state == .loading || (!force && state == .ready && CACurrentMediaTime() - loadedAt < 30) { return }
        guard FileManager.default.fileExists(atPath: Self.path) else { state = .missing; return }
        state = .loading
        queue.async { [weak self] in
            let r = Self.read(Self.path)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadedAt = CACurrentMediaTime()
                if let r { self.upNext = r.0; self.shows = r.1; self.episodes = [:]; self.state = .ready } else { self.state = .failed }
                self.onChange?()
            }
        }
    }

    func loadEpisodes(_ show: PodcastShow) {
        if demo || episodes[show.id] != nil || !Self.allowed { return }
        queue.async { [weak self] in
            let list = Self.withDB(Self.path) { db in Self.episodes(db, show: show) } ?? []
            DispatchQueue.main.async { self?.episodes[show.id] = list; self?.onChange?() }
        }
    }

    // MARK: SQLite（唯讀）

    private static func withDB<T>(_ path: String, _ body: (OpaquePointer) -> T?) -> T? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1500)
        return body(db)
    }
    private static func rows(_ db: OpaquePointer, _ sql: String, bind: Int64? = nil, _ each: (OpaquePointer) -> Void) -> Bool {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return false }
        defer { sqlite3_finalize(st) }
        if let bind { sqlite3_bind_int64(st, 1, bind) }
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_ROW { each(st) } else { return rc == SQLITE_DONE }
        }
    }
    private static func text(_ st: OpaquePointer, _ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }
    private static func date(_ st: OpaquePointer, _ i: Int32) -> Date? {
        sqlite3_column_type(st, i) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(st, i))   // Core Data：2001 起的秒
    }

    static func read(_ path: String) -> ([PodcastEpisode], [PodcastShow])? {
        withDB(path) { db in
            var up: [PodcastEpisode] = [], shows: [PodcastShow] = []
            let ok1 = rows(db, """
                SELECT e.ZTITLE, p.ZTITLE, e.ZDURATION, e.ZPLAYHEAD, e.ZPUBDATE, e.ZSTORETRACKID, p.ZSTORECOLLECTIONID, e.ZHASBEENPLAYED
                FROM ZMTEPISODE e JOIN ZMTPODCAST p ON p.Z_PK = e.ZPODCAST
                WHERE e.ZLISTENNOWEPISODE = 1 AND IFNULL(e.ZISHIDDEN, 0) = 0
                ORDER BY e.ZUPNEXTSCORE DESC, e.ZLASTDATEPLAYED DESC LIMIT 30
                """) { st in
                up.append(PodcastEpisode(title: text(st, 0), show: text(st, 1), duration: sqlite3_column_double(st, 2), playhead: sqlite3_column_double(st, 3),
                                         published: date(st, 4), storeTrackID: sqlite3_column_int64(st, 5), storeCollectionID: sqlite3_column_int64(st, 6),
                                         played: sqlite3_column_int(st, 7) != 0))
            }
            let ok2 = rows(db, """
                SELECT p.Z_PK, p.ZTITLE, p.ZAUTHOR, p.ZSTORECOLLECTIONID FROM ZMTPODCAST p
                WHERE IFNULL(p.ZHIDDEN, 0) = 0 AND (p.ZSUBSCRIBED = 1 OR p.ZLASTDATEPLAYED IS NOT NULL)
                ORDER BY p.ZLASTDATEPLAYED DESC LIMIT 60
                """) { st in
                shows.append(PodcastShow(id: sqlite3_column_int64(st, 0), title: text(st, 1), author: text(st, 2), storeID: sqlite3_column_int64(st, 3)))
            }
            guard ok1, ok2 else { return nil }
            return (up.filter { !$0.title.isEmpty }, shows.filter { !$0.title.isEmpty })
        }
    }

    private static func episodes(_ db: OpaquePointer, show: PodcastShow) -> [PodcastEpisode]? {
        var out: [PodcastEpisode] = []
        let ok = rows(db, """
            SELECT e.ZTITLE, e.ZDURATION, e.ZPLAYHEAD, e.ZPUBDATE, e.ZSTORETRACKID, e.ZHASBEENPLAYED FROM ZMTEPISODE e
            WHERE e.ZPODCAST = ? AND IFNULL(e.ZISHIDDEN, 0) = 0 ORDER BY e.ZPUBDATE DESC LIMIT 40
            """, bind: show.id) { st in
            out.append(PodcastEpisode(title: text(st, 0), show: show.title, duration: sqlite3_column_double(st, 1), playhead: sqlite3_column_double(st, 2),
                                      published: date(st, 3), storeTrackID: sqlite3_column_int64(st, 4), storeCollectionID: show.storeID,
                                      played: sqlite3_column_int(st, 5) != 0))
        }
        return ok ? out.filter { !$0.title.isEmpty } : nil
    }

    // MARK: 示範（--demo-podcasts；節目與單集都是自己編的）

    func applyDemo() {
        demo = true; state = .ready
        let d = Date(timeIntervalSinceReferenceDate: 812_000_000)
        upNext = [
            PodcastEpisode(title: "Capsaicin, Explained", show: "Field Notes", duration: 3664, playhead: 2443, published: d, storeTrackID: 0, storeCollectionID: 0, played: false),
            PodcastEpisode(title: "The Bread Episode", show: "Kitchen Table", duration: 2410, playhead: 0, published: d, storeTrackID: 0, storeCollectionID: 0, played: false),
            PodcastEpisode(title: "Why Owls Turn Their Heads", show: "Small Wonders", duration: 1520, playhead: 610, published: d, storeTrackID: 0, storeCollectionID: 0, played: false),
        ]   // l10n-ignore：示範節目
        shows = [PodcastShow(id: 1, title: "Field Notes", author: "Mira Holt", storeID: 0), PodcastShow(id: 2, title: "Kitchen Table", author: "Sam & Ivo", storeID: 0),
                 PodcastShow(id: 3, title: "Small Wonders", author: "Ada Lin", storeID: 0)]   // l10n-ignore
        episodes[1] = [upNext[0], PodcastEpisode(title: "Salt, Fat, Acid, Heat, and Everything Else We Got Wrong About Seasoning", show: "Field Notes", duration: 3120, playhead: 3120, published: d, storeTrackID: 0, storeCollectionID: 0, played: true),
                       PodcastEpisode(title: "Umami, Explained", show: "Field Notes", duration: 2980, playhead: 0, published: d, storeTrackID: 0, storeCollectionID: 0, played: false)]   // l10n-ignore
    }
}
