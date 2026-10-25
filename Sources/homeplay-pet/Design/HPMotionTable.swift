// HPDS Motion 參數表（2.0 動效包）：外殼所有系統轉場的彈簧、延遲、錯開，全部在這一張表；呼叫端只寫 HPMotion.T.xxx，不寫死數字。
//
// 規則（scratchpad/hv-research 的 videos.md、markview.md、chan-notes.md）：
// - 時長照 Apple 官方 HomeView 影片量到的「看起來結束」；換成臨界阻尼彈簧的 response＝時長 ÷ 0.76（Spring.settling）。
// - 曲線形狀、錯開節拍照 Mark View：介面位移一律臨界阻尼、零回彈，以最大速度進場、指數尾巴收住；同批元素固定節拍錯開、同向進場；
//   容器先到、內容後到；離場用加速、比進場短。
// - damping 1.0 是預設；只有放手帶動量（> 300 px/s）才用 0.8（Designing Fluid Interfaces）。
// - 全部可打斷：MotionValue／Anim 從畫面上的當下值與速度接著走；放手把速度交給彈簧；落點用投射挑停點；邊界用 rubber band。
// - 減少動態效果：位移與縮放換成 0.2 s 交叉淡化（reduce＝.crossfade），數字直接換（.instant）。
// - 驗收：HOMEPLAY_ANIM=名字:秒＋--frames N 出 30 fps 逐格，HOMEPLAY_REVERSE=秒 在那一刻反向（打斷測試）。

import AppKit

/// 一條轉場的參數
struct HPTransition {
    enum Reduce { case crossfade, instant }
    /// MotionValue／HOMEPLAY_ANIM 的名字
    let name: String
    let spring: Spring
    /// 晚多久才開始（秒）
    var delay: Double = 0
    /// 同一批元素之間的錯開（秒）
    var stagger: Double = 0
    /// 官方影片量到「看起來結束」的秒數；nil＝影片沒拍到，照規則推斷（source 寫依據）
    var measured: Double? = nil
    let source: String
    var reduce: Reduce = .crossfade

    /// 臨界阻尼走到剩 5% 的時間（＝0.76 × response）
    var settle: Double { Double(spring.response) * 0.76 }
}

extension HPMotion {
    /// 參數表。README「Motion」的表格就是這一張（改了要一起改）
    enum T {
        // MARK: 開關 App（從圖示／小工具長出、沿原路縮回）
        /// v1 0:47.075→47.37：白卡從小工具的位置與大小放大到滿版（逐格量白卡左緣，臨界阻尼擬合 95% 落定 0.184 s、最大誤差 2.9%）
        static let appOpen = HPTransition(name: "appopen", spring: .settling(0.18), measured: 0.184,
                                          source: "v1 0:47.075→47.37 逐格（vframes/motion/appopen）")   // l10n-ignore：依據／自檢說明，不是介面文字
        /// v1 0:47.28→47.45：卡片快滿才淡入內容（卡片起算晚 0.21 s；擬合 95% 落定 0.142 s、誤差 2.3%）
        static let appContent = HPTransition(name: "appopen", spring: .settling(0.14), delay: 0.21, measured: 0.142,
                                             source: "v1 0:47.28→47.45 逐格（卡片區亮度標準差）")   // l10n-ignore：依據／自檢說明，不是介面文字
        /// 關：同一條路回去（Chan：一來一回對稱）；內容先在約 80 ms 內一起淡出（Mark View R2，不錯開）
        static let appClose = HPTransition(name: "appclose", spring: .settling(0.18), source: "與 appOpen 對稱")   // l10n-ignore：依據／自檢說明，不是介面文字
        static let appCloseContent = HPTransition(name: "appclose", spring: .settling(0.08), source: "Mark View R2：內容 80 ms 淡出")   // l10n-ignore：依據／自檢說明，不是介面文字
        /// v1 1:51.45→111.70：家庭磚放大成滿版卡 0.17–0.21 s；標題與 ✕ 晚約 0.1 s
        static let tileExpand = HPTransition(name: "home.expand", spring: Spring(damping: 1, response: 0.185), delay: 0, stagger: 0.035, measured: 0.17,
                                             source: "v1 1:51.45→1:51.70")

