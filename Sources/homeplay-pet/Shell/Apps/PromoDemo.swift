// 2.0 promo：--demo-promo＝在我們的畫布上把 HomeView 宣傳片（@aaronp613，9.7 s）整段演一次，全部是示範資料：
//   0.0 s 主畫面 → 1.1 s iPhone 傳來一頁食譜（Handoff：舊畫面放大＋模糊淡出，網頁出來）→ 網頁好了停 0.5 s 自動進封面
//   → 3.0 s 點「食材」→ 3.9／4.3／4.75 s 勾三樣 → 5.05 s 往下捲 → 5.67 s 第 2 步的計時器（已跑 17 秒＝00:43）
//   → 7.33 s 攝影機一瞥（後院）→ 9.7 s 結束。
// --promo-frames <資料夾>：照參考影片的取樣時間存平面 1024² 圖（f-<秒>.png）與實際量到的過場時間（timings.json），存完就結束。
// 示範網頁不連網（loadHTMLString），網域是 cooking.example.com；食譜文字是我們自己寫的，三種語言都有。

import AppKit

enum PromoDemo {
    static let pageURL = URL(string: "https://cooking.example.com/lemon-blueberry-yogurt-loaf-cake")!   // l10n-ignore：示範網址
    static var on: Bool { CommandLine.arguments.contains("--demo-promo") }

    /// 腳本：第幾秒做什麼（跟參考影片的拍子對齊，見 docs/plans 的對照表）
    enum Action: String, CaseIterable { case handoff, ingredients, check0, check1, check3, scroll, timer, camera, end }
    static let script: [(t: Double, a: Action)] = [(1.10, .handoff), (3.00, .ingredients), (3.90, .check0), (4.30, .check1), (4.75, .check3),
                                                   (5.05, .scroll), (5.67, .timer), (7.33, .camera), (9.70, .end)]
    /// 對照參考影片的取樣時間（秒）與那一拍
    static let frames: [(t: Double, beat: String)] = [(0.5, "home"), (1.33, "takeover"), (1.83, "web page"), (2.5, "cover"), (3.5, "ingredients"),
                                                      (4.6, "check off"), (5.4, "scrolled"), (6.0, "timer 00:43"), (7.0, "Step 2 of 4"), (8.5, "camera")]   // l10n-ignore：檔名說明

    // MARK: 執行

    nonisolated(unsafe) private static var t0: Double?
    nonisolated(unsafe) private static var done = Set<Action>()
    nonisolated(unsafe) private static var shot = Set<Int>()
    nonisolated(unsafe) private static var marks: [String: Double] = [:]
    nonisolated(unsafe) private static var driver: Timer?

