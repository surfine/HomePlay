// 2.0 promo（HomeView 宣傳片 @aaronp613 第 3、4 拍）：烹飪畫面的零件——
// 食材勾選記在本機（每份食譜一組）、食材行拆出「份量」灰字、步驟計時器全螢幕（深藍底、黃色刻度環、00:43、1 MIN、✕／暫停），
// 還有烹飪時的語音指令（「下一步」「勾掉蛋」「開始計時」），不經模型、在本機就做完。
// 刻度環先畫在這裡（正圓，影片的樣子）；計時器 App 的共用環（HPComponents.tickRing，圓角方形）之後若加了正圓版本，換過去只動 drawRing。

import AppKit

// MARK: - 版面（1024 畫布；量自宣傳片 5.67–7.3 s 的計時器畫面）

extension HPTokens {
    enum StepTimer {
        /// 深藍底：上 #141A40 → 下 #080B1E（影片的藍黑，不是計時器 App 的純黑）
        static let bgTop = srgb(0x141A40), bgBottom = srgb(0x080B1E)
        /// 黃＝系統黃（深色）；過去的刻度＝帶橘的暗黃（影片的褐色）
        static let tint = srgb(0xFFD60A)
        static let elapsed = srgb(0xB86E3C).withAlphaComponent(0.62)
        static let ticks = 60
        static let center = CGPoint(x: 512, y: 540)
        static let outerRadius: CGFloat = 390, innerRadius: CGFloat = 344
        static let tickWidth: CGFloat = 13
        static let stepSize: CGFloat = 38, stepBaseline: CGFloat = 438
        static let timeSize: CGFloat = 170, timeBaseline: CGFloat = 604
        static let labelSize: CGFloat = 38, labelBaseline: CGFloat = 670
        /// 左下 ✕（玻璃）、右下暫停（黃）：直徑 120，圓心離邊 150
        static let close = HPComponents.actionRect(cx: 150, cy: 874, size: 120)
        static let pause = HPComponents.actionRect(cx: 874, cy: 874, size: 120)
        /// 左上小玻璃鈕（回到步驟，計時器照跑、變成頂端膠囊）
        static let back = HPTokens.Media.backButton
    }
}

// MARK: - 純邏輯（--selftest 驗）

enum RecipeLine {
    /// 「¾ cup refined coconut oil」→（「¾」，「cup refined coconut oil」）：開頭的數字、分數、範圍當份量（影片裡是灰字）
    static func split(_ line: String) -> (qty: String, rest: String) {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let r = t.range(of: #"^(?:[0-9]+(?:[.,][0-9]+)?(?:\s*[½¼¾⅓⅔⅛])?|[½¼¾⅓⅔⅛]|[0-9]+/[0-9]+)(?:\s+[0-9]+/[0-9]+)?(?:\s*[-–]\s*[0-9]+(?:/[0-9]+)?)?(?=\s)"#,   // l10n-ignore
                              options: .regularExpression) else { return ("", t) }
        return (String(t[r]), String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    /// 「mm:ss」（一小時以上「h:mm:ss」）
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)   // l10n-ignore
    }

    /// 刻度環亮幾根：剩下的比例 × 60，往上取整（剛開始全亮、最後一秒還留一根）
    static func lit(left: Double, total: Double, ticks: Int = HPTokens.StepTimer.ticks) -> Int {
        guard total > 0, left > 0 else { return 0 }
        return min(ticks, Int((left / total * Double(ticks)).rounded(.up)))
    }
}

// MARK: - 勾選記在本機（每份食譜一組，最多 30 份）

enum RecipeChecks {
    static var url: URL { RecipeStore.url.deletingLastPathComponent().appendingPathComponent("recipe-checks.json") }
    static func key(_ r: Recipe) -> String { r.sourceURL ?? r.title }
    static func load(_ r: Recipe) -> Set<Int> {
        guard let d = try? Data(contentsOf: url), let all = try? JSONDecoder().decode([String: [Int]].self, from: d) else { return [] }
        return Set(all[key(r)] ?? [])
    }
    static func save(_ checked: Set<Int>, for r: Recipe) {
        var all = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: [Int]].self, from: $0) } ?? [:]
        all[key(r)] = checked.isEmpty ? nil : checked.sorted()
        if all.count > 30 { for k in all.keys.sorted().prefix(all.count - 30) { all[k] = nil } }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(all) { try? d.write(to: url, options: .atomic) }
    }
}