        // MARK: 換頁
        /// v1 0:26.775→27.067：食譜步驟頁從右緣滑入 7 格 ≈ 0.29 s，減速、無回彈
        static let pageSlide = HPTransition(name: "recipe.step", spring: Spring(damping: 1, response: 0.33), measured: 0.276,
                                            source: "v1 0:26.775→27.067（O-041）")
        /// v1 2:19.7→2:20.0：搜尋 → Now Playing 模糊交叉淡化約 290 ms（鍵盤先下滑 170 ms）
        static let blurFade = HPTransition(name: "music.page", spring: .settling(0.29), measured: 0.29, source: "v1 2:19.7→2:20.0")
        static let keyboard = HPTransition(name: "keyboard", spring: .settling(0.17), measured: 0.17, source: "v1 2:19.59→2:19.76")

        // MARK: 錶面
        /// v2 0:42.60→42.87：錶面之間跟手的分頁（每頁自己的圓角、頁縫 20）；放手照投射挑頁、把速度交給彈簧
        static let facePage = HPTransition(name: "facepage", spring: .smooth, source: "v2 0:42.60（O112）跟手；放手 .smooth（Apple 預設）")   // l10n-ignore：依據／自檢說明，不是介面文字
        /// 錶面 ↔ 主畫面：舊畫面起霧化開、新的從 1.03 收回（影片沒拍到進主畫面的過場；跟頂端藥丸同一段時間收完）
        static let homeFace = HPTransition(name: "homeface", spring: .settling(0.3), source: "推斷：跟藥丸 0.3 s 同步")   // l10n-ignore：依據／自檢說明，不是介面文字
        /// v1 1:20.975→81.27：掛斷回錶面——照片從約 45 px 模糊變清楚（逐格量清晰度換算模糊半徑；擬合 0.274 s、先停 1 格、誤差 7.8%）
        static let toFace = HPTransition(name: "toface", spring: .settling(0.27), delay: 0.04, measured: 0.274, source: "v1 1:20.975→1:21.27 逐格（vframes/motion/toface）")   // l10n-ignore：依據／自檢說明，不是介面文字
        /// 眼睛膠囊縮成主畫面頂端藥丸
        static let pill = HPTransition(name: "pill", spring: .settling(0.3), source: "跟 homeFace 同一段")   // l10n-ignore：依據／自檢說明，不是介面文字

        // MARK: 疊層
        /// 控制中心：拖曳 1:1（內容位移＝手指位移），放手照投射挑開／關；點按（C 鍵、選單）走 .smooth
        static let controlCenter = HPTransition(name: "cc", spring: .smooth, source: "影片沒有控制中心；iOS 預設 .smooth＋跟手")   // l10n-ignore：依據／自檢說明，不是介面文字
        /// 控制中心拉滿時內容走多遠（1024 畫布）：手指移動這麼多＝全開，所以內容跟手 1:1
        static let ccTravel: CGFloat = 300
        /// Sheet（換人、小工具圖庫）：從下緣升起、底下壓暗（打斷主流程的任務：玻璃＋壓暗層，Chan 7:30）
        static let sheet = HPTransition(name: "sheet", spring: .smooth, source: "iOS sheet 預設 .smooth；影片沒拍到")   // l10n-ignore：依據／自檢說明，不是介面文字
        /// v2 0:31.80→32.00：接管（Handoff、門鈴）先把舊畫面放大 5%＋模糊 20 px（0.2 s）……
        static let takeoverZoom = HPTransition(name: "takeover", spring: .settling(0.2), measured: 0.2, source: "v2 0:31.80→0:32.00（O85）")
        /// ……再交叉淡化，新畫面從模糊變清楚（v2 0:32.00→32.33 逐格量平均色，擬合 0.282 s、誤差 3.8%）；整段 ≈ 0.5 s
        static let takeoverFade = HPTransition(name: "takeover", spring: .settling(0.28), delay: 0.2, measured: 0.282, source: "v2 0:32.00→0:32.33 逐格（vframes/motion/takeover）")   // l10n-ignore：依據／自檢說明，不是介面文字

        // MARK: ClioTalk（👀 膠囊不改樣子，膠囊材質跟年代）
        /// v1 0:21.60→21.81：膠囊收成水滴、錶面模糊轉淺色 0.21 s；v2 0:15.37→15.60 液滴從上緣拉長滴下約 0.2 s
        static let clioDrip = HPTransition(name: "cliodrop", spring: .settling(0.19), measured: 0.194, source: "v1 0:21.625→21.83 逐格（轉白進度，擬合誤差 6.4%）、v2 0:15.40→15.60（O51）")   // l10n-ignore：依據／自檢說明，不是介面文字
        /// 回答逐行由模糊到清楚：每行晚 0.03 s；白幕先停（打開後 0.58 s 第一行）
        static let clioLine = HPTransition(name: "cliodrop", spring: .settling(0.12), stagger: 0.03, measured: 0.06, source: "v1 0:22.21→22.38（O-027）")
        static let clioHold = 0.58
        static let clioCardDelay = 0.1
        static let clioButtonDelay = 0.3
        /// 在想：聆聽的大珠收成回答的小珠
        static let clioThink = HPTransition(name: "clio.think", spring: .settling(0.23), measured: 0.23, source: "v1 0:21.60（0.21–0.23）")

