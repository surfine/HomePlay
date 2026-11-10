// App 資料庫的分類（iPadOS 27.2 的 App Library）。依據與反編譯指令見 docs/hv-reference/app-library-categories.md。
//
// 系統的做法（🟢 反編譯）：
// - 分類是 SBHLibraryCategoryMap：一份有序的類別清單＋每類一份「已排序」的 App 清單＋每類的顯示名；
//   空類別不畫（沒有 App 就整顆豆莢拿掉）。
// - 類別身分是 Categories.framework 的 DH 字串（DH1001…DH1013），顯示名經 Localizable.loctable 翻出來
//   （所以「Productivity」顯示成「Productivity & Finance」）。
// - 系統 App 的分類來自 bundle 的 AppDirectoryDefaultCategories.plist（38 筆）；第三方靠 App Store genre。
// - 類別之間與類別內都照啟動次數排（ATXAppDirectoryOrderingProvider），不是字母。
// - 搜尋是另一層（SBHLibrarySearchController）：前綴命中優先，其餘 A→Z。
//
// HomePlay 目前做得到的：類別順序、空類別不畫、前綴優先的搜尋、iPhone App 另成一區。
// 🟡 還做不到：啟動次數排序（沒有這本帳，先 A→Z／固定順序）、第三方 App 的 genre（只有本機 App，
// 每個自家 App 手寫對映；Web App 一律 Other）、豆莢縮圖與點開、Suggestions／Recents 兩顆。

import Foundation

/// 開啟次數（App Library 的排序依據）。系統有兩本帳：裝置上的開啟次數（`_appLaunchCounts`）與
/// 從資料庫開啟的次數（`_libraryAppLaunchCounts`）；類別內的順序照合計次數，平手才用名字。
/// 依據見 `docs/hv-reference/app-library-categories.md` 第五節。
///
/// 快照與自檢不讀寫偏好（不然比對圖會被這台 Mac 的使用習慣影響、自檢也會留下紀錄）。
enum AppLaunchCounts {
    static let appsKey = "HomePlayAppLaunchCounts"
    static let libraryKey = "HomePlayLibraryLaunchCounts"
    static var frozen: Bool {
        SnapshotPrivacy.active || CommandLine.arguments.contains("--selftest")
            || CommandLine.arguments.contains { $0.hasPrefix("--demo") }   // 示範資料不是使用習慣
    }

    /// 自檢用：給定兩本帳，不碰偏好（nil＝照真的）
    nonisolated(unsafe) static var override: (apps: [String: Int], library: [String: Int])?

    nonisolated(unsafe) private static var apps: [String: Int] = load(appsKey)
    nonisolated(unsafe) private static var library: [String: Int] = load(libraryKey)

