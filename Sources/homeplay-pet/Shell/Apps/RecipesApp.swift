// 食譜 App（稿：hv-design/project/Cooking.dc.html；實機照片：handson.md §7）：
// 把食譜網址拖到桌寵上（或 ⌘V、右鍵「從剪貼簿開啟食譜」）→ 抓網頁 → 拆 schema.org Recipe → 封面（壓暗的食物照）、
// 食材清單、一頁一步的 Start Cooking；步驟裡有時間就給一顆「計時 N 分鐘」，點下去在計時器 App 的多組計時器裡開一組有名字的。
// 沒有 JSON-LD 食譜的網頁：顯示「這個網頁沒有食譜資料」；之後可以交給 ClioTalk 整理（見 clioFallback）。
// 最近開過的 10 份食譜釘在本機（Application Support/HomePlay/recipes.json），不經任何伺服器。
// 純邏輯在 RecipeParser.swift，輸入（拖放、貼上、選單）在 RecipeInput.swift。
// 2.0 P10（使用者 2026-10-25）：跟官方一樣，食譜併進 Safari——這裡是 Safari 的烹飪畫面：不上主畫面，從 Safari 的「開始烹飪」、
// 起始頁的「釘選的食譜」、拖放／貼上／ClioTalk 進來；最外層的返回回到 Safari（SafariApp.returnFromCooking）。

import AppKit

final class RecipesApp: PetApp {
    static let shared = RecipesApp()
    let id = "recipes"
    var title: String { L("app.recipes", "食谱") }
    let icon = AppIcon(color: srgb(0x34c759), symbol: "fork.knife")

    enum Screen: Equatable {
        case home                 // 沒有食譜：說明＋最近的食譜
        case loading(String)      // 正在抓（顯示主機名）
        case failed(String)       // 抓不到／不是網頁（訊息，已本地化）
        case noRecipe(String)     // 網頁裡沒有食譜資料（主機名）
        case overview
        case ingredients
        case step(Int)
        case timer(Int)           // 2.0 promo：這一步的計時器全螢幕（RecipeCooking.swift）
    }

    private(set) var screen: Screen = .home
    private(set) var recipe: Recipe?
    private var hero: CGImage?
    private var heroKey = ""
    private var checked = Set<Int>()
    private var scroll: CGFloat = 0
    private var maxScroll: CGFloat = 0
    private var shelf = RecipeStore.load()
    private weak var face: Face?
    private var generation = 0                 // 抓網頁的世代：慢的舊請求回來時不蓋掉新的
    private var lastSpin = 0.0
    private var persist = true
    private var lastURL: URL?
    // 2.0 promo：每一步的計時器（步驟 → Shell.timers 的 id）；暫停的記剩幾秒；總長照開的時候
    private var stepTimers: [Int: Int] = [:]
    private var pausedLeft: [Int: Double] = [:]
    private var stepTotals: [Int: Double] = [:]
    private var lastTimerDraw = 0.0
    /// 食材頁的程式捲動（語音勾到看不到的那一行、示範）：從哪捲到哪、何時開始
    private var scrollAnim: (from: CGFloat, to: CGFloat, start: Double)?

    /// 沒有 JSON-LD 食譜時的後備（ClioTalk 之後掛在這裡：傳入網頁純文字與網址，整理成 Recipe 後呼叫 show）
    nonisolated(unsafe) static var clioFallback: ((_ pageText: String, _ url: URL, _ done: @escaping (Recipe?) -> Void) -> Void)?

    // MARK: 版面（1024 畫布）
    // 2.0 r2：首頁、食材、步驟跟著淺／深色（影片 v1 00:27.25 步驟頁是白底黑字）；封面是照片滿版（深色內容，白字）
    static var bg: NSColor { HPComponents.bg }
    /// 步驟頁的卡：淺色時純白、深色時黑
    static var stepBG: NSColor { HPTokens.dark ? .black : .white }
    private static let bottomY: CGFloat = 834, bottomH: CGFloat = 112, sideX: CGFloat = 78
    private static var accent: NSColor { HPComponents.orange }

    private static func bottomRow(_ weights: [CGFloat]) -> [CGRect] {
        let gap: CGFloat = 14, total = 1024 - 2 * sideX - gap * CGFloat(weights.count - 1)
        let unit = total / weights.reduce(0, +)
        var x = sideX
        return weights.map { w in defer { x += w * unit + gap }; return CGRect(x: x, y: bottomY, width: w * unit, height: bottomH) }
    }
    // 2.0 逼真化：首頁不重複「食谱」標題；有最近的食譜時，上面一顆主要動作、底下 inset grouped 清單（列高 112、分隔線縮排）
    private static func pasteButton(_ hasRecents: Bool) -> CGRect {
        hasRecents ? CGRect(x: 64, y: 860, width: 896, height: 104) : CGRect(x: 512 - 290, y: 670, width: 580, height: 104)
    }
    private static let recentsTop: CGFloat = 226, recentsBottom: CGFloat = 836
    private static func recentRow(_ i: Int) -> CGRect { CGRect(x: 64, y: recentsTop + CGFloat(i) * 120, width: 896, height: 120) }
    private static func removeZone(_ row: CGRect) -> CGRect { CGRect(x: row.maxX - 104, y: row.minY, width: 104, height: row.height) }
    private static let backButton = CGRect(x: 512 - 150, y: 660, width: 300, height: 104)
    /// 封面頁底下兩顆清玻璃膠囊（影片 v1 O-037：各約 410×120、間距約 30、底距約 60）
    // R15：封面的兩顆膠囊照官方 recipe-overview（HPTokens.RecipeCover.buttons：高 125、間距 22、四周內縮 61）
    private static var overviewButtons: [CGRect] { HPTokens.RecipeCover.buttons }

    // 2.0 r2（R1）：封面頁是照片滿版——外殼的返回鈕與時間不畫，自己畫白色的；食材、步驟是子頁（‹）
    // R15：步驟頁也自己畫頂列（影片 v1 00:27.25：✕ 左上、中央小標＋頁點、右上時間）
    private var onStep: Bool { if case .step = screen { return true }; return false }
    // 2.0 promo：食材頁也自己畫頂列（影片：✕、中央食譜名＋「食材」、右上時間）；計時器全螢幕不要外殼的鈕
    private var ownsTopBar: Bool {
        switch screen { case .overview, .ingredients, .step, .timer: return true; default: return false }
    }
    var showsCloseButton: Bool { !ownsTopBar }
    var showsClock: Bool { !ownsTopBar }
    var backSymbol: String {
        "chevron.left"   // 2.0 P10：最外層也是 ‹（回 Safari）
    }
    func handleBack(now: Double) -> Bool {
        switch screen {
        case .ingredients, .step: go(.overview, now: now, kind: .blurFade); return true
        case .timer(let i): go(.step(i), now: now, kind: .blurFade); return true
        case .failed, .noRecipe: screen = .home; return true
        default: SafariApp.returnFromCooking(); return true   // 2.0 P10：回 Safari
        }
    }

