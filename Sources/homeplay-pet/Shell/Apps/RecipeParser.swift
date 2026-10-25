// 食譜的純邏輯（解析本身只用 Foundation；自檢要用剪貼簿與字體）：從網頁抽 schema.org Recipe JSON-LD、ISO-8601 時間、份量、步驟裡的時間。
// 食譜 App（RecipesApp.swift）只管畫與抓網頁；這裡的東西 --selftest 直接驗。
// 帶中文的正則與比對詞行尾標 l10n-ignore：那是比對用詞，不是介面文字。

import AppKit

struct RecipeStep: Equatable, Codable {
    var text: String
    var section: String? = nil
}

struct Recipe: Equatable, Codable {
    var title: String
    var imageURL: String? = nil
    var totalSeconds: Int? = nil
    var servings: Int? = nil
    /// 份量原文（「12 cookies」這種不是「人份」的）；servings 有值而這裡是 nil 時顯示「N 人份」
    var yieldText: String? = nil
    var ingredients: [String]
    var steps: [RecipeStep]
    var sourceURL: String? = nil
    var host: String? = nil
}

enum RecipeParser {
    // MARK: 網頁 → 食譜

    /// 整頁 HTML → 第一個找得到的 Recipe；沒有 JSON-LD 食譜、或沒有食材也沒有步驟就是 nil（呼叫端顯示「沒有食譜資料」）
    static func parse(html: String, sourceURL: String? = nil) -> Recipe? {
        for block in jsonLDBlocks(html) {
            if let d = findRecipe(block), var r = recipe(from: d) {
                r.sourceURL = sourceURL
                r.host = sourceURL.flatMap { URL(string: $0)?.host }
                return r
            }
        }
        return nil
    }

    /// 每個 <script type="application/ld+json"> 的內容（解析失敗的略過；常見的 CDATA／HTML 註解包裝先剝掉）
    static func jsonLDBlocks(_ html: String) -> [Any] {
        guard let re = try? NSRegularExpression(pattern: #"<script\b[^>]*type\s*=\s*["']?application/ld\+json["']?[^>]*>(.*?)</script>"#,
                                                options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        var out: [Any] = []
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
            var s = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            for (a, b) in [("<!--", "-->"), ("//<![CDATA[", "//]]>"), ("/*<![CDATA[*/", "/*]]>*/"), ("<![CDATA[", "]]>")] where s.hasPrefix(a) && s.hasSuffix(b) {
                s = String(s.dropFirst(a.count).dropLast(b.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // JSON 字串裡不允許的控制字元（有些網站把換行直接寫進字串）換成空白
            let cleaned = String(String.UnicodeScalarView(s.unicodeScalars.map { $0.value < 0x20 && $0 != "\n" ? " " : $0 }))
            for candidate in [s, cleaned] {
                if let data = candidate.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                    out.append(obj); break
                }
            }
        }
        return out
    }

    private static func types(_ d: [String: Any]) -> [String] {
        if let t = d["@type"] as? String { return [t] }
        if let t = d["@type"] as? [Any] { return t.compactMap { $0 as? String } }
        return []
    }

    /// 在 JSON-LD 節點裡找 Recipe：陣列、@graph、mainEntity 都往下找
    static func findRecipe(_ node: Any) -> [String: Any]? {
        if let arr = node as? [Any] {
            for n in arr { if let r = findRecipe(n) { return r } }
            return nil
        }
        guard let d = node as? [String: Any] else { return nil }
        if types(d).contains(where: { $0 == "Recipe" || $0.hasSuffix("/Recipe") }) { return d }
        for key in ["@graph", "mainEntity", "mainEntityOfPage", "about", "hasPart"] {
            if let v = d[key], let r = findRecipe(v) { return r }
        }
        return nil
    }

    static func recipe(from d: [String: Any]) -> Recipe? {
        let title = clean(d["name"] ?? d["headline"])
        let ingredients = strings(d["recipeIngredient"] ?? d["ingredients"]).map(clean).filter { !$0.isEmpty }
        let steps = steps(from: d["recipeInstructions"])
        guard !ingredients.isEmpty || !steps.isEmpty else { return nil }
        var total = (d["totalTime"] as? String).flatMap(isoDuration)
        if total == nil {
            let parts = [d["prepTime"], d["cookTime"]].compactMap { ($0 as? String).flatMap(isoDuration) }
            if !parts.isEmpty { total = parts.reduce(0, +) }
        }
        let y = parseYield(d["recipeYield"])
        return Recipe(title: title.isEmpty ? L("recipe.untitled", "未命名食谱") : title, imageURL: imageURL(d["image"]),
                      totalSeconds: total, servings: y.servings, yieldText: y.text, ingredients: ingredients, steps: steps)
    }

    /// image 可能是字串、字串陣列、ImageObject（url）、ImageObject 陣列
    static func imageURL(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s.isEmpty ? nil : s
        case let a as [Any]: return a.lazy.compactMap { imageURL($0) }.first
        case let d as [String: Any]: return imageURL(d["url"] ?? d["contentUrl"])
        default: return nil
        }
    }

    private static func strings(_ v: Any?) -> [String] {
        switch v {
        case let s as String: return s.components(separatedBy: "\n")
        case let a as [Any]: return a.flatMap { strings($0) }
        case let d as [String: Any]: return strings(d["text"] ?? d["name"])
        default: return []
        }
    }

    /// recipeInstructions：字串（可含換行）、字串陣列、HowToStep、HowToSection（含巢狀 itemListElement）
    static func steps(from v: Any?, section: String? = nil) -> [RecipeStep] {
        switch v {
        case let s as String:
            return s.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "<br/>", with: "\n")
                .replacingOccurrences(of: "</li>", with: "\n").replacingOccurrences(of: "</p>", with: "\n")
                .components(separatedBy: "\n").map(clean).map(stripNumbering).filter { !$0.isEmpty }
                .map { RecipeStep(text: $0, section: section) }
        case let a as [Any]:
            return a.flatMap { steps(from: $0, section: section) }
        case let d as [String: Any]:
            if let items = d["itemListElement"] ?? d["steps"] {
                let name = clean(d["name"])
                return steps(from: items, section: name.isEmpty ? section : name)
            }
            let t = clean(d["text"] ?? d["description"] ?? d["name"])
            let text = stripNumbering(t)
            return text.isEmpty ? [] : [RecipeStep(text: text, section: section)]
        default:
            return []
        }
    }