    private static func load(_ key: String) -> [String: Int] {
        guard !frozen else { return [:] }
        return (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
    }

    /// 開一次 App。`fromLibrary`＝從 App 資料庫點的（另外記一本，跟系統一樣）
    static func note(_ id: String, fromLibrary: Bool) {
        guard !frozen, !id.isEmpty else { return }
        var a = apps, l = library
        a[id, default: 0] += 1
        if fromLibrary { l[id, default: 0] += 1 }
        apps = a; library = l
        UserDefaults.standard.set(a, forKey: appsKey)
        if fromLibrary { UserDefaults.standard.set(l, forKey: libraryKey) }
        AppLaunchHistory.note(id)
    }

    /// 合計次數（類別內排序的鍵）
    static func total(_ id: String) -> Int {
        if let o = override { return (o.apps[id] ?? 0) + (o.library[id] ?? 0) }
        return (apps[id] ?? 0) + (library[id] ?? 0)
    }

    /// 從資料庫開啟的次數（`_libraryAppLaunchCounts`）。分類去重用的是這一本，不是合計。
    static func libraryCount(_ id: String) -> Int {
        if let o = override { return o.library[id] ?? 0 }
        return library[id] ?? 0
    }

    /// 快照：`--launch-counts timers=9,music=3` 假裝有這些開啟次數（只影響這次執行，不寫偏好）。
    /// 用來驗「類別內照次數排」而不依賴這台 Mac 的使用習慣。
    /// 同時合成一份逐日歷史（每天一次，連續 n 天）給「建議」豆莢的評分用——不然快照永遠看不到建議。
    static func parseSnapshotArgs(_ args: [String]) {
        guard let i = args.firstIndex(of: "--launch-counts"), i + 1 < args.count else { return }
        var a: [String: Int] = [:]
        var hist: [String: [Int: Int]] = [:]
        let today = AppLaunchHistory.dayIndex()
        for kv in args[i + 1].split(separator: ",") {
            let p = kv.split(separator: "=").map(String.init)
            guard p.count == 2, let n = Int(p[1]), n >= 0 else { continue }
            a[p[0]] = n
            var m: [Int: Int] = [:]
            for back in 0..<min(n, AppLaunchHistory.window) { m[today - back] = 1 }   // 一天一次
            hist[p[0]] = m
        }
        override = (apps: a, library: [:])
        AppLaunchHistory.override = hist
    }

    /// 類別內的順序：次數高的在前，平手照名字（系統的 _appBundleIDTotalLaunchComparator）
    static func order(_ apps: [PetApp]) -> [PetApp] {
        apps.sorted { a, b in
            let ta = total(a.id), tb = total(b.id)
            if ta != tb { return ta > tb }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
}

// MARK: - 豆莢幾何
//
// 兩組來源，分的很清楚：
//
// 甲、iPad Pro 13" M5 模擬器（iPadOS 27.0，1032×1376 pt）— 絕對座標從 AX frame 直接讀，
//     不是推的：`baguette describe-ui --x --y` 對單一元素取 frame（單位就是 pt）。
//
// | 項目                     | pt      |
// | 搜尋欄                    | 334×48  |
// | 搜尋欄圓角                 | 24（＝半高，膠囊；固件也給 24） |
// | 分類豆莢                   | 178.33×201.5 |
// | 豆莢內圖示                 | 72×72   |
// | 圖示 pitch（水平與垂直）    | 80（gap 8） |
// | 豆莢內邊距                 | 13      |
// | 豆莢底部標籤區              | 36.5    |
// | 第一顆豆莢左緣／上緣         | 111 / 532 |
//
// 乙、實機 iPad（iPad13,6，iPadOS 27.0.1，834×1194 pt，直向與橫向各一張）
//     — 分類標籤中心由 Vision OCR 取得，圖示由色度連通塊取得：
//
// | 項目                         | 直向 834 | 橫向 1194 |
// | 欄數                         | 4        | 4         |
// | 標籤中心 pitch               | 184.3    | 195.2     |
// | 第一欄中心                   | 138.9    | 303.3     |
// | 列 pitch                     | 205.6    | 205.0     |
// | 豆莢內 App 圖示              | 61×61，pitch 74（gap 13） | 同左 |
// | 小叢集圖示                   | 24.5×24.5，pitch 30.5     | 同左 |
//
// 兩張實機截圖的關鍵結構結論（可證偽，見自檢）：
//   1. 欄位左右邊距對稱 → 第一欄中心 = (寬 − 3×pitch) / 2。
//      直向 (834 − 3×184.3)/2 = 140.6，實測 138.9；橫向 (1194 − 3×195.2)/2 = 304.2，實測 303.3。
//      所以欄距不是固定常數，是「扣掉對稱邊距之後均分」。
//   2. 一頁 4 欄 × 3 列 = 12 格。實機 11 顆豆莢（8 個分類＋建議＋最近添加＋已隱藏）剛好排滿 3 列。
//   3. 豆莢裡是 2 欄圖示；> 4 個 App 時右下換成 2×2 小叢集（小圖示 24.5 pt 就是這個）。
//   4. 深色模式下豆莢與背景幾乎同色，所以豆莢外框的寬高只能靠圖示回推（🟡，誤差約 ±3 pt）。
//
// 還沒量到（不憑感覺填）：橫向時第一列豆莢的上緣、一頁到底幾列（實機只擺得下 3 列，
// 沒有第 4 列可看）、豆莢圓角。
//
// HomePlay 的畫布是 1024（不是 1032），套用時按比例縮，或整組當成「1032 座標系」再縮。
enum SBLPodMetrics {
    static let referenceWidth: CGFloat = 1032       // 量測時的螢幕寬
    static let searchSize = CGSize(width: 334, height: 48)
    static let searchCornerRadius: CGFloat = 24
    static let podSize = CGSize(width: 178.33, height: 201.5)
    static let iconSize: CGFloat = 72
    static let iconPitch: CGFloat = 80
    static var iconGap: CGFloat { iconPitch - iconSize }        // 8
    static let podPadding: CGFloat = 13
    static let podLabelHeight: CGFloat = podSize.height - (podPadding + iconSize + iconGap + iconSize)   // 36.5
    static let firstPodLeft: CGFloat = 111
    static let firstPodTop: CGFloat = 532

    /// 一頁幾欄。實機直向、橫向都是 4 欄（OCR 標籤中心 pitch 一致）。
    static let podColumnCount = 4

    // MARK: 豆莢的圓角與底色（2026-11-09 實機量測，見文件第九節）

    /// 11" 實機上的豆莢寬（靠圖示與 OCR 交叉回推）
    static let devicePodWidth: CGFloat = 159.6
    /// 圓擬合得到的圓角半徑（建議豆莢的左上 25.71、右上 25.84，取 26）
    static let podCornerRadius: CGFloat = 26
    /// 圓角 / 豆莢寬 = 0.162。HomePlay 的豆莢畫得比較大，照這個比例放大
    static var podCornerRatio: CGFloat { podCornerRadius / devicePodWidth }
    /// 底板的等效白幕覆蓋率：壁紙 121 → 豆莢 135 ⇒ α = 0.104
    static let podVeil: CGFloat = 0.104    /// 一頁幾列。實機 11 顆豆莢在直向與橫向都排成 3 列。🟡 容量上限還沒量到。
    /// 系統底板材質（`podBackgroundViewDark.visualstyleset`）的 vibrant 矩陣：RGB 三列的係數和
    /// 只有 0.0091、平移 0.16409，再加白 0.7255 染色。只用來記錄**否證**，HomePlay 不套這條矩陣：
    /// 背景差 38 級只會讓輸出差不到 1 級，但實機豆莢內差 47 級（第九節 9.4）。
    static let vibrantRowSum: CGFloat = 0.0091
    static let vibrantBias: CGFloat = 0.16409
    static let vibrantWhiteTint: CGFloat = 0.7255
    static let measuredBackgroundDelta: CGFloat = 38
    static let measuredPodDelta: CGFloat = 47
    static let podRowCount = 3
    static var podSlotsPerPage: Int { podColumnCount * podRowCount }

    /// 欄距 = 扣掉左右對稱邊距後，剩下的寬度均分給三個縫。不再用猜的 200。
    static var podColumnGap: CGFloat {
        (referenceWidth - 2 * firstPodLeft - CGFloat(podColumnCount) * podSize.width)
            / CGFloat(podColumnCount - 1)          // 32.23
    }
    static var podColumnPitch: CGFloat { podSize.width + podColumnGap }   // 210.56

    /// 列 pitch。🟡 只在實機量到「列 pitch 205.6、豆莢高約 190.5」→ 縫 15.1；
    /// 這裡假設縫與裝置尺寸無關，把同一條縫套到 13" 的豆莢高 201.5 上。兩者都還沒交叉驗證。
    static var podRowPitch: CGFloat { podSize.height + podRowGap }
    static let podRowGap: CGFloat = 15.1

    /// 把量測座標系（1032 寬）換到 HomePlay 的 1024 畫布
    static func scale(_ pt: CGFloat, to canvas: CGFloat = 1024) -> CGFloat {
        pt * canvas / referenceWidth
    }
}

/// 豆莢展開：內容從豆莢那一塊放大到滿版。
///
/// 常數讀自 SpringBoardHome 的 `+[SBHLibraryPodZoomSettings _defaultInnerFolderZoomAnimationSettings]`
/// （IMP 0x1c5c72a64）：質量 1、stiffness **246.74**（`__DATA` 0x1c5d79070）、
/// damping **31.42**（0x1c5d79078）。這兩個是固件裡存成兩位小數的圓整值
/// （25π² = 246.7401、10π = 31.4159）⇒ √k = 5π，ζ = c / (2√k) ≈ 1（臨界阻尼），
/// ω = 5π rad/s ⇒ response = 2π/ω = **0.4 秒**。延遲 **0.05 秒** 讀自 `_defaultInnerFolderZoomDelay`
/// （`__DATA` 0x1c5d74788）。交叉淡化是另一條設定（`_defaultCrossfadeSettings` 的 duration 0.2），
/// 兩者同時作用，不是互相取代。
///
/// 起點縮放不是猜的：豆莢寬 ÷ 展開頁的內容寬（主畫面左緣到右緣），兩個都是本專案自己的格子。
enum SBLPodZoom {
    /// `_defaultInnerFolderZoomDelay`：0.05 秒。固件只有這一個延遲，開與關都用它。
    static let delay: Double = 0.05
    /// 由 stiffness 246.74、damping 31.42 反推（ζ = 1、ω = 5π）
    static var spring: Spring {
        let stiffness: CGFloat = 246.74, damping: CGFloat = 31.42
        let omega = stiffness.squareRoot()
        return Spring(damping: damping / (2 * omega), response: 2 * .pi / omega)
    }
    /// 縮放起點：豆莢寬 ÷ 展開頁的內容寬
    static var startScale: CGFloat {
        SBLPodGrid.podWidth / (HPGrid.Home.trailing - HPGrid.Home.margin)
    }
    /// z：0＝還停在豆莢的大小、1＝滿版
    static func scale(at z: CGFloat) -> CGFloat {
        startScale + (1 - startScale) * max(0, min(1, z))
    }
}

// MARK: - 豆莢的內容（一類一顆豆莢，2×2 大圖示；> 4 個 App 時右下換成 2×2 小圖示叢集）
//
// 結構依據（docs/hv-reference/app-library-categories.md 第六之二節）：固件裡一類有四份資料夾
// ——compactPodFolder（縮起來的預覽）、expandedPodFolder（點開後）、
// compactPodAdditionalItemsFolder（放不下的那一截，用 SBHLibraryAdditionalItemsIndicatorIcon 畫），
// 加上位置常數 SBIconLocationAppLibraryCategoryPodAdditionalItems。三個獨立來源一致：
// 豆莢是 2×2 大格；> 4 個 App 時右下那一格換成 2×2 的四顆小圖示（共 3 大 + 4 小）；
// ≤ 4 個 App 時四顆全大、沒有小叢集。
//
// 這裡只算「哪一格放什麼」。豆莢的邊長、圓角、欄距還沒有固件數字，所以畫面仍用四欄清單，
// 不憑感覺造豆莢版面。
enum SBLCategoryPod {
    enum Slot: Equatable {
        /// 大圖示（2×2 的其中一格）
        case large(Int)
        /// 小圖示叢集（2×2 的四顆；空＝這一格沒有小圖示）
        case cluster([Int])
    }

    /// 豆莢要顯示的格位，順序＝左到右、上到下（大格 0…3）
    static func slots(count: Int) -> [Slot] {
        guard count > 0 else { return [] }
        if count <= 4 {
            // 四顆（或更少）全是大圖示，沒有小叢集
            return (0..<count).map { .large($0) }
        }
        // 3 大 + 右下角的 4 小小叢集
        let cluster = Array(4..<min(count, 8))
        return [.large(0), .large(1), .large(2), .cluster(cluster)]
    }

    /// 一類的豆莢內容：前幾個放大圖示、其餘收進小叢集
    static func layout(_ apps: [PetApp]) -> (large: [PetApp], cluster: [PetApp]) {
        let slots = slots(count: apps.count)
        var large: [PetApp] = [], cluster: [PetApp] = []
        for s in slots {
            switch s {
            case .large(let i): large.append(apps[i])
            case .cluster(let idx): cluster = idx.compactMap { $0 < apps.count ? apps[$0] : nil }
            }
        }
        return (large, cluster)
    }
}

/// 每次開啟的「哪一天」紀錄。
///
/// 為什麼需要它：系統的 App 資料庫建議不是照總開啟次數排，而是照一條加權分數
/// （`AppPredictionInternal` 的字串原文，見 docs/hv-reference/app-library-categories.md 第九節）：
///
///     uniqueDaysLaunched + rawLaunchCount / 5 + appPrior / 100 + hasHomescreenWidget * 3
///       + heursitics + complicationPrior / 100 + watchBundleIdCount * 2 + hyperRecentlyInstalled * 30
///
/// 前兩項的取法也有證據：`-[ATXAppLaunches rawLaunchCountAndDistinctDaysLaunchedOverLast28DaysForAllApps]`
/// ——**28 天**窗口內的原始次數與「有開啟的不同天數」。
enum AppLaunchHistory {
    static let key = "HomePlayAppLaunchDays"
    /// `ATXAppLaunches` 的 …OverLast28Days 系列，窗口就是 28 天
    static let window = 28
    private static let daySeconds: TimeInterval = 86_400

    /// 自檢用：直接指定 day→次數，不碰偏好
    nonisolated(unsafe) static var override: [String: [Int: Int]]?

    nonisolated(unsafe) private static var days: [String: [Int: Int]] = load()

    private static func load() -> [String: [Int: Int]] {
        guard !AppLaunchCounts.frozen,
              let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Int]] else { return [:] }
        var out: [String: [Int: Int]] = [:]
        for (id, m) in raw {
            var d: [Int: Int] = [:]
            for (k, v) in m { if let day = Int(k) { d[day] = v } }
            out[id] = d
        }
        return out
    }

    static func dayIndex(_ t: TimeInterval = Date().timeIntervalSince1970) -> Int { Int(t / daySeconds) }

    /// 記一筆（預設是今天）。順手把窗口外的日子剪掉，這本帳才不會長大。
    static func note(_ id: String, day: Int = dayIndex()) {
        guard !id.isEmpty, override == nil else { return }
        var d = days
        var m = d[id] ?? [:]
        m[day, default: 0] += 1
        let cutoff = day - window
        m = m.filter { $0.key > cutoff }
        d[id] = m
        d = d.mapValues { $0.filter { $0.key > cutoff } }
        days = d
        guard !AppLaunchCounts.frozen else { return }
        var raw: [String: [String: Int]] = [:]
        for (k, v) in d { raw[k] = Dictionary(uniqueKeysWithValues: v.map { (String($0.key), $0.value) }) }
        UserDefaults.standard.set(raw, forKey: key)
    }

    private static func histogram(_ id: String, day: Int) -> [Int: Int] {
        let m = override?[id] ?? days[id] ?? [:]
        let cutoff = day - window
        return m.filter { $0.key > cutoff }   // 窗口外的次數不算（28 天）
    }

    /// 28 天內的原始開啟次數（系統的 rawLaunchCount）
    static func rawCount(_ id: String, day: Int = dayIndex()) -> Int {
        histogram(id, day: day).values.reduce(0, +)
    }

    /// 28 天內「有開啟的不同天數」（系統的 uniqueDaysLaunched）
    static func uniqueDays(_ id: String, day: Int = dayIndex()) -> Int {
        histogram(id, day: day).count
    }
}

/// 安裝日期（給 `hyperRecentlyInstalled * 30` 那一項與「最近添加」排序用）。
/// 系統靠 `_ATXAppInfoManager` 的安裝通知與安裝日期；HomePlay 沒有安裝事件，改用「第一次看到這個 App」。
enum AppInstallDates {
    static let key = "HomePlayAppInstallDates"
    /// `hyperRecency` 是 `ATXAnchorModelHyperParameters._parameters` 的鍵
    /// （CFString，`-[ATXComplicationSuggestionScorer inputDescriptionForSignal:complicationDescriptors:]`
    /// 在 0x22eaee5e8 拿去對名字）。值在模型資產裡，這份 dylib 沒有對應的立即數。
    /// 604800（7 天）在同一檔裡出現多次，是錨點模型的 `candidateOccurrencesInLast7Days`，不是這把鍵。
    /// 沒有量到天數之前，這一項不加分。
    static let hyperRecent: TimeInterval? = nil