    /// 換頁過場：步驟頁從右緣滑入（影片 v1 00:26.775–00:27.067 量到 0.29 s、無回彈；逐格的進度
    /// 0.03／0.15／0.45／0.58／0.78／0.90／0.97／1.0，每格 41.7 ms → 臨界阻尼 response 0.36 s 最貼：0／0.17／0.43／0.64／0.79／0.88／0.93／0.96），
    /// 上一步從左；其他模糊交叉淡化（0.29 s）
    static let slideSpring = HPMotion.T.pageSlide.spring   // 動效包：參數表
    private var transition: PageTransition?
    private func go(_ next: Screen, now: Double, kind: PageTransition.Kind) {
        if let f = face { transition = PageTransition(kind, face: f, now: now, spring: kind == .blurFade ? AppMotion.critical(settle: 0.29) : Self.slideSpring, name: "recipe.step") }
        screen = next; scroll = 0
    }

    // MARK: 開啟、載入

    /// 入口：拖放、貼上、選單都走這裡。抓網頁在背景，結果回主執行緒
    func open(_ url: URL, face: Face) {
        self.face = face
        generation += 1
        let gen = generation
        lastURL = url
        screen = .loading(url.host ?? url.absoluteString); recipe = nil; hero = nil; scroll = 0; checked = []
        face.forceDirty = true
        log("recipe fetch \(url.host ?? "?")")
        MediaUI.fetch(url, accept: "text/html,application/xhtml+xml;q=0.9,*/*;q=0.5") { [weak self] result in
            guard let self, gen == self.generation else { return }
            switch result {
            case .failure:
                self.screen = .failed(L("recipe.failed", "打不开这个网页"))
            case .success(let r):
                let html = String(data: r.data, encoding: .utf8) ?? String(data: r.data, encoding: .isoLatin1) ?? ""
                if let rec = RecipeParser.parse(html: html, sourceURL: r.finalURL.absoluteString) {
                    self.show(rec, base: r.finalURL)
                } else {
                    self.screen = .noRecipe(r.finalURL.host ?? "")
                    log("recipe: no JSON-LD Recipe")
                }
            }
            self.face?.forceDirty = true
        }
    }

    /// 顯示一份食譜（解析好的，或之後 ClioTalk 整理出來的）；釘到「最近」，封面圖另外抓
    func show(_ r: Recipe, base: URL? = nil, remember: Bool = true) {
        if recipe.map(RecipeChecks.key) != RecipeChecks.key(r) { stepTimers = [:]; pausedLeft = [:]; stepTotals = [:] }
        recipe = r; screen = .overview; scroll = 0; hero = nil
        checked = persist ? RecipeChecks.load(r) : []   // 2.0 promo：勾過的食材記在本機（每份食譜一組）
        if remember && persist { shelf.add(r); RecipeStore.save(shelf) }
        loadHero(r, base: base)
        if r.sourceURL == PromoDemo.pageURL.absoluteString { hero = PromoDemo.hero(); heroKey = "demo" }   // 2.0 promo：示範網頁的封面照（程式畫的）
    }

    private func loadHero(_ r: Recipe, base: URL?) {
        guard let s = r.imageURL, let url = URL(string: s, relativeTo: base)?.absoluteURL else { return }
        let key = r.sourceURL ?? r.title
        heroKey = key
        MediaUI.fetch(url, accept: "image/*") { [weak self] result in
            guard let self, self.heroKey == key, case .success(let r) = result, let img = MediaUI.cgImage(from: r.data) else { return }
            self.hero = img
            self.face?.forceDirty = true
        }
    }

    /// 顯示一則錯誤（例如剪貼簿裡沒有網址）
    func showError(_ message: String, face: Face) {
        self.face = face
        screen = .failed(message); lastURL = nil
        face.forceDirty = true
    }

    /// 2.0 P10：釘在本機的食譜（Safari 起始頁的「釘選的食譜」）
    var pinned: [Recipe] { shelf.items }
    func openPinned(_ r: Recipe) { show(r, base: r.sourceURL.flatMap(URL.init(string:)), remember: true) }

    func didOpen(now: Double) {
        if case .failed = screen { screen = .home }
        if case .noRecipe = screen { screen = .home }
        scroll = 0
    }

    // MARK: 每幀

    func tick(_ now: Double) -> Bool {
        if HPComponents.needsFrame(now) { return true }
        if case .loading = screen, now - lastSpin > 0.05 { lastSpin = now; return true }
        if scrollAnim != nil { return true }
        // 計時器全螢幕、步驟頁上的倒數：每 0.25 秒重畫（秒數與刻度）
        if case .timer = screen, now - lastTimerDraw > 0.25 { lastTimerDraw = now; return true }
        if case .step(let i) = screen, stepTimers[i] != nil, now - lastTimerDraw > 0.5 { lastTimerDraw = now; return true }
        return false
    }

    // MARK: 畫

    func render(into g: CGContext, face: Face, rect: CGRect, now: Double) {
        self.face = face
        let slide = transition.flatMap { $0.kind != .blurFade && $0.progress(now) != nil ? $0 : nil }
        if let t = transition, t.progress(now) == nil { transition = nil }
        if let slide {
            // 舊畫面墊底，新的一頁（左側兩角是大圓角，像一張卡）從旁邊滑進來
            slide.drawUnder(g, face, now)
            g.saveGState()
            let dx = slide.offset(now)
            g.translateBy(x: dx, y: 0)
            g.setShadow(offset: .zero, blur: 40, color: NSColor(white: 0, alpha: 0.18).cgColor)
            g.addPath(continuousRoundedRect(rect, radius: dx == 0 ? HPComponents.screenRadius : 102)); g.setFillColor(backdrop.cgColor); g.fillPath()
            g.restoreGState()
            g.saveGState(); g.translateBy(x: dx, y: 0)
            g.addPath(continuousRoundedRect(rect, radius: 102)); g.clip()
        }
        g.setFillColor(backdrop.cgColor); g.fill(rect)
        switch screen {
        case .home: renderHome(g, face)
        case .loading(let host): renderLoading(g, face, host, now)
        case .failed(let msg): renderMessage(g, face, symbol: "wifi.exclamationmark", title: msg, detail: L("recipe.failed.hint", "检查网址和网络后再试一次。"), retry: true)
        case .noRecipe(let host):
            renderMessage(g, face, symbol: "doc.text.magnifyingglass", title: L("recipe.noData", "这个网页没有食谱资料"),
                          detail: host.isEmpty ? L("recipe.noData.hint", "只认网页里带有 schema.org 食谱数据的页面。") : host, retry: false)
        case .overview: renderOverview(g, face)
        case .ingredients: renderIngredients(g, face)
        case .step(let i): renderStep(g, face, i, now)
        case .timer(let i): renderTimer(g, face, i)
        }
        if slide != nil { g.restoreGState() }
        transition?.drawOver(g, face, now)
    }

    private var backdrop: NSColor {
        if case .step = screen { return Self.stepBG }
        return Self.bg
    }