// MARK: - 語音指令（烹飪畫面開著時，ClioTalk 聽到的一句先問這裡）

enum RecipeVoice: Equatable {
    case next, previous, startTimer, pauseTimer, ingredients
    case check(String)        // 說的食材名（原文，比對在 RecipesApp）

    static func classify(_ text: String) -> RecipeVoice? {
        var t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "。．.!！?？,，"))
        for p in ["hey clio ", "clio ", "please ", "請", "请", "幫我", "帮我"] where t.hasPrefix(p) { t = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces) }   // l10n-ignore：比對用詞
        for s in [" please", "吧", "啊", "喔"] where t.hasSuffix(s) && t.count > s.count + 1 { t = String(t.dropLast(s.count)) }   // l10n-ignore
        let flat = t.filter { $0.isLetter || $0.isNumber }
        let next: Set<String> = ["next", "nextstep", "goon", "continue", "下一步", "下一步骤", "下一個步驟", "下一个步骤", "繼續", "继续"]   // l10n-ignore
        let prev: Set<String> = ["back", "goback", "previous", "previousstep", "laststep", "上一步", "上一個步驟", "上一个步骤", "回去"]   // l10n-ignore
        let start: Set<String> = ["startthetimer", "starttimer", "startatimer", "settimer", "setthetimer", "開始計時", "开始计时", "計時", "计时", "開計時器", "开计时器"]   // l10n-ignore
        let pause: Set<String> = ["pause", "pausethetimer", "pausetimer", "stopthetimer", "暫停", "暂停", "暫停計時", "暂停计时"]   // l10n-ignore
        let ing: Set<String> = ["ingredients", "showingredients", "showmetheingredients", "食材", "看食材", "材料"]   // l10n-ignore
        if next.contains(flat) { return .next }
        if prev.contains(flat) { return .previous }
        if start.contains(flat) { return .startTimer }
        if pause.contains(flat) { return .pauseTimer }
        if ing.contains(flat) { return .ingredients }
        // 「check off eggs」「cross off the flour」「勾掉雞蛋」「雞蛋好了」
        for p in ["check off ", "cross off ", "tick off ", "check ", "mark "] where t.hasPrefix(p) {   // l10n-ignore
            var rest = String(t.dropFirst(p.count))
            for a in ["the ", "my "] where rest.hasPrefix(a) { rest = String(rest.dropFirst(a.count)) }   // l10n-ignore
            if rest.hasSuffix(" off") { rest = String(rest.dropLast(4)) }
            return rest.isEmpty ? nil : .check(rest)
        }
        for p in ["勾掉", "勾選", "勾选", "劃掉", "划掉", "打勾"] where t.hasPrefix(p) && t.count > p.count { return .check(String(t.dropFirst(p.count))) }   // l10n-ignore
        for s in ["好了", "加好了", "放好了", "準備好了", "准备好了"] where t.hasSuffix(s) && t.count > s.count { return .check(String(t.dropLast(s.count))) }   // l10n-ignore
        return nil
    }

    /// 說的食材名 → 第幾行（英文去掉複數 s／es 再比；中文直接找子字串）；找不到 nil
    static func match(_ said: String, in lines: [String]) -> Int? {
        let s = said.lowercased().trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        func stem(_ w: String) -> String {
            if w.hasSuffix("ies"), w.count > 4 { return String(w.dropLast(3)) + "y" }
            if w.hasSuffix("es"), w.count > 4 { return String(w.dropLast(2)) }
            if w.hasSuffix("s"), w.count > 3 { return String(w.dropLast()) }
            return w
        }
        let want = s.split(whereSeparator: { !$0.isLetter }).map { stem(String($0)) }.filter { $0.count >= 2 }
        for (i, line) in lines.enumerated() {
            let l = line.lowercased()
            if l.contains(s) { return i }
            let words = Set(l.split(whereSeparator: { !$0.isLetter }).map { stem(String($0)) })
            if !want.isEmpty, want.allSatisfy({ words.contains($0) }) { return i }
        }
        return nil
    }
}