    nonisolated(unsafe) static var override: [String: Double]?

    nonisolated(unsafe) private static var dates: [String: Double]?

    private static func map() -> [String: Double] {
        if let o = override { return o }
        if let d = dates { return d }
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: Double]
        dates = stored ?? [:]
        return dates ?? [:]
    }

    /// 啟動時對一次：第一次跑這本帳時全部記 0（＝比這本帳更早，不算新安裝）；
    /// 之後才第一次看到的 App 記「現在」。這樣就不會在升級後把所有 App 都當成剛安裝。
    static func bootstrap(_ ids: [String]) {
        guard override == nil, !AppLaunchCounts.frozen else { return }
        let had = UserDefaults.standard.object(forKey: key) != nil
        var m = map()
        let now = Date().timeIntervalSince1970
        var changed = false
        for id in ids where m[id] == nil {
            m[id] = had ? now : 0
            changed = true
        }
        guard changed else { return }
        dates = m
        UserDefaults.standard.set(m, forKey: key)
    }

    static func date(_ id: String) -> Double? {
        guard let d = map()[id] else { return nil }
        return d > 0 ? d : nil        // 0＝比這本帳更早，當成沒有日期
    }

    static func isHyperRecent(_ id: String, now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard let window = hyperRecent, let d = date(id) else { return false }
        return now - d <= window
    }
}

/// 建議豆莢的分數。系統那條公式裡，HomePlay 算得出的項照實算，算不出的項固定 0：
///
/// | 項 | 來源 | HomePlay |
/// | --- | --- | --- |
/// | `uniqueDaysLaunched` | 28 天內有開啟的天數 | 有（`AppLaunchHistory`） |
/// | `rawLaunchCount / 5` | 28 天內的開啟次數 | 有 |
/// | `hasHomescreenWidget * 3` | 主畫面上有沒有這個 App 的小工具 | 有（掃 `SB.layout`） |
/// | `hyperRecentlyInstalled * 30` | 剛安裝 | 門檻 `hyperRecency` 讀不到 ⇒ 0 |
/// | `appPrior / 100` | ATX 的 ML 先驗 | 沒有模型 → 0 |
/// | `heursitics` | ATX 的啟發式 | 沒有 → 0 |
/// | `complicationPrior / 100` | 手錶錶面 complication 的先驗 | 沒有 → 0 |
/// | `watchBundleIdCount * 2` | 配對手錶上的 App 數 | 沒有 → 0 |
///
/// 後四項是 ATX / 手錶的輸入，HomePlay 沒有模型、沒有配對手錶，也沒有可以從這兩者推出的純函式
/// ⇒ 固定 0，不是待辦。`hyperRecency` 則是「有資料、缺一個天數」：天數在模型資產裡，
/// 這份 dylib 只有鍵名，所以這一項也維持 0（見 `AppInstallDates.hyperRecent`）。
enum AppSuggestionScore {
    static func score(_ id: String, homeWidgetApps: Set<String>,
                      now: TimeInterval = Date().timeIntervalSince1970) -> Double {
        let unique = Double(AppLaunchHistory.uniqueDays(id))
        let raw = Double(AppLaunchHistory.rawCount(id))
        let widget = homeWidgetApps.contains(id) ? 3.0 : 0.0
        let hyper = AppInstallDates.isHyperRecent(id, now: now) ? 30.0 : 0.0
        return unique + raw / 5 + widget + hyper
    }