    private static func stripNumbering(_ s: String) -> String {
        s.replacingOccurrences(of: #"^\s*(?:step\s*)?[0-9]{1,2}\s*[\.\)、:：]\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
    }

    // MARK: 文字清理

    static func clean(_ v: Any?) -> String {
        let s: String
        switch v {
        case let x as String: s = x
        case let x as NSNumber: s = x.stringValue
        default: return ""
        }
        return decodeEntities(s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—", "hellip": "…",
                     "deg": "°", "frac12": "½", "frac14": "¼", "frac34": "¾", "rsquo": "’", "lsquo": "‘", "ldquo": "“", "rdquo": "”", "times": "×"]
        var out = ""
        var rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let tail = rest[amp...]
            guard let semi = tail.firstIndex(of: ";"), tail.distance(from: tail.startIndex, to: semi) <= 10 else { out += "&"; rest = rest[rest.index(after: amp)...]; continue }
            let name = String(tail[tail.index(after: tail.startIndex)..<semi])
            var rep: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") { rep = UInt32(name.dropFirst(2), radix: 16).flatMap { Unicode.Scalar($0) }.map { String($0) } }
            else if name.hasPrefix("#") { rep = UInt32(name.dropFirst(1)).flatMap { Unicode.Scalar($0) }.map { String($0) } }
            else { rep = named[name] }
            if let rep { out += rep; rest = tail[tail.index(after: semi)...] } else { out += "&"; rest = rest[rest.index(after: amp)...] }
        }
        return out + rest
    }

    // MARK: ISO-8601 時間

