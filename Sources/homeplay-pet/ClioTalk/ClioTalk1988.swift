// 2.0 第五輪：1988 年代（System 6 系列錶面、1988 的島）叫出 ClioTalk 時，用 System 6 的 1-bit 語彙畫同一份回答。
// 跟 AI System 6 的 1988 外觀同一套說法：50% 網點桌面、選單列（左上 1-bit 👀）、條紋標題列的「ClioTalk」視窗、
// 1 點框、硬邊陰影、預設按鈕的粗外圈、Chicago 標題與 Geneva 內文。
// 暫時與留下：回答是一張虛線框的紙條（暫時）；說「留下」後變成實線框＋2 點硬影（AI System 6 的 kept slip）。
// 交給 App 的物件：草稿是虛線框，做完是實線框＋硬影，左邊是那個 App 的 1-bit 圖示。
// 👀 不改樣子：膠囊在這個年代本來就是預設按鈕＋1-bit 眼睛（drawPixelButton），這裡只呼叫它。
// 第六輪（使用者決定 #7）：選單列「File Edit Talk」真的能點——點標題拉開 System 6 的下拉選單（標題反白、1 點框＋右下 1 點硬影），
// 再點項目：File › 關閉、Edit › 拷貝回答、Talk › 留下／想深一點／重新問（跟 AI System 6 同一套選單語彙）；用不了的項目是 50% 網點的灰字。
// 外框畫在 256 點的格子（×4，跟 System 6 錶面一樣粗）；字排在 512 點的座標、畫在 1024 的格子（中文才認得出來），都門檻化成純黑白。

import AppKit

nonisolated(unsafe) private var clio1988Cache: (key: String, chrome: CGImage, text: CGImage, buttons: [(ClioTalkPanel.Chip, CGRect)], bead: CGRect, menu: CGImage?)?

enum Clio1988Art {
    static let timer = ["   XXX   ", "    X    ", "  XXXXX  ", " X  X  X ", "X   X   X", "X   XX  X", "X       X", " X     X ", "  XXXXX  "]
    static let reminder = ["XXX      ", "X.X XXXXX", "XXX      ", "         ", "XXX      ", "XXX XXXXX", "XXX      ", "         ", "XXX      "]
    static let house = ["    X    ", "   XXX   ", "  XX.XX  ", " XX...XX ", "XX.....XX", " X.....X ", " X.XX..X ", " X.XX..X ", " XXXXXXX "]
    static let balloon = [" XXXXXXX ", "X.......X", "X.......X", "X.......X", " XXXXXXX ", "  XX     ", "  X      ", "         ", "         "]
    static let handset = ["XX       ", "XXX      ", " XX      ", " XX      ", "  XX     ", "   XX  XX", "    XXXXX", "     XXX ", "         "]
    static let caution = ["     X     ", "    X.X    ", "    X.X    ", "   X.X.X   ", "   X.X.X   ", "  X..X..X  ", "  X.....X  ",
                          " X...X...X ", " X.......X ", "XXXXXXXXXXX"]
    static let watch = ["  XXXXXXX  ", "  XXXXXXX  ", " XXXXXXXXX ", "X.........X", "X....X....X", "X....X....X", "X....XXX..X",
                        "X.........X", " XXXXXXXXX ", "  XXXXXXX  ", "  XXXXXXX  "]
    static let check = ["      X", "     XX", "X   XX ", "XX XX  ", " XXX   ", "  X    "]

    static func icon(_ k: ClioHandoff.Kind) -> [String] {
        switch k {
        case .timer: return timer
        case .reminder: return reminder
        case .event: return Sys6Art.iconCalendar
        case .scene: return house
        case .message: return balloon
        case .call: return handset
        }
    }