// MARK: - 步驟計時器全螢幕

enum RecipeStepTimerView {
    typealias T = HPTokens.StepTimer

    /// step：第幾步（從 0）；left／total 秒；paused；done＝已到點
    static func draw(_ g: CGContext, _ face: Face, step: Int, left: Double, total: Double, paused: Bool) {
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        if let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [T.bgTop.cgColor, T.bgBottom.cgColor] as CFArray, locations: [0, 1]) {
            g.saveGState(); g.clip(to: full)
            g.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: 1024), options: [])
            g.restoreGState()
        }
        drawRing(g, lit: RecipeLine.lit(left: left, total: total))
        let done = left <= 0
        let sf = FaceType.sf(T.stepSize, .semibold, mono: false)
        HPComponents.center(g, face, String(format: L("recipe.timer.step", "步骤 %d"), step + 1), sf, y: T.stepBaseline, .white)
        // 剩餘時間：等寬數字（秒數跳動時字不晃），白
        let big = RecipeLine.clock(left)
        let tf = FaceType.sf(big.count > 5 ? T.timeSize * 0.78 : T.timeSize, .medium, mono: true)
        HPComponents.center(g, face, big, tf, y: T.timeBaseline, NSColor.white.withAlphaComponent(paused ? 0.6 : 1))
        HPAX.note(g, CGRect(x: 512 - 260, y: T.timeBaseline - tf.ascender, width: 520, height: tf.ascender + 30), .text,
                  String(format: L("a11y.pair", "%1$@，%2$@"), big, String(format: L("recipe.timer.step", "步骤 %d"), step + 1)), shape: .rounded(40))
        let lf = FaceType.sf(T.labelSize, .semibold, mono: false)
        let label = done ? L("recipe.timer.done", "时间到了") : paused ? L("recipe.timer.paused", "已暂停") : durationLabel(total)
        HPComponents.center(g, face, label.uppercased(with: L10n.language.locale), lf, y: T.labelBaseline, T.tint)
        // 控制：左上回步驟（玻璃，黃色計時器符號）、左下 ✕、右下暫停／繼續（黃）
        HPComponents.glassCircle(g, face, T.back, symbol: "timer", ink: T.tint, scale: 0.44)
        HPComponents.actionButton(g, face, T.close, symbol: "xmark", role: .glass)
        if !done { HPComponents.actionButton(g, face, T.pause, symbol: paused ? "play.fill" : "pause.fill", role: .mic) }
    }

    /// 「1 MIN」「1 HR 30 MIN」：照計時器 App 的寫法（全大寫交給呼叫端）
    static func durationLabel(_ total: Double) -> String {
        let m = Int((total / 60).rounded())
        if m >= 60 { return String(format: L("recipe.timer.hm", "%1$d 小时 %2$d 分钟"), m / 60, m % 60) }
        if m >= 1 { return String(format: L("recipe.timer.min", "%d 分钟"), m) }
        return String(format: L("recipe.timer.sec", "%d 秒"), Int(total.rounded()))
    }

    /// 60 根徑向刻度排成正圓，從 12 點順時針：亮的是剩下的時間
    static func drawRing(_ g: CGContext, lit: Int) {
        g.saveGState()
        g.setLineCap(.round); g.setLineWidth(T.tickWidth)
        for i in 0..<T.ticks {
            let a = CGFloat(i) / CGFloat(T.ticks) * 2 * .pi
            let d = CGPoint(x: sin(a), y: -cos(a))
            g.setStrokeColor((i < lit ? T.tint : T.elapsed).cgColor)
            g.move(to: CGPoint(x: T.center.x + d.x * T.outerRadius, y: T.center.y + d.y * T.outerRadius))
            g.addLine(to: CGPoint(x: T.center.x + d.x * T.innerRadius, y: T.center.y + d.y * T.innerRadius))
            g.strokePath()
        }
        g.restoreGState()
    }

    enum Hit { case back, close, pause }
    static func hit(_ p: CGPoint) -> Hit? {
        if T.back.insetBy(dx: -8, dy: -8).contains(p) { return .back }
        if T.close.insetBy(dx: -8, dy: -8).contains(p) { return .close }
        if T.pause.insetBy(dx: -8, dy: -8).contains(p) { return .pause }
        return nil
    }
}

