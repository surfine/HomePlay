// 2.0 v2-music：音樂資料庫的資料層（「音樂」App 的 AppleScript，只讀；播放才送 play）。
// 一次把資料庫前 4000 首的歌名、演出者、專輯、曲序、persistent ID 整批拿回來（五個整批 get，不逐首問），
// 之後的專輯、藝人、歌曲、藝人的歌、搜尋都在記憶體裡算——不連網、不寫入、不進日誌。
// Apple Music 的推薦（主頁）、廣播、目錄搜尋要 MusicKit 的開發者權杖（App ID 開 MusicKit 服務），桌寵沒有：這幾項打開「音樂」的對應頁。

import AppKit
import SwiftUI

struct LibraryTrack: Equatable {
    var name: String
    var artist: String
    var album: String
    var number: Int
    var pid: String
}

/// 資料庫的一份快照與從它算出來的清單（純函式，自檢用）
struct MusicCatalog: Equatable {
    var tracks: [LibraryTrack] = []

    /// 第一頁 2000 首：約 0.4 秒就回來，先給清單頁顯示；接著一次整批讀全部（實測 26,284 首 1.5 秒）。
    /// 不能一頁一頁用 `tracks a thru b` 讀到底：資料庫的 index 有空號（刪掉的曲目留下的，這台 14 個，index 最大 26,298），
    /// 範圍取法照 index 算，會回幽靈 ID、漏掉 index 在 count 之後的真曲目（這台漏 28 首、多 14 個找不到的 ID）。`every track` 沒有這個問題。
    static let pageSize = 2000
    /// range＝nil：全部（every track）；否則第 a…b 首。回「總數 GS 五段」；a 超過總數時只回總數
    static func script(_ range: (Int, Int)?) -> String {
        let ref = range.map { "tracks \($0.0) thru b of library playlist 1" } ?? "every track of library playlist 1"
        let clamp = range.map { "if n < \($0.0) then return (n as text)\n    set b to \($0.1)\n    if b > n then set b to n" } ?? ""
        return """
        if application id "com.apple.Music" is not running then return "NOTRUNNING"
        with timeout of 60 seconds
          tell application id "com.apple.Music"
            set n to (count of tracks of library playlist 1)
            \(clamp)
            set ns to (name of \(ref))
            set ars to (artist of \(ref))
            set als to (album of \(ref))
            set tns to (track number of \(ref))
            set ps to (persistent ID of \(ref))
          end tell
        end timeout
        set AppleScript's text item delimiters to (ASCII character 30)
        set out to (n as text) & (ASCII character 29) & (ns as text) & (ASCII character 29) & (ars as text) & (ASCII character 29) & (als as text) & (ASCII character 29) & (tns as text) & (ASCII character 29) & (ps as text)
        set AppleScript's text item delimiters to ""
        return out
        """
    }
    /// 一頁的輸出 → (總數, 這一頁的曲目)；不是數字開頭＝nil
    static func parsePage(_ out: String) -> (total: Int, tracks: [LibraryTrack])? {
        let head = out.prefix { $0 != "\u{1D}" }
        guard let total = Int(head.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let rest = out.count > head.count ? String(out.dropFirst(head.count + 1)) : ""
        return (total, rest.isEmpty ? [] : parse(rest).tracks)
    }

    /// 五段（GS 分隔）、每段 RS 分隔 → 曲目；段數或長度對不上＝空
    static func parse(_ out: String) -> MusicCatalog {
        let blocks = out.components(separatedBy: "\u{1D}")
        guard blocks.count == 5 else { return MusicCatalog() }
        let cols = blocks.map { $0.components(separatedBy: "\u{1E}") }
        let n = cols[0].count
        guard n > 0, cols.allSatisfy({ $0.count == n }) else { return MusicCatalog() }
        var t: [LibraryTrack] = []
        t.reserveCapacity(n)
        for k in 0..<n where !cols[0][k].isEmpty && !cols[4][k].isEmpty {
            t.append(LibraryTrack(name: cols[0][k], artist: cols[1][k], album: cols[2][k], number: Int(cols[3][k]) ?? 0, pid: cols[4][k]))
        }
        return MusicCatalog(tracks: t)
    }

    private static func key(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil) }
    private static func sorted(_ a: [MusicApp.Item]) -> [MusicApp.Item] {
        a.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 專輯：每張取曲序最小的那首當「從頭播」
    func albums() -> [MusicApp.Item] {
        var first: [String: LibraryTrack] = [:]
        for t in tracks where !t.album.isEmpty {
            let k = t.album + "\u{1}" + t.artist
            if let f = first[k], f.number > 0, f.number <= t.number || t.number == 0 { continue }
            first[k] = t
        }
        return Self.sorted(first.values.map { MusicApp.Item(kind: .album, name: $0.album, detail: $0.artist, pid: $0.pid) })
    }
    func artists() -> [MusicApp.Item] {
        var count: [String: Int] = [:]
        for t in tracks where !t.artist.isEmpty { count[t.artist, default: 0] += 1 }
        return Self.sorted(count.map { MusicApp.Item(kind: .artist, name: $0.key, detail: String(format: L("music.lib.songCount", "%d 首歌"), $0.value)) })
    }
    func songs(artist: String? = nil) -> [MusicApp.Item] {
        let list = artist.map { a in tracks.filter { $0.artist == a } } ?? tracks
        return Self.sorted(list.map { MusicApp.Item(kind: .song, name: $0.name, detail: artist == nil ? $0.artist : $0.album, pid: $0.pid) })
    }
    /// 搜尋：歌名開頭＞歌名包含＞演出者／專輯包含；不分大小寫、全半形、重音
    func search(_ q: String, limit: Int = 60) -> [MusicApp.Item] {
        let k = Self.key(q.trimmingCharacters(in: .whitespaces))
        guard !k.isEmpty else { return [] }
        var scored: [(Int, LibraryTrack)] = []
        for t in tracks {
            let n = Self.key(t.name)
            let s = n.hasPrefix(k) ? 0 : n.contains(k) ? 1 : (Self.key(t.artist).contains(k) || Self.key(t.album).contains(k)) ? 2 : -1
            if s >= 0 { scored.append((s, t)) }
        }
        scored.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.name.localizedStandardCompare($1.1.name) == .orderedAscending }
        return scored.prefix(limit).map { MusicApp.Item(kind: .song, name: $0.1.name, detail: $0.1.artist, pid: $0.1.pid) }
    }
}

