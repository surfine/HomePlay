// 快照旗標（媒體類 App 的假資料，免得截圖要靠真的播放器與網路）：
//   --demo-music [nowplaying|mac|library|library-off|library-bottom]   固定一首「正在播放」（來源 iPhone；mac＝Mac）
//   --demo-recipe [overview|ingredients|step:N|home|home-recents|none|failed|loading]   內建樣本食譜（不連網、不寫入「最近」）
//   --demo-recipe promo[:ingredients|:step:N|:timer:N]   宣傳片那份食譜；--demo-promo [--promo-frames 資料夾]   整段宣傳片
// 單獨給旗標就直接打開對應的 App（不必再加 --app）。

import AppKit

extension Shell {
    static func applyMediaDemoFlags(face: Face) {
        let args = CommandLine.arguments
        func value(_ name: String) -> String?? {
            guard let i = args.firstIndex(of: name) else { return nil }
            if i + 1 < args.count, !args[i + 1].hasPrefix("--") { return .some(args[i + 1]) }
            return .some(nil)
        }
        func open(_ id: String) {
            guard case .app = nav.screen else {
                homeHue = homeHue ?? hue(fromFace: face.render(), face: face)
                nav.screen = .app(id); nav.appReturn = .home
                AppRegistry.app(id)?.didOpen(now: CACurrentMediaTime())
                return
            }
        }
        if let v = value("--demo-music") {
            if !args.contains("--app") { open("music") }
            if let m = AppRegistry.app("music") as? MusicApp { m.applyDemo(page: v, face: face) }
            pillT = face.shellActivity(CACurrentMediaTime()) == nil ? 0 : 1
        }
        // v2-music：--demo-podcasts [show|intro]：播客資料庫的示範資料（不讀真的「播客」資料庫）
        if let v = value("--demo-podcasts") {
            if !args.contains("--app") { open("podcasts") }
            if let p = AppRegistry.app("podcasts") as? PodcastsApp { p.applyDemo(v, face: face) }
        }
        if let u = value("--recipe-url") ?? nil, let url = URL(string: u) {   // 除錯：真的抓這個網址（用 HOMEPLAY_RECIPES_FILE 指到暫存檔，免得寫進真的「最近」）
            open("recipes")
            RecipesApp.shared.open(url, face: face)
        }
        if let dir = ProcessInfo.processInfo.environment["HOMEPLAY_LIVE_GLASS_BENCH"] { LiveGlassBench.start(face, dir: dir) }   // 2.0 live glass 量測台（Design/LiveGlass.swift）
        if OfficialDemo.on, value("--demo-recipe") == nil, let i = args.firstIndex(of: "--app"), i + 1 < args.count, args[i + 1] == "recipes" {
            RecipesApp.shared.applyDemo(screen: "overview", face: face)   // --demo-official --app recipes：官方的封面
        }
        // 第四輪除錯：--lyrics-probe <歌名> <歌手> <秒>：真的問一次 LRCLIB（走 LyricsStore 同一條路），只印行數、不印歌詞
        if let i = args.firstIndex(of: "--lyrics-probe"), i + 3 < args.count {
            let (t, a, d) = (args[i + 1], args[i + 2], Double(args[i + 3]) ?? 0)
            LyricsStore.shared.onUpdate = {
                let st = LyricsStore.shared.state(title: t, artist: a, duration: d)
                if case .ready(let l) = st { print("lyrics-probe: ready synced=\(l.synced.count) plain=\(l.plain.count) instrumental=\(l.instrumental)") }
                else { print("lyrics-probe: \(st)") }
                exit(0)
            }
            let st = LyricsStore.shared.state(title: t, artist: a, duration: d)
            if st != .loading { LyricsStore.shared.onUpdate?() }
        }
        // v2-music3 除錯：--music-catalog-probe：真的讀一次「音樂」資料庫（走 MusicCatalogStore 同一條路），只印首數與 ID 數，不印歌名
        if args.contains("--music-catalog-probe") {
            let t0 = CACurrentMediaTime()
            MusicCatalogStore.shared.onChange = {
                let c = MusicCatalogStore.shared.current
                print(String(format: "catalog-probe: %.2fs state=\(MusicCatalogStore.shared.state) complete=\(MusicCatalogStore.shared.complete) tracks=\(c.tracks.count) uniqueIDs=\(Set(c.tracks.map(\.pid)).count)", CACurrentMediaTime() - t0))
            }
            MusicCatalogStore.shared.loadAll { exit(0) }
        }
        // 第四輪除錯：--mr-probe：MediaRemote 符號在不在、perl 讀取迴圈讀到什麼（只印來源 App、長度、倍速，不印標題）
        if args.contains("--mr-probe") {
            let m = MediaRemote.shared
            print("mr-probe: send=\(m.canSend) skip=\(m.canSkip) rate=\(m.canRate) seek=\(m.canSeek)")
            MediaRemoteReader.shared.onChange = {
                if let n = MediaRemoteReader.shared.latest {
                    print("mr-probe: now playing bundle=\(n.bundle.isEmpty ? "-" : n.bundle) duration=\(Int(n.duration)) elapsed=\(Int(n.elapsed)) rate=\(n.rate) playing=\(n.playing) titleChars=\(n.title.count)")
                    if args.contains("--mr-skip") { print("mr-probe: skip +30 sent=\(MediaRemote.shared.skip(30)) rate 1.5 sent=\(MediaRemote.shared.setRate(1.5))") }
                    exit(0)
                }
            }
            MediaRemoteReader.shared.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { print("mr-probe: nothing playing (reader running=\(MediaRemoteReader.shared.running))"); exit(0) }
        }
        // 第四輪快照：--settings-png <path> 打開設定的「通用」頁，拍下視窗內容（驗收歌詞開關的原生分組表單）
        if let p = value("--settings-png") ?? nil, let app = NSApp.delegate as? AppDelegate {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                SettingsWindowController.show(app: app, pane: .general)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    guard let v = SettingsWindowController.shared?.window?.contentView,
                          let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: p))
                    SettingsWindowController.shared?.window?.close()
                }
            }
        }
        WebAppDemo.apply(face: face)   // 2.0 Web App：--demo-webapps sheet|home|app|prompt|settings（Shell/WebApps/WebAppDemo.swift）
        if args.contains("--demo-promo") { PromoDemo.start(face: face) }   // 2.0 promo：整段宣傳片（Shell/Apps/PromoDemo.swift）
        if let v = value("--demo-recipe") {
            if !args.contains("--app") { open("recipes") }
            RecipesApp.shared.applyDemo(screen: v, face: face)
        }
    }
}