    /// 分數高的在前；同分照名字（系統在平手時還有 App 數量與 DH 順序兩層，這裡只需要一個穩定次序）
    static func ranked(_ apps: [PetApp], homeWidgetApps: Set<String>,
                       now: TimeInterval = Date().timeIntervalSince1970) -> [String] {
        apps.map { ($0, score($0.id, homeWidgetApps: homeWidgetApps, now: now)) }
            .filter { $0.1 > 0 }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                return a.0.title.localizedStandardCompare(b.0.title) == .orderedAscending
            }
            .map { $0.0.id }
    }
}


//
// 只有一套格子，就是主畫面那組（98.5 起、欄距 225、圖示 152、首列頂 241、列距 240、右緣 925.5）。
// 一顆豆莢＝主畫面相鄰的兩欄、相鄰的兩列。四顆圖示就落在那四格上，不另起欄寬、不另起列距。
// 標籤用主畫面同一條：圖示底再 41。畫布放得下主畫面的前三列，所以一列豆莢（第 1、2 列）完整，
// 下一列豆莢（第 3、4 列）跟主畫面的第四列一樣，在畫面下面，捲動才看到。

enum SBLPodKind: Equatable {
    case suggestions
    case recentlyAdded
    case hidden
    case iphone
    case category(SBLibraryCategory)
}

struct SBLPod: Equatable {
    var kind: SBLPodKind
    var title: String
    /// 大圖示的 App id（≤3；第 4 格是右下的小叢集）
    var large: [String]
    /// 右下 2×2 小叢集的 App id（≤4）
    var cluster: [String]
}

enum SBLPodGrid {
    /// 一列兩顆。每顆佔主畫面的兩欄，所以欄數是主畫面的一半。
    static let columns = 2
    static let iconSide: CGFloat = HPTokens.Home.iconSide        // 152，跟主畫面同一顆
    /// 標籤佔的就是主畫面一格裡圖示底下那一截（格子高 218、圖示 152）。
    static var labelBand: CGFloat { Shell.rowH - iconSide }
    static let margin: CGFloat = HPGrid.Home.margin
    /// 主畫面兩顆圖示中間的縫（225 − 152）。豆莢和豆莢之間用同一條。
    static var columnGap: CGFloat { HPTokens.Home.columnPitch - iconSide }
    /// 左緣到右緣＝兩顆主畫面圖示＋中間那條縫。圖示貼著這條外緣，不再往內縮。
    static var podWidth: CGFloat { iconSide * 2 + columnGap }
    /// 底板只包住四顆圖示：上緣是第一列圖示的頂，下緣是第二列圖示的底。標籤在底板下面。
    static var podHeight: CGFloat { HPTokens.Home.rowPitch + iconSide }
    /// 兩欄主畫面的寬度。第二顆豆莢的左緣＝主畫面第三欄的左緣。
    static var columnPitch: CGFloat { HPTokens.Home.columnPitch * 2 }
    /// 下一列豆莢從再下面兩列主畫面開始。中間剩下的就是主畫面本來的列縫。
    static var rowPitch: CGFloat { HPTokens.Home.rowPitch * 2 }
    static var rowGap: CGFloat { rowPitch - podHeight - labelBand }
    static let miniSide: CGFloat = 48
    static let miniPitch: CGFloat = 64
    static var labelHeight: CGFloat { labelBand }
    /// 豆莢圓角。**量出來的，不是猜的**：iPad 11" 實機截圖上，把豆莢左／上緣的亞像素邊界取出來
    /// （用「覆蓋率 0.5」反演，不是憑顏色），再對那一圈做圓擬合：
    /// 建議豆莢 r = 25.71 pt（左上）/ 25.84 pt（右上），殘差平均 0.23 px、最大 0.64 px；
    /// 擬合圓心推回左緣 121.1 px、上緣 731.6 px，跟直接量到的邊界一致。
    /// 豆莢寬 159.6 pt ⇒ **r / 寬 = 0.162**。
    /// 形狀是圓弧，不是連續圓角：同一批點用連續圓角對不上（差數 px），圓弧殘差只有 0.23 px。
    static var cornerRadius: CGFloat { podWidth * SBLPodMetrics.podCornerRatio }
    /// 豆莢底板的等效白幕覆蓋率。實機量到：豆莢外壁紙 121、豆莢內（無圖示處）135，
    /// `135 = 121·(1−α) + 255·α` ⇒ α = 0.104。
    /// 系統的 `podBackgroundView*.visualstyleset` 是「vibrantColorMatrix ＋白 0.7255 染色」，
    /// 但那條矩陣的列和只有 0.009，直接套會把任何背景壓成同一個灰（否證見文件第九節），
    /// 與實測「豆莢內仍看得到背景色」矛盾，所以照實測的等效白幕做。
    static var veil: CGFloat { SBLPodMetrics.podVeil }

    static func podFrame(_ index: Int, top: CGFloat) -> CGRect {
        let c = index % columns, r = index / columns
        return CGRect(x: margin + CGFloat(c) * columnPitch, y: top + CGFloat(r) * rowPitch,
                      width: podWidth, height: podHeight)
    }

    /// 豆莢裡大圖示的框（2×2：0 左上、1 右上、2 左下、3 右下）。
    /// 座標就是主畫面那一格的圖示：橫向欄距 225、直向列距 240。
    static func largeFrame(_ slot: Int, in pod: CGRect) -> CGRect {
        let c = slot % 2, r = slot / 2
        return CGRect(x: pod.minX + CGFloat(c) * HPTokens.Home.columnPitch,
                      y: pod.minY + CGFloat(r) * HPTokens.Home.rowPitch,
                      width: iconSide, height: iconSide)
    }

    /// 小叢集那一格（右下）裡的第 i 顆（2×2，居中）
    static func miniFrame(_ i: Int, in pod: CGRect) -> CGRect {
        let cell = largeFrame(3, in: pod)
        let span = miniSide * 2 + (miniPitch - miniSide)
        let ox = cell.midX - span / 2, oy = cell.midY - span / 2
        return CGRect(x: ox + CGFloat(i % 2) * miniPitch, y: oy + CGFloat(i / 2) * miniPitch,
                      width: miniSide, height: miniSide)
    }

    /// 一頁要擺的豆莢：建議、最近添加、各分類（DH 順序、空類別不畫）、iPhone、已隱藏（沒有就不畫）
    /// 最近添加最多留幾個。系統 `_updateRecentsForInstalledApps:` 收尾是 `w1 = #8`
    /// （`NSMakeRange(0,8)` 的長度），豆莢本身只畫 4 格。
    static let recentsCapacity = 8
    /// 主畫面上的 App，從資料庫開啟還不到這麼多次，就從分類裡拿掉。
    /// `_reorderAndHideDupesForAppsInCategory:` 的 block（0x22e8f37a0）：在
    /// `_homescreenAppsToDedupeAgainst`（ivar +0xd0）裡，而且 `_libraryAppLaunchCounts`（ivar +0x10）
    /// 比 5 小（`fcmp d8, #5; b.pl` 跳過刪除），就從那一類移除。
    static let homeScreenDedupeLaunches = 5

    static func showsInCategory(_ id: String, homeScreenApps: Set<String>) -> Bool {
        !(homeScreenApps.contains(id) && AppLaunchCounts.libraryCount(id) < homeScreenDedupeLaunches)
    }

