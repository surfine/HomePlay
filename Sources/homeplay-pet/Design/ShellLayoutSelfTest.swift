// 外殼版面規格（docs/plans/shell-layout.md，2026-11-12 定案）的純邏輯自檢，跑在 `homeplay-pet --selftest`。
// 只驗幾何與規則的結果（呼叫畫面與點按真正用的函式），不渲染、不讀視窗，也不複述常數。

import AppKit

/// 系統畫面登記的「可以單獨點」的元件：名稱＋點按範圍（呼叫輸入程式真正用的命中函式）。
/// 規格第 2 節：寬高都不小於 88。新加可點的系統元件時一起登記在這裡。
enum ShellTapTargets {
    static func all() -> [(name: String, hit: CGRect)] {
        var out: [(name: String, hit: CGRect)] = []
        // 下一層頁首的返回鈕（App、資料庫展開頁、設定子頁共用）
        out.append(("返回鈕", HPTokens.backButton.insetBy(dx: -8, dy: -8)))   // l10n-ignore
        // App 資料庫：豆莢裡的大圖示、分類名稱、第四格小圖示群
        let f = SBLPodGrid.podFrame(0, top: SBUI.libraryTop)
        let pad = SBLPodGrid.iconGap / 2
        out.append(("資料庫豆莢大圖示", SBLPodGrid.largeFrame(0, in: f).insetBy(dx: -pad, dy: -pad)))   // l10n-ignore
        out.append(("資料庫豆莢名稱", SBLPodGrid.labelHit(f)))   // l10n-ignore
        out.append(("資料庫小圖示群", SBLPodGrid.largeFrame(3, in: f).insetBy(dx: -pad, dy: -pad)))   // l10n-ignore
        out.append(("資料庫展開頁圖示", SBUI.libraryExpandedHit(SBUI.libraryCell(0, SBUI.libraryTop))))   // l10n-ignore
        // 控制中心：編輯模式的「−」與改大小把手、右緣頁點（兩塊：上一頁／下一頁）、展開「家庭」的場景晶片
        let module = ControlCenter.frame(col: 0, row: 0, size: .s1x1)
        out.append(("控制中心移除鈕", ControlCenter.removeHit(module)))   // l10n-ignore
        out.append(("控制中心改大小把手", ControlCenter.resizeHit(module)))   // l10n-ignore
        for (i, h) in ControlCenter.pageDotHits(n: 3, x: 975, y0: 400, gapY: 26).enumerated() {
            out.append(("控制中心頁點 \(i + 1)", h.rect))   // l10n-ignore
        }
        out.append(("控制中心場景晶片", HPGrid.hitRect(CGRect(x: 0, y: 0, width: 60, height: HPTokens.Size.chip))))   // l10n-ignore
        return out
    }
}