        // MARK: Live Activity
        /// 展開／收回：臨界阻尼（點按沒有動量，不回彈）；影片沒拍到，照 Dynamic Island 的 0.3 s 級
        static let liveActivity = HPTransition(name: "la.expand", spring: .settling(0.32), source: "推斷：Chan 規則 damping 1；長度照 island 0.3 s")   // l10n-ignore：依據／自檢說明，不是介面文字

        // MARK: 數字
        /// v1 2:57.76→2:58.26：換分鐘——舊的往上模糊淡出（0.17 s）、新的從下浮入（0.3 s），十位數早 80 ms，整段 ≈ 0.5 s
        static let digitOut = HPTransition(name: "digits", spring: .settling(0.17), stagger: 0.08, measured: 0.5, source: "v1 2:57.76→2:58.26（#76）", reduce: .instant)
        static let digitIn = HPTransition(name: "digits", spring: .settling(0.3), delay: 0.05, stagger: 0.08, measured: 0.5, source: "v1 2:57.76→2:58.26（#76）", reduce: .instant)
        /// 數值計數（倒數、溫度、世界時鐘）：.numericText——只動變了的位數，高位先、錯開 33 ms，Spring(0.35, 1.0)
        static let numeric = HPTransition(name: "numeric", spring: Spring(damping: 1, response: 0.35), stagger: 0.033, measured: 0.5,
                                          source: "v2 0:43.0→44.5 恆溫器 74→73→72（O116）；Mark View R6", reduce: .instant)   // l10n-ignore：依據／自檢說明，不是介面文字
        /// 小工具資料更新：交叉淡化 0.3 s（HIG-WID-115：≤ 2 秒）
        static let widgetUpdate = HPTransition(name: "widget.update", spring: .settling(0.3), source: "HIG Widgets：資料更新用動畫提示，≤ 2 s", reduce: .instant)   // l10n-ignore：依據／自檢說明，不是介面文字

        // MARK: 玻璃
        /// 出現／消失＝materialize（折射、模糊、亮邊、形狀一起長，不是改透明度）
        static let materialize = HPTransition(name: "materialize", spring: .settling(0.25), source: "Chan T-LG 2:55；HPGlass presence")
        /// 按下：1 格內變亮放大 1.08（interactiveSpring）
        static let press = HPTransition(name: "press", spring: .interactive, measured: 0.042, source: "v2 0:38.00、v1 0:26.73")

        // MARK: 清單
        /// 插入／刪除：鄰居先讓位 Spring(0.30, 1.0)，新的一列在讓位約 70%（≈ 0.12 s）才進場；刪除的一列 80 ms 加速淡出
        static let listMove = HPTransition(name: "list", spring: Spring(damping: 1, response: 0.30), stagger: 0.035, source: "Mark View R10／R11")
        static let listInsert = HPTransition(name: "list", spring: Spring(damping: 1, response: 0.30), delay: 0.12, source: "Mark View R11：讓位 70% 才進場")   // l10n-ignore：依據／自檢說明，不是介面文字
        static let listDelete = HPTransition(name: "list", spring: .settling(0.08), source: "Mark View P3：離場加速、比進場短")   // l10n-ignore：依據／自檢說明，不是介面文字

        static let all: [HPTransition] = [appOpen, appContent, appClose, appCloseContent, tileExpand, pageSlide, blurFade, keyboard, facePage, homeFace, toFace, pill,
                                          controlCenter, sheet, takeoverZoom, takeoverFade, clioDrip, clioLine, clioThink, liveActivity, digitOut, digitIn, numeric, widgetUpdate,
                                          materialize, press, listMove, listInsert, listDelete]
    }

    /// 一般的 0…1 進度（ClioTalk、藥丸、數字）：彈簧從 0 走到 1；減少動態效果時 0.2 s 線性
    static func progress(_ tr: HPTransition, _ t: CGFloat) -> CGFloat {
        let t = t - CGFloat(tr.delay)
        guard t > 0 else { return 0 }
        if reduceMotion { return tr.reduce == .instant ? 1 : min(1, t / CGFloat(reduceFade)) }
        return max(0, min(1, tr.spring.value(from: 0, to: 1, velocity: 0, t: t).x))
    }
}