    static func pods(_ apps: [PetApp], homeWidgetApps: Set<String> = [],
                     homeScreenApps: Set<String> = SB.layout.appsOnHome) -> [SBLPod] {
        var out: [SBLPod] = []
        // 建議：系統那條加權分數（見 AppSuggestionScore），不是單純的總開啟次數
        let ranked = AppSuggestionScore.ranked(apps.filter { !AppRegistry.hidden.contains($0.id) },
                                              homeWidgetApps: homeWidgetApps)
        if !ranked.isEmpty {
            let picked = ranked.prefix(4).compactMap { AppRegistry.app($0) }
            out.append(pod(.suggestions, L("sb.library.cat.suggestions", "建议"), picked))
        }
        // 最近添加：安裝日期新的在前（沒有日期就退回 AppRegistry 的追加順序）
        let visible = apps.filter { !AppRegistry.hidden.contains($0.id) }
        let recent = visible.sorted { a, b in
            let da = AppInstallDates.date(a.id) ?? 0, db = AppInstallDates.date(b.id) ?? 0
            if da != db { return da > db }
            return registryIndex(a.id) > registryIndex(b.id)
        }
        if recent.count > 4 {
            out.append(pod(.recentlyAdded, L("sb.library.cat.recents", "最近添加"),
                           Array(recent.prefix(recentsCapacity).prefix(4))))
        }
        let own = apps.filter { !($0 is PhoneCarPlayApp) }
        for c in SBLibraryCategory.orderedCategories(own) {
            let group = own.filter {
                SBLibraryCategory.category(for: $0) == c && showsInCategory($0.id, homeScreenApps: homeScreenApps)
            }
            guard !group.isEmpty else { continue }
            out.append(pod(.category(c), c.title, AppLaunchCounts.order(group)))
        }
        let phone = apps.filter { $0 is PhoneCarPlayApp }
        if !phone.isEmpty {
            out.append(pod(.iphone, L("sb.library.iphone", "iPhone"), AppLaunchCounts.order(phone)))
        }
        let hidden = AppRegistry.all.filter { AppRegistry.hidden.contains($0.id) }
        if !hidden.isEmpty {
            out.append(pod(.hidden, L("sb.library.cat.hidden", "已隐藏"), hidden))
        }
        return out
    }

    private static func registryIndex(_ id: String) -> Int {
        AppRegistry.all.firstIndex { $0.id == id } ?? 0
    }

    private static func pod(_ kind: SBLPodKind, _ title: String, _ apps: [PetApp]) -> SBLPod {
        let split = SBLCategoryPod.layout(apps)
        return SBLPod(kind: kind, title: title,
                      large: split.large.map(\.id), cluster: split.cluster.map(\.id))
    }

    /// 整份內容的高度（＝捲動上限的依據）
    static func contentHeight(_ pods: [SBLPod]) -> CGFloat {
        guard !pods.isEmpty else { return 0 }
        let rows = (pods.count + columns - 1) / columns
        return CGFloat(rows) * rowPitch - rowGap
    }
}

enum SBLibraryCategory: String, CaseIterable {
    // 順序＝DH 表的順序（Games 起、Travel 止），系統照這份排
    case games = "DH1001"
    case social = "DH1002"
    case entertainment = "DH1003"
    case creativity = "DH1004"
    case productivity = "DH1005"
    case education = "DH1006"
    case reading = "DH1007"
    case health = "DH1008"
    case other = "DH1009"
    case utilities = "DH1011"
    case shopping = "DH1012"
    case travel = "DH1013"

    /// loctable 的鍵就是英文顯示名（Productivity→Productivity & Finance、Reading & Reference→Information & Reading）
    var title: String {
        switch self {
        case .games: return L("sb.library.cat.games", "游戏")
        case .social: return L("sb.library.cat.social", "社交")
        case .entertainment: return L("sb.library.cat.entertainment", "娱乐")
        case .creativity: return L("sb.library.cat.creativity", "创意")
        case .productivity: return L("sb.library.cat.productivity", "效率与财务")
        case .education: return L("sb.library.cat.education", "教育")
        case .reading: return L("sb.library.cat.reading", "信息与阅读")
        case .health: return L("sb.library.cat.health", "健康与健身")
        case .other: return L("sb.library.cat.other", "其他")
        case .utilities: return L("sb.library.cat.utilities", "实用工具")
        case .shopping: return L("sb.library.cat.shopping", "购物与美食")
        case .travel: return L("sb.library.cat.travel", "旅行")
        }
    }

    /// HomePlay 自家 App 的手寫對映。不是系統那張 plist：那張只有 com.apple.*，
    /// 我們的 App 沒有 App Store genre 可查，只能照「最接近的系統 App 會落在哪一類」填（🟡）。
    /// 系統 App 的實際歸類（AppDirectoryDefaultCategories.plist）：mobiletimer、Preferences→Utilities；
    /// mobilecal、reminders、mobilesafari、MobileAddressBook→Productivity；Music、podcasts→Entertainment；
    /// MobileSMS、facetime→Social；weather→Information & Reading；Home、findmy→Utilities。
    private static let own: [String: SBLibraryCategory] = [
        "timers": .utilities,      // mobiletimer
        "worldclock": .utilities,  // 系統「時鐘」也在 Utilities
        "alarms": .utilities,
        "settings": .utilities,    // Preferences
        "home": .utilities,        // Home
        "findmy": .utilities,
        "intercom": .utilities,    // 對講＝家裡的事，跟 Home 同一類
        "calendar": .productivity,
        "reminders": .productivity,
        "safari": .productivity,
        "contacts": .productivity, // MobileAddressBook
        "music": .entertainment,
        "podcasts": .entertainment,
        "sing": .entertainment,    // 跟唱＝聽歌，系統沒有對應 App
        "messages": .social,       // MobileSMS
        "facetime": .social,
        "games": .games,
        "weather": .reading,       // weather → Information & Reading
        "recipes": .shopping,      // 系統沒有食譜 App；App Store 的「Food & Drink」歸 Shopping & Food
        "cliotalk": .other,        // 助理，系統沒有對應 App
        "carplay": .other,         // 手機的 App 入口，系統的 App Library 沒有這一類
    ]

    /// 一個 App 落在哪一類。iPhone 的 App 不走這裡（另成一區，照 Mac 的 App 瀏覽）；
    /// Web App 沒有 genre，一律 Other。
    static func category(for app: PetApp) -> SBLibraryCategory {
        if let c = own[app.id] { return c }
        if app.id.hasPrefix(WebApp.idPrefix) { return .other }
        return .other
    }