    /// "PT35M"、"PT1H20M"、"P1DT2H"、"PT90S"、"PT1.5H" → 秒；格式不對或是 0 回 nil
    static func isoDuration(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces).uppercased()
        guard t.hasPrefix("P"), t.count > 1 else { return nil }
        var total = 0.0, num = "", inTime = false, any = false
        for ch in t.dropFirst() {
            if ch == "T" { inTime = true; continue }
            if ch.isNumber || ch == "." || ch == "," { num.append(ch == "," ? "." : ch); continue }
            guard let n = Double(num) else { return nil }
            num = ""
            switch (ch, inTime) {
            case ("Y", false): total += n * 365 * 86400
            case ("W", false): total += n * 7 * 86400
            case ("D", false): total += n * 86400
            case ("H", true): total += n * 3600
            case ("M", true): total += n * 60
            case ("S", true): total += n
            case ("M", false): total += n * 30 * 86400
            default: return nil
            }
            any = true
        }
        guard any, num.isEmpty, total >= 1 else { return nil }
        return Int(total.rounded())
    }

    // MARK: 份量

    /// recipeYield：數字、"4"、"Serves 4"、"4 servings"、["4", "4 servings"]、"4-6 人份"、"四人份"、"12 cookies"
    static func parseYield(_ v: Any?) -> (servings: Int?, text: String?) {
        var candidates: [String] = []
        switch v {
        case let s as String: candidates = [s]
        case let n as NSNumber: candidates = [n.stringValue]
        case let a as [Any]: candidates = a.map { clean($0) }
        default: return (nil, nil)
        }
        candidates = candidates.map(clean).filter { !$0.isEmpty }
        guard let pick = candidates.first(where: { $0.rangeOfCharacter(from: .decimalDigits) != nil }) ?? candidates.first else { return (nil, nil) }
        var n: Int?
        if let m = pick.range(of: #"[0-9]+"#, options: .regularExpression) { n = Int(pick[m]) }
        else if let m = pick.range(of: #"[一二兩两三四五六七八九十]+(?=\s*(?:人|份))"#, options: .regularExpression) {   // l10n-ignore
            n = StepDuration.chineseInt(String(pick[m]))
        }
        guard let servings = n, servings > 0, servings < 1000 else { return (nil, nil) }
        // 純「4」「4 servings」「Serves 4」「4 人份」→ 只留份數，顯示時統一寫成「N 人份」；其他描述（12 cookies）保留原文
        let generic = pick.range(of: #"^(?:serves?|makes?|yields?)?\s*[0-9]+(?:\s*[-–~到至]\s*[0-9]+)?\s*(?:servings?|portions?|people|persons?|人份|人|份)?$"#,   // l10n-ignore
                                 options: [.regularExpression, .caseInsensitive]) != nil   // l10n-ignore
            || pick.range(of: #"^[一二兩两三四五六七八九十]+\s*(?:人份|人|份)$"#, options: .regularExpression) != nil   // l10n-ignore
        return (servings, generic ? nil : pick)
    }
}

// MARK: - 步驟裡的時間

enum StepDuration {
    // 數字：阿拉伯數字、分數（1/2、1 1/2、1½）、中文數字（含「一個半」）、「半」
    private static let num = #"(?:[0-9]+\s+[0-9]+/[0-9]+|[0-9]+/[0-9]+|[0-9]+(?:\.[0-9]+)?[½¼¾⅓⅔]?|[½¼¾⅓⅔]|[零〇一二兩两三四五六七八九十]+(?:[個个]?半)?|半)"#   // l10n-ignore
    private static let unitH = #"(?:[個个]\s*)?(?:小時|小时|鐘頭|钟头|hours?|hrs?|h)(?![a-z])"#   // l10n-ignore
    private static let unitM = #"(?:分鐘|分钟|分(?![熟成裝装開开量之糖])|minutes?|mins?)(?![a-z])"#   // l10n-ignore
    private static let unitS = #"(?:秒鐘|秒钟|秒|seconds?|secs?)(?![a-z])"#   // l10n-ignore
    private static let regex = try! NSRegularExpression(
        pattern: "(\(num))(?:\\s*(?:-|–|—|~|～|到|至|to|or)\\s*\(num))?\\s*(?:(\(unitH))|(\(unitM))|(\(unitS)))",   // l10n-ignore
        options: [.caseInsensitive])

    /// 文字裡的第一段時間（秒）。「1 小時 20 分」「1 hour 30 minutes」這種相連的會加起來；範圍（8-10 分鐘）取下限；沒有回 nil
    static func find(in text: String) -> Int? {
        let ns = text as NSString
        let ms = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let first = ms.first else {
            let lower = text.lowercased()
            return lower.contains("half an hour") || lower.contains("half hour") ? 1800 : nil
        }
        func value(_ m: NSTextCheckingResult) -> (Double, Int)? {
            guard let n = number(ns.substring(with: m.range(at: 1))) else { return nil }
            if m.range(at: 2).location != NSNotFound { return (n * 3600, 3) }
            if m.range(at: 3).location != NSNotFound { return (n * 60, 2) }
            return (n, 1)
        }
        guard var (total, rank) = value(first) else { return nil }
        var end = first.range.location + first.range.length
        for m in ms.dropFirst() {
            let gap = ns.substring(with: NSRange(location: end, length: max(0, m.range.location - end)))
            guard m.range.location >= end, gap.count <= 6,
                  gap.range(of: #"^\s*(?:and|又|零|,)?\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil,   // l10n-ignore
                  let (v, r) = value(m), r < rank else { break }
            total += v; rank = r
            end = m.range.location + m.range.length
        }
        let s = Int(total.rounded())
        return s >= 1 ? s : nil
    }

    static func number(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let vulgar: [Character: Double] = ["½": 0.5, "¼": 0.25, "¾": 0.75, "⅓": 1.0 / 3, "⅔": 2.0 / 3]
        if let c = s.last, let f = vulgar[c] {
            let head = String(s.dropLast())
            return (head.isEmpty ? 0 : Double(head)) .map { $0 + f } ?? (head.isEmpty ? f : nil)
        }
        if let d = Double(s) { return d }
        if s.contains("/") {
            let parts = s.split(separator: " ")
            var sum = 0.0
            for p in parts {
                let f = p.split(separator: "/")
                if f.count == 2, let a = Double(f[0]), let b = Double(f[1]), b != 0 { sum += a / b }
                else if let a = Double(p) { sum += a } else { return nil }
            }
            return sum
        }
        // 中文：「半」「一個半」「十五」「兩」
        if s == "半" { return 0.5 }   // l10n-ignore
        var body = s, extra = 0.0
        if body.hasSuffix("半") { body.removeLast(); extra = 0.5 }   // l10n-ignore
        if body.hasSuffix("個") || body.hasSuffix("个") { body.removeLast() }   // l10n-ignore
        guard let n = chineseInt(body) else { return nil }
        return Double(n) + extra
    }

    /// 一…九十九的中文數字：「十五」15、「二十」20、「兩」2
    static func chineseInt(_ s: String) -> Int? {
        let digit: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "兩": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]   // l10n-ignore
        guard !s.isEmpty else { return nil }
        if let ten = s.firstIndex(of: "十") {   // l10n-ignore
            let head = s[..<ten], tail = s[s.index(after: ten)...]
            let h = head.isEmpty ? 1 : (head.count == 1 ? digit[head.first!] : nil)
            let t = tail.isEmpty ? 0 : (tail.count == 1 ? digit[tail.first!] : nil)
            guard let h, let t else { return nil }
            return h * 10 + t
        }
        var n = 0
        for c in s { guard let d = digit[c] else { return nil }; n = n * 10 + d }
        return n
    }

    /// 秒 → 介面上的樣子：「8 分钟」「1 小时 20 分钟」「30 秒」
    static func label(_ seconds: Int) -> String {
        let h = seconds / 3600, m = seconds % 3600 / 60, s = seconds % 60
        if h > 0 { return m > 0 ? String(format: L("recipe.time.hourMin", "%d 小时 %d 分钟"), h, m) : String(format: L("recipe.time.hour", "%d 小时"), h) }
        if m > 0 { return s > 0 ? String(format: L("recipe.time.minSec", "%d 分 %d 秒"), m, s) : String(format: L("recipe.time.min", "%d 分钟"), m) }
        return String(format: L("recipe.time.sec", "%d 秒"), s)
    }
}

/// 最近的食譜（釘選）：最多 10 筆，同一個網址／標題只留最新一筆
struct RecipeShelf: Equatable, Codable {
    static let limit = 10
    var items: [Recipe] = []

    mutating func add(_ r: Recipe) {
        items.removeAll { ($0.sourceURL != nil && $0.sourceURL == r.sourceURL) || ($0.sourceURL == nil && $0.title == r.title) }
        items.insert(r, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
    }
    mutating func remove(at i: Int) { if items.indices.contains(i) { items.remove(at: i) } }
}

/// 食譜 App 的自檢（main.swift 的 --selftest 經 ShellSelfTest 呼叫）
enum RecipeSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        // JSON-LD：@graph 裡的 Recipe、HowToSection 分段、型別是陣列、HTML 實體與標籤
        let graph = """
        <html><head><script type="application/ld+json">{"@context":"https://schema.org","@graph":[{"@type":"WebSite","name":"x"},
        {"@type":["Recipe","Thing"],"name":"Tom &amp; Jerry <b>Soup</b>","image":[{"@type":"ImageObject","url":"https://e.com/a.jpg"}],
        "totalTime":"PT1H20M","recipeYield":["4","4 servings"],"recipeIngredient":["1 onion","2 tbsp butter &amp; oil"],
        "recipeInstructions":[{"@type":"HowToSection","name":"Prep","itemListElement":[{"@type":"HowToStep","text":"1. Chop the onion."},{"@type":"HowToStep","text":"Melt butter."}]},
        {"@type":"HowToSection","name":"Cook","itemListElement":[{"@type":"HowToStep","text":"Simmer 10 minutes."}]}]}]}</script></head></html>
        """
        let r = RecipeParser.parse(html: graph, sourceURL: "https://example.com/soup")
        check(r?.title == "Tom & Jerry Soup" && r?.imageURL == "https://e.com/a.jpg", "食谱：@graph 里的 Recipe、实体与标签清掉、image 取 ImageObject.url")
        check(r?.totalSeconds == 4800 && r?.servings == 4 && r?.yieldText == nil && r?.host == "example.com", "食谱：totalTime、份量、来源主机")
        check(r?.ingredients == ["1 onion", "2 tbsp butter & oil"], "食谱：食材")
        check(r?.steps.map(\.text) == ["Chop the onion.", "Melt butter.", "Simmer 10 minutes."] && r?.steps.map(\.section) == ["Prep", "Prep", "Cook"], "食谱：HowToSection 展开、去掉步骤编号、保留分段名")
        // 其他形狀：字串型 instructions（換行分步）、prep+cook 相加、頂層陣列、沒有食譜
        let plain = #"<script type='application/ld+json'>[{"@type":"Recipe","name":"A","prepTime":"PT10M","cookTime":"PT20M","recipeIngredient":"1 egg","recipeInstructions":"Beat.\nFry 2 minutes."}]</script>"#
        let p = RecipeParser.parse(html: plain)
        check(p?.totalSeconds == 1800 && p?.steps.count == 2 && p?.ingredients == ["1 egg"], "食谱：prep+cook、字串型步骤、顶层数组")
        check(RecipeParser.parse(html: "<html><script type=\"application/ld+json\">{\"@type\":\"Article\"}</script></html>") == nil, "食谱：没有 Recipe 就是 nil")
        check(RecipeParser.parse(html: "<script type=\"application/ld+json\">{broken</script>") == nil, "食谱：坏掉的 JSON-LD 略过")
        // ISO-8601
        check(RecipeParser.isoDuration("PT35M") == 2100 && RecipeParser.isoDuration("PT1H20M") == 4800, "ISO 时间：分、时分")
        check(RecipeParser.isoDuration("P1DT2H") == 93600 && RecipeParser.isoDuration("PT90S") == 90 && RecipeParser.isoDuration("PT1.5H") == 5400, "ISO 时间：日、秒、小数")
        check(RecipeParser.isoDuration("35") == nil && RecipeParser.isoDuration("PT") == nil && RecipeParser.isoDuration("PT0M") == nil, "ISO 时间：不合格式回 nil")
        // 份量
        check(RecipeParser.parseYield("4").servings == 4 && RecipeParser.parseYield(6).servings == 6, "份量：数字")
        check(RecipeParser.parseYield("Serves 4").servings == 4 && RecipeParser.parseYield("Serves 4").text == nil, "份量：Serves 4")
        check(RecipeParser.parseYield("4-6 servings").servings == 4, "份量：范围取下限")
        check(RecipeParser.parseYield("四人份").servings == 4, "份量：中文数字")   // l10n-ignore
        check(RecipeParser.parseYield("12 cookies").servings == 12 && RecipeParser.parseYield("12 cookies").text == "12 cookies", "份量：非「人份」的保留原文")
        check(RecipeParser.parseYield(["", "4 servings"]).servings == 4 && RecipeParser.parseYield(nil).servings == nil, "份量：数组与缺省")
        // 步驟裡的時間（中英文）
        check(StepDuration.find(in: "南瓜和洋蔥放進鍋裡，中火炒到洋蔥變透明，大約 8 分鐘。") == 480, "步骤时间：8 分钟")   // l10n-ignore
        check(StepDuration.find(in: "小火燉 1 小時 20 分") == 4800, "步骤时间：1 小时 20 分")   // l10n-ignore
        check(StepDuration.find(in: "Simmer for 10 minutes.") == 600 && StepDuration.find(in: "bake 1½ hours") == 5400, "步骤时间：10 minutes、1½ hours")
        check(StepDuration.find(in: "Cook 1 hour 30 minutes") == 5400 && StepDuration.find(in: "1 hr and 15 min") == 4500, "步骤时间：相连的小时分钟相加")
        check(StepDuration.find(in: "烤一個半小時") == 5400 && StepDuration.find(in: "放半小時") == 1800 && StepDuration.find(in: "十五分鐘") == 900, "步骤时间：中文数字、一个半、半小时")   // l10n-ignore
        check(StepDuration.find(in: "Rest 2-3 minutes") == 120 && StepDuration.find(in: "煮 8 到 10 分鐘") == 480, "步骤时间：范围取下限")   // l10n-ignore
        check(StepDuration.find(in: "Boil 30 seconds") == 30 && StepDuration.find(in: "攪拌 45 秒") == 45, "步骤时间：秒")   // l10n-ignore
        check(StepDuration.find(in: "Cook 5 min, then 10 min") == 300, "步骤时间：只取第一段")
        check(StepDuration.find(in: "牛排煎三分熟") == nil && StepDuration.find(in: "加入 2 大匙醬油") == nil && StepDuration.find(in: "Add 2 tbsp salt") == nil, "步骤时间：不是时间的不误判")   // l10n-ignore
        check(StepDuration.find(in: "Let it rest for half an hour") == 1800, "步骤时间：half an hour")
        // 網址來源：純網址、夾在句子裡、剪貼簿裡的 URL 物件；檔案與非網頁不收
        check(RecipesApp.url(fromText: "  https://example.com/r?id=1 \n")?.host == "example.com", "食谱网址：纯网址")
        check(RecipesApp.url(fromText: "看看这个 https://example.com/soup 很好吃")?.path == "/soup", "食谱网址：夹在句子里")   // l10n-ignore
        check(RecipesApp.url(fromText: "file:///tmp/a.html") == nil && RecipesApp.url(fromText: "ftp://example.com/a") == nil && RecipesApp.url(fromText: "没有网址") == nil, "食谱网址：只收 http／https")   // l10n-ignore
        let pb = NSPasteboard(name: NSPasteboard.Name("homeplay.selftest.\(getpid())"))
        pb.clearContents(); pb.writeObjects([NSURL(string: "https://example.com/u")!])
        check(RecipesApp.url(from: pb)?.host == "example.com", "食谱网址：剪贴板里的 URL 对象")
        pb.clearContents(); pb.setString("https://example.org/t", forType: .string)
        check(RecipesApp.url(from: pb)?.host == "example.org", "食谱网址：剪贴板里的文字")
        pb.releaseGlobally()
        // 折行：每行不超寬，去掉空白後接回去等於原文
        let wf = Face.rounded(40, weight: .bold), src = "南瓜和洋蔥放進鍋裡，中火炒到洋蔥變透明，大約 8 分鐘。Simmer gently for about ten minutes"   // l10n-ignore
        let wl = MediaUI.wrap(src, wf, 600, maxLines: 20)
        check(wl.count > 2 && wl.allSatisfy { Typo.width($0, wf) <= 600.5 } && wl.joined().replacingOccurrences(of: " ", with: "") == src.replacingOccurrences(of: " ", with: ""), "折行：中英混排不超宽、不丢字")
        check(MediaUI.wrap("，。", wf, 10, maxLines: 3).first?.hasPrefix("，") == true && MediaUI.wrap(src, wf, 300, maxLines: 2).count == 2, "折行：超过行数缩成两行")
        // 釘選：最多 10 筆、同網址只留最新
        var shelf = RecipeShelf()
        for i in 0..<12 { shelf.add(Recipe(title: "r\(i)", ingredients: ["x"], steps: [], sourceURL: "https://e.com/\(i)")) }
        shelf.add(Recipe(title: "r5 again", ingredients: ["x"], steps: [], sourceURL: "https://e.com/5"))
        check(shelf.items.count == 10 && shelf.items.first?.title == "r5 again" && shelf.items.filter { $0.sourceURL == "https://e.com/5" }.count == 1, "食谱釘选：最多 10 笔、同网址去重、最新在前")
    }
}