// MARK: - 出現／消失（sheet、疊層）：一個布林 → 會打斷的 0…1

/// 用法：let p = HPPresence.value("sheet.people", shown: Shell.peopleSheet, .sheet)；p > 0 就畫（收起時畫到 0 為止）
enum HPPresence {
    nonisolated(unsafe) private static var tracks: [String: MotionValue] = [:]
    static func value(_ key: String, shown: Bool, _ tr: HPTransition, now: Double = CACurrentMediaTime()) -> CGFloat {
        let goal: CGFloat = shown ? 1 : 0
        if shown, let f = HPMotion.frozen(tr.name) {   // 快照：從 0 打開到第 f 秒
            return max(0, min(1, tr.spring.value(from: 0, to: 1, velocity: 0, t: CGFloat(f)).x))
        }
        guard var m = tracks[key] else {
            // 第一次看到：開著就直接到位（開機的快照）、關著就是 0
            tracks[key] = MotionValue(tr.name, spring: tr.spring, from: goal, to: goal, now: now); return goal
        }
        if m.to != goal { m.retarget(goal, now: now); tracks[key] = m }   // 半路改主意：從當下的值與速度接著走
        if m.done(now) { return goal }
        Anim.keepAlive()
        return max(0, min(1, m.value(now)))
    }
}

// MARK: - 數字內容轉場（.contentTransition(.numericText)）

/// 只動變了的位數：舊的往外（上）模糊淡出、新的從另一邊浮進來，高位先走；倒數時方向反過來。
/// 用法：HPNumeric.draw(g, face, key:, "4:32", font:, x:, y:, color:)（x 是左緣，跟 drawLeft 一樣）
enum HPNumeric {
    private struct Roll { var text: String; var old: String; var start: Double; var down: Bool }
    nonisolated(unsafe) private static var rolls: [String: Roll] = [:]

    /// 每個字元的 (舊, 新) 配對：右對齊（數字變長時多出來的在左邊）；nil＝那一邊沒有字
    static func pairs(_ old: String, _ new: String) -> [(old: Character?, new: Character?)] {
        let o = Array(old), n = Array(new), len = max(o.count, n.count)
        return (0..<len).map { i in
            let oi = i - (len - o.count), ni = i - (len - n.count)
            return (oi >= 0 ? o[oi] : nil, ni >= 0 ? n[ni] : nil)
        }
    }
    /// 值變小＝倒數（新的從上面掉下來）
    static func countsDown(_ old: String, _ new: String) -> Bool {
        let a = Double(old.filter { $0.isNumber }) ?? 0, b = Double(new.filter { $0.isNumber }) ?? 0
        return b < a
    }
    /// 第 k 個變了的位數（從左數）晚多久起跑
    static func delay(rank k: Int) -> Double { Double(k) * HPMotion.T.numeric.stagger }