    /// 系統的類別順序：合計開啟次數高的在前；平手比那一類的 App 數量（`_categoryComparator` 的 block
    /// 先比兩份次數查表，相等才比陣列 count，位址 0x22e8f136c）；再平手維持 DH 表順序（穩定）。
    static func orderedCategories(_ apps: [PetApp]) -> [SBLibraryCategory] {
        let groups = Dictionary(grouping: apps, by: category(for:))
        return allCases.enumerated().sorted { a, b in
            let ga = groups[a.element] ?? [], gb = groups[b.element] ?? []
            let wa = ga.reduce(0) { $0 + AppLaunchCounts.total($1.id) }
            let wb = gb.reduce(0) { $0 + AppLaunchCounts.total($1.id) }
            if wa != wb { return wa > wb }
            if ga.count != gb.count { return ga.count > gb.count }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// 分類後的區塊：空類別不畫（系統也是如此）。搜尋時是單一結果清單，不分類。
    static func sections(_ apps: [PetApp], searching: Bool) -> [(title: String?, apps: [PetApp])] {
        let own = apps.filter { !($0 is PhoneCarPlayApp) }
        let phone = apps.filter { $0 is PhoneCarPlayApp }
        if searching {
            // SBHLibrarySearchController：結果是另一張表，不分類（iPhone App 仍標一區）
            var out: [(title: String?, apps: [PetApp])] = []
            if !own.isEmpty { out.append((nil, own)) }
            if !phone.isEmpty { out.append((L("sb.library.iphone", "iPhone"), phone)) }
            return out
        }
        var out: [(title: String?, apps: [PetApp])] = []
        for c in orderedCategories(own) {
            let group = own.filter { category(for: $0) == c }
            guard !group.isEmpty else { continue }   // 空類別不畫
            out.append((c.title, AppLaunchCounts.order(group)))   // 類別內：開啟次數高的在前，平手照名字
        }
        if !phone.isEmpty { out.append((L("sb.library.iphone", "iPhone"), AppLaunchCounts.order(phone))) }
        return out
    }

    /// 搜尋結果的順序：前綴命中（標題、再逐字詞首）優先，其餘 A→Z。
    /// 系統用 prefixComparator＋aToZComparator 串起來（SBHIconLibraryQuery）；這裡照同一個規則。
    static func hits(_ apps: [PetApp], query raw: String) -> [PetApp] {
        let q = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return apps }
        let matched = apps.filter { $0.title.lowercased().contains(q) || $0.id.lowercased().contains(q) }
        return matched.sorted { a, b in
            let ra = prefixRank(a, q), rb = prefixRank(b, q)
            if ra != rb { return ra < rb }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    private static func prefixRank(_ app: PetApp, _ q: String) -> Int {
        let t = app.title.lowercased()
        if t.hasPrefix(q) { return 0 }
        if t.split(whereSeparator: { $0 == " " || $0 == "-" }).contains(where: { $0.hasPrefix(q) }) { return 1 }
        return 2
    }
}

// MARK: - 自檢

enum SBLibraryCategorySelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        // 類別順序＝DH 表（Games 起、Travel 止；沒有 DH1010）
        let raw = SBLibraryCategory.allCases.map(\.rawValue)
        check(raw == ["DH1001", "DH1002", "DH1003", "DH1004", "DH1005", "DH1006", "DH1007", "DH1008",
                      "DH1009", "DH1011", "DH1012", "DH1013"] && !raw.contains("DH1010"),
              "App 資料庫：類別照 DH 表的順序，沒有 DH1010")   // l10n-ignore

        // 每個自家 App 都有對映，而且每個只出現在一區
        let all = AppRegistry.visible.filter { !($0 is PhoneCarPlayApp) }
        let secs = SBLibraryCategory.sections(all, searching: false)
        let placed = secs.flatMap(\.apps)
        check(secs.allSatisfy { $0.title != nil && !$0.title!.isEmpty } && placed.count == all.count
              && Set(placed.map(\.id)) == Set(all.map(\.id)),
              "App 資料庫：每個 App 剛好落在一類，每類都有名字")   // l10n-ignore

        // 空的類別不畫（Educations、Creativity、Travel 目前沒有 App）
        check(!secs.contains { $0.apps.isEmpty },
              "App 資料庫：空類別整區不畫")   // l10n-ignore

        // 系統 App 的歸類照 AppDirectoryDefaultCategories.plist（Examples：時鐘→Utilities、Music→Entertainment、MobileSMS→Social）
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        let expect: [(String, SBLibraryCategory)] = [("timers", .utilities), ("music", .entertainment),
                                                     ("messages", .social), ("safari", .productivity),
                                                     ("weather", .reading), ("games", .games)]
        check(expect.allSatisfy { id, c in byID[id].map { SBLibraryCategory.category(for: $0) == c } ?? true },
              "App 資料庫：系統對應的分類（時鐘→實用工具、音樂→娛樂、訊息→社交、Safari→效率、天氣→資訊、遊戲→遊戲）")   // l10n-ignore

        // 搜尋：前綴命中優先，其餘 A→Z；空字串回全部
        let probe = ["timers", "worldclock", "weather", "calendar"].compactMap { AppRegistry.app($0) }
        let q = SBLibraryCategory.hits(probe, query: "")
        check(q.count == probe.count, "App 資料庫：沒有搜尋字串時不過濾")   // l10n-ignore
        let hits = SBLibraryCategory.hits(probe, query: "ti")
        check(hits.first?.id == "timers" && hits.count == 1, "App 資料庫：搜尋前綴命中排第一")   // l10n-ignore
        let none = SBLibraryCategory.hits(probe, query: "zzzz-none")
        check(none.isEmpty, "App 資料庫：搜尋沒有結果是空的")   // l10n-ignore

        // 豆莢網格：圖示落在主畫面的格子上；下一列從主畫面第 3 列起（第 4 列在畫面下面）
        let gridPods = SBLPodGrid.pods(AppRegistry.visible)
        let f0 = SBLPodGrid.podFrame(0, top: SBUI.libraryTop)
        let f1 = SBLPodGrid.podFrame(1, top: SBUI.libraryTop)
        let nextRow = SBLPodGrid.podFrame(SBLPodGrid.columns, top: SBUI.libraryTop)
        let homeIcon = { (c: Int, r: Int) in Shell.iconRect(in: Shell.cell(c, r)) }
        check(SBLPodGrid.columns == 2
              && SBLPodGrid.iconSide == HPTokens.Home.iconSide
              && abs(f0.minX - HPGrid.Home.margin) < 0.01
              && abs(f1.maxX - HPGrid.Home.trailing) < 0.01
              && abs(f1.minX - (HPGrid.Home.margin + 2 * HPTokens.Home.columnPitch)) < 0.01
              && abs(f0.minY - HPTokens.Home.gridTop) < 0.5
              && abs(nextRow.minY - (HPTokens.Home.gridTop + 2 * HPTokens.Home.rowPitch)) < 0.01
              && SBLPodGrid.largeFrame(0, in: f0) == homeIcon(0, 0)
              && SBLPodGrid.largeFrame(1, in: f0) == homeIcon(1, 0)
              && SBLPodGrid.largeFrame(2, in: f0) == homeIcon(0, 1)
              && SBLPodGrid.largeFrame(3, in: f0) == homeIcon(1, 1)
              && SBLPodGrid.largeFrame(0, in: f1) == homeIcon(2, 0)
              && abs(SBUI.libraryPodClipBottom - (f0.maxY + SBLPodGrid.labelBand)) < 0.01
              && SBUI.libraryPodClipBottom <= nextRow.minY,
              "App 資料庫：豆莢的圖示就落在主畫面的格子上（兩欄兩列，第一列頂 241，下一列從第 3 列開始，裁在完整的一列）")   // l10n-ignore
        check(abs(SBUI.librarySearch.minX - HPGrid.Home.margin) < 0.01
              && abs(SBUI.librarySearch.maxX - (HPGrid.Home.margin + 3 * HPTokens.Home.columnPitch)) < 0.01
              && abs(SBUI.librarySearch.height - 96) < 0.01
              && SBUI.librarySearch.maxX < Shell.avatarRect.minX,
              "App 資料庫：搜尋欄佔前三欄、高 96，第四欄留給頭像")   // l10n-ignore
        check(gridPods.allSatisfy { $0.large.count + $0.cluster.count > 0 && $0.large.count <= 4 && $0.cluster.count <= 4
                                     && !($0.large.count == 4 && !$0.cluster.isEmpty) },
              "App 資料庫：每顆豆莢都有內容（4 顆全大，或 3 大＋≤4 小叢集）")   // l10n-ignore
        let kinds = gridPods.map(\.kind)
        check(gridPods.first.map { $0.kind == .suggestions || $0.kind == .recentlyAdded } == true
              && !(kinds.contains(.hidden) && kinds.last != .hidden),
              "App 資料庫：豆莢從建議／最近添加開始，已隱藏排最後")   // l10n-ignore
        check(abs(SBLPodGrid.contentHeight(gridPods)
                  - (CGFloat((gridPods.count + SBLPodGrid.columns - 1) / SBLPodGrid.columns) * SBLPodGrid.rowPitch - SBLPodGrid.rowGap)) < 0.01,
              "App 資料庫：內容高度＝列數×列距−一條縫（捲動上限用它）")   // l10n-ignore

        // 建議排序＝系統那條加權公式（uniqueDays + raw/5 + 主畫面小工具×3 + 剛安裝×30），不是總次數。
        // 用 override 造一組「總次數高但天數少」對「總次數低但天數多」的對照，確認排序看的是分數。
        let day0 = AppLaunchHistory.dayIndex()
        AppLaunchHistory.override = [
            "timers": Dictionary(uniqueKeysWithValues: (0..<4).map { (day0 - $0, 5) }),   // 20 次，4 天
            "worldclock": Dictionary(uniqueKeysWithValues: (0..<10).map { (day0 - $0, 1) }), // 10 次，10 天
        ]
        let sTimers = AppSuggestionScore.score("timers", homeWidgetApps: [])
        let sWorld = AppSuggestionScore.score("worldclock", homeWidgetApps: [])
        check(abs(sTimers - (4 + 20.0 / 5)) < 0.001 && abs(sWorld - (10 + 10.0 / 5)) < 0.001
              && sWorld > sTimers,
              "App 資料庫：建議分數＝天數＋次數/5（20 次 4 天輸給 10 次 10 天）")   // l10n-ignore
        // 主畫面小工具那一項是 +3；剛安裝那一項（×30）沒有量到門檻，維持 0——不寫死天數。
        check(abs(AppSuggestionScore.score("worldclock", homeWidgetApps: ["worldclock"]) - (sWorld + 3)) < 0.001,
              "App 資料庫：主畫面上有小工具加 3 分")   // l10n-ignore
        AppInstallDates.override = ["timers": Date().timeIntervalSince1970]
        check(AppInstallDates.hyperRecent == nil
              && AppSuggestionScore.score("timers", homeWidgetApps: []) == sTimers,
              "App 資料庫：hyperRecency 沒量到就不加分（不寫死天數）")   // l10n-ignore
        // 28 天窗口：29 天前的次數不算
        AppLaunchHistory.override = ["timers": [day0 - AppLaunchHistory.window - 1: 99, day0: 1]]
        check(AppLaunchHistory.rawCount("timers") == 1 && AppLaunchHistory.uniqueDays("timers") == 1,
              "App 資料庫：28 天窗口外的開啟不算（29 天前 99 次只算 1 次）")   // l10n-ignore
        AppLaunchHistory.override = nil
        AppInstallDates.override = nil

        // 最近添加：安裝日期新的在前、上限 8、已隱藏不出現
        let probeIDs = ["timers", "worldclock", "alarms", "weather", "calendar", "reminders",
                        "music", "podcasts", "sing", "recipes"]
        AppInstallDates.override = Dictionary(uniqueKeysWithValues: probeIDs.enumerated().map {
            ($0.element, 1_000_000 + Double($0.offset))   // 越後面越新
        })
        let probeApps = probeIDs.compactMap { AppRegistry.app($0) }
        let recentPods = SBLPodGrid.pods(probeApps)
        let recents = recentPods.first { $0.kind == .recentlyAdded }
        check(recents?.large == ["recipes"] || recents?.large.contains("recipes") == true,
              "App 資料庫：最近添加把最新安裝的排在前面")   // l10n-ignore
        check(SBLPodGrid.recentsCapacity == 8, "App 資料庫：最近添加容量 8（固件 NSMakeRange(0,8)）")   // l10n-ignore
        AppInstallDates.override = nil


        // 分類去重：主畫面上、從資料庫開啟不到 5 次的 App 不進分類；滿 5 次就回來。
        // 用一組指定的主畫面，不依賴這台機器實際擺了什麼。
        let home: Set<String> = ["timers", "home"]
        AppLaunchCounts.override = (apps: [:], library: ["timers": 4])
        let hiddenIDs = SBLPodGrid.pods(AppRegistry.visible, homeScreenApps: home)
            .flatMap { $0.large + $0.cluster }
        AppLaunchCounts.override = (apps: [:], library: ["timers": 5])
        let shownIDs = SBLPodGrid.pods(AppRegistry.visible, homeScreenApps: home)
            .flatMap { $0.large + $0.cluster }
        AppLaunchCounts.override = nil
        check(SBLPodGrid.homeScreenDedupeLaunches == 5
              && !hiddenIDs.contains("timers") && !hiddenIDs.contains("home")
              && shownIDs.contains("timers") && !shownIDs.contains("home"),
              "App 資料庫：主畫面上的 App 要從資料庫開滿 5 次才回到分類（4 次還不回來）")   // l10n-ignore

        // 展開是 0.2 秒交叉淡化：起點在 0、1 秒內到 1；收回時展開頁留到淡出結束。
        SB.setLibraryExpanded(.utilities, now: 5000, immediate: false)
        check(SB.libraryExpanded == .utilities && SB.libraryReveal.value(5000) < 0.05 && !SB.libraryReveal.done(5000),
              "App 資料庫：展開從 0 開始交叉淡入")   // l10n-ignore
        check(SB.libraryReveal.done(5001) && abs(SB.libraryReveal.value(5001) - 1) < 0.02,
              "App 資料庫：0.2 秒交叉淡化在 1 秒內結束")   // l10n-ignore
        // 內容縮放：固件 stiffness 246.74、damping 31.42 ⇒ ζ ≈ 1、ω ≈ 5π（response 0.4）；延遲 0.05。
        // 這兩個是固件裡存成小數點後兩位的圓整值（25π² = 246.7401、10π = 31.4159），所以容差取 0.001。
        check(abs(SBLPodZoom.spring.damping - 1) < 0.001 && abs(SBLPodZoom.spring.response - 0.4) < 0.001
              && abs(SBLPodZoom.delay - 0.05) < 1e-12,
              "App 資料庫：展開縮放＝臨界阻尼 0.4 秒、延遲 0.05（固件 246.74／31.42）")   // l10n-ignore
        check(abs(SBLPodZoom.scale(at: 0) - SBLPodGrid.podWidth / (HPGrid.Home.trailing - HPGrid.Home.margin)) < 1e-9
              && SBLPodZoom.scale(at: 1) == 1 && SBLPodZoom.scale(at: 0.5) > SBLPodZoom.scale(at: 0.2),
              "App 資料庫：展開縮放從豆莢寬起步、單調放大到滿版")   // l10n-ignore
        check(SB.libraryZoom.value(5000 + SBLPodZoom.delay * 0.5) < 0.005
              && !SB.libraryZoom.done(5000 + SBLPodZoom.delay * 0.5),
              "App 資料庫：展開縮放要等 0.05 秒才動")   // l10n-ignore
        SB.setLibraryExpanded(nil, now: 6000, immediate: false)
        check(SB.libraryClosing && SB.libraryExpanded == .utilities, "App 資料庫：收回時展開頁留到淡出結束")   // l10n-ignore
        _ = SB.animating(6001)
        check(SB.libraryExpanded == nil && !SB.libraryClosing, "App 資料庫：淡出結束才清掉展開頁")   // l10n-ignore

        let catApps = SBLibraryCategory.sections(AppRegistry.visible, searching: false)
        if let firstCat = gridPods.compactMap({ p -> SBLibraryCategory? in
            if case .category(let c) = p.kind { return c } else { return nil } }).first {
            SB.libraryExpanded = firstCat
            let expanded = SBUI.libraryExpandedApps()
            let expect = (catApps.first { $0.title == firstCat.title }?.apps ?? []).map(\.id)
                .filter { SBLPodGrid.showsInCategory($0, homeScreenApps: SB.layout.appsOnHome) }
            check(expanded.map(\.id) == expect && !expanded.isEmpty
                  && SBUI.libraryExpandedCells().allSatisfy { $0.minX >= 14 && $0.maxX <= 1010 && $0.minY >= SBUI.libraryTop },
                  "App 資料庫：展開頁列出該類全部 App，格子都在畫面裡")   // l10n-ignore
            // 標題帶：只有分類豆莢有，點在標題帶上要回那一類
            if let idx = gridPods.firstIndex(where: { if case .category(let c) = $0.kind { return c == firstCat } else { return false } }) {
                let f = SBLPodGrid.podFrame(idx, top: SBUI.libraryTop)
                let bandCentre = CGPoint(x: f.midX, y: f.maxY + SBLPodGrid.labelHeight / 2)
                check(SBUI.libraryPodTitle(at: bandCentre, offset: 0) == firstCat
                      && SBUI.libraryPodTitle(at: CGPoint(x: f.midX, y: f.minY + 40), offset: 0) == nil,
                      "App 資料庫：點豆莢底下的標題才展開，點圖示區不展開")   // l10n-ignore
            }
            SB.libraryExpanded = nil
        }

        SB.libraryQuery = ""
        let lay = SBUI.libraryLayout()
        let secList = SBUI.librarySections(AppRegistry.visible)
        check(lay.headers.count == secList.count
              && zip(lay.headers.map(\.title), secList.map { $0.title ?? "" }).allSatisfy { $0 == $1 },
              "App 資料庫：分區標題照分區順序")   // l10n-ignore

        // 類別內排序：開啟次數高的在前，平手照名字（系統的 _appBundleIDTotalLaunchComparator）
        let trio = ["timers", "worldclock", "settings"].compactMap { AppRegistry.app($0) }
        if trio.count == 3 {
            AppLaunchCounts.override = (apps: ["settings": 5, "worldclock": 2], library: ["timers": 9])
            let ordered = AppLaunchCounts.order(trio).map(\.id)
            let tie = AppLaunchCounts.order(trio.filter { $0.id != "timers" }).map(\.id)
            AppLaunchCounts.override = nil
            check(ordered == ["timers", "settings", "worldclock"] && tie == ["settings", "worldclock"],
                  "App 資料庫：類別內照開啟次數排（兩本帳合計），平手照名字")   // l10n-ignore
            check(AppLaunchCounts.total("timers") == 0, "App 資料庫：自檢不把次數寫進偏好")   // l10n-ignore
        }

        // 豆莢內容：≤4 個全大；>4 個是 3 大 + 右下 4 小小叢集（固件四個資料夾＋三個來源一致）
        check(SBLCategoryPod.slots(count: 0).isEmpty
              && SBLCategoryPod.slots(count: 3) == [.large(0), .large(1), .large(2)]
              && SBLCategoryPod.slots(count: 4) == [.large(0), .large(1), .large(2), .large(3)]
              && SBLCategoryPod.slots(count: 5) == [.large(0), .large(1), .large(2), .cluster([4])]
              && SBLCategoryPod.slots(count: 9) == [.large(0), .large(1), .large(2), .cluster([4, 5, 6, 7])],
              "App 資料庫：豆莢 ≤4 個全大、>4 個是 3 大＋右下 2×2 小叢集")   // l10n-ignore
        let podApps = ["timers", "settings", "home", "findmy", "intercom", "worldclock"].compactMap { AppRegistry.app($0) }
        let pod = SBLCategoryPod.layout(podApps)
        check(pod.large.count == 3 && pod.cluster.count == 2 && pod.large.first?.id == podApps.first?.id
              && pod.cluster.first?.id == podApps[4].id,
              "App 資料庫：豆莢內容照順序取 3 大，其餘進小叢集")   // l10n-ignore

        // 豆莢幾何：量自 iPadOS 27 模擬器（AX frame）——寬高、圖示、pitch、padding 要自洽
        let M = SBLPodMetrics.self
        check(abs((M.podPadding + M.iconSize + M.iconGap + M.iconSize + M.podPadding) - M.podSize.width) < 0.5,
              "App 資料庫：豆莢寬＝左右邊距＋兩顆圖示＋中間縫（178.33）")   // l10n-ignore
        check(M.iconGap == 8 && M.podPadding == 13 && M.iconSize == 72 && abs(M.podLabelHeight - 36.5) < 0.01,
              "App 資料庫：豆莢圖示 72、縫 8、邊距 13、標籤區 36.5")   // l10n-ignore
        check(abs(M.scale(M.podSize.width) - 176.94) < 0.5 && M.podColumnGap > 20,
              "App 資料庫：豆莢換算到 1024 畫布後約 177 寬")   // l10n-ignore

        // 豆莢圓角與底色：實機量到的比例，不是猜的
        check(abs(M.podCornerRatio - 0.162) < 0.002 && M.podCornerRadius == 26
              && abs(SBLPodGrid.cornerRadius - SBLPodGrid.podWidth * M.podCornerRatio) < 0.01,
              "App 資料庫：豆莢圓角＝寬的 0.162（實機 26 pt / 159.6 pt，圓擬合殘差 0.23 px）")   // l10n-ignore
        check(abs(M.podVeil - 0.104) < 0.001
              && abs(((121.0 * (1 - M.podVeil)) + 255 * M.podVeil) - 135) < 0.6,
              "App 資料庫：底板白幕 0.104（壁紙 121 → 豆莢 135）")   // l10n-ignore
        // 否證：把系統那條 vibrant 矩陣套上去，背景差 38 級只會讓底板差不到 1 級（列和 0.0091）；
        // 實機豆莢內差 47 級。矩陣與像素互相矛盾，所以底板用實測的等效白幕，不是矩陣。
        check(M.vibrantRowSum * M.measuredBackgroundDelta < 1
              && M.measuredPodDelta > 40 && abs(M.vibrantBias - 0.16409) < 1e-9
              && abs(M.vibrantWhiteTint - 0.7255) < 1e-9,
              "App 資料庫：vibrant 矩陣會把背景壓平，和實測豆莢差 47 級矛盾 ⇒ 不套矩陣")   // l10n-ignore

        // 欄位排法：4 欄、左右邊距對稱，欄距是「扣掉邊距後均分」而不是固定常數。
        // 這條會把兩張實機截圖的 OCR 結果一起釘住：第一欄中心必須等於 (寬 − 3×pitch)/2。
        func firstColumnCentre(_ width: CGFloat, measuredPitch: CGFloat) -> CGFloat {
            (width - CGFloat(M.podColumnCount - 1) * measuredPitch) / 2
        }
        check((2 * M.firstPodLeft + CGFloat(M.podColumnCount) * M.podSize.width
               + CGFloat(M.podColumnCount - 1) * M.podColumnGap) - M.referenceWidth < 0.01,
              "App 資料庫：4 欄＋3 縫＋左右邊距剛好等於螢幕寬（1032）")   // l10n-ignore
        check(M.podColumnCount == 4 && M.podRowCount == 3 && M.podSlotsPerPage == 12,
              "App 資料庫：一頁 4 欄 × 3 列 = 12 格（實機 11 顆豆莢排滿 3 列）")   // l10n-ignore
        check(abs(firstColumnCentre(834, measuredPitch: 184.3) - 138.9) < 2
              && abs(firstColumnCentre(1194, measuredPitch: 195.2) - 303.3) < 2,
              "App 資料庫：對稱邊距公式要對得上實機 OCR 的第一欄中心（直向 138.9、橫向 303.3）")   // l10n-ignore
        check(abs(M.podColumnPitch - 210.56) < 0.05 && abs(M.podRowPitch - 216.6) < 0.05,
              "App 資料庫：欄 pitch 210.56、列 pitch 216.6（豆莢高 201.5＋縫 15.1）")   // l10n-ignore

        // 實機交叉驗證（兩個獨立來源對撞）：圖示偵測給「61 pt、pitch 74、左緣距豆莢中心 67.4」，
        // OCR 給「欄 pitch 184.3」。用圖示反解出來的豆莢寬與欄 gap 必須同時滿足這兩組。
        let devicePodWidth = 2 * 61 + 13 + 2 * 12.3          // 159.6
        let deviceColumnGap = 184.3 - devicePodWidth         // 24.7
        check(abs(devicePodWidth / 2 - 12.3 - 67.4) < 1.5 && deviceColumnGap > 20,
              "App 資料庫：實機豆莢寬 159.6／欄 gap 24.7 要同時對上圖示位置（67.4）與 OCR 欄 pitch（184.3）")   // l10n-ignore

        // 類別順序：合計次數高的在前；平手比 App 數量；再平手維持 DH 順序
        if let one = AppRegistry.app("recipes"), let game = AppRegistry.app("games") {
            let probe = [one, game]
            let base = SBLibraryCategory.orderedCategories(probe)
            AppLaunchCounts.override = (apps: ["recipes": 4], library: [:])
            let heavy = SBLibraryCategory.orderedCategories(probe)
            AppLaunchCounts.override = nil
            check(base.first == .games && heavy.first == .shopping,
                  "App 資料庫：類別照合計次數排（食譜 4 次就排到遊戲前面），平手照 DH 順序")   // l10n-ignore
        }
    }
}