    private func renderHome(_ g: CGContext, _ face: Face) {
        let hasRecents = !shelf.items.isEmpty
        let hint = L("recipe.home.hint", "把食谱网址拖到桌宠上，或复制网址后按 ⌘V。")
        let pb = Self.pasteButton(hasRecents)
        guard hasRecents else {
            HPComponents.emptyState(g, face, symbol: "fork.knife", tint: Self.accent, title: L("recipe.start", "开始烹饪"), body: hint, top: 260)
            HPComponents.filledButton(g, face, pb, L("recipe.home.paste", "从剪贴板打开"), tint: Self.accent, symbol: "doc.on.clipboard")
            return
        }
        // 清單（捲到上面時在分區標題底下淡出）
        maxScroll = max(0, CGFloat(shelf.items.count) * 120 - (Self.recentsBottom - Self.recentsTop))
        scroll = min(scroll, maxScroll)
        g.saveGState(); g.clip(to: CGRect(x: 0, y: Self.recentsTop, width: 1024, height: Self.recentsBottom - Self.recentsTop))
        let card = CGRect(x: 64, y: Self.recentsTop - scroll, width: 896, height: CGFloat(shelf.items.count) * 120)
        HPComponents.groupCard(g, card, radius: 52)
        for (i, r) in shelf.items.enumerated() {
            let row = Self.recentRow(i).offsetBy(dx: 0, dy: -scroll)
            guard row.maxY > Self.recentsTop, row.minY < Self.recentsBottom else { continue }
            if i > 0 { HPComponents.separatorLine(g, x: row.minX + 36, maxX: row.maxX, y: row.minY) }
            let w = row.width - 160
            let tf = HPComponents.sf(42, weight: .regular), sf = HPComponents.sf(30, weight: .regular)
            face.drawLeft(g, Face.clipped(r.title, tf, w), font: tf, x: row.minX + 36, y: row.minY + 56, color: HPComponents.label)
            face.drawLeft(g, Face.clipped(Self.subtitle(r) ?? r.host ?? "", sf, w), font: sf, x: row.minX + 36, y: row.minY + 96, color: HPComponents.secondary)
            let z = Self.removeZone(row)
            HPAX.note(g, CGRect(x: row.minX, y: row.minY, width: row.width - z.width, height: row.height), .button, r.title, value: Self.subtitle(r) ?? r.host, shape: .rounded(24))   // 2.0 depth：VoiceOver
            HPAX.note(g, z, .button, L("a11y.remove", "移除"), shape: .circle)
            face.drawSymbol(g, "xmark.circle.fill", in: CGRect(x: z.midX - 24, y: z.midY - 24, width: 48, height: 48), color: HPComponents.tertiary)
        }
        g.restoreGState()
        HPComponents.filledButton(g, face, pb, L("recipe.home.paste", "从剪贴板打开"), tint: Self.accent, symbol: "doc.on.clipboard")
        // 標題＝這一頁的內容「最近的食谱」（不是 App 名稱）
        AppUI.title(g, face, L("recipe.home.recent", "最近的食谱"))
    }

    private func renderLoading(_ g: CGContext, _ face: Face, _ host: String, _ now: Double) {
        let c = CGPoint(x: 512, y: 440)
        g.setLineCap(.round); g.setLineWidth(12)
        for i in 0..<12 {
            let a = -CGFloat.pi / 2 + CGFloat(i) / 12 * 2 * .pi
            let phase = (now * 1.2 - Double(i) / 12).truncatingRemainder(dividingBy: 1)
            g.setStrokeColor(HPComponents.label.withAlphaComponent(0.15 + 0.7 * CGFloat(1 - (phase < 0 ? phase + 1 : phase))).cgColor)
            g.move(to: CGPoint(x: c.x + cos(a) * 44, y: c.y + sin(a) * 44)); g.addLine(to: CGPoint(x: c.x + cos(a) * 74, y: c.y + sin(a) * 74)); g.strokePath()
        }
        face.drawCentered(g, L("recipe.loading", "正在读取食谱…"), font: HPComponents.sf(44, weight: .bold), y: 600, color: HPComponents.label)
        face.drawCentered(g, Face.clipped(host, HPComponents.sf(32, weight: .regular), 760), font: HPComponents.sf(32, weight: .regular), y: 654, color: HPComponents.secondary)
    }

    private func renderMessage(_ g: CGContext, _ face: Face, symbol: String, title: String, detail: String, retry: Bool) {
        HPComponents.emptyState(g, face, symbol: symbol, tint: Self.accent, title: title, body: detail, top: 260)
        if retry, lastURL != nil {
            let r = CGRect(x: 512 - 330, y: 660, width: 320, height: 104), b = CGRect(x: 512 + 10, y: 660, width: 320, height: 104)
            HPComponents.glassButton(g, face, r, L("recipe.back", "返回"))
            HPComponents.filledButton(g, face, b, L("recipe.retry", "重试"), tint: Self.accent)
        } else {
            HPComponents.glassButton(g, face, Self.backButton, L("recipe.back", "返回"))
        }
    }

    /// 「35 分鐘 · 4 人份」
    static func subtitle(_ r: Recipe) -> String? {
        var parts: [String] = []
        if let t = r.totalSeconds { parts.append(StepDuration.label(t)) }
        if let y = r.yieldText { parts.append(y) } else if let n = r.servings { parts.append(String(format: L("recipe.servings", "%d 人份"), n)) }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")   // l10n-ignore
    }

