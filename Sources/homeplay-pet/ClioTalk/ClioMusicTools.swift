// 2.0 v2-music：ClioTalk 的「播放…」（music_play）。
// 在 Mac「音乐」的资料库里找（MusicCatalogStore：整批读一次、记忆体里搜）：播放列表名字完全相同＞歌名＞艺人＞专辑。
// 只在「音乐」已经在跑时做；不替使用者打开它，也不搜 Apple Music 目录（没有 MusicKit 权杖）——找不到就老实说。

import AppKit

enum ClioMusicTools {
    static func play(query: String) async -> ClioToolResult {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return ClioToolResult(content: "Say what to play.", isError: true) }
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == MusicApp.bundle }) else {
            return ClioToolResult(content: "The Music app isn't open on this Mac. Ask the user to open it first.", isError: true)
        }
        // 先看播放列表（「音乐」的 user playlist，名字不分大小写完全相同）
        let src = "tell application id \"\(MusicApp.bundle)\"\nset n to (name of every user playlist whose special kind is none)\nend tell\nset AppleScript's text item delimiters to (ASCII character 30)\nreturn n as text"
        let lists = await Task.detached { NSAppleScript(source: src)?.executeAndReturnError(nil).stringValue ?? "" }.value
            .components(separatedBy: "\u{1E}")
        if let pl = lists.first(where: { $0.caseInsensitiveCompare(q) == .orderedSame }) {
            let esc = pl.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            await Task.detached { _ = NSAppleScript(source: "tell application id \"\(MusicApp.bundle)\" to play user playlist \"\(esc)\"")?.executeAndReturnError(nil) }.value
            return ClioToolResult(content: "Playing the playlist \"\(pl)\".", isError: false)
        }
        let catalog: MusicCatalog = await withCheckedContinuation { c in
            DispatchQueue.main.async { MusicCatalogStore.shared.loadAll { c.resume(returning: MusicCatalogStore.shared.current) } }
        }
        let state = await MainActor.run { MusicCatalogStore.shared.state }
        if state == .denied { return ClioToolResult(content: "HomePlay isn't allowed to control Music. Tell the user to allow it in System Settings › Privacy & Security › Automation.", isError: true) }
        if state == .failed { return ClioToolResult(content: "The Music library couldn't be read right now.", isError: true) }
        guard let hit = pick(catalog, q) else {
            if await MainActor.run(body: { MusicCatalogStore.shared.truncated }) {
                return ClioToolResult(content: "\"\(q)\" wasn't found in the part of the library that could be read (\(catalog.tracks.count) songs). Suggest searching in the Music app.", isError: true)
            }
            return ClioToolResult(content: "Nothing called \"\(q)\" is in the user's Music library on this Mac.", isError: true)
        }
        await MainActor.run { MusicControl.shared.playTrack(pid: hit.pid) }
        return ClioToolResult(content: "Playing \"\(hit.name)\" by \(hit.artist.isEmpty ? "unknown artist" : hit.artist).", isError: false)
    }

    /// 歌名完全相同＞歌名開頭／包含＞艺人＞专辑（純函式，自檢用）
    static func pick(_ c: MusicCatalog, _ q: String) -> LibraryTrack? {
        func k(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil) }
        let key = k(q)
        if let t = c.tracks.first(where: { k($0.name) == key }) { return t }
        if let s = c.search(q, limit: 1).first, let t = c.tracks.first(where: { $0.pid == s.pid }), k(t.name).contains(key) { return t }
        if let t = c.tracks.filter({ k($0.artist) == key }).min(by: { ($0.album, $0.number) < ($1.album, $1.number) }) { return t }
        return c.tracks.filter { k($0.album) == key }.min { $0.number < $1.number }
    }
}
