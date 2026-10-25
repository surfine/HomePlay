// HPDS v1：Type——字級表、SF Pro 取字、放不下就縮、中英混排規則。規格見 Design/README.md。
//
// 底層是 Faces/Typography.swift 的 FaceType／Typo（SF Pro 可變軸、照螢幕上實際字級選 opsz 與 trak 字距、中文退回蘋方）；
// 這裡只是 App 與外殼用的那一層：一律 SF Pro（不用圓體）、字級從表裡挑、大數字才用等寬。
// 字體是系統提供的（SF Pro／SF Compact／PingFang），不打包。
//
// 中英混排（照現有字串與 FaceType 的做法）：
// - 中文字形跟著介面語言：簡體介面用 PingFang SC，其餘（繁體、英文介面裡的中文）用 PingFang TC（台灣字形）；
//   退回字體照 wght 挑同粗細的蘋方（CoreText 自己挑會忽略可變粗細）。
// - 中文與英文、數字之間的半形空格寫在字串裡（「2 小時 46 分鐘」「3 樓 會議室 B」），排版不自動加。
// - 標點用全形（，。：「」），英文句子裡用半形。
// - 字距只照 SF Pro 的 trak 表（Typo.attributes），不另外加；全大寫的英文標籤（問候語、15 MIN）才另給字距。
// - 中文沒有斜體、不要假粗體；要強調用 semibold／bold。
// - 行高：內文 1.2 倍字級（英文）、中文多段時 1.3 倍；行數上限交給 Face.wrap / MediaUI.wrap。

import AppKit

enum HPType {
    /// 字級表（1024 畫布單位）。HomeView 在遠處看，字是 iPhone 的 2–3 倍；次要字不低於 28、主要字不低於 34
    /// 2.0 P05：「畫面文字大小」（設定 › 外觀；HPAccessibilitySettings）——1 預設、1.25 大、1.5 特大。
    /// 只放大「讀的字」（內文、回答、清單、膠囊列、按鈕字、說明）；遠看的大數字、圖示標籤、右上時間不變（它們已經夠大，放大會撞版面）
    static var textScale: CGFloat { HPAccessibilitySettings.scale(for: HPAccessibilitySettings.textSize) }

    enum Size {
        /// 遠看的主資訊（倒數、鬧鐘時間、溫度）：≥ 100
        static let display: CGFloat = 100
        /// 計時器全螢幕剩餘時間（官方 timer 約 150）
        static let hero: CGFloat = 150
        /// App 大標題（SF Pro bold）
        static var title: CGFloat { 56 * textScale }
        /// 回答、食譜步驟內文（影片 56–63）
        static var body: CGFloat { 56 * textScale }
        /// 列表主文字（40–44）
        static var list: CGFloat { 42 * textScale }
        /// 分區標題（SF Pro bold；可加 chevron）
        static var section: CGFloat { 38 * textScale }
        /// 文字按鈕、膠囊上的字
        static var button: CGFloat { 36 * textScale }
        /// 右上時間
        static let clock: CGFloat = 32
        /// 列表次要文字、分組上方的小標題（30–32）
        static var secondary: CGFloat { 30 * textScale }
        /// 主畫面圖示標籤（影片 30–32）
        static let iconLabel: CGFloat = 30
        /// 最小：圓鈕底下的說明、徽章
        static var caption: CGFloat { 28 * textScale }
        /// 助理回答（第三輪量自官方 siri-*：大寫高 42、字寬換算 ≈ 59 regular，重點詞 bold）
        static var answer: CGFloat { 59 * textScale }
        /// 回答裡的日期分區標題（semibold，大寫高 24.5）
        static var answerHeader: CGFloat { 35 * textScale }
        /// 膠囊列：標題 semibold 33.8、右邊「all-day」regular 29.5、第二行時間 regular 31（官方大寫高 24；字寬對官方 ±2%）
        static var rowTitle: CGFloat { 33.8 * textScale }
        static var rowTrailing: CGFloat { 29.5 * textScale }
        static var rowTime: CGFloat { 31 * textScale }
        /// 來源小晶片（「Wikipedia」「+3」）
        static var sourceChip: CGFloat { 21 * textScale }
    }