    /// 1 點虛線框（白底）：暫時的東西
    static func dotted(_ b: Bit1, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        b.fill(x, y, w, h, false)
        for i in stride(from: 0, to: w, by: 2) { b.fill(x + i, y, 1, 1); b.fill(x + i, y + h - 1, 1, 1) }
        for j in stride(from: 0, to: h, by: 2) { b.fill(x, y + j, 1, 1); b.fill(x + w - 1, y + j, 1, 1) }
    }
    /// 1 點實線框＋右下 2 點硬影：留下來、交出去的東西
    static func kept(_ b: Bit1, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        b.fill(x + 2, y + 2, w, h)
        b.box(x, y, w, h)
    }
    /// System 6 的按鈕：圓角 1 點框；預設按鈕外面隔 1 點白再一圈 3 點粗框
    static func button(_ b: Bit1, _ x: Int, _ y: Int, _ w: Int, _ h: Int, isDefault: Bool) {
        let r = 7
        if isDefault {
            b.roundRect(x - 4, y - 4, w + 8, h + 8, r + 4, true)
            b.roundRect(x - 1, y - 1, w + 2, h + 2, r + 1, false)
        }
        b.roundRect(x, y, w, h, r, true)
        b.roundRect(x + 1, y + 1, w - 2, h - 2, r - 1, false)
    }
}

// MARK: - 選單列（第六輪 #7）

enum Clio1988Menu {
    enum Item: Equatable { case close, copyAnswer, keep, deeper, askAgain }
    static let titles = ["File", "Edit", "Talk"]   // l10n-ignore：System 6 的選單列照原樣（錶面上的選單列也是英文）
    static func items(_ menu: Int) -> [Item] {
        switch menu {
        case 0: return [.close]
        case 1: return [.copyAnswer]
        default: return [.keep, .deeper, .askAgain]
        }
    }
    static func title(_ i: Item) -> String {
        switch i {
        case .close: return L("clio.menu.close", "关闭")
        case .copyAnswer: return L("clio.menu.copyAnswer", "拷贝回答")
        case .keep: return L("clio.chip.keep", "留下")
        case .deeper: return L("clio.chip.deeper", "想深一点")
        case .askAgain: return L("clio.menu.askAgain", "重新问")
        }
    }
    /// 用得了嗎（純邏輯）：留下／拷貝要有回答；想深一點跟 2026 的膠囊一樣，只在快模型、雲端模型時；重新問要有問題、不在等「好」
    static func enabled(_ i: Item, _ s: ClioSnapshot, provider: ClioProviderID) -> Bool {
        let answered = s.phase == .idle && !s.answer.isEmpty
        switch i {
        case .close: return true
        case .copyAnswer: return !s.answer.isEmpty
        case .keep: return answered && !s.kept
        case .deeper: return answered && s.tier == .fast && provider.needsKey
        case .askAgain: return !s.question.isEmpty && s.phase != .confirm && s.phase != .thinking && s.phase != .streaming
        }
    }

    /// 拉開的是哪一個（nil＝都收著）；快照：--clio-menu file|edit|talk
    nonisolated(unsafe) static var open: Int? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--clio-menu"), i + 1 < a.count else { return nil }
        return ["file", "edit", "talk"].firstIndex(of: a[i + 1].lowercased())
    }()
    /// 按著的那一項（反白）
    nonisolated(unsafe) static var pressed: Item?
    nonisolated(unsafe) static var pressedTitle: Int?
    /// 這一幀畫的是不是 1988 的視窗（是才接點擊）
    nonisolated(unsafe) static var live = false
    /// 最近一次畫出來的位置（1024 座標）
    nonisolated(unsafe) static var titleRects: [CGRect] = []
    nonisolated(unsafe) static var itemRects: [(Item, CGRect, Bool)] = []

    /// 按下：在選單列或拉開的選單上就歸選單（回 true）
    static func press(x: CGFloat, y: CGFloat) -> Bool {
        guard live else { return false }
        let p = CGPoint(x: x, y: y)
        if let t = titleRects.firstIndex(where: { $0.contains(p) }) { pressedTitle = t; pressed = nil; return true }
        guard open != nil else { return false }
        pressedTitle = nil
        pressed = itemRects.first { $0.1.contains(p) && $0.2 }?.0
        return true            // 選單開著：點哪裡都先歸選單（點外面＝收起）
    }
    /// 放開：點標題＝拉開／收起；點項目＝做那件事並收起；點外面＝收起
    static func release(x: CGFloat?, y: CGFloat?) -> Item? {
        defer { pressed = nil; pressedTitle = nil }
        guard let x, let y else { return nil }
        let p = CGPoint(x: x, y: y)
        if let t = pressedTitle {
            if titleRects.firstIndex(where: { $0.contains(p) }) == t { open = open == t ? nil : t }
            return nil
        }
        let hit = itemRects.first { $0.1.contains(p) && $0.2 }?.0
        open = nil
        return hit != nil && hit == pressed ? hit : nil
    }
}