    static func draw(_ g: CGContext, _ face: Face, key: String, _ s: String, font: NSFont, x: CGFloat, y: CGFloat, color: NSColor, now: Double = CACurrentMediaTime()) {
        let tr = HPMotion.T.numeric
        var roll = rolls[key]
        if let f = HPMotion.frozen(tr.name) {   // 快照：HOMEPLAY_NUMERIC_FROM＝舊字串（沒給就最後一位 +1，當成倒數走了一格）
            let env = ProcessInfo.processInfo.environment["HOMEPLAY_NUMERIC_FROM"]
            let old = env ?? bump(s)
            roll = Roll(text: s, old: old, start: now - f, down: countsDown(old, s))
        } else if roll == nil || HPMotion.reduceMotion {
            roll = Roll(text: s, old: s, start: -1e9, down: false)
        } else if var r = roll, r.text != s {
            r.old = r.text; r.text = s; r.start = now; r.down = countsDown(r.old, s); roll = r
        }
        rolls[key] = roll
        guard let r = roll else { return }
        let t = CGFloat(HPMotion.frozen(tr.name) ?? (now - r.start))
        let ps = pairs(r.old, r.text)
        let changed = ps.indices.filter { ps[$0].old != ps[$0].new }
        if r.old == r.text || changed.isEmpty || t > CGFloat(0.9) {
            face.drawLeft(g, s, font: font, x: x, y: y, color: color); return
        }
        Anim.keepAlive()
        // 新字串的每個字元的 x（舊的照舊字串自己的寬度排，右緣對齊新的）
        func xs(_ str: String) -> [CGFloat] {
            var out: [CGFloat] = [], acc = ""
            for ch in str { out.append(Typo.width(acc, font)); acc.append(ch) }
            return out
        }
        let nx = xs(r.text), ox = xs(r.old)
        let shift = Typo.width(r.text, font) - Typo.width(r.old, font)
        let n = Array(r.text), o = Array(r.old)
        let h = font.capHeight, dir: CGFloat = r.down ? -1 : 1   // 往上走＝y 變小（畫布左上原點）
        var rank = 0
        for (i, p) in ps.enumerated() {
            let ni = i - (ps.count - n.count), oi = i - (ps.count - o.count)
            if p.old == p.new, let c = p.new {
                face.drawLeft(g, String(c), font: font, x: x + nx[ni], y: y, color: color); continue
            }
            let lt = t - CGFloat(delay(rank: rank)); rank += 1
            let k = lt <= 0 ? 0 : max(0, min(1, tr.spring.value(from: 0, to: 1, velocity: 0, t: lt).x))
            // 舊的：往外移半個字高、淡出（前段就幾乎看不見，像 SwiftUI 的 numericText）
            if let c = p.old, k < 0.999 {
                blurredGlyph(g, face, String(c), font: font, x: x + shift + ox[oi], y: y - dir * h * 0.6 * k, color: color, alpha: pow(1 - k, 2), smear: k * (1 - k) * 4)
            }
            // 新的：從另一邊半個字高浮進來
            if let c = p.new, k > 0.001 {
                blurredGlyph(g, face, String(c), font: font, x: x + nx[ni], y: y + dir * h * 0.6 * (1 - k), color: color, alpha: k, smear: k * (1 - k) * 4)
            }
        }
    }
    /// 移動中的字：沿移動方向抹開一點（三張錯開的疊影，比每幀做高斯模糊便宜），停下來就是清楚的一張
    private static func blurredGlyph(_ g: CGContext, _ face: Face, _ s: String, font: NSFont, x: CGFloat, y: CGFloat, color: NSColor, alpha: CGFloat, smear: CGFloat) {
        guard alpha > 0.003 else { return }
        let spread = smear * font.pointSize * 0.06
        if spread < 0.3 { face.drawLeft(g, s, font: font, x: x, y: y, color: color.withAlphaComponent(color.alphaComponent * alpha)); return }
        for dy in [-spread, 0, spread] {
            face.drawLeft(g, s, font: font, x: x, y: y + dy, color: color.withAlphaComponent(color.alphaComponent * alpha * (dy == 0 ? 0.5 : 0.25)))
        }
    }
    /// 快照用：最後一個數字 +1（9 → 0 進位到前一位）
    static func bump(_ s: String) -> String {
        var c = Array(s), i = c.count - 1
        while i >= 0 {
            if let d = c[i].wholeNumberValue {
                if d < 9 { c[i] = Character(String(d + 1)); return String(c) }
                c[i] = "0"
            }
            i -= 1
        }
        return "1" + String(c)
    }
}

// MARK: - 清單的插入與刪除（鄰居先讓位、新的晚一點進場、刪掉的加速淡出）

/// 用法：每幀把這一幀的列（id、目標 y）交給 layout，拿回每列現在該畫在哪、透明度多少；刪掉的列也會回來一陣子（removing）
struct HPListMotion {
    struct Row: Equatable { let id: String; var y: CGFloat; var alpha: CGFloat; var removing: Bool }
    private var ys: [String: MotionValue] = [:]
    private var appear: [String: MotionValue] = [:]
    private var gone: [String: (y: CGFloat, fade: MotionValue)] = [:]
    private var seen = false