/// 資料庫的載入（背景佇列，一次一個；60 秒內不重讀）
final class MusicCatalogStore {
    static let shared = MusicCatalogStore()
    enum State: Equatable { case idle, loading, notRunning, denied, failed, ready }
    private(set) var state: State = .idle
    private(set) var catalog = MusicCatalog()
    var demo: MusicCatalog? { didSet { if demo != nil { state = .ready } } }
    var current: MusicCatalog { demo ?? catalog }
    private var loadedAt = -1e9
    private let queue = DispatchQueue(label: "homeplay.music.catalog", qos: .utility)
    var onChange: (() -> Void)?
    private var waiters: [() -> Void] = []

    /// 整個資料庫都讀完了（後面幾頁在背景補）；讀到一半失敗＝truncated
    private(set) var complete = false
    private(set) var truncated = false
    private var allWaiters: [() -> Void] = []

    /// done：第一頁好了就叫（清單頁先顯示）
    func load(force: Bool = false, then done: (() -> Void)? = nil) {
        if demo != nil { done?(); return }
        if SnapshotPrivacy.active { state = .notRunning; done?(); return }   // 快照不讀真的資料庫
        if let done { waiters.append(done) }
        if state == .loading || (state == .ready && !complete) { if state == .ready { flush() }; return }
        if !force, state == .ready, CACurrentMediaTime() - loadedAt < 60 { flush(); return }
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == MusicApp.bundle }) else { state = .notRunning; flush(); flushAll(); return }
        let first = catalog.tracks.isEmpty
        if first { state = .loading; onChange?() }
        complete = false
        queue.async { [weak self] in
            // 第一次讀先拿第一頁（清單頁馬上有東西），再整批讀全部；重讀直接整批
            for range in (first ? [(1, MusicCatalog.pageSize), nil] : [nil]) as [(Int, Int)?] {
                var err: NSDictionary?
                let out = NSAppleScript(source: MusicCatalog.script(range))?.executeAndReturnError(&err).stringValue
                let code = (err?[NSAppleScript.errorNumber] as? Int) ?? 0
                let page = out.flatMap(MusicCatalog.parsePage)
                let full = range == nil   // 第一頁用的範圍取法會漏（見上），一定要整批讀過才算完整
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let page {
                        self.catalog = MusicCatalog(tracks: page.tracks); self.state = .ready
                        self.truncated = false
                    } else if self.state != .ready {
                        self.state = code == -1743 ? .denied : (out == "NOTRUNNING" ? .notRunning : .failed)
                    } else {
                        self.truncated = true   // 第一頁有了、整批那次失敗：搜尋只涵蓋第一頁
                    }
                    if full || page == nil { self.complete = true; self.loadedAt = CACurrentMediaTime() }
                    self.onChange?(); self.flush()
                    if self.complete { self.flushAll() }
                }
                if full || page == nil { return }
            }
        }
    }
    /// done：整個資料庫都讀完才叫（ClioTalk 的「播放…」要找得到每一首）
    func loadAll(then done: @escaping () -> Void) {
        if demo != nil { done(); return }
        allWaiters.append(done)
        load()
        if complete, state != .loading { flushAll() }
    }
    private func flushAll() { let w = allWaiters; allWaiters = []; w.forEach { $0() } }
    private func flush() { let w = waiters; waiters = []; w.forEach { $0() } }

    static let demoCatalog = MusicCatalog(tracks: [
        LibraryTrack(name: "Golden Hour", artist: "Mika Lindqvist", album: "Golden Hour", number: 1, pid: "d1"),
        LibraryTrack(name: "Paper Boats", artist: "The Quiet Hours", album: "Paper Boats", number: 1, pid: "d2"),
        LibraryTrack(name: "Harbour Lights", artist: "The Quiet Hours", album: "Paper Boats", number: 2, pid: "d3"),
        LibraryTrack(name: "Long Way Home", artist: "Eli Ward", album: "Long Way Home", number: 1, pid: "d4"),
        LibraryTrack(name: "Tidal", artist: "Marin & Co.", album: "Tidal", number: 1, pid: "d5"),
        LibraryTrack(name: "Soft Machines", artist: "Kiri Okafor", album: "Soft Machines", number: 1, pid: "d6"),
        LibraryTrack(name: "Late Bloom", artist: "Aoi Hayashi", album: "Late Bloom", number: 1, pid: "d7"),
        LibraryTrack(name: "Blue Hour", artist: "Nova Sato", album: "Blue Hour", number: 1, pid: "d8"),
        LibraryTrack(name: "Golden Thread", artist: "Nova Sato", album: "Blue Hour", number: 2, pid: "d9"),
    ])   // l10n-ignore：示範資料庫（自己編的）
}

// MARK: - 搜尋框（桌寵旁邊的原生小框；沒有螢幕鍵盤，用實體鍵盤或聽寫）

final class MediaSearchModel: ObservableObject {
    @Published var text = ""
    var onSubmit: ((String) -> Void)?
}

struct MediaSearchView: View {
    @ObservedObject var model: MediaSearchModel
    let prompt: String
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(prompt, text: $model.text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { model.onSubmit?(model.text) }
                .frame(width: 320)
            Label(L("input.noOnscreenKeyboard", "没有屏幕键盘：用键盘打字，或按两下 fn 听写"), systemImage: "keyboard")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .onAppear { focused = true }
    }
}