extension ClioTalkController {
    /// 1988 選單的項目
    func menu(_ i: Clio1988Menu.Item) {
        guard ClioTalkPanel.demo == nil else { return }
        switch i {
        case .close: close()
        case .copyAnswer:
            let a = snapshot.answer
            guard !a.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(a, forType: .string)
        case .keep: tap(.keep)
        case .deeper: tap(.deeper)
        case .askAgain: tap(.retry)
        }
    }
}

/// 一段帶 **粗體** 的字：拆成可以折行的小塊（英文詞、數字不拆，漢字一個一個）
private struct Run1988 { var text: String; var bold: Bool }

private func tokens1988(_ s: String) -> [Run1988] {
    var out: [Run1988] = [], bold = false, word = ""
    let parts = s.components(separatedBy: "**")
    for (i, part) in parts.enumerated() {
        bold = i % 2 == 1
        for ch in part {
            if ch.isASCII && !ch.isWhitespace { word.append(ch); continue }
            if !word.isEmpty { out.append(Run1988(text: word, bold: bold)); word = "" }
            out.append(Run1988(text: String(ch), bold: bold))
        }
        if !word.isEmpty { out.append(Run1988(text: word, bold: bold)); word = "" }
    }
    return out
}

extension Face {
    /// 1988：同一份回答，System 6 的視窗。跟 2026 一樣把按鈕框存進 ClioTalkPanel.buttons（點珠＝用說的問）
    func drawClioTalk1988(_ g: CGContext, _ now: Double, _ snap: ClioSnapshot, t: CGFloat) {
        let P = ClioTalkPanel.self
        Clio1988Menu.live = true
        // 在聽：視窗裡就是聽到的字（同一份 System 6 視窗，不另畫水滴）
        let v = P.voiceView(snap, now)
        var s = snap
        var heard: String?
        if v.screen == .listening {
            heard = v.final + v.volatile
            s = ClioSnapshot(); s.model = ""
        }
        let a = P.alpha
        let busy = s.phase == .thinking || s.phase == .streaming
        let wx = 12, wy = 60, ww = 232, wh = 186                // 視窗（256 點）
        let bead = (x: 98, y: 26, w: 60, h: 22)                 // 👀 預設按鈕（不含外圈）
        g.saveGState(); defer { g.restoreGState() }
        if !P.entering { g.setAlpha(a) }

        // 開窗：System 6 的「zoom rects」——從眼睛膠囊往視窗拉出幾圈框，0.24 s 後視窗出現
        let open = HPMotion.frozen("cliodrop").map { CGFloat($0) } ?? t
        if open < 0.24 && P.demo == nil {
            let b = Bit1(256, 256)
            b.desktop(); b.menubar(["File", "Edit", "Talk"])
            let from = (islandRect ?? CGRect(x: 412, y: 40, width: 200, height: 80)).applying(CGAffineTransform(scaleX: 0.25, y: 0.25))
            let to = CGRect(x: wx, y: wy, width: ww, height: wh)
            for k in 0..<4 {
                let p = max(0, min(1, open / 0.24 - CGFloat(k) * 0.12))
                guard p > 0 else { continue }
                let r = Shell.lerp(from, to, p)
                b.box(Int(r.minX), Int(r.minY), max(2, Int(r.width)), max(2, Int(r.height)), fill: false)
            }
            g.setFillColor(NSColor.black.cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
            blit1(g, b.finish(), x: 0, y: 0, pixel: 4)
            drawPixelButton(g, x: bead.x, y: bead.y, w: bead.w, h: bead.h, pixel: 4, now: now)
            P.buttons = []
            return
        }

        let hint: String? = s.phase == .idle && !s.answer.isEmpty && !s.kept
            ? (P.demo != nil ? (P.demo == "answer" ? ClioAnswerCommand.hintText : nil) : (ClioAnswerCommand.hint(for: s.answer) ? ClioAnswerCommand.hintText : nil)) : nil
        let tick = busy ? Int(now * 2) % 2 : 0
        let key = "\(s.phase)|\(s.question)|\(s.answer)|\(s.confirm ?? "")|\(s.error ?? "")|\(s.previous ?? "")|\(s.kept)|\(String(describing: s.handoff))|\(s.sources)|\(s.source ?? "")|\(s.model)|\(s.note ?? "")|\(hint ?? "")|\(tick)|\(L10n.language.rawValue)|\(heard ?? "-")|\(v.listenHint)|m\(Clio1988Menu.open ?? -1)|\(String(describing: Clio1988Menu.pressed))|\(Clio1988Menu.pressedTitle ?? -1)|\(s.tier)|\(ClioSettings.provider.rawValue)"
        if clio1988Cache?.key != key {
            clio1988Cache = render1988(s, key: key, hint: hint, heard: heard, tick: tick, win: (wx, wy, ww, wh), bead: bead)
        }
        guard let c = clio1988Cache else { return }
        g.setFillColor(NSColor.black.cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        blit1(g, c.chrome, x: 0, y: 0, pixel: 4)
        blit1(g, c.text, x: 0, y: 0, pixel: 1)
        drawPixelButton(g, x: bead.x, y: bead.y, w: bead.w, h: bead.h, pixel: 4, now: now)
        if let m = c.menu { blit1(g, m, x: 0, y: 0, pixel: 1) }   // 第六輪：拉開的選單蓋在 👀 預設按鈕上面（System 6 的選單永遠在最上層）
        let beadRect = c.bead
        islandRectBuilding = islandRectBuilding.map { $0.union(beadRect) } ?? beadRect
        P.buttons = heard != nil ? [(.listen, CGRect(x: 0, y: 0, width: 1024, height: 1024))] : [(.listen, beadRect)] + c.buttons
    }

    private func render1988(_ s: ClioSnapshot, key: String, hint: String?, heard: String?, tick: Int,
                            win: (x: Int, y: Int, w: Int, h: Int), bead: (x: Int, y: Int, w: Int, h: Int))
        -> (key: String, chrome: CGImage, text: CGImage, buttons: [(ClioTalkPanel.Chip, CGRect)], bead: CGRect, menu: CGImage?) {
        let b = Bit1(256, 256)        // 外框（×4）
        let t = Bit1(1024, 1024)      // 字：排版用 512 點的座標，實際用 1024 的格子畫（中文筆畫才清楚），一樣門檻化成純黑白
        t.ctx.scaleBy(x: 2, y: 2)
        b.desktop(); b.menubar(["File", "Edit", "Talk"])
        b.window(win.x, win.y, win.w, win.h, title: "ClioTalk")
        let busy = s.phase == .thinking || s.phase == .streaming
        let body = Sys6Art.geneva(20), bold = Sys6Art.chicago(20), small = Sys6Art.geneva(15), label = Sys6Art.chicago(15)
        let lh = 27                                             // 內文行距（512 點）
        let left = (win.x + 8) * 2, right = (win.x + win.w - 8) * 2, width = right - left
        var y = (win.y + 19 + 8) * 2                            // 往下排到哪（512 點，基線以上的頂）
        let bottom = (win.y + win.h - 4) * 2

        /// 折行：英文詞不拆、漢字逐字；放不下的最後一行截「…」
        func wrap(_ s: String, maxLines: Int, w: Int = width, font: NSFont? = nil) -> [[Run1988]] {
            var lines: [[Run1988]] = [], cur: [Run1988] = [], cw = 0
            for tk in tokens1988(s) {
                let f = font ?? (tk.bold ? bold : body), tw = t.width(tk.text, f)
                if tk.text == "\n" { lines.append(cur); cur = []; cw = 0; continue }
                let closing = "，。、；：！？」』）》”’,.;:!?)".contains(tk.text)   // l10n-ignore：行首禁則的標點
                if cw + tw > w, !cur.isEmpty, !closing {
                    while cur.last?.text == " " { cur.removeLast() }
                    lines.append(cur); cur = []; cw = 0
                    if tk.text == " " { continue }
                }
                cur.append(tk); cw += tw
            }
            if !cur.isEmpty { lines.append(cur) }
            if lines.count > maxLines {
                lines = Array(lines[..<maxLines])
                var last = lines[maxLines - 1]
                while !last.isEmpty, last.reduce(0, { $0 + t.width($1.text, $1.bold ? bold : body) }) + t.width("…", body) > w { last.removeLast() }
                lines[maxLines - 1] = last + [Run1988(text: "…", bold: false)]
            }
            return lines
        }
        func drawRuns(_ runs: [Run1988], x: Int, base: Int) {
            var cx = x
            for r in runs { cx += t.text(r.text, cx, base, r.bold ? bold : body) }
        }
        func clipped(_ s: String, _ f: NSFont, _ w: Int) -> String {
            guard t.width(s, f) > w else { return s }
            var c = s
            while !c.isEmpty, t.width(c + "…", f) > w { c.removeLast() }
            return c + "…"
        }

        // 上一輪縮成一行
        if let prev = s.previous, !prev.isEmpty {
            y += 16
            t.text(clipped(prev + " ▸", small, width), left, y, small)
            y += 10
        }
        // 你說的話（還沒有回答、或出錯時）：右邊一個框
        if !s.question.isEmpty, s.answer.isEmpty || s.phase == .error {
            let q = clipped(s.question, body, width - 40)
            let qw = t.width(q, body) + 24
            let bx = (right - qw) / 2, by = y / 2 + 2
            b.box(bx, by, qw / 2 + 1, 18)
            t.text(q, bx * 2 + 12, by * 2 + 25, body)
            y = (by + 18) * 2 + 10
        }

        // 內文：出錯＝警示框；確認＝問句；回答＝第一行結論＋資料列
        var headline = "", details: [String] = []
        switch s.phase {
        case .error: headline = s.error ?? ""
        case .thinking where s.answer.isEmpty: headline = ""
        case .idle where heard != nil: headline = heard!.isEmpty ? L("clio.voice.listening", "在听…") : heard!
        case .idle where s.answer.isEmpty: headline = L("clio.empty", "想知道什么，或要做什么？")
        default:
            let src = s.phase == .confirm ? s.confirm ?? "" : s.answer
            let lines = src.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            headline = lines.first ?? ""
            details = Array(lines.dropFirst())
        }
        if s.phase == .confirm, let h = s.handoff {
            details = []   // 物件卡就是那份草稿
            if h.kind == .message { headline = L("clio.confirm.message", "要传这则信息吗？") }
        }
        if s.phase == .error {
            b.bitmap(Clio1988Art.caution, left / 2, y / 2 + 2, 2)
            let lines = wrap(headline, maxLines: 5, w: width - 60)
            var base = y + 24
            for l in lines { drawRuns(l, x: left + 60, base: base); base += lh }
            y = max(y + 56, base)
        } else if !headline.isEmpty {
            let lines = wrap(headline, maxLines: details.isEmpty && s.handoff == nil ? 8 : 3)
            let slip = s.phase == .idle && !s.answer.isEmpty   // 回答紙條：暫時＝虛線，留下＝實線＋硬影
            let top = y
            var base = y + (slip ? 30 : 22)
            for l in lines { drawRuns(l, x: left + (slip ? 12 : 0), base: base); base += lh }
            if slip {
                let sy = top / 2, sh = (base - lh + 14 - top) / 2
                if s.kept { Clio1988Art.kept(b, left / 2 - 2, sy, width / 2 + 2, sh) } else { Clio1988Art.dotted(b, left / 2 - 2, sy, width / 2 + 2, sh) }
                y = (sy + sh) * 2 + 12
            } else {
                y = base - lh + 16
            }
        }
        // 資料列：標籤（Chicago）＋1 點框的一列；行事曆用 1-bit 日曆／時鐘圖示
        let calendar = s.source == ClioToolGroup.calendar.source
        for d in details.prefix(4) {
            let (lab, value) = Self.splitDetail(d)
            let row = Self.splitRow(value)
            guard y + 70 < bottom else { break }
            if let lab { y += 18; t.text(clipped(lab, label, width), left, y, label); y += 8 }
            let ry = y / 2, rh = 16
            b.box(left / 2, ry, width / 2, rh)
            var tx = left + 12
            if calendar {
                b.bitmap(row.trailing.map { $0.contains { $0.isNumber } } == true ? Sys6Art.iconClock : Sys6Art.iconCalendar, left / 2 + 4, ry + 4, 1)
                tx = left + 28
            }
            var tw = width - 24
            if let tr = row.trailing {
                let trw = t.width(tr, small)
                t.text(tr, right - 10 - trw, ry * 2 + 22, small)
                tw -= trw + 16
            }
            t.text(clipped(row.title, body, tw - (tx - left)), tx, ry * 2 + 23, body)
            y = (ry + rh) * 2 + 6
        }
        // 交給 App 的物件
        if let h = s.handoff, y + 90 < bottom {
            y += 8
            let cy = y / 2, ch = h.detail.isEmpty ? 26 : 34, cw = width / 2 - 2
            if h.state == .done { Clio1988Art.kept(b, left / 2, cy, cw, ch) } else { Clio1988Art.dotted(b, left / 2, cy, cw, ch) }
            b.bitmap(Clio1988Art.icon(h.kind), left / 2 + 5, cy + (ch - 18) / 2, 2)
            let tx = left + 56, st = h.stateText, stw = t.width(st, small)
            t.text(clipped(h.app, label, width - 80 - stw - 30), tx, cy * 2 + 19, label)
            t.text(st, right - 14 - stw, cy * 2 + 19, small)
            if h.state == .done { b.bitmap(Clio1988Art.check, (right - 14 - stw) / 2 - 9, cy + 4, 1) }
            t.text(clipped(h.title, bold, width - 80), tx, cy * 2 + 41, bold)
            if !h.detail.isEmpty {
                let dt = h.kind == .message ? String(format: L("clio.card.quote", "“%@”"), h.detail) : h.detail
                t.text(clipped(dt, small, width - 80), tx, cy * 2 + 60, small)
            }
            y = (cy + ch + 2) * 2 + 10
        }
        // 來源與模型：小框，模型放最後
        var chips: [String] = []
        if let first = s.sources.first { chips.append(first); if s.sources.count > 1 { chips.append("+\(s.sources.count - 1)") } }
        else if let src = s.source { chips.append(src) }
        if s.phase != .error, !s.model.isEmpty { chips.append(s.model) }
        // 確認時 1988 的視窗比較擠：留給「你說『好』才會做」那一行，模型框不畫
        if !(busy && s.answer.isEmpty), s.phase != .confirm, !chips.isEmpty, y + 40 < bottom {
            var cx = left / 2
            let cy = y / 2 + 2
            for c in chips {
                let w = (t.width(c, small) + 14) / 2 + 1
                guard cx + w < (right / 2) else { break }
                b.box(cx, cy, w, 11)
                t.text(c, cx * 2 + 7, cy * 2 + 16, small)
                cx += w + 3
            }
            y = (cy + 11) * 2
        }

        // 底部：按鈕靠右（System 6 的對話框排法：取消在左、預設在最右），狀態在左
        var items: [(ClioTalkPanel.Chip, String)] = []
        switch s.phase {
        case .confirm: items = [(.cancel, L("clio.chip.cancel", "取消")), (.ok, L("clio.chip.ok", "好"))]
        case .error: items = [(.settings, L("clio.chip.settings", "设置…")), (.retry, L("clio.chip.retry", "再试一次"))]
        case .thinking, .streaming: items = [(.stop, L("clio.chip.stop", "停止"))]
        case .idle: items = s.answer.isEmpty && heard == nil ? [(.ask, L("clio.chip.ask", "问点什么"))] : []
        }
        var buttons: [(ClioTalkPanel.Chip, CGRect)] = []
        let bh = 22, byy = win.y + win.h - bh - 8
        var bx = win.x + win.w - 10
        let bf = Sys6Art.chicago(22)
        for (i, (chip, title)) in items.enumerated().reversed() {
            let bw = max(64, (t.width(title, bf) + 36) / 2)
            bx -= bw
            let isDefault = i == items.count - 1 && s.phase != .thinking && s.phase != .streaming && s.phase != .idle
            Clio1988Art.button(b, bx, byy, bw, bh, isDefault: isDefault)
            t.text(title, bx * 2 + bw, byy * 2 + bh + 8, bf, align: 0)
            buttons.append((chip, CGRect(x: bx * 4, y: byy * 4, width: bw * 4, height: bh * 4)))
            bx -= isDefault ? 14 : 10
        }
        var status: String?
        switch s.phase {
        case .thinking: status = s.note ?? L("clio.status.thinking", "正在想…")
        case .streaming: status = L("clio.status.answering", "正在回答…")
        case .confirm: status = L("clio.status.confirm", "你说「好」才会做")
        case .error: status = nil
        case .idle where heard != nil: status = ClioTalkPanel.voiceView(s, CACurrentMediaTime()).listenHint   // 2.0 P10：從頂端滑下來＝免按住的說法
        case .idle: status = s.kept ? L("clio.status.kept", "已留下 · 存在这台 Mac") : (hint ?? (s.answer.isEmpty ? L("clio.status.ready", "按住 F5 或点这里问") : nil))
        }
        if let status {
            let sx = win.x + 8, sy = byy + bh / 2
            var tx = sx * 2
            if busy { b.bitmap(Clio1988Art.watch, sx, sy - 6, 1); tx += 28 }
            let maxW = (bx - sx) * 2 - (busy ? 28 : 0) - 8
            // 跟按鈕同一列放不下：改放在按鈕上面一行（不截掉「好」這種關鍵字）
            let above = !items.isEmpty && t.width(status, small) > maxW
            let lines = items.isEmpty ? wrap(status, maxLines: 2, w: width, font: small).map { $0.map(\.text).joined() } : [above ? clipped(status, small, width) : status]
            var base = items.isEmpty ? (win.y + win.h - 6) * 2 - (lines.count - 1) * 20 : above ? byy * 2 - 16 : sy * 2 + 6
            if above { tx = sx * 2 + (busy ? 28 : 0) }
            if above && base - 18 < y + 6 { base = -100 }   // 上面也擠：不畫（按鈕本身已經說清楚）
            for l in lines where base > 0 {
                // 👀 在 1-bit 裡畫不出彩色表情：換成選單列那對 1-bit 👀（同一對眼睛的這個年代畫法）
                var x = tx
                for (i, part) in l.components(separatedBy: "👀").enumerated() {
                    if i > 0 { t.bitmap(Sys6Art.eyesMenu, x + 2, base - 11); x += 18 }
                    x += t.text(part, x, base, small)
                }
                base += 20
            }
        }
        _ = tick
        let menu = drawMenus1988(b, s)
        let beadRect = CGRect(x: CGFloat(bead.x - 4) * 4, y: CGFloat(bead.y - 4) * 4, width: CGFloat(bead.w + 8) * 4, height: CGFloat(bead.h + 8) * 4)
        return (key, b.finish(), t.finish(), buttons, beadRect, menu)
    }
}

extension Face {
    /// 第六輪 #7：選單列的標題位置，拉開的那一個反白＋下拉選單。下拉選單畫在自己的一層（512 點座標、2 倍＝256 點的 1 點），最後才貼，蓋得住視窗裡的字與 👀 按鈕
    fileprivate func drawMenus1988(_ b: Bit1, _ s: ClioSnapshot) -> CGImage? {
        let M = Clio1988Menu.self
        let f = Sys6Art.chicago(12)
        var x = 38
        var rects: [CGRect] = [], spans: [(Int, Int)] = []
        for title in M.titles {
            let w = b.width(title, f)
            spans.append((x - 6, w + 12))
            rects.append(CGRect(x: (x - 6) * 4, y: 0, width: (w + 12) * 4, height: 19 * 4))
            x += w + 13
        }
        M.titleRects = rects
        M.itemRects = []
        let hot = M.pressedTitle ?? M.open
        if let i = hot, i < spans.count {
            let (sx, sw) = spans[i]
            b.fill(sx, 0, sw, 19)                                   // 標題反白
            b.text(M.titles[i], sx + 6, 14, f, white: true)
        }
        guard let m = M.open, m < spans.count else { return nil }
        let t = Bit1(1024, 1024); t.ctx.scaleBy(x: 2, y: 2)   // 自己一層：最後才貼，蓋得住 👀 預設按鈕
        let items = M.items(m)
        let itemFont = Sys6Art.chicago(24), ih = 16            // 每項 16 點高
        let tw = items.map { t.width(M.title($0), itemFont) }.max() ?? 0
        let mx = spans[m].0, my = 19, mw = max(spans[m].1 + 20, (tw + 1) / 2 + 30), mh = items.count * ih + 2
        // 256 點 → 字層的 512 點
        func F(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ black: Bool = true) { t.fill(x * 2, y * 2, w * 2, h * 2, black) }
        F(mx, my, mw, mh, false)
        F(mx, my, mw, 1); F(mx, my + mh - 1, mw, 1); F(mx, my, 1, mh); F(mx + mw - 1, my, 1, mh)   // 1 點框
        F(mx + 1, my + mh, mw, 1); F(mx + mw, my + 1, 1, mh)                                        // 右下 1 點硬影
        let provider = ClioSettings.provider
        for (k, item) in items.enumerated() {
            let iy = my + 1 + k * ih
            let on = M.enabled(item, s, provider: provider)
            let hl = on && M.pressed == item
            if hl { F(mx + 1, iy, mw - 2, ih) }
            let tx = (mx + 14) * 2, base = iy * 2 + 25
            t.text(M.title(item), tx, base, itemFont, white: hl)
            if !on {
                // 停用＝50% 網點的灰字：字上每隔一點蓋一點白（以絕對座標排，跟網點桌面對得上）
                let w = t.width(M.title(item), itemFont)
                for yy in stride(from: iy * 2 + 2, to: (iy + ih) * 2 - 2, by: 1) {
                    for xx in stride(from: tx - 1, to: tx + w + 2, by: 1) where (xx + yy) % 2 == 0 { t.fill(xx, yy, 1, 1, false) }
                }
            }
            M.itemRects.append((item, CGRect(x: CGFloat(mx * 4), y: CGFloat(iy * 4), width: CGFloat(mw * 4), height: CGFloat(ih * 4)), on))
        }
        return t.finish()
    }
}