    /// 一段帶重點詞的文字：`**粗體**` 標記，拆成一行一行的（字, 粗不粗）片段。英文詞、數字不拆，漢字一個一個排
    struct Run: Equatable { var text: String; var bold: Bool }
    static func richWrap(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, boldWeight: NSFont.Weight = .bold,
                         width: CGFloat, maxLines: Int) -> [[Run]] {
        // 1. 拆字詞（空白自成一個 token，行首行尾的空白丟掉）
        var tokens: [Run] = [], word = "", bold = false
        let chars = Array(s)
        var i = 0
        func flush() { if !word.isEmpty { tokens.append(Run(text: word, bold: bold)); word = "" } }
        while i < chars.count {
            let ch = chars[i]
            if ch == "*", i + 1 < chars.count, chars[i + 1] == "*" { flush(); bold.toggle(); i += 2; continue }
            if ch.isWhitespace { flush(); tokens.append(Run(text: " ", bold: bold)) }
            else if ch.isASCII { word.append(ch) }
            else { flush(); tokens.append(Run(text: String(ch), bold: bold)) }
            i += 1
        }
        flush()
        let reg = sf(size, weight), bf = sf(size, boldWeight)
        func w(_ r: Run) -> CGFloat { Typo.width(r.text, r.bold ? bf : reg) }
        // 2. 排行
        var lines: [[Run]] = [], cur: [Run] = [], cw: CGFloat = 0
        for t in tokens {
            if t.text == " " && cur.isEmpty { continue }
            let tw = w(t)
            if cw + tw > width, !cur.isEmpty, t.text != " " {
                while cur.last?.text == " " { cur.removeLast() }
                lines.append(cur); cur = []; cw = 0
            }
            if t.text == " " && cur.isEmpty { continue }
            cur.append(t); cw += tw
        }
        while cur.last?.text == " " { cur.removeLast() }
        if !cur.isEmpty { lines.append(cur) }
        if lines.count > maxLines {
            lines = Array(lines[..<maxLines])
            if var last = lines.popLast() { last.append(Run(text: "…", bold: false)); lines.append(last) }
        }
        // 3. 同粗細的相鄰片段併成一段（畫的時候少幾次、字距照整段算）
        return lines.map { line in
            line.reduce(into: [Run]()) { acc, r in
                if let l = acc.last, l.bold == r.bold { acc[acc.count - 1].text += r.text } else { acc.append(r) }
            }
        }
    }

    /// SF Pro（比例數字）
    static func sf(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { FaceType.sf(size, weight, mono: false) }
    /// 大數字：SF Pro 等寬數字（倒數、時間跳動不晃），預設 light，照 iOS 時鐘／天氣
    static func numeric(_ size: CGFloat, _ weight: NSFont.Weight = .light) -> NSFont { FaceType.sf(size, weight) }
    /// 一行字的排版寬度（含照實際字級的字距）
    static func width(_ s: String, _ f: NSFont) -> CGFloat { Typo.width(s, f) }
    /// 放得下就用 size，放不下就縮（最小 size × minScale）
    static func fitted(_ s: String, size: CGFloat, weight: NSFont.Weight, maxWidth: CGFloat, minScale: CGFloat = 0.7) -> NSFont {
        let f = sf(size, weight)
        let w = Typo.width(s, f)
        guard w > maxWidth, w > 0 else { return f }
        return sf(max(size * minScale, (size * maxWidth / w).rounded(.down)), weight)
    }
    /// 有沒有中日韓字（決定行高、要不要避開斜體）
    static func hasCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0x3000...0x303F).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
    }
    /// 內文行高：英文 1.2、有中文 1.3
    static func lineHeight(_ size: CGFloat, for s: String) -> CGFloat { (size * (hasCJK(s) ? 1.3 : 1.2)).rounded() }
}