    mutating func layout(_ rows: [(id: String, y: CGFloat)], now: Double) -> [Row] {
        let T = HPMotion.T.self
        let ids = Set(rows.map(\.id))
        // 不見了的：留在原地、80 ms 加速淡出
        for (id, m) in ys where !ids.contains(id) {
            gone[id] = (m.value(now), MotionValue("list.delete", spring: T.listDelete.spring, from: 1, to: 0, now: now))
            ys[id] = nil; appear[id] = nil
        }
        var out: [Row] = []
        for r in rows {
            gone[r.id] = nil
            if var m = ys[r.id] {
                if m.to != r.y { m.retarget(r.y, now: now); ys[r.id] = m }   // 讓位：從當下的位置與速度接著走
            } else {
                ys[r.id] = MotionValue("list", spring: T.listMove.spring, from: r.y, to: r.y, now: now)
                // 第一次 layout 的列直接在；之後才出現的列＝插入：晚 0.12 s 淡入（從上一列的位置略往下 12 長出來）
                appear[r.id] = MotionValue("list.insert", spring: T.listInsert.spring, from: seen ? 0 : 1, to: 1, now: now, delay: seen ? T.listInsert.delay : 0)
            }
            let a = appear[r.id].map { max(0, min(1, $0.value(now))) } ?? 1
            let y = (ys[r.id]?.value(now) ?? r.y) + (1 - a) * 12
            out.append(Row(id: r.id, y: y, alpha: a, removing: false))
        }
        for (id, gr) in gone {
            let a = max(0, min(1, gr.fade.value(now)))
            if gr.fade.done(now) || a < 0.002 { gone[id] = nil; continue }
            out.append(Row(id: id, y: gr.y, alpha: a, removing: true))
        }
        seen = true
        return out
    }
    func animating(_ now: Double) -> Bool {
        !gone.isEmpty || ys.values.contains { !$0.done(now) } || appear.values.contains { !$0.done(now) }
    }
}

// MARK: - ClioTalk 滴落：膠囊與水滴的 smooth union（距離近時長出一段頸子，像液體拉斷）

enum HPDrip {
    /// 兩個圓角形狀之間的頸子：a 在上（膠囊）、b 在下（水滴）。gap 小於 merge 時，用兩條內凹的曲線連起來；
    /// 越遠頸子越細，超過 merge 就斷開（回 nil）。union 名字照 HPGlass 的慣例：同名的形狀融成一塊。
    static let unionName = "clio.drip"
    static func neck(top a: CGRect, bottom b: CGRect, merge: CGFloat) -> CGPath? {
        let gap = b.minY - a.maxY
        guard merge > 0, gap < merge else { return nil }
        // 頸子寬：兩邊較窄的那個 × (1 − gap/merge)；最細 0（拉斷）
        let k = max(0, min(1, 1 - max(0, gap) / merge))
        let w = min(a.width, b.width) * 0.42 * k
        guard w > 0.5 else { return nil }
        let cx = (b.midX + a.midX) / 2
        let y0 = a.maxY - min(a.height, 20) * 0.5, y1 = b.minY + min(b.height, 20) * 0.5
        let mid = (y0 + y1) / 2, pinch = w * (0.5 - 0.35 * (1 - k))   // 中間收腰
        let p = CGMutablePath()
        p.move(to: CGPoint(x: a.midX - w, y: y0))
        p.addCurve(to: CGPoint(x: b.midX - w, y: y1), control1: CGPoint(x: cx - pinch, y: mid), control2: CGPoint(x: cx - pinch, y: mid))
        p.addLine(to: CGPoint(x: b.midX + w, y: y1))
        p.addCurve(to: CGPoint(x: a.midX + w, y: y0), control1: CGPoint(x: cx + pinch, y: mid), control2: CGPoint(x: cx + pinch, y: mid))
        p.closeSubpath()
        return p
    }
    /// 滴落時的融合距離（1024 畫布；比靜態群組的 HPGlass.unionMerge 大，頸子才看得到）
    static let merge: CGFloat = 40
    /// 留在原處的那一截膠囊：水滴走到 60% 前縮完（不留第二顆）
    static func residual(_ cap: CGRect, w: CGFloat) -> CGRect {
        let k = max(0, 1 - w * 1.65)
        guard k > 0.01 else { return .zero }
        let h = cap.height * (0.55 + 0.45 * k), wd = max(h, cap.width * k)
        return CGRect(x: cap.midX - wd / 2, y: cap.midY - h / 2, width: wd, height: h)
    }
    /// 膠囊那一截 ∪ 水滴 ∪ 頸子（照上下順序接）；兩個都沒有面積就回 nil
    static func union(_ a: CGRect, _ b: CGRect, merge: CGFloat) -> CGPath? {
        guard a.width > 0.5, b.width > 0.5 else { return nil }
        func capsule(_ r: CGRect) -> CGPath { CGPath(roundedRect: r, cornerWidth: min(r.width, r.height) / 2, cornerHeight: min(r.width, r.height) / 2, transform: nil) }
        var u = capsule(a).union(capsule(b))
        let (top, bottom) = a.midY <= b.midY ? (a, b) : (b, a)
        if let n = neck(top: top, bottom: bottom, merge: merge) { u = u.union(n) }
        return u
    }
    /// 水滴在飛的時候沿運動方向拉長（高寬比最多 1.15，速度歸零就是正圓）；v＝進度的速度（每秒）
    static func stretch(_ r: CGRect, velocity v: CGFloat) -> CGRect {
        if HPMotion.reduceMotion { return r }
        let s = min(0.15, abs(v) * 0.012)
        let h = r.height * (1 + s), w = r.width
        return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }
}

