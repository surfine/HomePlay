// 遊戲：列出這台 Mac 上的遊戲（/Applications 與 ~/Applications，含一層子資料夾），用 App 自己的圖示，點一下在 Mac 上打開。
// 怎樣算遊戲：Info.plist 的 LSApplicationCategoryType 是 public.app-category.games，或 public.app-category.*-games（動作、益智…）。
// 只讀 Info.plist，不碰遊戲的資料；掃描在背景佇列、每次打開 App 重掃一次（裝了新遊戲就會出現）。
// 快照旗標：--demo-games [list|empty]（假的遊戲名稱與程式畫的圖示，不讀這台 Mac 的 App）

import AppKit

struct MacGame: Equatable {
    var name: String
    var path: String          // 示範資料是空字串
    var bundleID: String
    var symbol = "gamecontroller.fill"   // 示範用
    var color = srgb(0x5E5CE6)            // 示範用
}

enum MacGames {
    /// 是不是遊戲類（純函數，selftest 直接驗）
    static func isGame(category: String?) -> Bool {
        guard let c = category?.lowercased(), c.hasPrefix("public.app-category.") else { return false }
        return c == "public.app-category.games" || c.hasSuffix("-games")
    }

    static var roots: [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
    }

    /// 掃一遍（背景執行緒叫）：每個資料夾往下一層（例如 /Applications/Games/xxx.app），照顯示名稱排
    static func scan(_ roots: [URL] = roots) -> [MacGame] {
        let fm = FileManager.default
        var apps: [URL] = []
        for r in roots {
            guard let items = try? fm.contentsOfDirectory(at: r, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for u in items {
                if u.pathExtension == "app" { apps.append(u); continue }
                guard (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                      let sub = try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
                apps += sub.filter { $0.pathExtension == "app" }
            }
        }
        var seen = Set<String>(), out: [MacGame] = []
        for u in apps {
            guard let info = NSDictionary(contentsOf: u.appendingPathComponent("Contents/Info.plist")),
                  isGame(category: info["LSApplicationCategoryType"] as? String) else { continue }
            let bid = info["CFBundleIdentifier"] as? String ?? u.path
            guard !seen.contains(bid) else { continue }
            seen.insert(bid)
            let name = (fm.displayName(atPath: u.path) as NSString).deletingPathExtension
            out.append(MacGame(name: name, path: u.path, bundleID: bid))
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

final class GamesApp: PetApp {
    static let shared = GamesApp()
    let id = "games"
    var title: String { L("app.games", "游戏") }
    let icon = AppIcon(color: srgb(0x5E5CE6), symbol: "gamecontroller.fill", system: "/System/Applications/Games.app")

    private weak var face: Face?
    private var games: [MacGame] = []
    private var loaded = false
    private var scanning = false
    private var demo: String?
    private var scroll = AppScroll()
    private var contentHeight: CGFloat = 0
    private var hits: [(CGRect, MacGame)] = []
    private var opened: (name: String, at: Double)?

    private static let top = HPTokens.contentTop, cols = 4
    private static let cellW = AppUI.contentW / CGFloat(cols), icon: CGFloat = 160, rowH: CGFloat = 256

    private init() {
        if let i = CommandLine.arguments.firstIndex(of: "--demo-games") {
            let a = CommandLine.arguments
            demo = i + 1 < a.count && !a[i + 1].hasPrefix("--") ? a[i + 1] : "list"
        } else if SnapshotPrivacy.active { demo = "list" }   // 快照：不讀這台 Mac 的 App
    }

    static let demoGames: [MacGame] = [
        MacGame(name: "Lumen Drift", path: "", bundleID: "demo.1", symbol: "sparkles", color: srgb(0x5856D6)),          // l10n-ignore：示範
        MacGame(name: "Paper Kingdoms", path: "", bundleID: "demo.2", symbol: "crown.fill", color: srgb(0xFF9500)),      // l10n-ignore
        MacGame(name: "Harbor Lights", path: "", bundleID: "demo.3", symbol: "sailboat.fill", color: srgb(0x0A84FF)),    // l10n-ignore
        MacGame(name: "Tiny Orchard", path: "", bundleID: "demo.4", symbol: "leaf.fill", color: srgb(0x34C759)),         // l10n-ignore
        MacGame(name: "Night Circuit", path: "", bundleID: "demo.5", symbol: "car.fill", color: srgb(0xFF375F)),         // l10n-ignore
        MacGame(name: "Word Garden", path: "", bundleID: "demo.6", symbol: "textformat.abc", color: srgb(0x30B0C7)),     // l10n-ignore
    ]

    func didOpen(now: Double) {
        scroll = AppScroll()
        if let d = demo { games = d == "empty" ? [] : Self.demoGames; loaded = true; return }
        guard !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let list = MacGames.scan()
            DispatchQueue.main.async { self?.games = list; self?.loaded = true; self?.scanning = false; self?.face?.forceDirty = true }
        }
    }

    func tick(_ now: Double) -> Bool {
        if HPComponents.needsFrame(now) { return true }
        if let o = opened, now - o.at > 2.5 { opened = nil; return true }
        return false
    }

    func render(into g: CGContext, face: Face, rect: CGRect, now: Double) {
        self.face = face
        g.setFillColor(AppUI.bg.cgColor); g.fill(rect)
        hits = []
        if !loaded {
            AppUI.center(face, g, L("music.lib.loading", "读取中…"), AppUI.font(34), cx: 512, y: 520, AppUI.secondary)
        } else if games.isEmpty {
            let c = CGRect(x: 512 - 70, y: 300, width: 140, height: 140)
            g.setFillColor(AppUI.grouped.cgColor); g.fillEllipse(in: c)
            face.drawSymbol(g, "gamecontroller.fill", in: c.insetBy(dx: 30, dy: 36), color: AppUI.secondary, weight: .regular)
            let t = L("games.empty", "这台 Mac 上没有游戏")
            AppUI.center(face, g, t, AppUI.fitted(t, size: 48, weight: .bold, maxWidth: 800), cx: 512, y: 528, AppUI.label)
            let b = L("games.empty.body", "从 App Store 安装的游戏会出现在这里")
            AppUI.center(face, g, b, AppUI.fitted(b, size: 32, weight: .regular, maxWidth: 800), cx: 512, y: 584, AppUI.secondary)
            HPAX.note(g, CGRect(x: 112, y: 300, width: 800, height: 320), .text, t, value: b, shape: .rounded(24))
        } else {
            drawGrid(g, face)
        }
        // 頂端：內容捲到大標題底下時柔和淡出
        if scroll.offset > 0 { g.setFillColor(AppUI.bg.cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: AppUI.topEdge - 40)); HPComponents.topFade(g, AppUI.bg, solidTo: AppUI.topEdge - 40) }
        AppUI.title(g, face, title)
        if let o = opened { drawToast(g, face, String(format: L("games.opened", "已在 Mac 上打开「%@」"), o.name)) }
    }

    private func drawGrid(_ g: CGContext, _ face: Face) {
        let x0 = AppUI.margin, nf = AppUI.font(28, .medium)
        let px = Int((Self.icon * face.renderPixelScale).rounded())
        for (i, game) in games.enumerated() {
            let col = i % Self.cols, row = i / Self.cols
            let cell = CGRect(x: x0 + CGFloat(col) * Self.cellW, y: Self.top + CGFloat(row) * Self.rowH - scroll.offset, width: Self.cellW, height: Self.rowH)
            guard cell.maxY > AppUI.topEdge - 60, cell.minY < 1024 else { continue }
            let ir = CGRect(x: cell.midX - Self.icon / 2, y: cell.minY + 8, width: Self.icon, height: Self.icon)
            let k = 1 - 0.06 * Press.amount(ir)
            let r = HPComponents.scaled(ir, k)
            if !game.path.isEmpty, let img = AppIconArt.systemIcon(game.path, px: max(64, px)) {
                g.saveGState(); g.interpolationQuality = .high; g.draw(img, in: r); g.restoreGState()
            } else {
                AppIconArt.drawGlassy(g, face: face, icon: AppIcon(color: game.color, symbol: game.symbol), in: r)
            }
            let lines = MediaUI.wrap(game.name, nf, Self.cellW - 24, maxLines: 2)
            for (j, l) in lines.enumerated() {
                AppUI.center(face, g, l, nf, cx: cell.midX, y: ir.maxY + 44 + CGFloat(j) * 34, AppUI.label)
            }
            hits.append((CGRect(x: cell.minX + 8, y: cell.minY, width: cell.width - 16, height: cell.height - 8), game))
            HPAX.note(g, ir, .button, game.name, shape: .rounded(36))
        }
        contentHeight = Self.top + CGFloat((games.count + Self.cols - 1) / Self.cols) * Self.rowH + 40
    }

    private func drawToast(_ g: CGContext, _ face: Face, _ s: String) {
        let f = AppUI.font(32, .semibold)
        let w = min(880, Typo.width(s, f) + 80)
        let r = CGRect(x: 512 - w / 2, y: 1024 - 64 - 96, width: w, height: 96)
        HPComponents.glassCapsule(g, r, tint: nil) { c in
            AppUI.center(face, c, Face.clipped(s, f, w - 64), f, cx: r.midX, y: r.midY + f.capHeight / 2, AppUI.label)
        }
    }

    func handleScroll(_ dy: CGFloat, now: Double) -> Bool {
        scroll.scroll(dy * 1.6, contentHeight: contentHeight, viewport: 1024)
    }

    func handleTap(_ p: CGPoint, face: Face, now: Double) -> Bool {
        guard p.y > AppUI.topEdge - 40 else { return false }
        for (r, game) in hits where r.contains(p) {
            opened = (game.name, now)
            if demo == nil, !game.path.isEmpty {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: game.path), configuration: NSWorkspace.OpenConfiguration()) { _, err in
                    if let err { log("games: open failed \(err.localizedDescription)") }
                }
            }
            return true
        }
        return false
    }
}

enum GamesSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        check(MacGames.isGame(category: "public.app-category.games") && MacGames.isGame(category: "public.app-category.puzzle-games")
              && MacGames.isGame(category: "public.app-category.Action-Games"), "遊戲：遊戲類與它的子類別")   // l10n-ignore
        check(!MacGames.isGame(category: "public.app-category.productivity") && !MacGames.isGame(category: nil) && !MacGames.isGame(category: "games"),
              "遊戲：其他類別、沒寫類別都不算")   // l10n-ignore
        // 掃描：用暫存資料夾造兩個 App（一個遊戲、一個不是、一個在子資料夾裡的遊戲）
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("hp-games-\(UUID().uuidString)", isDirectory: true)
        func app(_ rel: String, _ cat: String, _ bid: String) {
            let c = root.appendingPathComponent(rel).appendingPathComponent("Contents", isDirectory: true)
            try? fm.createDirectory(at: c, withIntermediateDirectories: true)
            (["LSApplicationCategoryType": cat, "CFBundleIdentifier": bid] as NSDictionary).write(to: c.appendingPathComponent("Info.plist"), atomically: true)
        }
        app("Zeta.app", "public.app-category.games", "t.z"); app("Notes2.app", "public.app-category.productivity", "t.n")
        app("Folder/Alpha.app", "public.app-category.card-games", "t.a"); app("Dup.app", "public.app-category.games", "t.z")
        let found = MacGames.scan([root])
        check(found.map(\.bundleID) == ["t.a", "t.z"] && found.first?.name == "Alpha", "遊戲：掃到子資料夾裡的遊戲、略過非遊戲與重複的、照名稱排")
        try? fm.removeItem(at: root)
    }
}