enum ShellLayoutSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        // 規格第 2 節：登記的可點元件，點按範圍寬高都不小於 88
        let small = ShellTapTargets.all().filter { $0.hit.width < HPGrid.tap - 0.01 || $0.hit.height < HPGrid.tap - 0.01 }
        check(small.isEmpty, "外殼版面：可以單獨點的系統元件點按範圍都不小於 88（\(small.map { "\($0.name) \(Int($0.hit.width))×\(Int($0.hit.height))" }.joined(separator: "、"))）")   // l10n-ignore

        // 多顆即時動態：整組（主藥丸＋分離小藥丸）要對螢幕中線，不是只有主藥丸在中間
        do {
            let l = LiveActivityStack.layout(top: Shell.pillTop, single: nil, minimal: [40, 40])
            let span = l.detached.reduce(l.pill) { $0.union($1) }
            check(abs(span.midX - 512) < 0.01, "外殼版面：多顆即時動態整組置中")   // l10n-ignore
        }

        // 把手＝一次往上一層：主畫面→表面，App→主畫面；CarPlay 第一下只現身（2026-11-18）
        check(HomeHandle.tap(shownAtDown: false, livePill: false, onCarPlay: false, screen: .home) == .surface, "把手：主畫面點一下回表面")   // l10n-ignore
        check(HomeHandle.tap(shownAtDown: false, livePill: false, onCarPlay: false, screen: .app("weather")) == .home, "把手：App 點一下回主畫面")   // l10n-ignore
        check(HomeHandle.tap(shownAtDown: false, livePill: false, onCarPlay: true, screen: .app(CarPlayApp.id)) == .reveal, "把手：CarPlay 第一下只現身")   // l10n-ignore
        check(HomeHandle.tap(shownAtDown: true, livePill: false, onCarPlay: true, screen: .app(CarPlayApp.id)) == .home, "把手：CarPlay 看得見時回主畫面")   // l10n-ignore

        library(check)
        grids(check)
    }

    // MARK: 圖示格的頂 241、左右邊線（規格第 4、6 節）

    private static func grids(_ check: (Bool, String) -> Void) {
        // 遊戲：第一列圖示頂 241，第 1／4 欄外緣貼內容邊線（跟主畫面同一組欄線）
        let g0 = GamesApp.iconRect(col: 0, row: 0), g3 = GamesApp.iconRect(col: 3, row: 0)
        check(g0.minY == HPTokens.Home.gridTop && g0.minX == HPGrid.Content.leading && g3.maxX == HPGrid.Content.trailing,
              "外殼版面：遊戲的圖示格頂 241、第 1／4 欄外緣貼 98.5／925.5")   // l10n-ignore
        // 控制中心：模組格左右貼內容邊線
        let cc0 = ControlCenter.frame(col: 0, row: 0, size: .s1x1), ccR = ControlCenter.expandedRect
        check(cc0.minX == HPGrid.Content.leading && abs(ccR.maxX - HPGrid.Content.trailing) < 0.01
              && abs(ControlCenter.galleryRect.minX + HPGrid.Inset.card - HPGrid.Content.leading) < 0.01,
              "外殼版面：控制中心模組格與展開卡貼 98.5／925.5，圖庫卡的內容邊線也在 98.5")   // l10n-ignore
    }

    // MARK: App 資料庫（規格第 7 節）

    private static func library(_ check: (Bool, String) -> Void) {
        let G = SBLPodGrid.self
        let top = SBUI.libraryTop
        let row = (0..<G.columns).map { G.podFrame($0, top: top) }
        // 三欄、外緣貼內容邊線、豆莢不重疊、大圖示由三欄寬推出約 108 而且不小於 88
        check(row.count == 3 && abs(row[0].minX - HPGrid.Content.leading) < 0.01 && abs(row[2].maxX - HPGrid.Content.trailing) < 0.01
              && zip(row, row.dropFirst()).allSatisfy { $0.maxX < $1.minX }
              && G.podFrame(G.columns, top: top).minX == row[0].minX,
              "外殼版面：資料庫第一層一列三顆豆莢，外緣貼 98.5／925.5，第四顆換列")   // l10n-ignore
        let icon = G.largeFrame(0, in: row[0])
        check(icon.width >= HPGrid.tap && abs(icon.width - 108) < 2,
              "外殼版面：資料庫豆莢的大圖示約 108（不小於 88），是 \(icon.width)")   // l10n-ignore
        // 圖示格的頂 241：豆莢第一列、展開頁第一列、搜尋結果第一列
        check(row.allSatisfy { $0.minY == HPTokens.Home.gridTop }
              && SBUI.libraryCell(0, SBUI.libraryTop).minY == HPTokens.Home.gridTop
              && (SBUI.libraryCells(1).first?.minY ?? 0) == HPTokens.Home.gridTop,
              "外殼版面：資料庫的圖示格（豆莢、展開頁、搜尋結果）頂都是 241")   // l10n-ignore

        // 展開頁頁首＝下一層：返回鈕、分類名稱大標題（174／125、粗體 56）、沒有搜尋欄與頭像
        let savedNav = Shell.nav, savedExpanded = SB.libraryExpanded, savedQuery = SB.libraryQuery, savedSearching = SB.librarySearching
        Shell.nav = ShellNav(); Shell.nav.screen = .library
        SB.libraryQuery = ""; SB.librarySearching = false
        let face = Face(); face.frozen = true
        SB.setLibraryExpanded(nil, now: 0, immediate: true)
        let outer = SBAX.items(face: face)
        SB.setLibraryExpanded(.category(.utilities), now: 0, immediate: true)
        let inner = SBAX.items(face: face)
        let title = SBUI.libraryExpandedTitle()
        let header = SBUI.libraryExpandedHeader
        SB.setLibraryExpanded(nil, now: 0, immediate: true)
        Shell.nav = savedNav; SB.libraryExpanded = savedExpanded; SB.libraryQuery = savedQuery; SB.librarySearching = savedSearching
        let back = inner.first { $0.id == "sb.lib.back" }
        let heading = inner.first { $0.id == "sb.lib.expanded" }
        check(header && back.map { abs($0.rect.midX - 105) < 0.01 && abs($0.rect.midY - 105) < 0.01 && $0.rect.width == 90 } == true
              && !inner.contains { $0.id == "sb.search" || $0.id == "avatar" }
              && heading.map { abs($0.rect.minX - HPTokens.titleX) < 0.01 } == true
              && title.baseline == HPTokens.titleBaseline && title.font.pointSize == HPTokens.titleFont.pointSize,
              "外殼版面：資料庫展開頁的頁首是下一層（返回鈕圓心 105,105、標題 174／125 粗體 56，沒有搜尋欄與頭像）")   // l10n-ignore
        check(outer.contains { $0.id == "sb.search" } && outer.contains { $0.id == "avatar" } && !outer.contains { $0.id == "sb.lib.back" },
              "外殼版面：資料庫第一層是最外層（搜尋欄＋頭像，沒有返回鈕）")   // l10n-ignore

        // 四條內容規則（用自己造的 App 組，不依賴這台機器）
        let apps = ["timers", "worldclock", "alarms", "settings", "home", "findmy", "intercom", "messages", "facetime",
                    "music", "podcasts", "sing", "weather", "games", "cliotalk"].compactMap { AppRegistry.app($0) }
        let msgTwin = PhoneCarPlayApp(PhoneCarPlayEntry(bundleID: "com.apple.MobileSMS", name: "SMS", url: "sms:", path: ""))
        let weatherTwin = PhoneCarPlayApp(PhoneCarPlayEntry(bundleID: "com.example.weather", name: AppRegistry.app("weather")?.title ?? "", url: "w:", path: ""))
        let travel = PhoneCarPlayApp(PhoneCarPlayEntry(bundleID: "com.example.trip", name: "Trip", url: "trip:", path: "", genre: "public.app-category.travel"))
        let all = apps + [msgTwin, weatherTwin, travel]
        let savedHistory = AppLaunchHistory.override
        AppLaunchHistory.override = ["timers": [AppLaunchHistory.dayIndex(): 3]]   // 讓「建議」有東西
        AppLaunchCounts.override = (apps: [:], library: [:])
        AppInstallDates.override = [travel.id: 2_000_000]
        let pods = SBLPodGrid.pods(all, homeScreenApps: [])
        let groups = SBLPodGrid.categoryGroups(all, homeScreenApps: [])
        let builtInOnly = SBLPodGrid.pods(apps, homeScreenApps: [])
        AppLaunchCounts.override = nil
        AppInstallDates.override = nil
        AppLaunchHistory.override = savedHistory
        let kinds = pods.map(\.kind)
        let catKinds = kinds.filter { if case .category = $0 { return true } else { return false } }
        // 1. 順序：建議、最近加入、各分類、其他（永遠最後）
        let iRecent = kinds.firstIndex(of: .recentlyAdded) ?? -1, iFirstCat = kinds.firstIndex { catKinds.contains($0) } ?? -1
        check(kinds.first == .suggestions && iRecent == 1 && iFirstCat > iRecent && kinds.last == .category(.other),
              "外殼版面：資料庫豆莢順序是建議、最近加入、各分類，其他最後")   // l10n-ignore
        // 2. 分類至少 3 個 App，不到的併進其他（Social 只有訊息、FaceTime 兩個；Travel 只有一個 iPhone App）
        let other = groups.first { $0.category == .other }?.apps.map(\.id) ?? []
        check(groups.allSatisfy { $0.category == .other || $0.apps.count >= SBLPodGrid.minimumCategorySize }
              && !groups.contains { $0.category == .social || $0.category == .travel }
              && other.contains("messages") && other.contains("facetime") && other.contains(travel.id),
              "外殼版面：資料庫分類至少 3 個 App，不到的併進「其他」")   // l10n-ignore
        // 3. 同一 App 在分類裡只出現一次；iPhone 上跟桌寵同名（或同一個系統 App）的不列
        let listed = groups.flatMap { $0.apps.map(\.id) }
        check(Set(listed).count == listed.count && !listed.contains(msgTwin.id) && !listed.contains(weatherTwin.id)
              && listed.contains("messages") && listed.contains("weather"),
              "外殼版面：資料庫分類裡每個 App 只出現一次，iPhone 上同名的那個不列")   // l10n-ignore
        // 4. 最近加入只列後來加進來的（iPhone App、網頁），不含內建 App；沒有就不畫
        let recent = pods.first { $0.kind == .recentlyAdded }.map { $0.large + $0.cluster } ?? []
        check(recent == [travel.id] && !builtInOnly.contains { $0.kind == .recentlyAdded },
              "外殼版面：資料庫最近加入只列後來加進來的 App（不含內建），沒有就不畫")   // l10n-ignore
    }
}