// MARK: - 錶面跟手分頁（1:1、邊界 rubber band、放手投射＋速度交接）

/// 純邏輯：offset 以「頁」為單位（−1…1：往左一頁…往右一頁）。drag 給手指位移（頁寬為 1），release 回要停的頁與交給彈簧的初速。
struct FacePager {
    var canPrev = true, canNext = true
    private(set) var offset: CGFloat = 0
    /// 手指移動 dx（頁寬為 1，正＝往右拖＝看前一頁）；沒有下一頁的方向用 rubber band
    mutating func drag(_ dx: CGFloat) {
        let blocked = (dx > 0 && !canPrev) || (dx < 0 && !canNext)
        offset = blocked ? HPMotion.rubberBand(dx, 1) : max(-1, min(1, dx))
    }
    /// 放手：v＝每秒幾頁。回目標（−1、0、1）與交接的速度（進度單位）
    func release(velocity v: CGFloat) -> (target: CGFloat, velocity: CGFloat, spring: Spring) {
        var stops: [CGFloat] = [0]
        if canPrev { stops.append(1) }
        if canNext { stops.append(-1) }
        let goal = HPMotion.nearest(offset, velocity: v, stops: stops)
        return (goal, v, HPMotion.release(velocity: v * 1024))
    }
}

// MARK: - 自檢