// MARK: - 自檢

enum RecipeCookingSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        let a = RecipeLine.split("¾ cup refined coconut oil"), b = RecipeLine.split("1 ¼ teaspoons baking powder"), c = RecipeLine.split("Kosher salt")
        let d = RecipeLine.split("1 1/2 cups whole-milk Greek yogurt"), e = RecipeLine.split("2-3 large eggs")
        check(a == ("¾", "cup refined coconut oil") && b == ("1 ¼", "teaspoons baking powder") && c == ("", "Kosher salt")
              && d == ("1 1/2", "cups whole-milk Greek yogurt") && e == ("2-3", "large eggs"), "食譜：食材行拆出份量（灰字）")   // l10n-ignore：selftest 訊息
        check(RecipeLine.clock(43) == "00:43" && RecipeLine.clock(42.2) == "00:43" && RecipeLine.clock(3725) == "1:02:05" && RecipeLine.clock(-3) == "00:00",
              "食譜計時器：mm:ss（往上取整）")   // l10n-ignore
        check(RecipeLine.lit(left: 60, total: 60) == 60 && RecipeLine.lit(left: 43, total: 60) == 43 && RecipeLine.lit(left: 0.2, total: 60) == 1 && RecipeLine.lit(left: 0, total: 60) == 0,
              "食譜計時器：刻度亮的是剩下的")   // l10n-ignore
        let v: [(String, RecipeVoice?)] = [("Next step.", .next), ("下一步", .next), ("go back", .previous), ("Start the timer", .startTimer), ("開始計時", .startTimer),   // l10n-ignore：測試樣本
                                           ("pause", .pauseTimer), ("Check off eggs", .check("eggs")), ("check off the flour", .check("flour")), ("勾掉雞蛋", .check("雞蛋")),
                                           ("鸡蛋好了", .check("鸡蛋")), ("what's the weather", nil), ("next week's forecast", nil)]   // l10n-ignore：測試樣本
        let bad = v.filter { RecipeVoice.classify($0.0) != $0.1 }.map(\.0)
        check(bad.isEmpty, "食譜語音：下一步／勾掉食材／開始計時（\(bad)）")   // l10n-ignore
        let lines = ["¾ cup refined coconut oil", "2 cups all-purpose flour", "3 large eggs", "1 cup granulated sugar", "雞蛋 3 顆"]   // l10n-ignore
        check(RecipeVoice.match("eggs", in: lines) == 2 && RecipeVoice.match("egg", in: lines) == 2 && RecipeVoice.match("flour", in: lines) == 1
              && RecipeVoice.match("雞蛋", in: lines) == 4 && RecipeVoice.match("butter", in: lines) == nil, "食譜語音：說的食材找到那一行")   // l10n-ignore
        // 勾選記在本機：換一份食譜各自記、空的不留
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hp-checks-\(getpid())")
        setenv("HOMEPLAY_RECIPES_FILE", dir.appendingPathComponent("recipes.json").path, 1)
        let r1 = Recipe(title: "A", ingredients: ["x"], steps: [], sourceURL: "https://a.example/1"), r2 = Recipe(title: "B", ingredients: ["y"], steps: [])
        RecipeChecks.save([0, 2], for: r1); RecipeChecks.save([1], for: r2)
        let ok1 = RecipeChecks.load(r1) == [0, 2] && RecipeChecks.load(r2) == [1]
        RecipeChecks.save([], for: r1)
        let ok2 = RecipeChecks.load(r1).isEmpty && RecipeChecks.load(r2) == [1]
        unsetenv("HOMEPLAY_RECIPES_FILE"); try? FileManager.default.removeItem(at: dir)
        check(ok1 && ok2, "食譜：勾選每份食譜各自記在本機")   // l10n-ignore
        typealias T = HPTokens.StepTimer
        check(T.close.width >= 88 && T.pause.width >= 88 && T.center.y - T.outerRadius - T.tickWidth / 2 > 108 && abs(T.close.midX - (1024 - T.pause.midX)) < 0.5,
              "食譜計時器：按鈕 ≥ 88、刻度環在 👀 膠囊底下、左右對稱")   // l10n-ignore
    }
}