    private func renderOverview(_ g: CGContext, _ face: Face) {
        guard let r = recipe else { return }
        // 封面：食物照鋪滿；下方約 45% 往下加深的黑色漸層讓白字可讀（影片 v1 O-035）
        if let hero {
            MediaUI.drawCover(g, face: face, hero, in: MediaUI.full)
        } else {
            let (a, b) = MediaUI.gradient(for: r.title)
            MediaUI.fillGradient(g, MediaUI.full, a.blended(withFraction: 0.62, of: .black) ?? a, b.blended(withFraction: 0.7, of: .black) ?? b)
            face.drawSymbol(g, "fork.knife", in: CGRect(x: 512 - 90, y: 250, width: 180, height: 180), color: NSColor.white.withAlphaComponent(0.16))
        }
        if let grad = MediaUI.shade(0.78) {
            g.drawLinearGradient(grad, start: CGPoint(x: 0, y: 470), end: CGPoint(x: 0, y: 1024), options: [.drawsAfterEndLocation])
        }
        // R15（官方 recipe-overview）：頂列 ✕ 與時間離邊 61；標題 bold 57、副標 regular 31 用 vibrancy（照片的顏色透上來）；
        // 兩顆寬 Clear 玻璃膠囊（白色 regular 32＋符號）
        typealias C = HPTokens.RecipeCover
        // 2.0 glass：返回鈕與兩顆膠囊在同一個 GlassEffectContainer（iOS 共用 backdrop）；2.0 P10：返回 Safari
        HPGlass.container("recipe.cover") { HPComponents.mediaTopBar(g, face, symbol: "chevron.left") }
        let x = HPTokens.Media.textX, w: CGFloat = 1024 - 2 * x
        let tf = HPComponents.fitted(r.title, size: C.titleSize, weight: .bold, maxWidth: w, minScale: 0.8)
        let lines = MediaUI.wrap(r.title, tf, w, maxLines: 3)
        let sub = [r.host, Self.subtitle(r)].compactMap { $0 }.joined(separator: " • ")   // l10n-ignore
        let titleBase = sub.isEmpty ? C.subtitleBaseline : C.titleBaseline
        var y = titleBase - CGFloat(lines.count - 1) * C.titleLineHeight
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: 2), blur: 14, color: NSColor(white: 0, alpha: 0.25).cgColor)
        for l in lines { face.drawLeft(g, l, font: tf, x: x, y: y, color: .white); y += C.titleLineHeight }
        g.restoreGState()
        if !sub.isEmpty {
            let sf = HPComponents.sf(C.subtitleSize, weight: .regular)
            HPComponents.vibrantText(g, face, Face.clipped(sub, sf, w), font: sf, x: x, y: C.subtitleBaseline)
        }
        let b = Self.overviewButtons
        HPGlass.container("recipe.cover") {
            HPComponents.mediaCapsule(g, face, b[0], L("recipe.ingredients", "食材"), symbol: "checklist")
            HPComponents.mediaCapsule(g, face, b[1], L("recipe.start", "开始烹饪"), symbol: "frying.pan")
        }
    }

    /// 玻璃按鈕裡「符號＋字」置中
    private func bigLabel(_ g: CGContext, _ face: Face, _ r: CGRect, symbol: String?, text: String, color: NSColor = .white) {
        let f = HPComponents.sf(34, weight: .medium)
        let t = Face.clipped(text, f, r.width - (symbol == nil ? 40 : 120))
        let w = Typo.width(t, f) + (symbol == nil ? 0 : 54)
        var x = r.midX - w / 2
        if let symbol {
            face.drawSymbol(g, symbol, in: CGRect(x: x, y: r.midY - 20, width: 40, height: 40), color: color, weight: .semibold); x += 54
        }
        face.drawLeft(g, t, font: f, x: x, y: r.midY + f.capHeight / 2, color: color)
    }

    // 食材（2.0 promo，照宣傳片 3.0–5.6 s）：頂列＝✕＋中央食譜名、底下小字「食材」＋右上時間；
    // 每一行是自己一張圓角卡（不是分組清單），左邊空心圈、份量灰字；勾了變實心圈＋整行變淡加刪除線。捲到最後是「開始烹飪」
    private static let ingFont = HPComponents.sf(40, weight: .regular)
    private static let ingX: CGFloat = 64, ingW: CGFloat = 896, ingTextX: CGFloat = 168, ingGap: CGFloat = 14
    private static let ingTop: CGFloat = 226, ingBottom: CGFloat = 1024
    private func ingredientLines(_ r: Recipe) -> [[String]] {
        r.ingredients.map { line in
            // 份量跟後面的字黏在一起（不換行），中文食材行才不會「¾」自己一行
            let (q, rest) = RecipeLine.split(line)
            return MediaUI.wrap(q.isEmpty ? rest : q + "\u{00A0}" + rest, Self.ingFont, Self.ingX + Self.ingW - 40 - Self.ingTextX, maxLines: 3)
        }
    }
    /// 一張卡的高：至少 104
    private static func ingredientHeight(_ lines: [String]) -> CGFloat { max(104, 46 + CGFloat(lines.count) * 50) }
    /// 第 i 張卡（未捲動）的框；最後一個 i＝食材數＝「開始烹飪」
    private func ingredientRows(_ r: Recipe) -> [CGRect] {
        var y = Self.ingTop, out: [CGRect] = []
        for lines in ingredientLines(r) {
            let h = Self.ingredientHeight(lines)
            out.append(CGRect(x: Self.ingX, y: y, width: Self.ingW, height: h)); y += h + Self.ingGap
        }
        out.append(CGRect(x: 512 - 280, y: y + 16, width: 560, height: 112))
        return out
    }
    private var ingScroll: CGFloat {
        guard let a = scrollAnim else { return scroll }
        let t = min(1, (CACurrentMediaTime() - a.start) / 0.55), e = 1 - pow(1 - t, 3)   // ease-out 0.55 s（手指一撥的感覺）
        return a.from + (a.to - a.from) * CGFloat(e)
    }
    /// 程式捲到某一行看得到（語音勾選、示範用）
    func scrollIngredients(to y: CGFloat, now: Double = CACurrentMediaTime()) {
        let to = max(0, min(maxScroll, y))
        scrollAnim = (ingScroll, to, now); scroll = to
    }

    private func renderIngredients(_ g: CGContext, _ face: Face) {
        guard let r = recipe else { return }
        if let a = scrollAnim, CACurrentMediaTime() - a.start >= 0.55 { scrollAnim = nil }
        let rows = ingredientRows(r)
        maxScroll = max(0, (rows.last?.maxY ?? 0) + 60 - Self.ingBottom)
        scroll = min(scroll, maxScroll)
        let off = ingScroll
        if r.ingredients.isEmpty {
            face.drawCentered(g, L("recipe.noIngredients", "这份食谱没有列出食材"), font: HPComponents.sf(34, weight: .regular), y: 500, color: HPComponents.secondary)
        }
        g.saveGState(); g.clip(to: CGRect(x: 0, y: 150, width: 1024, height: 874))
        let f = Self.ingFont
        for (i, lines) in ingredientLines(r).enumerated() {
            let row = rows[i].offsetBy(dx: 0, dy: -off)
            guard row.maxY > 150, row.minY < 1024 else { continue }
            let on = checked.contains(i)
            HPComponents.groupCard(g, row, radius: 40)
            let dot = CGRect(x: row.minX + 34, y: row.midY - 23, width: 46, height: 46)
            if on {
                g.setFillColor(Self.accent.cgColor); g.fillEllipse(in: dot)
                face.drawSymbol(g, "checkmark", in: dot.insetBy(dx: 12, dy: 13), color: .white, weight: .bold)
            } else {
                g.setStrokeColor(HPComponents.tertiary.cgColor); g.setLineWidth(3.5)
                g.strokeEllipse(in: dot.insetBy(dx: 2, dy: 2))
            }
            let top = row.midY - CGFloat(lines.count - 1) * 25 + 14
            let ink = on ? HPComponents.tertiary : HPComponents.label, qtyInk = on ? HPComponents.tertiary : HPComponents.secondary
            for (k, l) in lines.enumerated() {
                let y = top + CGFloat(k) * 50
                var x = Self.ingTextX
                if k == 0 {
                    let (q, rest) = RecipeLine.split(l)
                    if !q.isEmpty { face.drawLeft(g, q, font: f, x: x, y: y, color: qtyInk); x += Typo.width(q + " ", f) }
                    face.drawLeft(g, rest, font: f, x: x, y: y, color: ink)
                } else {
                    face.drawLeft(g, l, font: f, x: x, y: y, color: ink)
                }
                if on {   // 刪除線
                    let w = Typo.width(l, f)
                    g.setFillColor(HPComponents.tertiary.cgColor); g.fill(CGRect(x: Self.ingTextX, y: y - f.xHeight / 2 - 1.5, width: w, height: 3))
                }
            }
            HPAX.note(g, row, .button, (on ? "✓ " : "") + r.ingredients[i])   // l10n-ignore：勾號
        }
        if let b = rows.last?.offsetBy(dx: 0, dy: -off) {
            HPComponents.filledButton(g, face, b, L("recipe.start", "开始烹饪"), tint: Self.accent, symbol: "frying.pan")
        }
        g.restoreGState()
        // 捲到頂列底下時柔邊；頂列：✕、中央食譜名＋「食材」、右上時間
        HPComponents.topFade(g, Self.bg, solidTo: 190, height: 30)
        HPComponents.pageTopBar(g, face, title: r.title, pages: 1, page: 0)
        let sf = HPComponents.sf(28, weight: .regular)
        HPComponents.center(g, face, L("recipe.ingredients", "食材"), sf, y: HPTokens.Media.pageTitleBaseline + 36, HPComponents.secondary)
    }


    // 步驟（R5：內文 56–60；影片 v1 O-043：SF Pro Text Regular ≈62 px、行高 1.15、左右邊距 0.10 W）
    private static let stepSizes: [CGFloat] = [60, 56, 50, 44, 40]
    private static let textTop: CGFloat = 240, textBottom: CGFloat = 800, textX: CGFloat = 102

    /// 這一步的字：從大到小挑第一個放得下的字級；都放不下就用最小的、可以滾
    private func stepLayout(_ text: String) -> (font: NSFont, lines: [String], lineHeight: CGFloat) {
        for s in Self.stepSizes {
            let f = HPComponents.sf(s, weight: .regular), lh = (s * 1.18).rounded()
            let lines = MediaUI.wrap(text, f, 1024 - 2 * Self.textX, maxLines: 40)
            if CGFloat(lines.count) * lh <= Self.textBottom - Self.textTop - 90 { return (f, lines, lh) }
        }
        let s = Self.stepSizes.last!, f = HPComponents.sf(s, weight: .regular)
        return (f, MediaUI.wrap(text, f, 1024 - 2 * Self.textX, maxLines: 60), (s * 1.18).rounded())
    }

    /// 這一步用到的食材（食材行裡的詞出現在步驟文字裡）：最多 6 個，顯示食材行原文
    private func relatedIngredients(_ r: Recipe, _ text: String) -> [String] {
        let hay = text.lowercased()
        var out: [String] = []
        for line in r.ingredients {
            let words = line.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            let hit = words.contains { w in
                if w.unicodeScalars.contains(where: { $0.value >= 0x2E80 }) { return w.count >= 2 && hay.contains(w) || (w.count > 3 && Self.cjkRuns(w).contains { hay.contains($0) }) }
                return w.count >= 4 && !Self.unitWords.contains(w) && hay.contains(w)
            }
            if hit { out.append(line) }
            if out.count >= 6 { break }
        }
        return out
    }
    private static let unitWords: Set<String> = ["tablespoon", "tablespoons", "teaspoon", "teaspoons", "ounce", "ounces", "pound", "pounds", "cups", "grams", "pinch", "large", "small", "medium", "fresh", "chopped", "sliced", "diced", "minced", "ground", "whole", "about", "plus", "more", "taste", "divided"]
    private static func cjkRuns(_ w: String) -> [String] {
        // 長詞切成兩字一組比對（「南瓜濃湯用」→ 南瓜、瓜濃…）：只為了找得到「南瓜」這類食材名
        let cs = Array(w); return cs.count < 2 ? [] : (0..<(cs.count - 1)).map { String(cs[$0...$0 + 1]) }
    }

    private func stepButtonRects(_ hasTimer: Bool) -> (prev: CGRect, timer: CGRect?, next: CGRect) {
        if hasTimer { let b = Self.bottomRow([1, 1.4, 1]); return (b[0], b[1], b[2]) }
        let b = Self.bottomRow([1, 1.5]); return (b[0], nil, b[1])
    }

    private func renderStep(_ g: CGContext, _ face: Face, _ i: Int, _ now: Double) {
        guard let r = recipe, r.steps.indices.contains(i) else { return }
        let step = r.steps[i]
        // R15：頂列＝✕、中央小標（食譜名）＋頁點、右上時間（影片 v1 00:27.25 O-042）
        let n = r.steps.count
        HPComponents.pageTopBar(g, face, title: r.title, pages: n, page: i)
        // 「步骤 i／n」灰字，分段名（有的話）接在後面
        var head = String(format: L("recipe.step", "步骤 %d／%d"), i + 1, n)
        if let sec = step.section { head += " · " + sec }
        let hf = HPComponents.sf(30, weight: .regular)
        face.drawLeft(g, Face.clipped(head, hf, 820), font: hf, x: Self.textX, y: Self.textTop - 18, color: HPComponents.secondary)
        let layout = stepLayout(step.text)
        // 2.0 depth：VoiceOver——步驟標題與整段步驟文字（文字多到要捲時也一次念完）
        HPAX.note(g, CGRect(x: Self.textX, y: Self.textTop - 56, width: 1024 - 2 * Self.textX, height: 56), .heading, head, shape: .rounded(12))
        HPAX.note(g, CGRect(x: Self.textX, y: Self.textTop + 20, width: 1024 - 2 * Self.textX, height: Self.textBottom - Self.textTop - 20), .text, step.text, shape: .rounded(12))
        let top = Self.textTop + 20
        let visible = Self.textBottom - top
        let related = relatedIngredients(r, step.text)
        let chipsH: CGFloat = related.isEmpty ? 0 : 76
        maxScroll = max(0, CGFloat(layout.lines.count) * layout.lineHeight + chipsH - visible)
        scroll = min(scroll, maxScroll)
        g.saveGState(); g.clip(to: CGRect(x: 0, y: top - 4, width: 1024, height: visible + 8))
        for (k, l) in layout.lines.enumerated() {
            let y = top + layout.font.ascender + CGFloat(k) * layout.lineHeight - scroll
            face.drawLeft(g, l, font: layout.font, x: Self.textX, y: y, color: HPComponents.label)
        }
        // 這一步用到的食材：小膠囊（一行），接在內文後面
        let cf = HPComponents.sf(30, weight: .regular)
        var x = Self.textX, cy = top + CGFloat(layout.lines.count) * layout.lineHeight + 22 - scroll
        for ing in related {
            let t = Face.clipped(ing, cf, 500), w = Typo.width(t, cf) + 44
            if x + w > 1024 - Self.textX { break }
            let chip = CGRect(x: x, y: cy, width: w, height: 56)
            g.setFillColor(HPComponents.fill.cgColor); g.addPath(MediaUI.capsule(chip)); g.fillPath()
            face.drawLeft(g, t, font: cf, x: x + 22, y: chip.midY + cf.capHeight / 2, color: HPComponents.secondary)
            x += w + 12
        }
        g.restoreGState()
        let dur = StepDuration.find(in: step.text)
        let b = stepButtonRects(dur != nil)
        let last = i == r.steps.count - 1
        // 上一步＝玻璃；計時＝橘色染色玻璃（影片的橘色計時 chip）；下一步＝玻璃（有計時時）或主要動作
        let nextText = last ? L("recipe.done", "完成") : L("recipe.next", "下一步")
        let ink = HPComponents.label
        HPAX.note(g, b.prev, .button, L("recipe.prev", "上一步"))   // 2.0 depth：VoiceOver
        HPComponents.glassCapsule(g, b.prev) { c in self.bigLabel(c, face, b.prev, symbol: "chevron.left", text: L("recipe.prev", "上一步"), color: ink) }
        if dur != nil {
            HPAX.note(g, b.next, .button, nextText)   // 2.0 depth：VoiceOver
            HPComponents.glassCapsule(g, b.next) { c in self.bigLabel(c, face, b.next, symbol: nil, text: nextText, color: ink) }
        }
        else { HPComponents.filledButton(g, face, b.next, nextText, tint: Self.accent) }
        if let tb = b.timer, let dur {
            let left = timerLeft(i)
            let text = left.map(RecipeLine.clock) ?? String(format: L("recipe.timer", "计时 %@"), StepDuration.label(dur))
            HPComponents.filledButton(g, face, tb, text, tint: Self.accent, symbol: pausedLeft[i] != nil ? "pause.fill" : "timer")
        }
    }

    // MARK: 步驟計時器（2.0 promo）

    private func timerLabel(_ i: Int) -> String { String(format: L("recipe.timerName", "步骤 %d · %@"), i + 1, recipe?.title ?? "") }
    /// 這一步的計時器還剩幾秒（暫停的照記下的；到點了或沒開是 nil）
    func timerLeft(_ i: Int) -> Double? {
        if let p = pausedLeft[i] { return p }
        guard let id = stepTimers[i] else { return nil }
        guard let t = Shell.timers.timer(id) else { stepTimers[i] = nil; return nil }
        return t.left(TimersApp.wallNow)
    }
    private func startTimer(_ i: Int, now: Double) {
        guard let r = recipe, r.steps.indices.contains(i), let face else { return }
        if pausedLeft[i] != nil { resumeTimer(i) }
        else if timerLeft(i) == nil, let dur = StepDuration.find(in: r.steps[i].text) {
            stepTotals[i] = Double(dur)
            stepTimers[i] = Shell.addTimer(minutes: Double(dur) / 60, label: timerLabel(i), face: face)
        }
        if screen != .timer(i) { go(.timer(i), now: now, kind: .blurFade) }
    }
    private func pauseTimer(_ i: Int) {
        guard let face, let id = stepTimers[i], let left = timerLeft(i) else { return }
        pausedLeft[i] = left; stepTimers[i] = nil
        Shell.removeTimer(id, face: face)
    }
    private func resumeTimer(_ i: Int) {
        guard let face, let left = pausedLeft[i] else { return }
        pausedLeft[i] = nil
        stepTimers[i] = Shell.addTimer(minutes: left / 60, label: timerLabel(i), face: face)
    }
    private func cancelTimer(_ i: Int) {
        if let id = stepTimers[i], let face { Shell.removeTimer(id, face: face) }
        stepTimers[i] = nil; pausedLeft[i] = nil
    }
    /// 頂端膠囊不要重複顯示正在全螢幕看的那組
    func hidesTimerActivity(_ id: Int) -> Bool {
        guard Shell.currentApp === self, case .timer(let i) = screen else { return false }
        return stepTimers[i] == id
    }

    private func renderTimer(_ g: CGContext, _ face: Face, _ i: Int) {
        let total = stepTotals[i] ?? Double(recipe.flatMap { $0.steps.indices.contains(i) ? StepDuration.find(in: $0.steps[i].text) : nil } ?? 60)
        RecipeStepTimerView.draw(g, face, step: i, left: timerLeft(i) ?? 0, total: total, paused: pausedLeft[i] != nil)
    }

    /// 計時器全螢幕時，👀 膠囊長成「步驟 2/4」（宣傳片 6.5 s 起頂端那顆；iOS 的前景 App Live Activity）
    func liveActivity(face: Face, now: Double) -> LiveActivity? {
        guard Shell.currentApp === self, case .timer(let i) = screen, let r = recipe else { return nil }
        return LiveActivity(kind: .message, title: String(format: L("recipe.la.step", "步骤 %1$d/%2$d"), i + 1, r.steps.count), detail: r.title,
                            accent: HPTokens.StepTimer.tint, progress: nil, appID: id, symbol: "fork.knife")
    }

    private func toggleIngredient(_ i: Int) {
        if checked.contains(i) { checked.remove(i) } else { checked.insert(i) }
        if persist, let r = recipe { RecipeChecks.save(checked, for: r) }
        face?.forceDirty = true
    }

    // MARK: 語音（ClioTalk 聽到的一句先問這裡；RecipeCooking.swift 的 RecipeVoice）

    /// 做掉了回 true（ClioTalk 就不送給模型）
    func handleVoice(_ cmd: RecipeVoice, now: Double) -> Bool {
        guard let r = recipe else { return false }
        let n = r.steps.count
        switch (cmd, screen) {
        case (.next, .overview), (.next, .ingredients): guard n > 0 else { return false }; go(.step(0), now: now, kind: .slideFromRight)
        case (.next, .step(let i)), (.next, .timer(let i)):
            guard i + 1 < n else { go(.overview, now: now, kind: .blurFade); break }
            go(.step(i + 1), now: now, kind: .slideFromRight)
        case (.previous, .step(let i)): go(i == 0 ? .overview : .step(i - 1), now: now, kind: i == 0 ? .blurFade : .slideFromLeft)
        case (.previous, .timer(let i)): go(.step(i), now: now, kind: .blurFade)
        case (.previous, .ingredients): go(.overview, now: now, kind: .blurFade)
        case (.startTimer, .step(let i)), (.startTimer, .timer(let i)):
            guard timerLeft(i) != nil || StepDuration.find(in: r.steps[i].text) != nil else { return false }
            startTimer(i, now: now)
        case (.pauseTimer, .step(let i)), (.pauseTimer, .timer(let i)):
            guard stepTimers[i] != nil else { return false }
            pauseTimer(i)
        case (.ingredients, _): go(.ingredients, now: now, kind: .blurFade)
        case (.check(let name), _):
            guard let k = RecipeVoice.match(name, in: r.ingredients) else { return false }
            if !checked.contains(k) { toggleIngredient(k) }
            if screen == .ingredients { let row = ingredientRows(r)[k]; if row.minY - scroll < Self.ingTop || row.maxY - scroll > 980 { scrollIngredients(to: row.minY - Self.ingTop) } }
        default: return false
        }
        face?.forceDirty = true
        return true
    }

    // MARK: 點、滾

    func handleTap(_ p: CGPoint, face: Face, now: Double) -> Bool {
        self.face = face
        func hit(_ r: CGRect) -> Bool { r.insetBy(dx: -6, dy: -6).contains(p) }
        switch screen {
        case .home:
            if hit(Self.pasteButton(!shelf.items.isEmpty)) { RecipesApp.openFromPasteboard(NSPasteboard.general, face: face); return true }
            if !shelf.items.isEmpty, p.y > Self.recentsTop, p.y < Self.recentsBottom {
                for (i, r) in shelf.items.enumerated() {
                    let row = Self.recentRow(i).offsetBy(dx: 0, dy: -scroll)
                    guard row.contains(p) else { continue }
                    if Self.removeZone(row).contains(p) { shelf.remove(at: i); RecipeStore.save(shelf); scroll = 0 }
                    else { show(r, base: r.sourceURL.flatMap(URL.init(string:)), remember: true) }
                    return true
                }
            }
            return false
        case .loading:
            return false
        case .failed:
            guard lastURL != nil else { if hit(Self.backButton) { screen = .home; return true }; return false }   // 沒有網址可重試（剪貼簿沒網址）：只有一顆「返回」
            let r = CGRect(x: 512 - 330, y: 660, width: 320, height: 104), b = CGRect(x: 512 + 10, y: 660, width: 320, height: 104)
            if hit(r) { screen = .home; return true }
            if hit(b), let u = lastURL { open(u, face: face); return true }
            return false
        case .noRecipe:
            if hit(Self.backButton) { screen = .home; return true }
            return false
        case .overview:
            if HPComponents.hitMediaBack(p) { HPComponents.navigateBack(); return true }
            let b = Self.overviewButtons
            if hit(b[0]) { go(.ingredients, now: now, kind: .blurFade); return true }
            if hit(b[1]) { go(.step(0), now: now, kind: .slideFromRight); return true }
            return false
        case .ingredients:
            if HPComponents.hitMediaBack(p) { go(.overview, now: now, kind: .blurFade); return true }
            guard let r = recipe, p.y >= 196 else { return false }
            let rows = ingredientRows(r).map { $0.offsetBy(dx: 0, dy: -scroll) }
            if let b = rows.last, hit(b) { go(.step(0), now: now, kind: .slideFromRight); return true }
            for (i, row) in rows.dropLast().enumerated() where row.insetBy(dx: 0, dy: -Self.ingGap / 2).contains(p) {
                toggleIngredient(i); return true
            }
            return false
        case .timer(let i):
            switch RecipeStepTimerView.hit(p) {
            case .back?: go(.step(i), now: now, kind: .blurFade)
            case .close?: cancelTimer(i); go(.step(i), now: now, kind: .blurFade)
            case .pause?: pausedLeft[i] != nil ? resumeTimer(i) : pauseTimer(i)
            case nil: return false
            }
            return true
        case .step(let i):
            guard let r = recipe, r.steps.indices.contains(i) else { return false }
            let dur = StepDuration.find(in: r.steps[i].text)
            let b = stepButtonRects(dur != nil)
            if HPComponents.hitMediaBack(p) { go(.overview, now: now, kind: .blurFade); return true }
            if hit(b.prev) { go(i == 0 ? .overview : .step(i - 1), now: now, kind: i == 0 ? .blurFade : .slideFromLeft); return true }
            if hit(b.next) { go(i >= r.steps.count - 1 ? .overview : .step(i + 1), now: now, kind: i >= r.steps.count - 1 ? .blurFade : .slideFromRight); return true }
            if let tb = b.timer, dur != nil, hit(tb) {
                // 2.0 promo：按計時＝開一組（已經有就不重開）並進全螢幕計時器（影片第 4 拍）；計時器在頂端膠囊繼續跑
                startTimer(i, now: now)
                return true
            }
            return false
        }
    }

    func handleScroll(_ dy: CGFloat, now: Double) -> Bool {
        switch screen {
        case .home, .ingredients, .step:
            guard maxScroll > 0 else { return false }
            scrollAnim = nil
            scroll = max(0, min(maxScroll, scroll - dy * 1.6)); return true
        default: return false
        }
    }

    // MARK: Demo（--demo-recipe；不連網、不寫入「最近」）

    /// 樣本食譜：JSON-LD 字串（含 @graph、HowToSection），文字走 L() 所以三種語言都有
    static func demoJSONLD() -> String {
        let steps1 = [L("recipe.demo.s1", "南瓜去皮切块，洋葱切丝。"), L("recipe.demo.s2", "锅里放奶油，中火融化。")]
        let steps2 = [L("recipe.demo.s3", "南瓜和洋葱放进锅里，中火炒到洋葱变透明，大约 8 分钟。"),
                      L("recipe.demo.s4", "加入高汤盖过食材，煮开后转小火，盖上锅盖煮 25 分钟，直到南瓜软烂。"),
                      L("recipe.demo.s5", "关火放凉 5 分钟，用调理棒打成滑顺的浓汤，加盐和黑胡椒调味。"),
                      L("recipe.demo.s6", "盛盘，淋上一点鲜奶油，撒上南瓜籽。")]
        func section(_ name: String, _ ss: [String]) -> [String: Any] {
            ["@type": "HowToSection", "name": name, "itemListElement": ss.map { ["@type": "HowToStep", "text": $0] }]
        }
        let recipe: [String: Any] = [
            "@type": "Recipe", "name": L("recipe.demo.title", "奶油南瓜浓汤"), "totalTime": "PT35M", "recipeYield": ["4", "4 servings"],
            "recipeIngredient": [L("recipe.demo.i1", "南瓜 600 克"), L("recipe.demo.i2", "洋葱 1 颗"), L("recipe.demo.i3", "奶油 20 克"),
                                 L("recipe.demo.i4", "鸡高汤 700 毫升"), L("recipe.demo.i5", "鲜奶油 50 毫升"), L("recipe.demo.i6", "盐和黑胡椒 适量"), L("recipe.demo.i7", "南瓜籽 1 大匙")],
            "recipeInstructions": [section(L("recipe.demo.prep", "准备"), steps1), section(L("recipe.demo.cook", "烹饪"), steps2)],
        ]
        let doc: [String: Any] = ["@context": "https://schema.org", "@graph": [["@type": "WebSite", "name": "Demo"], recipe]]
        let data = (try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])) ?? Data()
        return "<html><head><script type=\"application/ld+json\">" + (String(data: data, encoding: .utf8) ?? "{}") + "</script></head></html>"
    }

    /// 樣本封面（程式畫的：深色盤子上一碗橘色濃湯）
    private static func demoHero() -> CGImage {
        makeImage(1024, 1024) { c in
            MediaUI.fillGradient(c, MediaUI.full, srgb(0x3a2d24), srgb(0x14100d))
            c.setFillColor(srgb(0xd9d5cf).cgColor); c.fillEllipse(in: CGRect(x: 162, y: 190, width: 700, height: 700))
            c.setFillColor(srgb(0xf2efe9).cgColor); c.fillEllipse(in: CGRect(x: 196, y: 224, width: 632, height: 632))
            let cs = CGColorSpace(name: CGColorSpace.sRGB)
            if let grad = CGGradient(colorsSpace: cs, colors: [srgb(0xf5a53b).cgColor, srgb(0xd9731f).cgColor] as CFArray, locations: [0, 1]) {
                c.saveGState(); c.addEllipse(in: CGRect(x: 250, y: 278, width: 524, height: 524)); c.clip()
                c.drawRadialGradient(grad, startCenter: CGPoint(x: 480, y: 480), startRadius: 0, endCenter: CGPoint(x: 512, y: 540), endRadius: 290, options: [.drawsAfterEndLocation])
                c.restoreGState()
            }
            c.setFillColor(NSColor.white.withAlphaComponent(0.55).cgColor); c.fillEllipse(in: CGRect(x: 420, y: 470, width: 150, height: 40))
        }
    }

    /// 示範：直接放一組已經跑了 elapsed 秒的步驟計時器（宣傳片一切到計時器就是 00:43）
    func demoStartTimer(step i: Int, elapsed: Double) {
        guard let r = recipe, r.steps.indices.contains(i), let face else { return }
        let total = Double(StepDuration.find(in: r.steps[i].text) ?? 60)
        cancelTimer(i)
        stepTotals[i] = total
        stepTimers[i] = Shell.timers.add(seconds: max(1, total - elapsed), label: timerLabel(i), now: TimersApp.wallNow, total: total)
        Shell.reconcileTimers(face, now: CACurrentMediaTime())
    }
    /// 示範：直接換頁（走正式的過場）
    func demoGo(ingredients: Bool, now: Double = CACurrentMediaTime()) { go(ingredients ? .ingredients : .overview, now: now, kind: .blurFade) }
    func demoShowTimer(step i: Int, now: Double = CACurrentMediaTime()) { go(.timer(i), now: now, kind: .blurFade) }
    /// 示範：食材第 i 行現在在畫布上的哪裡（手指點那裡）
    func demoIngredientRow(_ i: Int) -> CGRect? {
        guard let r = recipe, i < r.ingredients.count else { return nil }
        return ingredientRows(r)[i].offsetBy(dx: 0, dy: -scroll)
    }
    func demoPrepare(_ f: Face) { face = f; persist = false; shelf = RecipeShelf() }

    /// 快照用：--demo-recipe [screen]，screen＝home｜overview｜ingredients｜step:N｜none｜failed｜loading
    func applyDemo(screen name: String?, face: Face) {
        self.face = face
        persist = false
        shelf = RecipeShelf()
        // 2.0 promo：--demo-recipe promo[:畫面]＝宣傳片的那份（檸檬藍莓優格磅蛋糕，PromoDemo.swift）
        let promo = name?.hasPrefix("promo") == true
        let html = promo ? PromoDemo.recipeHTML() : Self.demoJSONLD()
        var mode = name ?? "overview"
        if promo { mode = mode == "promo" ? "overview" : String(mode.dropFirst(6)) }
        if mode == "home" || mode == "home-recents" {
            screen = .home
            if mode == "home-recents", let r = RecipeParser.parse(html: html, sourceURL: "https://example.com/pumpkin-soup") {
                shelf.add(r)
                var second = r; second.title = L("recipe.demo.title2", "味噌烤鲑鱼"); second.sourceURL = "https://example.com/salmon"; second.totalSeconds = 1500; second.servings = 2
                shelf.add(second)
                var third = r; third.title = L("recipe.demo.title3", "番茄蛋炒饭"); third.sourceURL = "https://example.com/rice"; third.totalSeconds = 900; third.servings = 1
                shelf.add(third)
                var fourth = r; fourth.title = L("recipe.demo.title2", "味噌烤鲑鱼") + " 2"; fourth.sourceURL = "https://example.com/salmon2"
                shelf.add(fourth)
            }
            return
        }
        if mode == "none" { screen = .noRecipe("example.com"); return }
        if mode == "failed" { screen = .failed(L("recipe.failed", "打不开这个网页")); return }
        if mode == "loading" { screen = .loading("example.com"); return }
        guard var r = RecipeParser.parse(html: html, sourceURL: promo ? PromoDemo.pageURL.absoluteString : "https://example.com/pumpkin-soup") else { return }
        if OfficialDemo.on, !promo { r.title = OfficialDemo.recipeTitle; r.host = OfficialDemo.recipeSource }   // 官方 recipe-overview 的文字（照片仍是我們的）
        show(r, remember: false)
        hero = promo ? PromoDemo.hero() : Self.demoHero()
        heroKey = "demo"
        if mode == "ingredients" { screen = .ingredients; checked = [0, 1] }
        else if mode.hasPrefix("timer:"), let n = Int(mode.dropFirst(6)) {   // timer:N＝第 N 步的計時器，已經跑了 17 秒（影片的 00:43）
            demoStartTimer(step: max(0, min(r.steps.count - 1, n)), elapsed: 17)
            screen = .timer(max(0, min(r.steps.count - 1, n)))
        }
        else if mode.hasPrefix("step:"), let n = Int(mode.dropFirst(5)) {
            screen = .step(max(0, min(r.steps.count - 1, n)))
            // 快照：HOMEPLAY_ANIM=recipe.step:t 時，凍結「封面 → 步驟」滑入的第 t 秒（舊畫面用封面照代替，不經玻璃）
            if Anim.frozen("recipe.step") != nil, let h = hero {
                var t = PageTransition(.slideFromRight, face: face, now: CACurrentMediaTime(), spring: Self.slideSpring, name: "recipe.step")
                t.old = makeImage(1024, 1024) { c in MediaUI.drawCover(c, face: face, h, in: MediaUI.full)
                    if let grad = MediaUI.shade(0.78) { c.drawLinearGradient(grad, start: CGPoint(x: 0, y: 470), end: CGPoint(x: 0, y: 1024), options: [.drawsAfterEndLocation]) } }
                transition = t
            }
        }
    }
}

// MARK: - 最近的食譜（存在本機）

enum RecipeStore {
    static var url: URL {
        if let p = ProcessInfo.processInfo.environment["HOMEPLAY_RECIPES_FILE"] { return URL(fileURLWithPath: p) }   // 測試用：不動真的「最近」
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomePlay").appendingPathComponent("recipes.json")
    }
    static func load() -> RecipeShelf {
        guard let d = try? Data(contentsOf: url), var s = try? JSONDecoder().decode(RecipeShelf.self, from: d) else { return RecipeShelf() }
        if s.items.count > RecipeShelf.limit { s.items.removeLast(s.items.count - RecipeShelf.limit) }
        return s
    }
    static func save(_ s: RecipeShelf) {
        let u = url
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: u, options: .atomic) }
    }
}