enum MotionTableSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        let T = HPMotion.T.self
        // 規則：介面轉場一律臨界阻尼（有動量的放手才在 HPMotion.release 裡用 0.8）；全部 ≤ 2 s（HIG）；名字都有
        check(T.all.allSatisfy { abs($0.spring.damping - 1) < 1e-9 || $0.name == "press" }, "動效表：除了按下，全部臨界阻尼、無回彈")
        check(T.all.allSatisfy { $0.settle + $0.delay < 2 && !$0.name.isEmpty && !$0.source.isEmpty }, "動效表：每條 ≤ 2 s、有名字與依據")
        // 有量到的：落定時間對上影片（1 格＝1/24 s 以內，ClioTalk 每行、按下這種極短的不算）
        for tr in T.all { if let m = tr.measured, m > 0.1, tr.stagger == 0 || tr.name == "digits" {
            let fit = tr.name == "digits" ? (tr.delay + tr.settle + 0.08 <= m + 1.0 / 24) : abs(tr.settle - m) <= 1.0 / 24 + 0.02
            check(fit, "動效表：\(tr.name) 落定 \(String(format: "%.3f", tr.settle)) s 對上影片 \(m) s")
        } }
        // 開 App：放大＋內容淡入合起來對上 v1 0:47.08→47.42（≈ 0.3 s，從放開起算）
        check(abs(T.appContent.delay + T.appContent.settle - 0.36) < 0.03, "動效表：開 App 從卡片開始動到內容滿約 0.36 s（v1 0:47.075→47.45）")
        check(abs(T.takeoverFade.delay + T.takeoverFade.settle - 0.5) < 0.03, "動效表：接管整段約 0.5 s（v2 0:31.80→32.30）")
        // 反向（打斷）：HOMEPLAY_REVERSE 的算法＝真的 retarget
        var m = MotionValue("t", spring: T.appOpen.spring, from: 0, to: 1, now: 0)
        let at = 0.05
        var real = m; real.retarget(0, now: at)
        let mid = m.sample(at)
        m.retarget(0, now: at)
        check(abs(m.value(at + 0.03) - real.value(at + 0.03)) < 1e-9 && abs(m.value(at) - mid.x) < 1e-9, "打斷：反向從當下值接著走、不跳")
        // 反向之後速度連續（前後各 1 ms 的斜率差很小）
        let before = (mid.x - MotionValue("t", spring: T.appOpen.spring, from: 0, to: 1, now: 0).sample(at - 1e-4).x) / 1e-4
        let after = (real.value(at + 1e-4) - real.value(at)) / 1e-4
        check(abs(before - after) < 0.05 * max(1, abs(before)), "打斷：反向時速度連續（交接給新彈簧）")
        // 數字：右對齊配對、倒數判斷、只動變了的位數、高位先
        let ps = HPNumeric.pairs("9:59", "10:00")
        check(ps.count == 5 && ps[0].old == nil && ps[0].new == "1" && ps[4].old == "9" && ps[4].new == "0", "數字轉場：右對齊配對（變長時多的在左邊）")
        check(HPNumeric.countsDown("4:32", "4:31") && !HPNumeric.countsDown("72", "73"), "數字轉場：值變小＝倒數方向")
        check(HPNumeric.pairs("4:32", "4:31").filter { $0.old != $0.new }.count == 1, "數字轉場：只動變了的位數")
        check(HPNumeric.delay(rank: 1) > HPNumeric.delay(rank: 0) && HPNumeric.delay(rank: 4) <= 0.15, "數字轉場：高位先走、整串錯開 ≤ 150 ms")
        check(HPNumeric.bump("4:39") == "4:40" && HPNumeric.bump("9") == "10", "數字轉場：快照用的上一格")
        // 清單：插入的列晚進場、鄰居讓位從當下接著走、刪掉的淡出後消失
        var list = HPListMotion()
        _ = list.layout([("a", 0), ("b", 100)], now: 0)
        let ins = list.layout([("a", 0), ("n", 100), ("b", 200)], now: 1)
        let n0 = ins.first { $0.id == "n" }, b0 = ins.first { $0.id == "b" }
        check(n0?.alpha == 0 && b0.map { abs($0.y - 100) < 1e-6 } == true, "清單：插入的列先不出現、鄰居從原位開始讓位")
        let later = list.layout([("a", 0), ("n", 100), ("b", 200)], now: 1.6)
        check(later.allSatisfy { $0.alpha > 0.99 } && later.first { $0.id == "b" }.map { abs($0.y - 200) < 0.5 } == true, "清單：讓位完、新列淡入完成")
        _ = list.layout([("a", 0), ("b", 200)], now: 2)
        let del = list.layout([("a", 0), ("b", 200)], now: 2.03)
        check(del.contains { $0.id == "n" && $0.removing && $0.alpha < 1 }, "清單：刪掉的列留在原地淡出")
        _ = list.layout([("a", 0), ("b", 200)], now: 2.5)
        check(!list.layout([("a", 0), ("b", 200)], now: 2.6).contains { $0.id == "n" }, "清單：淡完就拿掉")
        // 滴落：靠近時有頸子、拉開就斷；在飛時拉長、停下正圓
        let cap = CGRect(x: 400, y: 40, width: 224, height: 70)
        check(HPDrip.neck(top: cap, bottom: CGRect(x: 460, y: 116, width: 103, height: 103), merge: 14) != nil
              && HPDrip.neck(top: cap, bottom: CGRect(x: 460, y: 140, width: 103, height: 103), merge: 14) == nil, "滴落：距離內長出頸子、拉開就斷")   // l10n-ignore：依據／自檢說明，不是介面文字
        let st = HPDrip.stretch(CGRect(x: 0, y: 0, width: 100, height: 100), velocity: 20)
        check(st.height / st.width <= 1.15 + 1e-6 && st.height > st.width && HPDrip.stretch(CGRect(x: 0, y: 0, width: 100, height: 100), velocity: 0).width == 100,
              "滴落：飛的時候拉長（≤ 1.15）、停下來正圓")   // l10n-ignore：依據／自檢說明，不是介面文字
        // 錶面分頁：1:1、頭尾 rubber band、放手照投射
        var pg = FacePager(); pg.canNext = false
        pg.drag(0.3); check(abs(pg.offset - 0.3) < 1e-9, "分頁：手指拖多少頁面就走多少（1:1）")
        pg.drag(-0.3); check(pg.offset > -0.3 && pg.offset < 0, "分頁：沒有下一頁時 rubber band")
        pg = FacePager(); pg.drag(-0.2)
        check(pg.release(velocity: -2).target == -1 && pg.release(velocity: 0.1).target == 0, "分頁：甩得快就換頁、慢放就回原位（投射）")
        check(pg.release(velocity: -2).spring.damping < 1 && pg.release(velocity: 0).spring.damping == 1, "分頁：有動量才允許一點過衝")
        // 出現／消失：半路改主意從當下接著走
        _ = HPPresence.value("selftest", shown: false, T.sheet, now: 0)
        _ = HPPresence.value("selftest", shown: true, T.sheet, now: 1)
        let half = HPPresence.value("selftest", shown: true, T.sheet, now: 1.1)
        let back = HPPresence.value("selftest", shown: false, T.sheet, now: 1.1)
        check(half > 0.05 && half < 0.95 && abs(back - half) < 1e-6, "sheet：收到一半反悔，從當下的位置回去")
    }
}