    /// applyMediaDemoFlags 叫：等第一幀畫出來（RealityKit 很慢時不要把前幾拍擠在一起）再開始計時
    static func start(face: Face) {
        guard driver == nil else { return }
        Face.demoData = true
        RecipesApp.shared.demoPrepare(face)
        Shell.timers = TimerBook()
        SafariApp.shared.prewarm()   // 跟開了 Handoff 的正式版一樣：網頁視圖先開好
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in MainActor.assumeIsolated { step() } }
        RunLoop.main.add(t, forMode: .common)
        driver = t
    }

    private static var framesDir: String? {
        let a = CommandLine.arguments
        return a.firstIndex(of: "--promo-frames").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
    }

    @MainActor private static func step() {
        guard let v = (NSApp.delegate as? AppDelegate)?.view else { return }
        let now = CACurrentMediaTime()
        if t0 == nil {
            guard v.face.lastFrame != nil else { return }
            t0 = now + 0.8                                 // 主畫面先停一下
            if Shell.nav.screen != .home { Shell.nav.screen = .home; Shell.nav.overlay = .none }
        }
        guard let t0 else { return }
        let t = now - t0
        Shell.lastActive = now                             // 示範期間不要因為「沒人靠近」回錶面
        SafariApp.shared.pumpWeb(now)                      // 3D 還沒起來時外殼的 tick 不一定在跑：自己幫 Safari 拍網頁
        for (bt, a) in script where t >= bt && !done.contains(a) { done.insert(a); act(a, v, t) }
        measure(t)
        if let dir = framesDir {
            for (i, f) in frames.enumerated() where t >= f.t && !shot.contains(i) {
                shot.insert(i)
                v.face.forceDirty = true
                let img = v.face.render()
                let name = String(format: "f-%05.2f.png", f.t)   // l10n-ignore：檔名
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
                marks["frame \(name)"] = t
            }
        }
        if done.contains(.end) {
            driver?.invalidate(); driver = nil
            writeTimings()
            log("promo demo done")
            if framesDir != nil { exit(0) }
        }
        v.face.forceDirty = true
    }

    @MainActor private static func act(_ a: Action, _ v: PetView, _ t: Double) {
        marks[a.rawValue] = t
        let r = RecipesApp.shared, now = CACurrentMediaTime()
        func tapRow(_ i: Int) { if let row = r.demoIngredientRow(i) { _ = r.handleTap(CGPoint(x: row.midX, y: row.midY), face: v.face, now: now) } }
        switch a {
        case .handoff: PhoneHandoff.receive(pageURL, via: .demo, demoHTML: recipeHTML())
        case .ingredients:
            if Shell.nav.screen != .app("recipes") { marks["late cover"] = t; v.shellOpenApp("recipes") }   // 網頁太慢：直接進
            let b = HPTokens.RecipeCover.buttons[0]
            _ = r.handleTap(CGPoint(x: b.midX, y: b.midY), face: v.face, now: now)   // 手指點「食材」
        case .check0: tapRow(0)
        case .check1: tapRow(1)
        case .check3: tapRow(3)
        case .scroll: r.scrollIngredients(to: 330, now: now)
        case .timer: r.demoStartTimer(step: 1, elapsed: 17); r.demoShowTimer(step: 1, now: now)
        case .camera: CameraGlance.open(from: v)
        case .end: break
        }
        v.face.forceDirty = true
    }

    /// 實際量：網頁第一張圖、封面出來的時間（跟影片比）
    @MainActor private static func measure(_ t: Double) {
        if marks["page"] == nil, done.contains(.handoff), SafariApp.shared.hasPage { marks["page"] = t }
        if marks["cover"] == nil, Shell.nav.screen == .app("recipes"), r.recipe != nil { marks["cover"] = t }
        if marks["reveal"] == nil, done.contains(.handoff), !Shell.takeoverHeld { marks["reveal"] = t }   // 網頁好了、接管放開
        if marks["takeover end"] == nil, done.contains(.handoff), Shell.takeover == nil { marks["takeover end"] = t }
        if marks["timer screen"] == nil, done.contains(.timer), Shell.nav.screen == .app("recipes") { marks["timer screen"] = t }
        if marks["camera screen"] == nil, done.contains(.camera), Shell.nav.screen == .app("home") { marks["camera screen"] = t }
    }
    private static var r: RecipesApp { RecipesApp.shared }

    private static func writeTimings() {
        guard let dir = framesDir else { return }
        let d = (try? JSONSerialization.data(withJSONObject: marks, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        try? d.write(to: URL(fileURLWithPath: dir).appendingPathComponent("timings.json"))
    }

    // MARK: 示範食譜（我們自己寫的；三種語言）

    static var title: String { L("promo.recipe.title", "柠檬蓝莓优格磅蛋糕") }
    static var ingredients: [String] {
        [L("promo.recipe.i1", "¾ 杯精制椰子油，融化后稍微放凉，另备一些抹模具"), L("promo.recipe.i2", "2 杯中筋面粉"), L("promo.recipe.i3", "1 ¼ 茶匙泡打粉"),
         L("promo.recipe.i4", "½ 茶匙小苏打"), L("promo.recipe.i5", "½ 茶匙犹太盐"), L("promo.recipe.i6", "1 杯细砂糖"), L("promo.recipe.i7", "3 颗大鸡蛋"),
         L("promo.recipe.i8", "1 ½ 杯全脂希腊优格"), L("promo.recipe.i9", "2 大匙磨细的柠檬皮"), L("promo.recipe.i10", "1 ½ 茶匙香草精"), L("promo.recipe.i11", "1 ½ 杯新鲜蓝莓")]
    }
    static var steps: [String] {
        [L("promo.recipe.s1", "烤箱预热到 180°C，长条模抹一层椰子油。"),
         L("promo.recipe.s2", "糖、鸡蛋和优格一起搅打 1 分钟，到滑顺、颜色变浅。"),
         L("promo.recipe.s3", "拌入面粉、泡打粉、小苏打和盐，再加椰子油、柠檬皮、香草精和蓝莓，拌匀就好。"),
         L("promo.recipe.s4", "倒进模具，烤 55 分钟，到竹签插进去拿出来是干净的。放凉 20 分钟再切。")]
    }

    static func recipeJSONLD() -> String {
        let recipe: [String: Any] = [
            "@context": "https://schema.org", "@type": "Recipe", "name": title, "totalTime": "PT1H30M", "recipeYield": ["8"],
            "recipeIngredient": ingredients, "recipeInstructions": steps.map { ["@type": "HowToStep", "text": $0] },
        ]
        let data = (try? JSONSerialization.data(withJSONObject: recipe, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// 像一般食譜網站的一頁：網站名、麵包屑、大標題、星等、封面色塊、導言、食材、做法
    static func recipeHTML() -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        let css = "<meta name=viewport content='width=device-width'><style>:root{color-scheme:light}body{font:16px -apple-system;margin:0;color:#1d1d1f;background:#fff}"   // l10n-ignore：CSS
            + "header{display:flex;justify-content:space-between;align-items:center;padding:10px 16px;border-bottom:1px solid #eee}.logo{font:800 19px Georgia,serif;letter-spacing:.5px}"
            + ".sub{background:#6b2fbf;color:#fff;font-size:11px;padding:5px 9px;border-radius:4px}.promo{background:#f6f1fb;color:#4a2a7a;font-size:13px;padding:8px 16px}"
            + "main{padding:6px 16px}.crumb{font-size:11px;letter-spacing:1px;color:#777;text-transform:uppercase;margin:10px 0}"
            + "h1{font:700 30px Georgia,serif;line-height:1.12;margin:4px 0 8px}.stars{color:#f0a400;font-size:15px}.stars span{color:#777;font-size:13px;margin-left:6px}"
            + ".hero{height:170px;border-radius:6px;margin:14px 0;background:linear-gradient(135deg,#f4e3c3,#e7b977 55%,#7a4a8c)}h2{font:700 20px Georgia,serif;margin-top:20px}</style>"
        let head = "<html><head><script type=\"application/ld+json\">\(recipeJSONLD())</script>" + css + "</head>"
        let body = "<body><header><div class=logo>KITCHEN NOTES</div><div class=sub>\(esc(L("promo.web.subscribe", "订阅")))</div></header>"   // l10n-ignore：示範網站名
            + "<div class=promo>\(esc(L("promo.web.banner", "本周末来厨房：现场示范与试吃")))</div><main>"
            + "<div class=crumb>\(esc(L("promo.web.crumb", "食谱 / 甜点 / 蛋糕")))</div><h1>\(esc(title))</h1>"
            + "<div class=stars>★★★★★<span>4.8 (212)</span></div><div class=hero></div>"   // l10n-ignore：星等
            + "<p>\(esc(L("promo.web.p1", "优格让这条磅蛋糕湿润又不腻，柠檬皮和蓝莓让每一口都很清爽。一个碗就能做完。")))</p>"
            + "<h2>\(esc(L("safari.demo.ingredients", "食材")))</h2><ul>" + ingredients.map { "<li>\(esc($0))</li>" }.joined() + "</ul>"
            + "<h2>\(esc(L("safari.demo.steps", "做法")))</h2><ol>" + steps.map { "<li>\(esc($0))</li>" }.joined() + "</ol></main></body></html>"
        return head + body
    }

    /// 封面照（程式畫的：淺色木桌上一條切開的磅蛋糕，奶白糖霜、紫色藍莓）
    nonisolated(unsafe) private static var heroCache: CGImage?
    static func hero() -> CGImage {
        if let h = heroCache { return h }
        let img = makeImage(1024, 1024) { c in
            MediaUI.fillGradient(c, MediaUI.full, srgb(0xe9dccb), srgb(0xb79c7e))
            // 盤子
            c.setFillColor(NSColor(white: 1, alpha: 0.9).cgColor); c.fillEllipse(in: CGRect(x: 60, y: 260, width: 900, height: 520))
            c.setFillColor(srgb(0xeee9e2).cgColor); c.fillEllipse(in: CGRect(x: 110, y: 300, width: 800, height: 440))
            // 四片斜放的蛋糕
            var rng = SystemRandomNumberGenerator()
            for k in 0..<4 {
                c.saveGState()
                c.translateBy(x: 250 + CGFloat(k) * 165, y: 470 + CGFloat(k % 2) * 20); c.rotate(by: -0.42)
                let slice = CGRect(x: -95, y: -150, width: 190, height: 300)
                c.addPath(continuousRoundedRect(slice, radius: 26)); c.setFillColor(srgb(0xb8742e).cgColor); c.fillPath()   // 外皮
                let crumb = slice.insetBy(dx: 16, dy: 18)
                c.addPath(continuousRoundedRect(crumb, radius: 18)); c.setFillColor(srgb(0xf6dc95).cgColor); c.fillPath()   // 內裡
                for _ in 0..<9 {
                    let x = CGFloat.random(in: crumb.minX + 14...crumb.maxX - 30, using: &rng), y = CGFloat.random(in: crumb.minY + 30...crumb.maxY - 24, using: &rng)
                    c.setFillColor(srgb(0x5b2a6e).cgColor); c.fillEllipse(in: CGRect(x: x, y: y, width: 22, height: 18))
                    c.setFillColor(srgb(0xa04c8a, 0.5).cgColor); c.fillEllipse(in: CGRect(x: x - 8, y: y - 6, width: 36, height: 30))
                }
                c.setFillColor(NSColor(white: 1, alpha: 0.96).cgColor)   // 頂上的糖霜
                c.addPath(continuousRoundedRect(CGRect(x: slice.minX - 4, y: slice.minY - 10, width: slice.width + 8, height: 44), radius: 20)); c.fillPath()
                c.restoreGState()
            }
            // 糖霜細線
            c.setStrokeColor(NSColor(white: 1, alpha: 0.85).cgColor); c.setLineWidth(9); c.setLineCap(.round)
            for i in 0..<5 { c.move(to: CGPoint(x: 160 + CGFloat(i) * 150, y: 330)); c.addCurve(to: CGPoint(x: 260 + CGFloat(i) * 150, y: 640), control1: CGPoint(x: 280 + CGFloat(i) * 150, y: 430), control2: CGPoint(x: 140 + CGFloat(i) * 150, y: 540)) }
            c.strokePath()
        }
        heroCache = img
        return img
    }
}

// MARK: - 自檢

enum PromoSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        HandoffSelfTest.run(check)
        RecipeCookingSelfTest.run(check)
        let r = RecipeParser.parse(html: PromoDemo.recipeHTML(), sourceURL: PromoDemo.pageURL.absoluteString)
        check(r?.steps.count == 4 && r?.ingredients.count == 11 && r.map { StepDuration.find(in: $0.steps[1].text) } == 60 && r.map { StepDuration.find(in: $0.steps[3].text) } == 3300,
              "宣傳片：示範網頁拆得出 4 步、11 樣食材，第 2 步 1 分鐘")   // l10n-ignore：selftest 訊息
        let ts = PromoDemo.script.map(\.t)
        check(ts == ts.sorted() && Set(PromoDemo.script.map(\.a)).count == PromoDemo.Action.allCases.count && PromoDemo.frames.map(\.t) == PromoDemo.frames.map(\.t).sorted()
              && (PromoDemo.frames.last?.t ?? 99) < (ts.last ?? 0), "宣傳片：腳本照時間排、每個動作一次、最後一張圖在結束前")   // l10n-ignore
        check(ControlCenter.Tile.allCases.allSatisfy { a in ControlCenter.Tile.allCases.allSatisfy { b in a == b || !ControlCenter.rect(a).intersects(ControlCenter.rect(b)) } }
              && ControlCenter.rect(.cameras).maxY < 1024 - 83, "控制中心：攝像頭磚不跟別的磚重疊")   // l10n-ignore
    }
}
